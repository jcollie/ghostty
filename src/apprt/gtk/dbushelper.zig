const std = @import("std");

const gio = @import("gio");
const glib = @import("glib");

const assert = @import("../../quirks.zig").inlineAssert;
const WeakRef = @import("weak_ref.zig").WeakRef;

const log = std.log.scoped(.gtk_dbus_object);

pub fn Object(comptime T: type) type {
    return struct {
        const Self = @This();

        object_path: [:0]const u8,
        interfaces: []const InterfaceInfo,

        /// Zig-friendly struct to define a DBus interface.
        pub const InterfaceInfo = struct {
            name: [:0]const u8,
            methods: []const MethodInfo,

            /// Convert the Zig-friendly struct to the GObject struct needed by GIO.
            fn dbusInterfaceInfo(self: @This()) gio.DBusInterfaceInfo {
                assert(@inComptime());
                var var_ptrs: [self.methods.len:null]?*gio.DBusMethodInfo = @splat(null);
                for (self.methods, 0..) |method, i| {
                    const m = method.dbusMethodInfo();
                    var_ptrs[i] = @constCast(&m);
                }
                var_ptrs[self.methods.len] = null;
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

        /// Zig-friendly struct to define a DBus method.
        pub const MethodInfo = struct {
            name: [:0]const u8,
            in_args: []const ArgInfo,
            out_args: []const ArgInfo,
            handler: MethodHandler,

            /// Convert the Zig-friendly struct to the GObject struct needed by GIO.
            fn dbusMethodInfo(self: @This()) gio.DBusMethodInfo {
                assert(@inComptime());
                return .{
                    .f_ref_count = -1,
                    .f_name = @constCast(self.name),
                    .f_in_args = if (self.in_args.len > 0) args: {
                        var var_ptrs: [self.in_args.len:null]?*gio.DBusArgInfo = @splat(null);
                        for (self.in_args, 0..) |arg, i| {
                            const a = arg.dbusArgInfo();
                            var_ptrs[i] = @constCast(&a);
                        }
                        var_ptrs[self.in_args.len] = null;
                        const const_ptrs = var_ptrs;
                        break :args @constCast(&const_ptrs);
                    } else null,
                    .f_out_args = if (self.out_args.len > 0) args: {
                        var var_ptrs: [self.out_args.len:null]?*gio.DBusArgInfo = @splat(null);
                        for (self.out_args, 0..) |arg, i| {
                            const a = arg.dbusArgInfo();
                            var_ptrs[i] = @constCast(&a);
                        }
                        var_ptrs[self.out_args.len] = null;
                        const const_ptrs = var_ptrs;
                        break :args @constCast(&const_ptrs);
                    } else null,
                    .f_annotations = null,
                };
            }
        };

        /// Zig-friendly struct to define a DBus method argument.
        pub const ArgInfo = struct {
            name: [:0]const u8,
            signature: [:0]const u8,

            /// Convert the Zig-friendly struct to the GObject struct needed by GIO.
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

        /// Function signature for a method handler.
        pub const MethodHandler = fn (*T, *glib.Variant, *gio.DBusMethodInvocation) void;

        /// Zig ztructure for handling incoming DBus method calls.
        pub const Handler = struct {
            objects: []const DBusObject,
            map: ObjectNameMap,

            pub const DBusObject = struct {
                object_path: [:0]const u8,
                interface_info: gio.DBusInterfaceInfo,
            };

            const ObjectNameMap = std.StaticStringMap(*const InterfaceNameMap);

            const InterfaceNameMap = std.StaticStringMap(*const MethodNameMap);

            const MethodNameMap = std.StaticStringMap(*const MethodHandler);

            /// Convert the Zig-friendly objects to GIO objects and a map to
            /// make finding the appropriate handler function for a method
            /// easier.
            pub fn init(comptime zig_objects: []const Self) Self.Handler {
                assert(@inComptime());

                const dbus_objects: []const DBusObject = dbo: {
                    var count = 0;

                    for (zig_objects) |object| {
                        count += object.interfaces.len;
                    }

                    var var_objects: [count]DBusObject = undefined;
                    var index = 0;

                    for (zig_objects) |object| {
                        for (object.interfaces) |info| {
                            var_objects[index] = .{
                                .object_path = object.object_path,
                                .interface_info = info.dbusInterfaceInfo(),
                            };

                            index += 1;
                        }
                    }

                    const const_objects = var_objects;
                    break :dbo &const_objects;
                };

                const InterfaceNameMapTuple = std.meta.Tuple(&[_]type{ []const u8, *const InterfaceNameMap });
                const MethodNameMapTuple = std.meta.Tuple(&[_]type{ []const u8, *const MethodNameMap });
                const MethodHandlerMapTuple = std.meta.Tuple(&[_]type{ []const u8, *const MethodHandler });

                const map = object_name_map: {
                    var object_name_kvs: [zig_objects.len]InterfaceNameMapTuple = undefined;
                    for (zig_objects, 0..) |object, i| {
                        object_name_kvs[i] = .{
                            object.object_path,
                            interface_name_map: {
                                var interface_name_kvs: [object.interfaces.len]MethodNameMapTuple = undefined;
                                for (object.interfaces, 0..) |interface, j| {
                                    interface_name_kvs[j] = .{
                                        interface.name,
                                        method_handler_map: {
                                            var method_handler_kvs: [interface.methods.len]MethodHandlerMapTuple = undefined;
                                            for (interface.methods, 0..) |method, k| {
                                                method_handler_kvs[k] = .{
                                                    method.name,
                                                    method.handler,
                                                };
                                            }
                                            const method_handler_map: MethodNameMap = .initComptime(method_handler_kvs);
                                            break :method_handler_map &method_handler_map;
                                        },
                                    };
                                }
                                const interface_name_map: InterfaceNameMap = .initComptime(interface_name_kvs);
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
                parent: WeakRef(T),

                pub fn new(alloc: std.mem.Allocator, handler: *const Self.Handler, parent: *T) std.mem.Allocator.Error!*UserData {
                    const userdata = try alloc.create(UserData);
                    userdata.* = .{
                        .alloc = alloc,
                        .handler = handler,
                        .parent = .empty,
                    };
                    userdata.parent.set(parent);
                    return userdata;
                }

                pub fn deinit(self: *UserData) void {
                    const alloc = self.alloc;
                    self.parent.set(null);
                    alloc.destroy(self);
                }
            };

            /// Register all of our objects at run-time. Returns a slice of
            /// registration IDs that will be used to unregister the objects
            /// when shutting down.
            pub fn register(
                self: *const Self.Handler,
                alloc: std.mem.Allocator,
                parent: *T,
                dbus: *gio.DBusConnection,
            ) std.mem.Allocator.Error![]c_uint {
                assert(!@inComptime());

                const registration_ids = try alloc.alloc(c_uint, self.objects.len);
                errdefer alloc.free(registration_ids);

                for (self.objects, 0..) |*dbus_object, i| {
                    const user_data: *UserData = try .new(alloc, self, parent);
                    var err_: ?*glib.Error = null;
                    registration_ids[i] = dbus.registerObject(
                        dbus_object.object_path,
                        @constCast(&dbus_object.interface_info),
                        @constCast(&dbus_vtable),
                        user_data,
                        userDataFree,
                        &err_,
                    );
                    if (registration_ids[i] == 0) {
                        if (err_) |err| {
                            defer err.free();
                            log.warn(
                                "error registering dbus interface {?s} for {s}: {s}",
                                .{
                                    dbus_object.interface_info.f_name,
                                    dbus_object.object_path,
                                    err.f_message orelse "«unknown error»",
                                },
                            );
                        }
                        continue;
                    }
                    assert(err_ == null);
                }

                return registration_ids;
            }

            /// Used to free the user data that we allocated at registration time.
            fn userDataFree(ud: ?*anyopaque) callconv(.c) void {
                const userdata: *Self.Handler.UserData = @ptrCast(@alignCast(ud orelse return));
                userdata.deinit();
            }

            pub const dbus_vtable: gio.DBusInterfaceVTable = .{
                .f_method_call = Self.Handler.methodCall,
                .f_get_property = null,
                .f_set_property = null,
                .f_padding = undefined,
            };

            /// Handle an incoming method call from DBus.
            fn methodCall(
                _: *gio.DBusConnection,
                _: ?[*:0]const u8,
                object_path_: ?[*:0]const u8,
                interface_name_: ?[*:0]const u8,
                method_name_: ?[*:0]const u8,
                parameters: *glib.Variant,
                invocation: *gio.DBusMethodInvocation,
                ud: ?*anyopaque,
            ) callconv(.c) void {
                const userdata: *Self.Handler.UserData = @ptrCast(@alignCast(ud orelse return));

                const parent = userdata.parent.get() orelse {
                    log.warn("no parent object set", .{});
                    return;
                };

                const object_path = std.mem.span(
                    object_path_ orelse {
                        invocation.returnDbusError("NoObjectPath", "no object path");
                        return;
                    },
                );

                const interface_name = std.mem.span(
                    interface_name_ orelse {
                        invocation.returnDbusError("NoInterfaceName", "no interface name");
                        return;
                    },
                );

                const method_name = std.mem.span(
                    method_name_ orelse {
                        invocation.returnDbusError("NoMethodName", "no method name");
                        return;
                    },
                );

                const object_path_map = userdata.handler.map.get(object_path) orelse {
                    invocation.returnDbusError("InvalidObjectPath", "invalid object path");
                    return;
                };

                const interface_name_map = object_path_map.get(interface_name) orelse {
                    invocation.returnDbusError("InvalidInterfaceName", "invalid interface name");
                    return;
                };

                const handler = interface_name_map.get(method_name) orelse {
                    invocation.returnDbusError("InvalidMethodName", "invalid method name");
                    return;
                };

                handler(parent, parameters, invocation);
            }
        };
    };
}
