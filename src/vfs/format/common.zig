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

const crc32c_impl = @import("db_internal").format.crc32c_impl;

/// CRC32C (Castagnoli), fixed algorithm and constants; no platform-specific state.
/// Shares the hardware-accelerated implementation with libdb (bit-identical output).
pub fn crc32c(bytes: []const u8) u32 {
    return crc32c_impl.hash(bytes);
}

/// CRC32C over `bytes` with the 4 bytes at `zero_offset` treated as zero, so a
/// header can be hashed in place without copying it to clear its own crc field.
pub fn crc32cWithZeroU32(bytes: []const u8, zero_offset: usize) u32 {
    const zero = [_]u8{ 0, 0, 0, 0 };
    if (zero_offset >= bytes.len) return crc32c_impl.hash(bytes);
    const hole_end = @min(bytes.len, zero_offset + 4);
    var state = crc32c_impl.update(crc32c_impl.init_state, bytes[0..zero_offset]);
    state = crc32c_impl.update(state, zero[0 .. hole_end - zero_offset]);
    state = crc32c_impl.update(state, bytes[hole_end..]);
    return crc32c_impl.finish(state);
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

    var with_hole = [_]u8{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10 };
    var zeroed = with_hole;
    @memset(zeroed[3..7], 0);
    try std.testing.expectEqual(crc32c(&zeroed), crc32cWithZeroU32(&with_hole, 3));
    @memset(zeroed[8..10], 0);
    zeroed[3..7].* = with_hole[3..7].*;
    try std.testing.expectEqual(crc32c(&zeroed), crc32cWithZeroU32(&with_hole, 8));
    try std.testing.expectEqual(crc32c(&with_hole), crc32cWithZeroU32(&with_hole, 10));
}
