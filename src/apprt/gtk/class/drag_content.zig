const std = @import("std");
const Allocator = std.mem.Allocator;
const gdk = @import("gdk");
const gio = @import("gio");
const glib = @import("glib");
const gobject = @import("gobject");

const terminal = @import("../../../terminal/main.zig");
const Common = @import("../class.zig").Common;
const Application = @import("application.zig").Application;
const Surface = @import("surface.zig").Surface;

const log = std.log.scoped(.gtk_ghostty_drag_content);

/// The content of a drag a program running in the terminal offers (the
/// Kitty drag and drop protocol). Each offered MIME type is served when a
/// drop target asks for it: from the data the program sent ahead of the
/// drag, or by asking the program for it and streaming its reply, which
/// arrives through `feed`.
pub const DragContent = extern struct {
    const Self = @This();
    parent_instance: Parent,
    pub const Parent = gdk.ContentProvider;
    pub const getGObjectType = gobject.ext.defineClass(Self, .{
        .name = "GhosttyDragContent",
        .classInit = &Class.init,
        .parent_class = &Class.parent,
        .private = .{ .Type = Private, .offset = &Private.offset },
    });

    const Private = struct {
        /// Owns the MIME types.
        arena: std.heap.ArenaAllocator,

        /// The offered MIME types, in the program's order, which is the
        /// index the program knows them by.
        mimes: [][:0]const u8,

        /// The data the program sent ahead of the drag, by MIME type.
        pre_sent: []?*glib.Bytes,

        /// The surface to ask the program through. Cleared when the drag
        /// ends so a drop target reading late gets an error instead of
        /// talking to a program that moved on.
        surface: ?*Surface,

        /// Writes waiting on data from the program.
        writes: std.ArrayList(*Write),

        /// The program's reply for each MIME type, kept as it arrives so
        /// a read that starts partway gets all of it, and once complete
        /// so later reads don't ask again.
        replies: []Reply,

        pub var offset: c_int = 0;
    };

    const Reply = struct {
        state: enum { none, requested, complete } = .none,
        data: std.ArrayListUnmanaged(u8) = .empty,
    };

    /// One drop target read of one MIME type.
    const Write = struct {
        self: *Self,
        index: u32,
        task: *gio.Task,
        stream: *gio.OutputStream,

        /// Data received and not yet written.
        queue: std.ArrayList(u8) = .empty,

        /// Data being written; must stay valid until the write finishes.
        writing: ?[]u8 = null,

        status: terminal.dnd.DragEvent.Data.Status = .pending,

        fn destroy(write: *Write, alloc: Allocator) void {
            write.queue.deinit(alloc);
            if (write.writing) |buf| alloc.free(buf);
            write.task.unref();
            write.stream.unref();
            alloc.destroy(write);
        }
    };

    /// Create the content for a drag the program asked to start.
    pub fn new(surface: *Surface, offer: *const terminal.dnd.DragEvent.Offer) Allocator.Error!*Self {
        const self = gobject.ext.newInstance(Self, .{});
        errdefer self.unref();

        const alloc = Application.default().allocator();
        const priv = self.private();
        priv.* = .{
            .arena = .init(alloc),
            .mimes = &.{},
            .pre_sent = &.{},
            .surface = surface.ref(),
            .writes = .empty,
            .replies = &.{},
        };

        const arena = priv.arena.allocator();
        priv.mimes = try arena.alloc([:0]const u8, offer.items.len);
        priv.pre_sent = try arena.alloc(?*glib.Bytes, offer.items.len);
        priv.replies = try arena.alloc(Reply, offer.items.len);
        @memset(priv.replies, .{});
        for (offer.items, priv.mimes, priv.pre_sent) |item, *mime, *pre_sent| {
            mime.* = try arena.dupeZ(u8, item.mime);
            pre_sent.* = if (item.pre_sent) |data| glib.Bytes.new(data.ptr, data.len) else null;
        }

        return self;
    }

    /// The program's reply for a MIME type a drop target asked for.
    pub fn feed(self: *Self, data: *const terminal.dnd.DragEvent.Data) void {
        const alloc = Application.default().allocator();
        const priv = self.private();
        if (data.index < priv.replies.len) {
            const reply = &priv.replies[data.index];
            switch (data.status) {
                .pending => reply.data.appendSlice(alloc, data.bytes) catch {},
                .complete => {
                    reply.data.appendSlice(alloc, data.bytes) catch {};
                    reply.state = .complete;
                },
                // Asked again by the next read.
                .failed => {
                    reply.state = .none;
                    reply.data.clearRetainingCapacity();
                },
            }
        }

        var i: usize = 0;
        while (i < priv.writes.items.len) {
            const write = priv.writes.items[i];
            if (write.index != data.index or write.status != .pending) {
                i += 1;
                continue;
            }
            write.queue.appendSlice(alloc, data.bytes) catch {
                write.status = .failed;
            };
            if (write.status == .pending) write.status = data.status;

            // A write may finish (and be removed) while pumping.
            const before = priv.writes.items.len;
            pump(write);
            if (priv.writes.items.len == before) i += 1;
        }
    }

    /// The drag ended: nothing more will come from the program.
    pub fn end(self: *Self) void {
        const priv = self.private();
        if (priv.surface) |surface| surface.unref();
        priv.surface = null;

        // Fail every read still waiting, newest first since each removes
        // itself.
        while (priv.writes.items.len > 0) {
            const write = priv.writes.items[priv.writes.items.len - 1];
            if (write.writing != null) {
                // Its write callback finishes it.
                write.status = .failed;
                write.queue.clearRetainingCapacity();
                _ = priv.writes.pop();
                continue;
            }
            write.status = .failed;
            pump(write);
        }
    }

    fn refFormats(self: *Self) callconv(.c) *gdk.ContentFormats {
        const builder = gdk.ContentFormatsBuilder.new();
        for (self.private().mimes) |mime| builder.addMimeType(mime.ptr);
        return builder.freeToFormats();
    }

    fn writeMimeTypeAsync(
        self: *Self,
        mime: [*:0]const u8,
        stream: *gio.OutputStream,
        _: c_int,
        cancellable: ?*gio.Cancellable,
        callback: ?gio.AsyncReadyCallback,
        user_data: ?*anyopaque,
    ) callconv(.c) void {
        const task = gio.Task.new(self.as(gobject.Object), cancellable, callback, user_data);
        const priv = self.private();
        const alloc = Application.default().allocator();

        const index: u32 = index: {
            const wanted = std.mem.span(mime);
            for (priv.mimes, 0..) |m, i| {
                if (std.mem.eql(u8, m, wanted)) break :index @intCast(i);
            }
            returnError(task, "MIME type not offered");
            task.unref();
            return;
        };

        const write = alloc.create(Write) catch {
            returnError(task, "out of memory");
            task.unref();
            return;
        };
        write.* = .{
            .self = self,
            .index = index,
            .task = task,
            .stream = stream,
        };
        stream.ref();
        priv.writes.append(alloc, write) catch {
            returnError(task, "out of memory");
            write.destroy(alloc);
            return;
        };

        if (priv.pre_sent[index]) |bytes| {
            var len: usize = 0;
            const data: [*]const u8 = @ptrCast(bytes.getData(&len) orelse "");
            write.queue.appendSlice(alloc, data[0..len]) catch {
                write.status = .failed;
            };
            if (write.status == .pending) write.status = .complete;
            pump(write);
            return;
        }

        // What the program sent so far, or all of it.
        const reply = &priv.replies[index];
        write.queue.appendSlice(alloc, reply.data.items) catch {
            write.status = .failed;
            return pump(write);
        };
        switch (reply.state) {
            .complete => {
                write.status = .complete;
                return pump(write);
            },
            .requested => return,
            .none => {},
        }

        // Ask the program. Its reply arrives through `feed`.
        const surface = priv.surface orelse {
            write.status = .failed;
            pump(write);
            return;
        };
        if (!surface.dndDragRequest(index)) {
            write.status = .failed;
            pump(write);
            return;
        }
        reply.state = .requested;
    }

    fn writeMimeTypeFinish(
        _: *Self,
        result: *gio.AsyncResult,
        err: ?*?*glib.Error,
    ) callconv(.c) c_int {
        const task = gobject.ext.cast(gio.Task, result) orelse return 0;
        return task.propagateBoolean(err);
    }

    /// Write what has arrived, and finish the read once everything has.
    fn pump(write: *Write) void {
        if (write.writing != null) return;
        const alloc = Application.default().allocator();

        if (write.queue.items.len > 0) {
            const buf = write.queue.toOwnedSlice(alloc) catch {
                write.status = .failed;
                return finish(write);
            };
            write.writing = buf;
            write.stream.writeAllAsync(
                buf.ptr,
                buf.len,
                glib.PRIORITY_DEFAULT,
                null,
                writeFinished,
                write,
            );
            return;
        }

        if (write.status != .pending) finish(write);
    }

    fn writeFinished(
        source: ?*gobject.Object,
        result: *gio.AsyncResult,
        ud: ?*anyopaque,
    ) callconv(.c) void {
        const write: *Write = @ptrCast(@alignCast(ud orelse return));
        const alloc = Application.default().allocator();
        if (write.writing) |buf| alloc.free(buf);
        write.writing = null;

        const stream = gobject.ext.cast(gio.OutputStream, source orelse return) orelse return;
        var gerr: ?*glib.Error = null;
        _ = stream.writeAllFinish(result, null, &gerr);
        if (gerr) |err| {
            defer err.free();
            log.warn("error writing drag data err={s}", .{err.f_message orelse "(no message)"});
            write.status = .failed;
            write.queue.clearRetainingCapacity();
        }

        // `end` may have dropped this write from the list while it was
        // being written.
        const priv = write.self.private();
        if (std.mem.indexOfScalar(*Write, priv.writes.items, write) == null) {
            returnError(write.task, "drag ended");
            write.destroy(alloc);
            return;
        }
        pump(write);
    }

    fn finish(write: *Write) void {
        const priv = write.self.private();
        if (std.mem.indexOfScalar(*Write, priv.writes.items, write)) |i| {
            _ = priv.writes.orderedRemove(i);
        }
        switch (write.status) {
            .complete => write.task.returnBoolean(1),
            .pending, .failed => returnError(write.task, "the program couldn't provide the data"),
        }
        write.destroy(Application.default().allocator());
    }

    fn returnError(task: *gio.Task, msg: [*:0]const u8) void {
        task.returnNewErrorLiteral(gio.ioErrorQuark(), @intFromEnum(gio.IOErrorEnum.failed), msg);
    }

    fn dispose(self: *Self) callconv(.c) void {
        self.end();
        gobject.Object.virtual_methods.dispose.call(Class.parent, self.as(Parent));
    }

    fn finalize(self: *Self) callconv(.c) void {
        const priv = self.private();
        for (priv.pre_sent) |bytes| if (bytes) |b| b.unref();
        for (priv.replies) |*reply| reply.data.deinit(Application.default().allocator());
        priv.writes.deinit(Application.default().allocator());
        priv.arena.deinit();
        gobject.Object.virtual_methods.finalize.call(Class.parent, self.as(Parent));
    }

    const C = Common(Self, Private);
    pub const as = C.as;
    pub const ref = C.ref;
    pub const unref = C.unref;
    const private = C.private;

    pub const Class = extern struct {
        parent_class: Parent.Class,
        var parent: *Parent.Class = undefined;
        pub const Instance = Self;

        fn init(class: *Class) callconv(.c) void {
            gobject.Object.virtual_methods.dispose.implement(class, &dispose);
            gobject.Object.virtual_methods.finalize.implement(class, &finalize);
            gdk.ContentProvider.virtual_methods.ref_formats.implement(class, &refFormats);
            gdk.ContentProvider.virtual_methods.write_mime_type_async.implement(class, &writeMimeTypeAsync);
            gdk.ContentProvider.virtual_methods.write_mime_type_finish.implement(class, &writeMimeTypeFinish);
        }
    };
};
