const std = @import("std");
const Allocator = std.mem.Allocator;

const glib = @import("glib");

const apprt = @import("../../../apprt.zig");
const DBus = @import("DBus.zig");

// Use a D-Bus method call to open a new window on GTK.
// See: https://wiki.gnome.org/Projects/GLib/GApplication/DBusAPI
//
// `ghostty +present-surface` is equivalent to the following command (on a release build):
//
// ```
// gdbus call --session --dest com.mitchellh.ghostty --object-path /com/mitchellh/ghostty --method org.gtk.Actions.Activate present-surface [0xba5019596327ce23] []
// ```
pub fn presentSurface(alloc: Allocator, target: apprt.ipc.Target, value: apprt.ipc.Action.Value(.present_surface)) (Allocator.Error || std.posix.WriteError || apprt.ipc.Errors)!bool {
    var dbus = try DBus.init(alloc, target, "present-surface");
    defer dbus.deinit(alloc);

    const t_variant_type = glib.ext.VariantType.newFor(u64);
    defer t_variant_type.free();

    const id = glib.Variant.newUint64(value.id);

    dbus.addParameter(id);

    try dbus.send();

    return true;
}
