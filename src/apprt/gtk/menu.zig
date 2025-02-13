const std = @import("std");

const c = @import("c.zig").c;
const apprt = @import("../../apprt.zig");
const App = @import("App.zig");
const Window = @import("Window.zig");
const Surface = @import("Surface.zig");
const Builder = @import("Builder.zig");

const gtk = @import("gtk");
const gdk = @import("gdk");
const gio = @import("gio");
const gobject = @import("gobject");

const log = std.log.scoped(.gtk_menu);

pub fn Menu(
    comptime T: type,
    comptime variant: []const u8,
    comptime style: enum { popover_menu, popover_menu_no_arrow, popover_menu_bar },
) type {
    return struct {
        const Self = @This();
        const MenuWidget = switch (style) {
            .popover_menu => gtk.PopoverMenu,
            .popover_menu_no_arrow => gtk.PopoverMenu,
            .popover_menu_bar => gtk.PopoverMenuBar,
        };

        parent: *T,
        menu_widget: *MenuWidget,

        pub fn init(self: *Self) void {
            const name = switch (T) {
                Window => "window",
                Surface => "surface",
                else => unreachable,
            };
            const parent: *T = @alignCast(@fieldParentPtr(variant, self));

            var builder = Builder.init("menu-" ++ name ++ "-" ++ variant, .ui);
            defer builder.deinit();

            const object = builder.getObject("menu") orelse unreachable;
            const menu_model: *gio.MenuModel = @ptrCast(@alignCast(object));

            const menu_widget: *MenuWidget = switch (style) {
                .popover_menu, .popover_menu_no_arrow => brk: {
                    const menu_widget: *MenuWidget = MenuWidget.newFromModelFull(menu_model, .{ .nested = true });
                    if (style == .popover_menu_no_arrow) {
                        menu_widget.as(gtk.Popover).setHasArrow(0);
                    }
                    _ = gtk.Popover.signals.closed.connect(
                        menu_widget,
                        *Self,
                        gtkRefocusTerm,
                        self,
                        .{},
                    );
                    break :brk menu_widget;
                },
                .popover_menu_bar => brk: {
                    break :brk gtk.PopoverMenuBar.newFromModel(menu_model);
                },
            };

            self.* = .{
                .parent = parent,
                .menu_widget = menu_widget,
            };
        }

        pub fn setParent(self: *const Self, widget: *c.GtkWidget) void {
            self.menu_widget.as(gtk.Widget).setParent(@ptrCast(@alignCast(widget)));
        }

        pub fn asWidget(self: *const Self) *c.GtkWidget {
            return @ptrCast(@alignCast(self.menu_widget));
        }

        pub fn isVisible(self: *const Self) bool {
            return self.menu_widget.as(gtk.Widget).getVisible() != 0;
        }

        pub fn setVisible(self: *const Self, visible: bool) void {
            self.menu_widget.as(gtk.Widget).setVisible(@intFromBool(visible));
        }

        pub fn refresh(self: *const Self) void {
            const window: *gtk.Window, const has_selection: bool = switch (T) {
                Window => window: {
                    const core_surface = self.parent.actionSurface() orelse break :window .{
                        @ptrCast(@alignCast(self.parent.window)),
                        false,
                    };
                    const has_selection = core_surface.hasSelection();
                    break :window .{ @ptrCast(@alignCast(self.parent.window)), has_selection };
                },
                Surface => surface: {
                    const window = self.parent.container.window() orelse return;
                    const has_selection = self.parent.core_surface.hasSelection();
                    break :surface .{ @ptrCast(@alignCast(window.window)), has_selection };
                },
                else => unreachable,
            };

            const action_map: *gio.ActionMap = @ptrCast(@alignCast(window));
            const action: *gio.SimpleAction = @ptrCast(@alignCast(action_map.lookupAction("copy") orelse return));
            action.setEnabled(@intFromBool(has_selection));
        }

        pub fn popupAt(self: *const Self, x: f64, y: f64) void {
            const rect: gdk.Rectangle = .{
                .f_x = @intFromFloat(x),
                .f_y = @intFromFloat(y),
                .f_width = 1,
                .f_height = 1,
            };
            const popover = self.menu_widget.as(gtk.Popover);
            popover.setPointingTo(&rect);
            self.refresh();
            popover.popup();
        }

        /// refocus tab that lost focus because of the popover menu
        fn gtkRefocusTerm(_: *MenuWidget, self: *Self) callconv(.C) void {
            const window: *Window = switch (T) {
                Window => self.parent,
                Surface => self.parent.container.window() orelse return,
                else => unreachable,
            };

            window.focusCurrentTab();
        }
    };
}
