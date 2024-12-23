const std = @import("std");

const global_state = &@import("global.zig").state;

const c = @cImport({
    @cInclude("locale.h");
    @cInclude("libintl.h");
});

const log = std.log.scoped(.i18n);

pub const Error = error{
    UnableToInitializeI18N,
    NoResourcesDir,
};

pub fn gettext(msgid: [:0]const u8) [:0]const u8 {
    return std.mem.span(c.gettext(msgid));
}
pub const _ = gettext;

pub fn init(alloc: std.mem.Allocator) (std.mem.Allocator.Error || Error)!void {
    const resources_dir = global_state.resources_dir orelse return error.NoResourcesDir;
    const po_dir = try std.fs.path.joinZ(alloc, &.{ resources_dir, "gettext" });
    defer alloc.free(po_dir);

    const dir = c.bindtextdomain("messages", po_dir);
    if (dir == null) return error.UnableToInitializeI18N;

    if (c.textdomain("messages") == null) return error.UnableToInitializeI18N;
}
