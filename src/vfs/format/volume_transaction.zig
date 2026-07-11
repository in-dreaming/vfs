const std = @import("std");
const fmt = @import("common.zig");
const volume_manifest = @import("volume_manifest.zig");

pub const MAGIC: u32 = fmt.magic32("VVTX");
pub const VERSION: u16 = 1;
pub const HEADER_SIZE: usize = 72;
const CRC_OFFSET: usize = 68;

pub const State = enum(u32) {
    prepared = 1,
    committed = 2,
    _,
};

pub const VolumeTransaction = struct {
    volume_id: u64,
    from_version: u64,
    to_version: u64,
    state: State,
    writable_pack_id: u64 = 0,
    mounts: []const volume_manifest.MountInput,
};

pub const DecodedVolumeTransaction = struct {
    volume_id: u64,
    from_version: u64,
    to_version: u64,
    state: State,
    writable_pack_id: u64,
    mounts: []volume_manifest.MountRecord,

    pub fn deinit(self: *DecodedVolumeTransaction, allocator: std.mem.Allocator) void {
        for (self.mounts) |mount| allocator.free(mount.path);
        allocator.free(self.mounts);
        self.* = undefined;
    }
};

pub fn encode(allocator: std.mem.Allocator, tx: VolumeTransaction) ![]u8 {
    if (tx.volume_id == 0 or tx.from_version == 0 or tx.to_version <= tx.from_version) return error.InvalidArgument;
    const manifest_bytes = try volume_manifest.encode(allocator, .{ .volume_id = tx.volume_id, .current_version = tx.to_version, .writable_pack_id = tx.writable_pack_id, .mounts = tx.mounts });
    defer allocator.free(manifest_bytes);
    const body = manifest_bytes[volume_manifest.HEADER_SIZE..];
    const total = HEADER_SIZE + body.len;
    var out = try allocator.alloc(u8, total);
    errdefer allocator.free(out);
    @memset(out, 0);
    fmt.putU32(out, 0, MAGIC);
    fmt.putU16(out, 4, VERSION);
    fmt.putU16(out, 6, HEADER_SIZE);
    fmt.putU64(out, 8, tx.volume_id);
    fmt.putU64(out, 16, tx.from_version);
    fmt.putU64(out, 24, tx.to_version);
    fmt.putU32(out, 32, @intFromEnum(tx.state));
    fmt.putU32(out, 36, @intCast(tx.mounts.len));
    fmt.putU64(out, 40, tx.writable_pack_id);
    fmt.putU32(out, 48, @intCast(body.len - tx.mounts.len * volume_manifest.RECORD_SIZE));
    @memcpy(out[HEADER_SIZE..], body);
    fmt.putU32(out, CRC_OFFSET, fmt.crc32c(out));
    return out;
}

pub fn decode(allocator: std.mem.Allocator, bytes: []const u8) !DecodedVolumeTransaction {
    if (bytes.len < HEADER_SIZE) return error.Corruption;
    if (fmt.getU32(bytes, 0) != MAGIC) return error.Corruption;
    if (fmt.getU16(bytes, 4) != VERSION) return error.UnsupportedVersion;
    if (fmt.getU16(bytes, 6) != HEADER_SIZE) return error.Corruption;
    try fmt.requireZero(bytes[52..68]);
    const stored_crc = fmt.getU32(bytes, CRC_OFFSET);
    const tmp = try allocator.dupe(u8, bytes);
    defer allocator.free(tmp);
    fmt.putU32(tmp, CRC_OFFSET, 0);
    if (fmt.crc32c(tmp) != stored_crc) return error.Corruption;
    const mount_count = fmt.getU32(bytes, 36);
    const strings_size = fmt.getU32(bytes, 48);
    const body_size = @as(usize, mount_count) * volume_manifest.RECORD_SIZE + strings_size;
    if (bytes.len != HEADER_SIZE + body_size) return error.Corruption;

    const manifest_bytes = try allocator.alloc(u8, volume_manifest.HEADER_SIZE + body_size);
    defer allocator.free(manifest_bytes);
    @memset(manifest_bytes, 0);
    fmt.putU32(manifest_bytes, 0, volume_manifest.MAGIC);
    fmt.putU16(manifest_bytes, 4, volume_manifest.VERSION);
    fmt.putU16(manifest_bytes, 6, volume_manifest.HEADER_SIZE);
    fmt.putU64(manifest_bytes, 8, fmt.getU64(bytes, 8));
    fmt.putU64(manifest_bytes, 16, fmt.getU64(bytes, 24));
    fmt.putU32(manifest_bytes, 24, mount_count);
    fmt.putU64(manifest_bytes, 32, fmt.getU64(bytes, 40));
    fmt.putU32(manifest_bytes, 40, strings_size);
    @memcpy(manifest_bytes[volume_manifest.HEADER_SIZE..], bytes[HEADER_SIZE..]);
    fmt.putU32(manifest_bytes, 60, fmt.crc32c(manifest_bytes));
    var manifest = try volume_manifest.decode(allocator, manifest_bytes);
    errdefer manifest.deinit(allocator);
    return .{
        .volume_id = fmt.getU64(bytes, 8),
        .from_version = fmt.getU64(bytes, 16),
        .to_version = fmt.getU64(bytes, 24),
        .state = @enumFromInt(fmt.getU32(bytes, 32)),
        .writable_pack_id = fmt.getU64(bytes, 40),
        .mounts = manifest.mounts,
    };
}

test "volume transaction roundtrips prepared and committed states" {
    const allocator = std.testing.allocator;
    const mounts = [_]volume_manifest.MountInput{.{ .pack_id = 1, .pack_generation = 2, .priority = 10, .path = "pack" }};
    const bytes = try encode(allocator, .{ .volume_id = 1, .from_version = 1, .to_version = 2, .state = .prepared, .mounts = &mounts });
    defer allocator.free(bytes);
    var decoded = try decode(allocator, bytes);
    defer decoded.deinit(allocator);
    try std.testing.expectEqual(State.prepared, decoded.state);
    try std.testing.expectEqual(@as(u64, 2), decoded.to_version);
}
