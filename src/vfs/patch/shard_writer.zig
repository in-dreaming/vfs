//! Per-shard staging of puts/deletes with watermark-driven Batch commits
//! (docs/vfs/diff_patch.md §9.2). Apply tasks stage without holding any DB
//! lock; the task that crosses the watermark performs the commit for its
//! shard, so commits on different shards run in parallel and a shard's own
//! commits never overlap.
//!
//! All ops of one apply unit are staged together into the unit's file shard
//! (`object_key.fileShard`), so a unit is either fully committed or not at
//! all — the property the idempotent re-run relies on.
const std = @import("std");
const db_internal = @import("db_internal");
const kv = db_internal.kv_db;
const batch_mod = db_internal.batch_snapshot;
const fmt_db = db_internal.format;
const sync = db_internal.platform.sync;
const object_key = @import("../object_key.zig");

pub const StagedOp = struct {
    key: u64,
    /// null = delete
    value: ?[]u8,
};

pub const Options = struct {
    batch_bytes: u64 = 16 << 20,
    batch_ops: u32 = 2048,
    /// Every Nth batch of a shard is committed `.async`, others `.none`.
    flush_every_n_batches: u16 = 4,
    intermediate_durability: fmt_db.Durability = .none,
    /// Staged bytes across all shards above which `stage` asks the caller to
    /// yield while a commit is in flight.
    max_staged_bytes: u64 = 256 << 20,
};

pub const Stats = struct {
    puts: u64 = 0,
    deletes: u64 = 0,
    bytes: u64 = 0,
    batches: u64 = 0,
    yields: u64 = 0,
};

const Shard = struct {
    lock: sync.Mutex = .{},
    ops: std.ArrayList(StagedOp) = .empty,
    bytes: u64 = 0,
    committing: bool = false,
    batches: u32 = 0,
};

pub const StageResult = enum { staged, would_block };

pub const ShardWriter = struct {
    allocator: std.mem.Allocator,
    db: *kv.KvDb,
    options: Options,
    shards: []Shard,
    total_staged: std.atomic.Value(u64) = .init(0),
    stats_lock: sync.Mutex = .{},
    stats: Stats = .{},

    pub fn init(allocator: std.mem.Allocator, db: *kv.KvDb, options: Options) !ShardWriter {
        const shards = try allocator.alloc(Shard, db.shardCount());
        for (shards) |*s| s.* = .{};
        return .{ .allocator = allocator, .db = db, .options = options, .shards = shards };
    }

    pub fn deinit(self: *ShardWriter) void {
        for (self.shards) |*s| {
            for (s.ops.items) |op| if (op.value) |v| self.allocator.free(v);
            s.ops.deinit(self.allocator);
        }
        self.allocator.free(self.shards);
        self.* = undefined;
    }

    pub fn shardOfFile(self: *const ShardWriter, file_entry: u64) u32 {
        return object_key.fileShard(file_entry, @intCast(self.shards.len));
    }

    fn opBytes(op: StagedOp) u64 {
        return if (op.value) |v| v.len + 64 else 64;
    }

    /// Stages every op of a unit into shard `si` atomically. On `.staged`
    /// ownership of the values moves to the writer; on `.would_block`
    /// nothing is consumed and the caller should yield and retry.
    pub fn stageAll(self: *ShardWriter, si: u32, ops: []const StagedOp) !StageResult {
        if (ops.len == 0) return .staged;
        const shard = &self.shards[si];
        var add: u64 = 0;
        for (ops) |op| add += opBytes(op);
        shard.lock.lock();
        if (shard.committing and self.total_staged.load(.acquire) + add > self.options.max_staged_bytes) {
            shard.lock.unlock();
            self.stats_lock.lock();
            self.stats.yields += 1;
            self.stats_lock.unlock();
            return .would_block;
        }
        shard.ops.appendSlice(self.allocator, ops) catch |e| {
            shard.lock.unlock();
            return e;
        };
        shard.bytes += add;
        _ = self.total_staged.fetchAdd(add, .monotonic);
        const cross = shard.bytes >= self.options.batch_bytes or shard.ops.items.len >= self.options.batch_ops;
        if (!cross or shard.committing) {
            shard.lock.unlock();
            return .staged;
        }
        shard.committing = true;
        const taken = shard.ops;
        const taken_bytes = shard.bytes;
        shard.ops = .empty;
        shard.bytes = 0;
        shard.lock.unlock();
        defer {
            shard.lock.lock();
            shard.committing = false;
            shard.lock.unlock();
        }
        try self.commitOps(si, taken, taken_bytes, null);
        return .staged;
    }

    /// Single-op convenience (routes by the object's file).
    pub fn stage(self: *ShardWriter, file_entry: u64, op: StagedOp) !StageResult {
        return self.stageAll(self.shardOfFile(file_entry), &.{op});
    }

    /// Commits whatever is staged on every shard. `durability` overrides the
    /// intermediate policy (used for the final drain).
    pub fn drain(self: *ShardWriter, durability: ?fmt_db.Durability) !void {
        for (self.shards, 0..) |*shard, si| {
            shard.lock.lock();
            const taken = shard.ops;
            const taken_bytes = shard.bytes;
            shard.ops = .empty;
            shard.bytes = 0;
            shard.lock.unlock();
            if (taken.items.len == 0) {
                var t = taken;
                t.deinit(self.allocator);
                continue;
            }
            try self.commitOps(@intCast(si), taken, taken_bytes, durability);
        }
    }

    fn commitOps(self: *ShardWriter, si: u32, ops_in: std.ArrayList(StagedOp), bytes: u64, durability_override: ?fmt_db.Durability) !void {
        var ops = ops_in;
        defer {
            for (ops.items) |op| if (op.value) |v| self.allocator.free(v);
            ops.deinit(self.allocator);
        }
        var batch = try batch_mod.Batch.beginWithOptions(self.db, self.allocator, .{ .shard = si });
        defer batch.deinit();
        var puts: u64 = 0;
        var dels: u64 = 0;
        for (ops.items) |op| {
            const kb = object_key.encodeDbKey(op.key);
            if (op.value) |v| {
                try batch.putBytes(&kb, v, 0);
                puts += 1;
            } else {
                try batch.deleteBytes(&kb);
                dels += 1;
            }
        }
        const shard = &self.shards[si];
        shard.lock.lock();
        shard.batches += 1;
        const n = shard.batches;
        shard.lock.unlock();
        const durability: fmt_db.Durability = durability_override orelse blk: {
            if (self.options.flush_every_n_batches != 0 and n % self.options.flush_every_n_batches == 0) break :blk .async;
            break :blk self.options.intermediate_durability;
        };
        try batch.commit(durability);
        _ = self.total_staged.fetchSub(bytes, .monotonic);
        self.stats_lock.lock();
        defer self.stats_lock.unlock();
        self.stats.puts += puts;
        self.stats.deletes += dels;
        self.stats.bytes += bytes;
        self.stats.batches += 1;
    }
};

test "shard writer stages commits per shard and drains" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var db = try kv.KvDb.openAt(tmp.dir, .{ .data_file_count = 2, .max_delta_entries = 4096 });
    defer db.close() catch {};
    var w = try ShardWriter.init(a, &db, .{ .batch_bytes = 2000, .batch_ops = 8 });
    defer w.deinit();
    var i: u64 = 0;
    while (i < 100) : (i += 1) {
        const v = try std.fmt.allocPrint(a, "value-{d}", .{i});
        try std.testing.expectEqual(StageResult.staged, try w.stage(i % 7, .{ .key = 1000 + i, .value = v }));
    }
    _ = try w.stage(5, .{ .key = 1005, .value = null });
    try w.drain(.sync);
    try std.testing.expect(w.stats.batches >= 2);
    try std.testing.expectEqual(@as(u64, 100), w.stats.puts);
    try std.testing.expectEqual(@as(u64, 1), w.stats.deletes);
    const k7 = object_key.encodeDbKey(1007);
    try std.testing.expectEqualStrings("value-7", try db.getBorrowedBytes(&k7));
    const k5 = object_key.encodeDbKey(1005);
    try std.testing.expectError(error.NotFound, db.getSizeBytes(&k5));
    try std.testing.expectEqual(@as(u64, 0), w.total_staged.load(.acquire));
}
