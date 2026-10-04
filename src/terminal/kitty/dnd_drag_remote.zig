//! Kitty drag and drop protocol (OSC 72): fetching the files of a drag
//! offered by a client on another machine. The client pre-sends the
//! drag's text/uri-list; when a drop target wants it, the terminal asks
//! the client for each file the list names (t=k:x=N) and the client sends
//! them back, directories recursively, which the embedder writes out as
//! they arrive so it can give the drop target a list of local copies.
//!
//! Mirrors kitty's remote drag handling (its drag_process_remote_data),
//! with the embedder writing the files where kitty spools them itself.

const std = @import("std");
const Allocator = std.mem.Allocator;

const simd = @import("../../simd/main.zig");
const dnd = @import("../dnd.zig");
const command = @import("dnd_command.zig");
const response = @import("dnd_response.zig");
const dnd_uri = @import("dnd_uri.zig");

const Metadata = command.Metadata;
const Errno = response.Errno;

/// The maximum base64 bytes of one chunk. Matches kitty.
pub const max_chunk_bytes = 4096;

/// The maximum decoded bytes of all of a drag's files. Matches kitty's
/// REMOTE_DRAG_LIMIT.
pub const max_total_bytes = 1024 * 1024 * 1024;

/// The maximum bytes of one directory listing or symbolic link target.
/// Matches kitty's PRESENT_DATA_CAP.
pub const max_entry_bytes = 64 * 1024 * 1024;

/// The deepest directory nesting accepted. Matches kitty's
/// MAX_DRAG_DIR_DEPTH.
pub const max_depth = 128;

/// A protocol error, sent to the client before the drag is canceled.
pub const Failure = struct {
    errno: Errno,
    desc: []const u8,
};

/// What arrived for one file, for the embedder to write out. Owned by
/// the remote drag until delivered.
pub const Out = struct {
    entry: u32,
    path: []u8,
    kind: dnd.FileKind,
    bytes: []u8,
    status: dnd.DragEvent.Data.Status,
};

pub const RemoteDrag = struct {
    alloc: Allocator,

    /// The pre-sent text/uri-list, kept for the drop target once the
    /// files arrived: the embedder rewrites it to name its copies.
    list: []u8,

    /// The index of the text/uri-list among the offered MIME types.
    uri_item: usize,

    /// The files the list names, in its order.
    entries: []Entry,

    /// True once the files were asked for.
    requested: bool = false,

    /// True once every file arrived.
    complete: bool = false,

    /// Decoded bytes received for all files.
    total: u64 = 0,

    /// What arrived since the embedder last heard.
    out: std.ArrayListUnmanaged(Out) = .empty,

    const Entry = struct {
        /// The 1-based index in the list, which the client knows it by.
        uri_index: u32,

        /// Where it is written, relative to the embedder's directory:
        /// "<0-based uri index>/<name>", as kitty lays out its spool.
        path: []u8,

        nodes: std.ArrayListUnmanaged(*Node) = .empty,

        /// Files and directories expected but not yet complete.
        pending: usize = 1,
    };

    const Node = struct {
        kind: dnd.FileKind,

        /// A directory's handle, by which its children name it.
        handle: i32,

        /// For a child, its parent's handle and its 1-based index in the
        /// parent's listing.
        parent: i32,
        index: i32,

        path: []u8,
        depth: u16,
        decoder: simd.base64.Streaming = .{},

        /// A directory's listing or a symbolic link's target.
        buf: std.ArrayListUnmanaged(u8) = .empty,

        /// A directory's entries' names, once listed.
        names: [][]u8 = &.{},

        complete: bool = false,

        fn deinit(self: *Node, alloc: Allocator) void {
            alloc.free(self.path);
            self.buf.deinit(alloc);
            for (self.names) |name| alloc.free(name);
            alloc.free(self.names);
            alloc.destroy(self);
        }
    };

    /// Start a remote drag for the pre-sent text/uri-list `list`, at
    /// index `uri_item` among the offered MIME types. Fails when a file
    /// URI has no usable name.
    pub fn init(
        alloc: Allocator,
        list: []const u8,
        uri_item: usize,
    ) (Allocator.Error || error{Invalid})!RemoteDrag {
        var entries: std.ArrayListUnmanaged(Entry) = .empty;
        errdefer {
            for (entries.items) |*e| alloc.free(e.path);
            entries.deinit(alloc);
        }

        var index: u32 = 0;
        var it: dnd_uri.UriList = .init(list);
        while (it.next()) |uri| {
            index += 1;
            const name = try fileName(alloc, uri) orelse continue;
            defer alloc.free(name);
            const path = try std.fmt.allocPrint(alloc, "{d}/{s}", .{ index - 1, name });
            errdefer alloc.free(path);
            try entries.append(alloc, .{ .uri_index = index, .path = path });
        }

        const owned = try alloc.dupe(u8, list);
        errdefer alloc.free(owned);
        return .{
            .alloc = alloc,
            .list = owned,
            .uri_item = uri_item,
            .entries = try entries.toOwnedSlice(alloc),
        };
    }

    pub fn deinit(self: *RemoteDrag) void {
        const alloc = self.alloc;
        for (self.entries) |*entry| {
            for (entry.nodes.items) |node| node.deinit(alloc);
            entry.nodes.deinit(alloc);
            alloc.free(entry.path);
        }
        alloc.free(self.entries);
        self.clearOut();
        self.out.deinit(alloc);
        alloc.free(self.list);
    }

    /// Free what was delivered to the embedder.
    pub fn clearOut(self: *RemoteDrag) void {
        for (self.out.items) |o| {
            self.alloc.free(o.path);
            self.alloc.free(o.bytes);
        }
        self.out.clearRetainingCapacity();
    }

    /// Ask the client for every file the list names.
    pub fn request(
        self: *RemoteDrag,
        writer: *std.Io.Writer,
        client_id: u32,
    ) std.Io.Writer.Error!void {
        if (self.requested) return;
        self.requested = true;
        for (self.entries) |entry| {
            var buf: [32]u8 = undefined;
            const header = std.fmt.bufPrint(&buf, "t=k:x={d}", .{entry.uri_index}) catch unreachable;
            try response.encode(writer, header, client_id, "", .plain, .st);
        }
    }

    /// Handle one t=k chunk from the client. Returns the failure to
    /// report, which ends the drag.
    pub fn data(
        self: *RemoteDrag,
        meta: Metadata,
        payload: []const u8,
    ) Allocator.Error!?Failure {
        if (!self.requested or self.complete) return .{
            .errno = .EINVAL,
            .desc = "unexpected remote drag data",
        };
        if (payload.len > max_chunk_bytes) return .{
            .errno = .EINVAL,
            .desc = "remote drag data chunk too large",
        };

        const entry = for (self.entries) |*e| {
            if (e.uri_index == meta.cell_x) break e;
        } else return .{ .errno = .EINVAL, .desc = "unknown remote drag entry" };

        const node = switch (try self.findNode(entry, meta)) {
            .node => |n| n,
            .failure => |f| return f,
        };
        if (node.complete) return .{
            .errno = .EINVAL,
            .desc = "remote drag data after its end",
        };

        // An empty final chunk ends the entry, possibly left unpadded.
        if (!meta.more and payload.len == 0) return try self.finish(entry, node);

        var decoded: std.ArrayListUnmanaged(u8) = .empty;
        defer decoded.deinit(self.alloc);
        try decoded.ensureUnusedCapacity(self.alloc, node.decoder.maxLen(payload));
        const bytes = node.decoder.feed(payload, decoded.unusedCapacitySlice()) catch return .{
            .errno = .EINVAL,
            .desc = "could not base64 decode remote drag data",
        };
        self.total += bytes.len;
        if (self.total > max_total_bytes) return .{
            .errno = .EMFILE,
            .desc = "too much remote drag data",
        };

        switch (node.kind) {
            .file => if (bytes.len > 0) try self.emit(entry, node, bytes, .pending),
            .symlink, .directory => {
                if (node.buf.items.len + bytes.len > max_entry_bytes) return .{
                    .errno = .EMFILE,
                    .desc = "remote drag directory listing or symlink target too large",
                };
                try node.buf.appendSlice(self.alloc, bytes);
            },
        }
        return null;
    }

    const Found = union(enum) { node: *Node, failure: Failure };

    /// The node a chunk is for, created by its first chunk.
    fn findNode(self: *RemoteDrag, entry: *Entry, meta: Metadata) Allocator.Error!Found {
        const parent_handle = meta.pixel_y;
        const index = meta.cell_y;
        for (entry.nodes.items) |node| {
            if (node.parent == parent_handle and (parent_handle == 0 or node.index == index)) {
                return .{ .node = node };
            }
        }

        // X is the kind: absent for a file, 1 for a symlink, otherwise a
        // directory's handle.
        const kind: dnd.FileKind = switch (meta.pixel_x) {
            0 => .file,
            1 => .symlink,
            else => .directory,
        };
        if (kind == .directory) {
            if (meta.pixel_x < 0) return .{ .failure = .{
                .errno = .EINVAL,
                .desc = "invalid remote drag directory handle",
            } };
            for (entry.nodes.items) |node| {
                if (node.kind == .directory and node.handle == meta.pixel_x) return .{ .failure = .{
                    .errno = .EINVAL,
                    .desc = "duplicate remote drag directory handle",
                } };
            }
        }

        var path: []u8 = undefined;
        var depth: u16 = 0;
        if (parent_handle == 0) {
            path = try self.alloc.dupe(u8, entry.path);
        } else {
            const parent = for (entry.nodes.items) |node| {
                if (node.kind == .directory and node.handle == parent_handle) break node;
            } else return .{ .failure = .{
                .errno = .EINVAL,
                .desc = "unknown remote drag parent directory",
            } };
            if (!parent.complete or index < 1 or index > parent.names.len) return .{ .failure = .{
                .errno = .EINVAL,
                .desc = "remote drag child index out of bounds",
            } };
            if (parent.depth + 1 > max_depth) return .{ .failure = .{
                .errno = .ELOOP,
                .desc = "remote drag directories nested too deeply",
            } };
            depth = parent.depth + 1;
            path = try std.fmt.allocPrint(self.alloc, "{s}/{s}", .{
                parent.path,
                parent.names[@intCast(index - 1)],
            });
        }
        errdefer self.alloc.free(path);

        const node = try self.alloc.create(Node);
        errdefer self.alloc.destroy(node);
        node.* = .{
            .kind = kind,
            .handle = if (kind == .directory) meta.pixel_x else 0,
            .parent = parent_handle,
            .index = index,
            .path = path,
            .depth = depth,
        };
        try entry.nodes.append(self.alloc, node);
        return .{ .node = node };
    }

    fn finish(self: *RemoteDrag, entry: *Entry, node: *Node) Allocator.Error!?Failure {
        var tail: [3]u8 = undefined;
        const rest = node.decoder.finishUnpadded(&tail) catch return .{
            .errno = .EINVAL,
            .desc = "could not base64 decode remote drag data",
        };
        node.complete = true;

        switch (node.kind) {
            .file => try self.emit(entry, node, rest, .complete),
            .symlink => {
                try node.buf.appendSlice(self.alloc, rest);
                try self.emit(entry, node, node.buf.items, .complete);
            },
            .directory => {
                try node.buf.appendSlice(self.alloc, rest);
                var names: std.ArrayListUnmanaged([]u8) = .empty;
                errdefer {
                    for (names.items) |name| self.alloc.free(name);
                    names.deinit(self.alloc);
                }
                var it = std.mem.tokenizeScalar(u8, node.buf.items, 0);
                while (it.next()) |name| try names.append(self.alloc, try sanitize(self.alloc, name));
                node.names = try names.toOwnedSlice(self.alloc);
                node.buf.clearAndFree(self.alloc);

                // Every child must be sent.
                entry.pending += node.names.len;
                try self.emit(entry, node, "", .complete);
            },
        }

        entry.pending -= 1;
        self.complete = for (self.entries) |e| {
            if (e.pending != 0) break false;
        } else true;
        return null;
    }

    fn emit(
        self: *RemoteDrag,
        entry: *const Entry,
        node: *const Node,
        bytes: []const u8,
        status: dnd.DragEvent.Data.Status,
    ) Allocator.Error!void {
        try self.out.ensureUnusedCapacity(self.alloc, 1);
        const path = try self.alloc.dupe(u8, node.path);
        errdefer self.alloc.free(path);
        self.out.appendAssumeCapacity(.{
            .entry = entry.uri_index - 1,
            .path = path,
            .kind = node.kind,
            .bytes = try self.alloc.dupe(u8, bytes),
            .status = status,
        });
    }
};

/// The name to write a file URI's file as: the last component of its
/// path (percent-decoded first, as kitty does), sanitized. Null when the
/// URI isn't a file URI (only those are fetched); error.Invalid when it
/// has no name.
fn fileName(alloc: Allocator, uri: []const u8) (Allocator.Error || error{Invalid})!?[]u8 {
    // The host names the client's machine, so any host is accepted.
    const path = dnd_uri.filePath(alloc, uri, .any) catch |err| return switch (err) {
        error.Unsupported => null,
        error.Invalid => error.Invalid,
        error.OutOfMemory => error.OutOfMemory,
    };
    defer alloc.free(path);
    const trimmed = std.mem.trimEnd(u8, path, "/");
    const name = trimmed[(std.mem.lastIndexOfScalar(u8, trimmed, '/') orelse return error.Invalid) + 1 ..];
    if (name.len == 0) return error.Invalid;
    return try sanitize(alloc, name);
}

/// A name that is safe to create inside a directory: "/" and NUL become
/// "_", and "." or ".." become "_", as kitty does.
fn sanitize(alloc: Allocator, name: []const u8) Allocator.Error![]u8 {
    if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) return try alloc.dupe(u8, "_");
    const out = try alloc.dupe(u8, name);
    for (out) |*c| if (c.* == '/' or c.* == 0) {
        c.* = '_';
    };
    return out;
}

test "remote drag file names" {
    const testing = std.testing;
    const alloc = testing.allocator;

    const cases = [_]struct { uri: []const u8, name: ?[]const u8 }{
        .{ .uri = "file:///home/me/a%20b.txt", .name = "a b.txt" },
        .{ .uri = "file://host/dir/", .name = "dir" },
        .{ .uri = "file:///x/a%2Fb", .name = "b" },
        .{ .uri = "file:///x/..", .name = "_" },
        .{ .uri = "https://example.com/a", .name = null },
    };
    for (cases) |case| {
        const name = try fileName(alloc, case.uri);
        defer if (name) |n| alloc.free(n);
        if (case.name) |want| try testing.expectEqualStrings(want, name.?) else try testing.expect(name == null);
    }
    try testing.expectError(error.Invalid, fileName(alloc, "file:///"));
}
