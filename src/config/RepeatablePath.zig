//! RepeatablePath is like repeatable string but represents a path value. The
//! difference is that when loading the configuration any values for this will
//! be automatically expanded relative to the path of the config file (or the home
//! directory).
const RepeatablePath = @This();

const std = @import("std");
const builtin = @import("builtin");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;

const cli = @import("../cli.zig");
const internal_os = @import("../os/main.zig");
const formatterpkg = @import("formatter.zig");
const Path = @import("path.zig").Path;

const log = std.log.scoped(.config);

value: std.ArrayListUnmanaged(Path) = .{},

pub fn parseCLI(self: *RepeatablePath, alloc: Allocator, input: ?[]const u8) (error{ValueRequired} || Allocator.Error)!void {
    const item = try Path.parse(alloc, input) orelse {
        self.value.clearRetainingCapacity();
        return;
    };

    if (item.len() == 0) {
        // This handles the case of zero length paths after removing any ?
        // prefixes or surrounding quotes. In this case, we don't reset the
        // list.
        return;
    }

    try self.value.append(alloc, item);
}

/// Deep copy of the struct. Required by Config.
pub fn clone(self: *const RepeatablePath, alloc: Allocator) Allocator.Error!RepeatablePath {
    const value = try self.value.clone(alloc);
    for (value.items) |*item| {
        item.* = try item.clone(alloc);
    }

    return .{
        .value = value,
    };
}

/// Compare if two of our value are equal. Required by Config.
pub fn equal(self: RepeatablePath, other: RepeatablePath) bool {
    if (self.value.items.len != other.value.items.len) return false;
    for (self.value.items, other.value.items) |a, b| {
        if (!a.equal(b)) return false;
    }

    return true;
}

/// Used by Formatter
pub fn formatEntry(self: RepeatablePath, formatter: anytype) !void {
    if (self.value.items.len == 0) {
        try formatter.formatEntry(void, {});
        return;
    }

    var buf: [std.fs.max_path_bytes + 1]u8 = undefined;
    for (self.value.items) |item| {
        const value = switch (item) {
            .optional => |path| std.fmt.bufPrint(
                &buf,
                "?{s}",
                .{path},
            ) catch |err| switch (err) {
                // Required for builds on Linux where NoSpaceLeft
                // isn't an allowed error for fmt.
                error.NoSpaceLeft => return error.OutOfMemory,
            },
            .required => |path| path,
        };

        try formatter.formatEntry([]const u8, value);
    }
}

/// Expand all the paths relative to the base directory.
pub fn expand(
    self: *RepeatablePath,
    alloc: Allocator,
    base: []const u8,
    diags: *cli.DiagnosticList,
) !void {
    for (self.value.items) |*path| {
        try path.expand(alloc, base, diags);
    }
}

test "parseCLI" {
    const testing = std.testing;
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var list: RepeatablePath = .{};
    try list.parseCLI(alloc, "config.1");
    try list.parseCLI(alloc, "?config.2");
    try list.parseCLI(alloc, "\"?config.3\"");

    // Zero-length values, ignored
    try list.parseCLI(alloc, "?");
    try list.parseCLI(alloc, "\"\"");

    try testing.expectEqual(@as(usize, 3), list.value.items.len);

    const Tag = std.meta.Tag(Path);
    try testing.expectEqual(Tag.required, @as(Tag, list.value.items[0]));
    try testing.expectEqualStrings("config.1", list.value.items[0].required);

    try testing.expectEqual(Tag.optional, @as(Tag, list.value.items[1]));
    try testing.expectEqualStrings("config.2", list.value.items[1].optional);

    try testing.expectEqual(Tag.required, @as(Tag, list.value.items[2]));
    try testing.expectEqualStrings("?config.3", list.value.items[2].required);

    try list.parseCLI(alloc, "");
    try testing.expectEqual(@as(usize, 0), list.value.items.len);
}

test "formatConfig empty" {
    const testing = std.testing;
    var buf = std.ArrayList(u8).init(testing.allocator);
    defer buf.deinit();

    var list: RepeatablePath = .{};
    try list.formatEntry(formatterpkg.entryFormatter("a", buf.writer()));
    try std.testing.expectEqualSlices(u8, "a = \n", buf.items);
}

test "formatConfig single item" {
    const testing = std.testing;
    var buf = std.ArrayList(u8).init(testing.allocator);
    defer buf.deinit();

    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var list: RepeatablePath = .{};
    try list.parseCLI(alloc, "A");
    try list.formatEntry(formatterpkg.entryFormatter("a", buf.writer()));
    try std.testing.expectEqualSlices(u8, "a = A\n", buf.items);
}

test "formatConfig multiple items" {
    const testing = std.testing;
    var buf = std.ArrayList(u8).init(testing.allocator);
    defer buf.deinit();

    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var list: RepeatablePath = .{};
    try list.parseCLI(alloc, "A");
    try list.parseCLI(alloc, "?B");
    try list.formatEntry(formatterpkg.entryFormatter("a", buf.writer()));
    try std.testing.expectEqualSlices(u8, "a = A\na = ?B\n", buf.items);
}
