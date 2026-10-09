const std = @import("std");
const db_internal = @import("db_internal");
const pf = db_internal.platform.file;
const kv = db_internal.kv_db;
const verify_mod = db_internal.recovery_verify;
const object_key = @import("../object_key.zig");
const hash = @import("../hash.zig");
const path_mod = @import("../path.zig");
const pack_writer = @import("../pack/pack_writer.zig");
const pack_manifest_fmt = @import("../format/pack_manifest.zig");
const path_index_fmt = @import("../format/path_index.zig");
const file_manifest_fmt = @import("../format/file_manifest.zig");
const page_value_fmt = @import("../format/page_value.zig");
const build_cfg_mod = @import("build_cfg.zig");
const build_plan_mod = @import("build_plan.zig");
const build_cache_mod = @import("build_cache.zig");
const pack_reader = @import("../pack/pack_reader.zig");
const registry = @import("../compress/registry.zig");
const task = @import("../task/root.zig");
const publication = @import("publication.zig");
const source_reader = @import("source_reader.zig");
pub const recoverBuild = publication.recover;

pub const DEFAULT_PAGE_SIZE: u32 = 64 * 1024;

pub const BuildFileInput = struct {
    source_path: []const u8,
    virtual_path: []const u8,
    file_entry: u64,
    page_size: u32 = DEFAULT_PAGE_SIZE,
    codec: file_manifest_fmt.Codec = .none,
    codec_level: i16 = 0,
};

pub const PackBuildOptions = struct {
    pack_id: u64 = 1,
    pack_version: u64 = 1,
    build_id: u64 = 1,
    /// Number of data_NNN.db shards for a new pack.
    shards: u32 = 1,
    /// Task budget for the page pipeline. Default derives from the host.
    budget: task.Budget = .{},
};

pub const IncrementalBuildResult = struct {
    rebuilt_files: u32 = 0,
    skipped_files: u32 = 0,
    cache_rebuilt: bool = false,
    cache_write_failed: bool = false,
    wrote_pack: bool = false,
    scheduled_tasks: u32 = 0,
};

// Reservations cover the entire page lifetime, not only the encode task.
// Object identity maps, path metadata and DB indexes are separate O(metadata)
// costs; see improvement_progress.md. No source/page-count-sized task arrays.
const BuildStats = struct {
    tasks: u64 = 0,
    windows: u64 = 0,
    peak_reserved: u64 = 0,
    peak_slots: usize = 0,
    peak_graph_tasks: usize = 0,
    peak_report_tasks: usize = 0,
    peak_pending_ops: usize = 0,
    peak_pending_payload: u64 = 0,
};

const BuildControl = struct {
    expected: ?[]const build_plan_mod.PlanFile = null,
    stats: ?*BuildStats = null,
    fail_after_close: bool = false,
    fail_after_windows: ?u64 = null,
    page_allocator: std.mem.Allocator = std.heap.smp_allocator,
};

const FileBuild = struct {
    input: BuildFileInput,
    normalized_path: []u8,
};

const PageSlot = struct {
    raw: []u8,
    value: ?[]u8 = null,
    page_index: u32,
    reservation: u64,
};

// Extra conservative admission margin, not an estimate of total heap usage.
// Scheduler/queue/DB descriptor capacities are separately O(worker_threads),
// retained up to the largest window. Worker stacks and persistent indexes
// likewise belong to the disclosed non-payload baseline.
const SLOT_ADMISSION_SLACK_BYTES: u64 = 4096;

fn pageReservation(raw_len: usize, codec: file_manifest_fmt.Codec, level: i16) !u64 {
    const n: u64 = raw_len;
    const value = try std.math.add(u64, n, page_value_fmt.HEADER_SIZE);
    if (value > std.math.maxInt(u32)) return error.InvalidArgument;
    const compression = try registry.compressionMemoryBound(raw_len, codec, level);
    // Raw + compressor scratch/output + VPAG + DB pending copy/key + aligned
    // DB append copy. Retaining the sum is conservative across stage changes.
    const append_record = try std.math.add(u64, value, 64 + 8 + 8 + 15);
    var total = try std.math.add(u64, n, compression);
    total = try std.math.add(u64, total, try std.math.mul(u64, value, 2));
    total = try std.math.add(u64, total, append_record);
    return std.math.add(u64, total, 8 + SLOT_ADMISSION_SLACK_BYTES);
}

const BuildContext = struct {
    allocator: std.mem.Allocator,
    input: BuildFileInput,
    slots: []PageSlot,

    fn run(ctx: *anyopaque, _: *task.Graph, _: task.TaskId, desc: task.TaskDesc) anyerror!task.RunResult {
        const self: *BuildContext = @ptrCast(@alignCast(ctx));
        const slot = &self.slots[desc.label_index];
        const raw = slot.raw;
        const compressed = try registry.compressPage(self.allocator, self.input.codec, self.input.codec_level, raw);
        defer self.allocator.free(compressed.bytes);
        slot.value = try page_value_fmt.encodePageValue(self.allocator, .{
            .file_entry = self.input.file_entry,
            .block_index = 0,
            .page_index = slot.page_index,
            .codec = compressed.codec,
            .raw_size = @intCast(raw.len),
            .stored_size = @intCast(compressed.bytes.len),
            .raw_crc = hash.crc32c(raw),
            .stored_crc = hash.crc32c(compressed.bytes),
            .content_hash = hash.contentHash(raw),
            .payload = compressed.bytes,
        });
        return .done;
    }
};

pub fn createPack(output_path: []const u8, files: []const BuildFileInput, options: PackBuildOptions) !void {
    return createPackInternal(output_path, files, options, false);
}

fn createPackInternal(output_path: []const u8, files: []const BuildFileInput, options: PackBuildOptions, fail_after_close: bool) !void {
    return createPackControlled(output_path, files, options, .{ .fail_after_close = fail_after_close });
}

fn createPackControlled(output_path: []const u8, files: []const BuildFileInput, options: PackBuildOptions, control: BuildControl) !void {
    const allocator = std.heap.smp_allocator;
    const page_allocator = control.page_allocator;
    if (control.expected) |expected| if (expected.len != files.len) return error.InvalidArgument;
    var stats: BuildStats = .{};
    defer if (control.stats) |out| {
        out.* = stats;
    };
    var publish = try publication.Publication.init(allocator, output_path);
    defer publish.deinit();
    try publish.begin();
    errdefer publish.cancel() catch {};
    var file_entries = std.AutoHashMap(u64, void).init(allocator);
    defer file_entries.deinit();
    var paths = std.StringHashMap(void).init(allocator);
    defer paths.deinit();

    const builds = try allocator.alloc(FileBuild, files.len);
    var builds_init: usize = 0;
    defer {
        for (builds[0..builds_init]) |fb| allocator.free(fb.normalized_path);
        allocator.free(builds);
    }
    for (files) |input| {
        if (input.file_entry == 0 or input.page_size == 0) return error.InvalidArgument;
        _ = try registry.codecIdentity(input.codec);
        if (file_entries.contains(input.file_entry)) return error.KeyCollision;
        try file_entries.put(input.file_entry, {});
        const normalized_path = try normalizeVirtualPath(allocator, input.virtual_path);
        errdefer allocator.free(normalized_path);
        if (paths.contains(normalized_path)) return error.KeyCollision;
        try paths.put(normalized_path, {});
        builds[builds_init] = .{ .input = input, .normalized_path = normalized_path };
        builds_init += 1;
    }

    var sched = try task.Scheduler.init(allocator, options.budget);
    defer sched.deinit();
    // Avoid millions of tiny descriptors even with a very large byte budget.
    const max_slots: usize = @as(usize, sched.budget.worker_threads) * 2;
    var writer = try pack_writer.PackWriter.createWithOptions(allocator, publish.stage, .{ .shards = options.shards });
    var writer_closed = false;
    errdefer if (!writer_closed) writer.abort();
    var path_entries = std.ArrayList(path_index_fmt.EntryInput).empty;
    defer path_entries.deinit(allocator);
    var pack_hasher = std.crypto.hash.sha2.Sha256.init(.{});

    for (builds, 0..) |fb, file_index| {
        var source = try pf.open(fb.input.source_path, .{ .mode = .read_only });
        defer pf.close(&source);
        const source_size = try pf.len(source);
        const page_count = try source_reader.pageCount(source_size, fb.input.page_size);
        if (control.expected) |expected| {
            if (expected[file_index].source_size != source_size) return error.SourceChanged;
        }
        var file_hasher = std.crypto.hash.sha2.Sha256.init(.{});
        var offset: u64 = 0;
        var page_index: u32 = 0;
        while (offset < source_size) {
            var slots = std.ArrayList(PageSlot).empty;
            defer {
                for (slots.items) |slot| {
                    page_allocator.free(slot.raw);
                    if (slot.value) |value| page_allocator.free(value);
                }
                slots.deinit(allocator);
            }
            var reserved: u64 = 0;
            while (offset < source_size and slots.items.len < max_slots) {
                const n: usize = @intCast(@min(source_size - offset, fb.input.page_size));
                const need = try pageReservation(n, fb.input.codec, fb.input.codec_level);
                if (need > sched.budget.mem_bytes) return error.NeedExceedsBudget;
                if (need > sched.budget.mem_bytes - reserved) break;
                const raw = try page_allocator.alloc(u8, n);
                errdefer page_allocator.free(raw);
                if (try pf.preadAll(source, offset, raw) != n) return error.SourceChanged;
                file_hasher.update(raw);
                try slots.append(allocator, .{ .raw = raw, .page_index = page_index, .reservation = need });
                reserved += need;
                offset += n;
                page_index += 1;
            }
            stats.peak_reserved = @max(stats.peak_reserved, reserved);
            stats.peak_slots = @max(stats.peak_slots, slots.items.len);
            // All retained raw/encoded/DB copies remain charged to this
            // window until commit; scheduler task completion does not refund
            // this ledger. Sum of every admitted slot <= resolved mem_bytes.
            var graph = task.Graph.init(allocator);
            defer graph.deinit();
            for (slots.items, 0..) |slot, i| {
                _ = try graph.addTask(.{
                    .kind = 1,
                    .label_file_entry = fb.input.file_entry,
                    .label_index = @intCast(i),
                    .need = if (fb.input.codec == .none)
                        .{ .cpu = 1, .mem_bytes = slot.reservation }
                    else
                        .{ .cpu_codec = 1, .mem_bytes = slot.reservation },
                });
            }
            stats.peak_graph_tasks = @max(stats.peak_graph_tasks, graph.tasks.items.len);
            var ctx = BuildContext{ .allocator = page_allocator, .input = fb.input, .slots = slots.items };
            var report = try sched.run(&graph, .{ .context = &ctx, .run = BuildContext.run }, .{});
            stats.tasks += report.finished;
            stats.peak_report_tasks = @max(stats.peak_report_tasks, report.dispatch_order.items.len);
            report.deinit(allocator);
            var pending_bytes: u64 = 0;
            for (slots.items) |slot| {
                const value = slot.value orelse return error.Corruption;
                try writer.putPage(fb.input.file_entry, 0, slot.page_index, value);
                pending_bytes += value.len;
            }
            stats.peak_pending_payload = @max(stats.peak_pending_payload, pending_bytes);
            stats.peak_pending_ops = @max(stats.peak_pending_ops, writer.db.pending.items.len);
            try writer.flush();
            stats.windows += 1;
            if (control.fail_after_windows) |limit| if (stats.windows >= limit) return error.InjectedBuildFailure;
        }
        var extra: [1]u8 = undefined;
        if (try pf.preadAll(source, source_size, &extra) != 0 or try pf.len(source) != source_size) return error.SourceChanged;
        var content_hash: [32]u8 = undefined;
        file_hasher.final(&content_hash);
        if (control.expected) |expected| {
            if (!std.mem.eql(u8, &content_hash, &expected[file_index].source_hash)) return error.SourceChanged;
        }
        const block = [_]file_manifest_fmt.BlockDesc{.{
            .raw_offset = 0,
            .raw_size = source_size,
            .page_size = fb.input.page_size,
            .page_count = page_count,
            .codec = fb.input.codec,
            .codec_level = fb.input.codec_level,
            .block_hash = content_hash,
        }};
        const manifest_value = try file_manifest_fmt.encodeFileManifest(allocator, .{
            .file_entry = fb.input.file_entry,
            .file_version = 1,
            .file_size = source_size,
            .content_hash = content_hash,
            .blocks = if (source_size == 0) &.{} else &block,
        });
        defer allocator.free(manifest_value);
        try writer.putFileManifest(fb.input.file_entry, manifest_value);
        // Keep metadata pending bounded too, even with many empty files.
        try writer.flush();
        try path_entries.append(allocator, .{ .normalized_path = fb.normalized_path, .file_entry = fb.input.file_entry });
        pack_hasher.update(&object_key.encodeDbKey(fb.input.file_entry));
        pack_hasher.update(fb.normalized_path);
        pack_hasher.update(&.{0});
        pack_hasher.update(&content_hash);
    }
    const path_index = try path_index_fmt.encodePathIndex(allocator, path_entries.items);
    defer allocator.free(path_index);
    try writer.putPathIndex(path_index);
    try writer.flush();
    var pack_hash: [32]u8 = undefined;
    pack_hasher.final(&pack_hash);
    const manifest = pack_manifest_fmt.encodePackManifest(.{
        .pack_id = options.pack_id,
        .pack_version = options.pack_version,
        .build_id = options.build_id,
        .file_count = files.len,
        .tombstone_count = 0,
        .content_hash = pack_hash,
    });
    try writer.putPackManifest(&manifest);
    try writer.close();
    writer_closed = true;
    if (control.fail_after_close) return error.InjectedBuildFailure;
    try verifyPackDb(publish.stage, allocator);
    try publish.publish();
}

pub const DumpInfo = struct {
    file_count: u64,
    tombstone_count: u64,
    pack_version: u64,
};

pub fn dumpPack(output: anytype, pack_path: []const u8) !DumpInfo {
    var db = try kv.KvDb.open(pack_path, .{ .mode = .read_only, .create_if_missing = false });
    defer db.close() catch {};
    var key = object_key.encodeDbKey(object_key.packManifestKey());
    const size = try db.getSizeBytes(&key);
    const buf = try std.heap.smp_allocator.alloc(u8, size);
    defer std.heap.smp_allocator.free(buf);
    _ = try db.getIntoBytes(&key, buf);
    const manifest = try pack_manifest_fmt.decodePackManifest(buf);
    try output.print("pack file_count={d} tombstone_count={d} pack_version={d}\n", .{ manifest.file_count, manifest.tombstone_count, manifest.pack_version });
    return .{ .file_count = manifest.file_count, .tombstone_count = manifest.tombstone_count, .pack_version = manifest.pack_version };
}

pub fn verifyPackDb(pack_path: []const u8, allocator: std.mem.Allocator) !void {
    const io = std.Io.Threaded.global_single_threaded.io();
    var dir = try std.Io.Dir.openDir(std.Io.Dir.cwd(), io, pack_path, .{});
    defer dir.close(io);
    var report = try verify_mod.verifyAt(dir, allocator);
    defer report.deinit();
    if (!report.ok()) return error.Corruption;
}

pub fn normalizeVirtualPath(allocator: std.mem.Allocator, virtual_path: []const u8) ![]u8 {
    return path_mod.normalizeVirtualPath(allocator, virtual_path);
}

pub fn buildFromConfig(cfg_path: []const u8, allocator: std.mem.Allocator) !IncrementalBuildResult {
    var cfg = try build_cfg_mod.parseFile(allocator, cfg_path);
    defer cfg.deinit(allocator);
    var plan = try build_plan_mod.create(allocator, cfg);
    defer plan.deinit(allocator);
    return buildPlanIncremental(plan, allocator);
}

pub fn buildPlanIncremental(plan: build_plan_mod.BuildPlan, allocator: std.mem.Allocator) !IncrementalBuildResult {
    _ = std.math.cast(u32, plan.files.len) orelse return error.InvalidArgument;
    var result: IncrementalBuildResult = .{};
    var cache = build_cache_mod.load(allocator, plan.pack_path) catch |e| switch (e) {
        error.FileNotFound, error.Corruption => blk: {
            result.cache_rebuilt = true;
            break :blk null;
        },
        else => |err| return err,
    };
    defer if (cache) |*c| c.deinit(allocator);

    var changed: usize = 0;
    if (cache) |c| {
        for (plan.files) |file| {
            const entry = c.findByFileEntry(file.file_entry);
            if (entry == null or !build_cache_mod.matchesPlan(entry.?, file)) changed += 1;
        }
        if (c.entries.len != plan.files.len) changed += 1;
    } else {
        changed = plan.files.len;
    }

    if (changed == 0 and cache != null and try packExists(plan.pack_path) and try packIdentityMatches(plan) and cacheMatchesOutput(plan, cache.?, allocator)) {
        // A caller can retain a plan after its snapshot becomes obsolete. A
        // no-op is safe only while its sources still match that snapshot.
        for (plan.files) |file| {
            const current = try source_reader.snapshot(file.source_path);
            if (current.size != file.source_size or !std.mem.eql(u8, &current.content_hash, &file.source_hash)) return error.SourceChanged;
        }
        result.skipped_files = @intCast(plan.files.len);
        return result;
    }

    var inputs = std.ArrayList(BuildFileInput).empty;
    defer inputs.deinit(allocator);
    var planned_tasks: u32 = 0;
    for (plan.files) |file| {
        try inputs.append(allocator, .{
            .source_path = file.source_path,
            .virtual_path = file.virtual_path,
            .file_entry = file.file_entry,
            .page_size = file.page_size,
            .codec = file.codec,
            .codec_level = file.codec_level,
        });
        planned_tasks = std.math.add(u32, planned_tasks, try source_reader.pageCount(file.source_size, file.page_size)) catch return error.InvalidArgument;
    }
    var stats: BuildStats = .{};
    try createPackControlled(plan.pack_path, inputs.items, .{ .pack_id = plan.pack_id, .pack_version = plan.pack_version, .build_id = plan.pack_version, .shards = plan.shards }, .{ .expected = plan.files, .stats = &stats });
    result.scheduled_tasks = @intCast(stats.tasks);
    result.rebuilt_files = @intCast(plan.files.len);
    result.wrote_pack = true;

    // The pack is already committed. Cache failure may cost a later rebuild,
    // but must not misreport successful publication as a failed build.
    writeBuildCache(plan, allocator) catch {
        result.cache_write_failed = true;
    };
    return result;
}

// A source cache is only a hint. Bind every no-op to the published generation's
// actual manifest bytes and path mapping, not just matching source metadata.
fn cacheMatchesOutput(plan: build_plan_mod.BuildPlan, cache: build_cache_mod.BuildCache, allocator: std.mem.Allocator) bool {
    var reader = pack_reader.PackReader.open(allocator, plan.pack_path) catch return false;
    defer reader.close(allocator);
    if (reader.manifest.file_count != plan.files.len or cache.entries.len != plan.files.len) return false;
    for (plan.files) |file| {
        const entry = cache.findByFileEntry(file.file_entry) orelse return false;
        const actual_entry = reader.resolvePath(allocator, file.virtual_path) catch return false;
        if (actual_entry != file.file_entry) return false;
        const bytes = reader.readObjectAlloc(allocator, file.file_manifest_key) catch return false;
        defer allocator.free(bytes);
        const actual_hash = hash.contentHash(bytes);
        if (!std.mem.eql(u8, &actual_hash, &entry.output_manifest_hash)) return false;
        var manifest = file_manifest_fmt.decodeFileManifest(allocator, bytes, file.file_entry) catch return false;
        defer manifest.deinit(allocator);
        if (manifest.header.file_size != file.source_size or !std.mem.eql(u8, &manifest.header.content_hash, &file.source_hash)) return false;
    }
    return true;
}

fn writeBuildCache(plan: build_plan_mod.BuildPlan, allocator: std.mem.Allocator) !void {
    var entries = std.ArrayList(build_cache_mod.Entry).empty;
    defer {
        for (entries.items) |entry| {
            allocator.free(entry.virtual_path);
            allocator.free(entry.source_path);
        }
        entries.deinit(allocator);
    }
    var reader = try pack_reader.PackReader.open(allocator, plan.pack_path);
    defer reader.close(allocator);
    for (plan.files) |file| {
        const manifest_bytes = try reader.readObjectAlloc(allocator, file.file_manifest_key);
        defer allocator.free(manifest_bytes);
        try entries.append(allocator, try build_cache_mod.entryFromPlan(allocator, file, hash.contentHash(manifest_bytes)));
    }
    try build_cache_mod.write(allocator, plan.pack_path, entries.items);
}

/// The per-file cache cannot see pack-level settings; a pack whose
/// id/version/shard layout differ from the plan must be rebuilt even when
/// every source is unchanged.
fn packIdentityMatches(plan: build_plan_mod.BuildPlan) !bool {
    var db = kv.KvDb.open(plan.pack_path, .{ .mode = .read_only, .create_if_missing = false }) catch return false;
    defer db.close() catch {};
    if (db.shardCount() != plan.shards) return false;
    const kb = object_key.encodeDbKey(object_key.packManifestKey());
    const bytes = db.getBorrowedBytes(&kb) catch return false;
    const manifest = pack_manifest_fmt.decodePackManifest(bytes) catch return false;
    return manifest.pack_id == plan.pack_id and manifest.pack_version == plan.pack_version and manifest.build_id == plan.pack_version;
}

fn packExists(pack_path: []const u8) !bool {
    const manifest_path = try std.fs.path.join(std.heap.smp_allocator, &.{ pack_path, "manifest.db" });
    defer std.heap.smp_allocator.free(manifest_path);
    var f = pf.open(manifest_path, .{ .mode = .read_only }) catch |e| switch (e) {
        error.FileNotFound => return false,
        else => |err| return err,
    };
    pf.close(&f);
    return true;
}

fn readDbObject(allocator: std.mem.Allocator, pack_path: []const u8, key: u64) ![]u8 {
    var db = try kv.KvDb.open(pack_path, .{ .mode = .read_only, .create_if_missing = false });
    defer db.close() catch {};
    var key_bytes = object_key.encodeDbKey(key);
    const size = try db.getSizeBytes(&key_bytes);
    const buf = try allocator.alloc(u8, size);
    errdefer allocator.free(buf);
    _ = try db.getIntoBytes(&key_bytes, buf);
    return buf;
}

test "normalize virtual path is deterministic and rejects parent traversal" {
    const allocator = std.testing.allocator;
    const p = try normalizeVirtualPath(allocator, "\\assets\\hero.png");
    defer allocator.free(p);
    try std.testing.expectEqualSlices(u8, "assets/hero.png", p);
    try std.testing.expectError(error.InvalidArgument, normalizeVirtualPath(allocator, "/assets/../secret"));
}

test "pack builder writes single multiple empty and paged files into real DB" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    const pack_path = "zig-cache-vfs-pack-builder-test";
    const small_path = "zig-cache-vfs-pack-small.bin";
    const large_path = "zig-cache-vfs-pack-large.bin";
    const empty_path = "zig-cache-vfs-pack-empty.bin";
    _ = std.Io.Dir.cwd().deleteTree(io, pack_path) catch {};
    defer _ = std.Io.Dir.cwd().deleteTree(io, pack_path) catch {};
    _ = std.Io.Dir.cwd().deleteFile(io, small_path) catch {};
    _ = std.Io.Dir.cwd().deleteFile(io, large_path) catch {};
    _ = std.Io.Dir.cwd().deleteFile(io, empty_path) catch {};
    defer _ = std.Io.Dir.cwd().deleteFile(io, small_path) catch {};
    defer _ = std.Io.Dir.cwd().deleteFile(io, large_path) catch {};
    defer _ = std.Io.Dir.cwd().deleteFile(io, empty_path) catch {};

    try writeSourceFile(small_path, "abcdef");
    try writeSourceFile(large_path, "0123456789");
    try writeSourceFile(empty_path, "");

    const inputs = [_]BuildFileInput{
        .{ .source_path = small_path, .virtual_path = "/small.bin", .file_entry = 10, .page_size = 4 },
        .{ .source_path = large_path, .virtual_path = "/large.bin", .file_entry = 11, .page_size = 4 },
        .{ .source_path = empty_path, .virtual_path = "/empty.bin", .file_entry = 12, .page_size = 4 },
    };

    try createPack(pack_path, &inputs, .{});
    try verifyPackDb(pack_path, allocator);

    const path_index = try readDbObject(allocator, pack_path, object_key.pathIndexKey());
    defer allocator.free(path_index);
    const found = (try path_index_fmt.lookup(path_index, "large.bin")).?;
    try std.testing.expectEqual(@as(u64, 11), found.file_entry);

    const page0 = try readDbObject(allocator, pack_path, try object_key.pageKey(11, 0, 0));
    defer allocator.free(page0);
    const decoded0 = try page_value_fmt.decodePageValue(page0, .{ .file_entry = 11, .block_index = 0, .page_index = 0 });
    try std.testing.expectEqualSlices(u8, "0123", decoded0.payload);
    const page2 = try readDbObject(allocator, pack_path, try object_key.pageKey(11, 0, 2));
    defer allocator.free(page2);
    const decoded2 = try page_value_fmt.decodePageValue(page2, .{ .file_entry = 11, .block_index = 0, .page_index = 2 });
    try std.testing.expectEqualSlices(u8, "89", decoded2.payload);

    const empty_manifest_bytes = try readDbObject(allocator, pack_path, try object_key.fileManifestKey(12));
    defer allocator.free(empty_manifest_bytes);
    var empty_manifest = try file_manifest_fmt.decodeFileManifest(allocator, empty_manifest_bytes, 12);
    defer empty_manifest.deinit(allocator);
    try std.testing.expectEqual(@as(u64, 0), empty_manifest.header.file_size);
    try std.testing.expectEqual(@as(usize, 0), empty_manifest.blocks.len);
}

test "pack builder rejects duplicate file_entry and duplicate object identity" {
    const io = std.Io.Threaded.global_single_threaded.io();
    const allocator = std.testing.allocator;
    _ = allocator;
    const source = "zig-cache-vfs-pack-dup-source.bin";
    const pack_path = "zig-cache-vfs-pack-builder-duplicate-test";
    _ = std.Io.Dir.cwd().deleteFile(io, source) catch {};
    _ = std.Io.Dir.cwd().deleteTree(io, pack_path) catch {};
    defer _ = std.Io.Dir.cwd().deleteFile(io, source) catch {};
    defer _ = std.Io.Dir.cwd().deleteTree(io, pack_path) catch {};
    try writeSourceFile(source, "a");
    const inputs = [_]BuildFileInput{
        .{ .source_path = source, .virtual_path = "/a.bin", .file_entry = 99, .page_size = 4 },
        .{ .source_path = source, .virtual_path = "/b.bin", .file_entry = 99, .page_size = 4 },
    };
    try std.testing.expectError(error.KeyCollision, createPack(pack_path, &inputs, .{}));
}

test "build cfg incremental rebuilds and skips safely" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    const pack_path = "zig-cache-vfs-buildcfg-pack";
    const cfg_path = "zig-cache-vfs-buildcfg.txt";
    const source_a = "zig-cache-vfs-buildcfg-a.txt";
    const source_b = "zig-cache-vfs-buildcfg-b.txt";
    _ = std.Io.Dir.cwd().deleteTree(io, pack_path) catch {};
    _ = std.Io.Dir.cwd().deleteFile(io, cfg_path) catch {};
    _ = std.Io.Dir.cwd().deleteFile(io, source_a) catch {};
    _ = std.Io.Dir.cwd().deleteFile(io, source_b) catch {};
    const cache_path = try build_cache_mod.cachePath(allocator, pack_path);
    defer allocator.free(cache_path);
    _ = std.Io.Dir.cwd().deleteFile(io, cache_path) catch {};
    defer _ = std.Io.Dir.cwd().deleteTree(io, pack_path) catch {};
    defer _ = std.Io.Dir.cwd().deleteFile(io, cfg_path) catch {};
    defer _ = std.Io.Dir.cwd().deleteFile(io, source_a) catch {};
    defer _ = std.Io.Dir.cwd().deleteFile(io, source_b) catch {};
    defer _ = std.Io.Dir.cwd().deleteFile(io, cache_path) catch {};

    try writeSourceFileForTest(source_a, "alpha");
    try writeSourceFileForTest(source_b, "bravo");
    const cfg_text1 = try std.fmt.allocPrint(
        allocator,
        "pack_path={s}\npack_id=3\ndefault_page_size=4\ndefault_codec=none\nfile=/a.txt|9101|{s}\nfile=/b.txt|9102|{s}|3|none|0\n",
        .{ pack_path, source_a, source_b },
    );
    defer allocator.free(cfg_text1);
    try writeSourceFileForTest(cfg_path, cfg_text1);
    var r = try buildFromConfig(cfg_path, allocator);
    try std.testing.expectEqual(@as(u32, 2), r.rebuilt_files);
    try std.testing.expect(r.scheduled_tasks > 0);
    try verifyPackDb(pack_path, allocator);
    r = try buildFromConfig(cfg_path, allocator);
    try std.testing.expectEqual(@as(u32, 2), r.skipped_files);

    const cfg_text_codec = try std.fmt.allocPrint(
        allocator,
        "pack_path={s}\npack_id=3\ndefault_page_size=4\ndefault_codec=none\ndefault_codec_level=1\nfile=/a.txt|9101|{s}\nfile=/b.txt|9102|{s}|3|none|0\n",
        .{ pack_path, source_a, source_b },
    );
    defer allocator.free(cfg_text_codec);
    try writeSourceFileForTest(cfg_path, cfg_text_codec);
    r = try buildFromConfig(cfg_path, allocator);
    try std.testing.expectEqual(@as(u32, 2), r.rebuilt_files);

    try writeSourceFileForTest(source_a, "alpha!");
    r = try buildFromConfig(cfg_path, allocator);
    try std.testing.expectEqual(@as(u32, 2), r.rebuilt_files);
    try verifyPackDb(pack_path, allocator);

    const cfg_text2 = try std.fmt.allocPrint(
        allocator,
        "pack_path={s}\npack_id=3\ndefault_page_size=8\ndefault_codec=none\nfile=/renamed.txt|9101|{s}\nfile=/b.txt|9202|{s}|3|none|0\n",
        .{ pack_path, source_a, source_b },
    );
    defer allocator.free(cfg_text2);
    try writeSourceFileForTest(cfg_path, cfg_text2);
    r = try buildFromConfig(cfg_path, allocator);
    try std.testing.expectEqual(@as(u32, 2), r.rebuilt_files);
    var reader = try pack_reader.PackReader.open(allocator, pack_path);
    defer reader.close(allocator);
    try std.testing.expectEqual(@as(u64, 9101), try reader.resolvePath(allocator, "/renamed.txt"));
    var changed_manifest = try reader.readFileManifest(allocator, 9202);
    changed_manifest.deinit(allocator);

    try writeSourceFileForTest(cache_path, "damaged");
    r = try buildFromConfig(cfg_path, allocator);
    try std.testing.expect(r.cache_rebuilt);
}

test "pack builder writes lz4 pages across shards and volume reads them back" {
    const allocator = std.testing.allocator;
    const volume_mod = @import("../volume/volume.zig");
    const io = std.Io.Threaded.global_single_threaded.io();
    const pack_path = "zig-cache-vfs-pack-lz4-test";
    const src_path = "zig-cache-vfs-pack-lz4-src.bin";
    _ = std.Io.Dir.cwd().deleteTree(io, pack_path) catch {};
    _ = std.Io.Dir.cwd().deleteFile(io, src_path) catch {};
    defer _ = std.Io.Dir.cwd().deleteTree(io, pack_path) catch {};
    defer _ = std.Io.Dir.cwd().deleteFile(io, src_path) catch {};

    // 3 pages: compressible, random (store-raw fallback), compressible tail.
    const page: usize = 4096;
    const data = try allocator.alloc(u8, page * 2 + 777);
    defer allocator.free(data);
    for (data[0..page], 0..) |*b, i| b.* = @intCast((i / 16) % 251);
    var prng = std.Random.DefaultPrng.init(7);
    prng.random().bytes(data[page .. page * 2]);
    @memset(data[page * 2 ..], 'z');
    try writeSourceFile(src_path, data);

    try createPack(pack_path, &.{.{ .source_path = src_path, .virtual_path = "/lz.bin", .file_entry = 4242, .page_size = @intCast(page), .codec = .lz4, .codec_level = 4 }}, .{ .pack_id = 7, .shards = 3 });
    try verifyPackDb(pack_path, allocator);

    const p0 = try readDbObject(allocator, pack_path, try object_key.pageKey(4242, 0, 0));
    defer allocator.free(p0);
    const d0 = try page_value_fmt.decodePageValue(p0, .{ .file_entry = 4242, .block_index = 0, .page_index = 0 });
    try std.testing.expectEqual(file_manifest_fmt.Codec.lz4, d0.codec);
    try std.testing.expect(d0.stored_size < d0.raw_size);
    const p1 = try readDbObject(allocator, pack_path, try object_key.pageKey(4242, 0, 1));
    defer allocator.free(p1);
    const d1 = try page_value_fmt.decodePageValue(p1, .{ .file_entry = 4242, .block_index = 0, .page_index = 1 });
    try std.testing.expectEqual(file_manifest_fmt.Codec.none, d1.codec);

    var v = try volume_mod.Volume.open("lz4-check", .{});
    defer v.close();
    try v.mountPackWithPriority(pack_path, 0, 0);
    var h = try v.openPath(1, "/lz.bin");
    defer h.close();
    const out = try allocator.alloc(u8, data.len);
    defer allocator.free(out);
    try std.testing.expectEqual(data.len, try h.readAt(0, out));
    try std.testing.expectEqualSlices(u8, data, out);
    // Partial read spanning the compressed/raw boundary.
    var small: [100]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 100), try h.readAt(page - 50, &small));
    try std.testing.expectEqualSlices(u8, data[page - 50 .. page + 50], &small);

    var db = try kv.KvDb.open(pack_path, .{ .mode = .read_only, .create_if_missing = false });
    defer db.close() catch {};
    try std.testing.expectEqual(@as(u32, 3), db.shardCount());
}

fn writeSourceFile(path: []const u8, data: []const u8) !void {
    return writeSourceFileForTest(path, data);
}

pub fn writeSourceFileForTest(path: []const u8, data: []const u8) !void {
    var file = try pf.open(path, .{ .mode = .create_read_write, .create_parent_dirs = true });
    defer pf.close(&file);
    try pf.setLen(file, 0);
    try pf.pwriteAll(file, 0, data);
    try pf.flushMetadata(file);
}

test "pack build capacity handles fresh and replacement outputs" {
    const io = std.Io.Threaded.global_single_threaded.io();
    const out = "zig-cache-vfs-build-capacity";
    const source = "zig-cache-vfs-build-capacity.bin";
    defer std.Io.Dir.cwd().deleteTree(io, out) catch {};
    defer std.Io.Dir.cwd().deleteFile(io, source) catch {};
    const bytes = try std.testing.allocator.alloc(u8, 1024 * 64);
    defer std.testing.allocator.free(bytes);
    @memset(bytes, 42);
    try writeSourceFileForTest(source, bytes);
    const inputs = [_]BuildFileInput{.{ .source_path = source, .virtual_path = "/large", .file_entry = 8100, .page_size = 64 }};
    try createPack(out, &inputs, .{});
    try verifyPackDb(out, std.testing.allocator);
    try createPack(out, &inputs, .{ .pack_version = 2 });
    var reader = try pack_reader.PackReader.open(std.testing.allocator, out);
    defer reader.close(std.testing.allocator);
    try std.testing.expectEqual(@as(u64, 2), reader.manifest.pack_version);
}

test "failed replacement retains old valid pack" {
    const io = std.Io.Threaded.global_single_threaded.io();
    const out = "zig-cache-vfs-build-failure";
    const source = "zig-cache-vfs-build-failure.bin";
    defer std.Io.Dir.cwd().deleteTree(io, out) catch {};
    defer std.Io.Dir.cwd().deleteFile(io, source) catch {};
    try writeSourceFileForTest(source, "old");
    const inputs = [_]BuildFileInput{.{ .source_path = source, .virtual_path = "/old", .file_entry = 8101 }};
    try createPack(out, &inputs, .{ .pack_version = 7 });
    // Invalid writer configuration fails after source processing, before publication.
    try std.testing.expectError(error.InvalidArgument, createPack(out, &inputs, .{ .shards = 0 }));
    try std.testing.expectError(error.InjectedBuildFailure, createPackInternal(out, &inputs, .{}, true));
    var reader = try pack_reader.PackReader.open(std.testing.allocator, out);
    defer reader.close(std.testing.allocator);
    try std.testing.expectEqual(@as(u64, 7), reader.manifest.pack_version);
}

test "incremental build invalidates removed inputs and stale planning hashes" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(root);
    const source = try std.fs.path.join(allocator, &.{ root, "source" });
    defer allocator.free(source);
    const output = try std.fs.path.join(allocator, &.{ root, "pack" });
    defer allocator.free(output);
    const config = try std.fs.path.join(allocator, &.{ root, "build.cfg" });
    defer allocator.free(config);
    try writeSourceFileForTest(source, "original");
    const cfg_text = try std.fmt.allocPrint(allocator, "pack_path={s}\nfile=/one|7101|{s}\nfile=/two|7102|{s}\n", .{ output, source, source });
    defer allocator.free(cfg_text);
    try writeSourceFileForTest(config, cfg_text);
    _ = try buildFromConfig(config, allocator);
    const cfg_one = try std.fmt.allocPrint(allocator, "pack_path={s}\nfile=/one|7101|{s}\n", .{ output, source });
    defer allocator.free(cfg_one);
    try writeSourceFileForTest(config, cfg_one);
    const removed = try buildFromConfig(config, allocator);
    try std.testing.expect(removed.wrote_pack);
    var reader = try pack_reader.PackReader.open(allocator, output);
    try std.testing.expectError(error.NotFound, reader.resolvePath(allocator, "/two"));
    reader.close(allocator);
    var cfg = try build_cfg_mod.parseFile(allocator, config);
    defer cfg.deinit(allocator);
    var plan = try build_plan_mod.create(allocator, cfg);
    defer plan.deinit(allocator);
    // Force construction while preserving the obsolete planned source hash.
    plan.pack_version += 1;
    try writeSourceFileForTest(source, "modified");
    try std.testing.expectError(error.SourceChanged, buildPlanIncremental(plan, allocator));
}

test "bounded pack windows retain reservations through DB commit" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(root);
    const source = try std.fs.path.join(allocator, &.{ root, "source" });
    defer allocator.free(source);
    const output = try std.fs.path.join(allocator, &.{ root, "pack" });
    defer allocator.free(output);
    const page_size = 4096;
    var page: [page_size]u8 = undefined;
    var prng = std.Random.DefaultPrng.init(771);
    prng.random().bytes(&page);
    for ([_]file_manifest_fmt.Codec{ .none, .lz4 }) |codec| {
        const reservation = try pageReservation(page_size, codec, 4);
        const budget = reservation * 2;
        var first_peak: usize = 0;
        for ([_]usize{ 8, 80, 800 }) |pages| {
            var f = try pf.open(source, .{ .mode = .create_read_write });
            try pf.setLen(f, 0);
            for (0..pages) |i| try pf.pwriteAll(f, i * page_size, &page);
            try pf.pwriteAll(f, pages * page_size, "tail");
            pf.close(&f);
            var stats: BuildStats = .{};
            const inputs = [_]BuildFileInput{.{ .source_path = source, .virtual_path = "/bounded", .file_entry = 0xffff_ffff_0000_7103, .page_size = page_size, .codec = codec, .codec_level = 4 }};
            const options: PackBuildOptions = .{ .shards = 3, .budget = .{ .mem_bytes = budget, .worker_threads = 2 } };
            try createPackControlled(output, &inputs, options, .{ .stats = &stats });
            try std.testing.expectEqual(@as(u64, pages + 1), stats.tasks);
            try std.testing.expect(stats.windows > 1);
            try std.testing.expect(stats.peak_reserved <= budget);
            try std.testing.expectEqual(@as(usize, 2), stats.peak_slots);
            try std.testing.expectEqual(stats.peak_slots, stats.peak_graph_tasks);
            try std.testing.expectEqual(stats.peak_slots, stats.peak_report_tasks);
            try std.testing.expectEqual(stats.peak_slots, stats.peak_pending_ops);
            try std.testing.expect(stats.peak_pending_payload <= 2 * (page_size + page_value_fmt.HEADER_SIZE));
            if (pages == 8) first_peak = stats.peak_slots else try std.testing.expectEqual(first_peak, stats.peak_slots);
            try verifyPackDb(output, allocator);
            {
                var reader = try pack_reader.PackReader.open(allocator, output);
                defer reader.close(allocator);
                for (0..pages + 1) |i| {
                    const bytes = try reader.readObjectAlloc(allocator, try object_key.pageKey(inputs[0].file_entry, 0, @intCast(i)));
                    defer allocator.free(bytes);
                    const decoded = try page_value_fmt.decodePageValue(bytes, .{ .file_entry = inputs[0].file_entry, .block_index = 0, .page_index = @intCast(i) });
                    const raw = try registry.decompressPage(allocator, decoded.codec, decoded.payload, decoded.raw_size, decoded.raw_crc);
                    defer allocator.free(raw);
                    try std.testing.expectEqualSlices(u8, if (i == pages) "tail" else &page, raw);
                }
            }
            // An encoded window has reached durable staging. Failure must
            // release all pending copies and leave the previous pack intact.
            try std.testing.expectError(error.InjectedBuildFailure, createPackControlled(output, &inputs, options, .{ .fail_after_windows = 2 }));
            try verifyPackDb(output, allocator);
            const before = try readDbObject(allocator, output, object_key.packManifestKey());
            defer allocator.free(before);
            try std.testing.expectError(error.NeedExceedsBudget, createPackControlled(output, &inputs, .{ .budget = .{ .mem_bytes = reservation - 1 } }, .{}));
            const after = try readDbObject(allocator, output, object_key.packManifestKey());
            defer allocator.free(after);
            try std.testing.expectEqualSlices(u8, before, after);
        }
    }
}

test "incremental cache binds published manifests and stale no-op plans" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(root);
    const source = try std.fs.path.join(allocator, &.{ root, "source" });
    defer allocator.free(source);
    const output = try std.fs.path.join(allocator, &.{ root, "pack" });
    defer allocator.free(output);
    const config = try std.fs.path.join(allocator, &.{ root, "build.cfg" });
    defer allocator.free(config);
    const cfg_text = try std.fmt.allocPrint(allocator, "pack_path={s}\nfile=/one|7104|{s}\n", .{ output, source });
    defer allocator.free(cfg_text);
    try writeSourceFileForTest(config, cfg_text);
    try writeSourceFileForTest(source, "original");
    _ = try buildFromConfig(config, allocator);
    try std.testing.expect(!(try buildFromConfig(config, allocator)).wrote_pack);
    // Replace output externally but retain the cache. Sources return to their
    // cached state, so only binding to the actual manifest catches this.
    try writeSourceFileForTest(source, "modified");
    try createPack(output, &.{.{ .source_path = source, .virtual_path = "/one", .file_entry = 7104 }}, .{});
    try writeSourceFileForTest(source, "original");
    const rebuilt = try buildFromConfig(config, allocator);
    try std.testing.expect(rebuilt.wrote_pack);
    try std.testing.expectEqual(@as(u32, 1), rebuilt.scheduled_tasks);
    try std.testing.expectEqual(@as(u32, 1), rebuilt.rebuilt_files);
    var cfg = try build_cfg_mod.parseFile(allocator, config);
    defer cfg.deinit(allocator);
    var plan = try build_plan_mod.create(allocator, cfg);
    defer plan.deinit(allocator);
    try writeSourceFileForTest(source, "modified");
    try std.testing.expectError(error.SourceChanged, buildPlanIncremental(plan, allocator));
}

test "bounded page admission accounts codec scratch and giant pages" {
    const none_need = try pageReservation(65536, .none, 0);
    const lz4_fast = try pageReservation(65536, .lz4, 0);
    const lz4_chain = try pageReservation(65536, .lz4, 4);
    try std.testing.expect(none_need > 4 * 65536);
    try std.testing.expect(lz4_fast > none_need + 262144);
    try std.testing.expectEqual(@as(u64, 2 * 65536), lz4_chain - lz4_fast);
    try std.testing.expectError(error.InvalidArgument, pageReservation(std.math.maxInt(u32), .none, 0));
    try std.testing.expectError(error.InvalidArgument, pageReservation(0x7e000001, .lz4, 0));
}

test "bounded pack source and encoder allocation failures release every window" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(root);
    const source = try std.fs.path.join(allocator, &.{ root, "source" });
    defer allocator.free(source);
    const output = try std.fs.path.join(allocator, &.{ root, "pack" });
    defer allocator.free(output);
    try writeSourceFileForTest(source, "0123456789abcdef");
    const inputs = [_]BuildFileInput{.{ .source_path = source, .virtual_path = "/fail", .file_entry = 7106, .page_size = 4 }};
    const options: PackBuildOptions = .{ .budget = .{ .worker_threads = 1, .mem_bytes = 2 * try pageReservation(4, .none, 0) } };
    try createPack(output, &inputs, .{ .pack_version = 99 });
    // Four pages each allocate raw, codec output and VPAG. This covers read
    // allocation, partial encode results, and failures after a flushed window.
    for (0..12) |fail_index| {
        var failing = std.testing.FailingAllocator.init(allocator, .{ .fail_index = fail_index });
        try std.testing.expectError(error.OutOfMemory, createPackControlled(output, &inputs, options, .{ .page_allocator = failing.allocator() }));
        try std.testing.expect(failing.has_induced_failure);
        try std.testing.expectEqual(failing.allocated_bytes, failing.freed_bytes);
        var reader = try pack_reader.PackReader.open(allocator, output);
        defer reader.close(allocator);
        try std.testing.expectEqual(@as(u64, 99), reader.manifest.pack_version);
    }
}
