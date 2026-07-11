const std = @import("std");
const fmt = @import("common.zig");

pub const ENTRY_MAGIC: u32 = fmt.magic32("VETS");
pub const PATH_MAGIC: u32 = fmt.magic32("VPTS");
pub const VERSION: u16 = 1;
pub const ENTRY_SIZE: usize = 40;
const ENTRY_CRC_OFFSET: usize = 36;

pub const EntryTombstone = struct {
    file_entry: u64,
    tombstone_version: u64,
    reason_flags: u32,
    crc: u32 = 0,
};

pub const PathTombstone = struct {
    path_hash: u64,
    tombstone_version: u64,
    reason_flags: u32,
};

pub fn encodeEntryTombstone(input: EntryTombstone) ![ENTRY_SIZE]u8 {
    if (input.file_entry == 0) return error.InvalidArgument;
    var out = [_]u8{0} ** ENTRY_SIZE;
    fmt.putU32(&out, 0, ENTRY_MAGIC);
    fmt.putU16(&out, 4, VERSION);
    fmt.putU16(&out, 6, ENTRY_SIZE);
    fmt.putU64(&out, 8, input.file_entry);
    fmt.putU64(&out, 16, input.tombstone_version);
    fmt.putU32(&out, 24, input.reason_flags);
    fmt.putU32(&out, ENTRY_CRC_OFFSET, 0);
    fmt.putU32(&out, ENTRY_CRC_OFFSET, fmt.crc32c(&out));
    return out;
}

pub fn decodeEntryTombstone(bytes: []const u8, expected_file_entry: ?u64) !EntryTombstone {
    if (bytes.len != ENTRY_SIZE) return error.Corruption;
    if (fmt.getU32(bytes, 0) != ENTRY_MAGIC) return error.Corruption;
    if (fmt.getU16(bytes, 4) != VERSION) return error.UnsupportedVersion;
    if (fmt.getU16(bytes, 6) != ENTRY_SIZE) return error.Corruption;
    try fmt.requireZero(bytes[28..36]);
    const stored_crc = fmt.getU32(bytes, ENTRY_CRC_OFFSET);
    var tmp = [_]u8{0} ** ENTRY_SIZE;
    @memcpy(&tmp, bytes);
    fmt.putU32(&tmp, ENTRY_CRC_OFFSET, 0);
    if (fmt.crc32c(&tmp) != stored_crc) return error.Corruption;
    const entry = fmt.getU64(bytes, 8);
    if (entry == 0) return error.Corruption;
    if (expected_file_entry) |expected| if (entry != expected) return error.Corruption;
    return .{ .file_entry = entry, .tombstone_version = fmt.getU64(bytes, 16), .reason_flags = fmt.getU32(bytes, 24), .crc = stored_crc };
}

test "entry tombstone roundtrips and rejects reserved bytes" {
    const encoded = try encodeEntryTombstone(.{ .file_entry = 9, .tombstone_version = 4, .reason_flags = 3 });
    const decoded = try decodeEntryTombstone(&encoded, 9);
    try std.testing.expectEqual(@as(u64, 9), decoded.file_entry);
    var bad = encoded;
    bad[28] = 1;
    try std.testing.expectError(error.Corruption, decodeEntryTombstone(&bad, 9));
}
