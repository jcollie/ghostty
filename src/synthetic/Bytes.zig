/// Generates bytes.
const Bytes = @This();

const std = @import("std");
const Generator = @import("Generator.zig");

/// Random number generator.
rand: std.Random,

/// The minimum and maximum length of the generated bytes. The maximum
/// length will be capped to the length of the buffer passed in if the
/// buffer length is smaller.
min_len: usize = 1,
max_len: usize = std.math.maxInt(usize),

/// The possible bytes that can be generated. If a byte is duplicated
/// in the alphabet, it will be more likely to be generated. That's a
/// side effect of the generator, not an intended use case.
alphabet: ?[]const u8 = null,

/// Predefined alphabets.
pub const Alphabet = struct {
    pub const ascii = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789!@#$%^&*()_+-=[]{}|;':\\\",./<>?`~";
};

pub fn generator(self: *Bytes) Generator {
    return .init(self, next);
}

pub fn next(self: *Bytes, buf: []u8) Generator.Error![]const u8 {
    const len = @min(
        self.rand.intRangeAtMostBiased(usize, self.min_len, self.max_len),
        buf.len,
    );

    const result = buf[0..len];
    self.rand.bytes(result);
    if (self.alphabet) |alphabet| {
        for (result) |*byte| byte.* = alphabet[byte.* % alphabet.len];
    }

    return result;
}

test "bytes" {
    const testing = std.testing;
    var prng = std.Random.DefaultPrng.init(0);
    var buf: [256]u8 = undefined;
    var v: Bytes = .{ .rand = prng.random() };
    const gen = v.generator();
    const result = try gen.next(&buf);
    try testing.expect(result.len > 0);
}
