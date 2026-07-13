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
const task_graph = @import("../mutation/task_graph.zig");
const scheduler = @import("../mutation/scheduler.zig");

pub const DEFAULT_PAGE_SIZE: u32 = 64 * 1024;

pub const BuildFileInput = struct {
    source_path: []const u8,
    virtual_path: []const u8,
    file_entry: u64,
    page_size: u32 = DEFAULT_PAGE_SIZE,
};

pub const PackBuildOptions = struct {
    pack_id: u64 = 1,
    pack_version: u64 = 1,
    build_id: u64 = 1,
};

pub const IncrementalBuildResult = struct {
    rebuilt_files: u32 = 0,
    skipped_files: u32 = 0,
    cache_rebuilt: bool = false,
    wrote_pack: bool = false,
    scheduled_tasks: u32 = 0,
};

const OwnedPathEntry = struct {
    path: []u8,
    input_index: usize,
};

pub fn createPack(output_path: []const u8, files: []const BuildFileInput, options: PackBuildOptions) !void {
    var writer = try pack_writer.PackWriter.create(std.heap.smp_allocator, output_path);
    var writer_closed = false;
    errdefer if (!writer_closed) writer.close() catch {};

    var file_entries = std.AutoHashMap(u64, void).init(std.heap.smp_allocator);
    defer file_entries.deinit();
    var paths = std.StringHashMap(void).init(std.heap.smp_allocator);
    defer paths.deinit();
    var owned_paths = std.ArrayList(OwnedPathEntry).empty;
    defer {
        for (owned_paths.items) |entry| std.heap.smp_allocator.free(entry.path);
        owned_paths.deinit(std.heap.smp_allocator);
    }
    var path_entries = std.ArrayList(path_index_fmt.EntryInput).empty;
    defer path_entries.deinit(std.heap.smp_allocator);

    var pack_hash_input = std.ArrayList(u8).empty;
    defer pack_hash_input.deinit(std.heap.smp_allocator);

    for (files, 0..) |input, input_index| {
        if (input.file_entry == 0 or input.page_size == 0) return error.InvalidArgument;
        if (file_entries.contains(input.file_entry)) return error.KeyCollision;
        try file_entries.put(input.file_entry, {});
        const normalized_path = try normalizeVirtualPath(std.heap.smp_allocator, input.virtual_path);
        errdefer std.heap.smp_allocator.free(normalized_path);
        if (paths.contains(normalized_path)) return error.KeyCollision;
        try paths.put(normalized_path, {});
        try owned_paths.append(std.heap.smp_allocator, .{ .path = normalized_path, .input_index = input_index });
    }

    for (owned_paths.items) |entry| {
        const input = files[entry.input_index];
        const data = try readFileAlloc(std.heap.smp_allocator, input.source_path);
        defer std.heap.smp_allocator.free(data);
        const content_hash = hash.contentHash(data);

        const page_count: u32 = if (data.len == 0) 0 else std.math.cast(u32, ((data.len - 1) / input.page_size) + 1) orelse return error.InvalidArgument;
        var blocks = std.ArrayList(file_manifest_fmt.BlockDesc).empty;
        defer blocks.deinit(std.heap.smp_allocator);
        if (data.len != 0) {
            const block_hash = content_hash;
            try blocks.append(std.heap.smp_allocator, .{
                .raw_offset = 0,
                .raw_size = data.len,
                .page_size = input.page_size,
                .page_count = page_count,
                .codec = .none,
                .block_hash = block_hash,
            });
        }

        var page_index: u32 = 0;
        while (page_index < page_count) : (page_index += 1) {
            const start: usize = @as(usize, page_index) * @as(usize, input.page_size);
            const end = @min(data.len, start + input.page_size);
            const payload = data[start..end];
            const page_value = try page_value_fmt.encodePageValue(std.heap.smp_allocator, .{
                .file_entry = input.file_entry,
                .block_index = 0,
                .page_index = page_index,
                .codec = .none,
                .raw_size = @intCast(payload.len),
                .stored_size = @intCast(payload.len),
                .content_hash = hash.contentHash(payload),
                .payload = payload,
            });
            defer std.heap.smp_allocator.free(page_value);
            try writer.putPage(input.file_entry, 0, page_index, page_value);
        }

        const manifest_value = try file_manifest_fmt.encodeFileManifest(std.heap.smp_allocator, .{
            .file_entry = input.file_entry,
            .file_version = 1,
            .file_size = data.len,
            .content_hash = content_hash,
            .blocks = blocks.items,
        });
        defer std.heap.smp_allocator.free(manifest_value);
        try writer.putFileManifest(input.file_entry, manifest_value);
        try path_entries.append(std.heap.smp_allocator, .{ .normalized_path = entry.path, .file_entry = input.file_entry });

        var key_buf = [_]u8{0} ** 8;
        @memcpy(&key_buf, &object_key.encodeDbKey(input.file_entry));
        try pack_hash_input.appendSlice(std.heap.smp_allocator, &key_buf);
        try pack_hash_input.appendSlice(std.heap.smp_allocator, entry.path);
        try pack_hash_input.append(std.heap.smp_allocator, 0);
        try pack_hash_input.appendSlice(std.heap.smp_allocator, &content_hash);
    }

    const path_index = try path_index_fmt.encodePathIndex(std.heap.smp_allocator, path_entries.items);
    defer std.heap.smp_allocator.free(path_index);
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

    if (changed == 0 and try packExists(plan.pack_path)) {
        result.skipped_files = @intCast(plan.files.len);
        return result;
    }

    var graph = try buildTaskGraphForPlan(allocator, plan);
    defer graph.deinit(allocator);
    var exec_context: BuildTaskExecutor = .{ .allocator = allocator, .plan = &plan };
    var schedule_report = try scheduler.runWithExecutor(allocator, &graph, .{}, .{}, .{ .context = &exec_context, .runTask = BuildTaskExecutor.runTask });
    defer schedule_report.deinit(allocator);
    result.scheduled_tasks = @intCast(schedule_report.dispatch_order.items.len);
    if (!exec_context.wrote_pack) return error.Corruption;
    result.rebuilt_files = @intCast(plan.files.len);
    result.wrote_pack = true;

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
    return result;
}

const BuildTaskExecutor = struct {
    allocator: std.mem.Allocator,
    plan: *const build_plan_mod.BuildPlan,
    wrote_pack: bool = false,
    verified: bool = false,

    fn runTask(ctx: *anyopaque, task: task_graph.Task) !void {
        const self: *BuildTaskExecutor = @ptrCast(@alignCast(ctx));
        switch (task.task_type) {
            .read_source => {
                const file = self.findFile(task.file_entry) orelse return error.InvalidArgument;
                if (file.source_size == 0 and file.estimated_page_count != 0) return error.Corruption;
            },
            .hash_page => {
                _ = self.findFile(task.file_entry) orelse return error.InvalidArgument;
            },
            .compress_page => {
                const file = self.findFile(task.file_entry) orelse return error.InvalidArgument;
                if (file.codec != .none) return error.UnsupportedFeature;
            },
            .write_page_kv, .write_file_manifest, .update_path_index => {
                // The current pack writer publishes pages, manifests, and path index together at UpdatePackManifest.
            },
            .update_pack_manifest => {
                if (self.wrote_pack) return;
                var inputs = std.ArrayList(BuildFileInput).empty;
                defer inputs.deinit(self.allocator);
                for (self.plan.files) |file| {
                    if (file.codec != .none) return error.UnsupportedFeature;
                    try inputs.append(self.allocator, .{
                        .source_path = file.source_path,
                        .virtual_path = file.virtual_path,
                        .file_entry = file.file_entry,
                        .page_size = file.page_size,
                    });
                }
                const io = std.Io.Threaded.global_single_threaded.io();
                _ = std.Io.Dir.cwd().deleteTree(io, self.plan.pack_path) catch {};
                try createPack(self.plan.pack_path, inputs.items, .{ .pack_id = self.plan.pack_id });
                self.wrote_pack = true;
            },
            .verify_pack => {
                if (!self.wrote_pack) return error.Corruption;
                try verifyPackDb(self.plan.pack_path, self.allocator);
                self.verified = true;
            },
            .flush_pack => {
                if (!self.wrote_pack) return error.Corruption;
            },
            .write_entry_tombstone => return error.InvalidArgument,
        }
    }

    fn findFile(self: *BuildTaskExecutor, file_entry: u64) ?*const build_plan_mod.PlanFile {
        for (self.plan.files) |*file| if (file.file_entry == file_entry) return file;
        return null;
    }
};

pub fn buildTaskGraphForPlan(allocator: std.mem.Allocator, plan: build_plan_mod.BuildPlan) !task_graph.ResourceTaskGraph {
    var graph: task_graph.ResourceTaskGraph = .{};
    errdefer graph.deinit(allocator);
    var file_manifest_tasks = std.ArrayList(task_graph.TaskId).empty;
    defer file_manifest_tasks.deinit(allocator);
    for (plan.files) |file| {
        var page_final_tasks = std.ArrayList(task_graph.TaskId).empty;
        defer page_final_tasks.deinit(allocator);
        var page_index: u32 = 0;
        const page_count = file.estimated_page_count;
        while (page_index < page_count) : (page_index += 1) {
            const page_memory = @as(u64, file.page_size);
            const read = try graph.addTask(allocator, .read_source, plan.pack_id, file.file_entry, .{ .disk_read_tasks = 1, .memory_bytes = page_memory, .pack_shared = true });
            const hash_task = try graph.addTask(allocator, .hash_page, plan.pack_id, file.file_entry, .{ .hash_tasks = 1, .memory_bytes = page_memory, .pack_shared = true });
            const compress = try graph.addTask(allocator, .compress_page, plan.pack_id, file.file_entry, .{ .compress_tasks = 1, .memory_bytes = page_memory, .pack_shared = true });
            const write = try graph.addTask(allocator, .write_page_kv, plan.pack_id, file.file_entry, .{ .disk_write_tasks = 1, .db_write_tasks = 1, .memory_bytes = page_memory, .pack_shared = true });
            try graph.addDependency(allocator, read, hash_task);
            try graph.addDependency(allocator, hash_task, compress);
            try graph.addDependency(allocator, compress, write);
            try page_final_tasks.append(allocator, write);
        }
        const manifest = try graph.addTask(allocator, .write_file_manifest, plan.pack_id, file.file_entry, .{ .db_write_tasks = 1, .pack_shared = true });
        for (page_final_tasks.items) |id| try graph.addDependency(allocator, id, manifest);
        try file_manifest_tasks.append(allocator, manifest);
    }
    const path_index = try graph.addTask(allocator, .update_path_index, plan.pack_id, 0, .{ .db_write_tasks = 1, .pack_shared = true });
    for (file_manifest_tasks.items) |id| try graph.addDependency(allocator, id, path_index);
    const pack_manifest = try graph.addTask(allocator, .update_pack_manifest, plan.pack_id, 0, .{ .db_write_tasks = 1, .disk_write_tasks = 1, .pack_exclusive = true });
    const flush = try graph.addTask(allocator, .flush_pack, plan.pack_id, 0, .{ .disk_write_tasks = 1, .pack_exclusive = true });
    const verify = try graph.addTask(allocator, .verify_pack, plan.pack_id, 0, .{ .disk_read_tasks = 1, .pack_exclusive = true });
    try graph.addDependency(allocator, path_index, pack_manifest);
    try graph.addDependency(allocator, pack_manifest, flush);
    try graph.addDependency(allocator, flush, verify);
    return graph;
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
