const std = @import("std");

const gio = @import("gio");
const glib = @import("glib");

const assert = @import("../../quirks.zig").inlineAssert;

const log = std.log.scoped(.dbushelper);

pub fn Object(comptime T: type) type {
    return struct {
        const Self = @This();

        object_path: [:0]const u8,
        interfaces: []const InterfaceInfo,

        pub const InterfaceInfo = struct {
            name: [:0]const u8,
            methods: []const MethodInfo,

            fn dbusInterfaceInfo(self: @This()) gio.DBusInterfaceInfo {
                assert(@inComptime());
                var var_ptrs: [self.methods.len:null]?*gio.DBusMethodInfo = @splat(null);
                for (self.methods, 0..) |method, i| {
                    const m = method.dbusMethodInfo();
                    var_ptrs[i] = @constCast(&m);
                }
                const const_ptrs = var_ptrs;
                return .{
                    .f_ref_count = -1,
                    .f_name = @constCast(self.name),
                    .f_methods = @constCast(&const_ptrs),
                    .f_properties = null,
                    .f_signals = null,
                    .f_annotations = null,
                };
            }
        };

        pub const MethodHandler = fn (*T, *glib.Variant, *gio.DBusMethodInvocation) void;

        pub const MethodInfo = struct {
            name: [:0]const u8,
            in_args: []const ArgInfo,
            out_args: []const ArgInfo,
            handler: MethodHandler,

            fn dbusMethodInfo(self: @This()) gio.DBusMethodInfo {
                assert(@inComptime());
                return .{
                    .f_ref_count = -1,
                    .f_name = @constCast(self.name),
                    .f_in_args = if (self.in_args.len > 0) args: {
                        var var_ptrs: [self.in_args.len:null]?*gio.DBusArgInfo = @splat(null);
                        for (self.in_args, 0..) |arg, i| {
                            const a = arg.dbusArgInfo();
                            var_ptrs[i] = @constCast(a);
                        }
                        const const_ptrs = var_ptrs;
                        break :args @constCast(&const_ptrs);
                    } else null,
                    .f_out_args = if (self.out_args.len > 0) args: {
                        var var_ptrs: [self.in_args.len:null]?*gio.DBusArgInfo = @splat(null);
                        for (self.out_args, 0..) |arg, i| {
                            const a = arg.dbusArgInfo();
                            var_ptrs[i] = @constCast(&a);
                        }
                        const const_ptrs = var_ptrs;
                        break :args @constCast(&const_ptrs);
                    } else null,
                    .f_annotations = null,
                };
            }
        };

        pub const ArgInfo = struct {
            name: [:0]const u8,
            signature: [:0]const u8,

            fn dbusArgInfo(self: @This()) gio.DBusArgInfo {
                assert(@inComptime());
                return .{
                    .f_ref_count = -1,
                    .f_name = @constCast(self.name),
                    .f_signature = @constCast(self.signature),
                    .f_annotations = null,
                };
            }
        };

        pub const DBusObject = struct {
            object_path: [:0]const u8,
            interface_info: gio.DBusInterfaceInfo,
        };

        pub const Handler = struct {
            objects: []const DBusObject,
            map: ObjectNameMap,

            pub fn init(comptime objects: []const Self) Self.Handler {
                assert(@inComptime());

                const dbus_objects: []const DBusObject = i: {
                    var count = 0;

                    for (objects) |object| {
                        count += object.interfaces.len;
                    }

                    var dbi: [count]DBusObject = undefined;
                    var index = 0;

                    for (objects) |object| {
                        for (object.interfaces) |info| {
                            dbi[index] = .{
                                .object_path = object.object_path,
                                .interface_info = info.dbusInterfaceInfo(),
                            };

                            index += 1;
                        }
                    }

                    const d = dbi;
                    break :i &d;
                };

                const map = object_name_map: {
                    var object_name_kvs: [objects.len]std.meta.Tuple(&[_]type{ []const u8, *const InterfaceNameMap }) = undefined;
                    for (objects, 0..) |object, i| {
                        object_name_kvs[i] = .{
                            object.object_path,
                            interface_name_map: {
                                var insterface_name_kvs: [object.interfaces.len]std.meta.Tuple(&[_]type{ []const u8, *const MethodHandlerMap }) = undefined;
                                for (object.interfaces, 0..) |interface, j| {
                                    insterface_name_kvs[j] = .{
                                        interface.name,
                                        method_handler_map: {
                                            var method_handler_kvs: [interface.methods.len]std.meta.Tuple(&[_]type{ []const u8, *const MethodHandler }) = undefined;
                                            for (interface.methods, 0..) |method, k| {
                                                method_handler_kvs[k] = .{
                                                    method.name,
                                                    method.handler,
                                                };
                                            }
                                            const method_handler_map: MethodHandlerMap = .initComptime(method_handler_kvs);
                                            break :method_handler_map &method_handler_map;
                                        },
                                    };
                                }
                                const interface_name_map: InterfaceNameMap = .initComptime(insterface_name_kvs);
                                break :interface_name_map &interface_name_map;
                            },
                        };
                    }
                    const object_name_map: ObjectNameMap = .initComptime(object_name_kvs);
                    break :object_name_map object_name_map;
                };

                return .{
                    .objects = dbus_objects,
                    .map = map,
                };
            }

            pub const UserData = struct {
                alloc: std.mem.Allocator,
                handler: *const Self.Handler,
                parent: *T,
            };

            pub fn register(self: *const Self.Handler, alloc: std.mem.Allocator, parent: *T, dbus_: ?*gio.DBusConnection) !void {
                const dbus = dbus_ orelse {
                    log.warn("No DBus connection when trying to register objects!", .{});
                    return;
                };

                for (self.objects) |d| {
                    const userdata = try alloc.create(UserData);
                    userdata.* = .{
                        .alloc = alloc,
                        .handler = self,
                        .parent = parent.ref(),
                    };
                    var err_: ?*glib.Error = null;
                    if (dbus.registerObject(
                        d.object_path,
                        @constCast(&d.interface_info),
                        @constCast(&dbus_vtable),
                        userdata,
                        dbusUserDataFree,
                        &err_,
                    ) == 0) {
                        if (err_) |err| {
                            defer err.free();
                            log.warn(
                                "error registering dbus objects: {s}",
                                .{err.f_message orelse "«unknown»"},
                            );
                        }
                    }
                    assert(err_ == null);
                }
            }

            fn dbusUserDataFree(ud: ?*anyopaque) callconv(.c) void {
                const userdata: *UserData = @ptrCast(@alignCast(ud orelse return));
                const alloc = userdata.alloc;
                userdata.parent.unref();
                alloc.destroy(userdata);
            }

            const ObjectNameMap = std.StaticStringMap(*const InterfaceNameMap);
            const InterfaceNameMap = std.StaticStringMap(*const MethodHandlerMap);
            const MethodHandlerMap = std.StaticStringMap(*const MethodHandler);

            pub const dbus_vtable: gio.DBusInterfaceVTable = .{
                .f_method_call = dbusMethodCall,
                .f_get_property = null,
                .f_set_property = null,
                .f_padding = undefined,
            };

            fn dbusMethodCall(
                _: *gio.DBusConnection,
                sender_: ?[*:0]const u8,
                object_path_: ?[*:0]const u8,
                interface_name_: ?[*:0]const u8,
                method_name_: ?[*:0]const u8,
                parameters: *glib.Variant,
                invocation: *gio.DBusMethodInvocation,
                ud: ?*anyopaque,
            ) callconv(.c) void {
                const userdata: *UserData = @ptrCast(@alignCast(ud orelse return));

                const sender = std.mem.span(
                    sender_ orelse {
                        invocation.returnDbusError("NoSender", "no sender");
                        return;
                    },
                );
                log.warn("dbus sender: {s}", .{sender});

                const object_path = std.mem.span(
                    object_path_ orelse {
                        invocation.returnDbusError("NoObjectPath", "no object path");
                        return;
                    },
                );
                log.warn("dbus object path: {s}", .{object_path});

                const object_path_map = userdata.handler.map.get(object_path) orelse {
                    invocation.returnDbusError("InvalidObjectPath", "invalid object path");
                    return;
                };

                const interface_name = std.mem.span(
                    interface_name_ orelse {
                        invocation.returnDbusError("NoInterfaceName", "no interface name");
                        return;
                    },
                );

                const interface_name_map = object_path_map.get(interface_name) orelse {
                    invocation.returnDbusError("InvalidInterfaceName", "invalid interface name");
                    return;
                };

                const method_name = std.mem.span(
                    method_name_ orelse {
                        invocation.returnDbusError("NoMethodName", "no method name");
                        return;
                    },
                );
                log.warn("dbus method name: {s}", .{method_name});

                const handler = interface_name_map.get(method_name) orelse {
                    invocation.returnDbusError("InvalidInterfaceName", "invalid interface name");
                    return;
                };

                handler(userdata.parent, parameters, invocation);
            }
        };
    };
}
