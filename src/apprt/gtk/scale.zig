const std = @import("std");
const gobject = @import("gobject");
const graphene = @import("graphene");
const gtk = @import("gtk");

pub const DeviceSize = struct {
    width: u32,
    height: u32,
};

pub const CssPoint = struct {
    x: f64,
    y: f64,
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

/// Widget (0,0) in GdkSurface CSS coordinates, including CSD transform.
pub fn widgetSurfaceOrigin(widget: *gtk.Widget) CssPoint {
    const native = widget.getNative() orelse return .{ .x = 0, .y = 0 };
    const native_widget = gobject.ext.cast(gtk.Widget, native) orelse return .{ .x = 0, .y = 0 };

    var native_origin: graphene.Point = undefined;
    if (widget.computePoint(
        native_widget,
        &.{ .f_x = 0, .f_y = 0 },
        &native_origin,
    ) == 0) return .{ .x = 0, .y = 0 };

    var tx: f64 = 0;
    var ty: f64 = 0;
    native.getSurfaceTransform(&tx, &ty);

    return .{
        .x = @as(f64, native_origin.f_x) + tx,
        .y = @as(f64, native_origin.f_y) + ty,
    };
}

pub fn widgetDeviceSize(widget: *gtk.Widget) DeviceSize {
    const origin = widgetSurfaceOrigin(widget);
    return snappedDeviceSize(
        origin.x,
        origin.y,
        widget.getWidth(),
        widget.getHeight(),
        widgetSurfaceScale(widget),
    );
}

pub fn deviceSize(css_width: c_int, css_height: c_int, scale: f64) DeviceSize {
    return snappedDeviceSize(0, 0, css_width, css_height, scale);
}

pub fn snappedDeviceSize(
    origin_x: f64,
    origin_y: f64,
    css_width: c_int,
    css_height: c_int,
    scale: f64,
) DeviceSize {
    return .{
        .width = snappedAxis(origin_x, css_width, scale),
        .height = snappedAxis(origin_y, css_height, scale),
    };
}

/// Offset a surface-relative CSS coordinate so it lands on the nearest
/// device pixel without changing the size of the rendered content.
pub fn snapOffset(css_origin: f64, scale: f64) f64 {
    if (!(scale > 0)) return 0;
    const device_origin = css_origin * scale;
    return (@round(device_origin) - device_origin) / scale;
}

fn snappedAxis(css_origin: f64, css: c_int, scale: f64) u32 {
    if (css <= 0 or !(scale > 0)) return 0;
    const css_size: f64 = @floatFromInt(css);
    const start = @round(css_origin * scale);
    const end = @round((css_origin + css_size) * scale);
    if (end <= start) return 0;
    return @intFromFloat(end - start);
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
    try testing.expectEqual(DeviceSize{ .width = 126, .height = 126 }, deviceSize(101, 101, 1.25));
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
    try testing.expectApproxEqAbs(@as(f64, 0.25), snapOffset(47, 4.0 / 3.0), 0.000001);
}

test "snappedDeviceSize uses origin-aware device spans" {
    const testing = std.testing;
    const scale_4_3 = 4.0 / 3.0;
    try testing.expectEqual(
        DeviceSize{ .width = 1066, .height = 1066 },
        snappedDeviceSize(47, 47, 800, 800, scale_4_3),
    );
    try testing.expectEqual(
        DeviceSize{ .width = 1097, .height = 628 },
        snappedDeviceSize(0, 0, 823, 471, scale_4_3),
    );
    try testing.expectEqual(
        DeviceSize{ .width = 126, .height = 126 },
        snappedDeviceSize(0, 0, 101, 101, 1.25),
    );
}
