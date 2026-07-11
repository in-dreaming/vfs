const std = @import("std");

pub fn magic32(comptime s: []const u8) u32 {
    comptime {
        if (s.len != 4) @compileError("VFS magic must be exactly 4 bytes");
    }
    var out: u32 = 0;
    inline for (s, 0..) |c, i| {
        out |= @as(u32, c) << @intCast(i * 8);
    }
    return out;
}

pub fn putU16(dst: []u8, off: usize, value: u16) void {
    dst[off + 0] = @truncate(value);
    dst[off + 1] = @truncate(value >> 8);
}

pub fn putU32(dst: []u8, off: usize, value: u32) void {
    dst[off + 0] = @truncate(value);
    dst[off + 1] = @truncate(value >> 8);
    dst[off + 2] = @truncate(value >> 16);
    dst[off + 3] = @truncate(value >> 24);
}

pub fn putU64(dst: []u8, off: usize, value: u64) void {
    dst[off + 0] = @truncate(value);
    dst[off + 1] = @truncate(value >> 8);
    dst[off + 2] = @truncate(value >> 16);
    dst[off + 3] = @truncate(value >> 24);
    dst[off + 4] = @truncate(value >> 32);
    dst[off + 5] = @truncate(value >> 40);
    dst[off + 6] = @truncate(value >> 48);
    dst[off + 7] = @truncate(value >> 56);
}

pub fn getU16(src: []const u8, off: usize) u16 {
    return @as(u16, src[off + 0]) | (@as(u16, src[off + 1]) << 8);
}

pub fn getU32(src: []const u8, off: usize) u32 {
    return @as(u32, src[off + 0]) |
        (@as(u32, src[off + 1]) << 8) |
        (@as(u32, src[off + 2]) << 16) |
        (@as(u32, src[off + 3]) << 24);
}

pub fn getU64(src: []const u8, off: usize) u64 {
    return @as(u64, src[off + 0]) |
        (@as(u64, src[off + 1]) << 8) |
        (@as(u64, src[off + 2]) << 16) |
        (@as(u64, src[off + 3]) << 24) |
        (@as(u64, src[off + 4]) << 32) |
        (@as(u64, src[off + 5]) << 40) |
        (@as(u64, src[off + 6]) << 48) |
        (@as(u64, src[off + 7]) << 56);
}

/// CRC32C (Castagnoli), fixed algorithm and constants; no platform-specific state.
pub fn crc32c(bytes: []const u8) u32 {
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

pub fn crc32cWithZeroU32(bytes: []const u8, zero_offset: usize) u32 {
    var crc: u32 = 0xffffffff;
    for (bytes, 0..) |actual, i| {
        const byte: u8 = if (i >= zero_offset and i < zero_offset + 4) 0 else actual;
        crc ^= byte;
        var bit: u8 = 0;
        while (bit < 8) : (bit += 1) {
            const mask: u32 = 0 -% (crc & 1);
            crc = (crc >> 1) ^ (0x82f63b78 & mask);
        }
    }
    return ~crc;
}

pub fn checkedSize(value: u64) !usize {
    return std.math.cast(usize, value) orelse error.InvalidArgument;
}

pub fn requireZero(bytes: []const u8) !void {
    for (bytes) |b| if (b != 0) return error.Corruption;
}

test "VFS common little-endian and crc helpers are stable" {
    var b = [_]u8{0} ** 16;
    putU16(&b, 0, 0x1234);
    putU32(&b, 2, 0x89abcdef);
    putU64(&b, 6, 0x0123456789abcdef);

    try std.testing.expectEqualSlices(u8, &.{ 0x34, 0x12 }, b[0..2]);
    try std.testing.expectEqual(@as(u16, 0x1234), getU16(&b, 0));
    try std.testing.expectEqual(@as(u32, 0x89abcdef), getU32(&b, 2));
    try std.testing.expectEqual(@as(u64, 0x0123456789abcdef), getU64(&b, 6));
    try std.testing.expectEqual(@as(u32, 0xe3069283), crc32c("123456789"));
}
