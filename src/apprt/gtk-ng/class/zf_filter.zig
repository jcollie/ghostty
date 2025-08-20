const std = @import("std");
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;

const adw = @import("adw");
const gio = @import("gio");
const glib = @import("glib");
const gobject = @import("gobject");
const gtk = @import("gtk");

const zf = @import("zf");

const ext = @import("../ext.zig");
const input = @import("../../../input.zig");
const gresource = @import("../build/gresource.zig");
const key = @import("../key.zig");
const Common = @import("../class.zig").Common;
const Application = @import("application.zig").Application;
const Window = @import("window.zig").Window;
const Surface = @import("surface.zig").Surface;
const ApprtSurface = @import("../Surface.zig");
const Config = @import("config.zig").Config;

const log = std.log.scoped(.gtk_ghostty_zf_search_filter);

pub const ZfFilter = extern struct {
    pub const Self = @This();
    pub const Parent = gtk.Filter;
    parent: Parent,

    pub const getGObjectType = gobject.ext.defineClass(Self, .{
        .name = "GhosttyZfFilter",
        .instanceInit = &init,
        .classInit = Class.init,
        .parent_class = &Class.parent,
        .private = .{ .Type = Private, .offset = &Private.offset },
    });

    const properties = struct {
        pub const expression = struct {
            pub const name = "expression";

            const impl = struct {
                pub var param_spec: *gobject.ParamSpec = undefined;

                fn newParamSpec() *gobject.ParamSpec {
                    return gtk.paramSpecExpression(
                        name,
                        "",
                        "",
                        .{
                            .readable = true,
                            .writable = true,
                            .construct = true,
                            .construct_only = false,
                            .lax_validation = false,
                            .explicit_notify = true,
                            .deprecated = false,
                            .static_name = true,
                            .static_nick = true,
                            .static_blurb = true,
                        },
                    );
                }

                pub fn register(class: *Self.Class, id: c_uint) void {
                    param_spec = newParamSpec();
                    gobject.Object.Class.installProperty(gobject.ext.as(gobject.Object.Class, class), id, param_spec);
                }

                pub fn get(object: *Self, value: *gobject.Value) void {
                    object.getExpression(value);
                }

                pub fn set(object: *Self, value: *const gobject.Value) void {
                    object.setExpression(value);
                }
            };
        };

        pub const search = struct {
            pub const name = "search";
            const impl = gobject.ext.defineProperty(
                name,
                Self,
                ?[:0]const u8,
                .{
                    .default = null,
                    .accessor = C.privateStringFieldAccessor("search"),
                },
            );
        };
    };

    pub const Private = struct {
        expression: ?*gtk.Expression = null,

        search: ?[:0]const u8 = null,

        tokens: std.ArrayListUnmanaged([]const u8),

        pub var offset: c_int = 0;
    };

    fn init(self: *Self, _: *Class) callconv(.c) void {
        log.warn("ZF instance init", .{});
        const priv = self.private();
        priv.tokens = .empty;

        // Listen for any changes to our expression.
        _ = gobject.Object.signals.notify.connect(
            self,
            ?*anyopaque,
            propSearch,
            null,
            .{
                .detail = "expression",
            },
        );

        // Listen for any changes to our search text.
        _ = gobject.Object.signals.notify.connect(
            self,
            ?*anyopaque,
            propSearch,
            null,
            .{
                .detail = "search",
            },
        );
    }

    fn dispose(self: *Self) callconv(.c) void {
        const priv = self.private();

        if (priv.expression) |expression| {
            expression.unref();
            priv.expression = null;
        }

        gobject.Object.virtual_methods.dispose.call(
            Class.parent,
            self.as(Parent),
        );
    }

    fn finalize(self: *Self) callconv(.c) void {
        const alloc = Application.default().allocator();
        const priv = self.private();

        if (priv.search) |search| {
            glib.free(@constCast(@ptrCast(search)));
            priv.search = null;
        }

        for (priv.tokens.items) |token| alloc.free(token);
        priv.tokens.deinit(alloc);

        gobject.Object.virtual_methods.finalize.call(
            Class.parent,
            self.as(Parent),
        );
    }

    //---------------------------------------------------------------

    fn getExpression(self: *Self, value: *gobject.Value) void {
        const priv = self.private();
        const expression = priv.expression orelse {
            value.setObject(null);
            return;
        };
        gtk.valueSetExpression(value, expression);
    }

    fn setExpression(self: *Self, value: *const gobject.Value) void {
        const priv = self.private();
        if (priv.expression) |v| {
            v.unref();
            priv.expression = null;
        }
        const expression = gtk.valueGetExpression(value) orelse {
            log.warn("unable to get  expression", .{});
            return;
        };
        if (expression.getValueType() != gobject.ext.types.string) return;
        priv.expression = expression.ref();
        self.emitChanged();
    }

    fn emitChanged(self: *Self) void {
        gobject.signalEmitByName(self.as(gobject.Object), "changed");
    }

    fn propSearch(self: *Self, _: *gobject.ParamSpec, _: ?*anyopaque) callconv(.c) void {
        const alloc = Application.default().allocator();
        const priv = self.private();

        for (priv.tokens.items) |token| alloc.free(token);

        priv.tokens.clearRetainingCapacity();

        if (priv.search) |search| {
            var it = std.mem.tokenizeScalar(u8, search, ' ');
            while (it.next()) |token| {
                const lower = std.ascii.allocLowerString(alloc, token) catch continue;
                priv.tokens.append(alloc, lower) catch continue;
                log.warn("token: {s}", .{lower});
            }
        }

        self.emitChanged();
    }

    //---------------------------------------------------------------

    fn match(self: *Self, item_: ?*gobject.Object) callconv(.c) c_int {
        log.warn("match start", .{});
        const item = item_ orelse return @intFromBool(false);
        const priv = self.private();
        const expression = priv.expression orelse {
            log.warn("match: no expression", .{});
            return @intFromBool(false);
        };
        if (priv.tokens.items.len == 0) return @intFromBool(true);

        var value = gobject.ext.Value.zero;
        defer value.unset();
        _ = value.init(gobject.ext.types.string);

        if (expression.evaluate(item, &value) == 0) return @intFromBool(false);
        if (!ext.gValueHolds(&value, gobject.ext.types.string)) return @intFromBool(false);

        const string = std.mem.span(value.getString() orelse return @intFromBool(false));

        const rank = zf.rank(string, priv.tokens.items, .{
            .to_lower = true,
            .plain = true,
        }) orelse {
            log.warn("match: {s} null", .{string});
            return @intFromBool(false);
        };

        log.warn("match: {s} {d}", .{ string, rank });

        return @intFromBool(true);
    }

    //---------------------------------------------------------------

    const C = Common(Self, Private);
    pub const as = C.as;
    pub const ref = C.ref;
    pub const unref = C.unref;
    const private = C.private;

    pub const Class = extern struct {
        parent_class: Parent.Class,
        var parent: *Parent.Class = undefined;
        pub const Instance = Self;

        fn init(class: *Class) callconv(.c) void {
            log.warn("ZF class init", .{});
            gobject.ext.registerProperties(class, &.{
                properties.expression.impl,
                properties.search.impl,
            });

            log.warn("ZF class init 2", .{});
            gtk.Filter.virtual_methods.match.implement(class, &match);
            gobject.Object.virtual_methods.dispose.implement(class, &dispose);
            gobject.Object.virtual_methods.finalize.implement(class, &finalize);
        }
    };
};
