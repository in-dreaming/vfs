const std = @import("std");
const db_internal = @import("db_internal");
const kv = db_internal.kv_db;
const checkpoint = db_internal.index.checkpoint;
const db_verify_mod = db_internal.recovery_verify;
const pf = db_internal.platform.file;

const object_key = @import("../object_key.zig");
const hash = @import("../hash.zig");
const fmt = @import("../format/common.zig");
const pack_manifest_fmt = @import("../format/pack_manifest.zig");
const path_index_fmt = @import("../format/path_index.zig");
const file_manifest_fmt = @import("../format/file_manifest.zig");
const page_value_fmt = @import("../format/page_value.zig");
const tombstone_fmt = @import("../format/tombstone.zig");
const page_placeholder_fmt = @import("../format/page_placeholder.zig");
const patch_intent_fmt = @import("../format/patch_intent.zig");
const directory_manifest_fmt = @import("../format/directory_manifest.zig");
const registry = @import("../compress/registry.zig");
const volume_mod = @import("../volume/volume.zig");
const volume_staging = @import("../volume/staging.zig");

pub const IssueKind = enum {
    db_verify_failed,
    object_read_failed,
    unknown_object,
    pack_manifest_missing,
    pack_manifest_invalid,
    pack_manifest_key_mismatch,
    path_index_missing,
    path_index_invalid,
    path_index_key_mismatch,
    path_hash_mismatch,
    duplicate_file_entry,
    file_manifest_missing,
    file_manifest_invalid,
    file_manifest_key_mismatch,
    file_manifest_shape_invalid,
    page_missing,
    page_invalid,
    page_key_mismatch,
    page_ref_pack_missing,
    page_ref_missing,
    page_ref_identity_mismatch,
    page_ref_hash_mismatch,
    orphan_page,
    tombstone_invalid,
    tombstone_key_mismatch,
    manifest_file_count_mismatch,
    manifest_tombstone_count_mismatch,
    volume_manifest_invalid,
    /// A patch was interrupted: PatchIntent still present.
    patch_in_progress,
    page_placeholder_invalid,
    /// Placeholders only make sense in an overlay pack.
    placeholder_in_non_overlay,
};

pub const Issue = struct {
    kind: IssueKind,
    object_key: u64 = 0,
    file_entry: u64 = 0,
    block_index: u32 = 0,
    page_index: u32 = 0,
};

pub const VerifyReport = struct {
    issues: std.ArrayList(Issue) = .empty,
    pack_id: u64 = 0,
    pack_version: u64 = 0,
    file_count: u64 = 0,
    tombstone_count: u64 = 0,
    path_count: u64 = 0,
    page_count: u64 = 0,

    pub fn deinit(self: *VerifyReport, allocator: std.mem.Allocator) void {
        self.issues.deinit(allocator);
        self.* = .{};
    }

    pub fn ok(self: VerifyReport) bool {
        return self.issues.items.len == 0;
    }

    fn add(self: *VerifyReport, allocator: std.mem.Allocator, issue: Issue) !void {
        try self.issues.append(allocator, issue);
    }

    pub fn print(self: VerifyReport, writer: anytype) !void {
        try writer.print("vfs verify pack_id={d} pack_version={d} files={d} paths={d} pages={d} tombstones={d} issues={d}\n", .{
            self.pack_id,
            self.pack_version,
            self.file_count,
            self.path_count,
            self.page_count,
            self.tombstone_count,
            self.issues.items.len,
        });
        for (self.issues.items) |issue| {
            try writer.print("issue kind={s} object_key=0x{x} file_entry={d} block={d} page={d}\n", .{
                @tagName(issue.kind),
                issue.object_key,
                issue.file_entry,
                issue.block_index,
                issue.page_index,
            });
        }
    }
};

const ManifestInfo = struct {
    file_entry: u64,
    file_size: u64,
    blocks: []file_manifest_fmt.BlockDesc,
    page_refs: []file_manifest_fmt.PageRef,

    fn deinit(self: *ManifestInfo, allocator: std.mem.Allocator) void {
        allocator.free(self.blocks);
        allocator.free(self.page_refs);
    }
};

const PageInfo = struct {
    file_entry: u64,
    block_index: u32,
    page_index: u32,
    object_key: u64,
};

const ScanState = struct {
    manifests: std.ArrayList(ManifestInfo) = .empty,
    pages: std.ArrayList(PageInfo) = .empty,
    file_entries: std.AutoHashMap(u64, void),
    tombstone_count: u64 = 0,
    pack_manifest_count: u64 = 0,
    path_index_count: u64 = 0,
    placeholder_count: u64 = 0,

    fn init(allocator: std.mem.Allocator) ScanState {
        return .{ .file_entries = std.AutoHashMap(u64, void).init(allocator) };
    }

    fn deinit(self: *ScanState, allocator: std.mem.Allocator) void {
        for (self.manifests.items) |*m| m.deinit(allocator);
        self.manifests.deinit(allocator);
        self.pages.deinit(allocator);
        self.file_entries.deinit();
    }
};

pub fn verifyPack(pack_path: []const u8, allocator: std.mem.Allocator) !VerifyReport {
    var report: VerifyReport = .{};
    errdefer report.deinit(allocator);

    if (!try dbVerifyOk(pack_path, allocator)) {
        try report.add(allocator, .{ .kind = .db_verify_failed });
        return report;
    }

    var db = try kv.KvDb.open(pack_path, .{ .mode = .read_only, .create_if_missing = false });
    defer db.close() catch {};

    var scan = ScanState.init(allocator);
    defer scan.deinit(allocator);
    try scanLiveObjects(&db, allocator, &report, &scan);

    const manifest_bytes = readObjectAlloc(&db, allocator, object_key.packManifestKey()) catch |e| switch (e) {
        error.NotFound => {
            try report.add(allocator, .{ .kind = .pack_manifest_missing, .object_key = object_key.packManifestKey() });
            try finishScanChecks(allocator, &report, &scan, null);
            return report;
        },
        else => |err| return err,
    };
    defer allocator.free(manifest_bytes);

    const manifest = pack_manifest_fmt.decodePackManifest(manifest_bytes) catch {
        try report.add(allocator, .{ .kind = .pack_manifest_invalid, .object_key = object_key.packManifestKey() });
        try finishScanChecks(allocator, &report, &scan, null);
        return report;
    };
    report.pack_id = manifest.pack_id;
    report.pack_version = manifest.pack_version;
    report.file_count = manifest.file_count;
    report.tombstone_count = manifest.tombstone_count;

    const path_index_bytes = readObjectAlloc(&db, allocator, manifest.path_index_key) catch |e| switch (e) {
        error.NotFound => {
            try report.add(allocator, .{ .kind = .path_index_missing, .object_key = manifest.path_index_key });
            try finishScanChecks(allocator, &report, &scan, manifest);
            return report;
        },
        else => |err| return err,
    };
    defer allocator.free(path_index_bytes);

    const path_entries = path_index_fmt.collectEntries(allocator, path_index_bytes) catch {
        try report.add(allocator, .{ .kind = .path_index_invalid, .object_key = manifest.path_index_key });
        try finishScanChecks(allocator, &report, &scan, manifest);
        return report;
    };
    defer path_index_fmt.freeDecodedEntries(allocator, path_entries);
    report.path_count = path_entries.len;

    var path_file_entries = std.AutoHashMap(u64, void).init(allocator);
    defer path_file_entries.deinit();
    for (path_entries) |entry| {
        if (entry.path_hash != hash.hashPath(entry.normalized_path)) {
            try report.add(allocator, .{ .kind = .path_hash_mismatch, .object_key = manifest.path_index_key, .file_entry = entry.file_entry });
        }
        if (path_file_entries.contains(entry.file_entry)) {
            try report.add(allocator, .{ .kind = .duplicate_file_entry, .object_key = manifest.path_index_key, .file_entry = entry.file_entry });
        } else {
            try path_file_entries.put(entry.file_entry, {});
        }
        if (!scan.file_entries.contains(entry.file_entry)) {
            try report.add(allocator, .{ .kind = .file_manifest_missing, .object_key = try object_key.fileManifestKey(entry.file_entry), .file_entry = entry.file_entry });
        }
    }

    try verifyExpectedPages(&db, allocator, &report, scan.manifests.items, manifest);
    try finishScanChecks(allocator, &report, &scan, manifest);
    return report;
}

fn dbVerifyOk(pack_path: []const u8, allocator: std.mem.Allocator) !bool {
    const io = std.Io.Threaded.global_single_threaded.io();
    var dir = try std.Io.Dir.openDir(std.Io.Dir.cwd(), io, pack_path, .{});
    defer dir.close(io);
    var db_report = try db_verify_mod.verifyAt(dir, allocator);
    defer db_report.deinit();
    return db_report.ok();
}

fn scanLiveObjects(db: *kv.KvDb, allocator: std.mem.Allocator, report: *VerifyReport, scan: *ScanState) !void {
    const live = try checkpoint.collectLiveEntries(db, allocator);
    defer allocator.free(live);

    for (live) |entry| {
        const bytes = readInternalObjectAlloc(db, allocator, entry.key) catch {
            try report.add(allocator, .{ .kind = .object_read_failed });
            continue;
        };
        defer allocator.free(bytes);
        if (bytes.len < 4) {
            try report.add(allocator, .{ .kind = .unknown_object });
            continue;
        }
        const magic = fmt.getU32(bytes, 0);
        if (magic == pack_manifest_fmt.MAGIC) {
            scan.pack_manifest_count += 1;
            if (!try keyMatchesObject(db, entry.key, object_key.packManifestKey())) {
                try report.add(allocator, .{ .kind = .pack_manifest_key_mismatch, .object_key = object_key.packManifestKey() });
            }
            _ = pack_manifest_fmt.decodePackManifest(bytes) catch {
                try report.add(allocator, .{ .kind = .pack_manifest_invalid, .object_key = object_key.packManifestKey() });
                continue;
            };
        } else if (magic == path_index_fmt.MAGIC) {
            scan.path_index_count += 1;
            if (!try keyMatchesObject(db, entry.key, object_key.pathIndexKey())) {
                try report.add(allocator, .{ .kind = .path_index_key_mismatch, .object_key = object_key.pathIndexKey() });
            }
            _ = path_index_fmt.verify(bytes) catch {
                try report.add(allocator, .{ .kind = .path_index_invalid, .object_key = object_key.pathIndexKey() });
                continue;
            };
        } else if (magic == file_manifest_fmt.MAGIC) {
            const file_entry = if (bytes.len >= 16) fmt.getU64(bytes, 8) else 0;
            const expected_key = object_key.fileManifestKey(file_entry) catch 0;
            if (expected_key == 0 or !try keyMatchesObject(db, entry.key, expected_key)) {
                try report.add(allocator, .{ .kind = .file_manifest_key_mismatch, .object_key = expected_key, .file_entry = file_entry });
            }
            var decoded = file_manifest_fmt.decodeFileManifest(allocator, bytes, file_entry) catch {
                try report.add(allocator, .{ .kind = .file_manifest_invalid, .object_key = expected_key, .file_entry = file_entry });
                continue;
            };
            if (try validateManifestShape(decoded.header.file_size, decoded.blocks) == false) {
                try report.add(allocator, .{ .kind = .file_manifest_shape_invalid, .object_key = expected_key, .file_entry = file_entry });
            }
            try scan.file_entries.put(file_entry, {});
            try scan.manifests.append(allocator, .{ .file_entry = file_entry, .file_size = decoded.header.file_size, .blocks = decoded.blocks, .page_refs = decoded.page_refs });
            decoded.blocks = &.{};
            decoded.page_refs = &.{};
        } else if (magic == page_value_fmt.MAGIC) {
            const file_entry = if (bytes.len >= 16) fmt.getU64(bytes, 8) else 0;
            const block_index = if (bytes.len >= 20) fmt.getU32(bytes, 16) else 0;
            const page_index = if (bytes.len >= 24) fmt.getU32(bytes, 20) else 0;
            const expected_key = object_key.pageKey(file_entry, block_index, page_index) catch 0;
            if (expected_key == 0 or !try keyMatchesObject(db, entry.key, expected_key)) {
                try report.add(allocator, .{ .kind = .page_key_mismatch, .object_key = expected_key, .file_entry = file_entry, .block_index = block_index, .page_index = page_index });
            }
            const page = page_value_fmt.decodePageValue(bytes, .{ .file_entry = file_entry, .block_index = block_index, .page_index = page_index }) catch {
                try report.add(allocator, .{ .kind = .page_invalid, .object_key = expected_key, .file_entry = file_entry, .block_index = block_index, .page_index = page_index });
                continue;
            };
            const raw = registry.decompressPage(allocator, page.codec, page.payload, page.raw_size, page.raw_crc) catch {
                try report.add(allocator, .{ .kind = .page_invalid, .object_key = expected_key, .file_entry = file_entry, .block_index = block_index, .page_index = page_index });
                continue;
            };
            allocator.free(raw);
            report.page_count += 1;
            try scan.pages.append(allocator, .{ .file_entry = file_entry, .block_index = block_index, .page_index = page_index, .object_key = expected_key });
        } else if (magic == tombstone_fmt.ENTRY_MAGIC) {
            const file_entry = if (bytes.len >= 16) fmt.getU64(bytes, 8) else 0;
            const expected_key = object_key.entryTombstoneKey(file_entry) catch 0;
            if (expected_key == 0 or !try keyMatchesObject(db, entry.key, expected_key)) {
                try report.add(allocator, .{ .kind = .tombstone_key_mismatch, .object_key = expected_key, .file_entry = file_entry });
            }
            _ = tombstone_fmt.decodeEntryTombstone(bytes, file_entry) catch {
                try report.add(allocator, .{ .kind = .tombstone_invalid, .object_key = expected_key, .file_entry = file_entry });
                continue;
            };
            scan.tombstone_count += 1;
        } else if (magic == page_placeholder_fmt.MAGIC) {
            const file_entry = if (bytes.len >= 16) fmt.getU64(bytes, 8) else 0;
            const block_index = if (bytes.len >= 20) fmt.getU32(bytes, 16) else 0;
            const page_index = if (bytes.len >= 24) fmt.getU32(bytes, 20) else 0;
            const expected_key = object_key.pageKey(file_entry, block_index, page_index) catch 0;
            if (expected_key == 0 or !try keyMatchesObject(db, entry.key, expected_key)) {
                try report.add(allocator, .{ .kind = .page_key_mismatch, .object_key = expected_key, .file_entry = file_entry, .block_index = block_index, .page_index = page_index });
            }
            _ = page_placeholder_fmt.decode(bytes, .{ .file_entry = file_entry, .block_index = block_index, .page_index = page_index }) catch {
                try report.add(allocator, .{ .kind = .page_placeholder_invalid, .object_key = expected_key, .file_entry = file_entry, .block_index = block_index, .page_index = page_index });
                continue;
            };
            scan.placeholder_count += 1;
        } else if (magic == patch_intent_fmt.MAGIC) {
            try report.add(allocator, .{ .kind = .patch_in_progress, .object_key = object_key.patchIntentKey() });
        } else if (magic == directory_manifest_fmt.MAGIC) {
            if (!try keyMatchesObject(db, entry.key, object_key.directoryManifestKey())) {
                try report.add(allocator, .{ .kind = .unknown_object, .object_key = object_key.directoryManifestKey() });
            }
        } else {
            try report.add(allocator, .{ .kind = .unknown_object });
        }
    }
}

fn finishScanChecks(allocator: std.mem.Allocator, report: *VerifyReport, scan: *const ScanState, manifest: ?pack_manifest_fmt.PackManifest) !void {
    for (scan.pages.items) |page| {
        if (!pageBelongsToManifest(page, scan.manifests.items)) {
            try report.add(allocator, .{ .kind = .orphan_page, .object_key = page.object_key, .file_entry = page.file_entry, .block_index = page.block_index, .page_index = page.page_index });
        }
    }
    if (manifest) |m| {
        // Overlay packs hold only a subset of the logical pack; their counts
        // describe the merged view and cannot be checked locally.
        if (!m.isOverlay()) {
            if (m.file_count != scan.manifests.items.len) {
                try report.add(allocator, .{ .kind = .manifest_file_count_mismatch });
            }
            if (m.tombstone_count != scan.tombstone_count) {
                try report.add(allocator, .{ .kind = .manifest_tombstone_count_mismatch });
            }
            if (scan.placeholder_count != 0) {
                try report.add(allocator, .{ .kind = .placeholder_in_non_overlay });
            }
        }
    }
}

fn verifyExpectedPages(db: *kv.KvDb, allocator: std.mem.Allocator, report: *VerifyReport, manifests: []const ManifestInfo, pack_manifest: pack_manifest_fmt.PackManifest) !void {
    for (manifests) |manifest| {
        for (manifest.blocks, 0..) |block, block_i| {
            var page_index: u32 = 0;
            while (page_index < block.page_count) : (page_index += 1) {
                const identity, const key = if ((block.flags & file_manifest_fmt.BLOCK_FLAG_EXPLICIT_PAGE_REFS) != 0) blk: {
                    const ref = manifestPageRef(manifest, block, page_index) catch {
                        try report.add(allocator, .{ .kind = .page_ref_missing, .file_entry = manifest.file_entry, .block_index = @intCast(block_i), .page_index = page_index });
                        continue;
                    };
                    if (ref.pack_id != pack_manifest.pack_id or ref.pack_generation > pack_manifest.pack_version) {
                        try report.add(allocator, .{ .kind = .page_ref_pack_missing, .object_key = ref.page_key, .file_entry = ref.file_entry, .block_index = ref.block_index, .page_index = ref.page_index });
                        continue;
                    }
                    const derived_key = object_key.pageKey(ref.file_entry, ref.block_index, ref.page_index) catch {
                        try report.add(allocator, .{ .kind = .page_ref_identity_mismatch, .object_key = ref.page_key, .file_entry = ref.file_entry, .block_index = ref.block_index, .page_index = ref.page_index });
                        continue;
                    };
                    if (derived_key != ref.page_key) {
                        try report.add(allocator, .{ .kind = .page_ref_identity_mismatch, .object_key = ref.page_key, .file_entry = ref.file_entry, .block_index = ref.block_index, .page_index = ref.page_index });
                        continue;
                    }
                    break :blk .{ page_value_fmt.PageIdentity{ .file_entry = ref.file_entry, .block_index = ref.block_index, .page_index = ref.page_index }, ref.page_key };
                } else blk: {
                    const block_index: u32 = @intCast(block_i);
                    break :blk .{ page_value_fmt.PageIdentity{ .file_entry = manifest.file_entry, .block_index = block_index, .page_index = page_index }, try object_key.pageKey(manifest.file_entry, block_index, page_index) };
                };
                const page_bytes = readObjectAlloc(db, allocator, key) catch |e| switch (e) {
                    error.NotFound => {
                        // An overlay's manifest may reference pages that live in the base layer.
                        if (pack_manifest.isOverlay()) continue;
                        try report.add(allocator, .{ .kind = if ((block.flags & file_manifest_fmt.BLOCK_FLAG_EXPLICIT_PAGE_REFS) != 0) .page_ref_missing else .page_missing, .object_key = key, .file_entry = identity.file_entry, .block_index = identity.block_index, .page_index = identity.page_index });
                        continue;
                    },
                    else => |err| return err,
                };
                defer allocator.free(page_bytes);
                if (page_placeholder_fmt.isPlaceholder(page_bytes)) {
                    if (!pack_manifest.isOverlay()) try report.add(allocator, .{ .kind = .placeholder_in_non_overlay, .object_key = key, .file_entry = identity.file_entry, .block_index = identity.block_index, .page_index = identity.page_index });
                    continue;
                }
                const page = page_value_fmt.decodePageValue(page_bytes, identity) catch {
                    try report.add(allocator, .{ .kind = if ((block.flags & file_manifest_fmt.BLOCK_FLAG_EXPLICIT_PAGE_REFS) != 0) .page_ref_identity_mismatch else .page_invalid, .object_key = key, .file_entry = identity.file_entry, .block_index = identity.block_index, .page_index = identity.page_index });
                    continue;
                };
                const raw = registry.decompressPage(allocator, page.codec, page.payload, page.raw_size, page.raw_crc) catch {
                    try report.add(allocator, .{ .kind = .page_invalid, .object_key = key, .file_entry = identity.file_entry, .block_index = identity.block_index, .page_index = identity.page_index });
                    continue;
                };
                defer allocator.free(raw);
                if ((block.flags & file_manifest_fmt.BLOCK_FLAG_EXPLICIT_PAGE_REFS) != 0) {
                    const ref = (try manifestPageRef(manifest, block, page_index));
                    if (hash.crc32c(raw) != ref.raw_crc or !std.mem.eql(u8, &hash.contentHash(raw), &ref.content_hash)) {
                        try report.add(allocator, .{ .kind = .page_ref_hash_mismatch, .object_key = key, .file_entry = identity.file_entry, .block_index = identity.block_index, .page_index = identity.page_index });
                    }
                }
            }
        }
    }
}

fn manifestPageRef(manifest: ManifestInfo, block: file_manifest_fmt.BlockDesc, page_index: u32) !file_manifest_fmt.PageRef {
    if ((block.flags & file_manifest_fmt.BLOCK_FLAG_EXPLICIT_PAGE_REFS) == 0) return error.InvalidArgument;
    if (page_index >= block.page_count) return error.Corruption;
    const start = std.math.cast(usize, block.page_ref_offset) orelse return error.Corruption;
    const idx = start + page_index;
    if (idx >= manifest.page_refs.len) return error.Corruption;
    return manifest.page_refs[idx];
}

fn validateManifestShape(file_size: u64, blocks: []const file_manifest_fmt.BlockDesc) !bool {
    var cursor: u64 = 0;
    for (blocks) |block| {
        if (block.raw_offset != cursor) return false;
        if (block.page_count != 0 and block.page_size == 0) return false;
        const expected_pages: u32 = if (block.raw_size == 0) 0 else std.math.cast(u32, ((block.raw_size - 1) / block.page_size) + 1) orelse return false;
        if (block.page_count != expected_pages) return false;
        cursor = try std.math.add(u64, cursor, block.raw_size);
    }
    return cursor == file_size;
}

fn pageBelongsToManifest(page: PageInfo, manifests: []const ManifestInfo) bool {
    for (manifests) |manifest| {
        if (manifest.file_entry == page.file_entry and page.block_index < manifest.blocks.len) {
            const block = manifest.blocks[page.block_index];
            if ((block.flags & file_manifest_fmt.BLOCK_FLAG_EXPLICIT_PAGE_REFS) == 0 and page.page_index < block.page_count) return true;
        }
        for (manifest.blocks) |block| {
            if ((block.flags & file_manifest_fmt.BLOCK_FLAG_EXPLICIT_PAGE_REFS) == 0) continue;
            var i: u32 = 0;
            while (i < block.page_count) : (i += 1) {
                const ref = manifestPageRef(manifest, block, i) catch continue;
                if (ref.file_entry == page.file_entry and ref.block_index == page.block_index and ref.page_index == page.page_index and ref.page_key == page.object_key) return true;
            }
        }
    }
    return false;
}

fn keyMatchesObject(db: *const kv.KvDb, live_key: anytype, vfs_object_key: u64) !bool {
    var raw = object_key.encodeDbKey(vfs_object_key);
    const expected = try db.keyFromBytes(&raw);
    return expected.hi == live_key.hi and expected.lo == live_key.lo;
}

fn readObjectAlloc(db: *kv.KvDb, allocator: std.mem.Allocator, key: u64) ![]u8 {
    var raw = object_key.encodeDbKey(key);
    const size = try db.getSizeBytes(&raw);
    const buf = try allocator.alloc(u8, size);
    errdefer allocator.free(buf);
    _ = try db.getIntoBytes(&raw, buf);
    return buf;
}

fn readInternalObjectAlloc(db: *kv.KvDb, allocator: std.mem.Allocator, key: anytype) ![]u8 {
    const size = try db.getSize(key);
    const buf = try allocator.alloc(u8, size);
    errdefer allocator.free(buf);
    _ = try db.getInto(key, buf);
    return buf;
}

pub fn dumpPack(writer: anytype, pack_path: []const u8, allocator: std.mem.Allocator) !void {
    var report = try verifyPack(pack_path, allocator);
    defer report.deinit(allocator);
    try report.print(writer);

    var db = try kv.KvDb.open(pack_path, .{ .mode = .read_only, .create_if_missing = false });
    defer db.close() catch {};
    const manifest_bytes = try readObjectAlloc(&db, allocator, object_key.packManifestKey());
    defer allocator.free(manifest_bytes);
    const manifest = try pack_manifest_fmt.decodePackManifest(manifest_bytes);
    try writer.print("pack_id={d} pack_version={d} build_id={d} file_count={d} tombstone_count={d}\n", .{
        manifest.pack_id,
        manifest.pack_version,
        manifest.build_id,
        manifest.file_count,
        manifest.tombstone_count,
    });
    try dumpPathIndex(writer, pack_path, allocator);
}

pub fn dumpPathIndex(writer: anytype, pack_path: []const u8, allocator: std.mem.Allocator) !void {
    var db = try kv.KvDb.open(pack_path, .{ .mode = .read_only, .create_if_missing = false });
    defer db.close() catch {};
    const manifest_bytes = try readObjectAlloc(&db, allocator, object_key.packManifestKey());
    defer allocator.free(manifest_bytes);
    const manifest = try pack_manifest_fmt.decodePackManifest(manifest_bytes);
    const path_index = try readObjectAlloc(&db, allocator, manifest.path_index_key);
    defer allocator.free(path_index);
    const entries = try path_index_fmt.collectEntries(allocator, path_index);
    defer path_index_fmt.freeDecodedEntries(allocator, entries);
    try writer.print("path_index entries={d}\n", .{entries.len});
    for (entries) |entry| {
        try writer.print("path={s} path_hash=0x{x} file_entry={d} flags=0x{x}\n", .{ entry.normalized_path, entry.path_hash, entry.file_entry, entry.flags });
    }
}

pub fn dumpFile(writer: anytype, pack_path: []const u8, file_entry: u64, allocator: std.mem.Allocator) !void {
    var db = try kv.KvDb.open(pack_path, .{ .mode = .read_only, .create_if_missing = false });
    defer db.close() catch {};
    const bytes = try readObjectAlloc(&db, allocator, try object_key.fileManifestKey(file_entry));
    defer allocator.free(bytes);
    var manifest = try file_manifest_fmt.decodeFileManifest(allocator, bytes, file_entry);
    defer manifest.deinit(allocator);
    try writer.print("file_entry={d} file_size={d} block_count={d} flags=0x{x}\n", .{
        file_entry,
        manifest.header.file_size,
        manifest.blocks.len,
        manifest.header.flags,
    });
    for (manifest.blocks, 0..) |block, i| {
        try writer.print("block={d} raw_offset={d} raw_size={d} page_size={d} page_count={d} codec={s} flags=0x{x}\n", .{
            i,
            block.raw_offset,
            block.raw_size,
            block.page_size,
            block.page_count,
            @tagName(block.codec),
            block.flags,
        });
    }
}

pub fn extractFile(pack_path: []const u8, file_entry: u64, out_path: []const u8, allocator: std.mem.Allocator) !void {
    var v = try volume_mod.Volume.open("verify-extract", .{});
    defer v.close();
    try v.mountPackWithPriority(pack_path, 0, 0);
    var handle = try v.openEntry(1, file_entry);
    defer handle.close();
    const size = std.math.cast(usize, handle.size) orelse return error.InvalidArgument;
    const buf = try allocator.alloc(u8, size);
    defer allocator.free(buf);
    const n = try handle.readAt(0, buf);
    if (n != buf.len) return error.Corruption;
    try writeFile(out_path, buf);
}

pub fn recoverPack(pack_path: []const u8, allocator: std.mem.Allocator) !VerifyReport {
    const io = std.Io.Threaded.global_single_threaded.io();
    var dir = try std.Io.Dir.openDir(std.Io.Dir.cwd(), io, pack_path, .{});
    defer dir.close(io);
    try db_verify_mod.recoverAt(dir);
    return verifyPack(pack_path, allocator);
}

pub fn verifyVolume(path: []const u8, allocator: std.mem.Allocator) !VerifyReport {
    if (try looksLikePack(path)) return verifyPack(path, allocator);
    var report: VerifyReport = .{};
    errdefer report.deinit(allocator);
    const has_manifest = volume_staging.loadManifest(path, allocator) catch {
        try report.add(allocator, .{ .kind = .volume_manifest_invalid });
        return report;
    };
    if (has_manifest) |manifest_value| {
        var manifest = manifest_value;
        manifest.deinit(allocator);
        if (!try volume_staging.verifyVolumeManifest(path, allocator)) {
            try report.add(allocator, .{ .kind = .volume_manifest_invalid });
        }
        return report;
    }
    const io = std.Io.Threaded.global_single_threaded.io();
    var dir = try std.Io.Dir.openDir(std.Io.Dir.cwd(), io, path, .{ .iterate = true });
    defer dir.close(io);
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .directory) continue;
        const child = try std.fs.path.join(allocator, &.{ path, entry.name });
        defer allocator.free(child);
        if (!try looksLikePack(child)) continue;
        var child_report = try verifyPack(child, allocator);
        defer child_report.deinit(allocator);
        for (child_report.issues.items) |issue| try report.add(allocator, issue);
    }
    return report;
}

fn looksLikePack(path: []const u8) !bool {
    const io = std.Io.Threaded.global_single_threaded.io();
    const manifest_path = try std.fs.path.join(std.heap.smp_allocator, &.{ path, "manifest.db" });
    defer std.heap.smp_allocator.free(manifest_path);
    var f = pf.open(manifest_path, .{ .mode = .read_only }) catch |e| switch (e) {
        error.FileNotFound => return false,
        else => |err| return err,
    };
    _ = io;
    pf.close(&f);
    return true;
}

fn writeFile(path: []const u8, data: []const u8) !void {
    var f = try pf.open(path, .{ .mode = .create_read_write, .create_parent_dirs = true });
    defer pf.close(&f);
    try pf.setLen(f, 0);
    try pf.pwriteAll(f, 0, data);
    try pf.flushMetadata(f);
}

test "verify pack detects major VFS corruptions and extract validates reader path" {
    const builder = @import("../build/pack_builder.zig");
    const writer_mod = @import("../pack/pack_writer.zig");
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();

    const source_path = "zig-cache-vfs-verify-source.bin";
    const extract_path = "zig-cache-vfs-verify-extract.bin";
    _ = std.Io.Dir.cwd().deleteFile(io, source_path) catch {};
    _ = std.Io.Dir.cwd().deleteFile(io, extract_path) catch {};
    defer _ = std.Io.Dir.cwd().deleteFile(io, source_path) catch {};
    defer _ = std.Io.Dir.cwd().deleteFile(io, extract_path) catch {};
    try builder.writeSourceFileForTest(source_path, "verify-data-0123456789");

    const clean_pack = "zig-cache-vfs-verify-clean";
    _ = std.Io.Dir.cwd().deleteTree(io, clean_pack) catch {};
    defer _ = std.Io.Dir.cwd().deleteTree(io, clean_pack) catch {};
    try builder.createPack(clean_pack, &.{.{ .source_path = source_path, .virtual_path = "/verify.bin", .file_entry = 7001, .page_size = 5 }}, .{});
    var clean_report = try verifyPack(clean_pack, allocator);
    defer clean_report.deinit(allocator);
    try std.testing.expect(clean_report.ok());
    try extractFile(clean_pack, 7001, extract_path, allocator);
    const extracted = try readWholeFile(allocator, extract_path);
    defer allocator.free(extracted);
    try std.testing.expectEqualSlices(u8, "verify-data-0123456789", extracted);

    try expectCorruption(source_path, "zig-cache-vfs-corrupt-pack-manifest-crc", .pack_manifest_invalid, corruptPackManifestCrc);
    try expectCorruption(source_path, "zig-cache-vfs-corrupt-path-hash", .path_hash_mismatch, corruptPathHashRecrc);
    try expectCorruption(source_path, "zig-cache-vfs-corrupt-missing-manifest", .file_manifest_missing, deleteFileManifest);
    try expectCorruption(source_path, "zig-cache-vfs-corrupt-file-entry", .file_manifest_key_mismatch, corruptFileManifestEntryRecrc);
    try expectCorruption(source_path, "zig-cache-vfs-corrupt-file-shape", .file_manifest_shape_invalid, corruptFileManifestPageCountRecrc);
    try expectCorruption(source_path, "zig-cache-vfs-corrupt-page-header-crc", .page_invalid, corruptPageHeaderCrc);
    try expectCorruption(source_path, "zig-cache-vfs-corrupt-page-stored-crc", .page_invalid, corruptPageStoredCrc);
    try expectCorruption(source_path, "zig-cache-vfs-corrupt-page-raw-crc", .page_invalid, corruptPageRawCrc);
    try expectCorruption(source_path, "zig-cache-vfs-corrupt-page-identity", .page_key_mismatch, corruptPageIdentityRecrc);

    const tomb_pack = "zig-cache-vfs-corrupt-tombstone";
    _ = std.Io.Dir.cwd().deleteTree(io, tomb_pack) catch {};
    defer _ = std.Io.Dir.cwd().deleteTree(io, tomb_pack) catch {};
    var writer = try writer_mod.PackWriter.create(allocator, tomb_pack);
    const path_index = try path_index_fmt.encodePathIndex(allocator, &.{});
    defer allocator.free(path_index);
    try writer.putPathIndex(path_index);
    const tomb = try tombstone_fmt.encodeEntryTombstone(.{ .file_entry = 8001, .tombstone_version = 1, .reason_flags = 1 });
    try writer.putEntryTombstone(8001, &tomb);
    const manifest = pack_manifest_fmt.encodePackManifest(.{ .pack_id = 1, .pack_version = 1, .build_id = 1, .file_count = 0, .tombstone_count = 1, .content_hash = hash.contentHash(&tomb) });
    try writer.putPackManifest(&manifest);
    try writer.close();
    try corruptTombstoneReserved(tomb_pack);
    var tomb_report = try verifyPack(tomb_pack, allocator);
    defer tomb_report.deinit(allocator);
    try expectIssue(tomb_report, .tombstone_invalid);

    const corrupt_extract_pack = "zig-cache-vfs-corrupt-extract";
    _ = std.Io.Dir.cwd().deleteTree(io, corrupt_extract_pack) catch {};
    defer _ = std.Io.Dir.cwd().deleteTree(io, corrupt_extract_pack) catch {};
    try builder.createPack(corrupt_extract_pack, &.{.{ .source_path = source_path, .virtual_path = "/verify.bin", .file_entry = 7001, .page_size = 5 }}, .{});
    try corruptPageStoredCrc(corrupt_extract_pack);
    const bad_out = "zig-cache-vfs-corrupt-extract-out.bin";
    _ = std.Io.Dir.cwd().deleteFile(io, bad_out) catch {};
    defer _ = std.Io.Dir.cwd().deleteFile(io, bad_out) catch {};
    try std.testing.expectError(error.ChecksumMismatch, extractFile(corrupt_extract_pack, 7001, bad_out, allocator));
}

fn expectCorruption(source_path: []const u8, pack_path: []const u8, kind: IssueKind, corrupt: *const fn ([]const u8) anyerror!void) !void {
    const builder = @import("../build/pack_builder.zig");
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    _ = std.Io.Dir.cwd().deleteTree(io, pack_path) catch {};
    defer _ = std.Io.Dir.cwd().deleteTree(io, pack_path) catch {};
    try builder.createPack(pack_path, &.{.{ .source_path = source_path, .virtual_path = "/verify.bin", .file_entry = 7001, .page_size = 5 }}, .{});
    try corrupt(pack_path);
    var report = try verifyPack(pack_path, allocator);
    defer report.deinit(allocator);
    try expectIssue(report, kind);
}

fn expectIssue(report: VerifyReport, kind: IssueKind) !void {
    for (report.issues.items) |issue| if (issue.kind == kind) return;
    return error.TestExpectedEqual;
}

fn mutateObject(pack_path: []const u8, key: u64, mutator: *const fn ([]u8) anyerror!void) !void {
    var db = try kv.KvDb.open(pack_path, .{ .mode = .read_write, .create_if_missing = false });
    defer db.close() catch {};
    const bytes = try readObjectAlloc(&db, std.testing.allocator, key);
    defer std.testing.allocator.free(bytes);
    try mutator(bytes);
    var raw = object_key.encodeDbKey(key);
    try db.putBytes(&raw, bytes, .{ .durability = .sync });
    try db.commitPending(.sync);
    try db.optimize();
}

fn corruptPackManifestCrc(pack_path: []const u8) !void {
    try mutateObject(pack_path, object_key.packManifestKey(), struct {
        fn f(bytes: []u8) !void {
            bytes[pack_manifest_fmt.HEADER_SIZE - 1] ^= 0xff;
        }
    }.f);
}

fn corruptPathHashRecrc(pack_path: []const u8) !void {
    try mutateObject(pack_path, object_key.pathIndexKey(), struct {
        fn f(bytes: []u8) !void {
            const entries_off = fmt.getU32(bytes, 24);
            fmt.putU64(bytes, entries_off, fmt.getU64(bytes, entries_off) ^ 0x55);
            fmt.putU32(bytes, 44, fmt.crc32cWithZeroU32(bytes, 44));
        }
    }.f);
}

fn deleteFileManifest(pack_path: []const u8) !void {
    var db = try kv.KvDb.open(pack_path, .{ .mode = .read_write, .create_if_missing = false });
    defer db.close() catch {};
    var raw = object_key.encodeDbKey(try object_key.fileManifestKey(7001));
    try db.deleteBytes(&raw, .{ .durability = .sync });
    try db.commitPending(.sync);
    try db.optimize();
}

fn corruptFileManifestEntryRecrc(pack_path: []const u8) !void {
    try mutateObject(pack_path, try object_key.fileManifestKey(7001), struct {
        fn f(bytes: []u8) !void {
            fmt.putU64(bytes, 8, 7002);
            fmt.putU32(bytes, 76, fmt.crc32cWithZeroU32(bytes, 76));
        }
    }.f);
}

fn corruptFileManifestPageCountRecrc(pack_path: []const u8) !void {
    try mutateObject(pack_path, try object_key.fileManifestKey(7001), struct {
        fn f(bytes: []u8) !void {
            fmt.putU32(bytes, file_manifest_fmt.HEADER_SIZE + 20, 99);
            fmt.putU32(bytes, 76, fmt.crc32cWithZeroU32(bytes, 76));
        }
    }.f);
}

fn corruptPageHeaderCrc(pack_path: []const u8) !void {
    try mutateObject(pack_path, try object_key.pageKey(7001, 0, 0), struct {
        fn f(bytes: []u8) !void {
            bytes[page_value_fmt.HEADER_SIZE - 1] ^= 0xff;
        }
    }.f);
}

fn corruptPageStoredCrc(pack_path: []const u8) !void {
    try mutateObject(pack_path, try object_key.pageKey(7001, 0, 0), struct {
        fn f(bytes: []u8) !void {
            fmt.putU32(bytes, 44, fmt.getU32(bytes, 44) ^ 0x1234);
            fmt.putU32(bytes, 100, fmt.crc32cWithZeroU32(bytes[0..page_value_fmt.HEADER_SIZE], 100));
        }
    }.f);
}

fn corruptPageRawCrc(pack_path: []const u8) !void {
    try mutateObject(pack_path, try object_key.pageKey(7001, 0, 0), struct {
        fn f(bytes: []u8) !void {
            fmt.putU32(bytes, 40, fmt.getU32(bytes, 40) ^ 0x1234);
            fmt.putU32(bytes, 100, fmt.crc32cWithZeroU32(bytes[0..page_value_fmt.HEADER_SIZE], 100));
        }
    }.f);
}

fn corruptPageIdentityRecrc(pack_path: []const u8) !void {
    try mutateObject(pack_path, try object_key.pageKey(7001, 0, 0), struct {
        fn f(bytes: []u8) !void {
            fmt.putU64(bytes, 8, 7002);
            fmt.putU32(bytes, 100, fmt.crc32cWithZeroU32(bytes[0..page_value_fmt.HEADER_SIZE], 100));
        }
    }.f);
}

fn corruptTombstoneReserved(pack_path: []const u8) !void {
    try mutateObject(pack_path, try object_key.entryTombstoneKey(8001), struct {
        fn f(bytes: []u8) !void {
            bytes[28] = 1;
            fmt.putU32(bytes, 36, fmt.crc32cWithZeroU32(bytes, 36));
        }
    }.f);
}

fn readWholeFile(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    var f = try pf.open(path, .{ .mode = .read_only });
    defer pf.close(&f);
    const size = try pf.len(f);
    const buf = try allocator.alloc(u8, size);
    errdefer allocator.free(buf);
    if (try pf.preadAll(f, 0, buf) != buf.len) return error.Corruption;
    return buf;
}
