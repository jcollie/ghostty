//! NonRepeatablePath is like a string that represents a path value. The
//! difference is that when loading the configuration the value for this will
//! be automatically expanded relative to the path of the config file (or the home
//! directory).
const NonRepeatablePath = @This();

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

value: ?Path = null,

pub const ParseError = error{ValueRequired} || Allocator.Error;

pub fn parseCLI(self: *NonRepeatablePath, alloc: Allocator, input: ?[]const u8) ParseError!void {
    const item = try Path.parse(alloc, input) orelse {
        self.value = null;
        return;
    };

    if (item.len() == 0) {
        // This handles the case of zero length paths after removing any ?
        // prefixes or surrounding quotes. In this case, we don't reset the
        // list.
        return;
    }

    self.value = item;
}

/// Deep copy of the struct. Required by Config.
pub fn clone(self: *const NonRepeatablePath, alloc: Allocator) Allocator.Error!NonRepeatablePath {
    if (self.value) |value| {
        return .{
            .value = try value.clone(alloc),
        };
    }
    return .{
        .value = null,
    };
}

/// Compare if two of our value are requal. Required by Config.
pub fn equal(self: NonRepeatablePath, other: NonRepeatablePath) bool {
    if (self.value == null and other.value == null) return true;
    const a = self.value orelse return false;
    const b = other.value orelse return false;
    return a.equal(b);
}

/// Used by Formatter
pub fn formatEntry(self: *const NonRepeatablePath, formatter: anytype) !void {
    const item = self.value orelse {
        try formatter.formatEntry(void, {});
        return;
    };

    var buf: [std.fs.max_path_bytes + 1]u8 = undefined;
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

/// Expand all the paths relative to the base directory.
pub fn expand(
    self: *NonRepeatablePath,
    alloc: Allocator,
    base: []const u8,
    diags: *cli.DiagnosticList,
) !void {
    if (self.value) |*path| {
        try path.expand(alloc, base, diags);
    }
}

test "parseCLI" {
    const testing = std.testing;
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const Tag = std.meta.Tag(Path);
    var item: NonRepeatablePath = .{};

    try item.parseCLI(alloc, "config.1");
    try testing.expectEqual(Tag.required, @as(Tag, item.value.?));
    try testing.expectEqualStrings("config.1", item.value.?.required);

    try item.parseCLI(alloc, "?config.2");
    try testing.expectEqual(Tag.optional, @as(Tag, item.value.?));
    try testing.expectEqualStrings("config.2", item.value.?.optional);

    try item.parseCLI(alloc, "\"?config.3\"");
    try testing.expectEqual(Tag.required, @as(Tag, item.value.?));
    try testing.expectEqualStrings("?config.3", item.value.?.required);

    // Zero-length values, ignored
    try item.parseCLI(alloc, "?");
    try item.parseCLI(alloc, "\"\"");

    try item.parseCLI(alloc, "");
    try testing.expectEqual(null, item.value);
}

test "formatConfig empty" {
    const testing = std.testing;
    var buf = std.ArrayList(u8).init(testing.allocator);
    defer buf.deinit();

    var list: NonRepeatablePath = .{};
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

    var list: NonRepeatablePath = .{};
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

    var list: NonRepeatablePath = .{};
    try list.parseCLI(alloc, "A");
    try list.parseCLI(alloc, "?B");
    try list.formatEntry(formatterpkg.entryFormatter("a", buf.writer()));
    try std.testing.expectEqualSlices(u8, "a = ?B\n", buf.items);
}

test "formatConfig reset" {
    const testing = std.testing;
    var buf = std.ArrayList(u8).init(testing.allocator);
    defer buf.deinit();

    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var list: NonRepeatablePath = .{};
    try list.parseCLI(alloc, "A");
    try list.parseCLI(alloc, "");
    try list.formatEntry(formatterpkg.entryFormatter("a", buf.writer()));
    try std.testing.expectEqualSlices(u8, "a = \n", buf.items);
}
