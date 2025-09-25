/// RepeatableColorMap is a key/value that can be repeated to accumulate a
/// string map. This isn't called "StringMap" because I find that sometimes
/// leads to confusion that it _accepts_ a map such as JSON dict.
const RepeatableColorMap = @This();
const std = @import("std");
const Allocator = std.mem.Allocator;

const formatterpkg = @import("formatter.zig");
const Color = @import("Color.zig");

pub const Map = std.ArrayHashMapUnmanaged(
    [:0]const u8,
    Color,
    std.array_hash_map.StringContext,
    true,
);

// Allocator for the list is the arena for the parent config.
map: Map = .empty,

pub const empty: RepeatableColorMap = .{ .map = .empty };

pub fn parseCLI(
    self: *RepeatableColorMap,
    alloc: Allocator,
    input: ?[]const u8,
) !void {
    const value = input orelse return error.ValueRequired;

    // Empty value resets the list. We don't need to free our values because
    // the allocator used is always an arena.
    if (value.len == 0) {
        self.map.clearRetainingCapacity();
        return;
    }

    const index = std.mem.indexOfScalar(
        u8,
        value,
        '=',
    ) orelse return error.ValueRequired;

    const key = std.mem.trim(u8, value[0..index], &std.ascii.whitespace);
    const val = std.mem.trim(u8, value[index + 1 ..], &std.ascii.whitespace);

    const key_copy = try alloc.dupeZ(u8, key);
    errdefer alloc.free(key_copy);

    // Empty value removes the key from the map.
    if (val.len == 0) {
        _ = self.map.orderedRemove(key_copy);
        alloc.free(key_copy);
        return;
    }

    try self.map.put(alloc, key_copy, try Color.parseCLI(val));
}

/// Deep copy of the struct. Required by Config.
pub fn clone(
    self: *const RepeatableColorMap,
    alloc: Allocator,
) Allocator.Error!RepeatableColorMap {
    var map: Map = .{};
    try map.ensureTotalCapacity(alloc, self.map.count());

    errdefer {
        var it = map.iterator();
        while (it.next()) |entry| {
            alloc.free(entry.key_ptr.*);
        }
        map.deinit(alloc);
    }

    var it = self.map.iterator();
    while (it.next()) |entry| {
        const key = try alloc.dupeZ(u8, entry.key_ptr.*);
        map.putAssumeCapacity(key, entry.value_ptr.*);
    }

    return .{ .map = map };
}

/// The number of items in the map
pub fn count(self: RepeatableColorMap) usize {
    return self.map.count();
}

/// Iterator over the entries in the map.
pub fn iterator(self: RepeatableColorMap) Map.Iterator {
    return self.map.iterator();
}

/// Compare if two of our value are requal. Required by Config.
pub fn equal(self: RepeatableColorMap, other: RepeatableColorMap) bool {
    if (self.map.count() != other.map.count()) return false;
    var it = self.map.iterator();
    while (it.next()) |entry| {
        const value = other.map.get(entry.key_ptr.*) orelse return false;
        if (!entry.value_ptr.equal(value)) return false;
    } else return true;
}

/// Used by formatter
pub fn formatEntry(self: RepeatableColorMap, formatter: formatterpkg.EntryFormatter) !void {
    // If no items, we want to render an empty field.
    if (self.map.count() == 0) {
        try formatter.formatEntry(void, {});
        return;
    }

    var it = self.map.iterator();
    while (it.next()) |entry| {
        var buf: [256]u8 = undefined;
        var writer: std.Io.Writer = .fixed(&buf);
        try writer.print("{s}={f}", .{ entry.key_ptr.*, entry.value_ptr });
        try formatter.formatEntry([]const u8, writer.buffered());
    }
}

test "RepeatableColorMap: parseCLI" {
    const testing = std.testing;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var map: RepeatableColorMap = .{};

    try testing.expectError(error.ValueRequired, map.parseCLI(alloc, "A"));

    try map.parseCLI(alloc, "A=#bbccdd");
    try map.parseCLI(alloc, "B=#ccddee");
    try testing.expectEqual(@as(usize, 2), map.count());

    try map.parseCLI(alloc, "");
    try testing.expectEqual(@as(usize, 0), map.count());

    try map.parseCLI(alloc, "A=#bbccdd");
    try testing.expectEqual(@as(usize, 1), map.count());
    try map.parseCLI(alloc, "A=#ccddee");
    try testing.expectEqual(@as(usize, 1), map.count());
}

test "RepeatableColorMap: formatConfig empty" {
    const testing = std.testing;
    var buf: std.Io.Writer.Allocating = .init(testing.allocator);
    defer buf.deinit();

    var list: RepeatableColorMap = .{};
    try list.formatEntry(formatterpkg.entryFormatter("a", &buf.writer));
    try std.testing.expectEqualSlices(u8, "a = \n", buf.written());
}

test "RepeatableColorMap: formatConfig single item" {
    const testing = std.testing;

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    {
        var buf: std.Io.Writer.Allocating = .init(testing.allocator);
        defer buf.deinit();
        var map: RepeatableColorMap = .{};
        try map.parseCLI(alloc, "A=red");
        try map.formatEntry(formatterpkg.entryFormatter("a", &buf.writer));
        try std.testing.expectEqualSlices(u8, "a = A=#ff0000\n", buf.written());
    }
    {
        var buf: std.Io.Writer.Allocating = .init(testing.allocator);
        defer buf.deinit();
        var map: RepeatableColorMap = .{};
        try map.parseCLI(alloc, " A = red ");
        try map.formatEntry(formatterpkg.entryFormatter("a", &buf.writer));
        try std.testing.expectEqualSlices(u8, "a = A=#ff0000\n", buf.written());
    }
}

test "RepeatableColorMap: formatConfig multiple items" {
    const testing = std.testing;

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    {
        var buf: std.Io.Writer.Allocating = .init(testing.allocator);
        defer buf.deinit();
        var list: RepeatableColorMap = .{};
        try list.parseCLI(alloc, "A=#aabbcc");
        try list.parseCLI(alloc, "B = #001122");
        try list.formatEntry(formatterpkg.entryFormatter("a", &buf.writer));
        try std.testing.expectEqualSlices(u8, "a = A=#aabbcc\na = B=#001122\n", buf.written());
    }
}
