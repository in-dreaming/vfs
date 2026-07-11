const std = @import("std");
const fmt = @import("common.zig");
const object_key = @import("../object_key.zig");

pub const MAGIC: u32 = fmt.magic32("VPKM");
pub const VERSION: u16 = 1;
pub const HEADER_SIZE: usize = 108;
const CRC_OFFSET: usize = 104;

pub const PackManifest = struct {
    pack_id: u64,
    flags: u32 = 0,
    pack_version: u64,
    build_id: u64,
    file_count: u64,
    tombstone_count: u64,
    path_index_key: u64 = object_key.pathIndexKey(),
    directory_manifest_key: u64 = object_key.directoryManifestKey(),
    content_hash: [32]u8 = [_]u8{0} ** 32,
    manifest_crc: u32 = 0,
};

pub fn encodePackManifest(input: PackManifest) [HEADER_SIZE]u8 {
    var out = [_]u8{0} ** HEADER_SIZE;
    fmt.putU32(&out, 0, MAGIC);
    fmt.putU16(&out, 4, VERSION);
    fmt.putU16(&out, 6, HEADER_SIZE);
    fmt.putU64(&out, 8, input.pack_id);
    fmt.putU32(&out, 16, input.flags);
    fmt.putU64(&out, 24, input.pack_version);
    fmt.putU64(&out, 32, input.build_id);
    fmt.putU64(&out, 40, input.file_count);
    fmt.putU64(&out, 48, input.tombstone_count);
    fmt.putU64(&out, 56, input.path_index_key);
    fmt.putU64(&out, 64, input.directory_manifest_key);
    @memcpy(out[72..104][0..32], &input.content_hash);
    fmt.putU32(&out, CRC_OFFSET, 0);
    fmt.putU32(&out, CRC_OFFSET, fmt.crc32c(&out));
    return out;
}

pub fn decodePackManifest(bytes: []const u8) !PackManifest {
    if (bytes.len < HEADER_SIZE) return error.Corruption;
    const slice = bytes[0..HEADER_SIZE];
    if (fmt.getU32(slice, 0) != MAGIC) return error.Corruption;
    if (fmt.getU16(slice, 4) != VERSION) return error.UnsupportedVersion;
    if (fmt.getU16(slice, 6) != HEADER_SIZE) return error.Corruption;
    try fmt.requireZero(slice[20..24]);

    const stored_crc = fmt.getU32(slice, CRC_OFFSET);
    var tmp = [_]u8{0} ** HEADER_SIZE;
    @memcpy(&tmp, slice);
    fmt.putU32(&tmp, CRC_OFFSET, 0);
    if (fmt.crc32c(&tmp) != stored_crc) return error.Corruption;

    var h: [32]u8 = undefined;
    @memcpy(&h, slice[72..104][0..32]);
    return .{
        .pack_id = fmt.getU64(slice, 8),
        .flags = fmt.getU32(slice, 16),
        .pack_version = fmt.getU64(slice, 24),
        .build_id = fmt.getU64(slice, 32),
        .file_count = fmt.getU64(slice, 40),
        .tombstone_count = fmt.getU64(slice, 48),
        .path_index_key = fmt.getU64(slice, 56),
        .directory_manifest_key = fmt.getU64(slice, 64),
        .content_hash = h,
        .manifest_crc = stored_crc,
    };
}

pub fn verifyPackManifest(bytes: []const u8) !void {
    _ = try decodePackManifest(bytes);
}

test "pack manifest roundtrips and rejects reserved corruption" {
    var m: PackManifest = .{
        .pack_id = 0x1111222233334444,
        .flags = 7,
        .pack_version = 9,
        .build_id = 10,
        .file_count = 11,
        .tombstone_count = 12,
    };
    m.content_hash[0] = 0xaa;
    const encoded = encodePackManifest(m);
    const decoded = try decodePackManifest(&encoded);
    try std.testing.expectEqual(m.pack_id, decoded.pack_id);
    try std.testing.expectEqual(m.path_index_key, decoded.path_index_key);
    try std.testing.expectEqualSlices(u8, &m.content_hash, &decoded.content_hash);

    var bad = encoded;
    bad[20] = 1;
    try std.testing.expectError(error.Corruption, decodePackManifest(&bad));
}
