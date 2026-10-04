//! Kitty drag and drop protocol (OSC 72): reading text/uri-list data.
//! File requests and remote drags refer to a list's URIs by index, so
//! the terminal and embedders must split it the same way kitty does.

const std = @import("std");
const Allocator = std.mem.Allocator;

/// The lines of a text/uri-list: split on CR or LF, with trailing spaces
/// and tabs trimmed. Blank lines and comments (#) aren't URIs.
pub const UriList = struct {
    it: std.mem.TokenIterator(u8, .any),

    pub const Line = struct {
        /// The line as written.
        text: []const u8,

        /// Its URI, or null for a comment or blank line.
        uri: ?[]const u8,
    };

    pub fn init(list: []const u8) UriList {
        return .{ .it = std.mem.tokenizeAny(u8, list, "\r\n") };
    }

    pub fn nextLine(self: *UriList) ?Line {
        const line = self.it.next() orelse return null;
        const uri = std.mem.trimEnd(u8, line, " \t");
        return .{
            .text = line,
            .uri = if (uri.len == 0 or uri[0] == '#') null else uri,
        };
    }

    /// The next URI, skipping comments and blank lines.
    pub fn next(self: *UriList) ?[]const u8 {
        while (self.nextLine()) |line| {
            if (line.uri) |uri| return uri;
        }
        return null;
    }

    /// The n'th (zero-based) URI.
    pub fn get(list: []const u8, n: usize) ?[]const u8 {
        var it: UriList = .init(list);
        var i: usize = 0;
        while (it.next()) |uri| : (i += 1) {
            if (i == n) return uri;
        }
        return null;
    }
};

pub const PathError = error{
    /// Not a file URI, or (for `local`) a file URI naming another host.
    Unsupported,

    /// A file URI without an absolute path, or with bad escapes.
    Invalid,
} || Allocator.Error;

/// The absolute path a `file://` URI names, without query or fragment,
/// percent-decoded. With `local`, only URIs without a host or naming
/// localhost are accepted, as kitty does for files it reads; otherwise
/// the host names the machine the file is on and is ignored.
pub fn filePath(alloc: Allocator, uri: []const u8, host: enum { local, any }) PathError![]u8 {
    const prefix = "file://";
    if (uri.len < prefix.len or !std.ascii.eqlIgnoreCase(uri[0..prefix.len], prefix)) return error.Unsupported;
    const rest = uri[prefix.len..];
    const slash = std.mem.indexOfScalar(u8, rest, '/') orelse return error.Invalid;
    const name = rest[0..slash];
    if (host == .local and name.len != 0 and !std.ascii.eqlIgnoreCase(name, "localhost")) {
        return error.Unsupported;
    }

    var encoded = rest[slash..];
    if (std.mem.indexOfAny(u8, encoded, "?#")) |end| encoded = encoded[0..end];

    const path = try alloc.alloc(u8, encoded.len);
    errdefer alloc.free(path);
    var len: usize = 0;
    var i: usize = 0;
    while (i < encoded.len) : (len += 1) {
        if (encoded[i] == '%') {
            if (i + 2 >= encoded.len) return error.Invalid;
            path[len] = std.fmt.parseInt(u8, encoded[i + 1 ..][0..2], 16) catch return error.Invalid;
            i += 3;
        } else {
            path[len] = encoded[i];
            i += 1;
        }
    }

    // A NUL can't be part of a path.
    if (std.mem.indexOfScalar(u8, path[0..len], 0) != null) return error.Invalid;
    return alloc.realloc(path, len);
}

test "UriList" {
    const testing = std.testing;
    const list = "# comment\r\nfile:///a  \r\n\r\n \r\nhttps://b\nfile:///c";
    try testing.expectEqualStrings("file:///a", UriList.get(list, 0).?);
    try testing.expectEqualStrings("https://b", UriList.get(list, 1).?);
    try testing.expectEqualStrings("file:///c", UriList.get(list, 2).?);
    try testing.expect(UriList.get(list, 3) == null);

    var it: UriList = .init(list);
    try testing.expect(it.nextLine().?.uri == null);
    try testing.expectEqualStrings("file:///a  ", it.nextLine().?.text);
}

test "filePath" {
    const testing = std.testing;
    const alloc = testing.allocator;

    const path = try filePath(alloc, "file://localhost/a%20b/c?q#f", .local);
    defer alloc.free(path);
    try testing.expectEqualStrings("/a b/c", path);

    try testing.expectError(error.Unsupported, filePath(alloc, "https://x/a", .any));
    try testing.expectError(error.Unsupported, filePath(alloc, "file://host/a", .local));
    const remote = try filePath(alloc, "file://host/a", .any);
    defer alloc.free(remote);
    try testing.expectEqualStrings("/a", remote);
    try testing.expectError(error.Unsupported, filePath(alloc, "file:relative", .any));
    try testing.expectError(error.Invalid, filePath(alloc, "file://nopath", .any));
    try testing.expectError(error.Invalid, filePath(alloc, "file:///bad%zz", .any));
    try testing.expectError(error.Invalid, filePath(alloc, "file:///nul%00", .any));
}
