const std = @import("std");
const fmt = @import("common.zig");
const object_key = @import("../object_key.zig");

pub const MAGIC: u32 = fmt.magic32("VPKM");
/// v1: 108-byte header. v2 (current): 140-byte header with overlay fields.
pub const VERSION: u16 = 2;
pub const V1_HEADER_SIZE: usize = 108;
pub const HEADER_SIZE: usize = 140;
const V1_CRC_OFFSET: usize = 104;
const CRC_OFFSET: usize = 136;

/// This pack is an overlay layered above a base pack with the same pack_id.
pub const PACK_FLAG_OVERLAY: u32 = 1 << 0;

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
    /// Overlay link (valid when `flags & PACK_FLAG_OVERLAY`).
    base_pack_id: u64 = 0,
    base_pack_version: u64 = 0,
    base_pack_generation: u64 = 0,
    overlay_flags: u32 = 0,
    manifest_crc: u32 = 0,

    pub fn isOverlay(self: PackManifest) bool {
        return (self.flags & PACK_FLAG_OVERLAY) != 0;
    }
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
    fmt.putU64(&out, 104, input.base_pack_id);
    fmt.putU64(&out, 112, input.base_pack_version);
    fmt.putU64(&out, 120, input.base_pack_generation);
    fmt.putU32(&out, 128, input.overlay_flags);
    fmt.putU32(&out, CRC_OFFSET, fmt.crc32cWithZeroU32(&out, CRC_OFFSET));
    return out;
}

pub fn decodePackManifest(bytes: []const u8) !PackManifest {
    if (bytes.len < 8) return error.Corruption;
    if (fmt.getU32(bytes, 0) != MAGIC) return error.Corruption;
    const version = fmt.getU16(bytes, 4);
    const header_size = fmt.getU16(bytes, 6);
    switch (version) {
        1 => {
            if (header_size != V1_HEADER_SIZE or bytes.len < V1_HEADER_SIZE) return error.Corruption;
            const slice = bytes[0..V1_HEADER_SIZE];
            try fmt.requireZero(slice[20..24]);
            const stored_crc = fmt.getU32(slice, V1_CRC_OFFSET);
            if (fmt.crc32cWithZeroU32(slice, V1_CRC_OFFSET) != stored_crc) return error.Corruption;
            return commonFields(slice, stored_crc);
        },
        2 => {
            if (header_size != HEADER_SIZE or bytes.len < HEADER_SIZE) return error.Corruption;
            const slice = bytes[0..HEADER_SIZE];
            try fmt.requireZero(slice[20..24]);
            try fmt.requireZero(slice[132..136]);
            const stored_crc = fmt.getU32(slice, CRC_OFFSET);
            if (fmt.crc32cWithZeroU32(slice, CRC_OFFSET) != stored_crc) return error.Corruption;
            var m = commonFields(slice, stored_crc);
            m.base_pack_id = fmt.getU64(slice, 104);
            m.base_pack_version = fmt.getU64(slice, 112);
            m.base_pack_generation = fmt.getU64(slice, 120);
            m.overlay_flags = fmt.getU32(slice, 128);
            if (m.isOverlay() and m.base_pack_id != m.pack_id) return error.Corruption;
            return m;
        },
        else => return error.UnsupportedVersion,
    }
}

fn commonFields(slice: []const u8, stored_crc: u32) PackManifest {
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

/// Test/compat helper: encode the legacy v1 layout.
pub fn encodePackManifestV1(input: PackManifest) [V1_HEADER_SIZE]u8 {
    var out = [_]u8{0} ** V1_HEADER_SIZE;
    fmt.putU32(&out, 0, MAGIC);
    fmt.putU16(&out, 4, 1);
    fmt.putU16(&out, 6, V1_HEADER_SIZE);
    fmt.putU64(&out, 8, input.pack_id);
    fmt.putU32(&out, 16, input.flags);
    fmt.putU64(&out, 24, input.pack_version);
    fmt.putU64(&out, 32, input.build_id);
    fmt.putU64(&out, 40, input.file_count);
    fmt.putU64(&out, 48, input.tombstone_count);
    fmt.putU64(&out, 56, input.path_index_key);
    fmt.putU64(&out, 64, input.directory_manifest_key);
    @memcpy(out[72..104][0..32], &input.content_hash);
    fmt.putU32(&out, V1_CRC_OFFSET, fmt.crc32cWithZeroU32(&out, V1_CRC_OFFSET));
    return out;
}

test "pack manifest roundtrips and rejects reserved corruption" {
    var m: PackManifest = .{
        .pack_id = 0x1111222233334444,
        .flags = 6,
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
    try std.testing.expect(!decoded.isOverlay());

    var bad = encoded;
    bad[20] = 1;
    try std.testing.expectError(error.Corruption, decodePackManifest(&bad));
    var bad2 = encoded;
    bad2[133] = 1;
    try std.testing.expectError(error.Corruption, decodePackManifest(&bad2));
}

test "pack manifest v2 overlay fields and v1 compatibility" {
    const ov: PackManifest = .{ .pack_id = 5, .flags = PACK_FLAG_OVERLAY, .pack_version = 3, .build_id = 1, .file_count = 0, .tombstone_count = 0, .base_pack_id = 5, .base_pack_version = 2, .base_pack_generation = 2, .overlay_flags = 1 };
    const enc = encodePackManifest(ov);
    const dec = try decodePackManifest(&enc);
    try std.testing.expect(dec.isOverlay());
    try std.testing.expectEqual(@as(u64, 2), dec.base_pack_version);
    try std.testing.expectEqual(@as(u32, 1), dec.overlay_flags);
    // overlay with mismatched base id is rejected
    var bad_ov = ov;
    bad_ov.base_pack_id = 6;
    try std.testing.expectError(error.Corruption, decodePackManifest(&encodePackManifest(bad_ov)));

    const v1 = encodePackManifestV1(.{ .pack_id = 9, .pack_version = 4, .build_id = 2, .file_count = 3, .tombstone_count = 1 });
    const d1 = try decodePackManifest(&v1);
    try std.testing.expectEqual(@as(u64, 9), d1.pack_id);
    try std.testing.expectEqual(@as(u64, 4), d1.pack_version);
    try std.testing.expectEqual(@as(u64, 0), d1.base_pack_id);
    var bad_v1 = v1;
    bad_v1[30] ^= 1;
    try std.testing.expectError(error.Corruption, decodePackManifest(&bad_v1));
}
