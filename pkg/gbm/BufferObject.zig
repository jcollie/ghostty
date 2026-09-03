//! A GBM buffer object: a GPU-accessible allocation that can be
//! exported as a DMA-BUF.
const BufferObject = @This();

const std = @import("std");
const c = @import("c");

const Device = @import("Device.zig");

fn fourccCode(code: *const [4]u8) u32 {
    return std.mem.readInt(u32, code, .little);
}

pub const Format = enum(u32) {
    // 32-bit RGBA formats
    argb8888 = fourccCode("AR24"),
    abgr8888 = fourccCode("AB24"),
    rgba8888 = fourccCode("RA24"),
    bgra8888 = fourccCode("BG24"),

    // 32-bit RGBX formats
    xrgb8888 = fourccCode("XR24"),
    xbgr8888 = fourccCode("XB24"),
    rgbx8888 = fourccCode("RX24"),
    bgrx8888 = fourccCode("BX24"),

    // There are many others, no need to list them all here
    _,
};

/// Buffer allocation usage flags, mirrors `enum gbm_bo_flags`.
pub const Usage = packed struct {
    /// Buffer is going to be presented to the screen using an API such
    /// as KMS.
    scanout: bool = false,

    /// Buffer is to be used for cursor overlays.
    cursor: bool = false,

    /// Buffer is to be used for rendering, e.g. as the storage for a
    /// color buffer.
    rendering: bool = false,

    /// Buffer can be used for `gbm_bo_write`. This is guaranteed to
    /// work with `cursor`, but may not work for other combinations.
    write: bool = false,

    /// Buffer is linear, i.e. not tiled.
    linear: bool = false,

    /// Buffer is protected, i.e. encrypted and not readable by CPU or
    /// any other non-secure component.
    protected: bool = false,

    _pad: u26 = 0,

    pub fn toInt(self: Usage) c_uint {
        return @bitCast(self);
    }
};

pub const Error = error{
    /// `gbm_bo_create*` failed.
    BoCreateFailed,
    /// The created buffer has an unsupported number of planes.
    BadPlaneCount,
    /// Exporting a plane returned an invalid file descriptor.
    InvalidPlanes,
};

/// The maximum number of planes a buffer can have (GBM_MAX_PLANES).
pub const max_planes: usize = @intCast(c.GBM_MAX_PLANES);

bo: *c.struct_gbm_bo,
width: u32,
height: u32,
format: Format,
plane_count: u8,

/// The DRM format modifier of the buffer.
/// This is `Modifier.invalid` if the driver chose an implicit layout.
modifier: Modifier,

pub const Options = struct {
    width: u32,
    height: u32,
    format: Format,
    usage: Usage = .{},

    /// An explicit modifier list to allocate with. If null (the
    /// default), the driver chooses its optimal layout, which may be
    /// an implicit layout (`Modifier.invalid`).
    modifiers: ?[]const Modifier = null,
};

// See `drm_fourcc.h`
pub const Modifier = packed struct(u64) {
    value: Value,
    vendor: Vendor,

    pub const Value = enum(u56) {
        linear = 0,
        reserved = std.math.maxInt(u56),
        _,
    };

    pub const Vendor = enum(u8) {
        none = 0,
        _,
    };

    pub const linear: Modifier = .{ .value = .linear, .vendor = .none };
    pub const invalid: Modifier = .{ .value = .reserved, .vendor = .none };

    /// Whether the modifier describes an implicit driver-chosen
    /// layout, in which case importers must not be given an explicit
    /// modifier.
    pub fn isImplicit(self: Modifier) bool {
        return self.value == .reserved and self.vendor == .none;
    }
};

/// Allocates a new buffer object.
pub fn init(device: *const Device, opts: Options) Error!BufferObject {
    const bo = c.gbm_bo_create_with_modifiers2(
        device.device,
        opts.width,
        opts.height,
        @intFromEnum(opts.format),
        if (opts.modifiers) |m| @ptrCast(m.ptr) else null,
        if (opts.modifiers) |m| @intCast(m.len) else 0,
        opts.usage.toInt(),
    ) orelse return error.BoCreateFailed;
    errdefer c.gbm_bo_destroy(bo);

    const plane_count: usize = @intCast(c.gbm_bo_get_plane_count(bo));
    if (plane_count < 1 or plane_count > max_planes) {
        return error.BadPlaneCount;
    }

    return .{
        .bo = bo,
        .width = opts.width,
        .height = opts.height,
        .format = opts.format,
        .modifier = @bitCast(c.gbm_bo_get_modifier(bo)),
        .plane_count = @intCast(plane_count),
    };
}

/// Destroys the buffer object.
///
/// Any DMA-BUF file descriptors previously exported via `planes`
/// keep the underlying memory alive until they're closed by every
/// consumer.
pub fn deinit(self: *BufferObject) void {
    c.gbm_bo_destroy(self.bo);
}

/// The set of planes that make up a buffer, with one file descriptor
/// opened per plane.
pub const Planes = struct {
    count: u8,
    fds: [max_planes]std.posix.fd_t = @splat(-1),
    strides: [max_planes]c_int = @splat(0),
    offsets: [max_planes]c_int = @splat(0),

    /// Closes all file descriptors.
    pub fn deinit(self: Planes) void {
        for (self.fds[0..self.count]) |fd| {
            if (fd >= 0) _ = std.posix.system.close(fd);
        }
    }
};

/// Open fresh file descriptors for each plane of the buffer.
///
/// The caller takes ownership of the returned planes and must call
/// `Planes.deinit` (or otherwise close the fds) when done.
pub fn planes(self: *const BufferObject) Error!Planes {
    var result: Planes = .{ .count = self.plane_count };

    for (0..self.plane_count) |i| {
        const plane: c_int = @intCast(i);
        result.fds[i] = c.gbm_bo_get_fd_for_plane(self.bo, plane);
        result.strides[i] = @intCast(c.gbm_bo_get_stride_for_plane(self.bo, plane));
        result.offsets[i] = @intCast(c.gbm_bo_get_offset(self.bo, plane));
    }

    var valid: usize = 0;
    while (valid < result.count) : (valid += 1) {
        if (result.fds[valid] < 0) {
            for (result.fds[0..valid]) |fd| {
                _ = std.posix.system.close(fd);
            }
            return error.InvalidPlanes;
        }
    }

    return result;
}
