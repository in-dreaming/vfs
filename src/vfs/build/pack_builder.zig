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

const OwnedPathEntry = struct {
    path: []u8,
    input_index: usize,
};

/// Encoded page ready to be written; produced by the page pipeline tasks.
const EncodedPage = struct {
    file_index: usize,
    page_index: u32,
    value: []u8,
};

const FileBuild = struct {
    input: BuildFileInput,
    normalized_path: []u8,
    data: []u8 = &.{},
    content_hash: [32]u8 = [_]u8{0} ** 32,
    page_count: u32 = 0,
    pages: []?[]u8 = &.{},
};

/// Task kinds used by the builder's graph.
const BuildKind = enum(u16) {
    read_source = 1,
    encode_page = 2,
    file_done = 3,
};

const BuildContext = struct {
    allocator: std.mem.Allocator,
    files: []FileBuild,
    lock: db_internal.platform.sync.Mutex = .{},

    fn run(ctx: *anyopaque, graph: *task.Graph, id: task.TaskId, desc: task.TaskDesc) anyerror!task.RunResult {
        const self: *BuildContext = @ptrCast(@alignCast(ctx));
        const file_index: usize = @intCast(desc.label_file_entry);
        const fb = &self.files[file_index];
        switch (@as(BuildKind, @enumFromInt(desc.kind))) {
            .read_source => {
                const data = try readFileAlloc(self.allocator, fb.input.source_path);
                const page_count: u32 = if (data.len == 0) 0 else std.math.cast(u32, ((data.len - 1) / fb.input.page_size) + 1) orelse return error.InvalidArgument;
                const pages = try self.allocator.alloc(?[]u8, page_count);
                @memset(pages, null);
                {
                    self.lock.lock();
                    defer self.lock.unlock();
                    fb.data = data;
                    fb.content_hash = hash.contentHash(data);
                    fb.page_count = page_count;
                    fb.pages = pages;
                }
                // Fan out one encode task per page now that the size is known.
                var page_index: u32 = 0;
                var deps = std.ArrayList(task.TaskId).empty;
                defer deps.deinit(self.allocator);
                while (page_index < page_count) : (page_index += 1) {
                    const need: task.Need = if (fb.input.codec == .none)
                        .{ .cpu = 1, .mem_bytes = fb.input.page_size, .pack_shared = true, .pack_id = 1 }
                    else
                        .{ .cpu_codec = 1, .mem_bytes = @as(u64, fb.input.page_size) * 2, .pack_shared = true, .pack_id = 1 };
                    const t = try graph.addTaskWithDeps(.{ .kind = @intFromEnum(BuildKind.encode_page), .need = need, .label_file_entry = desc.label_file_entry, .label_index = page_index, .priority = 10 }, &.{id});
                    try deps.append(self.allocator, t);
                }
                _ = try graph.addTaskWithDeps(.{ .kind = @intFromEnum(BuildKind.file_done), .label_file_entry = desc.label_file_entry }, deps.items);
                return .done;
            },
            .encode_page => {
                const page_index = desc.label_index;
                const start: usize = @as(usize, page_index) * @as(usize, fb.input.page_size);
                const end = @min(fb.data.len, start + fb.input.page_size);
                const raw = fb.data[start..end];
                const compressed = try registry.compressPage(self.allocator, fb.input.codec, fb.input.codec_level, raw);
                defer self.allocator.free(compressed.bytes);
                const value = try page_value_fmt.encodePageValue(self.allocator, .{
                    .file_entry = fb.input.file_entry,
                    .block_index = 0,
                    .page_index = page_index,
                    .codec = compressed.codec,
                    .raw_size = @intCast(raw.len),
                    .stored_size = @intCast(compressed.bytes.len),
                    .raw_crc = hash.crc32c(raw),
                    .stored_crc = hash.crc32c(compressed.bytes),
                    .content_hash = hash.contentHash(raw),
                    .payload = compressed.bytes,
                });
                self.lock.lock();
                defer self.lock.unlock();
                fb.pages[page_index] = value;
                return .done;
            },
            .file_done => return .done,
        }
    }
};

pub fn createPack(output_path: []const u8, files: []const BuildFileInput, options: PackBuildOptions) !void {
    return createPackInternal(output_path, files, options, false);
}

fn createPackInternal(output_path: []const u8, files: []const BuildFileInput, options: PackBuildOptions, fail_after_close: bool) !void {
    const allocator = std.heap.smp_allocator;
    var publish = try publication.Publication.init(allocator, output_path);
    defer publish.deinit();
    try publish.begin();
    errdefer publish.cancel() catch {};
    var file_entries = std.AutoHashMap(u64, void).init(allocator);
    defer file_entries.deinit();
    var paths = std.StringHashMap(void).init(allocator);
    defer paths.deinit();

    var builds = try allocator.alloc(FileBuild, files.len);
    var builds_init: usize = 0;
    defer {
        for (builds[0..builds_init]) |*fb| {
            allocator.free(fb.normalized_path);
            allocator.free(fb.data);
            for (fb.pages) |p| if (p) |v| allocator.free(v);
            allocator.free(fb.pages);
        }
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

    // Phase 1: read + encode every page through the task graph.
    var graph = task.Graph.init(allocator);
    defer graph.deinit();
    for (builds, 0..) |fb, i| {
        _ = fb;
        _ = try graph.addTask(.{ .kind = @intFromEnum(BuildKind.read_source), .need = .{ .io_read = 1 }, .label_file_entry = @intCast(i), .priority = 20 });
    }
    var ctx = BuildContext{ .allocator = allocator, .files = builds };
    var sched = try task.Scheduler.init(allocator, options.budget);
    defer sched.deinit();
    var report = try sched.run(&graph, .{ .context = &ctx, .run = BuildContext.run }, .{});
    report.deinit(allocator);

    // Build a fresh, private generation. The old output is never mutated.
    var writer = try pack_writer.PackWriter.createWithOptions(allocator, publish.stage, .{ .shards = options.shards });
    var writer_closed = false;
    errdefer if (!writer_closed) writer.abort();

    var path_entries = std.ArrayList(path_index_fmt.EntryInput).empty;
    defer path_entries.deinit(allocator);
    var pack_hash_input = std.ArrayList(u8).empty;
    defer pack_hash_input.deinit(allocator);

    for (builds) |fb| {
        var blocks = std.ArrayList(file_manifest_fmt.BlockDesc).empty;
        defer blocks.deinit(allocator);
        if (fb.data.len != 0) {
            try blocks.append(allocator, .{
                .raw_offset = 0,
                .raw_size = fb.data.len,
                .page_size = fb.input.page_size,
                .page_count = fb.page_count,
                .codec = fb.input.codec,
                .codec_level = fb.input.codec_level,
                .block_hash = fb.content_hash,
            });
        }
        for (fb.pages, 0..) |maybe_value, page_index| {
            const value = maybe_value orelse return error.Corruption;
            try writer.putPage(fb.input.file_entry, 0, @intCast(page_index), value);
        }
        const manifest_value = try file_manifest_fmt.encodeFileManifest(allocator, .{
            .file_entry = fb.input.file_entry,
            .file_version = 1,
            .file_size = fb.data.len,
            .content_hash = fb.content_hash,
            .blocks = blocks.items,
        });
        defer allocator.free(manifest_value);
        try writer.putFileManifest(fb.input.file_entry, manifest_value);
        try path_entries.append(allocator, .{ .normalized_path = fb.normalized_path, .file_entry = fb.input.file_entry });

        var key_buf = [_]u8{0} ** 8;
        @memcpy(&key_buf, &object_key.encodeDbKey(fb.input.file_entry));
        try pack_hash_input.appendSlice(allocator, &key_buf);
        try pack_hash_input.appendSlice(allocator, fb.normalized_path);
        try pack_hash_input.append(allocator, 0);
        try pack_hash_input.appendSlice(allocator, &fb.content_hash);
    }

    const path_index = try path_index_fmt.encodePathIndex(allocator, path_entries.items);
    defer allocator.free(path_index);
    try writer.putPathIndex(path_index);

    const manifest = pack_manifest_fmt.encodePackManifest(.{
        .pack_id = options.pack_id,
        .pack_version = options.pack_version,
        .build_id = options.build_id,
        .file_count = files.len,
        .tombstone_count = 0,
        .content_hash = hash.contentHash(pack_hash_input.items),
    });
    try writer.putPackManifest(&manifest);
    try writer.close();
    writer_closed = true;
    if (fail_after_close) return error.InjectedBuildFailure;
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
    var result: IncrementalBuildResult = .{};
    var cache = build_cache_mod.load(allocator, plan.pack_path) catch |e| switch (e) {
        error.FileNotFound, error.Corruption => blk: {
            result.cache_rebuilt = true;
            break :blk null;
        },
        else => |err| return err,
    };
    defer if (cache) |*c| c.deinit(allocator);

    var changed: u32 = 0;
    if (cache) |c| {
        for (plan.files) |file| {
            const entry = c.findBySource(file.source_path);
            if (entry == null or !build_cache_mod.matchesPlan(entry.?, file)) changed += 1;
        }
    } else {
        changed = @intCast(plan.files.len);
    }

    if (changed == 0 and try packExists(plan.pack_path) and try packIdentityMatches(plan)) {
        result.skipped_files = @intCast(plan.files.len);
        return result;
    }

    var inputs = std.ArrayList(BuildFileInput).empty;
    defer inputs.deinit(allocator);
    var estimated_tasks: u32 = 0;
    for (plan.files) |file| {
        try inputs.append(allocator, .{
            .source_path = file.source_path,
            .virtual_path = file.virtual_path,
            .file_entry = file.file_entry,
            .page_size = file.page_size,
            .codec = file.codec,
            .codec_level = file.codec_level,
        });
        estimated_tasks += 2 + file.estimated_page_count;
    }
    try createPack(plan.pack_path, inputs.items, .{ .pack_id = plan.pack_id, .pack_version = plan.pack_version, .build_id = plan.pack_version, .shards = plan.shards });
    result.scheduled_tasks = estimated_tasks;
    result.rebuilt_files = @intCast(plan.files.len);
    result.wrote_pack = true;

    // The pack is already committed. Cache failure may cost a later rebuild,
    // but must not misreport successful publication as a failed build.
    writeBuildCache(plan, allocator) catch {
        result.cache_write_failed = true;
    };
    return result;
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

fn readFileAlloc(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    var f = try pf.open(path, .{ .mode = .read_only });
    defer pf.close(&f);
    const size = try pf.len(f);
    const buf = try allocator.alloc(u8, size);
    errdefer allocator.free(buf);
    if (try pf.preadAll(f, 0, buf) != buf.len) return error.Corruption;
    return buf;
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
