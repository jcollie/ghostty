const std = @import("std");
const gtk = @import("gtk");

pub const DeviceSize = struct {
    width: u32,
    height: u32,
};

pub fn widgetSurfaceScale(widget: *gtk.Widget) f64 {
    if (widget.getNative()) |native| {
        if (native.getSurface()) |surface| {
            const scale = surface.getScale();
            if (scale > 0) return scale;
        }
    }

    const scale = widget.getScaleFactor();
    if (scale <= 0) return 1.0;
    return @floatFromInt(scale);
}

pub fn widgetDeviceSize(widget: *gtk.Widget) DeviceSize {
    return deviceSize(
        widget.getWidth(),
        widget.getHeight(),
        widgetSurfaceScale(widget),
    );
}

pub fn deviceSize(css_width: c_int, css_height: c_int, scale: f64) DeviceSize {
    return .{
        .width = scaledAxis(css_width, scale),
        .height = scaledAxis(css_height, scale),
    };
}

/// Offset a surface-relative CSS coordinate so it lands on the nearest
/// device pixel without changing the size of the rendered content.
pub fn snapOffset(css_origin: f64, scale: f64) f64 {
    if (!(scale > 0)) return 0;
    const device_origin = css_origin * scale;
    return (@round(device_origin) - device_origin) / scale;
}

fn scaledAxis(css: c_int, scale: f64) u32 {
    if (css <= 0 or !(scale > 0)) return 0;
    return @intFromFloat(@ceil(@as(f64, @floatFromInt(css)) * scale));
}

test "deviceSize integer scale" {
    const testing = std.testing;
    try testing.expectEqual(DeviceSize{ .width = 800, .height = 600 }, deviceSize(800, 600, 1.0));
    try testing.expectEqual(DeviceSize{ .width = 1600, .height = 1200 }, deviceSize(800, 600, 2.0));
}

test "deviceSize fractional scale" {
    const testing = std.testing;
    try testing.expectEqual(DeviceSize{ .width = 1000, .height = 750 }, deviceSize(800, 600, 1.25));
    try testing.expectEqual(DeviceSize{ .width = 1200, .height = 900 }, deviceSize(800, 600, 1.5));
    try testing.expectEqual(DeviceSize{ .width = 127, .height = 127 }, deviceSize(101, 101, 1.25));
}

test "deviceSize rejects non-positive inputs" {
    const testing = std.testing;
    try testing.expectEqual(DeviceSize{ .width = 0, .height = 15 }, deviceSize(0, 10, 1.5));
    try testing.expectEqual(DeviceSize{ .width = 0, .height = 0 }, deviceSize(10, 10, 0));
    try testing.expectEqual(DeviceSize{ .width = 0, .height = 15 }, deviceSize(-1, 10, 1.5));
}

test "snapOffset aligns fractional device origins" {
    const testing = std.testing;
    try testing.expectApproxEqAbs(@as(f64, 0), snapOffset(0, 1.75), 0.000001);
    try testing.expectApproxEqAbs(@as(f64, -1.0 / 7.0), snapOffset(47, 1.75), 0.000001);
    try testing.expectApproxEqAbs(@as(f64, 0.2), snapOffset(47, 1.25), 0.000001);
}
