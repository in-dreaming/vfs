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

pub fn encodeDbKey(key: ObjectKey) [8]u8 {
    var b = [_]u8{0} ** 8;
    fmt.putU64(&b, 0, key);
    return b;
}

pub fn decodeDbKey(bytes: *const [8]u8) ObjectKey {
    return fmt.getU64(bytes, 0);
}

pub fn reservedKeys() [4]ObjectKey {
    return .{ 0, packManifestKey(), pathIndexKey(), directoryManifestKey() };
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
