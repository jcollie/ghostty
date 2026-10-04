//! C API for native drag and drop: the drop and drag effects, which tell
//! the embedder what the running program did, and ghostty_terminal_drop()
//! and ghostty_terminal_drag(), which report what the user did natively.
//! Kitty's OSC 72 is the only protocol behind them today.

const std = @import("std");
const testing = std.testing;
const lib = @import("../lib.zig");
const dnd = @import("../dnd.zig");
const kitty_dnd = @import("../kitty/dnd.zig");
const stream_terminal = @import("../stream_terminal.zig");
const terminal_c = @import("terminal.zig");
const Terminal = terminal_c.Terminal;
const TerminalWrapper = terminal_c.TerminalWrapper;
const Handler = stream_terminal.Handler;
const Result = @import("result.zig").Result;

const log = std.log.scoped(.dnd_c);

/// A drag and drop operation.
///
/// C: GhosttyDndOperation
pub const Operation = enum(c_int) {
    none = 0,
    copy = 1,
    move = 2,
    _,

    fn init(op: dnd.Operation) Operation {
        return switch (op) {
            .none => .none,
            .copy => .copy,
            .move => .move,
        };
    }

    fn zig(self: Operation) ?dnd.Operation {
        return switch (self) {
            .none => .none,
            .copy => .copy,
            .move => .move,
            _ => null,
        };
    }
};

/// Bits of an operations bitmask (GHOSTTY_DND_OPERATIONS_*).
const operations_copy: u32 = 1;
const operations_move: u32 = 2;

fn operationsMask(ops: dnd.Operations) u32 {
    var mask: u32 = 0;
    if (ops.copy) mask |= operations_copy;
    if (ops.move) mask |= operations_move;
    return mask;
}

/// A position on the terminal.
///
/// C: GhosttyDndPosition
pub const Position = extern struct {
    cell_x: u32,
    cell_y: u32,
    pixel_x: i32,
    pixel_y: i32,
};

/// C: GhosttyDropRegistration
pub const DropRegistration = extern struct {
    accepting: bool,
    mimes: ?[*]const lib.String,
    mimes_len: usize,
};

/// C: GhosttyDropAcceptance
pub const DropAcceptance = extern struct {
    operation: Operation,
    mimes: ?[*]const lib.String,
    mimes_len: usize,
};

/// C: GhosttyDropDataRequest
pub const DropDataRequest = extern struct {
    id: u32,
    mime_index: u32,
    mime: lib.String,
};

/// A change in drops onto the terminal, delivered to the drop effect.
///
/// C: GhosttyDropEvent
pub const DropEvent = union(Tag) {
    registration: DropRegistration,
    acceptance: DropAcceptance,
    data_request: DropDataRequest,
    concluded: Operation,

    /// C: GhosttyDropEventTag
    pub const Tag = lib.Enum(lib.target, &.{
        "registration",
        "acceptance",
        "data_request",
        "concluded",
    });

    const c_union = lib.TaggedUnion(lib.target, @This(), .{ .padding = [8]u64 });
    pub const C = c_union.C;
    pub const CValue = c_union.CValue;
    pub const cval = c_union.cval;
};

/// C: GhosttyTerminalDropFn
pub const DropFn = *const fn (Terminal, ?*anyopaque, *const DropEvent.C) callconv(lib.calling_conv) void;

/// A native drag over or dropped onto the terminal.
///
/// C: GhosttyDropMotion
pub const DropMotion = extern struct {
    position: Position,

    /// GHOSTTY_DND_OPERATIONS_* bits for the operations the drag allows.
    operations: u32,

    mimes: ?[*]const lib.String,
    mimes_len: usize,
};

/// C: GhosttyDropData
pub const DropData = extern struct {
    id: u32,
    data: lib.String,
};

/// Why reading drop data failed.
///
/// C: GhosttyDropError
pub const DropError = enum(c_int) {
    io = 0,
    not_found = 1,
    denied = 2,
    too_large = 3,
    out_of_memory = 4,
    _,

    fn zig(self: DropError) ?dnd.DropInput.Error {
        return switch (self) {
            .io => .io,
            .not_found => .not_found,
            .denied => .denied,
            .too_large => .too_large,
            .out_of_memory => .out_of_memory,
            _ => null,
        };
    }
};

/// C: GhosttyDropFailure
pub const DropFailure = extern struct {
    id: u32,
    reason: DropError,
};

/// Native drop activity reported with ghostty_terminal_drop().
///
/// C: GhosttyDropInput
pub const DropInput = union(Tag) {
    move: DropMotion,
    leave: void,
    drop: DropMotion,
    data: DropData,
    end: u32,
    fail: DropFailure,

    /// C: GhosttyDropInputTag
    pub const Tag = lib.Enum(lib.target, &.{
        "move",
        "leave",
        "drop",
        "data",
        "end",
        "fail",
    });

    const c_union = lib.TaggedUnion(lib.target, @This(), .{
        .padding = [8]u64,
        .field_renames = .{ .end = "id" },
    });
    pub const C = c_union.C;
    pub const CValue = c_union.CValue;
    pub const cval = c_union.cval;
};

/// C: GhosttyDragItem
pub const DragItem = extern struct {
    mime: lib.String,
    has_pre_sent: bool,
    pre_sent: lib.String,
};

/// C: GhosttyDragImage
pub const DragImage = extern struct {
    format: dnd.Image.Format,
    width: u32,
    height: u32,
    opacity: u32,
    data: lib.String,
};

/// C: GhosttyDragOffer
pub const DragOffer = extern struct {
    /// GHOSTTY_DND_OPERATIONS_* bits.
    operations: u32,
    items: ?[*]const DragItem,
    items_len: usize,
    images: ?[*]const DragImage,
    images_len: usize,
    has_image: bool,
    image: u32,
};

/// C: GhosttyDragImageChange
pub const DragImageChange = extern struct {
    has_image: bool,
    image: u32,
};

/// C: GhosttyDragData
pub const DragData = extern struct {
    index: u32,
    bytes: lib.String,
    status: dnd.DragEvent.Data.Status,
};

/// A change in the drag the program offers, delivered to the drag effect.
///
/// C: GhosttyDragEvent
pub const DragEvent = union(Tag) {
    offers: bool,
    start: DragOffer,
    image: DragImageChange,
    data: DragData,
    cancel: void,

    /// C: GhosttyDragEventTag
    pub const Tag = lib.Enum(lib.target, &.{
        "offers",
        "start",
        "image",
        "data",
        "cancel",
    });

    const c_union = lib.TaggedUnion(lib.target, @This(), .{
        .padding = [8]u64,
        .field_renames = .{ .offers = "enabled" },
    });
    pub const C = c_union.C;
    pub const CValue = c_union.CValue;
    pub const cval = c_union.cval;
};

/// C: GhosttyTerminalDragFn
pub const DragFn = *const fn (Terminal, ?*anyopaque, *const DragEvent.C) callconv(lib.calling_conv) void;

/// The result of starting a native drag the program asked for.
///
/// C: GhosttyDragStartResult
pub const DragStartResult = enum(c_int) {
    /// The native drag started.
    started = 0,

    /// The user already let go of the drag.
    denied = 1,

    /// The native drag couldn't be started.
    failed = 2,
    _,
};

/// Native drag activity reported with ghostty_terminal_drag().
///
/// C: GhosttyDragInput
pub const DragInput = union(Tag) {
    gesture: Position,
    start_result: DragStartResult,
    accepted: i32,
    operation: Operation,
    dropped: void,
    finished: bool,
    request_data: u32,

    /// C: GhosttyDragInputTag
    pub const Tag = lib.Enum(lib.target, &.{
        "gesture",
        "start_result",
        "accepted",
        "operation",
        "dropped",
        "finished",
        "request_data",
    });

    const c_union = lib.TaggedUnion(lib.target, @This(), .{
        .padding = [8]u64,
        .field_renames = .{
            .gesture = "position",
            .accepted = "mime_index",
            .finished = "canceled",
            .request_data = "index",
        },
    });
    pub const C = c_union.C;
    pub const CValue = c_union.CValue;
    pub const cval = c_union.cval;
};

/// The drop effect trampoline, installed on the stream handler while a
/// C drop callback is set.
pub fn dropTrampoline(handler: *Handler, ev: dnd.DropEvent) void {
    const wrapper = TerminalWrapper.fromHandler(handler);
    const func = wrapper.effects.drop orelse return;

    // MIME lists are short, so keep the common case allocation-free.
    var sfa = std.heap.stackFallback(512, wrapper.terminal.gpa());
    const alloc = sfa.get();
    var mimes: []lib.String = &.{};
    defer alloc.free(mimes);

    const value: DropEvent.C = DropEvent.cval(switch (ev) {
        .registration => |r| reg: {
            mimes = mimeStrings(alloc, r.mimes);
            break :reg .{ .registration = .{
                .accepting = r.accepting,
                .mimes = mimes.ptr,
                .mimes_len = mimes.len,
            } };
        },
        .acceptance => |a| acc: {
            mimes = mimeStrings(alloc, a.mimes);
            break :acc .{ .acceptance = .{
                .operation = .init(a.operation),
                .mimes = mimes.ptr,
                .mimes_len = mimes.len,
            } };
        },
        .data_request => |r| .{ .data_request = .{
            .id = r.id,
            .mime_index = r.mime_index,
            .mime = .init(r.mime),
        } },
        .concluded => |op| .{ .concluded = .init(op) },
    });
    func(@ptrCast(wrapper), wrapper.effects.userdata, &value);
}

fn mimeStrings(alloc: std.mem.Allocator, list: dnd.MimeList) []lib.String {
    const strings = alloc.alloc(lib.String, list.count()) catch {
        log.warn("out of memory listing drag and drop MIME types", .{});
        return &.{};
    };
    var it = list.iterator();
    for (strings) |*s| s.* = .init(it.next().?);
    return strings;
}

/// The drag effect trampoline, installed on the stream handler while a
/// C drag callback is set.
pub fn dragTrampoline(handler: *Handler, ev: dnd.DragEvent) void {
    const wrapper = TerminalWrapper.fromHandler(handler);
    const func = wrapper.effects.drag orelse return;

    var sfa = std.heap.stackFallback(1024, wrapper.terminal.gpa());
    const alloc = sfa.get();
    var items: []DragItem = &.{};
    defer alloc.free(items);
    var images: []DragImage = &.{};
    defer alloc.free(images);

    const value: DragEvent.C = DragEvent.cval(switch (ev) {
        .offers => |enabled| .{ .offers = enabled },
        .start => |offer| start: {
            items = alloc.alloc(DragItem, offer.items.len) catch {
                log.warn("out of memory starting a drag", .{});
                return;
            };
            for (items, offer.items) |*item, src| item.* = .{
                .mime = .init(src.mime),
                .has_pre_sent = src.pre_sent != null,
                .pre_sent = .init(src.pre_sent orelse ""),
            };
            images = alloc.alloc(DragImage, offer.images.len) catch {
                log.warn("out of memory starting a drag", .{});
                return;
            };
            for (images, offer.images) |*image, src| image.* = .{
                .format = src.format,
                .width = src.width,
                .height = src.height,
                .opacity = src.opacity,
                .data = .init(src.data),
            };
            break :start .{ .start = .{
                .operations = operationsMask(offer.operations),
                .items = items.ptr,
                .items_len = items.len,
                .images = images.ptr,
                .images_len = images.len,
                .has_image = offer.image != null,
                .image = offer.image orelse 0,
            } };
        },
        .image => |image| .{ .image = .{
            .has_image = image != null,
            .image = image orelse 0,
        } },
        .data => |data| .{ .data = .{
            .index = data.index,
            .bytes = .init(data.bytes),
            .status = data.status,
        } },
        .cancel => .cancel,
    });
    func(@ptrCast(wrapper), wrapper.effects.userdata, &value);
}

/// A pty writer for answering the program outside of vt_write.
const Pty = struct {
    buf: [4096]u8 = undefined,
    pty: stream_terminal.PtyWriter = undefined,

    fn init(self: *Pty, wrapper: *TerminalWrapper) *std.Io.Writer {
        self.pty = wrapper.stream.handler.ptyWriter(&self.buf);
        return &self.pty.writer;
    }

    fn flush(self: *Pty) void {
        // The pty writer never fails.
        self.pty.writer.flush() catch unreachable;
    }
};

/// The state for an input function: the wrapper, which must be able to
/// write to the pty, and the drag and drop state, which must exist.
fn inputState(terminal_: Terminal) union(enum) {
    ok: struct { *TerminalWrapper, *kitty_dnd.State },
    err: Result,
} {
    const wrapper = terminal_ orelse return .{ .err = .invalid_value };
    if (wrapper.effects.write_pty == null) return .{ .err = .invalid_value };
    const state = wrapper.terminal.kitty_dnd orelse return .{ .err = .no_value };
    return .{ .ok = .{ wrapper, state } };
}

pub fn terminal_drop(
    terminal_: Terminal,
    input_: ?*const DropInput.C,
) callconv(lib.calling_conv) Result {
    const input = input_ orelse return .invalid_value;
    _ = std.enums.fromInt(DropInput.Tag, @intFromEnum(input.tag)) orelse
        return .invalid_value;
    const wrapper, const state = switch (inputState(terminal_)) {
        .ok => |v| v,
        .err => |e| return e,
    };
    const gpa = wrapper.terminal.gpa();

    // MIME lists are short, so keep the common case allocation-free.
    var sfa = std.heap.stackFallback(256, gpa);
    const alloc = sfa.get();
    var mimes: []const []const u8 = &.{};
    defer alloc.free(mimes);

    const zig_input: dnd.DropInput = switch (input.tag) {
        .move, .drop => motion: {
            const motion = if (input.tag == .move) input.value.move else input.value.drop;
            if (motion.mimes == null and motion.mimes_len > 0) return .invalid_value;
            const c_mimes: []const lib.String = if (motion.mimes) |ptr| ptr[0..motion.mimes_len] else &.{};
            const slices = alloc.alloc([]const u8, c_mimes.len) catch return .out_of_memory;
            for (slices, c_mimes) |*m, c| m.* = c.ptr[0..c.len];
            mimes = slices;

            const value: dnd.DropInput.Motion = .{
                .position = .{
                    .cell_x = motion.position.cell_x,
                    .cell_y = motion.position.cell_y,
                    .pixel_x = motion.position.pixel_x,
                    .pixel_y = motion.position.pixel_y,
                },
                .operations = .{
                    .copy = motion.operations & operations_copy != 0,
                    .move = motion.operations & operations_move != 0,
                },
                .mimes = mimes,
            };
            break :motion if (input.tag == .move) .{ .move = value } else .{ .drop = value };
        },
        .leave => .leave,
        .data => .{ .data = .{
            .id = input.value.data.id,
            .bytes = input.value.data.data.ptr[0..input.value.data.data.len],
        } },
        .end => .{ .end = input.value.end },
        .fail => .{ .fail = .{
            .id = input.value.fail.id,
            .reason = input.value.fail.reason.zig() orelse return .invalid_value,
        } },
    };

    var pty: Pty = .{};
    const followup = kitty_dnd.dropInput(state, gpa, pty.init(wrapper), zig_input) catch |err| {
        pty.flush();
        return inputResult(err);
    };

    // The embedder hears what comes next once the messages are sent.
    pty.flush();
    if (followup) |ev| dropTrampoline(&wrapper.stream.handler, ev);
    return .success;
}

pub fn terminal_drag(
    terminal_: Terminal,
    input_: ?*const DragInput.C,
) callconv(lib.calling_conv) Result {
    const input = input_ orelse return .invalid_value;
    _ = std.enums.fromInt(DragInput.Tag, @intFromEnum(input.tag)) orelse
        return .invalid_value;
    const wrapper, const state = switch (inputState(terminal_)) {
        .ok => |v| v,
        .err => |e| return e,
    };

    const zig_input: dnd.DragInput = switch (input.tag) {
        .gesture => .{ .gesture = .{
            .cell_x = input.value.gesture.cell_x,
            .cell_y = input.value.gesture.cell_y,
            .pixel_x = input.value.gesture.pixel_x,
            .pixel_y = input.value.gesture.pixel_y,
        } },
        .start_result => .{ .start_result = switch (input.value.start_result) {
            .started => .started,
            .denied => .denied,
            .failed => .failed,
            _ => return .invalid_value,
        } },
        .accepted => .{ .accepted = if (input.value.accepted < 0)
            null
        else
            @intCast(input.value.accepted) },
        .operation => .{ .operation = input.value.operation.zig() orelse return .invalid_value },
        .dropped => .dropped,
        .finished => .{ .finished = input.value.finished },
        .request_data => .{ .request_data = input.value.request_data },
    };

    var pty: Pty = .{};
    defer pty.flush();
    kitty_dnd.dragInput(state, wrapper.terminal.gpa(), pty.init(wrapper), zig_input) catch |err|
        return inputResult(err);
    return .success;
}

fn inputResult(err: kitty_dnd.InputError) Result {
    return switch (err) {
        error.Inactive => .no_value,
        error.Rejected => .rejected,
        error.OutOfMemory => .out_of_memory,
        // The pty writer never fails.
        error.WriteFailed => unreachable,
    };
}

const TestTerminal = struct {
    t: Terminal,

    var pty: std.ArrayListUnmanaged(u8) = .empty;

    /// A copy of each event, since what they borrow is only valid during
    /// the callback.
    var drops: std.ArrayListUnmanaged(DropEvent.Tag) = .empty;
    var drags: std.ArrayListUnmanaged(DragEvent.Tag) = .empty;
    var strings: std.ArrayListUnmanaged(u8) = .empty;
    var last_drop: DropEvent.C = undefined;
    var last_drag: DragEvent.C = undefined;

    fn init() !TestTerminal {
        pty = .empty;
        drops = .empty;
        drags = .empty;
        strings = .empty;
        var t: Terminal = null;
        try testing.expectEqual(Result.success, terminal_c.new(
            &lib.alloc.test_allocator,
            &t,
            80,
            24,
        ));
        try testing.expectEqual(Result.success, terminal_c.set(t, .write_pty, @ptrCast(&writePty)));
        try testing.expectEqual(Result.success, terminal_c.set(t, .drop, @ptrCast(&onDrop)));
        try testing.expectEqual(Result.success, terminal_c.set(t, .drag, @ptrCast(&onDrag)));
        return .{ .t = t };
    }

    fn deinit(self: *TestTerminal) void {
        terminal_c.free(self.t);
        pty.deinit(testing.allocator);
        drops.deinit(testing.allocator);
        drags.deinit(testing.allocator);
        strings.deinit(testing.allocator);
    }

    fn writePty(_: Terminal, _: ?*anyopaque, data: [*]const u8, len: usize) callconv(lib.calling_conv) void {
        pty.appendSlice(testing.allocator, data[0..len]) catch @panic("OOM");
    }

    fn record(s: lib.String) void {
        strings.appendSlice(testing.allocator, s.ptr[0..s.len]) catch @panic("OOM");
        strings.append(testing.allocator, ',') catch @panic("OOM");
    }

    fn onDrop(_: Terminal, _: ?*anyopaque, ev: *const DropEvent.C) callconv(lib.calling_conv) void {
        drops.append(testing.allocator, ev.tag) catch @panic("OOM");
        last_drop = ev.*;
        switch (ev.tag) {
            .registration => for (ev.value.registration.mimes.?[0..ev.value.registration.mimes_len]) |m| record(m),
            .acceptance => for (ev.value.acceptance.mimes.?[0..ev.value.acceptance.mimes_len]) |m| record(m),
            .data_request => record(ev.value.data_request.mime),
            .concluded => {},
        }
    }

    fn onDrag(_: Terminal, _: ?*anyopaque, ev: *const DragEvent.C) callconv(lib.calling_conv) void {
        drags.append(testing.allocator, ev.tag) catch @panic("OOM");
        last_drag = ev.*;
        switch (ev.tag) {
            .start => {
                const offer = ev.value.start;
                for (offer.items.?[0..offer.items_len]) |item| {
                    record(item.mime);
                    if (item.has_pre_sent) record(item.pre_sent);
                }
                for (offer.images.?[0..offer.images_len]) |image| record(image.data);
            },
            .data => record(ev.value.data.bytes),
            .offers, .image, .cancel => {},
        }
    }

    fn write(self: *TestTerminal, data: []const u8) void {
        terminal_c.vt_write(self.t, data.ptr, data.len);
    }

    fn drop(self: *TestTerminal, input: DropInput) Result {
        const c = DropInput.cval(input);
        return terminal_drop(self.t, &c);
    }

    fn drag(self: *TestTerminal, input: DragInput) Result {
        const c = DragInput.cval(input);
        return terminal_drag(self.t, &c);
    }

    fn expectOutput(_: *TestTerminal, expected: []const u8) !void {
        try testing.expectEqualStrings(expected, pty.items);
        pty.clearRetainingCapacity();
    }

    fn expectDrops(_: *TestTerminal, expected: []const DropEvent.Tag, expected_strings: []const u8) !void {
        try testing.expectEqualSlices(DropEvent.Tag, expected, drops.items);
        try testing.expectEqualStrings(expected_strings, strings.items);
        drops.clearRetainingCapacity();
        strings.clearRetainingCapacity();
    }

    fn expectDrags(_: *TestTerminal, expected: []const DragEvent.Tag, expected_strings: []const u8) !void {
        try testing.expectEqualSlices(DragEvent.Tag, expected, drags.items);
        try testing.expectEqualStrings(expected_strings, strings.items);
        drags.clearRetainingCapacity();
        strings.clearRetainingCapacity();
    }
};

test "dnd effects enable the protocol" {
    var tt: TestTerminal = try .init();
    defer tt.deinit();

    tt.write("\x1b]72;t=q\x1b\\");
    try tt.expectOutput("\x1b]72;t=q\x1b\\");

    // Without a drag effect, offers are refused.
    try testing.expectEqual(Result.success, terminal_c.set(tt.t, .drag, null));
    tt.write("\x1b]72;t=o:x=1\x1b\\");
    try tt.expectDrags(&.{}, "");
    tt.write("\x1b]72;t=P:x=-1\x1b\\");
    try tt.expectOutput("\x1b]72;t=E:m=0;EPERM:drag out is not supported by this terminal\x1b\\");

    // Without either, OSC 72 is ignored.
    try testing.expectEqual(Result.success, terminal_c.set(tt.t, .drop, null));
    tt.write("\x1b]72;t=q\x1b\\");
    tt.write("\x1b]72;t=a\x1b\\");
    try tt.expectOutput("");
    try tt.expectDrops(&.{}, "");
    try testing.expectEqual(Result.no_value, tt.drop(.leave));
}

test "dnd drop round trip" {
    var tt: TestTerminal = try .init();
    defer tt.deinit();

    const mimes = [_]lib.String{.init(@as([]const u8, "text/plain"))};
    const motion: DropMotion = .{
        .position = .{ .cell_x = 1, .cell_y = 2, .pixel_x = 10, .pixel_y = 20 },
        .operations = operations_copy,
        .mimes = &mimes,
        .mimes_len = mimes.len,
    };

    // Nothing to forward to before registration.
    try testing.expectEqual(Result.no_value, tt.drop(.{ .move = motion }));

    tt.write("\x1b]72;t=a;text/plain\x1b\\");
    try tt.expectDrops(&.{.registration}, "text/plain,");
    try testing.expect(TestTerminal.last_drop.value.registration.accepting);

    try testing.expectEqual(Result.success, tt.drop(.{ .move = motion }));
    try tt.expectOutput("\x1b]72;t=m:x=1:y=2:X=10:Y=20:o=1:m=0;text/plain \x1b\\");

    // The program's acceptance.
    tt.write("\x1b]72;t=m:o=1;text/plain\x1b\\");
    try tt.expectDrops(&.{.acceptance}, "text/plain,");
    try testing.expectEqual(Operation.copy, TestTerminal.last_drop.value.acceptance.operation);

    try testing.expectEqual(Result.success, tt.drop(.{ .drop = motion }));
    try tt.expectOutput("\x1b]72;t=M:x=1:y=2:X=10:Y=20:o=1:m=0;text/plain \x1b\\");
    try tt.expectDrops(&.{}, "");

    // Two requests: the second is handed out once the first is answered,
    // after the effect returned.
    tt.write("\x1b]72;t=r:x=1\x1b\\");
    tt.write("\x1b]72;t=r:x=1\x1b\\");
    try tt.expectDrops(&.{.data_request}, "text/plain,");
    const first = TestTerminal.last_drop.value.data_request;
    try testing.expectEqual(@as(u32, 0), first.mime_index);
    try testing.expectEqual(Result.success, tt.drop(.{ .data = .{ .id = first.id, .data = .init(@as([]const u8, "hi")) } }));
    try testing.expectEqual(Result.success, tt.drop(.{ .end = first.id }));
    try tt.expectOutput("\x1b]72;t=r:x=1:m=0;aGk=\x1b\\\x1b]72;t=r:x=1\x1b\\");
    try testing.expectEqual(Result.rejected, tt.drop(.{ .end = first.id }));
    try tt.expectDrops(&.{.data_request}, "text/plain,");

    // The second fails.
    const second = TestTerminal.last_drop.value.data_request;
    try testing.expectEqual(Result.invalid_value, tt.drop(.{ .fail = .{ .id = second.id, .reason = @enumFromInt(99) } }));
    try testing.expectEqual(Result.success, tt.drop(.{ .fail = .{ .id = second.id, .reason = .io } }));
    try tt.expectOutput("\x1b]72;t=R:x=1:m=0;EIO:drop data request failed to read data\x1b\\");
    try tt.expectDrops(&.{}, "");

    tt.write("\x1b]72;t=r:o=1\x1b\\");
    try tt.expectDrops(&.{.concluded}, "");
    try testing.expectEqual(Operation.copy, TestTerminal.last_drop.value.concluded);
}

test "dnd drop a new drag concludes an abandoned drop" {
    var tt: TestTerminal = try .init();
    defer tt.deinit();

    const motion: DropMotion = .{
        .position = .{ .cell_x = 0, .cell_y = 0, .pixel_x = 0, .pixel_y = 0 },
        .operations = operations_copy,
        .mimes = null,
        .mimes_len = 0,
    };
    tt.write("\x1b]72;t=a\x1b\\");
    try testing.expectEqual(Result.success, tt.drop(.{ .drop = motion }));
    try tt.expectDrops(&.{.registration}, "");

    try testing.expectEqual(Result.success, tt.drop(.{ .move = motion }));
    try tt.expectDrops(&.{.concluded}, "");
    try testing.expectEqual(Operation.none, TestTerminal.last_drop.value.concluded);
}

test "dnd drag round trip" {
    var tt: TestTerminal = try .init();
    defer tt.deinit();

    const pos: Position = .{ .cell_x = 3, .cell_y = 4, .pixel_x = 30, .pixel_y = 40 };
    try testing.expectEqual(Result.no_value, tt.drag(.{ .gesture = pos }));

    tt.write("\x1b]72;t=o:x=1\x1b\\");
    try tt.expectDrags(&.{.offers}, "");
    try testing.expect(TestTerminal.last_drag.value.offers);

    try testing.expectEqual(Result.success, tt.drag(.{ .gesture = pos }));
    try tt.expectOutput("\x1b]72;t=o:x=3:y=4:X=30:Y=40\x1b\\");

    // The program offers a drag with pre-sent data and an image.
    tt.write("\x1b]72;t=o:o=3;text/plain text/html\x1b\\");
    tt.write("\x1b]72;t=p:x=0;aGVsbG8=\x1b\\");
    tt.write("\x1b]72;t=p:x=-1:y=32:X=1:Y=1;/wAA/w==\x1b\\");
    tt.write("\x1b]72;t=P:x=-1\x1b\\");
    try tt.expectDrags(&.{.start}, "text/plain,hello,text/html,\xff\x00\x00\xff,");
    const offer = TestTerminal.last_drag.value.start;
    try testing.expectEqual(operations_copy | operations_move, offer.operations);
    try testing.expect(offer.has_image);
    try testing.expectEqual(@as(u32, 0), offer.image);

    try testing.expectEqual(Result.invalid_value, tt.drag(.{ .start_result = @enumFromInt(9) }));
    try testing.expectEqual(Result.success, tt.drag(.{ .start_result = .started }));
    try tt.expectOutput("\x1b]72;t=E:m=0;OK\x1b\\");
    try testing.expectEqual(Result.rejected, tt.drag(.{ .start_result = .started }));

    // A drop target wants the HTML.
    try testing.expectEqual(Result.success, tt.drag(.{ .request_data = 1 }));
    try tt.expectOutput("\x1b]72;t=e:x=5:y=1\x1b\\");
    try testing.expectEqual(Result.no_value, tt.drag(.{ .request_data = 2 }));
    tt.write("\x1b]72;t=e:y=1:m=1;PGI+\x1b\\");
    tt.write("\x1b]72;t=e:y=1:m=0\x1b\\");
    try tt.expectDrags(&.{ .data, .data }, "<b>,,");
    try testing.expectEqual(dnd.DragEvent.Data.Status.complete, TestTerminal.last_drag.value.data.status);

    try testing.expectEqual(Result.success, tt.drag(.{ .accepted = 1 }));
    try testing.expectEqual(Result.invalid_value, tt.drag(.{ .operation = @enumFromInt(7) }));
    try testing.expectEqual(Result.success, tt.drag(.{ .finished = false }));
    try tt.expectOutput("\x1b]72;t=e:x=1:y=1\x1b\\\x1b]72;t=e:x=4:y=0\x1b\\");
}

test "dnd inputs need write_pty" {
    var t: Terminal = null;
    try testing.expectEqual(Result.success, terminal_c.new(&lib.alloc.test_allocator, &t, 80, 24));
    defer terminal_c.free(t);

    const leave = DropInput.cval(.leave);
    try testing.expectEqual(Result.invalid_value, terminal_drop(t, &leave));
    try testing.expectEqual(Result.invalid_value, terminal_drop(null, &leave));
    try testing.expectEqual(Result.invalid_value, terminal_drop(t, null));
    const dropped = DragInput.cval(.dropped);
    try testing.expectEqual(Result.invalid_value, terminal_drag(t, &dropped));
}
