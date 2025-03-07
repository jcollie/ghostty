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

const log = std.log.scoped(.config);

const Path = union(enum) {
    /// No error if the file does not exist.
    optional: [:0]const u8,

    /// The file is required to exist.
    required: [:0]const u8,
};

value: std.ArrayListUnmanaged(Path) = .{},

pub fn parseCLI(self: *RepeatablePath, alloc: Allocator, input: ?[]const u8) !void {
    const value, const optional = if (input) |value| blk: {
        if (value.len == 0) {
            self.value.clearRetainingCapacity();
            return;
        }

        break :blk if (value[0] == '?')
            .{ value[1..], true }
        else if (value.len >= 2 and value[0] == '"' and value[value.len - 1] == '"')
            .{ value[1 .. value.len - 1], false }
        else
            .{ value, false };
    } else return error.ValueRequired;

    if (value.len == 0) {
        // This handles the case of zero length paths after removing any ?
        // prefixes or surrounding quotes. In this case, we don't reset the
        // list.
        return;
    }

    const item: Path = if (optional)
        .{ .optional = try alloc.dupeZ(u8, value) }
    else
        .{ .required = try alloc.dupeZ(u8, value) };

    try self.value.append(alloc, item);
}

/// Deep copy of the struct. Required by Config.
pub fn clone(self: *const RepeatablePath, alloc: Allocator) Allocator.Error!RepeatablePath {
    const value = try self.value.clone(alloc);
    for (value.items) |*item| {
        switch (item.*) {
            .optional, .required => |*path| path.* = try alloc.dupeZ(u8, path.*),
        }
    }

    return .{
        .value = value,
    };
}

/// Compare if two of our value are equal. Required by Config.
pub fn equal(self: RepeatablePath, other: RepeatablePath) bool {
    if (self.value.items.len != other.value.items.len) return false;
    for (self.value.items, other.value.items) |a, b| {
        if (!std.meta.eql(a, b)) return false;
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
    assert(std.fs.path.isAbsolute(base));
    var dir = try std.fs.cwd().openDir(base, .{});
    defer dir.close();

    for (0..self.value.items.len) |i| {
        const path = switch (self.value.items[i]) {
            .optional, .required => |path| path,
        };

        // If it is already absolute we can ignore it.
        if (path.len == 0 or std.fs.path.isAbsolute(path)) continue;

        // If it isn't absolute, we need to make it absolute relative
        // to the base.
        var buf: [std.fs.max_path_bytes]u8 = undefined;

        // Check if the path starts with a tilde and expand it to the
        // home directory on Linux/macOS. We explicitly look for "~/"
        // because we don't support alternate users such as "~alice/"
        if (std.mem.startsWith(u8, path, "~/")) expand: {
            // Windows isn't supported yet
            if (comptime builtin.os.tag == .windows) break :expand;

            const expanded: []const u8 = internal_os.expandHome(
                path,
                &buf,
            ) catch |err| {
                try diags.append(alloc, .{
                    .message = try std.fmt.allocPrintZ(
                        alloc,
                        "error expanding home directory for path {s}: {}",
                        .{ path, err },
                    ),
                });

                // Blank this path so that we don't attempt to resolve it
                // again
                self.value.items[i] = .{ .required = "" };

                continue;
            };

            log.debug(
                "expanding file path from home directory: path={s}",
                .{expanded},
            );

            switch (self.value.items[i]) {
                .optional, .required => |*p| p.* = try alloc.dupeZ(u8, expanded),
            }

            continue;
        }

        const abs = dir.realpath(path, &buf) catch |err| abs: {
            if (err == error.FileNotFound) {
                // The file doesn't exist. Try to resolve the relative path
                // another way.
                const resolved = try std.fs.path.resolve(alloc, &.{ base, path });
                defer alloc.free(resolved);
                @memcpy(buf[0..resolved.len], resolved);
                break :abs buf[0..resolved.len];
            }

            try diags.append(alloc, .{
                .message = try std.fmt.allocPrintZ(
                    alloc,
                    "error resolving file path {s}: {}",
                    .{ path, err },
                ),
            });

            // Blank this path so that we don't attempt to resolve it again
            self.value.items[i] = .{ .required = "" };

            continue;
        };

        log.debug(
            "expanding file path relative={s} abs={s}",
            .{ path, abs },
        );

        switch (self.value.items[i]) {
            .optional, .required => |*p| p.* = try alloc.dupeZ(u8, abs),
        }
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
