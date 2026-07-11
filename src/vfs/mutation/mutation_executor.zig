const std = @import("std");
const db_internal = @import("db_internal");
const kv = db_internal.kv_db;
const volume_mod = @import("../volume/volume.zig");
const pack_reader = @import("../pack/pack_reader.zig");
const pack_writer = @import("../pack/pack_writer.zig");
const mutation_plan = @import("mutation_plan.zig");
const pack_tools = @import("../tools/pack_tools.zig");
const hash = @import("../hash.zig");
const task_graph = @import("task_graph.zig");
const scheduler = @import("scheduler.zig");
const resource_budget = @import("resource_budget.zig");
const file_manifest_fmt = @import("../format/file_manifest.zig");
const page_value_fmt = @import("../format/page_value.zig");
const pack_manifest_fmt = @import("../format/pack_manifest.zig");
const path_index_fmt = @import("../format/path_index.zig");
const tombstone_fmt = @import("../format/tombstone.zig");
const path_mod = @import("../path.zig");
const object_key = @import("../object_key.zig");

pub const MUTATION_PAGE_SIZE: u32 = 64 * 1024;

pub const ExecuteResult = struct {
    applied_files: u32 = 0,
    verified: bool = false,
    scheduled_tasks: u32 = 0,
};

pub fn execute(allocator: std.mem.Allocator, plan: mutation_plan.PackMutationPlan) !ExecuteResult {
    var reader = try pack_reader.PackReader.open(allocator, plan.target_pack_path);
    defer reader.close(allocator);
    if (reader.manifest.pack_id != plan.target_pack_id or reader.manifest.pack_version != plan.base_pack_version) return error.InvalidArgument;

    for (plan.files) |file| {
        if (!mutation_plan.payloadHashOk(file)) return error.ChecksumMismatch;
        switch (file.op) {
            .add_file => if (file.old_file_size != 0) return error.InvalidArgument,
            .modify_file, .delete_file => {
                const old = try readEntryAlloc(allocator, plan.target_pack_path, file.file_entry);
                defer allocator.free(old);
                if (old.len != file.old_file_size) return error.InvalidArgument;
                if (!std.mem.eql(u8, &hash.contentHash(old), &file.old_content_hash)) return error.ChecksumMismatch;
            },
        }
    }

    var writer = try pack_writer.PackWriter.create(allocator, plan.target_pack_path);
    var writer_open = true;
    errdefer if (writer_open) writer.abort();

    var graph = try buildTaskGraph(allocator, plan);
    defer graph.deinit(allocator);
    var context = try MutationTaskExecutor.init(allocator, &plan, &reader, &writer);
    defer context.deinit();
    var schedule_report = scheduler.runWithExecutor(allocator, &graph, .{}, .{}, .{ .context = &context, .runTask = MutationTaskExecutor.runTask }) catch |err| {
        writer_open = !context.writer_closed;
        if (writer_open) {
            writer.abort();
            writer_open = false;
        }
        return err;
    };
    defer schedule_report.deinit(allocator);
    writer_open = !context.writer_closed;
    if (!context.writer_closed) {
        try writer.close();
        writer_open = false;
    }
    return .{ .applied_files = context.applied_files, .verified = context.verified, .scheduled_tasks = @intCast(schedule_report.dispatch_order.items.len) };
}

const MutationTaskExecutor = struct {
    const FileState = struct {
        file_entry: u64,
        op: mutation_plan.MutationOp,
        page_refs: []file_manifest_fmt.PageRef = &.{},
        existed: bool = false,

        fn deinit(self: *FileState, allocator: std.mem.Allocator) void {
            allocator.free(self.page_refs);
            self.* = undefined;
        }
    };

    allocator: std.mem.Allocator,
    plan: *const mutation_plan.PackMutationPlan,
    reader: *pack_reader.PackReader,
    writer: *pack_writer.PackWriter,
    states: []FileState,
    target_generation: u64,
    writer_closed: bool = false,
    applied_files: u32 = 0,
    verified: bool = false,

    fn init(allocator: std.mem.Allocator, plan: *const mutation_plan.PackMutationPlan, reader: *pack_reader.PackReader, writer: *pack_writer.PackWriter) !MutationTaskExecutor {
        const states = try allocator.alloc(FileState, plan.files.len);
        errdefer allocator.free(states);
        for (states, 0..) |*state, i| {
            state.* = .{
                .file_entry = plan.files[i].file_entry,
                .op = plan.files[i].op,
                .existed = fileManifestExists(reader, plan.files[i].file_entry) catch |err| return err,
            };
            if (plan.files[i].op != .delete_file) {
                state.page_refs = try allocator.alloc(file_manifest_fmt.PageRef, pageCount(plan.files[i].payload.len));
            }
        }
        return .{
            .allocator = allocator,
            .plan = plan,
            .reader = reader,
            .writer = writer,
            .states = states,
            .target_generation = plan.patch_version,
        };
    }

    fn deinit(self: *MutationTaskExecutor) void {
        for (self.states) |*state| state.deinit(self.allocator);
        self.allocator.free(self.states);
        self.* = undefined;
    }

    fn runTask(ctx: *anyopaque, task: task_graph.Task) !void {
        const self: *MutationTaskExecutor = @ptrCast(@alignCast(ctx));
        switch (task.task_type) {
            .read_source => {
                const file = self.findFile(task.file_entry) orelse return error.InvalidArgument;
                if (file.op != .delete_file and pagePayload(file.*, task.page_index) == null) return error.InvalidArgument;
            },
            .hash_page => {
                const file = self.findFile(task.file_entry) orelse return error.InvalidArgument;
                const payload = pagePayload(file.*, task.page_index) orelse return error.InvalidArgument;
                _ = hash.contentHash(payload);
            },
            .compress_page => {
                // V1 mutation pages are stored with the none codec. This task is still real
                // page-granularity work and is the extension point for codec-enabled patches.
            },
            .write_page_kv => {
                try self.writePage(task.file_entry, task.page_index);
            },
            .write_file_manifest => {
                try self.writeFileManifest(task.file_entry);
                self.applied_files += 1;
            },
            .write_entry_tombstone => {
                const file = self.findFile(task.file_entry) orelse return error.InvalidArgument;
                if (file.op != .delete_file) return error.InvalidArgument;
                const tombstone = try tombstone_fmt.encodeEntryTombstone(.{ .file_entry = file.file_entry, .tombstone_version = self.target_generation, .reason_flags = 1 });
                try self.writer.putEntryTombstone(file.file_entry, &tombstone);
                self.applied_files += 1;
            },
            .update_path_index => try self.updatePathIndex(),
            .update_pack_manifest => try self.updatePackManifest(),
            .verify_pack => {
                if (self.plan.verify_after_apply) {
                    var report = try pack_tools.verifyPack(self.plan.target_pack_path, self.allocator);
                    defer report.deinit(self.allocator);
                    if (!report.ok()) return error.Corruption;
                    self.verified = true;
                }
            },
            .flush_pack => {
                try self.writer.close();
                self.writer_closed = true;
                try optimizePack(self.plan.target_pack_path);
            },
        }
    }

    fn findFile(self: *MutationTaskExecutor, file_entry: u64) ?*const mutation_plan.FileMutation {
        for (self.plan.files) |*file| if (file.file_entry == file_entry) return file;
        return null;
    }

    fn findState(self: *MutationTaskExecutor, file_entry: u64) ?*FileState {
        for (self.states) |*state| if (state.file_entry == file_entry) return state;
        return null;
    }

    fn writePage(self: *MutationTaskExecutor, file_entry: u64, page_index: u32) !void {
        const file = self.findFile(file_entry) orelse return error.InvalidArgument;
        const state = self.findState(file_entry) orelse return error.InvalidArgument;
        const payload = pagePayload(file.*, page_index) orelse return error.InvalidArgument;
        const payload_hash = hash.contentHash(payload);
        const payload_crc = hash.crc32c(payload);
        if (try self.reusablePageRef(file.*, page_index, payload, payload_hash, payload_crc)) |ref| {
            state.page_refs[page_index] = ref;
            return;
        }
        const page_value = try page_value_fmt.encodePageValue(self.allocator, .{
            .file_entry = file_entry,
            .block_index = 0,
            .page_index = page_index,
            .raw_size = @intCast(payload.len),
            .stored_size = @intCast(payload.len),
            .content_hash = payload_hash,
            .payload = payload,
        });
        defer self.allocator.free(page_value);
        try self.writer.putPage(file_entry, 0, page_index, page_value);
        state.page_refs[page_index] = .{
            .pack_id = @intCast(self.plan.target_pack_id),
            .pack_generation = self.target_generation,
            .file_entry = file_entry,
            .block_index = 0,
            .page_index = page_index,
            .page_key = try object_key.pageKey(file_entry, 0, page_index),
            .raw_hash = payload_hash,
            .content_hash = payload_hash,
            .raw_crc = payload_crc,
        };
    }

    fn writeFileManifest(self: *MutationTaskExecutor, file_entry: u64) !void {
        const file = self.findFile(file_entry) orelse return error.InvalidArgument;
        const state = self.findState(file_entry) orelse return error.InvalidArgument;
        if (file.op == .delete_file) return error.InvalidArgument;
        const blocks = if (file.payload.len == 0) &[_]file_manifest_fmt.BlockDesc{} else &[_]file_manifest_fmt.BlockDesc{.{
            .raw_offset = 0,
            .raw_size = file.payload.len,
            .page_size = MUTATION_PAGE_SIZE,
            .page_count = @intCast(state.page_refs.len),
            .codec = .none,
            .block_hash = hash.contentHash(file.payload),
            .flags = file_manifest_fmt.BLOCK_FLAG_EXPLICIT_PAGE_REFS,
            .page_ref_offset = 0,
        }};
        const encoded = try file_manifest_fmt.encodeFileManifest(self.allocator, .{
            .file_entry = file_entry,
            .file_version = self.target_generation,
            .file_size = file.payload.len,
            .content_hash = hash.contentHash(file.payload),
            .blocks = blocks,
            .page_refs = state.page_refs,
        });
        defer self.allocator.free(encoded);
        try self.writer.putFileManifest(file_entry, encoded);
    }

    fn updatePathIndex(self: *MutationTaskExecutor) !void {
        const existing = try path_index_fmt.collectEntries(self.allocator, self.reader.path_index);
        defer path_index_fmt.freeDecodedEntries(self.allocator, existing);
        var inputs = std.ArrayList(path_index_fmt.EntryInput).empty;
        defer inputs.deinit(self.allocator);
        var owned_paths = std.ArrayList([]u8).empty;
        defer {
            for (owned_paths.items) |p| self.allocator.free(p);
            owned_paths.deinit(self.allocator);
        }
        for (existing) |entry| {
            if (self.deletedEntry(entry.file_entry)) continue;
            if (try self.replacementForPath(entry.normalized_path)) |replacement| {
                try inputs.append(self.allocator, replacement);
            } else {
                try inputs.append(self.allocator, .{ .normalized_path = entry.normalized_path, .file_entry = entry.file_entry, .flags = entry.flags });
            }
        }
        for (self.plan.files) |file| {
            if (file.op == .delete_file) continue;
            const path = file.virtual_path orelse continue;
            const normalized = try path_mod.normalizeVirtualPath(self.allocator, path);
            errdefer self.allocator.free(normalized);
            var found = false;
            for (inputs.items) |input| {
                if (std.mem.eql(u8, input.normalized_path, normalized)) {
                    found = true;
                    break;
                }
            }
            if (!found) try inputs.append(self.allocator, .{ .normalized_path = normalized, .file_entry = file.file_entry });
            if (!found) {
                try owned_paths.append(self.allocator, normalized);
            } else {
                self.allocator.free(normalized);
            }
        }
        const encoded = try path_index_fmt.encodePathIndex(self.allocator, inputs.items);
        defer self.allocator.free(encoded);
        try self.writer.putPathIndex(encoded);
    }

    fn updatePackManifest(self: *MutationTaskExecutor) !void {
        var file_count = self.reader.manifest.file_count;
        var tombstone_count = self.reader.manifest.tombstone_count;
        for (self.states) |state| switch (state.op) {
            .add_file, .modify_file => {
                if (!state.existed) file_count += 1;
            },
            .delete_file => {
                tombstone_count += 1;
            },
        };
        const manifest = pack_manifest_fmt.encodePackManifest(.{
            .pack_id = self.plan.target_pack_id,
            .flags = self.reader.manifest.flags,
            .pack_version = self.target_generation,
            .build_id = self.reader.manifest.build_id + 1,
            .file_count = file_count,
            .tombstone_count = tombstone_count,
            .content_hash = self.packContentHash(),
        });
        try self.writer.putPackManifest(&manifest);
    }

    fn replacementForPath(self: *MutationTaskExecutor, normalized_path: []const u8) !?path_index_fmt.EntryInput {
        for (self.plan.files) |file| {
            if (file.op == .delete_file) continue;
            const path = file.virtual_path orelse continue;
            const normalized = try path_mod.normalizeVirtualPath(self.allocator, path);
            defer self.allocator.free(normalized);
            if (std.mem.eql(u8, normalized_path, normalized)) return .{ .normalized_path = normalized_path, .file_entry = file.file_entry };
        }
        return null;
    }

    fn deletedEntry(self: *MutationTaskExecutor, file_entry: u64) bool {
        for (self.plan.files) |file| if (file.file_entry == file_entry and file.op == .delete_file) return true;
        return false;
    }

    fn reusablePageRef(self: *MutationTaskExecutor, file: mutation_plan.FileMutation, page_index: u32, payload: []const u8, payload_hash: [32]u8, payload_crc: u32) !?file_manifest_fmt.PageRef {
        if (file.op == .add_file) return null;
        var manifest = self.reader.readFileManifest(self.allocator, file.file_entry) catch |err| switch (err) {
            error.NotFound => return null,
            else => |e| return e,
        };
        defer manifest.deinit(self.allocator);
        if (manifest.blocks.len == 0) return null;
        const block = manifest.blocks[0];
        if (page_index >= block.page_count) return null;
        const page_ref = if ((block.flags & file_manifest_fmt.BLOCK_FLAG_EXPLICIT_PAGE_REFS) != 0)
            try manifest.pageRef(block, page_index)
        else
            file_manifest_fmt.PageRef{
                .pack_id = @intCast(self.reader.manifest.pack_id),
                .pack_generation = self.reader.manifest.pack_version,
                .file_entry = file.file_entry,
                .block_index = 0,
                .page_index = page_index,
                .page_key = try object_key.pageKey(file.file_entry, 0, page_index),
            };
        if (page_ref.pack_id != self.reader.manifest.pack_id or page_ref.pack_generation != self.reader.manifest.pack_version) return null;
        const page_bytes = try self.reader.readObjectAlloc(self.allocator, page_ref.page_key);
        defer self.allocator.free(page_bytes);
        const decoded = try page_value_fmt.decodePageValue(page_bytes, .{ .file_entry = page_ref.file_entry, .block_index = page_ref.block_index, .page_index = page_ref.page_index });
        if (decoded.codec != .none) return null;
        if (!std.mem.eql(u8, decoded.payload, payload)) return null;
        if (!std.mem.eql(u8, &hash.contentHash(decoded.payload), &payload_hash) or hash.crc32c(decoded.payload) != payload_crc) return null;
        var out = page_ref;
        out.pack_generation = self.target_generation;
        out.raw_hash = payload_hash;
        out.content_hash = payload_hash;
        out.raw_crc = payload_crc;
        return out;
    }

    fn packContentHash(self: *MutationTaskExecutor) [32]u8 {
        var sha = std.crypto.hash.sha2.Sha256.init(.{});
        for (self.plan.files) |file| {
            var entry_buf: [8]u8 = undefined;
            std.mem.writeInt(u64, &entry_buf, file.file_entry, .little);
            sha.update(&entry_buf);
            sha.update(@tagName(file.op));
            if (file.op != .delete_file) sha.update(&hash.contentHash(file.payload));
        }
        var out: [32]u8 = undefined;
        sha.final(&out);
        return out;
    }
};

pub fn buildTaskGraph(allocator: std.mem.Allocator, plan: mutation_plan.PackMutationPlan) !task_graph.ResourceTaskGraph {
    var graph: task_graph.ResourceTaskGraph = .{};
    errdefer graph.deinit(allocator);
    var file_final_tasks = std.ArrayList(task_graph.TaskId).empty;
    defer file_final_tasks.deinit(allocator);
    for (plan.files) |file| {
        switch (file.op) {
            .add_file, .modify_file => {
                const write_manifest = try graph.addTask(allocator, .write_file_manifest, plan.target_pack_id, file.file_entry, .{ .db_write_tasks = 1, .pack_shared = true });
                const pages = pageCount(file.payload.len);
                var page_index: u32 = 0;
                while (page_index < pages) : (page_index += 1) {
                    const payload = pagePayload(file, page_index) orelse return error.InvalidArgument;
                    const read = try graph.addPageTask(allocator, .read_source, plan.target_pack_id, file.file_entry, page_index, .{ .disk_read_tasks = 1, .memory_bytes = payload.len, .pack_shared = true });
                    const hash_task = try graph.addPageTask(allocator, .hash_page, plan.target_pack_id, file.file_entry, page_index, .{ .hash_tasks = 1, .memory_bytes = payload.len, .pack_shared = true });
                    const compress = try graph.addPageTask(allocator, .compress_page, plan.target_pack_id, file.file_entry, page_index, .{ .compress_tasks = 1, .memory_bytes = payload.len, .pack_shared = true });
                    const write_page = try graph.addPageTask(allocator, .write_page_kv, plan.target_pack_id, file.file_entry, page_index, .{ .disk_write_tasks = 1, .db_write_tasks = 1, .memory_bytes = payload.len, .pack_shared = true });
                    try graph.addDependency(allocator, read, hash_task);
                    try graph.addDependency(allocator, hash_task, compress);
                    try graph.addDependency(allocator, compress, write_page);
                    try graph.addDependency(allocator, write_page, write_manifest);
                }
                try file_final_tasks.append(allocator, write_manifest);
            },
            .delete_file => {
                const tombstone = try graph.addTask(allocator, .write_entry_tombstone, plan.target_pack_id, file.file_entry, .{ .db_write_tasks = 1, .disk_write_tasks = 1, .pack_shared = true });
                try file_final_tasks.append(allocator, tombstone);
            },
        }
    }
    const path_index = try graph.addTask(allocator, .update_path_index, plan.target_pack_id, 0, .{ .db_write_tasks = 1, .pack_shared = true });
    for (file_final_tasks.items) |id| try graph.addDependency(allocator, id, path_index);
    const pack_manifest = try graph.addTask(allocator, .update_pack_manifest, plan.target_pack_id, 0, .{ .db_write_tasks = 1, .disk_write_tasks = 1, .pack_exclusive = true });
    const flush = try graph.addTask(allocator, .flush_pack, plan.target_pack_id, 0, .{ .disk_write_tasks = 1, .pack_exclusive = true });
    const verify = try graph.addTask(allocator, .verify_pack, plan.target_pack_id, 0, .{ .disk_read_tasks = 1, .pack_exclusive = true });
    try graph.addDependency(allocator, path_index, pack_manifest);
    try graph.addDependency(allocator, pack_manifest, flush);
    try graph.addDependency(allocator, flush, verify);
    return graph;
}

pub fn schedulePlanOnly(allocator: std.mem.Allocator, plan: mutation_plan.PackMutationPlan, budget: resource_budget.ResourceBudget) !scheduler.RunReport {
    var graph = try buildTaskGraph(allocator, plan);
    defer graph.deinit(allocator);
    return scheduler.run(allocator, &graph, budget, .{});
}

fn pageCount(len: usize) u32 {
    if (len == 0) return 0;
    return @intCast(((len - 1) / MUTATION_PAGE_SIZE) + 1);
}

fn pagePayload(file: mutation_plan.FileMutation, page_index: u32) ?[]const u8 {
    if (file.op == .delete_file) return null;
    const start = @as(usize, page_index) * @as(usize, MUTATION_PAGE_SIZE);
    if (start >= file.payload.len) return null;
    return file.payload[start..@min(file.payload.len, start + MUTATION_PAGE_SIZE)];
}

fn fileManifestExists(reader: *pack_reader.PackReader, file_entry: u64) !bool {
    var manifest = reader.readFileManifest(std.heap.smp_allocator, file_entry) catch |err| switch (err) {
        error.NotFound => return false,
        else => |e| return e,
    };
    manifest.deinit(std.heap.smp_allocator);
    return true;
}

fn optimizePack(pack_path: []const u8) !void {
    var db = try kv.KvDb.open(pack_path, .{});
    defer db.close() catch {};
    try db.optimize();
}

fn readEntryAlloc(allocator: std.mem.Allocator, pack_path: []const u8, file_entry: u64) ![]u8 {
    var v = try volume_mod.Volume.open("mutation-read", .{});
    defer v.close();
    try v.mountPackWithPriority(pack_path, 0, 0);
    var handle = try v.openEntry(1, file_entry);
    defer handle.close();
    const size = std.math.cast(usize, handle.size) orelse return error.InvalidArgument;
    const buf = try allocator.alloc(u8, size);
    errdefer allocator.free(buf);
    const n = try handle.readAt(0, buf);
    if (n != buf.len) return error.Corruption;
    return buf;
}

test "mutation executor applies add modify delete and rejects bad base" {
    const builder = @import("../build/pack_builder.zig");
    const patch_manifest = @import("../format/patch_manifest.zig");
    const merge_planner = @import("merge_planner.zig");
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    const pack_path = "zig-cache-vfs-mutation-pack";
    const src_path = "zig-cache-vfs-mutation-src.txt";
    _ = std.Io.Dir.cwd().deleteTree(io, pack_path) catch {};
    _ = std.Io.Dir.cwd().deleteFile(io, src_path) catch {};
    defer _ = std.Io.Dir.cwd().deleteTree(io, pack_path) catch {};
    defer _ = std.Io.Dir.cwd().deleteFile(io, src_path) catch {};
    try builder.writeSourceFileForTest(src_path, "old");
    try builder.createPack(pack_path, &.{.{ .source_path = src_path, .virtual_path = "/old.txt", .file_entry = 10001, .page_size = 4 }}, .{ .pack_id = 1, .pack_version = 1 });

    const old_hash = hash.contentHash("old");
    const add_hash = hash.contentHash("added");
    const mod_hash = hash.contentHash("new");
    const encoded = try patch_manifest.encode(allocator, .{ .target_pack_id = 1, .base_pack_version = 1, .patch_version = 2, .files = &.{
        .{ .file_entry = 10002, .virtual_path = "/add.txt", .op = .add_file, .new_file_size = 5, .new_content_hash = add_hash, .payload = "added" },
        .{ .file_entry = 10001, .virtual_path = "/old.txt", .op = .modify_file, .old_file_size = 3, .new_file_size = 3, .old_content_hash = old_hash, .new_content_hash = mod_hash, .payload = "new" },
    } });
    defer allocator.free(encoded);
    var patch = try patch_manifest.decode(allocator, encoded);
    defer patch.deinit(allocator);
    var plan = try merge_planner.createPlan(allocator, pack_path, patch);
    defer plan.deinit(allocator);
    const result = try execute(allocator, plan);
    try std.testing.expectEqual(@as(u32, 2), result.applied_files);
    try std.testing.expect(result.verified);
    try std.testing.expect(result.scheduled_tasks > 0);

    var v = try volume_mod.Volume.open("check", .{});
    defer v.close();
    try v.mountPackWithPriority(pack_path, 0, 0);
    var h = try v.openPath(1, "/add.txt");
    var buf: [16]u8 = undefined;
    var n = try h.readAt(0, &buf);
    h.close();
    try std.testing.expectEqualSlices(u8, "added", buf[0..n]);
    h = try v.openEntry(1, 10001);
    n = try h.readAt(0, &buf);
    h.close();
    try std.testing.expectEqualSlices(u8, "new", buf[0..n]);

    const bad_base = try patch_manifest.encode(allocator, .{ .target_pack_id = 1, .base_pack_version = 1, .patch_version = 3, .files = &.{} });
    defer allocator.free(bad_base);
    var bad_patch = try patch_manifest.decode(allocator, bad_base);
    defer bad_patch.deinit(allocator);
    var bad_plan = try merge_planner.createPlan(allocator, pack_path, bad_patch);
    defer bad_plan.deinit(allocator);
    try std.testing.expectError(error.InvalidArgument, execute(allocator, bad_plan));

    const delete_hash = hash.contentHash("new");
    const del_encoded = try patch_manifest.encode(allocator, .{ .target_pack_id = 1, .base_pack_version = 2, .patch_version = 3, .files = &.{
        .{ .file_entry = 10001, .op = .delete_file, .old_file_size = 3, .old_content_hash = delete_hash },
    } });
    defer allocator.free(del_encoded);
    var del_patch = try patch_manifest.decode(allocator, del_encoded);
    defer del_patch.deinit(allocator);
    var del_plan = try merge_planner.createPlan(allocator, pack_path, del_patch);
    defer del_plan.deinit(allocator);
    _ = try execute(allocator, del_plan);
    try std.testing.expectError(error.NotFound, v.openEntry(1, 10001));
}

test "mutation task graph emits real per-page write tasks" {
    const allocator = std.testing.allocator;
    const payload = try allocator.alloc(u8, MUTATION_PAGE_SIZE + 7);
    defer allocator.free(payload);
    @memset(payload[0..MUTATION_PAGE_SIZE], 'a');
    @memset(payload[MUTATION_PAGE_SIZE..], 'b');
    const owned_payload = try allocator.dupe(u8, payload);
    const files = try allocator.alloc(mutation_plan.FileMutation, 1);
    files[0] = .{
        .op = .add_file,
        .file_entry = 90001,
        .new_file_size = payload.len,
        .new_content_hash = hash.contentHash(payload),
        .payload = owned_payload,
        .file_manifest_key = try object_key.fileManifestKey(90001),
    };
    var plan = mutation_plan.PackMutationPlan{
        .target_pack_path = try allocator.dupe(u8, "pack"),
        .target_pack_id = 1,
        .base_pack_version = 1,
        .patch_version = 2,
        .files = files,
    };
    defer plan.deinit(allocator);

    var graph = try buildTaskGraph(allocator, plan);
    defer graph.deinit(allocator);
    var write_page_count: u32 = 0;
    for (graph.tasks.items) |task| {
        if (task.task_type == .write_page_kv) {
            write_page_count += 1;
            try std.testing.expect(task.page_index < 2);
        }
    }
    try std.testing.expectEqual(@as(u32, 2), write_page_count);
}
