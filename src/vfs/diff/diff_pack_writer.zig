//! Serializes an engine result into a DiffPack directory (a single-shard
//! libdb store). Payloads are packed into fixed-size chunks per shard hint
//! (docs/vfs/diff_patch.md §7).
const std = @import("std");
const db_internal = @import("db_internal");
const kv = db_internal.kv_db;
const batch_mod = db_internal.batch_snapshot;
const pack_scan = @import("pack_scan.zig");
const planner = @import("diff_planner.zig");
const engine = @import("diff_engine.zig");
const diff_pack = @import("../format/diff_pack.zig");
const object_key = @import("../object_key.zig");
const hash = @import("../hash.zig");
const hdiff = @import("../hdiff/root.zig");

pub const TOOL_VERSION_HASH: u64 = 0x7666735f64696631; // "vfs_dif1"
/// Chunks for file-op payloads carry this shard marker.
pub const FILE_OP_SHARD: u32 = std.math.maxInt(u32);

pub const WriteOptions = struct {
    chunk_nominal_bytes: u32 = 8 << 20,
    hdiff_options_hash: u64 = 0,
};

pub const WriteReport = struct {
    unit_count: u64 = 0,
    chunk_count: u32 = 0,
    payload_bytes: u64 = 0,
    file_op_count: u64 = 0,
};

const ChunkBuilder = struct {
    allocator: std.mem.Allocator,
    db: *kv.KvDb,
    nominal: u32,
    next_chunk_id: u32 = 0,
    cur_shard: u32 = 0,
    buf: std.ArrayList(u8) = .empty,
    report: *WriteReport,

    fn deinit(self: *ChunkBuilder) void {
        self.buf.deinit(self.allocator);
    }

    fn place(self: *ChunkBuilder, shard: u32, payload: []const u8) !diff_pack.PayloadRef {
        if (payload.len == 0) return diff_pack.PayloadRef.none;
        if (self.buf.items.len != 0 and (shard != self.cur_shard or self.buf.items.len + payload.len > self.nominal)) try self.flush();
        self.cur_shard = shard;
        const aligned = std.mem.alignForward(usize, self.buf.items.len, diff_pack.CHUNK_ALIGN);
        try self.buf.appendNTimes(self.allocator, 0, aligned - self.buf.items.len);
        const offset = self.buf.items.len;
        try self.buf.appendSlice(self.allocator, payload);
        self.report.payload_bytes += payload.len;
        return .{ .chunk_id = self.next_chunk_id, .offset = @intCast(offset), .len = @intCast(payload.len) };
    }

    fn flush(self: *ChunkBuilder) !void {
        if (self.buf.items.len == 0) return;
        const encoded = try diff_pack.encodeChunk(self.allocator, self.next_chunk_id, self.cur_shard, self.buf.items);
        defer self.allocator.free(encoded);
        try putObject(self.db, object_key.diffChunkKey(self.next_chunk_id), encoded);
        try self.db.commitPending(.none);
        self.next_chunk_id += 1;
        self.report.chunk_count += 1;
        self.buf.clearRetainingCapacity();
    }
};

fn putObject(db: *kv.KvDb, key: u64, value: []const u8) !void {
    const kb = object_key.encodeDbKey(key);
    try db.putBytes(&kb, value, .{ .durability = .none });
}

pub fn write(
    allocator: std.mem.Allocator,
    out_path: []const u8,
    base: *const pack_scan.PackImage,
    target: *const pack_scan.PackImage,
    plan: *const planner.Plan,
    result: *engine.Result,
    hdiff_options: hdiff.DiffOptions,
    options: WriteOptions,
) !WriteReport {
    if (base.manifest.pack_id != target.manifest.pack_id) return error.InvalidArgument;
    var report: WriteReport = .{};
    var db = try kv.KvDb.open(out_path, .{ .data_file_count = 1, .durability = .none });
    var closed = false;
    errdefer if (!closed) db.close() catch {};

    var chunks = ChunkBuilder{ .allocator = allocator, .db = &db, .nominal = options.chunk_nominal_bytes, .report = &report };
    defer chunks.deinit();

    // Units: per shard hint, in engine order (already sorted by shard).
    var descs = try allocator.alloc(diff_pack.UnitDesc, result.units.items.len);
    defer allocator.free(descs);
    for (result.units.items, 0..) |u, i| {
        descs[i] = u.desc;
        descs[i].payload = try chunks.place(u.shard_hint, u.payload);
    }
    try chunks.flush();
    var shard: u32 = 0;
    while (shard < plan.shard_hint_count) : (shard += 1) {
        var start: usize = 0;
        while (start < result.units.items.len and result.units.items[start].shard_hint < shard) start += 1;
        var end = start;
        while (end < result.units.items.len and result.units.items[end].shard_hint == shard) end += 1;
        const table = try diff_pack.encodeUnits(allocator, shard, descs[start..end]);
        defer allocator.free(table);
        try putObject(&db, object_key.diffUnitTableKey(shard), table);
        report.unit_count += end - start;
    }

    // File ops.
    var ops = try allocator.alloc(diff_pack.FileOp, plan.file_ops.items.len);
    defer allocator.free(ops);
    for (plan.file_ops.items, 0..) |fo, i| {
        ops[i] = fo.op;
        ops[i].payload = try chunks.place(FILE_OP_SHARD, fo.payload);
    }
    try chunks.flush();
    const op_table = try diff_pack.encodeFileOps(allocator, ops);
    defer allocator.free(op_table);
    try putObject(&db, object_key.diffFileOpTableKey(), op_table);
    report.file_op_count = ops.len;

    // Path delta.
    var flags: u32 = 0;
    if (plan.path_adds.items.len != 0 or plan.path_removes.items.len != 0) {
        flags |= diff_pack.MANIFEST_FLAG_HAS_PATH_DELTA;
        const pd = try diff_pack.encodePathDelta(allocator, .{ .adds = plan.path_adds.items, .removes = plan.path_removes.items });
        defer allocator.free(pd);
        try putObject(&db, object_key.diffPathDeltaKey(), pd);
    }
    if (target.directory_manifest_bytes != null) flags |= diff_pack.MANIFEST_FLAG_HAS_DIRECTORY_MANIFEST;

    const manifest = diff_pack.DiffManifest{
        .diff_id = diffId(base, target),
        .target_pack_id = target.manifest.pack_id,
        .base_pack_version = base.manifest.pack_version,
        .target_pack_version = target.manifest.pack_version,
        .target_build_id = target.manifest.build_id,
        .flags = flags,
        .shard_hint_count = plan.shard_hint_count,
        .unit_count = report.unit_count,
        .chunk_count = report.chunk_count,
        .chunk_nominal_bytes = options.chunk_nominal_bytes,
        .file_op_count = report.file_op_count,
        .target_file_count = target.manifest.file_count,
        .target_tombstone_count = target.manifest.tombstone_count,
        .base_content_hash = base.manifest.content_hash,
        .target_content_hash = target.manifest.content_hash,
        .payload_total_bytes = report.payload_bytes,
        .tool_version_hash = TOOL_VERSION_HASH,
        .hdiff_options_hash = if (options.hdiff_options_hash != 0) options.hdiff_options_hash else hdiff_options.hash(),
    };
    try putObject(&db, object_key.diffManifestKey(), &diff_pack.encodeManifest(manifest));
    try db.commitPending(.sync);
    try db.close();
    closed = true;
    return report;
}

pub fn diffId(base: *const pack_scan.PackImage, target: *const pack_scan.PackImage) u64 {
    var h = hash.Hasher64{};
    h.update("vfs.diff.id.v1");
    h.updateU64Le(target.manifest.pack_id);
    h.updateU64Le(base.manifest.pack_version);
    h.updateU64Le(target.manifest.pack_version);
    h.update(&base.manifest.content_hash);
    h.update(&target.manifest.content_hash);
    return h.final();
}

pub const CreateOptions = struct {
    plan: planner.PlanOptions = .{},
    engine: engine.EngineOptions = .{},
    write: WriteOptions = .{},
};

pub const CreateReport = struct {
    write: WriteReport,
    downgraded_ratio: u32,
    unchanged_files: u32,
    planned_units: usize,
};

/// One-shot: scan both packs, plan, encode, write.
pub fn createDiffPack(allocator: std.mem.Allocator, base_path: []const u8, target_path: []const u8, out_path: []const u8, options: CreateOptions) !CreateReport {
    var base = try pack_scan.PackImage.load(allocator, base_path);
    defer base.deinit();
    var target = try pack_scan.PackImage.load(allocator, target_path);
    defer target.deinit();
    if (base.manifest.pack_id != target.manifest.pack_id) return error.InvalidArgument;
    if (base.manifest.pack_version == target.manifest.pack_version) return error.InvalidArgument;
    var plan = try planner.create(allocator, &base, &target, options.plan);
    defer plan.deinit();
    var result = try engine.run(allocator, &base, &target, &plan, options.engine);
    defer result.deinit();
    const w = try write(allocator, out_path, &base, &target, &plan, &result, options.engine.hdiff, options.write);
    return .{ .write = w, .downgraded_ratio = result.downgraded_ratio, .unchanged_files = plan.unchanged_files, .planned_units = plan.units.items.len };
}
