/// Clipboard Confirmation Window
const ClipboardConfirmation = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;

const apprt = @import("../../apprt.zig");
const CoreSurface = @import("../../Surface.zig");
const App = @import("App.zig");
const View = @import("View.zig");
const c = @import("c.zig").c;

const log = std.log.scoped(.gtk_clipboard);

app: *App,
core_surface: *CoreSurface,
data: [:0]u8,
request: apprt.ClipboardRequest,
secure_input: bool,
window: *c.GtkWindow,
overlay: *c.GtkOverlay,
nsfw: ?*c.GtkWidget = null,

pub fn create(
    app: *App,
    data: []const u8,
    core_surface: *CoreSurface,
    request: apprt.ClipboardRequest,
    secure_input: bool,
) !void {
    if (app.clipboard_confirmation_window != null) return error.WindowAlreadyExists;

    const alloc = app.core_app.alloc;
    const self = try alloc.create(ClipboardConfirmation);
    errdefer alloc.destroy(self);

    try self.init(
        app,
        data,
        core_surface,
        request,
        secure_input,
    );

    app.clipboard_confirmation_window = self;
}

/// Not public because this should be called by the GTK lifecycle.
fn destroy(self: *ClipboardConfirmation) void {
    const alloc = self.app.core_app.alloc;
    self.app.clipboard_confirmation_window = null;
    alloc.free(self.data);
    alloc.destroy(self);
}

fn init(
    self: *ClipboardConfirmation,
    app: *App,
    data: []const u8,
    core_surface: *CoreSurface,
    request: apprt.ClipboardRequest,
    secure_input: bool,
) !void {
    const builder = c.gtk_builder_new_from_file("/home/jeff/paste.ui");
    defer c.g_object_unref(builder);

    const gtk_window: *c.GtkWindow = @ptrCast(c.gtk_builder_get_object(builder, "window"));
    const window: *c.GtkWidget = @ptrCast(gtk_window);
    errdefer c.gtk_window_destroy(gtk_window);
    c.gtk_window_set_title(gtk_window, titleText(request));

    _ = c.g_signal_connect_data(
        window,
        "destroy",
        c.G_CALLBACK(&gtkDestroy),
        self,
        null,
        c.G_CONNECT_DEFAULT,
    );

    const overlay: *c.GtkOverlay = @ptrCast(c.gtk_builder_get_object(builder, "overlay"));

    // Set some state
    self.* = .{
        .app = app,
        .core_surface = core_surface,
        .data = try app.core_app.alloc.dupeZ(u8, data),
        .request = request,
        .secure_input = secure_input,
        .window = gtk_window,
        .overlay = overlay,
    };

    const gesture_click = c.gtk_gesture_click_new();
    errdefer c.g_object_unref(gesture_click);
    c.gtk_gesture_single_set_button(@ptrCast(gesture_click), 0);
    c.gtk_widget_add_controller(@ptrCast(@alignCast(overlay)), @ptrCast(@alignCast(gesture_click)));
    _ = c.g_signal_connect_data(
        gesture_click,
        "pressed",
        c.G_CALLBACK(&gtkMouseDown),
        self,
        null,
        c.G_CONNECT_DEFAULT,
    );
    _ = c.g_signal_connect_data(
        gesture_click,
        "released",
        c.G_CALLBACK(&gtkMouseUp),
        self,
        null,
        c.G_CONNECT_DEFAULT,
    );

    const prompt_label: *c.GtkLabel = @ptrCast(c.gtk_builder_get_object(builder, "prompt"));
    c.gtk_label_set_text(prompt_label, promptText(request));

    const text: *c.GtkTextView = @ptrCast(c.gtk_builder_get_object(builder, "text"));
    const buf = unsafeBuffer(self.data);
    c.gtk_text_view_set_buffer(text, buf);

    const cancel_text, const confirm_text = switch (request) {
        .paste => .{ "Cancel", "Paste" },
        .osc_52_read, .osc_52_write => .{ "Deny", "Allow" },
    };

    const cancel_button: *c.GtkButton = @ptrCast(c.gtk_builder_get_object(builder, "cancel"));
    c.gtk_button_set_label(cancel_button, cancel_text);
    _ = c.g_signal_connect_data(
        cancel_button,
        "clicked",
        c.G_CALLBACK(&gtkCancelClick),
        self,
        null,
        c.G_CONNECT_DEFAULT,
    );

    const confirm_button: *c.GtkButton = @ptrCast(c.gtk_builder_get_object(builder, "confirm"));
    c.gtk_button_set_label(confirm_button, confirm_text);
    _ = c.g_signal_connect_data(
        confirm_button,
        "clicked",
        c.G_CALLBACK(&gtkConfirmClick),
        self,
        null,
        c.G_CONNECT_DEFAULT,
    );

    // _ = c.gtk_widget_grab_focus(view.buttons.cancel_button);

    if (self.secure_input) self.addNSFW();

    c.gtk_widget_show(window);

    // Block the main window from input.
    // This will auto-revert when the window is closed.
    // c.gtk_window_set_modal(gtk_window, 1);
}

pub fn addNSFW(self: *ClipboardConfirmation) void {
    if (self.nsfw) |_| return;

    const nsfw_label = c.gtk_label_new("The clipboard may contain sensitive data. Click to reveal.");
    c.gtk_label_set_wrap(@ptrCast(nsfw_label), 1);
    c.gtk_widget_set_valign(nsfw_label, c.GTK_ALIGN_CENTER);
    c.gtk_widget_set_vexpand(nsfw_label, 1);
    c.gtk_widget_set_size_request(nsfw_label, -1, 200);
    c.gtk_widget_add_css_class(nsfw_label, "view");

    c.gtk_overlay_add_overlay(self.overlay, nsfw_label);
    c.gtk_overlay_set_measure_overlay(self.overlay, nsfw_label, 0);
    self.nsfw = nsfw_label;
}

pub fn removeNSFW(self: *ClipboardConfirmation) void {
    const nsfw = self.nsfw orelse return;
    c.gtk_overlay_remove_overlay(self.overlay, nsfw);
    self.nsfw = null;
}

pub fn toggleNSFW(self: *ClipboardConfirmation) void {
    if (self.nsfw) |_| return self.removeNSFW();
    return self.addNSFW();
}

/// Returns the GtkTextBuffer for the data that was unsafe.
fn unsafeBuffer(data: []const u8) *c.GtkTextBuffer {
    const buf = c.gtk_text_buffer_new(null);
    errdefer c.g_object_unref(buf);

    c.gtk_text_buffer_insert_at_cursor(buf, data.ptr, @intCast(data.len));

    return buf;
}

fn gtkDestroy(_: *c.GtkWidget, ud: ?*anyopaque) callconv(.C) void {
    const self: *ClipboardConfirmation = @ptrCast(@alignCast(ud orelse return));
    log.warn("destroy!", .{});
    self.destroy();
}

fn gtkCancelClick(_: *c.GtkWidget, ud: ?*anyopaque) callconv(.C) void {
    const self: *ClipboardConfirmation = @ptrCast(@alignCast(ud));
    c.gtk_window_destroy(@ptrCast(self.window));
}

fn gtkConfirmClick(_: *c.GtkWidget, ud: ?*anyopaque) callconv(.C) void {
    // Requeue the paste with force.
    const self: *ClipboardConfirmation = @ptrCast(@alignCast(ud));
    self.core_surface.completeClipboardRequest(
        self.request,
        self.data,
        true,
    ) catch |err| {
        std.log.err("Failed to requeue clipboard request: {}", .{err});
    };

    c.gtk_window_destroy(@ptrCast(self.window));
}

const PrimaryView = struct {
    root: *c.GtkWidget,
    text: *c.GtkTextView,
    overlay: *c.GtkOverlay,
    nsfw: ?*c.GtkWidget = null,
    buttons: ButtonsView,

    pub fn init(root: *ClipboardConfirmation, data: []const u8) !PrimaryView {
        // All our widgets
        const label = c.gtk_label_new(promptText(root.request));
        const buf = unsafeBuffer(data);
        defer c.g_object_unref(buf);
        const buttons = try ButtonsView.init(root);

        const overlay = c.gtk_overlay_new();
        c.gtk_widget_set_focusable(@ptrCast(overlay), 0);
        c.gtk_widget_set_focus_on_click(@ptrCast(overlay), 0);

        const gesture_click = c.gtk_gesture_click_new();
        errdefer c.g_object_unref(gesture_click);
        c.gtk_gesture_single_set_button(@ptrCast(gesture_click), 0);
        c.gtk_widget_add_controller(@ptrCast(@alignCast(overlay)), @ptrCast(gesture_click));
        _ = c.g_signal_connect_data(gesture_click, "pressed", c.G_CALLBACK(&gtkMouseDown), root, null, c.G_CONNECT_DEFAULT);
        _ = c.g_signal_connect_data(gesture_click, "released", c.G_CALLBACK(&gtkMouseUp), root, null, c.G_CONNECT_DEFAULT);

        const text_scroll = c.gtk_scrolled_window_new();
        errdefer c.g_object_unref(text_scroll);
        const text = c.gtk_text_view_new_with_buffer(buf);
        errdefer c.g_object_unref(text);
        c.gtk_scrolled_window_set_child(@ptrCast(text_scroll), text);

        c.gtk_overlay_set_child(@ptrCast(overlay), text_scroll);

        // Create our view
        const view = try View.init(&.{
            .{ .name = "label", .widget = label },
            .{ .name = "text", .widget = overlay },
            .{ .name = "buttons", .widget = buttons.root },
        }, &vfl);
        errdefer view.deinit();

        // We can do additional settings once the layout is setup
        c.gtk_label_set_wrap(@ptrCast(label), 1);
        c.gtk_text_view_set_editable(@ptrCast(text), 0);
        c.gtk_text_view_set_cursor_visible(@ptrCast(text), 0);
        c.gtk_text_view_set_top_margin(@ptrCast(text), 8);
        c.gtk_text_view_set_bottom_margin(@ptrCast(text), 8);
        c.gtk_text_view_set_left_margin(@ptrCast(text), 8);
        c.gtk_text_view_set_right_margin(@ptrCast(text), 8);
        c.gtk_text_view_set_monospace(@ptrCast(text), 1);

        return .{
            .root = view.root,
            .text = @ptrCast(text),
            .buttons = buttons,
            .overlay = @ptrCast(overlay),
        };
    }

    const vfl = [_][*:0]const u8{
        "H:|-8-[label]-8-|",
        "H:|[text]|",
        "H:|[buttons]|",
        "V:|[label(<=80)][text(>=100)]-[buttons]-|",
    };
};

fn gtkMouseDown(
    gesture: *c.GtkGestureClick,
    _: c.gint,
    _: c.gdouble,
    _: c.gdouble,
    ud: ?*anyopaque,
) callconv(.C) void {
    _ = c.gtk_event_controller_get_current_event(@ptrCast(gesture)) orelse return;

    const self: *ClipboardConfirmation = @ptrCast(@alignCast(ud orelse return));
    _ = self;

    log.info("mouse down", .{});
}

fn gtkMouseUp(
    gesture: *c.GtkGestureClick,
    _: c.gint,
    _: c.gdouble,
    _: c.gdouble,
    ud: ?*anyopaque,
) callconv(.C) void {
    _ = c.gtk_event_controller_get_current_event(@ptrCast(gesture)) orelse return;

    const self: *ClipboardConfirmation = @ptrCast(@alignCast(ud orelse return));

    log.info("mouse up", .{});

    if (self.secure_input) self.toggleNSFW();
}

const ButtonsView = struct {
    root: *c.GtkWidget,
    confirm_button: *c.GtkWidget,
    cancel_button: *c.GtkWidget,

    pub fn init(root: *ClipboardConfirmation) !ButtonsView {
        const cancel_text, const confirm_text = switch (root.request) {
            .paste => .{ "Cancel", "Paste" },
            .osc_52_read, .osc_52_write => .{ "Deny", "Allow" },
        };

        const cancel_button = c.gtk_button_new_with_label(cancel_text);
        errdefer c.g_object_unref(cancel_button);
        c.gtk_widget_add_css_class(cancel_button, "suggested-action");

        const confirm_button = c.gtk_button_new_with_label(confirm_text);
        errdefer c.g_object_unref(confirm_button);
        c.gtk_widget_add_css_class(confirm_button, "destructive-action");

        // Create our view
        const view = try View.init(&.{
            .{ .name = "cancel", .widget = cancel_button },
            .{ .name = "confirm", .widget = confirm_button },
        }, &vfl);

        // Signals
        _ = c.g_signal_connect_data(
            cancel_button,
            "clicked",
            c.G_CALLBACK(&gtkCancelClick),
            root,
            null,
            c.G_CONNECT_DEFAULT,
        );
        _ = c.g_signal_connect_data(
            confirm_button,
            "clicked",
            c.G_CALLBACK(&gtkConfirmClick),
            root,
            null,
            c.G_CONNECT_DEFAULT,
        );

        return .{ .root = view.root, .confirm_button = confirm_button, .cancel_button = cancel_button };
    }

    const vfl = [_][*:0]const u8{
        "H:[cancel]-8-[confirm]-8-|",
    };
};

/// The title of the window, based on the reason the prompt is being shown.
fn titleText(req: apprt.ClipboardRequest) [:0]const u8 {
    return switch (req) {
        .paste => "Warning: Potentially Unsafe Paste",
        .osc_52_read, .osc_52_write => "Authorize Clipboard Access",
    };
}

/// The text to display in the prompt window, based on the reason the prompt
/// is being shown.
fn promptText(req: apprt.ClipboardRequest) [:0]const u8 {
    return switch (req) {
        .paste =>
        \\Pasting this text into the terminal may be dangerous as it looks like some commands may be executed.
        ,
        .osc_52_read =>
        \\An application is attempting to read from the clipboard.
        \\The current clipboard contents are shown below.
        ,
        .osc_52_write =>
        \\An application is attempting to write to the clipboard.
        \\The content to write is shown below.
        ,
    };
}
