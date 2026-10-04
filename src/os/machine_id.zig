//! The OS's machine ID: a stable identifier for this machine, which
//! programs on other machines (e.g. over ssh) compare to their own to
//! tell they are elsewhere, as in Kitty's drag and drop protocol.

const std = @import("std");
const builtin = @import("builtin");

/// Read the raw machine ID into `buf`: /etc/machine-id (or D-Bus's copy)
/// on Linux and the BSDs. Null where there isn't one, including other
/// platforms, which have their own (IOPlatformUUID on macOS).
pub fn machineId(io: std.Io, buf: []u8) ?[]const u8 {
    if (comptime !(builtin.os.tag == .linux or builtin.os.tag.isBSD())) return null;
    for ([_][]const u8{ "/etc/machine-id", "/var/lib/dbus/machine-id" }) |path| {
        const data = std.Io.Dir.cwd().readFile(io, path, buf) catch continue;
        const id = std.mem.trim(u8, data, &std.ascii.whitespace);
        if (id.len > 0) return id;
    }
    return null;
}
