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

/// Pass-through "decompression": returns an owned copy of `stored`.
///
/// Callers obtain `stored` from `page_value.decodePageValue`, which has already
/// verified `crc32c(stored) == stored_crc == raw_crc` for this codec, so the
/// crc is not recomputed here. Codecs that actually transform bytes must
/// verify `raw_crc` over their output instead.
pub fn decompressPage(allocator: std.mem.Allocator, stored: []const u8, raw_size: u32, raw_crc: u32) ![]u8 {
    _ = raw_crc;
    if (stored.len != raw_size) return error.Corruption;
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
    try std.testing.expectError(error.Corruption, decompressPage(std.testing.allocator, data, data.len + 1, 0));
}
