//! Presents rendered frames to the apprt.
//!
//! This should in theory be quite simple: there's an EGL extension
//! (`EGL_MESA_image_dma_buf_export`) that can export EGL images directly
//! into DMABUFs which apprts like GTK can directly consume and composite.
//!
//! However, this is *Mesa-specific*. NVIDIA proprietary drivers therefore
//! don't implement it, even when they already have all the pieces to do so.
//! (There's a NVIDIA-specific internal API that does this exact thing, but
//! it's experimental and only used by EGL platform APIs like `egl-x11` and
//! `egl-wayland2`.) More frustratingly, this is entirely unnecessary with
//! Vulkan, since just about everyone supports the standard
//! `VK_EXT_external_memory_dma_buf` extension, even NVIDIA.
//! This is why we can't have good things.
//!
//! Therefore, we have to go the long way around. We use libgbm to directly
//! access DRM devices and allocate buffer objects as the data storage, which
//! can be imported into EGL as our export image, and then bound to a 2D
//! texture to which we can blit the target framebuffer. The export image can
//! then be directly exported into a DMABUF with libgbm APIs.
//!
//! GPU land:
//!      +--------------------+                  +------------------+
//!      | Target framebuffer | ~~ effective ~~> | GBM BufferObject |---+
//!      +--------------------+    data transfer +------------------+   |
//!                        |                           |                |
//!             blits into |          memory backed by |     exports to |
//! -----------------------+---------------------------+----------------+----
//! CPU land:              V                           V                V
//!                   +-----------+                +----------+     +--------+
//!                   | GLTexture | <- bound to -- | EGLImage |     | DMABUF |
//!                   +-----------+                +----------+     +--------+
const Presenter = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const gl = @import("opengl");
const egl = gl.egl;
const gbm = @import("gbm");
const Target = @import("Target.zig");
const Dmabuf = @import("../Dmabuf.zig");

const log = std.log.scoped(.opengl);

const global = @import("../../global.zig");

/// A finished frame exported for presentation by the apprt.
///
/// The presentation buffers are allocated with GBM and presented as
/// DMA-BUFs for zero-copy compositing by the apprt. If GBM isn't
/// available, we present by reading the frame back into CPU memory
/// instead.
pub const ExportedFrame = union(enum) {
    dmabuf: Dmabuf,
    memory: Memory,

    /// RGBA8 pixel data with premultiplied alpha, tightly packed
    /// (`width * 4` bytes per row), in CPU memory.
    pub const Memory = struct {
        width: u32,
        height: u32,
        pixels: []u8,
        alloc: Allocator,

        pub fn deinit(self: Memory) void {
            self.alloc.free(self.pixels);
        }
    };

    pub fn deinit(self: ExportedFrame) void {
        switch (self) {
            .dmabuf => |v| v.deinit(),
            .memory => |v| v.deinit(),
        }
    }
};

egl_display: *egl.Display,

/// The GBM device used to allocate presentation buffers, owned by the
/// presenter. If null, we can't present via DMA-BUFs and the API
/// falls back to CPU readback.
device: ?gbm.Device = null,

/// Once a DMA-BUF presentation fails, we latch off and fall back to
/// CPU readback for all future frames.
dmabuf_failed: bool = false,

/// The export framebuffer. Its color attachment is rebound to a fresh
/// GBM-backed image every frame. Only created when `device` is set;
/// creation is deferred until the first present since it must happen
/// with the GL context current (i.e. on the render thread).
texture: ?gl.Texture = null,
framebuffer: ?gl.Framebuffer = null,

/// The GBM buffer currently backing the export framebuffer.
bo: ?gbm.BufferObject = null,

/// The EGLImage importing `bo`.
image: ?*egl.Image = null,

/// Initializes the presenter.
///
/// `drm_node` is the DRM device node of the EGL device in use, if
/// known. GBM-backed DMA-BUF presentation is only set up when a node
/// is available and the display supports DMA-BUF import; otherwise
/// the API falls back to CPU readback.
pub fn init(display: *egl.Display, drm_node: ?[:0]const u8) Presenter {
    var self: Presenter = .{ .egl_display = display };

    if (drm_node) |node| device: {
        const extensions = display.queryString(.extensions) orelse break :device;

        if (std.mem.find(
            u8,
            extensions,
            "EGL_EXT_image_dma_buf_import_modifiers",
        ) == null) {
            break :device;
        }

        self.device = gbm.Device.init(global.io(), node) catch |err| {
            log.warn(
                "failed to initialize GBM device, presentation will fall back err={}",
                .{err},
            );
            break :device;
        };
    }

    if (self.device == null) {
        log.warn("EGL driver cannot present via DMA-BUFs, presenting via CPU memory copy", .{});
    }

    return self;
}

/// Presents `target` as a DMA-BUF. The caller takes ownership of the
/// returned DMA-BUF. Must be called with the GL context current.
///
/// On the first failure this logs the reason, latches off, and all
/// future calls return `error.GbmUnavailable` (the API then falls
/// back to CPU readback).
pub fn present(self: *Presenter, target: *const Target) !Dmabuf {
    if (self.device == null or self.dmabuf_failed) return error.GbmUnavailable;
    return self.presentDmabuf(target) catch |err| {
        log.warn(
            "failed to export frame as DMABUF ({}), falling back to CPU memory presentation",
            .{err},
        );
        self.dmabuf_failed = true;
        return err;
    };
}

fn presentDmabuf(self: *Presenter, target: *const Target) !Dmabuf {
    const device = &self.device.?;

    // Lazily create the export framebuffer objects.
    if (self.framebuffer == null) {
        self.texture = try gl.Texture.create();
        errdefer if (self.texture) |t| t.destroy();
        self.framebuffer = try gl.Framebuffer.create();
        errdefer if (self.framebuffer) |f| f.destroy();
    }

    // Allocate a fresh buffer every frame, import it, and rebind the
    // export framebuffer's color attachment to it.
    var bo: gbm.BufferObject = try .init(device, .{
        .width = @intCast(target.width),
        .height = @intCast(target.height),
        .format = .abgr8888,
        .usage = .{ .rendering = true },
    });
    errdefer bo.deinit();

    const image = try importImage(&bo, self.egl_display);
    errdefer image.destroy(self.egl_display) catch {};

    {
        const texture = self.texture.?;
        const bound_tex = try texture.bind(.@"2d");
        defer bound_tex.unbind();
        try image.bindToTexture2D();
    }

    // Tear down the previous frame's buffer only after the new image
    // is bound. The memory of the old buffer is kept alive by any fds
    // we exported from it until their last consumer closes them.
    if (self.image) |old_image| {
        old_image.destroy(self.egl_display) catch |err| {
            log.err("failed to destroy previous export EGLImage err={}", .{err});
        };
        self.image = null;
    }
    if (self.bo) |*old_bo| old_bo.deinit();

    self.bo = bo;
    self.image = image;

    // We disable GL_FRAMEBUFFER_SRGB while doing this blit, otherwise
    // the values may be linearized as they're copied, but even though
    // the draw framebuffer has a linear internal format, the values in
    // it should be sRGB, not linear!
    try gl.disable(gl.c.GL_FRAMEBUFFER_SRGB);
    defer gl.enable(gl.c.GL_FRAMEBUFFER_SRGB) catch |err| {
        log.err("Error re-enabling GL_FRAMEBUFFER_SRGB, err={}", .{err});
    };

    const read_bind = try target.framebuffer.bind(.read);
    defer read_bind.unbind();

    const draw_bind = try self.framebuffer.?.bind(.draw);
    defer draw_bind.unbind();

    // (Re)attach the color attachment every frame: the texture's
    // storage (the imported image) changes every frame.
    try draw_bind.texture2D(.color0, .@"2d", self.texture.?, 0);

    try gl.blitFramebuffer(
        0,
        0,
        @intCast(target.width),
        @intCast(target.height),
        0,
        0,
        @intCast(target.width),
        @intCast(target.height),
        .{ .color_buffer_bit = true },
        .nearest,
    );

    // Make sure the blit is complete before exporting.
    gl.flush();

    // Export the buffer as a DMA-BUF. Each export produces fresh file
    // descriptors, so the caller takes ownership of the result.
    const planes = try bo.planes();
    return .{
        .width = bo.width,
        .height = bo.height,
        .fourcc = @intFromEnum(bo.format),
        .modifier = @bitCast(bo.modifier),
        .premultiplied = true,
        .planes = .{
            .count = planes.count,
            .fds = planes.fds,
            .strides = planes.strides,
            .offsets = planes.offsets,
        },
    };
}

/// Imports a GBM buffer into EGL as an `EGL_LINUX_DMA_BUF_EXT` image
/// so it can be rendered into via OpenGL. The image references the
/// same memory as the buffer; it must be destroyed before the buffer
/// is.
fn importImage(bo: *const gbm.BufferObject, display: *egl.Display) !*egl.Image {
    var planes = try bo.planes();
    defer planes.deinit();

    const attribs = egl.dmabufImportAttribs(
        @intFromEnum(bo.format),
        @intCast(bo.width),
        @intCast(bo.height),
        planes.fds[0..planes.count],
        planes.strides[0..planes.count],
        planes.offsets[0..planes.count],
        // An invalid/implicit modifier must not be passed explicitly.
        if (bo.modifier == gbm.Modifier.invalid) null else @bitCast(bo.modifier),
    );

    return try .create(
        display,
        // Per `EGL_EXT_image_dma_buf_import`, the context for a
        // `EGL_LINUX_DMA_BUF_EXT` image must be EGL_NO_CONTEXT.
        null,
        .linux_dma_buf,
        attribs.items(),
    );
}

/// Destroys all GL, EGL, and GBM resources. Must be called with the
/// GL context current (i.e. on the render thread) so the GL resources
/// are destroyed properly. Safe to call multiple times.
pub fn deinit(self: *Presenter) void {
    if (self.framebuffer) |fbo| fbo.destroy();
    if (self.image) |image| {
        image.destroy(self.egl_display) catch |err| {
            log.err("failed to destroy export EGLImage err={}", .{err});
        };
    }
    if (self.bo) |*bo| bo.deinit();
    if (self.texture) |texture| texture.destroy();
    if (self.device) |*device| device.deinit(global.io());
}
