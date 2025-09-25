//! Color represents a color using RGB.
const Color = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;

const terminal = @import("../terminal/main.zig");
const formatterpkg = @import("./formatter.zig");

r: u8,
g: u8,
b: u8,

/// ghostty_config_color_s
pub const C = extern struct {
    r: u8,
    g: u8,
    b: u8,
};

pub fn cval(self: Color) Color.C {
    return .{ .r = self.r, .g = self.g, .b = self.b };
}

/// Convert this to the terminal RGB struct
pub fn toTerminalRGB(self: Color) terminal.color.RGB {
    return .{ .r = self.r, .g = self.g, .b = self.b };
}

pub fn parseCLI(input_: ?[]const u8) !Color {
    const input = input_ orelse return error.ValueRequired;
    const rgb: terminal.color.RGB = terminal.color.RGB.parse(input) catch return error.InvalidValue;
    return .{ .r = rgb.r, .g = rgb.g, .b = rgb.b };
}

/// Deep copy of the struct. Required by Config.
pub fn clone(self: Color, _: Allocator) error{}!Color {
    return self;
}

/// Compare if two of our value are requal. Required by Config.
pub fn equal(self: Color, other: Color) bool {
    return std.meta.eql(self, other);
}

/// Used by Formatter
pub fn formatEntry(self: Color, formatter: formatterpkg.EntryFormatter) !void {
    var buf: [128]u8 = undefined;
    try formatter.formatEntry(
        []const u8,
        try self.formatBuf(&buf),
    );
}

/// Format the color as a string.
pub fn formatBuf(self: Color, buf: []u8) Allocator.Error![]const u8 {
    var writer: std.Io.Writer = .fixed(buf);
    writer.print(
        "{f}",
        .{self},
    ) catch return error.OutOfMemory;
    return writer.buffered();
}

pub fn int(self: Color) u24 {
    return std.math.shl(u24, self.r, 16) | std.math.shl(u24, self.g, 8) | self.b;
}

/// Writergate format
pub fn format(self: Color, writer: *std.Io.Writer) std.Io.Writer.Error!void {
    try writer.print(
        "#{x:0>2}{x:0>2}{x:0>2}",
        .{ self.r, self.g, self.b },
    );
}

const Short = struct {
    color: Color,

    pub fn format(self: Short, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        try writer.print(
            "{x:0>2}{x:0>2}{x:0>2}",
            .{ self.color.r, self.color.g, self.color.b },
        );
    }
};

pub fn short(self: Color) std.fmt.Alt(Short, Short.format) {
    return .{ .data = .{ .color = self } };
}

const RGBA = struct {
    color: Color,
    opacity: f32,

    pub fn format(self: RGBA, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        try writer.print(
            "rgba({d}, {d}, {d}, {d:.1})",
            .{ self.color.r, self.color.g, self.color.b, self.opacity },
        );
    }
};

pub fn rgba(self: Color, opacity: f32) std.fmt.Alt(RGBA, RGBA.format) {
    return .{ .data = .{ .color = self, .opacity = opacity } };
}

test "parseCLI hex" {
    const testing = std.testing;

    try testing.expectEqual(Color{ .r = 0, .g = 0, .b = 0 }, try Color.parseCLI("#000000"));
    try testing.expectEqual(Color{ .r = 10, .g = 11, .b = 12 }, try Color.parseCLI("#0A0B0C"));
    try testing.expectEqual(Color{ .r = 10, .g = 11, .b = 12 }, try Color.parseCLI("0A0B0C"));
    try testing.expectEqual(Color{ .r = 255, .g = 255, .b = 255 }, try Color.parseCLI("FFFFFF"));
    try testing.expectEqual(Color{ .r = 255, .g = 255, .b = 255 }, try Color.parseCLI("FFF"));
    try testing.expectEqual(Color{ .r = 51, .g = 68, .b = 85 }, try Color.parseCLI("#345"));
}

test "parseCLI from name" {
    try std.testing.expectEqual(Color{ .r = 0, .g = 0, .b = 0 }, try Color.parseCLI("black"));
}

test "formatConfig" {
    const testing = std.testing;
    var buf: std.Io.Writer.Allocating = .init(testing.allocator);
    defer buf.deinit();

    var color: Color = .{ .r = 10, .g = 11, .b = 12 };
    try color.formatEntry(formatterpkg.entryFormatter("a", &buf.writer));
    try std.testing.expectEqualSlices(u8, "a = #0a0b0c\n", buf.written());
}

test "parseCLI with whitespace" {
    const testing = std.testing;
    try testing.expectEqual(
        Color{ .r = 0xAA, .g = 0xBB, .b = 0xCC },
        try Color.parseCLI(" #AABBCC   "),
    );
    try testing.expectEqual(
        Color{ .r = 0, .g = 0, .b = 0 },
        try Color.parseCLI("  black "),
    );
}
