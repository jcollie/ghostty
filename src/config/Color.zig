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
    // Trim any whitespace before processing
    const trimmed = std.mem.trim(u8, input, " \t");

    if (terminal.x11_color.map.get(trimmed)) |rgb| return .{
        .r = rgb.r,
        .g = rgb.g,
        .b = rgb.b,
    };

    return fromHex(trimmed);
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

/// fromHex parses a color from a hex value such as #RRGGBB. The "#"
/// is optional.
pub fn fromHex(input: []const u8) !Color {
    // Trim the beginning '#' if it exists
    const trimmed = if (input.len != 0 and input[0] == '#') input[1..] else input;
    if (trimmed.len != 6 and trimmed.len != 3) return error.InvalidValue;

    // Expand short hex values to full hex values
    const rgb: []const u8 = if (trimmed.len == 3) &.{
        trimmed[0], trimmed[0],
        trimmed[1], trimmed[1],
        trimmed[2], trimmed[2],
    } else trimmed;

    // Parse the colors two at a time.
    var result: Color = undefined;
    comptime var i: usize = 0;
    inline while (i < 6) : (i += 2) {
        const v: u8 =
            ((try std.fmt.charToDigit(rgb[i], 16)) * 16) +
            try std.fmt.charToDigit(rgb[i + 1], 16);

        @field(result, switch (i) {
            0 => "r",
            2 => "g",
            4 => "b",
            else => unreachable,
        }) = v;
    }

    return result;
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

test "fromHex" {
    const testing = std.testing;

    try testing.expectEqual(Color{ .r = 0, .g = 0, .b = 0 }, try Color.fromHex("#000000"));
    try testing.expectEqual(Color{ .r = 10, .g = 11, .b = 12 }, try Color.fromHex("#0A0B0C"));
    try testing.expectEqual(Color{ .r = 10, .g = 11, .b = 12 }, try Color.fromHex("0A0B0C"));
    try testing.expectEqual(Color{ .r = 255, .g = 255, .b = 255 }, try Color.fromHex("FFFFFF"));
    try testing.expectEqual(Color{ .r = 255, .g = 255, .b = 255 }, try Color.fromHex("FFF"));
    try testing.expectEqual(Color{ .r = 51, .g = 68, .b = 85 }, try Color.fromHex("#345"));
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
