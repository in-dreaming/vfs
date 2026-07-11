const std = @import("std");
const fmt = @import("common.zig");

pub const MAGIC: u32 = fmt.magic32("VVMF");
pub const VERSION: u16 = 1;
pub const HEADER_SIZE: usize = 64;
pub const RECORD_SIZE: usize = 32;
const CRC_OFFSET: usize = 60;

pub const MountInput = struct {
    pack_id: u64,
    pack_generation: u64,
    priority: u32,
    flags: u32 = 0,
    path: []const u8,
};

pub const MountRecord = struct {
    pack_id: u64,
    pack_generation: u64,
    priority: u32,
    flags: u32,
    path: []u8,
};

pub const VolumeManifest = struct {
    volume_id: u64,
    current_version: u64,
    writable_pack_id: u64 = 0,
    mounts: []const MountInput,
};

pub const DecodedVolumeManifest = struct {
    volume_id: u64,
    current_version: u64,
    writable_pack_id: u64,
    mounts: []MountRecord,

    pub fn deinit(self: *DecodedVolumeManifest, allocator: std.mem.Allocator) void {
        for (self.mounts) |mount| allocator.free(mount.path);
        allocator.free(self.mounts);
        self.* = undefined;
    }
};

pub fn encode(allocator: std.mem.Allocator, manifest: VolumeManifest) ![]u8 {
    if (manifest.volume_id == 0 or manifest.current_version == 0) return error.InvalidArgument;
    if (manifest.mounts.len > std.math.maxInt(u32)) return error.InvalidArgument;
    var strings = std.ArrayList(u8).empty;
    defer strings.deinit(allocator);
    for (manifest.mounts) |mount| {
        if (mount.pack_id == 0 or mount.pack_generation == 0 or mount.path.len == 0) return error.InvalidArgument;
        try strings.appendSlice(allocator, mount.path);
    }
    const total = HEADER_SIZE + manifest.mounts.len * RECORD_SIZE + strings.items.len;
    var out = try allocator.alloc(u8, total);
    errdefer allocator.free(out);
    @memset(out, 0);
    fmt.putU32(out, 0, MAGIC);
    fmt.putU16(out, 4, VERSION);
    fmt.putU16(out, 6, HEADER_SIZE);
    fmt.putU64(out, 8, manifest.volume_id);
    fmt.putU64(out, 16, manifest.current_version);
    fmt.putU32(out, 24, @intCast(manifest.mounts.len));
    fmt.putU64(out, 32, manifest.writable_pack_id);
    fmt.putU32(out, 40, @intCast(strings.items.len));
    fmt.putU32(out, CRC_OFFSET, 0);
    var string_offset: u32 = 0;
    for (manifest.mounts, 0..) |mount, i| {
        const rec = out[HEADER_SIZE + i * RECORD_SIZE ..][0..RECORD_SIZE];
        fmt.putU64(rec, 0, mount.pack_id);
        fmt.putU64(rec, 8, mount.pack_generation);
        fmt.putU32(rec, 16, mount.priority);
        fmt.putU32(rec, 20, mount.flags);
        fmt.putU32(rec, 24, string_offset);
        fmt.putU32(rec, 28, @intCast(mount.path.len));
        string_offset += @intCast(mount.path.len);
    }
    @memcpy(out[HEADER_SIZE + manifest.mounts.len * RECORD_SIZE ..], strings.items);
    fmt.putU32(out, CRC_OFFSET, fmt.crc32c(out));
    return out;
}

pub fn decode(allocator: std.mem.Allocator, bytes: []const u8) !DecodedVolumeManifest {
    if (bytes.len < HEADER_SIZE) return error.Corruption;
    if (fmt.getU32(bytes, 0) != MAGIC) return error.Corruption;
    if (fmt.getU16(bytes, 4) != VERSION) return error.UnsupportedVersion;
    if (fmt.getU16(bytes, 6) != HEADER_SIZE) return error.Corruption;
    try fmt.requireZero(bytes[28..32]);
    try fmt.requireZero(bytes[44..60]);
    const stored_crc = fmt.getU32(bytes, CRC_OFFSET);
    const tmp = try allocator.dupe(u8, bytes);
    defer allocator.free(tmp);
    fmt.putU32(tmp, CRC_OFFSET, 0);
    if (fmt.crc32c(tmp) != stored_crc) return error.Corruption;
    const mount_count = fmt.getU32(bytes, 24);
    const strings_size = fmt.getU32(bytes, 40);
    const strings_start = HEADER_SIZE + @as(usize, mount_count) * RECORD_SIZE;
    if (bytes.len != strings_start + strings_size) return error.Corruption;
    const strings = bytes[strings_start..];
    const mounts = try allocator.alloc(MountRecord, mount_count);
    errdefer {
        for (mounts) |mount| allocator.free(mount.path);
        allocator.free(mounts);
    }
    for (mounts, 0..) |*mount, i| {
        const rec = bytes[HEADER_SIZE + i * RECORD_SIZE ..][0..RECORD_SIZE];
        const path_offset = fmt.getU32(rec, 24);
        const path_size = fmt.getU32(rec, 28);
        if (@as(usize, path_offset) + path_size > strings.len) return error.Corruption;
        mount.* = .{
            .pack_id = fmt.getU64(rec, 0),
            .pack_generation = fmt.getU64(rec, 8),
            .priority = fmt.getU32(rec, 16),
            .flags = fmt.getU32(rec, 20),
            .path = try allocator.dupe(u8, strings[path_offset..][0..path_size]),
        };
        if (mount.pack_id == 0 or mount.pack_generation == 0 or mount.path.len == 0) return error.Corruption;
    }
    return .{
        .volume_id = fmt.getU64(bytes, 8),
        .current_version = fmt.getU64(bytes, 16),
        .writable_pack_id = fmt.getU64(bytes, 32),
        .mounts = mounts,
    };
}

test "volume manifest roundtrips and validates crc" {
    const allocator = std.testing.allocator;
    const mounts = [_]MountInput{
        .{ .pack_id = 1, .pack_generation = 2, .priority = 10, .path = "pack-a" },
        .{ .pack_id = 2, .pack_generation = 3, .priority = 20, .flags = 1, .path = "pack-b" },
    };
    const bytes = try encode(allocator, .{ .volume_id = 9, .current_version = 4, .writable_pack_id = 2, .mounts = &mounts });
    defer allocator.free(bytes);
    var decoded = try decode(allocator, bytes);
    defer decoded.deinit(allocator);
    try std.testing.expectEqual(@as(u64, 4), decoded.current_version);
    try std.testing.expectEqualStrings("pack-b", decoded.mounts[1].path);
    var bad = try allocator.dupe(u8, bytes);
    defer allocator.free(bad);
    bad[bad.len - 1] ^= 1;
    try std.testing.expectError(error.Corruption, decode(allocator, bad));
}
