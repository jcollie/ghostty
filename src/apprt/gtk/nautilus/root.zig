const std = @import("std");
const glib = @import("glib");
const gobject = @import("gobject");

pub fn nautilus_module_initialize(module: *gobject.TypeModule) callconv(.c) void {
    const info: gobject.TypeInfo = .{
        .f_base_init = null,
        .f_base_finalize = null,
        .f_instance_size = @sizeOf(GhosttyNautilusExtension),
        .f_instance_init = GhosttyNautilusExtension.init,
        .f_class_size = @sizeOf(GhosttyNautilusExtension.Class),
        .f_class_init = GhosttyNautilusExtension.Class.init,
        .f_class_data = null,
        .f_class_finalize = null,
        .f_n_preallocs = 0,
        .f_value_table = null,
    };

    gobject.TypeModule.registerType(
        module,
        gobject.Object.getGObjectType(),
        "GhosttyNautilusExtension",
        &info,
        .{},
    );

    gobject.ext.ensureType(GhosttyNautilusExtension);
}

pub fn nautilus_module_shutdown() callconv(.c) void {}

pub fn nautilus_module_list_types(types: [*][*]gobject.Type, num_types: *c_int) callconv(.c) void {}

pub const GhosttyNautilusExtension = extern struct {
    const Self = @This();

    parent_instance: Parent,

    pub const Parent = gobject.Object;

    pub const getGObjectType = gobject.ext.defineClass(Self, .{
        .name = "GhosttyNautilusExtension",
        .classInit = &Class.init,
        .parent_class = &Class.parent,
        .private = null,
    });

    pub fn init(self: *Self) void {
        _ = self;
    }

    pub const Class = extern struct {
        parent_class: Parent.Class,
        var parent: *Parent.Class = undefined;
        pub const Instance = Self;

        fn init(class: *Class) callconv(.c) void {
            _ = class;
        }
    };
};
