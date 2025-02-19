const ProcessScanner = @This();

const std = @import("std");
const linux = std.os.linux;

const xev = @import("xev");

const Pty = @import("../pty.zig");
const termio = @import("../termio.zig");
const linuxproc = @import("../os/linuxproc.zig");

const log = std.log.scoped(.process_scanner);

fd: Pty.Fd,
td: *termio.Termio.ThreadData,
ssh: bool = false,
elevated: bool = false,
thread: ?std.Thread = null,
stop_: ?*xev.Async = null,

pub fn init(self: *ProcessScanner, fd: Pty.Fd, td: *termio.Termio.ThreadData) void {
    self.* = .{
        .fd = fd,
        .td = td,
    };

    self.thread = std.Thread.spawn(.{}, run, .{self}) catch |err| {
        log.warn("unable to spawn process scanner thread: {}", .{err});
        return;
    };
}

pub fn stop(self: *ProcessScanner) void {
    if (self.stop_) |s| s.notify() catch |err| {
        log.warn("unable to stop process scanner: {}", .{err});
    };
    if (self.thread) |thread| thread.join();
}

fn run(self: *ProcessScanner) void {
    var loop = xev.Loop.init(.{}) catch |err| {
        log.warn("unable to initialize process scan event loop: {}", .{err});
        return;
    };
    defer loop.deinit();

    var stop_a = xev.Async.init() catch |err| {
        log.warn("unable to initialize process scan stop async: {}", .{err});
        return;
    };
    defer stop_a.deinit();

    var stop_c: xev.Completion = undefined;

    stop_a.wait(
        &loop,
        &stop_c,
        ProcessScanner,
        self,
        stopCallback,
    );
    self.stop_ = &stop_a;

    var timer = xev.Timer.init() catch |err| {
        log.warn("unable to init process scan timer: {}", .{err});
        return;
    };
    defer timer.deinit();

    var timer_c: xev.Completion = undefined;

    timer.run(
        &loop,
        &timer_c,
        100,
        ProcessScanner,
        self,
        timerCallback,
    );

    loop.run(.until_done) catch |err| {
        log.warn("error while running process scan loop: {}", .{err});
    };
}

fn stopCallback(
    _: ?*ProcessScanner,
    loop: *xev.Loop,
    _: *xev.Completion,
    result: xev.Async.WaitError!void,
) xev.CallbackAction {
    _ = result catch unreachable;
    loop.stop();
    return .disarm;
}

fn timerCallback(
    self_: ?*ProcessScanner,
    _: *xev.Loop,
    _: *xev.Completion,
    result: xev.Timer.RunError!void,
) xev.CallbackAction {
    _ = result catch unreachable;
    const self = self_ orelse unreachable;

    const tc = struct {
        extern fn tcgetpgrp(handle: std.posix.fd_t) std.posix.pid_t;
    };

    const pid = tc.tcgetpgrp(self.fd);

    if (pid < 1) {
        log.info("error getting pgrp: {}", .{pid});
        return .rearm;
    }

    const info = linuxproc.getProcessInfo(pid) catch |err| {
        log.warn("unable to get process info for {}: {}", .{ pid, err });
        return .rearm;
    } orelse return .rearm;

    if (self.ssh != info.ssh) {
        log.info("surface: pid: {} ssh: {} -> {}", .{ info.pid, self.ssh, info.ssh });
        self.ssh = info.ssh;
    }
    if (self.elevated != info.elevated) {
        log.info("surface: pid: {} elevated: {} -> {}", .{ info.pid, self.elevated, info.elevated });
        self.elevated = info.elevated;
    }

    return .rearm;
}
