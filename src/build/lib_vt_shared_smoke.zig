//! Build tool that drives the libghostty-vt C ABI through the *shared*
//! library, loading it the way an embedder does.
//!
//! The unit tests in `src/terminal` link the terminal into a test
//! executable, which is not the image shape embedders use. A dynamic
//! library has its own entry point and its own initialization, and things
//! can be broken there while every in-process test passes: the vendored
//! simdutf keeps its dispatch pointer in a global constructor, so a library
//! whose constructors never ran dies on the first non-ASCII byte while the
//! test executable is perfectly happy. See `src/lib/windows_dll.zig`.
//!
//! This deliberately does not link the library at build time. It opens the
//! library by path at runtime through the platform loader, because
//! load-time initialization is the thing under test.
//!
//! Usage: lib_vt_shared_smoke <library>

const std = @import("std");
const builtin = @import("builtin");

/// Opaque `GhosttyTerminal` handle.
const Terminal = ?*anyopaque;

/// `GhosttyResult`. Our C enums are int-sized (`GHOSTTY_ENUM_MAX_VALUE` is
/// `INT_MAX`) and `GHOSTTY_SUCCESS` is zero.
const Result = c_int;
const success: Result = 0;

const NewFn = *const fn (?*const anyopaque, *Terminal, u16, u16) callconv(.c) Result;
const WriteFn = *const fn (Terminal, [*]const u8, usize) callconv(.c) void;
const FreeFn = *const fn (Terminal) callconv(.c) void;

/// Each entry is a single write carrying a complete UTF-8 sequence, which
/// is what reaches the SIMD decoder. Pure ASCII never does, so an
/// ASCII-only smoke test would not notice an uninitialized decoder.
const writes: []const []const u8 = &.{
    "hello", // ASCII only: must keep working
    "é", // the minimal failing case: one 2-byte sequence
    "aé€😀", // 1, 2, 3 and 4 byte sequences together
    "a" ** 128 ++ "é", // past a full SIMD chunk of ASCII
    "é\x1b[0m€", // split by a control sequence
};

pub fn main(init: std.process.Init) !void {
    // One-off tool, so we leak and let the OS clean up on exit.
    const alloc = init.arena.allocator();

    const args = try init.minimal.args.toSlice(alloc);
    if (args.len != 2) fatal("usage: lib_vt_shared_smoke <library>", .{});

    const path = args[1];
    var lib: Library = Library.open(alloc, path) catch |err| fatal(
        "failed to load '{s}': {t}",
        .{ path, err },
    );
    defer lib.close();

    const new = lib.lookup(NewFn, "ghostty_terminal_new") orelse
        fatal("missing symbol: ghostty_terminal_new", .{});
    const write = lib.lookup(WriteFn, "ghostty_terminal_vt_write") orelse
        fatal("missing symbol: ghostty_terminal_vt_write", .{});
    const free = lib.lookup(FreeFn, "ghostty_terminal_free") orelse
        fatal("missing symbol: ghostty_terminal_free", .{});

    var term: Terminal = null;
    if (new(null, &term, 80, 24) != success) {
        fatal("ghostty_terminal_new failed", .{});
    }
    defer free(term);

    for (writes) |buf| write(term, buf.ptr, buf.len);
}

/// A loaded shared library.
///
/// `std.DynLib` covers every platform we ship except Windows, so Windows
/// goes through kernel32 directly.
const Library = if (builtin.os.tag == .windows) struct {
    const windows = std.os.windows;

    extern "kernel32" fn LoadLibraryW(
        lpLibFileName: [*:0]const u16,
    ) callconv(.winapi) ?windows.HMODULE;
    extern "kernel32" fn GetProcAddress(
        hModule: windows.HMODULE,
        lpProcName: [*:0]const u8,
    ) callconv(.winapi) ?windows.FARPROC;
    extern "kernel32" fn FreeLibrary(
        hLibModule: windows.HMODULE,
    ) callconv(.winapi) windows.BOOL;

    handle: windows.HMODULE,

    fn open(alloc: std.mem.Allocator, path: []const u8) !Library {
        const path_w = try std.unicode.wtf8ToWtf16LeAllocZ(alloc, path);
        return .{ .handle = LoadLibraryW(path_w.ptr) orelse
            return error.FileNotFound };
    }

    fn close(self: *Library) void {
        _ = FreeLibrary(self.handle);
    }

    fn lookup(self: *Library, comptime T: type, name: [:0]const u8) ?T {
        const proc = GetProcAddress(self.handle, name.ptr) orelse return null;
        return @ptrCast(@alignCast(proc));
    }
} else struct {
    inner: std.DynLib,

    fn open(alloc: std.mem.Allocator, path: []const u8) !Library {
        _ = alloc;
        return .{ .inner = try std.DynLib.open(path) };
    }

    fn close(self: *Library) void {
        self.inner.close();
    }

    fn lookup(self: *Library, comptime T: type, name: [:0]const u8) ?T {
        return self.inner.lookup(T, name);
    }
};

fn fatal(comptime fmt: []const u8, args: anytype) noreturn {
    std.log.err(fmt, args);
    std.process.exit(1);
}
