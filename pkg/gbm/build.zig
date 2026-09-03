const std = @import("std");

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const c = b.addTranslateC(.{
        .root_source_file = b.path("gbm.c"),
        .target = target,
        .optimize = optimize,
    });
    c.linkSystemLibrary("gbm", .{});

    const module = b.addModule("gbm", .{ .root_source_file = b.path("main.zig") });
    module.addImport("c", c.createModule());
}
