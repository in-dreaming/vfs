const std = @import("std");
const fmt = @import("common.zig");

pub const MAGIC: u32 = fmt.magic32("VDIR");
pub const VERSION: u16 = 1;
pub const HEADER_SIZE: usize = 40;
const CRC_OFFSET: usize = 36;

pub const DirectoryManifest = struct {
    directory_count: u32 = 0,
    file_count: u64 = 0,
    flags: u32 = 0,
    crc: u32 = 0,
};

pub fn encodeDirectoryManifest(input: DirectoryManifest) [HEADER_SIZE]u8 {
    var out = [_]u8{0} ** HEADER_SIZE;
    fmt.putU32(&out, 0, MAGIC);
    fmt.putU16(&out, 4, VERSION);
    fmt.putU16(&out, 6, HEADER_SIZE);
    fmt.putU32(&out, 8, input.directory_count);
    fmt.putU64(&out, 16, input.file_count);
    fmt.putU32(&out, 24, input.flags);
    fmt.putU32(&out, CRC_OFFSET, 0);
    fmt.putU32(&out, CRC_OFFSET, fmt.crc32c(&out));
    return out;
}

pub fn decodeDirectoryManifest(bytes: []const u8) !DirectoryManifest {
    if (bytes.len != HEADER_SIZE) return error.Corruption;
    if (fmt.getU32(bytes, 0) != MAGIC) return error.Corruption;
    if (fmt.getU16(bytes, 4) != VERSION) return error.UnsupportedVersion;
    if (fmt.getU16(bytes, 6) != HEADER_SIZE) return error.Corruption;
    try fmt.requireZero(bytes[12..16]);
    try fmt.requireZero(bytes[28..36]);
    const crc = fmt.getU32(bytes, CRC_OFFSET);
    var tmp = [_]u8{0} ** HEADER_SIZE;
    @memcpy(&tmp, bytes);
    fmt.putU32(&tmp, CRC_OFFSET, 0);
    if (fmt.crc32c(&tmp) != crc) return error.Corruption;
    return .{ .directory_count = fmt.getU32(bytes, 8), .file_count = fmt.getU64(bytes, 16), .flags = fmt.getU32(bytes, 24), .crc = crc };
}

test "directory manifest roundtrips" {
    const encoded = encodeDirectoryManifest(.{ .directory_count = 3, .file_count = 9, .flags = 1 });
    const decoded = try decodeDirectoryManifest(&encoded);
    try std.testing.expectEqual(@as(u32, 3), decoded.directory_count);
    try std.testing.expectEqual(@as(u64, 9), decoded.file_count);
}
