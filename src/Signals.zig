//! Structure for managing POSIX signal handlers.
const Signals = @This();

const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;

const App = @import("./App.zig");

const log = std.log.scoped(.signals);

/// Global variable to store core app. This needs to be
/// a global since it needs to be accessed from a POSIX
/// signal handler.
var _app: ?*App = null;

pub const init: Signals = .{};

// Start handling POSIX signals. This _should not_ modify the handler for
// SIGPIPE as that's handled in the global state initialization.
pub fn start(_: *Signals, app: *App) void {
    // Only posix systems.
    if (comptime builtin.os.tag == .windows) return;

    _app = app;

    var sa: posix.Sigaction = .{
        .handler = .{ .handler = handler },
        .mask = posix.empty_sigset,
        .flags = 0,
    };

    // SIGUSR2 => reload config
    posix.sigaction(posix.SIG.USR2, &sa, null);
}

/// POSIX signal handler. This must follow all the rules for POSIX signal
/// handlers. In general it's best to send a message that's handled by other
/// threads.
fn handler(signal: c_int) callconv(.c) void {
    // Failsafe in case we get called on a non-POSIX system.
    const app = _app orelse return;

    log.info("POSIX signal received: {d}", .{signal});

    switch (signal) {
        posix.SIG.USR2 => {
            _ = app.mailbox.push(.reload_config, .instant);
        },
        else => {},
    }
}
