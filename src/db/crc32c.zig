//! CRC32C (Castagnoli) shared by the DB and VFS on-disk formats.
//!
//! Parameters (identical to the previous bitwise implementation):
//! - polynomial: 0x1EDC6F41 normal, 0x82F63B78 reflected
//! - init: 0xffffffff, refin/refout: true, xorout: 0xffffffff
//! - crc32c("123456789") == 0xe3069283
//!
//! Three implementations produce bit-identical results:
//! - x86-64 SSE4.2 `crc32` instruction (selected at comptime for the build target)
//! - AArch64 `crc32cx/crc32cb` (feature `crc`)
//! - portable slicing-by-8 table lookup
//!
//! `update`/`finish`/`resume` expose the running state so callers can hash a
//! logical record that lives in several buffers with a single pass per byte.
const std = @import("std");
const builtin = @import("builtin");

pub const has_hardware: bool = switch (builtin.cpu.arch) {
    .x86_64 => builtin.cpu.has(.x86, .sse4_2),
    .aarch64 => builtin.cpu.has(.aarch64, .crc),
    else => false,
};

pub const init_state: u32 = 0xffffffff;

pub fn hash(bytes: []const u8) u32 {
    return finish(update(init_state, bytes));
}

/// Continue a CRC whose final value was `previous_crc` over `bytes`.
pub fn hashContinue(previous_crc: u32, bytes: []const u8) u32 {
    return finish(update(stateFromCrc(previous_crc), bytes));
}

pub inline fn finish(state: u32) u32 {
    return ~state;
}

/// Inverse of `finish`: turn a final crc value back into a running state.
pub inline fn stateFromCrc(crc: u32) u32 {
    return ~crc;
}

pub fn update(state: u32, bytes: []const u8) u32 {
    if (comptime has_hardware) return updateHardware(state, bytes);
    return updateSlicing8(state, bytes);
}

// ---------------------------------------------------------------------------
// Hardware paths
// ---------------------------------------------------------------------------

fn updateHardware(state: u32, bytes: []const u8) u32 {
    var crc: u32 = state;
    var i: usize = 0;
    while (i + 8 <= bytes.len) : (i += 8) {
        const word = std.mem.readInt(u64, bytes[i..][0..8], .little);
        crc = hwWord(crc, word);
    }
    while (i < bytes.len) : (i += 1) {
        crc = hwByte(crc, bytes[i]);
    }
    return crc;
}

inline fn hwWord(crc: u32, word: u64) u32 {
    switch (builtin.cpu.arch) {
        .x86_64 => {
            const acc: u64 = crc;
            const out = asm ("crc32q %[word], %[acc]"
                : [acc] "=r" (-> u64),
                : [word] "r" (word),
                  [acc_in] "0" (acc),
            );
            return @truncate(out);
        },
        .aarch64 => {
            // Zig names register-width modifiers inside the operand brackets.
            return asm ("crc32cx %[out:w], %[crc:w], %[word]"
                : [out] "=r" (-> u32),
                : [crc] "r" (crc),
                  [word] "r" (word),
            );
        },
        else => unreachable,
    }
}

inline fn hwByte(crc: u32, byte: u8) u32 {
    switch (builtin.cpu.arch) {
        .x86_64 => {
            // Let operand types select 8-bit input / 32-bit accumulator. Zig
            // 0.16's x86 backend rejects `q` and mis-sizes the `crc32b` suffix.
            // This spelling also works with LLVM; keep the u8 input type.
            return asm ("crc32 %[byte], %[acc]"
                : [acc] "=r" (-> u32),
                : [byte] "r" (byte),
                  [acc_in] "0" (crc),
            );
        },
        .aarch64 => {
            return asm ("crc32cb %[out:w], %[crc:w], %[byte:w]"
                : [out] "=r" (-> u32),
                : [crc] "r" (crc),
                  [byte] "r" (@as(u32, byte)),
            );
        },
        else => unreachable,
    }
}

// ---------------------------------------------------------------------------
// Portable slicing-by-8
// ---------------------------------------------------------------------------

const POLY_REFLECTED: u32 = 0x82f63b78;

const tables: [8][256]u32 = blk: {
    @setEvalBranchQuota(200_000);
    var t: [8][256]u32 = undefined;
    for (0..256) |n| {
        var c: u32 = @intCast(n);
        var k: u8 = 0;
        while (k < 8) : (k += 1) {
            const mask: u32 = 0 -% (c & 1);
            c = (c >> 1) ^ (POLY_REFLECTED & mask);
        }
        t[0][n] = c;
    }
    for (1..8) |slice| {
        for (0..256) |n| {
            const prev = t[slice - 1][n];
            t[slice][n] = (prev >> 8) ^ t[0][prev & 0xff];
        }
    }
    break :blk t;
};

fn updateSlicing8(state: u32, bytes: []const u8) u32 {
    var crc: u32 = state;
    var i: usize = 0;
    while (i + 8 <= bytes.len) : (i += 8) {
        const w0 = std.mem.readInt(u32, bytes[i..][0..4], .little) ^ crc;
        const w1 = std.mem.readInt(u32, bytes[i + 4 ..][0..4], .little);
        crc = tables[7][w0 & 0xff] ^
            tables[6][(w0 >> 8) & 0xff] ^
            tables[5][(w0 >> 16) & 0xff] ^
            tables[4][w0 >> 24] ^
            tables[3][w1 & 0xff] ^
            tables[2][(w1 >> 8) & 0xff] ^
            tables[1][(w1 >> 16) & 0xff] ^
            tables[0][w1 >> 24];
    }
    while (i < bytes.len) : (i += 1) {
        crc = tables[0][(crc ^ bytes[i]) & 0xff] ^ (crc >> 8);
    }
    return crc;
}

// ---------------------------------------------------------------------------
// Reference and tests
// ---------------------------------------------------------------------------

/// Bitwise reference implementation; kept for tests and as documentation of the
/// exact algorithm the tables and hardware paths must match.
pub fn referenceBitwise(bytes: []const u8) u32 {
    var crc: u32 = 0xffffffff;
    for (bytes) |byte| {
        crc ^= byte;
        var i: u8 = 0;
        while (i < 8) : (i += 1) {
            const mask: u32 = 0 -% (crc & 1);
            crc = (crc >> 1) ^ (0x82f63b78 & mask);
        }
    }
    return ~crc;
}

test "crc32c fixed vectors" {
    try std.testing.expectEqual(@as(u32, 0x00000000), hash(""));
    try std.testing.expectEqual(@as(u32, 0xe3069283), hash("123456789"));
    try std.testing.expectEqual(@as(u32, 0xe3069283), updateSlicing8(init_state, "123456789") ^ 0xffffffff);
}

test "crc32c hardware, slicing and bitwise agree on all lengths and alignments" {
    var prng = std.Random.DefaultPrng.init(0x5eed);
    const random = prng.random();
    var buf: [1024 + 17]u8 = undefined;
    random.bytes(&buf);
    var len: usize = 0;
    while (len <= 1024) : (len += 1) {
        const start = len % 9;
        const slice = buf[start .. start + len];
        const expected = referenceBitwise(slice);
        try std.testing.expectEqual(expected, hash(slice));
        try std.testing.expectEqual(expected, finish(updateSlicing8(init_state, slice)));
        if (comptime has_hardware) try std.testing.expectEqual(expected, finish(updateHardware(init_state, slice)));
    }
}

test "crc32c continuation equals one-shot over concatenation" {
    var prng = std.Random.DefaultPrng.init(42);
    const random = prng.random();
    var buf: [4096]u8 = undefined;
    random.bytes(&buf);
    const a = buf[0..1000];
    const b = buf[1000..2345];
    const c = buf[2345..];
    const whole = hash(&buf);
    var crc = hash(a);
    crc = hashContinue(crc, b);
    crc = hashContinue(crc, c);
    try std.testing.expectEqual(whole, crc);
    var state = init_state;
    state = update(state, a);
    state = update(state, b);
    state = update(state, c);
    try std.testing.expectEqual(whole, finish(state));
}

test "crc32c every byte value and short hardware tail matches reference" {
    var bytes: [16]u8 = undefined;
    for (0..256) |value| {
        @memset(&bytes, @intCast(value));
        for (1..bytes.len + 1) |len| {
            try std.testing.expectEqual(referenceBitwise(bytes[0..len]), hash(bytes[0..len]));
        }
    }
}
