const std = @import("std");
const c = @cImport({
    @cInclude("locale.h");
    @cInclude("libintl.h");
});
const log = std.log.scoped(.i18n);

pub fn gettext(msgid: [:0]const u8) [:0]const u8 {
    return std.mem.span(c.gettext(msgid));
}
pub const _ = gettext;

pub fn init() !void {
    const dir = c.bindtextdomain("messages", "/home/leah/coding/ghostty/po");
    if (dir == null) return error.OutOfMemory;

    if (c.textdomain("messages") == null) return error.OutOfMemory;
}
