//! "VPHD": an overlay-layer marker stored under a page's key meaning "this
//! page is deleted in this layer; do not fall through to the base pack".
const std = @import("std");
const fmt = @import("common.zig");
const page_value = @import("page_value.zig");

pub const MAGIC: u32 = fmt.magic32("VPHD");
pub const VERSION: u16 = 1;
pub const SIZE: usize = 40;
const CRC_OFFSET: usize = 36;

pub const PagePlaceholder = struct {
    file_entry: u64,
    block_index: u32,
    page_index: u32,
    reason: u32 = 1,
};

pub fn encode(input: PagePlaceholder) [SIZE]u8 {
    var out = [_]u8{0} ** SIZE;
    fmt.putU32(&out, 0, MAGIC);
    fmt.putU16(&out, 4, VERSION);
    fmt.putU16(&out, 6, SIZE);
    fmt.putU64(&out, 8, input.file_entry);
    fmt.putU32(&out, 16, input.block_index);
    fmt.putU32(&out, 20, input.page_index);
    fmt.putU32(&out, 24, input.reason);
    fmt.putU32(&out, CRC_OFFSET, fmt.crc32cWithZeroU32(&out, CRC_OFFSET));
    return out;
}

/// Cheap probe: is this object a placeholder at all (magic only)?
pub fn isPlaceholder(bytes: []const u8) bool {
    return bytes.len >= 4 and fmt.getU32(bytes, 0) == MAGIC;
}

pub fn decode(bytes: []const u8, expected: page_value.PageIdentity) !PagePlaceholder {
    if (bytes.len != SIZE) return error.Corruption;
    if (fmt.getU32(bytes, 0) != MAGIC) return error.Corruption;
    if (fmt.getU16(bytes, 4) != VERSION) return error.UnsupportedVersion;
    if (fmt.getU16(bytes, 6) != SIZE) return error.Corruption;
    try fmt.requireZero(bytes[28..36]);
    if (fmt.getU32(bytes, CRC_OFFSET) != fmt.crc32cWithZeroU32(bytes, CRC_OFFSET)) return error.Corruption;
    const out: PagePlaceholder = .{
        .file_entry = fmt.getU64(bytes, 8),
        .block_index = fmt.getU32(bytes, 16),
        .page_index = fmt.getU32(bytes, 20),
        .reason = fmt.getU32(bytes, 24),
    };
    if (out.file_entry != expected.file_entry or out.block_index != expected.block_index or out.page_index != expected.page_index) return error.Corruption;
    return out;
}

test "page placeholder roundtrip identity and corruption" {
    const p: PagePlaceholder = .{ .file_entry = 77, .block_index = 1, .page_index = 9 };
    const enc = encode(p);
    try std.testing.expect(isPlaceholder(&enc));
    const dec = try decode(&enc, .{ .file_entry = 77, .block_index = 1, .page_index = 9 });
    try std.testing.expectEqual(@as(u32, 9), dec.page_index);
    try std.testing.expectError(error.Corruption, decode(&enc, .{ .file_entry = 78, .block_index = 1, .page_index = 9 }));
    var i: usize = 0;
    while (i < SIZE) : (i += 1) {
        var bad = enc;
        bad[i] ^= 0x01;
        try std.testing.expect(std.meta.isError(decode(&bad, .{ .file_entry = 77, .block_index = 1, .page_index = 9 })));
    }
    // A real page value header is not a placeholder.
    try std.testing.expect(!isPlaceholder("VPAG....."));
}
