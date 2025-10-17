const std = @import("std");
const glib = @import("glib");
const gobject = @import("gobject");
const nautilus = @import("nautilus");

var module_: ?*gobject.TypeModule = null;
var my_types: [1]gobject.Type = undefined;

export fn nautilus_module_initialize(module: *gobject.TypeModule) callconv(.c) void {
    module_ = module;
    my_types[0] = GhosttyNautilusExtension.getGObjectType();
}

export fn nautilus_module_shutdown() callconv(.c) void {}

export fn nautilus_module_list_types(types: [*][*]gobject.Type, num_types: *c_int) callconv(.c) void {
    types.* = &my_types;
    num_types.* = 1;
}

pub const GhosttyNautilusExtension = extern struct {
    const Self = @This();

    parent_instance: Parent,

    pub const Parent = gobject.Object;
    pub const Implements = [_]type{}

    pub const getGObjectType = registerType(Self, .{
        .name = "GhosttyNautilusExtension",
        .classInit = &Class.init,
        .parent_class = &Class.parent,
        .private = null,
        .interfaces = .{

        }
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

pub fn registerType(
    comptime Instance: type,
    comptime options: gobject.ext.DefineClassOptions(Instance),
) fn () callconv(.c) gobject.Type {
    const instance_info = @typeInfo(Instance);
    if (instance_info != .@"struct" or instance_info.@"struct".layout != .@"extern") {
        @compileError("an instance type must be an extern struct");
    }

    if (!@hasDecl(Instance, "Parent")) {
        @compileError("a class type must have a declaration named Parent pointing to the parent type");
    }
    const parent_info = @typeInfo(Instance.Parent);
    if (parent_info != .@"struct" or parent_info.@"struct".layout != .@"extern" or !@hasDecl(Instance.Parent, "getGObjectType")) {
        @compileError("the defined parent type " ++ @typeName(Instance.Parent) ++ " does not appear to be a GObject class type");
    }
    if (instance_info.@"struct".fields.len == 0 or instance_info.@"struct".fields[0].type != Instance.Parent) {
        @compileError("the first field of the instance struct must have type " ++ @typeName(Instance.Parent));
    }

    if (!@hasDecl(Instance, "Class")) {
        @compileError("a class type must have a member named Class pointing to the class record");
    }
    const class_info = @typeInfo(Instance.Class);
    if (class_info != .@"struct" or class_info.@"struct".layout != .@"extern") {
        @compileError("a class type must be an extern struct");
    }
    if (!@hasDecl(Instance.Class, "Instance") or Instance.Class.Instance != Instance) {
        @compileError("a class type must have a declaration named Instance pointing to the instance type");
    }
    if (class_info.@"struct".fields.len == 0 or class_info.@"struct".fields[0].type != Instance.Parent.Class) {
        @compileError("the first field of the class struct must have type " ++ @typeName(Instance.Parent.Class));
    }

    return struct {
        var registered_type: gobject.Type = 0;

        pub fn getGObjectType() callconv(.c) gobject.Type {
            const module = module_ orelse @panic("no module");

            if (glib.Once.initEnter(&registered_type) != 0) {
                const classInitFunc = struct {
                    fn classInit(class: *Instance.Class) callconv(.c) void {
                        if (options.parent_class) |parent_class| {
                            const parent = gobject.TypeClass.peekParent(gobject.ext.as(gobject.TypeClass, class));
                            parent_class.* = @ptrCast(@alignCast(parent));
                        }
                        if (options.private) |private| {
                            gobject.TypeClass.adjustPrivateOffset(class, private.offset);
                        }
                        if (options.classInit) |userClassInit| {
                            userClassInit(class);
                        }
                    }
                }.classInit;

                const info: gobject.TypeInfo = .{
                    .f_class_size = @sizeOf(Instance.Class),
                    .f_base_init = @ptrCast(options.baseInit),
                    .f_base_finalize = @ptrCast(options.baseFinalize),
                    .f_class_init = @ptrCast(&classInitFunc),
                    .f_class_finalize = @ptrCast(options.classFinalize),
                    .f_class_data = null,
                    .f_instance_size = @sizeOf(Instance),
                    .f_n_preallocs = 0,
                    .f_instance_init = @ptrCast(options.instanceInit),
                    .f_value_table = null,
                };

                const type_id = gobject.TypeModule.registerType(
                    module,
                    Instance.Parent.getGobjectType(),
                    options.name orelse gobject.ext.deriveTypeName(Instance),
                    &info,
                    options.flags,
                );

                if (options.private) |private| {
                    private.offset.* = gobject.typeAddInstancePrivate(type_id, @sizeOf(private.Type));
                }

                {
                    const Implements = if (@hasDecl(Instance, "Implements")) Instance.Implements else [_]type{};
                    comptime var found = [_]bool{false} ** Implements.len;
                    inline for (options.implements) |implementation| {
                        inline for (Implements, &found) |Iface, *found_match| {
                            if (implementation.Iface == Iface) {
                                if (found_match.*) @compileError("duplicate implementation of " ++ @typeName(Iface));
                                gobject.typeAddInterfaceStatic(type_id, implementation.Iface.getGObjectType(), &implementation.info);
                                found_match.* = true;
                                break;
                            }
                        }
                    }
                    inline for (Implements, found) |Iface, found_match| {
                        if (!found_match) @compileError("missing implementation of " ++ @typeName(Iface));
                    }
                }

                glib.Once.initLeave(&registered_type, type_id);
            }
            return registered_type;
        }
    }.getGObjectType;
}
