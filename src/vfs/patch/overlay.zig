//! Overlay pack lifecycle (docs/vfs/diff_patch.md §8.2).
//!
//! A readonly base pack cannot be patched in place; patch output goes to an
//! overlay pack with the same pack_id, mounted above the base. The overlay's
//! PackManifest records which base version it was created for so the Volume
//! can refuse to layer it over a replaced base.
const std = @import("std");
const pack_reader = @import("../pack/pack_reader.zig");
const pack_writer = @import("../pack/pack_writer.zig");
const pack_manifest_fmt = @import("../format/pack_manifest.zig");
const path_index_fmt = @import("../format/path_index.zig");
const hash = @import("../hash.zig");

pub const CreateOptions = struct {
    shards: u32 = 1,
};

/// Creates an empty overlay for `base_path` at `overlay_path`. The overlay
/// starts at the base's pack_version with an empty path index; patches raise
/// its version.
pub fn create(allocator: std.mem.Allocator, base_path: []const u8, overlay_path: []const u8, options: CreateOptions) !void {
    var base = try pack_reader.PackReader.open(allocator, base_path);
    defer base.close(allocator);
    if (base.manifest.isOverlay()) return error.InvalidArgument;

    var writer = try pack_writer.PackWriter.createWithOptions(allocator, overlay_path, .{ .shards = options.shards });
    var closed = false;
    errdefer if (!closed) writer.abort();

    const path_index = try path_index_fmt.encodePathIndex(allocator, &.{});
    defer allocator.free(path_index);
    try writer.putPathIndex(path_index);
    const manifest = pack_manifest_fmt.encodePackManifest(.{
        .pack_id = base.manifest.pack_id,
        .flags = pack_manifest_fmt.PACK_FLAG_OVERLAY,
        .pack_version = base.manifest.pack_version,
        .build_id = base.manifest.build_id,
        .file_count = 0,
        .tombstone_count = 0,
        .content_hash = base.manifest.content_hash,
        .base_pack_id = base.manifest.pack_id,
        .base_pack_version = base.manifest.pack_version,
        .base_pack_generation = base.manifest.pack_version,
    });
    try writer.putPackManifest(&manifest);
    try writer.close();
    closed = true;
}

/// Opens (or creates) the overlay for `base_path` and validates the link.
pub fn openOrCreate(allocator: std.mem.Allocator, base_path: []const u8, overlay_path: []const u8, options: CreateOptions) !void {
    var existing = pack_reader.PackReader.open(allocator, overlay_path) catch |e| switch (e) {
        error.FileNotFound, error.NotFound => {
            try create(allocator, base_path, overlay_path, options);
            return;
        },
        else => |err| return err,
    };
    defer existing.close(allocator);
    try validate(allocator, base_path, existing.manifest);
}

/// Patch-only entry point. The caller must own the overlay's advisory patch
/// lock and update admission before calling. A crash-dirty native overlay may
/// need explicit writable recovery; ordinary read-only opens never do this.
pub fn openOrCreateForPatch(allocator: std.mem.Allocator, base_path: []const u8, overlay_path: []const u8, options: CreateOptions) !void {
    var existing = pack_reader.PackReader.open(allocator, overlay_path) catch |e| switch (e) {
        error.FileNotFound, error.NotFound => {
            try create(allocator, base_path, overlay_path, options);
            return;
        },
        error.Busy => blk: {
            // Reject unreadable, dirty, or overlay bases before touching the
            // output. In particular, never recover a dirty base through an
            // alias passed as overlay_path.
            var base = try pack_reader.PackReader.open(allocator, base_path);
            defer base.close(allocator);
            if (base.manifest.isOverlay()) return error.InvalidArgument;

            // Only the explicitly authorized patch target is opened writable.
            // Its overlay link can be validated once recovery has made its
            // committed manifest readable again.
            var recovery = try @import("db_internal").kv_db.KvDb.open(overlay_path, .{ .mode = .read_write, .create_if_missing = false });
            try recovery.close();
            break :blk try pack_reader.PackReader.open(allocator, overlay_path);
        },
        else => |err| return err,
    };
    defer existing.close(allocator);
    try validate(allocator, base_path, existing.manifest);
}

pub fn validate(allocator: std.mem.Allocator, base_path: []const u8, overlay: pack_manifest_fmt.PackManifest) !void {
    if (!overlay.isOverlay()) return error.InvalidArgument;
    var base = try pack_reader.PackReader.open(allocator, base_path);
    defer base.close(allocator);
    if (base.manifest.isOverlay()) return error.InvalidArgument;
    if (overlay.base_pack_id != base.manifest.pack_id) return error.InvalidArgument;
    if (overlay.base_pack_version != base.manifest.pack_version) return error.OverlayBaseMismatch;
}

test "overlay create validate and volume layering with placeholder" {
    const allocator = std.testing.allocator;
    const builder = @import("../build/pack_builder.zig");
    const volume_mod = @import("../volume/volume.zig");
    const page_value_fmt = @import("../format/page_value.zig");
    const page_placeholder_fmt = @import("../format/page_placeholder.zig");
    const io = std.Io.Threaded.global_single_threaded.io();
    const base_path = "zig-cache-vfs-overlay-base";
    const overlay_path = "zig-cache-vfs-overlay-top";
    const src_path = "zig-cache-vfs-overlay-src.bin";
    _ = std.Io.Dir.cwd().deleteTree(io, base_path) catch {};
    _ = std.Io.Dir.cwd().deleteTree(io, overlay_path) catch {};
    _ = std.Io.Dir.cwd().deleteFile(io, src_path) catch {};
    defer _ = std.Io.Dir.cwd().deleteTree(io, base_path) catch {};
    defer _ = std.Io.Dir.cwd().deleteTree(io, overlay_path) catch {};
    defer _ = std.Io.Dir.cwd().deleteFile(io, src_path) catch {};

    try builder.writeSourceFileForTest(src_path, "AAAABBBBCCCC");
    try builder.createPack(base_path, &.{.{ .source_path = src_path, .virtual_path = "/f.bin", .file_entry = 501, .page_size = 4 }}, .{ .pack_id = 3, .pack_version = 1 });
    try create(allocator, base_path, overlay_path, .{});
    try openOrCreate(allocator, base_path, overlay_path, .{});

    // Capture the published manifest before opening the writer. Read-only
    // pack opens never recover a live writer's dirty delta as a side effect.
    var m = blk: {
        var r = try pack_reader.PackReader.open(allocator, overlay_path);
        defer r.close(allocator);
        break :blk r.manifest;
    };
    // Overlay: replace page 1 ("BBBB" -> "bbbb"), placeholder page 2, bump version.
    {
        var w = try pack_writer.PackWriter.create(allocator, overlay_path);
        var closed = false;
        errdefer if (!closed) w.abort();
        const pv = try page_value_fmt.encodePageValue(allocator, .{ .file_entry = 501, .block_index = 0, .page_index = 1, .raw_size = 4, .stored_size = 4, .content_hash = hash.contentHash("bbbb"), .payload = "bbbb" });
        defer allocator.free(pv);
        try w.putPage(501, 0, 1, pv);
        const ph = page_placeholder_fmt.encode(.{ .file_entry = 501, .block_index = 0, .page_index = 2 });
        try w.putPagePlaceholder(501, 0, 2, &ph);
        m.pack_version = 2;
        try w.putPackManifest(&pack_manifest_fmt.encodePackManifest(m));
        try w.close();
        closed = true;
    }

    var v = try volume_mod.Volume.open("overlay-vol", .{});
    defer v.close();
    try v.mountPackWithPriority(base_path, 10, 0);
    try v.mountPackWithPriority(overlay_path, 20, 0);
    // A second overlay of the same pack is rejected; wrong priority rejected.
    try std.testing.expectError(error.InvalidArgument, v.mountPackWithPriority(overlay_path, 30, 0));

    var h = try v.openEntry(1, 501);
    defer h.close();
    var buf: [12]u8 = undefined;
    // pages 0 and 1: base + overlay
    try std.testing.expectEqual(@as(usize, 8), try h.readAt(0, buf[0..8]));
    try std.testing.expectEqualSlices(u8, "AAAAbbbb", buf[0..8]);
    // page 2 is placeholdered in the overlay -> NotFound (not the base bytes)
    try std.testing.expectError(error.NotFound, h.readAt(8, buf[8..12]));

    // Base replaced by a different version => overlay refuses to layer.
    var v2 = try volume_mod.Volume.open("overlay-vol2", .{});
    defer v2.close();
    try builder.writeSourceFileForTest(src_path, "AAAABBBBCCCCDDDD");
    const base2 = "zig-cache-vfs-overlay-base2";
    _ = std.Io.Dir.cwd().deleteTree(io, base2) catch {};
    defer _ = std.Io.Dir.cwd().deleteTree(io, base2) catch {};
    try builder.createPack(base2, &.{.{ .source_path = src_path, .virtual_path = "/f.bin", .file_entry = 501, .page_size = 4 }}, .{ .pack_id = 3, .pack_version = 5 });
    try v2.mountPackWithPriority(base2, 10, 0);
    try std.testing.expectError(error.InvalidArgument, v2.mountPackWithPriority(overlay_path, 20, 0));
    var ov = try pack_reader.PackReader.open(allocator, overlay_path);
    defer ov.close(allocator);
    try std.testing.expectError(error.OverlayBaseMismatch, validate(allocator, base2, ov.manifest));
}

test "patch preparation explicitly recovers only crash-dirty overlay" {
    const db = @import("db_internal");
    const pf = db.platform.file;
    const builder = @import("../build/pack_builder.zig");
    const TestFiles = struct {
        fn markDirty(path: []const u8) !void {
            var store = try db.kv_db.KvDb.open(path, .{ .create_if_missing = false });
            const delta_offset = store.delta.journal.region.offset;
            try store.close();
            const index_path = try std.fs.path.join(std.testing.allocator, &.{ path, "index.db" });
            defer std.testing.allocator.free(index_path);
            var index = try pf.open(index_path, .{ .mode = .read_write });
            defer pf.close(&index);
            var header: [64]u8 = undefined;
            try std.testing.expectEqual(header.len, try pf.preadAll(index, delta_offset, &header));
            db.format.writeU32Le(header[48..52], 0);
            db.format.writeU32Le(header[56..60], 0);
            db.format.writeU32Le(header[56..60], db.format.crc32c(&header));
            try pf.pwriteAll(index, delta_offset, &header);
            try pf.flushMetadata(index);
        }

        fn fingerprint(path: []const u8) ![32]u8 {
            var hasher = std.crypto.hash.sha2.Sha256.init(.{});
            for ([_][]const u8{ "manifest.db", "index.db", "data_000.db" }) |leaf| {
                const file_path = try std.fs.path.join(std.testing.allocator, &.{ path, leaf });
                defer std.testing.allocator.free(file_path);
                var file = try pf.open(file_path, .{ .mode = .read_only });
                defer pf.close(&file);
                var bytes: [4096]u8 = undefined;
                var offset: u64 = 0;
                while (true) {
                    const n = try pf.preadAll(file, offset, &bytes);
                    hasher.update(bytes[0..n]);
                    if (n < bytes.len) break;
                    offset += n;
                }
            }
            return hasher.finalResult();
        }
    };
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(root);
    const base_path = try std.fs.path.join(allocator, &.{ root, "base" });
    defer allocator.free(base_path);
    const overlay_path = try std.fs.path.join(allocator, &.{ root, "overlay" });
    defer allocator.free(overlay_path);
    const source_path = try std.fs.path.join(allocator, &.{ root, "source" });
    defer allocator.free(source_path);
    try builder.writeSourceFileForTest(source_path, "unchanged-base");
    try builder.createPack(base_path, &.{.{ .source_path = source_path, .virtual_path = "/base", .file_entry = 61003, .page_size = 4 }}, .{ .pack_id = 61003 });
    try create(allocator, base_path, overlay_path, .{});
    try TestFiles.markDirty(overlay_path);
    const base_before = try TestFiles.fingerprint(base_path);
    const overlay_before = try TestFiles.fingerprint(overlay_path);
    try std.testing.expectError(error.Busy, pack_reader.PackReader.open(allocator, overlay_path));
    try std.testing.expectError(error.Busy, openOrCreate(allocator, base_path, overlay_path, .{}));
    try std.testing.expectEqual(overlay_before, try TestFiles.fingerprint(overlay_path));
    try openOrCreateForPatch(allocator, base_path, overlay_path, .{});
    try openOrCreate(allocator, base_path, overlay_path, .{});
    try std.testing.expectEqual(base_before, try TestFiles.fingerprint(base_path));

    // A dirty base is never silently recovered, even in patch preparation.
    try TestFiles.markDirty(overlay_path);
    try TestFiles.markDirty(base_path);
    const dirty_base_before = try TestFiles.fingerprint(base_path);
    const dirty_overlay_before = try TestFiles.fingerprint(overlay_path);
    try std.testing.expectError(error.Busy, openOrCreateForPatch(allocator, base_path, overlay_path, .{}));
    try std.testing.expectEqual(dirty_base_before, try TestFiles.fingerprint(base_path));
    try std.testing.expectEqual(dirty_overlay_before, try TestFiles.fingerprint(overlay_path));
    try std.testing.expectError(error.Busy, pack_reader.PackReader.open(allocator, base_path));
}
