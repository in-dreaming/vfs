const std = @import("std");
const db_internal = @import("db_internal");
const kv = db_internal.kv_db;
const object_key = @import("../object_key.zig");
const path_mod = @import("../path.zig");
const pack_manifest_fmt = @import("../format/pack_manifest.zig");
const path_index_fmt = @import("../format/path_index.zig");
const file_manifest_fmt = @import("../format/file_manifest.zig");
const page_value_fmt = @import("../format/page_value.zig");
const tombstone_fmt = @import("../format/tombstone.zig");

pub const Stat = struct {
    file_entry: u64,
    size: u64,
    page_size: u64,
};

pub const OpenOptions = struct {
    /// Extra read-only OS handles on the data file so concurrent page reads
    /// are not serialized by the kernel on one file object (Windows).
    read_handles: u8 = DEFAULT_READ_HANDLES,
};

pub const DEFAULT_READ_HANDLES: u8 = 4;

pub const PackReader = struct {
    db: kv.KvDb,
    manifest: pack_manifest_fmt.PackManifest,
    /// Owned immutable backing storage for path_index_view. Both are replaced
    /// together when mounted metadata is refreshed after an admitted update.
    path_index: []const u8,
    path_index_view: path_index_fmt.VerifiedView,

    pub fn open(allocator: std.mem.Allocator, pack_path: []const u8) !PackReader {
        return openWithOptions(allocator, pack_path, .{});
    }

    pub fn openWithOptions(allocator: std.mem.Allocator, pack_path: []const u8, options: OpenOptions) !PackReader {
        var db = try kv.KvDb.open(pack_path, .{ .mode = .read_only, .create_if_missing = false, .read_handles = options.read_handles });
        errdefer db.close() catch {};
        const manifest_bytes = try readObjectFromDb(&db, allocator, object_key.packManifestKey());
        defer allocator.free(manifest_bytes);
        const manifest = try pack_manifest_fmt.decodePackManifest(manifest_bytes);
        const path_index = try readObjectFromDb(&db, allocator, manifest.path_index_key);
        errdefer allocator.free(path_index);
        const path_index_view = try path_index_fmt.VerifiedView.init(path_index);
        return .{ .db = db, .manifest = manifest, .path_index = path_index, .path_index_view = path_index_view };
    }

    pub fn close(self: *PackReader, allocator: std.mem.Allocator) void {
        allocator.free(self.path_index);
        self.path_index = &.{};
        self.path_index_view = undefined;
        self.db.close() catch {};
    }

    pub fn isReady(self: *const PackReader) bool {
        return !self.db.isParked();
    }

    pub fn park(self: *PackReader) !void {
        try self.db.park();
    }

    pub fn ensureReady(self: *PackReader) !void {
        try self.db.ensureReady();
    }

    pub fn resolvePath(self: *PackReader, allocator: std.mem.Allocator, virtual_path: []const u8) !u64 {
        const normalized = try path_mod.normalizeVirtualPath(allocator, virtual_path);
        defer allocator.free(normalized);
        const found = self.path_index_view.lookup(normalized);
        return if (found) |entry| entry.file_entry else error.NotFound;
    }

    pub fn readFileManifest(self: *PackReader, allocator: std.mem.Allocator, file_entry: u64) !file_manifest_fmt.DecodedFileManifest {
        if (file_entry == 0) return error.InvalidArgument;
        const bytes = try self.readObjectAlloc(allocator, try object_key.fileManifestKey(file_entry));
        defer allocator.free(bytes);
        return file_manifest_fmt.decodeFileManifest(allocator, bytes, file_entry);
    }

    pub fn hasEntryTombstone(self: *PackReader, allocator: std.mem.Allocator, file_entry: u64) !bool {
        if (file_entry == 0) return error.InvalidArgument;
        const bytes = self.readObjectAlloc(allocator, try object_key.entryTombstoneKey(file_entry)) catch |e| switch (e) {
            error.NotFound => return false,
            else => |err| return err,
        };
        defer allocator.free(bytes);
        _ = try tombstone_fmt.decodeEntryTombstone(bytes, file_entry);
        return true;
    }

    pub fn statEntry(self: *PackReader, allocator: std.mem.Allocator, file_entry: u64) !Stat {
        var decoded = try self.readFileManifest(allocator, file_entry);
        defer decoded.deinit(allocator);
        const page_size: u64 = if (decoded.blocks.len == 0) 0 else decoded.blocks[0].page_size;
        return .{ .file_entry = file_entry, .size = decoded.header.file_size, .page_size = page_size };
    }

    pub fn readPageAlloc(self: *PackReader, allocator: std.mem.Allocator, file_entry: u64, block_index: u32, page_index: u32) ![]u8 {
        return self.readObjectAlloc(allocator, try object_key.pageKey(file_entry, block_index, page_index));
    }

    pub fn readObjectAlloc(self: *PackReader, allocator: std.mem.Allocator, key: u64) ![]u8 {
        if (self.db.isParked()) return error.Busy;
        return readObjectFromDb(&self.db, allocator, key);
    }

    /// Single-syscall object read. The returned slice is a thread-local
    /// borrow valid until the next DB read on this thread; copy out before
    /// touching the pack again.
    pub fn readObjectBorrow(self: *PackReader, key: u64) ![]const u8 {
        if (self.db.isParked()) return error.Busy;
        var key_bytes = object_key.encodeDbKey(key);
        return self.db.getBorrowedBytes(&key_bytes);
    }
};

fn readObjectFromDb(db: *kv.KvDb, allocator: std.mem.Allocator, key: u64) ![]u8 {
    var key_bytes = object_key.encodeDbKey(key);
    const borrowed = try db.getBorrowedBytes(&key_bytes);
    return allocator.dupe(u8, borrowed);
}

test "pack reader resolves path and entry from builder output" {
    const builder = @import("../build/pack_builder.zig");
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    const pack_path = "zig-cache-vfs-pack-reader-test";
    const source_path = "zig-cache-vfs-pack-reader-source.bin";
    _ = std.Io.Dir.cwd().deleteTree(io, pack_path) catch {};
    _ = std.Io.Dir.cwd().deleteFile(io, source_path) catch {};
    defer _ = std.Io.Dir.cwd().deleteTree(io, pack_path) catch {};
    defer _ = std.Io.Dir.cwd().deleteFile(io, source_path) catch {};
    try builder.writeSourceFileForTest(source_path, "reader-data");
    const input = builder.BuildFileInput{ .source_path = source_path, .virtual_path = "/reader.bin", .file_entry = 501, .page_size = 4 };
    try builder.createPack(pack_path, &.{input}, .{});

    var reader = try PackReader.open(allocator, pack_path);
    defer reader.close(allocator);
    for (0..128) |_| {
        try std.testing.expectEqual(@as(u64, 501), try reader.resolvePath(allocator, "/reader.bin"));
        try std.testing.expectError(error.NotFound, reader.resolvePath(allocator, "/missing.bin"));
    }
    const index_bytes = reader.path_index.ptr;
    try reader.park();
    try reader.ensureReady();
    try std.testing.expectEqual(index_bytes, reader.path_index.ptr);
    try std.testing.expectEqual(index_bytes, reader.path_index_view.bytes.ptr);
    try std.testing.expectEqual(@as(u64, 501), try reader.resolvePath(allocator, "/reader.bin"));
    var manifest = try reader.readFileManifest(allocator, 501);
    defer manifest.deinit(allocator);
    try std.testing.expectEqual(@as(u64, 11), manifest.header.file_size);
}

test "pack reader rejects CRC-valid malformed path index at open" {
    const writer_mod = @import("pack_writer.zig");
    const fmt = @import("../format/common.zig");
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const pack_path = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(pack_path);
    const encoded = try path_index_fmt.encodePathIndex(allocator, &.{.{ .normalized_path = "a.txt", .file_entry = 1 }});
    defer allocator.free(encoded);
    const entries_off: usize = fmt.getU32(encoded, 24);
    fmt.putU32(encoded, entries_off + 28, 1);
    // The link is a self-cycle, but the object checksum is intact.
    const crc_offset = path_index_fmt.HEADER_SIZE - 4;
    fmt.putU32(encoded, crc_offset, fmt.crc32cWithZeroU32(encoded, crc_offset));
    const manifest = pack_manifest_fmt.encodePackManifest(.{ .pack_id = 1, .pack_version = 1, .build_id = 1, .file_count = 1, .tombstone_count = 0 });
    {
        var writer = try writer_mod.PackWriter.create(allocator, pack_path);
        errdefer writer.abort();
        try writer.putPathIndex(encoded);
        try writer.putPackManifest(&manifest);
        try writer.close();
    }
    try std.testing.expectError(error.Corruption, PackReader.open(allocator, pack_path));
}
