const std = @import("std");

const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;

const Action = @import("../cli.zig").ghostty.Action;
const apprt = @import("../apprt.zig");
const internal_os = @import("../os/main.zig");
const args = @import("args.zig");
const diagnostics = @import("diagnostics.zig");

pub const Options = struct {
    /// This is set by the CLI parser for deinit.
    _arena: ?ArenaAllocator = null,

    /// If set, open up a new window in a custom instance of Ghostty.
    class: ?[:0]const u8 = null,

    /// Enable arg parsing diagnostics so that we don't get an error if
    /// there is a "normal" config setting on the cli.
    _diagnostics: diagnostics.DiagnosticList = .{},

    pub fn deinit(self: *Options) void {
        if (self._arena) |arena| arena.deinit();
        self.* = undefined;
    }

    /// Enables "-h" and "--help" to work.
    pub fn help(self: Options) !void {
        _ = self;
        return Action.help_error;
    }
};

/// The `present-surface` action will use native platform IPC to attempt to
/// bring the surface that this command is run in to the front.
///
/// NOTE: On Wayland the change in window focus isn't tied to a user interaction
/// so the Ghostty window won't be brought to the front directly. Instead the
/// user will be shown a notification. Clicking on that notification will bring
/// the window to the front.
///
/// If the `--class` flag is not set, the `present-window` command will try and
/// connect to a running instance of Ghostty based on what optimizations the
/// Ghostty CLI was compiled with. Otherwise the `present-window` command will try
/// and contact a running Ghostty instance that was configured with the same
/// `class` as was given on the command line.
///
/// GTK uses an application ID to identify instances of applications. If Ghostty
/// is compiled with release optimizations, the default application ID will be
/// `com.mitchellh.ghostty`. If Ghostty is compiled with debug optimizations,
/// the default application ID will be `com.mitchellh.ghostty-debug`.  The
/// `class` configuration entry can be used to set up a custom application
/// ID. The class name must follow the requirements defined [in the GTK
/// documentation](https://docs.gtk.org/gio/type_func.Application.id_is_valid.html)
/// or it will be ignored and Ghostty will use the default as defined above.
///
/// On GTK, D-Bus activation must be properly configured. Ghostty does not need
/// to be running for this to open a new window, making it suitable for binding
/// to keys in your window manager (if other methods for configuring global
/// shortcuts are unavailable). D-Bus will handle launching a new instance
/// of Ghostty if it is not already running. See the Ghostty website for
/// information on properly configuring D-Bus activation.
///
/// Only supported on GTK.
///
/// Flags:
///
///   * `--class=<class>`: If set, open up a new window in a custom instance of
///     Ghostty. The class must be a valid GTK application ID.
///
/// Available since: 1.2.0
pub fn run(alloc: Allocator) !u8 {
    var iter = try args.argsIterator(alloc);
    defer iter.deinit();
    return try runArgs(alloc, &iter);
}

fn runArgs(alloc_gpa: Allocator, argsIter: anytype) !u8 {
    const stderr = std.io.getStdErr().writer();

    var opts: Options = .{};
    defer opts.deinit();

    args.parse(Options, alloc_gpa, &opts, argsIter) catch |err| switch (err) {
        error.ActionHelpRequested => return err,
        else => {
            try stderr.print("Error parsing args: {}\n", .{err});
            return 1;
        },
    };

    // Print out any diagnostics, unless it's likely that the diagnostic was
    // generated trying to parse a "normal" configuration setting. Exit with an
    // error code if any diagnostics were printed.
    if (!opts._diagnostics.empty()) {
        var exit: bool = false;
        outer: for (opts._diagnostics.items()) |diagnostic| {
            if (diagnostic.location != .cli) continue :outer;
            inner: inline for (@typeInfo(Options).@"struct".fields) |field| {
                if (field.name[0] == '_') continue :inner;
                if (std.mem.eql(u8, field.name, diagnostic.key)) {
                    try stderr.writeAll("config error: ");
                    try diagnostic.write(stderr);
                    try stderr.writeAll("\n");
                    exit = true;
                }
            }
        }
        if (exit) return 1;
    }

    var arena = ArenaAllocator.init(alloc_gpa);
    defer arena.deinit();
    const alloc = arena.allocator();

    const env = try internal_os.getenv(alloc, "GHOSTTY_SURFACE") orelse {
        try stderr.writeAll("Unable to get GHOSTTY_SURFACE environment variable. Is this running in a Ghostty window?\n");
        return 1;
    };
    defer env.deinit(alloc);

    const id = std.fmt.parseUnsigned(u64, env.value, 0) catch {
        try stderr.writeAll("The GHOSTTY_SURFACE environment variable does not appear to contain an ID.\n");
        return 1;
    };

    if (apprt.App.performIpc(
        alloc,
        if (opts.class) |class| .{ .class = class } else .detect,
        .present_surface,
        .{ .id = id },
    ) catch |err| switch (err) {
        error.IPCFailed => {
            // The apprt should have printed a more specific error message
            // already.
            return 1;
        },
        else => {
            try stderr.print("Sending the IPC failed: {}", .{err});
            return 1;
        },
    }) return 0;

    // If we get here, the platform is not supported.
    try stderr.print("+present-surface is not supported on this platform.\n", .{});
    return 1;
}
