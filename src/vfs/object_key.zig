const std = @import("std");
const hash = @import("hash.zig");
const fmt = @import("format/common.zig");

pub const ObjectKey = u64;

pub fn packManifestKey() ObjectKey {
    return hash.hash64("vfs.object.singleton.v1", "pack-manifest");
}

pub fn pathIndexKey() ObjectKey {
    return hash.hash64("vfs.object.singleton.v1", "path-index");
}

pub fn directoryManifestKey() ObjectKey {
    return hash.hash64("vfs.object.singleton.v1", "directory-manifest");
}

pub fn fileManifestKey(file_entry: u64) !ObjectKey {
    if (file_entry == 0) return error.InvalidFileEntry;
    const key = hash.hashIdentity1("vfs.file-manifest.v1", file_entry);
    if (isReservedKey(key)) return error.KeyCollision;
    return key;
}

pub fn pageKey(file_entry: u64, block_index: u32, page_index: u32) !ObjectKey {
    if (file_entry == 0) return error.InvalidFileEntry;
    const key = hash.hashIdentity3("vfs.page.v1", file_entry, block_index, page_index);
    if (isReservedKey(key)) return error.KeyCollision;
    return key;
}

pub fn entryTombstoneKey(file_entry: u64) !ObjectKey {
    if (file_entry == 0) return error.InvalidFileEntry;
    const key = hash.hashIdentity1("vfs.entry-tombstone.v1", file_entry);
    if (isReservedKey(key)) return error.KeyCollision;
    return key;
}

/// Marks an in-progress patch on the target pack (docs/vfs/diff_patch.md §14).
pub fn patchIntentKey() ObjectKey {
    return hash.hash64("vfs.object.singleton.v1", "patch-intent");
}

// ---- DiffPack object keys (a DiffPack is its own libdb store) ----

pub fn diffManifestKey() ObjectKey {
    return hash.hash64("vfs.diff.singleton.v1", "diff-manifest");
}

pub fn diffFileOpTableKey() ObjectKey {
    return hash.hash64("vfs.diff.singleton.v1", "file-op-table");
}

pub fn diffPathDeltaKey() ObjectKey {
    return hash.hash64("vfs.diff.singleton.v1", "path-delta");
}

pub fn diffUnitTableKey(shard: u32) ObjectKey {
    return hash.hashIdentity1("vfs.diff.unit-table.v1", shard);
}

pub fn diffChunkKey(chunk_id: u32) ObjectKey {
    return hash.hashIdentity1("vfs.diff.chunk.v1", chunk_id);
}

/// Data shard used by builders and patchers for every object of a file
/// (pages, manifest, tombstone). Keeping a file inside one shard makes a
/// patch unit's writes atomic within one shard batch and keeps its pages
/// physically adjacent. The DB itself routes reads by `IndexInfo.data_db_id`,
/// so this is a placement policy, not a lookup rule.
pub fn fileShard(file_entry: u64, shard_count: u32) u32 {
    if (shard_count <= 1 or file_entry == 0) return 0;
    const h = std.hash.Wyhash.hash(0x7366735f73686172, std.mem.asBytes(&file_entry));
    return @intCast(h % shard_count);
}

pub fn encodeDbKey(key: ObjectKey) [8]u8 {
    var b = [_]u8{0} ** 8;
    fmt.putU64(&b, 0, key);
    return b;
}

pub fn decodeDbKey(bytes: *const [8]u8) ObjectKey {
    return fmt.getU64(bytes, 0);
}

pub fn reservedKeys() [5]ObjectKey {
    return .{ 0, packManifestKey(), pathIndexKey(), directoryManifestKey(), patchIntentKey() };
}

pub fn isReservedKey(key: ObjectKey) bool {
    for (reservedKeys()) |reserved| {
        if (key == reserved) return true;
    }
    return false;
}

pub fn ensureNoReservedConflict(key: ObjectKey) !void {
    if (isReservedKey(key)) return error.KeyCollision;
}

test "object keys are stable, little-endian DB keys, and reject invalid file_entry" {
    try std.testing.expectEqual(packManifestKey(), packManifestKey());
    try std.testing.expectEqual(try fileManifestKey(42), try fileManifestKey(42));
    try std.testing.expectEqual(try pageKey(42, 7, 9), try pageKey(42, 7, 9));
    try std.testing.expectEqual(try entryTombstoneKey(42), try entryTombstoneKey(42));
    try std.testing.expect((try fileManifestKey(42)) != (try pageKey(42, 0, 0)));
    try std.testing.expectError(error.InvalidFileEntry, fileManifestKey(0));
    try std.testing.expectError(error.InvalidFileEntry, pageKey(0, 0, 0));
    try std.testing.expectError(error.InvalidFileEntry, entryTombstoneKey(0));

    const bytes = encodeDbKey(0x0123456789abcdef);
    try std.testing.expectEqualSlices(u8, &.{ 0xef, 0xcd, 0xab, 0x89, 0x67, 0x45, 0x23, 0x01 }, &bytes);
    try std.testing.expectEqual(@as(u64, 0x0123456789abcdef), decodeDbKey(&bytes));
}

test "reserved singleton keys do not collide with common file/page keys" {
    for (reservedKeys()) |key| try std.testing.expect(isReservedKey(key));
    const entries = [_]u64{ 1, 2, 3, 42, 0xffff_ffff_ffff_ffff };
    for (entries) |entry| {
        try ensureNoReservedConflict(try fileManifestKey(entry));
        try ensureNoReservedConflict(try pageKey(entry, 0, 0));
        try ensureNoReservedConflict(try pageKey(entry, 3, 1024));
        try ensureNoReservedConflict(try entryTombstoneKey(entry));
    }
}
