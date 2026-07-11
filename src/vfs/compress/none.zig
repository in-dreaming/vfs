const std = @import("std");
const fmt = @import("../format/common.zig");

pub const CODEC_ID: u16 = 0;

pub fn encodeNone(input: []const u8) []const u8 {
    return input;
}

pub fn decodeNone(input: []const u8, expected_raw_size: usize) ![]const u8 {
    if (input.len != expected_raw_size) return error.Corruption;
    return input;
}

pub fn decompressPage(allocator: std.mem.Allocator, stored: []const u8, raw_size: u32, raw_crc: u32) ![]u8 {
    if (stored.len != raw_size) return error.Corruption;
    if (fmt.crc32c(stored) != raw_crc) return error.ChecksumMismatch;
    return allocator.dupe(u8, stored);
}

test "none codec is pass-through and validates raw size" {
    const data = "plain";
    try std.testing.expectEqualSlices(u8, data, encodeNone(data));
    try std.testing.expectEqualSlices(u8, data, try decodeNone(data, data.len));
    try std.testing.expectError(error.Corruption, decodeNone(data, data.len + 1));
    const owned = try decompressPage(std.testing.allocator, data, data.len, fmt.crc32c(data));
    defer std.testing.allocator.free(owned);
    try std.testing.expectEqualSlices(u8, data, owned);
}
