const std = @import("std");
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;

const adw = @import("adw");
const gio = @import("gio");
const glib = @import("glib");
const gobject = @import("gobject");
const gtk = @import("gtk");

const input = @import("../../../input.zig");
const gresource = @import("../build/gresource.zig");
const key = @import("../key.zig");
const Common = @import("../class.zig").Common;
const Application = @import("application.zig").Application;
const Window = @import("window.zig").Window;
const Surface = @import("surface.zig").Surface;
const ApprtSurface = @import("../Surface.zig");
const Config = @import("config.zig").Config;
const ZFSearchFilter = @import("zf_search_filter.zig").ZFSearchFilter;

const log = std.log.scoped(.gtk_ghostty_command_palette);

pub const CommandPalette = extern struct {
    const Self = @This();
    parent_instance: Parent,
    pub const Parent = adw.Bin;
    pub const getGObjectType = gobject.ext.defineClass(Self, .{
        .name = "GhosttyCommandPalette",
        .instanceInit = &init,
        .classInit = &Class.init,
        .parent_class = &Class.parent,
        .private = .{ .Type = Private, .offset = &Private.offset },
    });

    pub const properties = struct {
        pub const config = struct {
            pub const name = "config";
            const impl = gobject.ext.defineProperty(
                name,
                Self,
                ?*Config,
                .{
                    .accessor = C.privateObjFieldAccessor("config"),
                },
            );
        };
    };

    pub const signals = struct {
        /// Emitted when a command from the command palette is activated. The
        /// action contains pointers to allocated data so if a receiver of this
        /// signal needs to keep the action around it will need to clone the
        /// action or there may be use-after-free errors.
        pub const trigger = struct {
            pub const name = "trigger";
            pub const connect = impl.connect;
            const impl = gobject.ext.defineSignal(
                name,
                Self,
                &.{*const input.Binding.Action},
                void,
            );
        };
    };

    const Private = struct {
        /// The configuration that this command palette is using.
        config: ?*Config = null,

        /// The dialog object containing the palette UI.
        dialog: *adw.Dialog,

        /// The search input text field.
        search: *gtk.SearchEntry,

        /// The view containing each result row.
        view: *gtk.ListView,

        /// The model that provides filtered data for the view to display.
        model: *gtk.SingleSelection,

        /// The list that serves as the data source of the model.
        /// This is where all command data is ultimately stored.
        source: *gio.ListStore,

        /// The idle handler.
        idler: ?c_uint = null,

        pub var offset: c_int = 0;
    };

    /// Create a new instance of the command palette. The caller will own a
    /// reference to the object.
    pub fn new() *Self {
        const self = gobject.ext.newInstance(Self, .{});

        // Sink ourselves so that we aren't floating anymore. We'll unref
        // ourselves when the palette is closed or an action is activated.
        _ = self.refSink();

        // Bump the ref so that the caller has a reference.
        return self.ref();
    }

    //---------------------------------------------------------------
    // Virtual Methods

    fn init(self: *Self, _: *Class) callconv(.c) void {
        gtk.Widget.initTemplate(self.as(gtk.Widget));

        // Listen for any changes to our config.
        _ = gobject.Object.signals.notify.connect(
            self,
            ?*anyopaque,
            propConfig,
            null,
            .{
                .detail = "config",
            },
        );

        // Listen for when additions/removals from the list of active surfaces
        // happen.
        _ = Application.signals.@"surfaces-changed".connect(
            Application.default(),
            *Self,
            signalSurfacesChanged,
            self,
            .{},
        );
    }

    fn dispose(self: *Self) callconv(.c) void {
        const app = Application.default();
        _ = gobject.signalHandlersDisconnectMatched(
            app.as(gobject.Object),
            .{ .data = true },
            0,
            0,
            null,
            null,
            self,
        );

        const priv = self.private();

        if (priv.idler) |idler| {
            if (glib.Source.remove(idler) == 0) {
                log.warn("unable to remove command palette updater", .{});
            }
            priv.idler = null;
        }

        priv.source.removeAll();

        if (priv.config) |config| {
            config.unref();
            priv.config = null;
        }

        gtk.Widget.disposeTemplate(
            self.as(gtk.Widget),
            getGObjectType(),
        );

        gobject.Object.virtual_methods.dispose.call(
            Class.parent,
            self.as(Parent),
        );
    }

    //---------------------------------------------------------------
    // Signal Handlers

    /// Update the commands when the config changes.
    fn propConfig(self: *CommandPalette, _: *gobject.ParamSpec, _: ?*anyopaque) callconv(.c) void {
        self.scheduleUpdateList();
    }

    /// Update the commands when the list of active surfaces changes.
    fn signalSurfacesChanged(_: *Application, self: *CommandPalette) callconv(.c) void {
        self.scheduleUpdateList();
    }

    fn scheduleUpdateList(self: *CommandPalette) void {
        const priv = self.private();
        if (priv.idler) |_| return;
        priv.idler = glib.idleAdd(updateList, self);
    }

    fn updateList(ud: ?*anyopaque) callconv(.c) c_int {
        const self: *Self = @ptrCast(@alignCast(ud orelse return @intFromBool(glib.SOURCE_REMOVE)));

        const priv = self.private();

        priv.idler = null;

        const config = priv.config orelse {
            log.warn("command palette does not have a config!", .{});
            return @intFromBool(glib.SOURCE_REMOVE);
        };

        const cfg = config.get();

        // Clear existing binds
        priv.source.removeAll();

        for (cfg.@"command-palette-entry".value.items) |command| {
            // Filter out actions that are not implemented or don't make sense
            // for GTK.
            switch (command.action) {
                .close_all_windows,
                .toggle_secure_input,
                .check_for_updates,
                .redo,
                .undo,
                .reset_window_size,
                .toggle_window_float_on_top,
                => continue,

                else => {},
            }

            const cmd = Command.newFromCommand(config, command) catch continue;
            priv.source.append(cmd.as(gobject.Object));
            cmd.unref();
        }

        const app = Application.default();

        for (app.core().surfaces.items) |surface| {
            const cmd = Command.newFromSurface(config, surface) catch continue;
            priv.source.append(cmd.as(gobject.Object));
            cmd.unref();
        }

        return @intFromBool(glib.SOURCE_REMOVE);
    }

    fn close(self: *CommandPalette) void {
        const priv = self.private();
        _ = priv.dialog.close();
    }

    fn dialogClosed(_: *adw.Dialog, self: *CommandPalette) callconv(.c) void {
        self.unref();
    }

    fn searchStopped(_: *gtk.SearchEntry, self: *CommandPalette) callconv(.c) void {
        // ESC was pressed - close the palette
        self.close();
    }

    fn searchActivated(_: *gtk.SearchEntry, self: *CommandPalette) callconv(.c) void {
        // If Enter is pressed, activate the selected entry
        const priv = self.private();
        self.activated(priv.model.getSelected());
    }

    fn rowActivated(_: *gtk.ListView, pos: c_uint, self: *CommandPalette) callconv(.c) void {
        self.activated(pos);
    }

    fn getSubtitle(_: *CommandPalette, action_string_: ?[*:0]const u8, description_: ?[*:0]const u8) callconv(.c) ?[*:0]const u8 {
        const action_string = action_string_ orelse return null;
        if (std.mem.startsWith(u8, std.mem.span(action_string), "present_surface:")) {
            const description = description_ orelse return null;
            return glib.ext.dupeZ(u8, std.mem.span(description));
        }
        return glib.ext.dupeZ(u8, std.mem.span(action_string));
    }

    fn getIconName(_: *CommandPalette, action_string_: ?[*:0]const u8) callconv(.c) ?[*:0]const u8 {
        const action_string = action_string_ orelse return null;
        if (std.mem.startsWith(u8, std.mem.span(action_string), "present_surface:")) {
            return glib.ext.dupeZ(u8, "utilities-terminal-symbolic");
        }
        return glib.ext.dupeZ(u8, "system-run-symbolic");
    }

    //---------------------------------------------------------------

    /// Show or hide the command palette dialog. If the dialog is shown it will
    /// be modal over the given window.
    pub fn toggle(self: *CommandPalette, window: *Window) void {
        const priv = self.private();

        // If the dialog has been shown, close it.
        if (priv.dialog.as(gtk.Widget).getRealized() != 0) {
            self.close();
            return;
        }

        // Show the dialog
        priv.dialog.present(window.as(gtk.Widget));

        // Focus on the search bar when opening the dialog
        _ = priv.search.as(gtk.Widget).grabFocus();
    }

    /// Helper function to send a signal containing the action that should be
    /// performed.
    fn activated(self: *CommandPalette, pos: c_uint) void {
        const priv = self.private();

        // Use priv.model and not priv.source here to use the list of *visible* results
        const object_ = priv.model.as(gio.ListModel).getObject(pos);
        defer if (object_) |object| object.unref();

        // Close before running the action in order to avoid being replaced by
        // another dialog (such as the change title dialog). If that occurs then
        // the command palette dialog won't be counted as having closed properly
        // and cannot receive focus when reopened.
        self.close();

        const cmd = gobject.ext.cast(Command, object_ orelse return) orelse return;
        const action = cmd.getAction() orelse return;

        // Signal that an an action has been selected. Signals are synchronous
        // so we shouldn't need to worry about cloning the action.
        signals.trigger.impl.emit(
            self,
            null,
            .{&action},
            null,
        );
    }

    const C = Common(Self, Private);
    pub const as = C.as;
    pub const ref = C.ref;
    pub const refSink = C.refSink;
    pub const unref = C.unref;
    const private = C.private;

    pub const Class = extern struct {
        parent_class: Parent.Class,
        var parent: *Parent.Class = undefined;
        pub const Instance = Self;

        fn init(class: *Class) callconv(.c) void {
            gobject.ext.ensureType(Command);
            gobject.ext.ensureType(ZFSearchFilter);
            gtk.Widget.Class.setTemplateFromResource(
                class.as(gtk.Widget.Class),
                comptime gresource.blueprint(.{
                    .major = 1,
                    .minor = 5,
                    .name = "command-palette",
                }),
            );

            // Bindings
            class.bindTemplateChildPrivate("dialog", .{});
            class.bindTemplateChildPrivate("search", .{});
            class.bindTemplateChildPrivate("view", .{});
            class.bindTemplateChildPrivate("model", .{});
            class.bindTemplateChildPrivate("source", .{});

            // Template Callbacks
            class.bindTemplateCallback("closed", &dialogClosed);
            class.bindTemplateCallback("notify_config", &propConfig);
            class.bindTemplateCallback("search_stopped", &searchStopped);
            class.bindTemplateCallback("search_activated", &searchActivated);
            class.bindTemplateCallback("row_activated", &rowActivated);
            class.bindTemplateCallback("get_subtitle", &getSubtitle);
            class.bindTemplateCallback("get_icon_name", &getIconName);

            // Properties
            gobject.ext.registerProperties(class, &.{
                properties.config.impl,
            });

            // Signals
            signals.trigger.impl.register(.{});

            // Virtual methods
            gobject.Object.virtual_methods.dispose.implement(class, &dispose);
        }

        pub const as = C.Class.as;
        pub const bindTemplateChildPrivate = C.Class.bindTemplateChildPrivate;
        pub const bindTemplateCallback = C.Class.bindTemplateCallback;
    };
};

/// Object that wraps around a command.
///
/// As GTK list models only accept objects that are within the GObject hierarchy,
/// we have to construct a wrapper to be easily consumed by the list model.
const Command = extern struct {
    pub const Self = @This();
    pub const Parent = gobject.Object;
    parent: Parent,

    pub const getGObjectType = gobject.ext.defineClass(Self, .{
        .name = "GhosttyCommand",
        .instanceInit = &init,
        .classInit = Class.init,
        .parent_class = &Class.parent,
        .private = .{ .Type = Private, .offset = &Private.offset },
    });

    const properties = struct {
        pub const config = struct {
            pub const name = "config";
            const impl = gobject.ext.defineProperty(
                name,
                Self,
                ?*Config,
                .{
                    .accessor = C.privateObjFieldAccessor("config"),
                },
            );
        };

        pub const @"action-keybind" = struct {
            pub const name = "action-keybind";
            const impl = gobject.ext.defineProperty(
                name,
                Self,
                ?[:0]const u8,
                .{
                    .default = null,
                    .accessor = C.privateStringFieldAccessor("action_keybind"),
                },
            );
        };

        pub const @"action-string" = struct {
            pub const name = "action-string";
            const impl = gobject.ext.defineProperty(
                name,
                Self,
                ?[:0]const u8,
                .{
                    .default = null,
                    .accessor = C.privateStringFieldAccessor("action_string"),
                },
            );
        };

        pub const title = struct {
            pub const name = "title";
            const impl = gobject.ext.defineProperty(
                name,
                Self,
                ?[:0]const u8,
                .{
                    .default = null,
                    .accessor = C.privateStringFieldAccessor("title"),
                },
            );
        };

        pub const description = struct {
            pub const name = "description";
            const impl = gobject.ext.defineProperty(
                name,
                Self,
                ?[:0]const u8,
                .{
                    .default = null,
                    .accessor = C.privateStringFieldAccessor("description"),
                },
            );
        };
    };

    pub const Private = struct {
        /// The configuration we should use to get keybindings.
        config: ?*Config = null,

        /// Arena used to manage our allocations.
        arena: ArenaAllocator,

        /// The action.
        action: ?input.Binding.Action = null,

        /// Title for the action.
        title: ?[:0]const u8 = null,

        /// Description for the action.
        description: ?[:0]const u8 = null,

        /// The formatted action.
        action_string: ?[:0]const u8 = null,

        /// The formatted keybind.
        action_keybind: ?[:0]const u8 = null,

        pub var offset: c_int = 0;
    };

    pub fn newFromCommand(
        config: *Config,
        command: input.Command,
    ) (Allocator.Error || error{NoSpaceLeft})!*Self {
        const cfg = config.get();
        const keybinds = cfg.keybind.set;

        var action_string_buf: [256]u8 = undefined;
        const action_string = try std.fmt.bufPrintZ(
            &action_string_buf,
            "{}",
            .{command.action},
        );

        var action_keybind_buf: [256]u8 = undefined;
        const action_keybind = action_keybind: {
            const trigger = keybinds.getTrigger(command.action) orelse break :action_keybind null;
            const accel = (key.accelFromTrigger(&action_keybind_buf, trigger) catch break :action_keybind null) orelse break :action_keybind null;
            break :action_keybind accel;
        };

        const self = gobject.ext.newInstance(Self, .{
            .config = config,
            .title = command.title,
            .description = command.description,
            .@"action-string" = action_string,
            .@"action-keybind" = action_keybind,
        });
        errdefer self.unref();

        const priv = self.private();
        const alloc = priv.arena.allocator();

        priv.action = try command.action.clone(alloc);

        return self;
    }

    pub fn newFromSurface(
        config: *Config,
        surface: *ApprtSurface,
    ) error{NoSpaceLeft}!*Self {
        const action: input.Binding.Action = .{
            .present_surface = surface.core().id,
        };

        var action_string_buf: [256]u8 = undefined;
        const action_string = try std.fmt.bufPrintZ(
            &action_string_buf,
            "{}",
            .{action},
        );

        const self = gobject.ext.newInstance(Self, .{
            .config = config,
            .@"action-string" = action_string,
        });
        errdefer self.unref();

        const priv = self.private();
        priv.action = action;

        _ = gobject.Object.bindProperty(
            surface.gobj().as(gobject.Object),
            "title",
            self.as(gobject.Object),
            "title",
            .{ .sync_create = true },
        );

        _ = gobject.Object.bindProperty(
            surface.gobj().as(gobject.Object),
            "pwd",
            self.as(gobject.Object),
            "description",
            .{ .sync_create = true },
        );

        return self;
    }

    pub fn getSubtitle(self: *Command) ?[*:0]const u8 {
        const priv = self.private();
        const action = priv.action orelse return null;
        switch (action) {
            .present_surface => {
                return glib.ext.dupeZ(u8, priv.description orelse return null);
            },
            else => {
                return glib.ext.dupeZ(u8, priv.action_string orelse return null);
            },
        }
    }

    fn init(self: *Self, _: *Class) callconv(.c) void {
        // NOTE: we do not watch for changes to the config here as the command
        // palette will destroy and recreate this object if/when the config
        // changes.

        const priv = self.private();
        priv.arena = .init(Application.default().allocator());
    }

    fn dispose(self: *Self) callconv(.c) void {
        const priv = self.private();

        if (priv.config) |config| {
            config.unref();
            priv.config = null;
        }

        gobject.Object.virtual_methods.dispose.call(
            Class.parent,
            self.as(Parent),
        );
    }

    fn finalize(self: *Self) callconv(.c) void {
        const priv = self.private();

        priv.arena.deinit();

        gobject.Object.virtual_methods.finalize.call(
            Class.parent,
            self.as(Parent),
        );
    }

    //---------------------------------------------------------------

    /// Return a copy of the action. Callers must ensure that they do not use
    /// the action beyond the lifetime of this object because it has internally
    /// allocated data that will be freed when this object is.
    pub fn getAction(self: *Self) ?input.Binding.Action {
        const priv = self.private();
        return priv.action;
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
                properties.config.impl,
                properties.@"action-keybind".impl,
                properties.@"action-string".impl,
                properties.title.impl,
                properties.description.impl,
            });

            gobject.Object.virtual_methods.dispose.implement(class, &dispose);
            gobject.Object.virtual_methods.finalize.implement(class, &finalize);
        }
    };
};
