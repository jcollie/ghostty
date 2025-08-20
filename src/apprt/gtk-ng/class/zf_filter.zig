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

            const impl = ext.defineExpressionProperty(
                name,
                Self,
                .{
                    .accessor = .{
                        .getter = getExpression,
                        .setter = setExpression,
                    },
                },
            );
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
        const priv = self.private();
        priv.tokens = .empty;

        // // Listen for any changes to our expression.
        // _ = gobject.Object.signals.notify.connect(
        //     self,
        //     ?*anyopaque,
        //     propSearch,
        //     null,
        //     .{
        //         .detail = "expression",
        //     },
        // );

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

    fn getExpression(self: *Self) ?*gtk.Expression {
        const priv = self.private();
        return priv.expression;
    }

    fn setExpression(self: *Self, value: ?*gtk.Expression) void {
        const priv = self.private();

        if (priv.expression) |old| {
            old.unref();
            priv.expression = null;
        }

        const new = value orelse return;

        if (new.getValueType() != gobject.ext.types.string) return;

        priv.expression = new.ref();

        self.emitChanged();
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
            }
        }

        self.emitChanged();
    }

    //---------------------------------------------------------------

    fn emitChanged(self: *Self) void {
        gobject.signalEmitByName(self.as(gobject.Object), "changed");
    }

    fn match(self: *Self, item_: ?*gobject.Object) callconv(.c) c_int {
        const item = item_ orelse return @intFromBool(false);

        const priv = self.private();
        const expression = priv.expression orelse return @intFromBool(false);

        if (priv.tokens.items.len == 0) return @intFromBool(true);

        var value = gobject.ext.Value.zero;
        defer value.unset();
        _ = value.init(gobject.ext.types.string);

        if (expression.evaluate(item, &value) == 0) return @intFromBool(false);
        if (!ext.gValueHolds(&value, gobject.ext.types.string)) return @intFromBool(false);

        const string = std.mem.span(value.getString() orelse return @intFromBool(false));

        _ = zf.rank(
            string,
            priv.tokens.items,
            .{
                .to_lower = true,
                .plain = true,
            },
        ) orelse {
            return @intFromBool(false);
        };

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
            gobject.ext.registerProperties(class, &.{
                properties.expression.impl,
                properties.search.impl,
            });

            gtk.Filter.virtual_methods.match.implement(class, &match);
            gobject.Object.virtual_methods.dispose.implement(class, &dispose);
            gobject.Object.virtual_methods.finalize.implement(class, &finalize);
        }
    };
};
