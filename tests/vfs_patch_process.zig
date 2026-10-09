//! Opt-in real process-death recovery matrix. No return/error injection: each
//! stopped child remains inside patch.run until its parent kills that owned Child.
const std = @import("std");
const vfs = @import("vfs");
const session = vfs.patch.patch_session;
const a = std.heap.page_allocator;
const cwd = std.Io.Dir.cwd();
const points = [_][]const u8{ "after_intent", "after_units", "after_file_ops", "before_finalize", "after_finalize_before_optimize" };

fn path(root: []const u8, name: []const u8) ![]const u8 {
    return std.fs.path.join(a, &.{ root, name });
}
fn check(ok: bool) !void {
    if (!ok) return error.ProcessRecoveryAssertionFailed;
}
fn same(x: []const u8, y: []const u8) !void {
    try check(std.mem.eql(u8, x, y));
}
fn build(root: []const u8, name: []const u8, version: u64) !void {
    var data: [24576]u8 = undefined;
    for (&data, 0..) |*b, i| b.* = @intCast((i * 7 + i / 13) % 251);
    if (version == 2) @memset(data[5000..6000], 73);
    const source = try path(root, "source");
    const extra = try path(root, "extra");
    try vfs.build.pack_builder.writeSourceFileForTest(source, &data);
    try vfs.build.pack_builder.writeSourceFileForTest(extra, if (version == 1) "removed file" else "new file data");
    try vfs.build.pack_builder.createPack(try path(root, name), &.{
        .{ .source_path = source, .virtual_path = "/large.bin", .file_entry = 101, .page_size = 4096, .codec = .lz4 },
        .{ .source_path = extra, .virtual_path = if (version == 1) "/removed.bin" else "/added.bin", .file_entry = if (version == 1) 102 else 103, .page_size = 4096 },
    }, .{ .pack_id = 77, .pack_version = version, .build_id = version, .shards = 2, .budget = .{ .cpu = 2, .worker_threads = 2 } });
}

// Snapshot every byte of every base file, rather than comparing only visible
// objects: even an accidental generation/journal write is a failure.
const Snapshot = std.StringHashMap([]const u8);
fn snapshot(io: std.Io, root: []const u8) !Snapshot {
    var result = Snapshot.init(a);
    var dir = try cwd.openDir(io, root, .{ .iterate = true });
    defer dir.close(io);
    var walker = try dir.walk(a);
    defer walker.deinit();
    while (try walker.next(io)) |entry| {
        if (entry.kind == .file) try result.put(try a.dupe(u8, entry.path), try dir.readFileAlloc(io, entry.path, a, .unlimited));
    }
    return result;
}
fn unchanged(io: std.Io, root: []const u8, before: Snapshot) !void {
    var after = try snapshot(io, root);
    try check(before.count() == after.count());
    var it = before.iterator();
    while (it.next()) |entry| try same(entry.value_ptr.*, after.get(entry.key_ptr.*) orelse return error.BaseFileMissing);
}

fn equivalent(got_path: []const u8, want_path: []const u8) !void {
    var got = try vfs.diff.pack_scan.PackImage.load(a, got_path);
    defer got.deinit();
    var want = try vfs.diff.pack_scan.PackImage.load(a, want_path);
    defer want.deinit();
    try check(got.manifest.pack_version == want.manifest.pack_version);
    try same(&got.manifest.content_hash, &want.manifest.content_hash);
    try check(got.manifest.pack_id == want.manifest.pack_id);
    try check(got.manifest.file_count == want.manifest.file_count);
    try check(got.manifest.tombstone_count == want.manifest.tombstone_count);
    try check(got.manifest.flags == want.manifest.flags);
    try check(got.manifest.base_pack_id == want.manifest.base_pack_id);
    try check(got.manifest.base_pack_version == want.manifest.base_pack_version);
    try same(got.path_index_bytes, want.path_index_bytes);
    if (want.directory_manifest_bytes) |bytes| try same(got.directory_manifest_bytes orelse return error.MissingDirectoryManifest, bytes);
    try check(got.files.count() == want.files.count());
    var fit = want.files.iterator();
    while (fit.next()) |e| try same(e.value_ptr.manifest_bytes, (got.files.get(e.key_ptr.*) orelse return error.MissingManifest).manifest_bytes);
    try check(got.pages.count() == want.pages.count());
    var pit = want.pages.iterator();
    while (pit.next()) |e| {
        const g = got.pages.get(e.key_ptr.*) orelse return error.MissingPage;
        const wr = try vfs.diff.block_codec.rawFromPageBytes(a, e.value_ptr.bytes, e.value_ptr.identity);
        defer a.free(wr);
        const gr = try vfs.diff.block_codec.rawFromPageBytes(a, g.bytes, g.identity);
        defer a.free(gr);
        try same(gr, wr);
    }
    try check(got.tombstones.count() == want.tombstones.count());
    var tit = want.tombstones.iterator();
    while (tit.next()) |e| try same(e.value_ptr.*, got.tombstones.get(e.key_ptr.*) orelse return error.MissingTombstone);
    try check(got.placeholders.count() == want.placeholders.count());
    var hit = want.placeholders.keyIterator();
    while (hit.next()) |key| try check(got.placeholders.contains(key.*));
}
fn visibleMatches(base: []const u8, overlay: ?[]const u8, target: []const u8) !void {
    var image = try vfs.diff.pack_scan.PackImage.load(a, target);
    defer image.deinit();
    var volume = try vfs.volume.volume.Volume.open("process-recovery", .{});
    defer volume.close();
    try volume.mountPackWithPriority(base, 10, 0);
    if (overlay) |top| try volume.mountPackWithPriority(top, 20, 0);
    var expected = try vfs.volume.volume.Volume.open("process-expected", .{});
    defer expected.close();
    try expected.mountPackWithPriority(target, 10, 0);
    for (image.path_entries) |e| {
        var got = try volume.openPath(1, e.normalized_path);
        defer got.close();
        var want = try expected.openPath(1, e.normalized_path);
        defer want.close();
        try check(got.size == want.size);
        const gb = try a.alloc(u8, @intCast(got.size + 1));
        defer a.free(gb);
        const wb = try a.alloc(u8, @intCast(want.size + 1));
        defer a.free(wb);
        const gn = try got.readAt(0, gb);
        const wn = try want.readAt(0, wb);
        try same(gb[0..gn], wb[0..wn]);
    }
    if (volume.openPath(1, "/removed.bin")) |handle| {
        var h = handle;
        h.close();
        return error.DeletedFileStillVisible;
    } else |err| try check(err == error.NotFound);
}
fn options(workers: u32) session.PatchOptions {
    return .{ .budget = .{ .cpu = 4, .worker_threads = @intCast(workers) }, .writer = .{ .batch_ops = 1, .batch_bytes = 4096 }, .overlay_shards = 2, .optimize_after = true };
}
fn resumePatch(root: []const u8, overlay_mode: bool, workers: u32) !void {
    const base = try path(root, "base");
    const top: ?[]const u8 = if (overlay_mode) try path(root, "overlay") else null;
    const diff = try path(root, "diff");
    const recovered = try session.run(a, base, top, &.{diff}, null, options(workers));
    try check(recovered.to_version == 2 and (recovered.resumed or recovered.no_op));
    try equivalent(top orelse base, try path(root, if (overlay_mode) "control-overlay" else "control"));
    try visibleMatches(base, top, try path(root, "target"));
    var wanted = try vfs.diff.pack_scan.PackImage.load(a, try path(root, "target"));
    defer wanted.deinit();
    var actual = try vfs.diff.pack_scan.PackImage.load(a, top orelse base);
    defer actual.deinit();
    var manifests = wanted.files.iterator();
    while (manifests.next()) |entry| try same(entry.value_ptr.manifest_bytes, (actual.files.get(entry.key_ptr.*) orelse return error.MissingTargetManifest).manifest_bytes);
    const report = try session.run(a, base, top, &.{diff}, null, options(workers));
    try check(report.no_op and report.units_total == 0 and report.units_applied == 0 and report.file_ops == 0 and report.batches == 0 and report.bytes_written == 0);
}

fn waitReady(io: std.Io, marker: []const u8) !void {
    // Bound readiness waits; the caller's defer kills only its owned child on
    // timeout, including a child that fails or hangs before publishing readiness.
    for (0..3000) |_| {
        if (cwd.access(io, marker, .{})) |_| return else |err| {
            if (err != error.FileNotFound) return err;
        }
        try std.Io.sleep(io, .fromMilliseconds(10), .awake);
    }
    return error.ChildReadyTimeout;
}

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(a);
    if (args.len > 1) {
        const root = args[2];
        const overlay_mode = std.mem.eql(u8, args[3], "overlay");
        const workers = try std.fmt.parseInt(u32, args[4], 10);
        if (std.mem.eql(u8, args[1], "resume")) {
            try resumePatch(root, overlay_mode, workers);
            try vfs.build.pack_builder.writeSourceFileForTest(try path(root, "resumed"), "ok");
            return;
        }
        var opts = options(workers);
        // Set by the explicit process-stop hook; unlike fault injection this
        // publishes readiness while patch.run still owns every live resource.
        opts.process_stop = .{ .point = if (std.mem.eql(u8, args[5], "after_intent")) .after_intent else if (std.mem.eql(u8, args[5], "after_units")) .{ .after_units = 1 } else if (std.mem.eql(u8, args[5], "after_file_ops")) .{ .after_file_ops = 1 } else if (std.mem.eql(u8, args[5], "before_finalize")) .before_finalize else .after_finalize_before_optimize, .ready_path = try path(root, "ready") };
        _ = try session.run(a, try path(root, "base"), if (overlay_mode) try path(root, "overlay") else null, &.{try path(root, "diff")}, null, opts);
        return error.StopHookReturned;
    }
    var random: [16]u8 = undefined;
    std.Io.random(init.io, &random);
    const root = try std.fmt.allocPrint(a, "zig-cache-vfs-patch-process-{x}", .{random});
    try cwd.createDir(init.io, root, .default_dir);
    defer cwd.deleteTree(init.io, root) catch {};
    var count: usize = 0;
    for ([_]bool{ false, true }) |overlay_mode| for ([_]u32{ 1, 4 }) |workers| for (points) |point| {
        const case = try std.fmt.allocPrint(a, "{s}/{d}", .{ root, count });
        try cwd.createDir(init.io, case, .default_dir);
        try build(case, "base", 1);
        try build(case, "control", 1);
        try build(case, "target", 2);
        const base = try path(case, "base");
        const before = if (overlay_mode) try snapshot(init.io, base) else Snapshot.init(a);
        const diff = try path(case, "diff");
        const diff_report = try vfs.diff.createDiffPack(a, base, try path(case, "target"), diff, .{ .engine = .{ .budget = .{ .cpu = 2, .worker_threads = 2 } } });
        try check(diff_report.write.unit_count >= 2 and diff_report.write.file_op_count >= 2);
        _ = try session.run(a, try path(case, "control"), if (overlay_mode) try path(case, "control-overlay") else null, &.{diff}, null, options(workers));
        const mode = if (overlay_mode) "overlay" else "in-place";
        const worker_text = try std.fmt.allocPrint(a, "{d}", .{workers});
        std.debug.print("process recovery: {s}, workers={d}, {s}\n", .{ mode, workers, point });
        var child = try std.process.spawn(init.io, .{ .argv = &.{ args[0], "stop", case, mode, worker_text, point } });
        defer child.kill(init.io);
        const ready = try path(case, "ready");
        try waitReady(init.io, ready);
        child.kill(init.io);
        var fresh = try std.process.spawn(init.io, .{ .argv = &.{ args[0], "resume", case, mode, worker_text } });
        defer fresh.kill(init.io);
        try waitReady(init.io, try path(case, "resumed"));
        const term = try fresh.wait(init.io);
        try check(term == .exited and term.exited == 0);
        if (overlay_mode) try unchanged(init.io, base, before);
        count += 1;
    };
    std.debug.print("Passed {d} real process-death recovery cases.\n", .{count});
}
