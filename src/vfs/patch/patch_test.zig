//! End-to-end diff/patch tests (docs/vfs/task/task_22_diff_patch_integration_tests.md).
const std = @import("std");
const fixture = @import("../diff/test_fixture.zig");
const pack_scan = @import("../diff/pack_scan.zig");
const diff_writer = @import("../diff/diff_pack_writer.zig");
const session = @import("patch_session.zig");
const volume_mod = @import("../volume/volume.zig");
const pack_tools = @import("../tools/pack_tools.zig");
const object_key = @import("../object_key.zig");

const P = struct {
    v1: []const u8,
    v2: []const u8,
    v3: []const u8,
    d12: []const u8,
    d23: []const u8,
    d13: []const u8,
};

fn paths(comptime tag: []const u8) P {
    return .{
        .v1 = "zig-cache-vfs-pt-" ++ tag ++ "-v1",
        .v2 = "zig-cache-vfs-pt-" ++ tag ++ "-v2",
        .v3 = "zig-cache-vfs-pt-" ++ tag ++ "-v3",
        .d12 = "zig-cache-vfs-pt-" ++ tag ++ "-d12",
        .d23 = "zig-cache-vfs-pt-" ++ tag ++ "-d23",
        .d13 = "zig-cache-vfs-pt-" ++ tag ++ "-d13",
    };
}

fn cleanAll(p: P) void {
    fixture.cleanup(p.v1);
    fixture.cleanup(p.v2);
    fixture.cleanup(p.v3);
    fixture.cleanup(p.d12);
    fixture.cleanup(p.d23);
    fixture.cleanup(p.d13);
}

fn buildAll(a: std.mem.Allocator, ds: *const fixture.Dataset, p: P, comptime tag: []const u8, shards: u32) !void {
    try fixture.buildPack(a, "zig-cache-vfs-pt-" ++ tag ++ "-fx1", p.v1, ds.v1, 77, 1, shards);
    try fixture.buildPack(a, "zig-cache-vfs-pt-" ++ tag ++ "-fx2", p.v2, ds.v2, 77, 2, shards);
    try fixture.buildPack(a, "zig-cache-vfs-pt-" ++ tag ++ "-fx3", p.v3, ds.v3, 77, 3, shards);
    const eng: @import("../diff/diff_engine.zig").EngineOptions = .{ .budget = .{ .cpu = 2, .worker_threads = 2 } };
    _ = try diff_writer.createDiffPack(a, p.v1, p.v2, p.d12, .{ .engine = eng, .write = .{ .chunk_nominal_bytes = 8192 } });
    _ = try diff_writer.createDiffPack(a, p.v2, p.v3, p.d23, .{ .engine = eng, .write = .{ .chunk_nominal_bytes = 8192 } });
    _ = try diff_writer.createDiffPack(a, p.v1, p.v3, p.d13, .{ .engine = eng });
}

/// Every visible object (manifests, pages, tombstones, path index, pack
/// manifest version/content_hash) must match between two packs. Pages are
/// compared by decoded raw bytes so recompressed pages count as equal.
fn expectEquivalent(a: std.mem.Allocator, got_path: []const u8, want_path: []const u8) !void {
    const block_codec = @import("../diff/block_codec.zig");
    var got = try pack_scan.PackImage.load(a, got_path);
    defer got.deinit();
    var want = try pack_scan.PackImage.load(a, want_path);
    defer want.deinit();
    try std.testing.expectEqual(want.manifest.pack_version, got.manifest.pack_version);
    try std.testing.expectEqualSlices(u8, &want.manifest.content_hash, &got.manifest.content_hash);
    try std.testing.expectEqual(want.files.count(), got.files.count());
    var fit = want.files.iterator();
    while (fit.next()) |e| {
        const g = got.files.getPtr(e.key_ptr.*) orelse return error.TestExpectedEqual;
        try std.testing.expectEqualSlices(u8, e.value_ptr.manifest_bytes, g.manifest_bytes);
    }
    try std.testing.expectEqual(want.pages.count(), got.pages.count());
    var pit = want.pages.iterator();
    while (pit.next()) |e| {
        const g = got.pages.getPtr(e.key_ptr.*) orelse return error.TestExpectedEqual;
        try std.testing.expectEqual(e.value_ptr.raw_crc, g.raw_crc);
        const wr = try block_codec.rawFromPageBytes(a, e.value_ptr.bytes, e.value_ptr.identity);
        defer a.free(wr);
        const gr = try block_codec.rawFromPageBytes(a, g.bytes, g.identity);
        defer a.free(gr);
        try std.testing.expectEqualSlices(u8, wr, gr);
    }
    try std.testing.expectEqual(want.tombstones.count(), got.tombstones.count());
    try std.testing.expectEqual(want.path_entries.len, got.path_entries.len);
    for (want.path_entries) |we| {
        const ge = got.pathEntry(we.normalized_path) orelse return error.TestExpectedEqual;
        try std.testing.expectEqual(we.file_entry, ge.file_entry);
    }
    try std.testing.expectEqual(@as(usize, 0), got.placeholders.count());
    var report = try pack_tools.verifyPack(got_path, a);
    defer report.deinit(a);
    try std.testing.expect(report.ok());
}

fn expectVolumeMatches(a: std.mem.Allocator, v: *volume_mod.Volume, specs: []const fixture.FileSpec) !void {
    for (specs) |spec| {
        var h = try v.openPath(1, spec.path);
        defer h.close();
        const buf = try a.alloc(u8, spec.data.len + 16);
        defer a.free(buf);
        const n = try h.readAt(0, buf);
        try std.testing.expectEqual(spec.data.len, n);
        try std.testing.expectEqualSlices(u8, spec.data, buf[0..n]);
    }
}

test "patch in-place: chain v1->v2->v3, merged (d12,d23), and direct d13 are all equivalent to built v3" {
    const a = std.testing.allocator;
    var ds = try fixture.dataset(a);
    defer ds.deinit();
    const p = paths("inplace");
    defer cleanAll(p);
    try buildAll(a, &ds, p, "inplace", 2);
    const opts: session.PatchOptions = .{ .budget = .{ .cpu = 2, .worker_threads = 3 }, .writer = .{ .batch_bytes = 4096, .batch_ops = 16 }, .optimize_after = true };

    // (a) two sequential runs
    const r1 = try session.run(a, p.v1, null, &.{p.d12}, null, opts);
    try std.testing.expectEqual(@as(u64, 2), r1.to_version);
    try std.testing.expect(r1.units_applied > 0);
    try expectEquivalent(a, p.v1, p.v2);
    const r2 = try session.run(a, p.v1, null, &.{p.d23}, null, opts);
    try std.testing.expectEqual(@as(u64, 3), r2.to_version);
    try expectEquivalent(a, p.v1, p.v3);
    // idempotent re-run: nothing to do
    const r3 = try session.run(a, p.v1, null, &.{ p.d12, p.d23 }, null, opts);
    try std.testing.expect(r3.no_op);

    // (b) merged chain in one run
    try fixture.buildPack(a, "zig-cache-vfs-pt-inplace-fx1b", p.v1, ds.v1, 77, 1, 2);
    const rb = try session.run(a, p.v1, null, &.{ p.d12, p.d23 }, null, opts);
    try std.testing.expectEqual(@as(u64, 3), rb.to_version);
    try std.testing.expect(rb.batches >= 1);
    try expectEquivalent(a, p.v1, p.v3);

    // (c) direct diff wins over the chain when lighter, and gives the same result
    try fixture.buildPack(a, "zig-cache-vfs-pt-inplace-fx1c", p.v1, ds.v1, 77, 1, 2);
    const rc = try session.run(a, p.v1, null, &.{ p.d12, p.d23, p.d13 }, 3, opts);
    try std.testing.expectEqual(@as(u64, 3), rc.to_version);
    try expectEquivalent(a, p.v1, p.v3);

    // volume reads the patched pack
    var v = try volume_mod.Volume.open("pt-inplace", .{});
    defer v.close();
    try v.mountPackWithPriority(p.v1, 0, 0);
    try expectVolumeMatches(a, &v, ds.v3);
}

test "patch overlay: readonly base v1 + overlay reads as v3 and is re-patchable" {
    const a = std.testing.allocator;
    var ds = try fixture.dataset(a);
    defer ds.deinit();
    const p = paths("overlay");
    defer cleanAll(p);
    const overlay_path = "zig-cache-vfs-pt-overlay-top";
    defer fixture.cleanup(overlay_path);
    try buildAll(a, &ds, p, "overlay", 1);
    const opts: session.PatchOptions = .{ .budget = .{ .cpu = 2, .worker_threads = 2 }, .overlay_shards = 2 };

    const r1 = try session.run(a, p.v1, overlay_path, &.{p.d12}, null, opts);
    try std.testing.expectEqual(@as(u64, 2), r1.to_version);
    {
        var v = try volume_mod.Volume.open("pt-ov1", .{});
        defer v.close();
        try v.mountPackWithPriority(p.v1, 10, 0);
        try v.mountPackWithPriority(overlay_path, 20, 0);
        try expectVolumeMatches(a, &v, ds.v2);
        // c.bin was deleted in v2
        try std.testing.expectError(error.NotFound, v.openPath(1, "/c.bin"));
    }
    const r2 = try session.run(a, p.v1, overlay_path, &.{ p.d23, p.d13 }, null, opts);
    try std.testing.expectEqual(@as(u64, 3), r2.to_version);
    {
        var v = try volume_mod.Volume.open("pt-ov2", .{});
        defer v.close();
        try v.mountPackWithPriority(p.v1, 10, 0);
        try v.mountPackWithPriority(overlay_path, 20, 0);
        try expectVolumeMatches(a, &v, ds.v3);
        try std.testing.expectError(error.NotFound, v.openPath(1, "/c.bin"));
        // a.bin shrank from 3 to 2 pages: the third page is placeholdered
        var h = try v.openPath(1, "/a.bin");
        defer h.close();
        try std.testing.expectEqual(ds.v3[0].data.len, h.size);
    }
    // idempotent
    const r3 = try session.run(a, p.v1, overlay_path, &.{p.d23}, null, opts);
    try std.testing.expect(r3.no_op);
    // base of the wrong version is rejected
    try std.testing.expectError(error.OverlayBaseMismatch, session.run(a, p.v2, overlay_path, &.{p.d23}, null, opts));
}

test "patch crash matrix: interrupted runs resume idempotently and converge" {
    const a = std.testing.allocator;
    var ds = try fixture.dataset(a);
    defer ds.deinit();
    const p = paths("crash");
    defer cleanAll(p);
    try buildAll(a, &ds, p, "crash", 2);
    const faults = [_]session.FaultPoint{ .after_intent, .{ .after_units = 0 }, .{ .after_units = 1 }, .{ .after_units = 3 }, .{ .after_file_ops = 0 }, .{ .after_file_ops = 2 }, .before_finalize };
    for (faults) |f| {
        try fixture.buildPack(a, "zig-cache-vfs-pt-crash-fx1", p.v1, ds.v1, 77, 1, 2);
        var opts: session.PatchOptions = .{ .budget = .{ .cpu = 1, .worker_threads = 1 }, .writer = .{ .batch_bytes = 2048, .batch_ops = 4 }, .fault = f };
        try std.testing.expectError(error.InjectedFailure, session.run(a, p.v1, null, &.{ p.d12, p.d23 }, null, opts));
        // The pack is still at v1 (manifest untouched) but has an intent.
        {
            var img = try pack_scan.PackImage.load(a, p.v1);
            defer img.deinit();
            try std.testing.expectEqual(@as(u64, 1), img.manifest.pack_version);
        }
        // Different chain to the same version is refused without --force.
        opts.fault = .none;
        try std.testing.expectError(error.PatchIntentMismatch, session.run(a, p.v1, null, &.{p.d13}, null, opts));
        // Different target version is refused.
        try std.testing.expectError(error.PatchIntentMismatch, session.run(a, p.v1, null, &.{p.d12}, 2, opts));
        // Resume with the same chain converges.
        opts.optimize_after = true;
        const r = try session.run(a, p.v1, null, &.{ p.d12, p.d23 }, null, opts);
        try std.testing.expect(r.resumed);
        try expectEquivalent(a, p.v1, p.v3);
    }
    // --force with a different chain to the same version also converges.
    try fixture.buildPack(a, "zig-cache-vfs-pt-crash-fx1f", p.v1, ds.v1, 77, 1, 2);
    try std.testing.expectError(error.InjectedFailure, session.run(a, p.v1, null, &.{ p.d12, p.d23 }, null, .{ .budget = .{ .cpu = 1, .worker_threads = 1 }, .fault = .{ .after_units = 2 } }));
    _ = try session.run(a, p.v1, null, &.{p.d13}, null, .{ .budget = .{ .cpu = 1, .worker_threads = 1 }, .force = true, .optimize_after = true });
    try expectEquivalent(a, p.v1, p.v3);

    // Overlay mode: the base is never touched; the interrupted overlay resumes.
    try fixture.buildPack(a, "zig-cache-vfs-pt-crash-fx1o", p.v1, ds.v1, 77, 1, 2);
    const overlay_path = "zig-cache-vfs-pt-crash-overlay";
    defer fixture.cleanup(overlay_path);
    const overlay_faults = [_]session.FaultPoint{ .{ .after_units = 1 }, .{ .after_file_ops = 0 }, .before_finalize };
    for (overlay_faults) |f| {
        fixture.cleanup(overlay_path);
        var opts: session.PatchOptions = .{ .budget = .{ .cpu = 1, .worker_threads = 1 }, .writer = .{ .batch_bytes = 2048, .batch_ops = 4 }, .fault = f };
        try std.testing.expectError(error.InjectedFailure, session.run(a, p.v1, overlay_path, &.{ p.d12, p.d23 }, null, opts));
        {
            var base = try pack_scan.PackImage.load(a, p.v1);
            defer base.deinit();
            try std.testing.expectEqual(@as(u64, 1), base.manifest.pack_version);
            var ov = try pack_scan.PackImage.load(a, overlay_path);
            defer ov.deinit();
            try std.testing.expectEqual(@as(u64, 1), ov.manifest.pack_version);
        }
        opts.fault = .none;
        const r = try session.run(a, p.v1, overlay_path, &.{ p.d12, p.d23 }, null, opts);
        try std.testing.expect(r.resumed);
        try std.testing.expectEqual(@as(u64, 3), r.to_version);
        var v = try volume_mod.Volume.open("pt-crash-ov", .{});
        defer v.close();
        try v.mountPackWithPriority(p.v1, 10, 0);
        try v.mountPackWithPriority(overlay_path, 20, 0);
        try expectVolumeMatches(a, &v, ds.v3);
        try std.testing.expectError(error.NotFound, v.openPath(1, "/c.bin"));
    }
}

/// Writes one raw object into a pack (test-only tampering).
fn putRawObject(pack_path: []const u8, key: u64, value: []const u8) !void {
    const kv = @import("db_internal").kv_db;
    var db = try kv.KvDb.open(pack_path, .{ .mode = .read_write, .create_if_missing = false });
    defer db.close() catch {};
    const kb = object_key.encodeDbKey(key);
    try db.putBytes(&kb, value, .{});
    try db.commitPending(.sync);
}

fn readRawObject(a: std.mem.Allocator, pack_path: []const u8, key: u64) ![]u8 {
    const kv = @import("db_internal").kv_db;
    var db = try kv.KvDb.open(pack_path, .{ .mode = .read_only, .create_if_missing = false });
    defer db.close() catch {};
    const kb = object_key.encodeDbKey(key);
    return a.dupe(u8, try db.getBorrowedBytes(&kb));
}

test "patch page precondition: tampered page fails without being overwritten; foreign identity is a key collision" {
    const a = std.testing.allocator;
    const page_value_fmt = @import("../format/page_value.zig");
    var ds = try fixture.dataset(a);
    defer ds.deinit();
    const p = paths("tamper");
    defer cleanAll(p);
    try buildAll(a, &ds, p, "tamper", 1);
    // Page-level units for every changed block so the check under test is
    // the P precondition (old_stored_crc), not the block hash.
    const d23p = "zig-cache-vfs-pt-tamper-d23p";
    defer fixture.cleanup(d23p);
    _ = try diff_writer.createDiffPack(a, p.v2, p.v3, d23p, .{ .engine = .{ .budget = .{ .cpu = 1, .worker_threads = 1 } }, .plan = .{ .default_override = .page } });
    const opts: session.PatchOptions = .{ .budget = .{ .cpu = 1, .worker_threads = 1 } };

    // b.bin page 0 is edited in v3. Replace v2's copy by a well-formed page
    // with other content: the PackManifest content hash still matches, so
    // the failure must come from the unit's own precondition.
    const identity: page_value_fmt.PageIdentity = .{ .file_entry = 102, .block_index = 0, .page_index = 0 };
    const key = try object_key.pageKey(102, 0, 0);
    const junk = [_]u8{0xee} ** 4096;
    const tampered = try page_value_fmt.encodePageValue(a, .{ .file_entry = 102, .block_index = 0, .page_index = 0, .raw_size = junk.len, .stored_size = junk.len, .payload = &junk });
    defer a.free(tampered);
    _ = try page_value_fmt.decodePageValue(tampered, identity);
    try putRawObject(p.v2, key, tampered);
    try std.testing.expectError(error.PreconditionFailed, session.run(a, p.v2, null, &.{d23p}, null, opts));
    {
        const after = try readRawObject(a, p.v2, key);
        defer a.free(after);
        try std.testing.expectEqualSlices(u8, tampered, after);
        var img = try pack_scan.PackImage.load(a, p.v2);
        defer img.deinit();
        try std.testing.expectEqual(@as(u64, 2), img.manifest.pack_version);
    }

    // A value whose intact header names another object under this key is a
    // key collision: the patch must refuse rather than overwrite it.
    try fixture.buildPack(a, "zig-cache-vfs-pt-tamper-fx2b", p.v2, ds.v2, 77, 2, 1);
    const foreign = try page_value_fmt.encodePageValue(a, .{ .file_entry = 777, .block_index = 0, .page_index = 0, .raw_size = junk.len, .stored_size = junk.len, .payload = &junk });
    defer a.free(foreign);
    try putRawObject(p.v2, key, foreign);
    try std.testing.expectError(error.KeyCollision, session.run(a, p.v2, null, &.{d23p}, null, opts));
    const still = try readRawObject(a, p.v2, key);
    defer a.free(still);
    try std.testing.expectEqualSlices(u8, foreign, still);

    // Same stored bytes but encoded by a codec the delta was not computed
    // against: the CRC precondition passes, the codec identity must not.
    try fixture.buildPack(a, "zig-cache-vfs-pt-tamper-fx2c", p.v2, ds.v2, 77, 2, 1);
    const orig = try readRawObject(a, p.v2, key);
    defer a.free(orig);
    const pv = try page_value_fmt.decodePageValue(orig, identity);
    const relabelled = try page_value_fmt.encodePageValue(a, .{ .file_entry = 102, .block_index = 0, .page_index = 0, .codec = .lz4, .raw_size = pv.raw_size, .stored_size = pv.stored_size, .raw_crc = pv.raw_crc, .stored_crc = pv.stored_crc, .payload = pv.payload });
    defer a.free(relabelled);
    try putRawObject(p.v2, key, relabelled);
    try std.testing.expectError(error.CodecMismatch, session.run(a, p.v2, null, &.{d23p}, null, opts));
}

test "patch lock file excludes a second patcher; full verify and trace dump work" {
    const a = std.testing.allocator;
    var ds = try fixture.dataset(a);
    defer ds.deinit();
    const p = paths("lock");
    defer cleanAll(p);
    try buildAll(a, &ds, p, "lock", 1);
    const io = std.Io.Threaded.global_single_threaded.io();

    // A stale/foreign lock file makes the run fail with Busy before touching the pack.
    const lock_path = "zig-cache-vfs-pt-lock-v1/" ++ session.LOCK_FILE_NAME;
    {
        const f = try std.Io.Dir.cwd().createFile(io, lock_path, .{});
        f.close(io);
    }
    try std.testing.expectError(error.Busy, session.run(a, p.v1, null, &.{p.d12}, null, .{ .budget = .{ .cpu = 1, .worker_threads = 1 } }));
    {
        var img = try pack_scan.PackImage.load(a, p.v1);
        defer img.deinit();
        try std.testing.expectEqual(@as(u64, 1), img.manifest.pack_version);
    }
    try std.Io.Dir.cwd().deleteFile(io, lock_path);

    // Normal run: lock released afterwards, full verify passes, trace written.
    const trace_path = "zig-cache-vfs-pt-lock-trace.json";
    defer _ = std.Io.Dir.cwd().deleteFile(io, trace_path) catch {};
    const r = try session.run(a, p.v1, null, &.{p.d12}, null, .{ .budget = .{ .cpu = 1, .worker_threads = 1 }, .verify_after = .full, .trace_path = trace_path });
    try std.testing.expectEqual(@as(u64, 2), r.to_version);
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().openFile(io, lock_path, .{}));
    const trace = try std.Io.Dir.cwd().readFileAlloc(io, trace_path, a, .limited(1 << 20));
    defer a.free(trace);
    try std.testing.expect(std.mem.startsWith(u8, trace, "{\"finished\":"));
    try std.testing.expect(std.mem.indexOf(u8, trace, "\"trace\":[{") != null);
    try expectEquivalent(a, p.v1, p.v2);
}

test "patch rejects tampered base (precondition) and missing chain" {
    const a = std.testing.allocator;
    var ds = try fixture.dataset(a);
    defer ds.deinit();
    const p = paths("reject");
    defer cleanAll(p);
    try buildAll(a, &ds, p, "reject", 1);
    const opts: session.PatchOptions = .{ .budget = .{ .cpu = 1, .worker_threads = 1 } };
    // no path from v1 to v3 with only d23
    try std.testing.expectError(error.NoPatchPath, session.run(a, p.v1, null, &.{p.d23}, 3, opts));
    // d23 against v1: content hash precondition fails before any write
    try std.testing.expectError(error.NoPatchPath, session.run(a, p.v1, null, &.{p.d23}, null, opts));
    // apply d12 to a v2 built pack whose content differs from v1 -> PreconditionFailed
    try std.testing.expectError(error.PreconditionFailed, blk: {
        // forge: make v2 claim version 1 by building a v1-versioned pack from v2 data
        try fixture.buildPack(a, "zig-cache-vfs-pt-reject-forge", p.v3, ds.v2, 77, 1, 1);
        break :blk session.run(a, p.v3, null, &.{p.d12}, null, opts);
    });
}
