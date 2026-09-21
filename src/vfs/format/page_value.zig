const std = @import("std");
const fmt = @import("common.zig");
const file_manifest = @import("file_manifest.zig");

pub const MAGIC: u32 = fmt.magic32("VPAG");
pub const VERSION: u16 = 1;
pub const HEADER_SIZE: usize = 104;
const HEADER_CRC_OFFSET: usize = 100;

pub const PageIdentity = struct {
    file_entry: u64,
    block_index: u32,
    page_index: u32,
};

pub const PageValue = struct {
    file_entry: u64,
    block_index: u32,
    page_index: u32,
    codec: file_manifest.Codec = .none,
    codec_flags: u32 = 0,
    raw_size: u32,
    stored_size: u32,
    raw_crc: u32 = 0,
    stored_crc: u32 = 0,
    content_hash: [32]u8 = [_]u8{0} ** 32,
    page_flags: u32 = 0,
    payload: []const u8,
};

pub fn encodePageValue(allocator: std.mem.Allocator, value: PageValue) ![]u8 {
    if (value.file_entry == 0) return error.InvalidArgument;
    if (value.stored_size != value.payload.len) return error.InvalidArgument;
    if (value.raw_size != value.payload.len and value.codec == .none) return error.InvalidArgument;
    const total = HEADER_SIZE + value.payload.len;
    var out = try allocator.alloc(u8, total);
    errdefer allocator.free(out);
    @memset(out, 0);
    fmt.putU32(out, 0, MAGIC);
    fmt.putU16(out, 4, VERSION);
    fmt.putU16(out, 6, HEADER_SIZE);
    fmt.putU64(out, 8, value.file_entry);
    fmt.putU32(out, 16, value.block_index);
    fmt.putU32(out, 20, value.page_index);
    fmt.putU16(out, 24, @intFromEnum(value.codec));
    fmt.putU32(out, 28, value.codec_flags);
    fmt.putU32(out, 32, value.raw_size);
    fmt.putU32(out, 36, value.stored_size);
    const raw_crc = if (value.raw_crc == 0 and value.codec == .none) fmt.crc32c(value.payload) else value.raw_crc;
    const stored_crc = if (value.stored_crc == 0) fmt.crc32c(value.payload) else value.stored_crc;
    fmt.putU32(out, 40, raw_crc);
    fmt.putU32(out, 44, stored_crc);
    @memcpy(out[48..80][0..32], &value.content_hash);
    fmt.putU32(out, 80, value.page_flags);
    @memcpy(out[HEADER_SIZE..], value.payload);
    fmt.putU32(out, HEADER_CRC_OFFSET, 0);
    fmt.putU32(out, HEADER_CRC_OFFSET, fmt.crc32c(out[0..HEADER_SIZE]));
    return out;
}

pub fn decodePageValue(bytes: []const u8, expected: PageIdentity) !PageValue {
    if (bytes.len < HEADER_SIZE) return error.Corruption;
    if (fmt.getU32(bytes, 0) != MAGIC) return error.Corruption;
    if (fmt.getU16(bytes, 4) != VERSION) return error.UnsupportedVersion;
    if (fmt.getU16(bytes, 6) != HEADER_SIZE) return error.Corruption;
    try fmt.requireZero(bytes[26..28]);
    try fmt.requireZero(bytes[84..100]);

    const stored_header_crc = fmt.getU32(bytes, HEADER_CRC_OFFSET);
    var header = [_]u8{0} ** HEADER_SIZE;
    @memcpy(&header, bytes[0..HEADER_SIZE]);
    fmt.putU32(&header, HEADER_CRC_OFFSET, 0);
    if (fmt.crc32c(&header) != stored_header_crc) return error.Corruption;

    const file_entry = fmt.getU64(bytes, 8);
    const block_index = fmt.getU32(bytes, 16);
    const page_index = fmt.getU32(bytes, 20);
    if (file_entry == 0 or file_entry != expected.file_entry or block_index != expected.block_index or page_index != expected.page_index) return error.Corruption;
    const stored_size = fmt.getU32(bytes, 36);
    if (bytes.len != HEADER_SIZE + stored_size) return error.Corruption;
    const payload = bytes[HEADER_SIZE..];
    const stored_crc = fmt.getU32(bytes, 44);
    // One pass over the payload: for the `none` codec stored bytes are the raw
    // bytes, so the same value must also match raw_crc.
    const payload_crc = fmt.crc32c(payload);
    if (payload_crc != stored_crc) return error.ChecksumMismatch;
    const codec: file_manifest.Codec = @enumFromInt(fmt.getU16(bytes, 24));
    const raw_crc = fmt.getU32(bytes, 40);
    const raw_size = fmt.getU32(bytes, 32);
    if (codec == .none) {
        if (raw_size != stored_size) return error.Corruption;
        if (payload_crc != raw_crc) return error.ChecksumMismatch;
    }
    var h: [32]u8 = undefined;
    @memcpy(&h, bytes[48..80][0..32]);
    return .{
        .file_entry = file_entry,
        .block_index = block_index,
        .page_index = page_index,
        .codec = codec,
        .codec_flags = fmt.getU32(bytes, 28),
        .raw_size = raw_size,
        .stored_size = stored_size,
        .raw_crc = raw_crc,
        .stored_crc = stored_crc,
        .content_hash = h,
        .page_flags = fmt.getU32(bytes, 80),
        .payload = payload,
    };
}

test "page value validates identity crc and truncation" {
    const allocator = std.testing.allocator;
    const payload = "hello page";
    const encoded = try encodePageValue(allocator, .{ .file_entry = 77, .block_index = 3, .page_index = 4, .raw_size = payload.len, .stored_size = payload.len, .payload = payload });
    defer allocator.free(encoded);
    const decoded = try decodePageValue(encoded, .{ .file_entry = 77, .block_index = 3, .page_index = 4 });
    try std.testing.expectEqualSlices(u8, payload, decoded.payload);
    try std.testing.expectError(error.Corruption, decodePageValue(encoded, .{ .file_entry = 78, .block_index = 3, .page_index = 4 }));

    var bad = try allocator.dupe(u8, encoded);
    defer allocator.free(bad);
    bad[bad.len - 1] ^= 0xff;
    try std.testing.expectError(error.ChecksumMismatch, decodePageValue(bad, .{ .file_entry = 77, .block_index = 3, .page_index = 4 }));
    try std.testing.expectError(error.Corruption, decodePageValue(encoded[0 .. encoded.len - 1], .{ .file_entry = 77, .block_index = 3, .page_index = 4 }));
}
