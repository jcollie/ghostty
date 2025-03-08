const std = @import("std");
const builtin = @import("builtin");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;

const cli = @import("../cli.zig");
const internal_os = @import("../os/main.zig");

const log = std.log.scoped(.config);

pub const ParseError = error{ValueRequired} || Allocator.Error;

pub const Path = union(enum) {
    /// No error if the file does not exist.
    optional: [:0]const u8,

    /// The file is required to exist.
    required: [:0]const u8,

    pub fn len(self: Path) usize {
        return switch (self) {
            inline else => |path| path.len,
        };
    }

    pub fn equal(self: Path, other: Path) bool {
        return std.meta.eql(self, other);
    }

    /// Parse the input and return a Path. A leading `?` indicates that the path
    /// is _optional_ and an error should not be logged or displayed to the user
    /// if that path does not exist. Otherwise the path is required and an error
    /// should be logged if the path does not exist.
    pub fn parse(
        /// Allocator to use. This must be an arena allocator because we assume
        /// that any allocations will be cleaned up when the arena.
        arena_alloc: Allocator,
        /// The input.
        input: ?[]const u8,
    ) ParseError!?Path {
        const value = input orelse return error.ValueRequired;

        if (value.len == 0) return null;

        if (value[0] == '?') {
            return .{ .optional = try arena_alloc.dupeZ(u8, value[1..]) };
        }

        if (value.len >= 2 and value[0] == '"' and value[value.len - 1] == '"') {
            return .{ .required = try arena_alloc.dupeZ(u8, value[1 .. value.len - 1]) };
        }

        return .{ .required = try arena_alloc.dupeZ(u8, value) };
    }

    /// Return a clone of the path.
    pub fn clone(
        /// The path to clone.
        self: Path,
        /// This must be an arena allocator because we rely on the arena to
        /// clean up our allocations.
        arena_alloc: Allocator,
    ) Allocator.Error!Path {
        return switch (self) {
            .optional => |path| .{
                .optional = try arena_alloc.dupeZ(u8, path),
            },
            .required => |path| .{
                .required = try arena_alloc.dupeZ(u8, path),
            },
        };
    }

    /// Expand relative paths or paths prefixed with `~/`. The path will be
    /// overwritten.
    pub fn expand(
        /// The path to expand.
        self: *Path,
        /// This must be an arena allocator because we rely on the arena to
        /// clean up our allocations.
        arena_alloc: Allocator,
        /// The base directory to expand relative paths. It must be an absolute
        /// path.
        base: []const u8,
        /// Errors will be added to the list of diagnostics if they occur.
        diags: *cli.DiagnosticList,
    ) !void {
        assert(std.fs.path.isAbsolute(base));

        const path = switch (self.*) {
            .optional, .required => |path| path,
        };

        // If it is already absolute we can ignore it.
        if (path.len == 0 or std.fs.path.isAbsolute(path)) return;

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
                try diags.append(arena_alloc, .{
                    .message = try std.fmt.allocPrintZ(
                        arena_alloc,
                        "error expanding home directory for path {s}: {}",
                        .{ path, err },
                    ),
                });

                // Blank this path so that we don't attempt to resolve it
                // again
                self.* = .{ .required = "" };

                return;
            };

            log.debug(
                "expanding file path from home directory: path={s}",
                .{expanded},
            );

            switch (self.*) {
                .optional, .required => |*p| p.* = try arena_alloc.dupeZ(u8, expanded),
            }

            return;
        }

        var dir = try std.fs.openDirAbsolute(base, .{});
        defer dir.close();

        const abs = dir.realpath(path, &buf) catch |err| abs: {
            if (err == error.FileNotFound) {
                // The file doesn't exist. Try to resolve the relative path
                // another way.
                const resolved = try std.fs.path.resolve(arena_alloc, &.{ base, path });
                defer arena_alloc.free(resolved);
                @memcpy(buf[0..resolved.len], resolved);
                break :abs buf[0..resolved.len];
            }

            try diags.append(arena_alloc, .{
                .message = try std.fmt.allocPrintZ(
                    arena_alloc,
                    "error resolving file path {s}: {}",
                    .{ path, err },
                ),
            });

            // Blank this path so that we don't attempt to resolve it again
            self.* = .{ .required = "" };

            return;
        };

        log.debug(
            "expanding file path relative={s} abs={s}",
            .{ path, abs },
        );

        switch (self.*) {
            .optional, .required => |*p| p.* = try arena_alloc.dupeZ(u8, abs),
        }
    }
};
