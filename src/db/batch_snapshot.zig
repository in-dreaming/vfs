const std = @import("std");
const fmt = @import("format.zig");
const kv = @import("kv_db.zig");
const data_file = @import("data/data_file.zig");
const base_mod = @import("index/base_index.zig");
const delta_mod = @import("index/delta_index.zig");
const journal_mod = @import("index/delta_journal.zig");

fn keyId(key: fmt.Key128) u128 {
    return (@as(u128, key.hi) << 64) | key.lo;
}

const BatchOp = union(enum) {
    put: struct { key: fmt.Key128, key_bytes: []u8, data: []u8, flags: u32, shard: u32 },
    delete: fmt.Key128,
};

pub const BatchOptions = struct {
    /// Pin every put in this batch to one data shard. `null` = per-key
    /// default shard.
    shard: ?u32 = null,
};

pub const Batch = struct {
    db: *kv.KvDb,
    allocator: std.mem.Allocator,
    ops: std.ArrayList(BatchOp) = .empty,
    closed: bool = false,
    options: BatchOptions = .{},
    staged_bytes: u64 = 0,

    pub fn begin(db: *kv.KvDb, allocator: std.mem.Allocator) Batch {
        return .{ .db = db, .allocator = allocator };
    }

    pub fn beginWithOptions(db: *kv.KvDb, allocator: std.mem.Allocator, options: BatchOptions) !Batch {
        if (options.shard) |s| if (s >= db.shardCount()) return error.InvalidArgument;
        return .{ .db = db, .allocator = allocator, .options = options };
    }

    pub fn opCount(self: *const Batch) usize {
        return self.ops.items.len;
    }

    pub fn put(self: *Batch, key: fmt.Key128, data: []const u8, flags: u32) !void {
        if (self.closed) return error.InvalidArgument;
        const shard = try self.db.resolveShard(key, self.options.shard);
        const owned_key = try self.allocator.alloc(u8, 0);
        errdefer self.allocator.free(owned_key);
        const owned = try self.allocator.dupe(u8, data);
        try self.ops.append(self.allocator, .{ .put = .{ .key = key, .key_bytes = owned_key, .data = owned, .flags = flags, .shard = shard } });
        self.staged_bytes += data.len;
    }

    pub fn putBytes(self: *Batch, key_bytes: []const u8, data: []const u8, flags: u32) !void {
        if (self.closed) return error.InvalidArgument;
        const key = try self.db.keyFromBytes(key_bytes);
        const shard = try self.db.resolveShard(key, self.options.shard);
        const owned_key = try self.allocator.dupe(u8, key_bytes);
        errdefer self.allocator.free(owned_key);
        const owned = try self.allocator.dupe(u8, data);
        errdefer self.allocator.free(owned);
        try self.ops.append(self.allocator, .{ .put = .{ .key = key, .key_bytes = owned_key, .data = owned, .flags = flags, .shard = shard } });
        self.staged_bytes += data.len + key_bytes.len;
    }

    pub fn deleteBytes(self: *Batch, key_bytes: []const u8) !void {
        try self.delete(try self.db.keyFromBytes(key_bytes));
    }

    pub fn delete(self: *Batch, key: fmt.Key128) !void {
        if (self.closed) return error.InvalidArgument;
        try self.ops.append(self.allocator, .{ .delete = key });
    }

    /// Two-phase commit: (a) data records are appended per shard holding only
    /// that shard's append mutex, so batches on disjoint shards run in
    /// parallel; (b) the journal/publish phase is serialized on the store's
    /// batch lock. A record is invisible until (b) completes, and recovery
    /// treats un-journaled records as orphans.
    pub fn commit(self: *Batch, durability: fmt.Durability) !void {
        if (self.closed) return error.InvalidArgument;
        if (self.ops.items.len == 0) {
            self.closed = true;
            return;
        }
        try self.db.commitPending(null);

        var data_inputs = std.ArrayList(kv.KvDb.ShardedAppendInput).empty;
        defer data_inputs.deinit(self.allocator);
        for (self.ops.items) |op| switch (op) {
            .put => |p| try data_inputs.append(self.allocator, .{
                .shard = p.shard,
                .input = .{
                    .key = p.key,
                    .key_bytes = p.key_bytes,
                    .payload = p.data,
                    .options = .{ .version = self.db.nextVersion(p.key), .durability = .none, .defer_superblock = true },
                },
            }),
            .delete => {},
        };
        var appended = try self.db.appendSharded(self.allocator, data_inputs.items);
        defer appended.deinit(self.allocator);

        self.db.beginBatchCommit();
        defer self.db.endBatchCommit();
        try self.db.reserveCommit(@intCast(self.ops.items.len));
        const batch_id = self.db.nextBatchIdNoLock();
        _ = try self.db.delta.journal.appendBatchBegin(batch_id, .{ .durability = .none, .defer_header = true });
        errdefer _ = self.db.delta.journal.appendBatchAbort(batch_id, .{ .durability = durability }) catch {};

        var published = std.ArrayList(delta_mod.PublishEntry).empty;
        defer published.deinit(self.allocator);
        var journal_inputs = std.ArrayList(journal_mod.AppendRecordInput).empty;
        defer journal_inputs.deinit(self.allocator);
        var put_i: usize = 0;
        for (self.ops.items) |op| switch (op) {
            .put => |p| {
                const r = appended.results[put_i];
                put_i += 1;
                const info = fmt.IndexInfo{ .data_db_id = p.shard, .flags = p.flags, .offset = r.offset, .stored_size = r.stored_size, .raw_size = r.raw_size, .version = r.version, .crc = r.crc, .codec = r.codec, .reserved = 0 };
                try journal_inputs.append(self.allocator, .{ .op = .put, .key = p.key, .info = info });
                try published.append(self.allocator, .{ .key = p.key, .info = info, .deleted = false });
            },
            .delete => |k| {
                const tombstone = fmt.IndexInfo{ .data_db_id = 0, .flags = 1, .offset = 0, .stored_size = 0, .raw_size = 0, .version = 0, .crc = 0, .codec = 0, .reserved = 0 };
                try journal_inputs.append(self.allocator, .{ .op = .delete, .key = k, .info = tombstone });
                try published.append(self.allocator, .{ .key = k, .info = tombstone, .deleted = true });
            },
        };
        try self.db.delta.journal.appendMany(self.allocator, journal_inputs.items, .{ .durability = .none, .batch_id = batch_id, .data_durable = true, .defer_header = true });
        try self.db.flushShardsForCommit(appended.touched_shards, durability);
        _ = try self.db.delta.journal.appendBatchCommit(batch_id, .{ .durability = durability });
        try self.db.delta.publishCommittedMany(published.items);
        self.closed = true;
    }

    pub fn rollback(self: *Batch) void {
        self.closed = true;
    }

    pub fn deinit(self: *Batch) void {
        for (self.ops.items) |op| switch (op) {
            .put => |p| {
                self.allocator.free(p.key_bytes);
                self.allocator.free(p.data);
            },
            .delete => {},
        };
        self.ops.deinit(self.allocator);
    }
};

pub const Snapshot = struct {
    allocator: std.mem.Allocator,
    db: *kv.KvDb,
    values: std.AutoHashMap(u128, []u8),

    pub fn begin(db: *kv.KvDb, allocator: std.mem.Allocator) !Snapshot {
        try db.commitPending(null);
        db.beginBatchCommit();
        defer db.endBatchCommit();
        var snap = Snapshot{ .allocator = allocator, .db = db, .values = std.AutoHashMap(u128, []u8).init(allocator) };
        var base = base_mod.open(db.index) catch null;
        if (base) |*b| {
            defer b.close();
            const entries = try base_mod.collectEntries(b, allocator);
            defer allocator.free(entries);
            for (entries) |e| {
                const data = try allocator.alloc(u8, e.info.raw_size);
                errdefer allocator.free(data);
                _ = try data_file.readPayload(try db.dataFile(e.info.data_db_id), e.info.offset, e.key, data);
                try snap.values.put(keyId(e.key), data);
            }
        }
        const records = try journal_mod.collectCommittedRecords(&db.delta.journal, allocator);
        defer allocator.free(records);
        for (records) |rec| {
            const id = keyId(rec.key);
            switch (rec.op) {
                .put => {
                    const data = try allocator.alloc(u8, rec.info.raw_size);
                    errdefer allocator.free(data);
                    _ = try data_file.readPayload(try db.dataFile(rec.info.data_db_id), rec.info.offset, rec.key, data);
                    if (try snap.values.fetchPut(id, data)) |old| allocator.free(old.value);
                },
                .delete => if (snap.values.fetchRemove(id)) |old| allocator.free(old.value),
                else => {},
            }
        }
        return snap;
    }

    pub fn getSize(self: *Snapshot, key: fmt.Key128) !u64 {
        const v = self.values.get(keyId(key)) orelse return error.NotFound;
        return v.len;
    }

    pub fn getInto(self: *Snapshot, key: fmt.Key128, dst: []u8) !usize {
        const v = self.values.get(keyId(key)) orelse return error.NotFound;
        if (dst.len < v.len) return error.BufferTooSmall;
        @memcpy(dst[0..v.len], v);
        return v.len;
    }

    pub fn getSizeBytes(self: *Snapshot, key_bytes: []const u8) !u64 {
        return self.getSize(try self.db.keyFromBytes(key_bytes));
    }

    pub fn getIntoBytes(self: *Snapshot, key_bytes: []const u8, dst: []u8) !usize {
        return self.getInto(try self.db.keyFromBytes(key_bytes), dst);
    }

    pub fn deinit(self: *Snapshot) void {
        var it = self.values.iterator();
        while (it.next()) |entry| self.allocator.free(entry.value_ptr.*);
        self.values.deinit();
    }
};

pub export fn db_batch_begin(db_handle: u64) u64 {
    const d = kv.validateHandle(kv.KvDb, db_handle, .db) catch |err| {
        _ = kv.setLastError(err);
        return 0;
    };
    const b = std.heap.smp_allocator.create(Batch) catch {
        _ = kv.setLastStatus(.no_space, "allocation failed");
        return 0;
    };
    b.* = Batch.begin(d, std.heap.smp_allocator);
    const h = @intFromPtr(b);
    kv.registerHandle(h, .batch) catch |err| {
        std.heap.smp_allocator.destroy(b);
        _ = kv.setLastError(err);
        return 0;
    };
    _ = kv.setOk();
    return h;
}

pub export fn db_batch_put(batch_handle: u64, key: ?*const anyopaque, key_size: u64, data: ?*const anyopaque, size: u64, flags: u32) c_int {
    const b = kv.validateHandle(Batch, batch_handle, .batch) catch |err| return kv.setLastError(err);
    const k = kv.keySlice(key, key_size) catch |err| return kv.setLastError(err);
    const slice = kv.dataSlice(data, size) catch |err| return kv.setLastError(err);
    b.putBytes(k, slice, flags) catch |err| return kv.setLastError(err);
    return kv.setOk();
}

pub export fn db_batch_delete(batch_handle: u64, key: ?*const anyopaque, key_size: u64) c_int {
    const b = kv.validateHandle(Batch, batch_handle, .batch) catch |err| return kv.setLastError(err);
    const k = kv.keySlice(key, key_size) catch |err| return kv.setLastError(err);
    b.deleteBytes(k) catch |err| return kv.setLastError(err);
    return kv.setOk();
}

pub export fn db_batch_commit(batch_handle: u64, durability: u32) c_int {
    const b = kv.validateHandle(Batch, batch_handle, .batch) catch |err| return kv.setLastError(err);
    const d: fmt.Durability = switch (durability) { 0 => .none, 1 => .async, 2 => .sync, else => .sync };
    kv.unregisterHandle(batch_handle);
    b.commit(d) catch |err| {
        b.deinit();
        std.heap.smp_allocator.destroy(b);
        return kv.setLastError(err);
    };
    b.deinit();
    std.heap.smp_allocator.destroy(b);
    return kv.setOk();
}

pub export fn db_batch_rollback(batch_handle: u64) c_int {
    const b = kv.validateHandle(Batch, batch_handle, .batch) catch |err| return kv.setLastError(err);
    kv.unregisterHandle(batch_handle);
    b.rollback();
    b.deinit();
    std.heap.smp_allocator.destroy(b);
    return kv.setOk();
}

pub export fn db_snapshot_begin(db_handle: u64) u64 {
    const d = kv.validateHandle(kv.KvDb, db_handle, .db) catch |err| {
        _ = kv.setLastError(err);
        return 0;
    };
    const s = std.heap.smp_allocator.create(Snapshot) catch {
        _ = kv.setLastStatus(.no_space, "allocation failed");
        return 0;
    };
    s.* = Snapshot.begin(d, std.heap.smp_allocator) catch |err| {
        std.heap.smp_allocator.destroy(s);
        _ = kv.setLastError(err);
        return 0;
    };
    const h = @intFromPtr(s);
    kv.registerHandle(h, .snapshot) catch |err| {
        s.deinit();
        std.heap.smp_allocator.destroy(s);
        _ = kv.setLastError(err);
        return 0;
    };
    _ = kv.setOk();
    return h;
}

pub export fn db_snapshot_get_size(snapshot_handle: u64, key: ?*const anyopaque, key_size: u64, out_size: ?*u64) c_int {
    const s = kv.validateHandle(Snapshot, snapshot_handle, .snapshot) catch |err| return kv.setLastError(err);
    const out = out_size orelse return kv.setLastStatus(.invalid_argument, "out_size is null");
    const k = kv.keySlice(key, key_size) catch |err| return kv.setLastError(err);
    out.* = s.getSizeBytes(k) catch |err| return kv.setLastError(err);
    return kv.setOk();
}

pub export fn db_snapshot_get_into(snapshot_handle: u64, key: ?*const anyopaque, key_size: u64, dst: ?*anyopaque, dst_size: u64, out_written: ?*u64) c_int {
    const s = kv.validateHandle(Snapshot, snapshot_handle, .snapshot) catch |err| return kv.setLastError(err);
    const out = out_written orelse return kv.setLastStatus(.invalid_argument, "out_written is null");
    const k = kv.keySlice(key, key_size) catch |err| return kv.setLastError(err);
    const slice = kv.mutSlice(dst, dst_size) catch |err| return kv.setLastError(err);
    out.* = s.getIntoBytes(k, slice) catch |err| return kv.setLastError(err);
    return kv.setOk();
}

pub export fn db_snapshot_end(snapshot_handle: u64) c_int {
    const s = kv.validateHandle(Snapshot, snapshot_handle, .snapshot) catch |err| return kv.setLastError(err);
    kv.unregisterHandle(snapshot_handle);
    s.deinit();
    std.heap.smp_allocator.destroy(s);
    return kv.setOk();
}

test "batch atomic visibility and snapshot stable reads" {
    const testing = std.testing;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var db = try kv.KvDb.openAt(tmp.dir, .{});
    defer db.close() catch unreachable;
    const key: fmt.Key128 = .{ .hi = 1, .lo = 2 };
    var batch = Batch.begin(&db, testing.allocator);
    defer batch.deinit();
    try batch.put(key, "abc", 0);
    try testing.expectError(error.NotFound, db.getSize(key));
    try batch.commit(.sync);
    try testing.expectEqual(@as(u64, 3), try db.getSize(key));

    var snap = try Snapshot.begin(&db, testing.allocator);
    defer snap.deinit();
    try db.put(key, "new", .{});
    var buf: [4]u8 = undefined;
    try testing.expectEqual(@as(usize, 3), try snap.getInto(key, &buf));
    try testing.expectEqualStrings("abc", buf[0..3]);

    var rb = Batch.begin(&db, testing.allocator);
    defer rb.deinit();
    try rb.put(.{ .hi = 9, .lo = 9 }, "x", 0);
    rb.rollback();
    try testing.expectError(error.NotFound, db.getSize(.{ .hi = 9, .lo = 9 }));
}

test "batch journal recovery only replays committed batches" {
    const testing = std.testing;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const uncommitted: fmt.Key128 = .{ .hi = 10, .lo = 1 };
    const committed: fmt.Key128 = .{ .hi = 10, .lo = 2 };

    var db = try kv.KvDb.openAt(tmp.dir, .{});
    const batch_id_1 = db.nextBatchId();
    _ = try db.delta.journal.appendBatchBegin(batch_id_1, .{ .durability = .sync });
    const r1 = try data_file.append(&db.data, uncommitted, "lost", .{ .version = 1, .durability = .sync });
    const info1 = fmt.IndexInfo{ .data_db_id = 0, .flags = 0, .offset = r1.offset, .stored_size = r1.stored_size, .raw_size = r1.raw_size, .version = r1.version, .crc = r1.crc, .codec = r1.codec, .reserved = 0 };
    _ = try db.delta.journal.appendPut(uncommitted, info1, .{ .durability = .sync, .batch_id = batch_id_1, .data_durable = true });

    var batch = Batch.begin(&db, testing.allocator);
    defer batch.deinit();
    try batch.put(committed, "kept", 0);
    try batch.commit(.sync);
    try db.close();

    var reopened = try kv.KvDb.openAt(tmp.dir, .{});
    defer reopened.close() catch unreachable;
    try testing.expectError(error.NotFound, reopened.getSize(uncommitted));
    var buf: [8]u8 = undefined;
    try testing.expectEqual(@as(usize, 4), try reopened.getInto(committed, &buf));
    try testing.expectEqualStrings("kept", buf[0..4]);
}
