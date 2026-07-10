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
    put: struct { key: fmt.Key128, data: []u8, flags: u32 },
    delete: fmt.Key128,
};

pub const Batch = struct {
    db: *kv.KvDb,
    allocator: std.mem.Allocator,
    ops: std.ArrayList(BatchOp) = .empty,
    closed: bool = false,

    pub fn begin(db: *kv.KvDb, allocator: std.mem.Allocator) Batch {
        return .{ .db = db, .allocator = allocator };
    }

    pub fn put(self: *Batch, key: fmt.Key128, data: []const u8, flags: u32) !void {
        if (self.closed) return error.InvalidArgument;
        const owned = try self.allocator.dupe(u8, data);
        try self.ops.append(self.allocator, .{ .put = .{ .key = key, .data = owned, .flags = flags } });
    }

    pub fn delete(self: *Batch, key: fmt.Key128) !void {
        if (self.closed) return error.InvalidArgument;
        try self.ops.append(self.allocator, .{ .delete = key });
    }

    pub fn commit(self: *Batch, durability: fmt.Durability) !void {
        if (self.closed) return error.InvalidArgument;
        if (self.ops.items.len == 0) {
            self.closed = true;
            return;
        }
        try self.db.commitPending(null);
        self.db.beginBatchCommit();
        defer self.db.endBatchCommit();
        try self.db.delta.ensureRoomFor(@intCast(self.ops.items.len));
        const batch_id = self.db.nextBatchIdNoLock();
        _ = try self.db.delta.journal.appendBatchBegin(batch_id, .{ .durability = .none, .defer_header = true });
        errdefer _ = self.db.delta.journal.appendBatchAbort(batch_id, .{ .durability = durability }) catch {};

        var data_inputs = std.ArrayList(data_file.BatchAppendInput).empty;
        defer data_inputs.deinit(self.allocator);
        for (self.ops.items) |op| switch (op) {
            .put => |p| try data_inputs.append(self.allocator, .{
                .key = p.key,
                .payload = p.data,
                .options = .{ .version = self.db.nextVersionNoLock(p.key), .durability = .none, .defer_superblock = true },
            }),
            .delete => {},
        };
        const data_results = try data_file.appendBatch(&self.db.data, self.allocator, data_inputs.items);
        defer self.allocator.free(data_results);

        var published = std.ArrayList(delta_mod.PublishEntry).empty;
        defer published.deinit(self.allocator);
        var journal_inputs = std.ArrayList(journal_mod.AppendRecordInput).empty;
        defer journal_inputs.deinit(self.allocator);
        var put_i: usize = 0;
        for (self.ops.items) |op| switch (op) {
            .put => |p| {
                const r = data_results[put_i];
                put_i += 1;
                const info = fmt.IndexInfo{ .data_db_id = 0, .flags = p.flags, .offset = r.offset, .stored_size = r.stored_size, .raw_size = r.raw_size, .version = r.version, .crc = r.crc, .codec = r.codec, .reserved = 0 };
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
        try self.db.flushDataForCommit(durability);
        _ = try self.db.delta.journal.appendBatchCommit(batch_id, .{ .durability = durability });
        try self.db.delta.publishCommittedMany(published.items);
        self.closed = true;
    }

    pub fn rollback(self: *Batch) void {
        self.closed = true;
    }

    pub fn deinit(self: *Batch) void {
        for (self.ops.items) |op| switch (op) {
            .put => |p| self.allocator.free(p.data),
            .delete => {},
        };
        self.ops.deinit(self.allocator);
    }
};

pub const Snapshot = struct {
    allocator: std.mem.Allocator,
    values: std.AutoHashMap(u128, []u8),

    pub fn begin(db: *kv.KvDb, allocator: std.mem.Allocator) !Snapshot {
        try db.commitPending(null);
        var snap = Snapshot{ .allocator = allocator, .values = std.AutoHashMap(u128, []u8).init(allocator) };
        var base = base_mod.open(db.index) catch null;
        if (base) |*b| {
            defer b.close();
            const entries = try base_mod.collectEntries(b, allocator);
            defer allocator.free(entries);
            for (entries) |e| {
                const data = try allocator.alloc(u8, e.info.raw_size);
                errdefer allocator.free(data);
                _ = try data_file.readPayload(&db.data, e.info.offset, e.key, data);
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
                    _ = try data_file.readPayload(&db.data, rec.info.offset, rec.key, data);
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

    pub fn deinit(self: *Snapshot) void {
        var it = self.values.iterator();
        while (it.next()) |entry| self.allocator.free(entry.value_ptr.*);
        self.values.deinit();
    }
};

pub export fn db_batch_begin(db: ?*kv.KvDb, out_batch: ?**Batch) c_int {
    const d = db orelse return @intFromEnum(fmt.DbStatus.invalid_argument);
    const out = out_batch orelse return @intFromEnum(fmt.DbStatus.invalid_argument);
    const b = std.heap.smp_allocator.create(Batch) catch return @intFromEnum(fmt.DbStatus.no_space);
    b.* = Batch.begin(d, std.heap.smp_allocator);
    out.* = b;
    return @intFromEnum(fmt.DbStatus.ok);
}

pub export fn db_batch_put(batch: ?*Batch, key: kv.db_key128_t, data: ?*const anyopaque, size: u64, flags: u32) c_int {
    const b = batch orelse return @intFromEnum(fmt.DbStatus.invalid_argument);
    const ptr = data orelse return @intFromEnum(fmt.DbStatus.invalid_argument);
    const len: usize = std.math.cast(usize, size) orelse return @intFromEnum(fmt.DbStatus.invalid_argument);
    b.put(.{ .hi = key.hi, .lo = key.lo }, @as([*]const u8, @ptrCast(ptr))[0..len], flags) catch |err| return @intFromEnum(fmt.statusFromError(err));
    return @intFromEnum(fmt.DbStatus.ok);
}

pub export fn db_batch_delete(batch: ?*Batch, key: kv.db_key128_t) c_int {
    const b = batch orelse return @intFromEnum(fmt.DbStatus.invalid_argument);
    b.delete(.{ .hi = key.hi, .lo = key.lo }) catch |err| return @intFromEnum(fmt.statusFromError(err));
    return @intFromEnum(fmt.DbStatus.ok);
}

pub export fn db_batch_commit(batch: ?*Batch, durability: u32) c_int {
    const b = batch orelse return @intFromEnum(fmt.DbStatus.invalid_argument);
    const d: fmt.Durability = switch (durability) { 0 => .none, 1 => .async, 2 => .sync, else => .sync };
    b.commit(d) catch |err| return @intFromEnum(fmt.statusFromError(err));
    b.deinit();
    std.heap.smp_allocator.destroy(b);
    return @intFromEnum(fmt.DbStatus.ok);
}

pub export fn db_batch_rollback(batch: ?*Batch) c_int {
    const b = batch orelse return @intFromEnum(fmt.DbStatus.invalid_argument);
    b.rollback();
    b.deinit();
    std.heap.smp_allocator.destroy(b);
    return @intFromEnum(fmt.DbStatus.ok);
}

pub export fn db_snapshot_begin(db: ?*kv.KvDb, out_snapshot: ?**Snapshot) c_int {
    const d = db orelse return @intFromEnum(fmt.DbStatus.invalid_argument);
    const out = out_snapshot orelse return @intFromEnum(fmt.DbStatus.invalid_argument);
    const s = std.heap.smp_allocator.create(Snapshot) catch return @intFromEnum(fmt.DbStatus.no_space);
    s.* = Snapshot.begin(d, std.heap.smp_allocator) catch |err| {
        std.heap.smp_allocator.destroy(s);
        return @intFromEnum(fmt.statusFromError(err));
    };
    out.* = s;
    return @intFromEnum(fmt.DbStatus.ok);
}

pub export fn db_snapshot_get_size(snapshot: ?*Snapshot, key: kv.db_key128_t, out_size: ?*u64) c_int {
    const s = snapshot orelse return @intFromEnum(fmt.DbStatus.invalid_argument);
    const out = out_size orelse return @intFromEnum(fmt.DbStatus.invalid_argument);
    out.* = s.getSize(.{ .hi = key.hi, .lo = key.lo }) catch |err| return @intFromEnum(fmt.statusFromError(err));
    return @intFromEnum(fmt.DbStatus.ok);
}

pub export fn db_snapshot_get_into(snapshot: ?*Snapshot, key: kv.db_key128_t, dst: ?*anyopaque, dst_size: u64, out_written: ?*u64) c_int {
    const s = snapshot orelse return @intFromEnum(fmt.DbStatus.invalid_argument);
    const ptr = dst orelse return @intFromEnum(fmt.DbStatus.invalid_argument);
    const out = out_written orelse return @intFromEnum(fmt.DbStatus.invalid_argument);
    const len: usize = std.math.cast(usize, dst_size) orelse return @intFromEnum(fmt.DbStatus.invalid_argument);
    out.* = s.getInto(.{ .hi = key.hi, .lo = key.lo }, @as([*]u8, @ptrCast(ptr))[0..len]) catch |err| return @intFromEnum(fmt.statusFromError(err));
    return @intFromEnum(fmt.DbStatus.ok);
}

pub export fn db_snapshot_end(snapshot: ?*Snapshot) c_int {
    const s = snapshot orelse return @intFromEnum(fmt.DbStatus.invalid_argument);
    s.deinit();
    std.heap.smp_allocator.destroy(s);
    return @intFromEnum(fmt.DbStatus.ok);
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
