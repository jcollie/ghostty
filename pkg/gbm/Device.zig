//! A GBM device, created over an open DRM device node.
const Device = @This();

const std = @import("std");
const c = @import("c");

const BufferObject = @import("BufferObject.zig");

pub const InitError = error{
    GbmInitFailed,
} || std.Io.File.OpenError;

file: std.Io.File,
device: *c.struct_gbm_device,

/// Initializes a GBM device over the DRM device node at `path`
/// (e.g. `/dev/dri/card0`).
pub fn init(io: std.Io, path: []const u8) InitError!Device {
    const file = try std.Io.Dir.openFileAbsolute(
        io,
        path,
        .{ .mode = .read_write },
    );
    errdefer file.close(io);

    const device = c.gbm_create_device(file.handle) orelse
        return error.GbmInitFailed;

    return .{ .file = file, .device = device };
}

/// Destroys the GBM device and closes the underlying DRM device node
/// file descriptor.
///
/// All buffer objects created from this device must be destroyed
/// first.
pub fn deinit(self: *Device, io: std.Io) void {
    _ = c.gbm_device_destroy(self.device);
    self.file.close(io);
}

/// Returns whether the device supports allocating buffers with the
/// given format and usage.
pub fn isFormatSupported(
    self: *const Device,
    format: BufferObject.Format,
    usage: BufferObject.Usage,
) bool {
    return c.gbm_device_is_format_supported(
        self.device,
        @intFromEnum(format),
        usage.toInt(),
    ) != 0;
}

/// Allocates a new buffer object from this device.
pub fn createBufferObject(
    self: *const Device,
    opts: BufferObject.Options,
) BufferObject.Error!BufferObject {
    return .init(self, opts);
}
