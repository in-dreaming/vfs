//! Loads a pack into memory as a classified object set (docs/vfs/diff_patch.md §12.3).
//!
//! Every live object is read once and classified by its value magic; the
//! identity lives in each header, so no key reverse-mapping is needed.
const std = @import("std");
const db_internal = @import("db_internal");
const kv = db_internal.kv_db;
const pack_manifest_fmt = @import("../format/pack_manifest.zig");
const file_manifest_fmt = @import("../format/file_manifest.zig");
const page_value_fmt = @import("../format/page_value.zig");
const tombstone_fmt = @import("../format/tombstone.zig");
const path_index_fmt = @import("../format/path_index.zig");
const directory_manifest_fmt = @import("../format/directory_manifest.zig");
const page_placeholder_fmt = @import("../format/page_placeholder.zig");
const fmt = @import("../format/common.zig");
const object_key = @import("../object_key.zig");

pub const FileImage = struct {
    manifest_bytes: []u8,
    manifest: file_manifest_fmt.DecodedFileManifest,
};

pub const PageImage = struct {
    /// Full encoded PageValue.
    bytes: []u8,
    identity: page_value_fmt.PageIdentity,
    codec: file_manifest_fmt.Codec,
    raw_size: u32,
    stored_size: u32,
    raw_crc: u32,
    stored_crc: u32,
};

pub const PackImage = struct {
    allocator: std.mem.Allocator,
    path: []u8,
    manifest: pack_manifest_fmt.PackManifest,
    path_index_bytes: []u8,
    path_entries: []path_index_fmt.DecodedEntry,
    directory_manifest_bytes: ?[]u8 = null,
    files: std.AutoHashMapUnmanaged(u64, FileImage) = .empty,
    tombstones: std.AutoHashMapUnmanaged(u64, []u8) = .empty,
    pages: std.AutoHashMapUnmanaged(u64, PageImage) = .empty,
    placeholders: std.AutoHashMapUnmanaged(u64, void) = .empty,
    unknown_objects: u32 = 0,
    shard_count: u32 = 1,

    pub fn load(allocator: std.mem.Allocator, pack_path: []const u8) !PackImage {
        var db = try kv.KvDb.open(pack_path, .{ .mode = .read_only, .create_if_missing = false });
        defer db.close() catch {};

        var self: PackImage = .{
            .allocator = allocator,
            .path = try allocator.dupe(u8, pack_path),
            .manifest = undefined,
            .path_index_bytes = &.{},
            .path_entries = &.{},
            .shard_count = db.shardCount(),
        };
        errdefer self.deinit();

        var have_manifest = false;
        const live = try db.collectLiveKeys(allocator);
        defer allocator.free(live);
        for (live) |entry| {
            var key_buf: [64]u8 = undefined;
            const key_len = try db.readKeyBytes(entry.info, &key_buf);
            if (key_len != 8) {
                self.unknown_objects += 1;
                continue;
            }
            const key_bytes = key_buf[0..8];
            const obj_key = object_key.decodeDbKey(key_bytes[0..8]);
            const value = try allocator.dupe(u8, try db.getBorrowedBytes(key_bytes));
            var keep = false;
            defer if (!keep) allocator.free(value);
            if (value.len < 4) {
                self.unknown_objects += 1;
                continue;
            }
            const magic = fmt.getU32(value, 0);
            if (magic == pack_manifest_fmt.MAGIC) {
                self.manifest = try pack_manifest_fmt.decodePackManifest(value);
                have_manifest = true;
            } else if (magic == file_manifest_fmt.MAGIC) {
                var decoded = try file_manifest_fmt.decodeFileManifest(allocator, value, null);
                errdefer decoded.deinit(allocator);
                if (try object_key.fileManifestKey(decoded.header.file_entry) != obj_key) return error.Corruption;
                const gop = try self.files.getOrPut(allocator, decoded.header.file_entry);
                if (gop.found_existing) return error.Corruption;
                gop.value_ptr.* = .{ .manifest_bytes = value, .manifest = decoded };
                keep = true;
            } else if (magic == page_value_fmt.MAGIC) {
                if (value.len < page_value_fmt.HEADER_SIZE) return error.Corruption;
                const identity: page_value_fmt.PageIdentity = .{ .file_entry = fmt.getU64(value, 8), .block_index = fmt.getU32(value, 16), .page_index = fmt.getU32(value, 20) };
                const pv = try page_value_fmt.decodePageValue(value, identity);
                if (try object_key.pageKey(identity.file_entry, identity.block_index, identity.page_index) != obj_key) return error.Corruption;
                try self.pages.put(allocator, obj_key, .{
                    .bytes = value,
                    .identity = identity,
                    .codec = pv.codec,
                    .raw_size = pv.raw_size,
                    .stored_size = pv.stored_size,
                    .raw_crc = pv.raw_crc,
                    .stored_crc = pv.stored_crc,
                });
                keep = true;
            } else if (magic == tombstone_fmt.ENTRY_MAGIC) {
                const t = try tombstone_fmt.decodeEntryTombstone(value, null);
                if (try object_key.entryTombstoneKey(t.file_entry) != obj_key) return error.Corruption;
                try self.tombstones.put(allocator, t.file_entry, value);
                keep = true;
            } else if (magic == path_index_fmt.MAGIC) {
                if (obj_key != object_key.pathIndexKey()) return error.Corruption;
                self.path_index_bytes = value;
                self.path_entries = try path_index_fmt.collectEntries(allocator, value);
                keep = true;
            } else if (magic == directory_manifest_fmt.MAGIC) {
                if (obj_key != object_key.directoryManifestKey()) return error.Corruption;
                self.directory_manifest_bytes = value;
                keep = true;
            } else if (magic == page_placeholder_fmt.MAGIC) {
                try self.placeholders.put(allocator, obj_key, {});
            } else {
                self.unknown_objects += 1;
            }
        }
        if (!have_manifest) return error.Corruption;
        return self;
    }

    pub fn deinit(self: *PackImage) void {
        const a = self.allocator;
        a.free(self.path);
        if (self.path_index_bytes.len != 0) a.free(self.path_index_bytes);
        if (self.path_entries.len != 0) path_index_fmt.freeDecodedEntries(a, self.path_entries);
        if (self.directory_manifest_bytes) |d| a.free(d);
        var fit = self.files.iterator();
        while (fit.next()) |e| {
            a.free(e.value_ptr.manifest_bytes);
            e.value_ptr.manifest.deinit(a);
        }
        self.files.deinit(a);
        var tit = self.tombstones.iterator();
        while (tit.next()) |e| a.free(e.value_ptr.*);
        self.tombstones.deinit(a);
        var pit = self.pages.iterator();
        while (pit.next()) |e| a.free(e.value_ptr.bytes);
        self.pages.deinit(a);
        self.placeholders.deinit(a);
        self.* = undefined;
    }

    pub fn page(self: *const PackImage, file_entry: u64, block_index: u32, page_index: u32) ?*const PageImage {
        const key = object_key.pageKey(file_entry, block_index, page_index) catch return null;
        return self.pages.getPtr(key);
    }

    pub fn pathEntry(self: *const PackImage, normalized_path: []const u8) ?path_index_fmt.DecodedEntry {
        for (self.path_entries) |e| if (std.mem.eql(u8, e.normalized_path, normalized_path)) return e;
        return null;
    }
};

test "pack scan classifies every object of a built pack" {
    const allocator = std.testing.allocator;
    const builder = @import("../build/pack_builder.zig");
    const io = std.Io.Threaded.global_single_threaded.io();
    const pack_path = "zig-cache-vfs-scan-pack";
    const src_a = "zig-cache-vfs-scan-a.bin";
    const src_b = "zig-cache-vfs-scan-b.bin";
    _ = std.Io.Dir.cwd().deleteTree(io, pack_path) catch {};
    defer _ = std.Io.Dir.cwd().deleteTree(io, pack_path) catch {};
    defer _ = std.Io.Dir.cwd().deleteFile(io, src_a) catch {};
    defer _ = std.Io.Dir.cwd().deleteFile(io, src_b) catch {};
    try builder.writeSourceFileForTest(src_a, "a" ** 5000);
    try builder.writeSourceFileForTest(src_b, "");
    try builder.createPack(pack_path, &.{
        .{ .source_path = src_a, .virtual_path = "/a.bin", .file_entry = 11, .page_size = 2048, .codec = .lz4 },
        .{ .source_path = src_b, .virtual_path = "/b.bin", .file_entry = 12, .page_size = 2048 },
    }, .{ .pack_id = 4, .pack_version = 2, .shards = 2 });
    var img = try PackImage.load(allocator, pack_path);
    defer img.deinit();
    try std.testing.expectEqual(@as(u64, 4), img.manifest.pack_id);
    try std.testing.expectEqual(@as(u32, 2), img.shard_count);
    try std.testing.expectEqual(@as(usize, 2), img.files.count());
    try std.testing.expectEqual(@as(usize, 3), img.pages.count());
    try std.testing.expectEqual(@as(usize, 2), img.path_entries.len);
    try std.testing.expectEqual(@as(u32, 0), img.unknown_objects);
    const p = img.page(11, 0, 2).?;
    try std.testing.expectEqual(@as(u32, 904), p.raw_size);
    try std.testing.expect(img.page(11, 0, 3) == null);
    try std.testing.expectEqual(@as(u64, 12), img.pathEntry("b.bin").?.file_entry);
}
