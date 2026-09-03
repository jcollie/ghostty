//! Minimal GBM (Generic Buffer Manager) bindings.
//!
//! This only includes the API that Ghostty needs but can
//! be expanded if needed.
//!
//! Requires libgbm >= 21.1 for `gbm_bo_create_with_modifiers2` and
//! `gbm_bo_get_fd_for_plane`.

const std = @import("std");

/// The raw GBM C API, translated from gbm.h.
pub const c = @import("c");

pub const Device = @import("Device.zig");
pub const BufferObject = @import("BufferObject.zig");
pub const Format = BufferObject.Format;
pub const Modifier = BufferObject.Modifier;
pub const Usage = BufferObject.Usage;
