//! LZ4 block format (no frame). Pure Zig, no external dependency.
//!
//! Compressor: greedy hash-chain matcher. `level` controls how many chain
//! candidates are probed per position. Output is deterministic for a given
//! (input, level, implementation version), which the diff "page" strategy
//! relies on (docs/vfs/diff_patch.md §5.4).
//!
//! Decompressor: strictly bounds-checked; malformed input yields
//! `error.Corruption` and never reads or writes out of range.
const std = @import("std");
const fmt = @import("../format/common.zig");

pub const CODEC_ID: u16 = 1;
pub const VERSION_HASH: u64 = 0x6c7a342d7a696731; // "lz4-zig1"

const MIN_MATCH: usize = 4;
const LAST_LITERALS: usize = 5;
const MF_LIMIT: usize = MIN_MATCH + LAST_LITERALS + 3; // 12
const MAX_DISTANCE: usize = 65535;
const HASH_BITS: u6 = 16;
const HASH_SIZE: usize = 1 << HASH_BITS;
const HASH_SHIFT: u5 = @intCast(32 - HASH_BITS);
const NO_POS: u32 = std.math.maxInt(u32);

pub const MAX_INPUT_SIZE: usize = 0x7E000000;

/// Worst-case compressed size for `n` input bytes.
pub fn compressBound(n: usize) usize {
    return n + (n / 255) + 16;
}

inline fn hash4(v: u32) u16 {
    return @intCast((v *% 2654435761) >> HASH_SHIFT);
}

inline fn read32(src: []const u8, i: usize) u32 {
    return std.mem.readInt(u32, src[i..][0..4], .little);
}

fn writeLength(dst: []u8, pos: *usize, len_in: usize) !void {
    var len = len_in;
    while (len >= 255) : (len -= 255) {
        if (pos.* >= dst.len) return error.NoSpace;
        dst[pos.*] = 255;
        pos.* += 1;
    }
    if (pos.* >= dst.len) return error.NoSpace;
    dst[pos.*] = @intCast(len);
    pos.* += 1;
}

/// `match_len` is the full match length (>= MIN_MATCH) or 0 with offset 0 for
/// the final literal-only sequence.
fn emitSequence(dst: []u8, pos: *usize, literals: []const u8, match_len: usize, offset: usize) !void {
    const lit_token: u8 = if (literals.len >= 15) 15 else @intCast(literals.len);
    const has_match = offset != 0;
    const ml = if (has_match) match_len - MIN_MATCH else 0;
    const ml_token: u8 = if (!has_match) 0 else if (ml >= 15) 15 else @intCast(ml);
    if (pos.* >= dst.len) return error.NoSpace;
    dst[pos.*] = (lit_token << 4) | ml_token;
    pos.* += 1;
    if (literals.len >= 15) try writeLength(dst, pos, literals.len - 15);
    if (pos.* + literals.len > dst.len) return error.NoSpace;
    @memcpy(dst[pos.*..][0..literals.len], literals);
    pos.* += literals.len;
    if (!has_match) return;
    if (pos.* + 2 > dst.len) return error.NoSpace;
    std.mem.writeInt(u16, dst[pos.*..][0..2], @intCast(offset), .little);
    pos.* += 2;
    if (ml >= 15) try writeLength(dst, pos, ml - 15);
}

fn probesForLevel(level: i16) u32 {
    if (level <= 0) return 1;
    if (level >= 12) return 64;
    return @as(u32, 1) << @intCast(@min(level, 6));
}

const Matcher = struct {
    head: []u32,
    chain: []u16,
    probes: u32,

    inline fn insert(self: *Matcher, src: []const u8, i: usize) void {
        const h = hash4(read32(src, i));
        const prev = self.head[h];
        if (self.chain.len != 0) {
            self.chain[i] = if (prev == NO_POS or i - prev > MAX_DISTANCE) 0 else @intCast(i - prev);
        }
        self.head[h] = @intCast(i);
    }
};

/// Compresses `src` into `dst` and returns the compressed size. `dst.len`
/// must be >= `compressBound(src.len)` to be guaranteed to succeed.
pub fn compressBlock(allocator: std.mem.Allocator, src: []const u8, dst: []u8, level: i16) !usize {
    if (src.len > MAX_INPUT_SIZE) return error.InvalidArgument;
    var pos: usize = 0;
    if (src.len < MF_LIMIT + 1) {
        try emitSequence(dst, &pos, src, 0, 0);
        return pos;
    }
    const probes = probesForLevel(level);
    const head = try allocator.alloc(u32, HASH_SIZE);
    defer allocator.free(head);
    @memset(head, NO_POS);
    const chain: []u16 = if (probes > 1) try allocator.alloc(u16, src.len) else &.{};
    defer if (chain.len != 0) allocator.free(chain);
    var m = Matcher{ .head = head, .chain = chain, .probes = probes };

    const match_limit = src.len - LAST_LITERALS;
    const mf_limit = src.len - MF_LIMIT;
    var anchor: usize = 0;
    var ip: usize = 0;
    m.insert(src, ip);
    ip += 1;

    while (ip <= mf_limit) {
        var best_len: usize = 0;
        var best_off: usize = 0;
        var cand = head[hash4(read32(src, ip))];
        var probes_left = probes;
        while (cand != NO_POS and probes_left != 0) : (probes_left -= 1) {
            const dist = ip - cand;
            if (dist > MAX_DISTANCE) break;
            if (read32(src, cand) == read32(src, ip)) {
                var l: usize = MIN_MATCH;
                while (ip + l < match_limit and src[cand + l] == src[ip + l]) l += 1;
                if (l > best_len) {
                    best_len = l;
                    best_off = dist;
                }
            }
            if (chain.len == 0) break;
            const back = chain[cand];
            if (back == 0) break;
            cand -= back;
        }
        if (best_len < MIN_MATCH) {
            m.insert(src, ip);
            ip += 1;
            continue;
        }
        while (ip > anchor and ip > best_off and src[ip - 1] == src[ip - best_off - 1]) {
            ip -= 1;
            best_len += 1;
        }
        try emitSequence(dst, &pos, src[anchor..ip], best_len, best_off);
        var k = ip;
        const end = ip + best_len;
        while (k < end and k <= mf_limit) : (k += 1) m.insert(src, k);
        ip = end;
        anchor = ip;
    }
    try emitSequence(dst, &pos, src[anchor..], 0, 0);
    return pos;
}

fn readLength(src: []const u8, ip: *usize, base: usize) !usize {
    var len = base;
    while (true) {
        if (ip.* >= src.len) return error.Corruption;
        const b = src[ip.*];
        ip.* += 1;
        len += b;
        if (len > MAX_INPUT_SIZE) return error.Corruption;
        if (b != 255) return len;
    }
}

/// Decompresses an LZ4 block into `dst`, which must be exactly `raw_size`
/// bytes. Returns the number of bytes written (== dst.len on success).
pub fn decompressBlock(src: []const u8, dst: []u8) !usize {
    var ip: usize = 0;
    var op: usize = 0;
    if (src.len == 0) {
        if (dst.len != 0) return error.Corruption;
        return 0;
    }
    while (true) {
        if (ip >= src.len) return error.Corruption;
        const token = src[ip];
        ip += 1;
        var lit_len: usize = token >> 4;
        if (lit_len == 15) lit_len = try readLength(src, &ip, 15);
        if (ip + lit_len > src.len or op + lit_len > dst.len) return error.Corruption;
        @memcpy(dst[op..][0..lit_len], src[ip..][0..lit_len]);
        ip += lit_len;
        op += lit_len;
        if (ip == src.len) {
            if (op != dst.len) return error.Corruption;
            return op;
        }
        if (ip + 2 > src.len) return error.Corruption;
        const offset: usize = std.mem.readInt(u16, src[ip..][0..2], .little);
        ip += 2;
        if (offset == 0 or offset > op) return error.Corruption;
        var match_len: usize = (token & 0x0F);
        if (match_len == 15) match_len = try readLength(src, &ip, 15);
        match_len += MIN_MATCH;
        if (op + match_len > dst.len) return error.Corruption;
        const match_start = op - offset;
        if (offset >= match_len) {
            @memcpy(dst[op..][0..match_len], dst[match_start..][0..match_len]);
        } else {
            var i: usize = 0;
            while (i < match_len) : (i += 1) dst[op + i] = dst[match_start + i];
        }
        op += match_len;
    }
}

/// Codec adapter: decompress a stored page and verify `raw_crc`.
pub fn decompressPage(allocator: std.mem.Allocator, stored: []const u8, raw_size: u32, raw_crc: u32) ![]u8 {
    const out = try allocator.alloc(u8, raw_size);
    errdefer allocator.free(out);
    const n = try decompressBlock(stored, out);
    if (n != raw_size) return error.Corruption;
    if (fmt.crc32c(out) != raw_crc) return error.ChecksumMismatch;
    return out;
}

/// Codec adapter: compress a raw page; returns an owned buffer sized to the
/// compressed length.
pub fn compressPage(allocator: std.mem.Allocator, raw: []const u8, level: i16) ![]u8 {
    const buf = try allocator.alloc(u8, compressBound(raw.len));
    errdefer allocator.free(buf);
    const n = try compressBlock(allocator, raw, buf, level);
    return allocator.realloc(buf, n);
}

fn roundtrip(allocator: std.mem.Allocator, input: []const u8, level: i16) !usize {
    const dst = try allocator.alloc(u8, compressBound(input.len));
    defer allocator.free(dst);
    const n = try compressBlock(allocator, input, dst, level);
    const out = try allocator.alloc(u8, input.len);
    defer allocator.free(out);
    const m = try decompressBlock(dst[0..n], out);
    try std.testing.expectEqual(input.len, m);
    try std.testing.expectEqualSlices(u8, input, out);
    return n;
}

test "lz4 reference vectors decode" {
    // Hand-assembled blocks following the LZ4 block spec.
    // "aaaaaaaaaaaaaaaaaaaa" (20 x 'a'): 1 literal 'a', match offset 1 len 14 (token ml=10 -> 14), then 5 last literals.
    const v1 = [_]u8{ 0x1a, 'a', 0x01, 0x00, 0x50, 'a', 'a', 'a', 'a', 'a' };
    var out1: [20]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 20), try decompressBlock(&v1, &out1));
    try std.testing.expectEqualSlices(u8, "aaaaaaaaaaaaaaaaaaaa", &out1);
    // Literal-only block: "hello" -> token 0x50 + 5 literals.
    const v2 = [_]u8{ 0x50, 'h', 'e', 'l', 'l', 'o' };
    var out2: [5]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 5), try decompressBlock(&v2, &out2));
    try std.testing.expectEqualSlices(u8, "hello", &out2);
    // Long literal length encoding: 20 literals -> token 0xF0, extra 5.
    var v3: [22]u8 = undefined;
    v3[0] = 0xF0;
    v3[1] = 5;
    @memset(v3[2..], 'x');
    var out3: [20]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 20), try decompressBlock(&v3, &out3));
    try std.testing.expectEqualSlices(u8, "x" ** 20, &out3);
}

test "lz4 roundtrip random repetitive and incompressible" {
    const allocator = std.testing.allocator;
    var prng = std.Random.DefaultPrng.init(0x1234);
    const rnd = prng.random();
    const sizes = [_]usize{ 0, 1, 5, 12, 13, 64, 1000, 65536, 300_000 };
    for (sizes) |n| {
        const buf = try allocator.alloc(u8, n);
        defer allocator.free(buf);
        // repetitive
        for (buf, 0..) |*b, i| b.* = @intCast((i / 7) % 13 + 'a');
        _ = try roundtrip(allocator, buf, 0);
        const n_rep = try roundtrip(allocator, buf, 4);
        if (n >= 1000) try std.testing.expect(n_rep < n / 4);
        // random
        rnd.bytes(buf);
        _ = try roundtrip(allocator, buf, 0);
        _ = try roundtrip(allocator, buf, 12);
        // mixed
        var i: usize = 0;
        while (i + 32 <= n) : (i += 64) @memset(buf[i .. i + 32], 0);
        _ = try roundtrip(allocator, buf, 2);
    }
}

test "lz4 compression is deterministic and matches text structure" {
    const allocator = std.testing.allocator;
    const text = "the quick brown fox jumps over the lazy dog. the quick brown fox jumps over the lazy dog. " ** 20;
    const a = try compressPage(allocator, text, 4);
    defer allocator.free(a);
    const b = try compressPage(allocator, text, 4);
    defer allocator.free(b);
    try std.testing.expectEqualSlices(u8, a, b);
    try std.testing.expect(a.len < text.len / 5);
    const out = try decompressPage(allocator, a, @intCast(text.len), fmt.crc32c(text));
    defer allocator.free(out);
    try std.testing.expectEqualSlices(u8, text, out);
    try std.testing.expectError(error.ChecksumMismatch, decompressPage(allocator, a, @intCast(text.len), 0));
}

test "lz4 rejects corrupted and truncated input without overflow" {
    const allocator = std.testing.allocator;
    const text = "abcabcabcabcabcabcabcabcabcabc0123456789abcabcabcabc";
    const comp = try compressPage(allocator, text, 4);
    defer allocator.free(comp);
    var out: [64]u8 = undefined;
    // truncated
    var cut: usize = 0;
    while (cut < comp.len) : (cut += 1) {
        const r = decompressBlock(comp[0..cut], out[0..text.len]);
        try std.testing.expect(r == error.Corruption or (r catch 0) != text.len or cut == comp.len);
    }
    // wrong raw size
    try std.testing.expectError(error.Corruption, decompressBlock(comp, out[0 .. text.len - 1]));
    try std.testing.expectError(error.Corruption, decompressBlock(comp, out[0 .. text.len + 1]));
    // bad offset (0) and offset beyond output
    const bad_off0 = [_]u8{ 0x10, 'a', 0x00, 0x00, 0x50, 'a', 'a', 'a', 'a', 'a' };
    try std.testing.expectError(error.Corruption, decompressBlock(&bad_off0, out[0..10]));
    const bad_off_far = [_]u8{ 0x10, 'a', 0x09, 0x00, 0x50, 'a', 'a', 'a', 'a', 'a' };
    try std.testing.expectError(error.Corruption, decompressBlock(&bad_off_far, out[0..10]));
    // bit flips on a valid stream must not crash
    var flipped = try allocator.dupe(u8, comp);
    defer allocator.free(flipped);
    var i: usize = 0;
    while (i < flipped.len) : (i += 1) {
        flipped[i] ^= 0x5a;
        _ = decompressBlock(flipped, out[0..text.len]) catch {};
        flipped[i] ^= 0x5a;
    }
}
