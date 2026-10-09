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
    /// Borrowed callback context; it must outlive the reader, including park /
    /// reopen. The pack path is an opaque provider root when this is non-null.
    file_ops: ?db_internal.platform.file.CustomFileOps = null,
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
        var db = try kv.KvDb.open(pack_path, .{ .mode = .read_only, .create_if_missing = false, .read_handles = options.read_handles, .file_ops = options.file_ops });
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

test "pack reader readonly custom backend short reads and opaque root reopen" {
    const builder = @import("../build/pack_builder.zig");
    const backend_mod = @import("backend_test_support.zig");
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const parent_path = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(parent_path);
    const pack_path = try std.fs.path.join(allocator, &.{ parent_path, "pack" });
    defer allocator.free(pack_path);
    const source_path = try std.fs.path.join(allocator, &.{ parent_path, "source" });
    defer allocator.free(source_path);
    try builder.writeSourceFileForTest(source_path, "provider-only-payload");
    try builder.createPack(pack_path, &.{.{ .source_path = source_path, .virtual_path = "/custom.bin", .file_entry = 991, .page_size = 7 }}, .{});
    {
        var native = try kv.KvDb.open(pack_path, .{});
        defer native.close() catch {};
        try native.checkpoint();
    }

    var backend = backend_mod.ReadOnlyBackend.init(allocator);
    defer backend.deinit();
    const root = "memory-provider/opaque/../root";
    try backend.importPack(pack_path, root);
    const corrupt_root = "memory-provider/corrupt";
    try backend.importPack(pack_path, corrupt_root);
    var corrupt_manifest = try db_internal.platform.file.openIn(.fromCustom(corrupt_root, backend.memoryOps()), "manifest.db", .{ .mode = .read_write });
    try db_internal.platform.file.pwriteAll(corrupt_manifest, 0, "BAD!");
    db_internal.platform.file.close(&corrupt_manifest);
    try tmp.dir.deleteTree(io, "pack");

    var reader = try PackReader.openWithOptions(allocator, root, .{ .file_ops = backend.ops() });
    var closed = false;
    defer if (!closed) reader.close(allocator);
    const index_bytes = reader.path_index.ptr;
    try std.testing.expectEqual(@as(u64, 991), try reader.resolvePath(allocator, "custom.bin"));
    const native_stat = try reader.statEntry(allocator, 991);
    try std.testing.expectEqual(@as(u64, 21), native_stat.size);
    try std.testing.expect(backend.read_count > 3);
    try std.testing.expectEqual(@as(usize, 3), backend.live_handles);
    for (0..3) |_| {
        try reader.park();
        try std.testing.expectEqual(@as(usize, 0), backend.live_handles);
        try std.testing.expectEqual(@as(usize, 0), backend.live_mappings);
        backend.fail_open = true;
        try std.testing.expectError(error.IoError, reader.ensureReady());
        try std.testing.expect(!reader.isReady());
        backend.fail_open = false;
        const record_reads_before_reopen = backend.record_read_count;
        try reader.ensureReady();
        // Reopen must not recovery-scan records outside bounded worker scratch.
        try std.testing.expectEqual(record_reads_before_reopen, backend.record_read_count);
        try std.testing.expectEqual(index_bytes, reader.path_index_view.bytes.ptr);
        try std.testing.expectEqual(@as(u64, 991), try reader.resolvePath(allocator, "/custom.bin"));
        const page = try reader.readPageAlloc(allocator, 991, 0, 0);
        defer allocator.free(page);
        const decoded = try page_value_fmt.decodePageValue(page, .{ .file_entry = 991, .block_index = 0, .page_index = 0 });
        try std.testing.expectEqualStrings("provide", decoded.payload);
    }
    reader.close(allocator);
    closed = true;
    try std.testing.expectEqual(backend.open_count, backend.close_count);
    try std.testing.expectEqual(@as(usize, 0), backend.mutation_count);

    try std.testing.expectError(error.Corruption, PackReader.openWithOptions(allocator, corrupt_root, .{ .file_ops = backend.ops() }));
    try std.testing.expectEqual(@as(usize, 0), backend.live_handles);
    backend.fail_open_after = backend.open_count + 1;
    try std.testing.expectError(error.IoError, PackReader.openWithOptions(allocator, root, .{ .file_ops = backend.ops() }));
    try std.testing.expectEqual(@as(usize, 0), backend.live_handles);
    backend.fail_open_after = null;
    var no_mapping = backend.ops();
    no_mapping.mmap = null;
    try std.testing.expectError(error.Unsupported, PackReader.openWithOptions(allocator, root, .{ .file_ops = no_mapping }));
    try std.testing.expectEqual(@as(usize, 0), backend.live_handles);
    backend.fail_read = true;
    try std.testing.expectError(error.IoError, PackReader.openWithOptions(allocator, root, .{ .file_ops = backend.ops() }));
    try std.testing.expectEqual(@as(usize, 0), backend.live_handles);
    backend.fail_read = false;
    try std.testing.expectError(error.FileNotFound, PackReader.openWithOptions(allocator, "memory-provider/missing-root", .{ .file_ops = backend.ops() }));
    // Invalid persisted slot state is rejected without leaking a provider map.
    const offsets = blk: {
        var inspect = try kv.KvDb.openCustom(root, backend.memoryOps(), .{ .mode = .read_only });
        defer inspect.close() catch {};
        const base = try inspect.index.region(inspect.index.activeBaseRegionId());
        break :blk .{ .slot = inspect.delta.journal.region.offset + inspect.delta.journal.header.slot_offset, .base = base.offset };
    };
    {
        const pf = db_internal.platform.file;
        const db_fmt = db_internal.format;
        var index = try pf.openIn(.fromCustom(root, backend.memoryOps()), "index.db", .{ .mode = .read_write });
        defer pf.close(&index);
        var original: [64]u8 = undefined;
        try std.testing.expectEqual(original.len, try pf.preadAll(index, offsets.base, &original));
        var malformed = original;
        db_fmt.writeU32Le(malformed[12..16], 32); // Invalid shift with a valid CRC.
        db_fmt.writeU32Le(malformed[48..52], 0);
        db_fmt.writeU32Le(malformed[48..52], db_fmt.crc32c(&malformed));
        try pf.pwriteAll(index, offsets.base, &malformed);
        try std.testing.expectError(error.Corruption, PackReader.openWithOptions(allocator, root, .{ .file_ops = backend.ops() }));
        try std.testing.expectEqual(@as(usize, 0), backend.live_handles);
        try std.testing.expectEqual(@as(usize, 0), backend.live_mappings);
        try pf.pwriteAll(index, offsets.base, &original);
        try pf.pwriteAll(index, offsets.slot, &.{255});
    }
    try std.testing.expectError(error.Corruption, PackReader.openWithOptions(allocator, root, .{ .file_ops = backend.ops() }));
    try std.testing.expectEqual(@as(usize, 0), backend.live_handles);
    try std.testing.expectEqual(@as(usize, 0), backend.live_mappings);
    try std.testing.expectEqual(@as(usize, 0), backend.mutation_count);
}
