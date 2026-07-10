const std = @import("std");
const fmt = @import("format.zig");
const manifest_mod = @import("manifest.zig");
const data_mod = @import("data/data_file.zig");
const index_mod = @import("index/index_file.zig");
const base_mod = @import("index/base_index.zig");
const delta_mod = @import("index/delta_index.zig");
const journal_mod = @import("index/delta_journal.zig");
const checkpoint_mod = @import("index/checkpoint.zig");
const alloc_mod = @import("data/allocator.zig");
const pf = @import("platform/file.zig");
const KEY_LOCK_COUNT: usize = 256;

pub const OpenOptions = struct {
    durability: fmt.Durability = .sync,
    max_delta_entries: u64 = 1024,
    mode: AccessMode = .read_write,
};

pub const AccessMode = enum(u32) {
    read_only = 0,
    write_only = 1,
    read_write = 2,
};

pub const PutOptions = struct {
    durability: fmt.Durability = .sync,
    flags: u32 = 0,
};

pub const DeleteOptions = struct {
    durability: fmt.Durability = .sync,
};

const PendingOp = union(enum) {
    put: struct { key: fmt.Key128, data: []u8, flags: u32, durability: fmt.Durability },
    delete: struct { key: fmt.Key128, durability: fmt.Durability },
};

pub const KvDb = struct {
    dir: std.Io.Dir,
    owns_dir: bool = false,
    manifest: manifest_mod.Manifest,
    data: data_mod.DataFile,
    index: *index_mod.IndexFile,
    delta: delta_mod.DeltaIndex,
    batch_counter: u64 = 1,
    key_locks: [KEY_LOCK_COUNT]std.atomic.Mutex = [_]std.atomic.Mutex{.unlocked} ** KEY_LOCK_COUNT,
    batch_lock: std.atomic.Mutex = .unlocked,
    pending_lock: std.atomic.Mutex = .unlocked,
    maintenance_lock: std.atomic.Mutex = .unlocked,
    pending: std.ArrayList(PendingOp) = .empty,
    mode: AccessMode = .read_write,

    pub fn openAt(dir: std.Io.Dir, options: OpenOptions) !KvDb {
        var man = manifest_mod.openAt(dir, "manifest.db") catch |err| switch (err) {
            error.FileNotFound => if (options.mode == .read_only) return err else try manifest_mod.createAt(dir, "manifest.db", .{ .initial_data_files = 1 }),
            else => |e| return e,
        };
        errdefer man.close() catch {};
        var data = data_mod.openAt(dir, "data_000.db", .{}) catch |err| switch (err) {
            error.FileNotFound => if (options.mode == .read_only) return err else try data_mod.createAt(dir, "data_000.db", .{ .durability = options.durability }),
            else => |e| return e,
        };
        errdefer data.close() catch {};
        const index_ptr = try std.heap.smp_allocator.create(index_mod.IndexFile);
        errdefer std.heap.smp_allocator.destroy(index_ptr);
        index_ptr.* = index_mod.openAt(dir, "index.db") catch |err| switch (err) {
            error.FileNotFound => if (options.mode == .read_only) return err else try index_mod.createAt(dir, "index.db", [_]u8{0} ** 16),
            else => |e| return e,
        };
        errdefer index_ptr.close() catch {};
        const delta_entries = pow2AtLeast(options.max_delta_entries);
        const delta = if (options.mode == .read_only)
            delta_mod.openReadOnly(index_ptr) catch |err| switch (err) {
                error.Busy => try delta_mod.open(index_ptr),
                error.NotFound => return err,
                else => |e| return e,
            }
        else
            delta_mod.open(index_ptr) catch |err| switch (err) {
                error.NotFound => try delta_mod.create(index_ptr, delta_entries, journalSizeForEntries(delta_entries)),
                else => |e| return e,
            };
        return .{ .dir = dir, .manifest = man, .data = data, .index = index_ptr, .delta = delta, .mode = options.mode };
    }

    pub fn open(path: []const u8, options: OpenOptions) !KvDb {
        const io = std.Io.Threaded.global_single_threaded.io();
        _ = std.Io.Dir.cwd().createDirPath(io, path) catch {};
        const dir = try std.Io.Dir.openDir(std.Io.Dir.cwd(), io, path, .{});
        var db = try openAt(dir, options);
        db.owns_dir = true;
        return db;
    }

    pub fn close(self: *KvDb) !void {
        if (self.canWrite()) try self.commitPending(null);
        try self.delta.close();
        try self.index.close();
        std.heap.smp_allocator.destroy(self.index);
        try self.data.close();
        try self.manifest.close();
        self.freePending();
        self.pending.deinit(std.heap.smp_allocator);
        if (self.owns_dir) self.dir.close(std.Io.Threaded.global_single_threaded.io());
    }

    pub fn getSize(self: *KvDb, key: fmt.Key128) !u64 {
        try self.requireRead();
        try self.commitPending(null);
        const info = try self.lookupInfoNoLock(key);
        return info.raw_size;
    }

    pub fn getInto(self: *KvDb, key: fmt.Key128, dst: []u8) !usize {
        try self.requireRead();
        try self.commitPending(null);
        const info = try self.lookupInfoNoLock(key);
        return data_mod.readPayload(&self.data, info.offset, key, dst);
    }

    pub fn put(self: *KvDb, key: fmt.Key128, data: []const u8, options: PutOptions) !void {
        try self.requireWrite();
        const owned = try std.heap.smp_allocator.dupe(u8, data);
        errdefer std.heap.smp_allocator.free(owned);
        lockMutex(&self.pending_lock);
        defer self.pending_lock.unlock();
        try self.pending.append(std.heap.smp_allocator, .{ .put = .{ .key = key, .data = owned, .flags = options.flags, .durability = options.durability } });
    }

    pub fn putNoLock(self: *KvDb, key: fmt.Key128, data: []const u8, options: PutOptions) !void {
        const r = try data_mod.append(&self.data, key, data, .{ .version = self.nextVersionNoLock(key), .durability = options.durability });
        const info = fmt.IndexInfo{ .data_db_id = 0, .flags = options.flags, .offset = r.offset, .stored_size = r.stored_size, .raw_size = r.raw_size, .version = r.version, .crc = r.crc, .codec = r.codec, .reserved = 0 };
        try self.delta.put(key, info, .{ .durability = options.durability, .data_durable = true });
    }

    pub fn delete(self: *KvDb, key: fmt.Key128, options: DeleteOptions) !void {
        try self.requireWrite();
        lockMutex(&self.pending_lock);
        defer self.pending_lock.unlock();
        try self.pending.append(std.heap.smp_allocator, .{ .delete = .{ .key = key, .durability = options.durability } });
    }

    pub fn deleteNoLock(self: *KvDb, key: fmt.Key128, options: DeleteOptions) !void {
        try self.delta.delete(key, .{ .durability = options.durability });
    }

    pub fn checkpoint(self: *KvDb) !void {
        try self.requireWrite();
        try self.commitPending(null);
        lockMutex(&self.maintenance_lock);
        defer self.maintenance_lock.unlock();
        try checkpoint_mod.run(self, std.heap.smp_allocator);
    }

    pub fn optimize(self: *KvDb) !void {
        try self.requireWrite();
        try self.commitPending(null);
        lockMutex(&self.maintenance_lock);
        defer self.maintenance_lock.unlock();
        try self.optimizeNoConcurrentAccess(std.heap.smp_allocator);
    }

    pub fn nextBatchId(self: *KvDb) u64 {
        lockMutex(&self.batch_lock);
        defer self.batch_lock.unlock();
        return self.nextBatchIdNoLock();
    }

    pub fn nextBatchIdNoLock(self: *KvDb) u64 {
        const id = self.batch_counter;
        self.batch_counter += 1;
        return id;
    }

    pub fn nextVersion(self: *KvDb, key: fmt.Key128) u64 {
        const lock = self.keyLock(key);
        lockMutex(lock);
        defer lock.unlock();
        return self.nextVersionNoLock(key);
    }

    pub fn nextVersionNoLock(self: *KvDb, key: fmt.Key128) u64 {
        const meta = self.lookupMetaNoLock(key) catch return 1;
        return meta.version + 1;
    }

    pub fn beginBatchCommit(self: *KvDb) void {
        lockMutex(&self.batch_lock);
    }

    pub fn endBatchCommit(self: *KvDb) void {
        self.batch_lock.unlock();
    }

    pub fn keyLock(self: *KvDb, key: fmt.Key128) *std.atomic.Mutex {
        const h = fmt.mixHash128To64(key);
        return &self.key_locks[@as(usize, @intCast(h % KEY_LOCK_COUNT))];
    }

    pub fn commitPending(self: *KvDb, durability_override: ?fmt.Durability) !void {
        lockMutex(&self.pending_lock);
        if (self.pending.items.len == 0) {
            self.pending_lock.unlock();
            return;
        }
        self.pending_lock.unlock();

        lockMutex(&self.batch_lock);
        defer self.batch_lock.unlock();
        lockMutex(&self.pending_lock);
        defer self.pending_lock.unlock();
        if (self.pending.items.len == 0) return;
        try self.requireWrite();
        try self.delta.ensureRoomFor(@intCast(self.pending.items.len));

        var prealloc_bytes: u64 = 0;
        for (self.pending.items) |op| switch (op) {
            .put => |p| {
                const total = @as(u64, data_mod.RECORD_HEADER_SIZE) + p.data.len + data_mod.RECORD_FOOTER_SIZE;
                prealloc_bytes += try fmt.alignUp(total, data_mod.RECORD_ALIGNMENT);
            },
            .delete => {},
        };
        if (prealloc_bytes != 0) try pf.preallocate(self.data.file, self.data.logical_tail, prealloc_bytes);

        const batch_id = self.nextBatchIdNoLock();
        const durability = durability_override orelse pendingMaxDurability(self.pending.items);
        _ = try self.delta.journal.appendBatchBegin(batch_id, .{ .durability = .none, .defer_header = true });
        errdefer _ = self.delta.journal.appendBatchAbort(batch_id, .{ .durability = durability }) catch {};

        var data_inputs = std.ArrayList(data_mod.BatchAppendInput).empty;
        defer data_inputs.deinit(std.heap.smp_allocator);
        for (self.pending.items) |op| switch (op) {
            .put => |p| try data_inputs.append(std.heap.smp_allocator, .{
                .key = p.key,
                .payload = p.data,
                .options = .{ .version = self.nextVersionNoLock(p.key), .durability = .none, .defer_superblock = true },
            }),
            .delete => {},
        };
        const data_results = try data_mod.appendBatch(&self.data, std.heap.smp_allocator, data_inputs.items);
        defer std.heap.smp_allocator.free(data_results);

        var published = std.ArrayList(delta_mod.PublishEntry).empty;
        defer published.deinit(std.heap.smp_allocator);
        var journal_inputs = std.ArrayList(journal_mod.AppendRecordInput).empty;
        defer journal_inputs.deinit(std.heap.smp_allocator);
        var put_i: usize = 0;
        for (self.pending.items) |op| switch (op) {
            .put => |p| {
                const lock = self.keyLock(p.key);
                lockMutex(lock);
                defer lock.unlock();
                const r = data_results[put_i];
                put_i += 1;
                const info = fmt.IndexInfo{ .data_db_id = 0, .flags = p.flags, .offset = r.offset, .stored_size = r.stored_size, .raw_size = r.raw_size, .version = r.version, .crc = r.crc, .codec = r.codec, .reserved = 0 };
                try journal_inputs.append(std.heap.smp_allocator, .{ .op = .put, .key = p.key, .info = info });
                try published.append(std.heap.smp_allocator, .{ .key = p.key, .info = info, .deleted = false });
            },
            .delete => |d| {
                const lock = self.keyLock(d.key);
                lockMutex(lock);
                defer lock.unlock();
                try journal_inputs.append(std.heap.smp_allocator, .{ .op = .delete, .key = d.key, .info = tombstoneInfo() });
                try published.append(std.heap.smp_allocator, .{ .key = d.key, .info = tombstoneInfo(), .deleted = true });
            },
        };
        try self.delta.journal.appendMany(std.heap.smp_allocator, journal_inputs.items, .{ .durability = .none, .batch_id = batch_id, .data_durable = true, .defer_header = true });
        try self.flushDataForCommit(durability);
        _ = try self.delta.journal.appendBatchCommit(batch_id, .{ .durability = durability });
        try self.delta.publishCommittedMany(published.items);
        self.freePending();
        self.pending.clearRetainingCapacity();
    }

    pub fn flushDataForCommit(self: *KvDb, durability: fmt.Durability) !void {
        try data_mod.publishSuper(&self.data, durability);
    }

    fn freePending(self: *KvDb) void {
        for (self.pending.items) |op| switch (op) {
            .put => |p| std.heap.smp_allocator.free(p.data),
            .delete => {},
        };
    }

    fn lookupMetaNoLock(self: *KvDb, key: fmt.Key128) !data_mod.RecordMeta {
        const info = try self.lookupInfoNoLock(key);
        return data_mod.readMeta(&self.data, info.offset);
    }

    fn lookupInfoNoLock(self: *KvDb, key: fmt.Key128) !fmt.IndexInfo {
        switch (try self.delta.lookup(key)) {
            .found => |info| return info,
            .deleted => return error.NotFound,
            .not_found => {},
        }
        var base = base_mod.open(self.index) catch |err| switch (err) {
            error.NotFound => return error.NotFound,
            error.Corruption => return error.NotFound,
            else => |e| return e,
        };
        defer base.close();
        return base.lookup(key);
    }

    fn canWrite(self: *const KvDb) bool {
        return self.mode != .read_only;
    }

    fn canRead(self: *const KvDb) bool {
        return self.mode != .write_only;
    }

    fn requireWrite(self: *const KvDb) !void {
        if (!self.canWrite()) return error.PermissionDenied;
    }

    fn requireRead(self: *const KvDb) !void {
        if (!self.canRead()) return error.PermissionDenied;
    }

    fn optimizeNoConcurrentAccess(self: *KvDb, allocator: std.mem.Allocator) !void {
        const live_entries = try checkpoint_mod.collectLiveEntries(self, allocator);
        defer allocator.free(live_entries);

        var live_offsets = std.AutoHashMap(u64, void).init(allocator);
        defer live_offsets.deinit();
        for (live_entries) |entry| try live_offsets.put(entry.info.offset, {});

        var free_blocks = std.ArrayList(alloc_mod.Block).empty;
        defer free_blocks.deinit(allocator);

        var seen_live: usize = 0;
        var off = data_mod.RECORD_AREA_OFFSET;
        while (off < self.data.logical_tail) {
            const meta = try data_mod.verifyRecord(&self.data, off);
            if (live_offsets.contains(off)) {
                seen_live += 1;
            } else {
                try free_blocks.append(allocator, .{ .offset = off, .size = meta.aligned_size });
            }
            off += meta.aligned_size;
        }
        if (off != self.data.logical_tail or seen_live != live_entries.len) return error.Corruption;

        var free_len = coalesceBlocks(free_blocks.items);
        free_blocks.shrinkRetainingCapacity(free_len);
        var new_tail = self.data.logical_tail;
        var tail_free_bytes: u64 = 0;
        while (true) {
            var found_i: ?usize = null;
            var i: usize = 0;
            while (i < free_len) : (i += 1) {
                const b = free_blocks.items[i];
                if (b.offset + b.size == new_tail) {
                    found_i = i;
                    break;
                }
            }
            if (found_i) |remove_i| {
                const b = free_blocks.items[remove_i];
                tail_free_bytes += b.size;
                new_tail = b.offset;
                free_blocks.items[remove_i] = free_blocks.items[free_len - 1];
                free_len -= 1;
            } else break;
        }
        free_blocks.shrinkRetainingCapacity(free_len);
        free_len = coalesceBlocks(free_blocks.items);
        free_blocks.shrinkRetainingCapacity(free_len);

        var free_bytes: u64 = 0;
        for (free_blocks.items) |b| {
            if (b.size > std.math.maxInt(u32)) return error.NoSpace;
            free_bytes += b.size;
        }
        const checkpoint_size = if (free_blocks.items.len == 0) 0 else alloc_mod.HEADER_SIZE + @as(u64, free_blocks.items.len) * alloc_mod.BLOCK_SIZE;
        if (checkpoint_size > data_mod.CHECKPOINT_AREA_SIZE) return error.NoSpace;

        var data_allocator = alloc_mod.Allocator.init(allocator, new_tail);
        defer data_allocator.deinit();
        data_allocator.epoch.current = self.data.epoch + 1;
        for (free_blocks.items) |b| try data_allocator.free.append(allocator, b);

        if (new_tail != self.data.logical_tail) {
            try pf.setLen(self.data.file, new_tail);
            try pf.flushMetadata(self.data.file);
            self.data.logical_tail = new_tail;
        }
        self.data.epoch += 1;
        var alloc_super = data_mod.AllocatorSuper{
            .checkpoint_offset = 0,
            .checkpoint_size = 0,
            .checkpoint_epoch = data_allocator.epoch.current,
            .free_bytes = free_bytes,
            .pending_free_bytes = 0,
            .tail_free_bytes = tail_free_bytes,
        };
        if (checkpoint_size != 0) {
            try data_allocator.writeCheckpoint(self.data.file, data_mod.ALLOCATOR_CHECKPOINT_OFFSET);
            alloc_super.checkpoint_offset = data_mod.ALLOCATOR_CHECKPOINT_OFFSET;
            alloc_super.checkpoint_size = checkpoint_size;
        }
        try data_mod.publishSuperWithAllocator(&self.data, .sync, alloc_super);

        _ = try base_mod.build(self.index, allocator, live_entries);
        const slot_count = self.delta.journal.header.slot_count;
        const journal_size = self.delta.journal.header.journal_size;
        var fresh_delta = try delta_mod.create(self.index, slot_count, journal_size);
        errdefer fresh_delta.close() catch {};
        try self.delta.close();
        self.delta = fresh_delta;
    }
};

fn coalesceBlocks(blocks: []alloc_mod.Block) usize {
    if (blocks.len <= 1) return blocks.len;
    std.mem.sort(alloc_mod.Block, blocks, {}, blockLessThan);
    var out: usize = 0;
    var i: usize = 1;
    while (i < blocks.len) : (i += 1) {
        if (blocks[out].offset + blocks[out].size >= blocks[i].offset) {
            const end = @max(blocks[out].offset + blocks[out].size, blocks[i].offset + blocks[i].size);
            blocks[out].size = end - blocks[out].offset;
        } else {
            out += 1;
            blocks[out] = blocks[i];
        }
    }
    return out + 1;
}

fn blockLessThan(_: void, a: alloc_mod.Block, b: alloc_mod.Block) bool {
    return a.offset < b.offset;
}

fn pow2AtLeast(n_in: u64) u64 {
    var n: u64 = if (n_in < 8) 8 else n_in;
    n -= 1;
    n |= n >> 1;
    n |= n >> 2;
    n |= n >> 4;
    n |= n >> 8;
    n |= n >> 16;
    n |= n >> 32;
    return n + 1;
}

fn journalSizeForEntries(entries: u64) u64 {
    const min_size: u64 = 1024 * 1024;
    const need = (entries + 2) * @as(u64, journal_mod.JOURNAL_RECORD_SIZE);
    return @max(min_size, need);
}

fn lockMutex(m: *std.atomic.Mutex) void {
    while (!m.tryLock()) std.atomic.spinLoopHint();
}

fn tombstoneInfo() fmt.IndexInfo {
    return .{ .data_db_id = 0, .flags = 1, .offset = 0, .stored_size = 0, .raw_size = 0, .version = 0, .crc = 0, .codec = 0, .reserved = 0 };
}

fn pendingMaxDurability(items: []const PendingOp) fmt.Durability {
    var out: fmt.Durability = .none;
    for (items) |op| {
        const d = switch (op) {
            .put => |p| p.durability,
            .delete => |p| p.durability,
        };
        if (@intFromEnum(d) > @intFromEnum(out)) out = d;
    }
    return out;
}

pub const db_key128_t = extern struct {
    hi: u64,
    lo: u64,
};

pub const db_open_options_t = extern struct {
    struct_size: u32,
    flags: u32,
    durability: u32,
    reserved0: u32,
    max_delta_entries: u64,
    data_file_target_size: u64,
};

fn toStatus(err: anyerror) c_int {
    return @intFromEnum(fmt.statusFromError(err));
}

fn keyFromC(k: db_key128_t) fmt.Key128 {
    return .{ .hi = k.hi, .lo = k.lo };
}

pub export fn db_open(path: [*:0]const u8, options: ?*const db_open_options_t, out_db: ?**KvDb) c_int {
    const out = out_db orelse return @intFromEnum(fmt.DbStatus.invalid_argument);
    const p = std.mem.span(path);
    const opts = if (options) |o| OpenOptions{ .durability = switch (o.durability) { 0 => .none, 1 => .async, 2 => .sync, else => .sync }, .max_delta_entries = if (o.max_delta_entries == 0) 1024 else o.max_delta_entries, .mode = switch (o.flags & 0x3) { 1 => .read_only, 2 => .write_only, else => .read_write } } else OpenOptions{};
    const db = std.heap.smp_allocator.create(KvDb) catch return @intFromEnum(fmt.DbStatus.no_space);
    db.* = KvDb.open(p, opts) catch |err| {
        std.heap.smp_allocator.destroy(db);
        return toStatus(err);
    };
    out.* = db;
    return @intFromEnum(fmt.DbStatus.ok);
}

pub export fn db_close(db: ?*KvDb) c_int {
    const d = db orelse return @intFromEnum(fmt.DbStatus.invalid_argument);
    d.close() catch |err| return toStatus(err);
    std.heap.smp_allocator.destroy(d);
    return @intFromEnum(fmt.DbStatus.ok);
}

pub export fn db_get_size(db: ?*KvDb, key: db_key128_t, out_size: ?*u64) c_int {
    const d = db orelse return @intFromEnum(fmt.DbStatus.invalid_argument);
    const out = out_size orelse return @intFromEnum(fmt.DbStatus.invalid_argument);
    out.* = d.getSize(keyFromC(key)) catch |err| return toStatus(err);
    return @intFromEnum(fmt.DbStatus.ok);
}

pub export fn db_get_into(db: ?*KvDb, key: db_key128_t, dst: ?*anyopaque, dst_size: u64, out_written: ?*u64) c_int {
    const d = db orelse return @intFromEnum(fmt.DbStatus.invalid_argument);
    const ptr = dst orelse return @intFromEnum(fmt.DbStatus.invalid_argument);
    const out = out_written orelse return @intFromEnum(fmt.DbStatus.invalid_argument);
    const len: usize = std.math.cast(usize, dst_size) orelse return @intFromEnum(fmt.DbStatus.invalid_argument);
    const slice = @as([*]u8, @ptrCast(ptr))[0..len];
    out.* = d.getInto(keyFromC(key), slice) catch |err| return toStatus(err);
    return @intFromEnum(fmt.DbStatus.ok);
}

pub export fn db_put(db: ?*KvDb, key: db_key128_t, data: ?*const anyopaque, size: u64, flags: u32) c_int {
    const d = db orelse return @intFromEnum(fmt.DbStatus.invalid_argument);
    const ptr = data orelse return @intFromEnum(fmt.DbStatus.invalid_argument);
    const len: usize = std.math.cast(usize, size) orelse return @intFromEnum(fmt.DbStatus.invalid_argument);
    const slice = @as([*]const u8, @ptrCast(ptr))[0..len];
    d.put(keyFromC(key), slice, .{ .flags = flags }) catch |err| return toStatus(err);
    return @intFromEnum(fmt.DbStatus.ok);
}

pub export fn db_delete(db: ?*KvDb, key: db_key128_t) c_int {
    const d = db orelse return @intFromEnum(fmt.DbStatus.invalid_argument);
    d.delete(keyFromC(key), .{}) catch |err| return toStatus(err);
    return @intFromEnum(fmt.DbStatus.ok);
}

test "kv db internal and c abi put get overwrite delete reopen" {
    const testing = std.testing;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var db = try KvDb.openAt(tmp.dir, .{});
    const key: fmt.Key128 = .{ .hi = 1, .lo = 2 };
    try db.put(key, "abc", .{});
    try testing.expectEqual(@as(u64, 3), try db.getSize(key));
    var buf: [8]u8 = undefined;
    try testing.expectEqual(@as(usize, 3), try db.getInto(key, &buf));
    try testing.expectEqualStrings("abc", buf[0..3]);
    try db.put(key, "abcdef", .{});
    try testing.expectEqual(@as(u64, 6), try db.getSize(key));
    try db.delete(key, .{});
    try testing.expectError(error.NotFound, db.getSize(key));
    try db.close();

    var reopened = try KvDb.openAt(tmp.dir, .{});
    defer reopened.close() catch unreachable;
    try testing.expectError(error.NotFound, reopened.getSize(key));
}

test "kv db pending writes auto commit on read and explicit commit" {
    const testing = std.testing;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var db = try KvDb.openAt(tmp.dir, .{});
    defer db.close() catch unreachable;

    const key: fmt.Key128 = .{ .hi = 7, .lo = 8 };
    try db.put(key, "pending", .{ .durability = .none });
    try testing.expectEqual(@as(usize, 1), db.pending.items.len);

    var buf: [16]u8 = undefined;
    try testing.expectEqual(@as(usize, 7), try db.getInto(key, &buf));
    try testing.expectEqualStrings("pending", buf[0..7]);
    try testing.expectEqual(@as(usize, 0), db.pending.items.len);

    try db.put(key, "next", .{ .durability = .none });
    try db.delete(.{ .hi = 9, .lo = 9 }, .{ .durability = .none });
    try testing.expectEqual(@as(usize, 2), db.pending.items.len);
    try db.commitPending(.sync);
    try testing.expectEqual(@as(usize, 0), db.pending.items.len);
    try testing.expectEqual(@as(u64, 4), try db.getSize(key));
}

test "kv db open modes enforce read write API access" {
    const testing = std.testing;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const key: fmt.Key128 = .{ .hi = 11, .lo = 12 };

    var db = try KvDb.openAt(tmp.dir, .{ .mode = .read_write });
    try db.put(key, "rw", .{});
    try db.commitPending(.sync);
    try db.close();

    var ro = try KvDb.openAt(tmp.dir, .{ .mode = .read_only });
    var buf: [8]u8 = undefined;
    try testing.expectEqual(@as(usize, 2), try ro.getInto(key, &buf));
    try testing.expectEqualStrings("rw", buf[0..2]);
    try testing.expectError(error.PermissionDenied, ro.put(.{ .hi = 99, .lo = 1 }, "no", .{}));
    try ro.close();

    var wo = try KvDb.openAt(tmp.dir, .{ .mode = .write_only });
    try testing.expectError(error.PermissionDenied, wo.getSize(key));
    try wo.put(.{ .hi = 13, .lo = 14 }, "wo", .{});
    try wo.commitPending(.sync);
    try wo.close();

    var check = try KvDb.openAt(tmp.dir, .{ .mode = .read_only });
    defer check.close() catch unreachable;
    try testing.expectEqual(@as(usize, 2), try check.getInto(.{ .hi = 13, .lo = 14 }, &buf));
    try testing.expectEqualStrings("wo", buf[0..2]);
}

test "kv db non-race concurrent staged writers require explicit commit" {
    const testing = std.testing;
    const writer_count = 4;
    const iterations = 32;
    const value_size = 24;

    const Ctx = struct {
        db: *KvDb,
        errors: *[writer_count]u32,

        fn key(writer_id: usize, i: usize) fmt.Key128 {
            return .{ .hi = 0xabc00000 + @as(u64, @intCast(writer_id)), .lo = @intCast(i) };
        }

        fn value(writer_id: usize, i: usize) [value_size]u8 {
            var out = [_]u8{0} ** value_size;
            @memset(&out, @as(u8, @intCast(writer_id * 17 + i)));
            return out;
        }

        fn writer(ctx: *@This(), writer_id: usize) void {
            var i: usize = 0;
            while (i < iterations) : (i += 1) {
                const v = value(writer_id, i);
                ctx.db.put(key(writer_id, i), &v, .{ .durability = .none }) catch {
                    ctx.errors[writer_id] = 1;
                    return;
                };
            }
        }
    };

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var db = try KvDb.openAt(tmp.dir, .{ .durability = .none, .max_delta_entries = 512 });
    defer db.close() catch unreachable;
    const tail_before = db.data.logical_tail;

    var errors = [_]u32{0} ** writer_count;
    var ctx = Ctx{ .db = &db, .errors = &errors };
    var threads: [writer_count]std.Thread = undefined;
    for (&threads, 0..) |*thread, i| thread.* = try std.Thread.spawn(.{}, Ctx.writer, .{ &ctx, i });
    for (&threads) |*thread| thread.join();
    for (errors) |err| try testing.expectEqual(@as(u32, 0), err);

    try testing.expectEqual(@as(usize, writer_count * iterations), db.pending.items.len);
    try testing.expectEqual(tail_before, db.data.logical_tail);

    try db.commitPending(.sync);
    try testing.expectEqual(@as(usize, 0), db.pending.items.len);
    try testing.expect(db.data.logical_tail > tail_before);

    var writer_id: usize = 0;
    while (writer_id < writer_count) : (writer_id += 1) {
        var i: usize = 0;
        while (i < iterations) : (i += 1) {
            var buf: [value_size]u8 = undefined;
            try testing.expectEqual(@as(usize, value_size), try db.getInto(Ctx.key(writer_id, i), &buf));
            const expected = Ctx.value(writer_id, i);
            try testing.expectEqualSlices(u8, &expected, &buf);
        }
    }
}

test "kv db concurrent readers writers overwrite delete and maintenance" {
    const testing = std.testing;
    const writer_count = 4;
    const reader_count = 4;
    const iterations = 64;
    const value_size = 32;

    const StressCtx = struct {
        db: *KvDb,
        errors: *[writer_count + reader_count]u32,

        fn key(writer_id: usize, i: usize) fmt.Key128 {
            return .{ .hi = 0xfeed0000 + @as(u64, @intCast(writer_id)), .lo = @intCast(i) };
        }

        fn fill(writer_id: usize, generation: u8) [value_size]u8 {
            var out = [_]u8{0} ** value_size;
            @memset(&out, @as(u8, @intCast(writer_id + 1)) +% generation);
            return out;
        }

        fn writer(ctx: *@This(), writer_id: usize) void {
            var i: usize = 0;
            while (i < iterations) : (i += 1) {
                const k = key(writer_id, i);
                const v1 = fill(writer_id, 0);
                const v2 = fill(writer_id, 16);
                ctx.db.put(k, &v1, .{ .durability = .none }) catch {
                    ctx.errors[writer_id] = 1;
                    return;
                };
                if (i % 3 == 0) {
                    ctx.db.put(k, &v2, .{ .durability = .none }) catch {
                        ctx.errors[writer_id] = 2;
                        return;
                    };
                }
                if (i % 7 == 0) {
                    ctx.db.delete(k, .{ .durability = .none }) catch {
                        ctx.errors[writer_id] = 3;
                        return;
                    };
                }
            }
        }

        fn reader(ctx: *@This(), reader_id: usize) void {
            var round: usize = 0;
            while (round < iterations * 4) : (round += 1) {
                const writer_id = (round + reader_id) % writer_count;
                const i = (round * 13 + reader_id * 7) % iterations;
                const k = key(writer_id, i);
                const size = ctx.db.getSize(k) catch |err| switch (err) {
                    error.NotFound => continue,
                    else => {
                        ctx.errors[writer_count + reader_id] = 10;
                        return;
                    },
                };
                if (size != value_size) {
                    ctx.errors[writer_count + reader_id] = 11;
                    return;
                }
                var buf: [value_size]u8 = undefined;
                const n = ctx.db.getInto(k, &buf) catch |err| switch (err) {
                    error.NotFound => continue,
                    else => {
                        ctx.errors[writer_count + reader_id] = 12;
                        return;
                    },
                };
                if (n != value_size) {
                    ctx.errors[writer_count + reader_id] = 13;
                    return;
                }
                const b1 = fill(writer_id, 0)[0];
                const b2 = fill(writer_id, 16)[0];
                if (buf[0] != b1 and buf[0] != b2) {
                    ctx.errors[writer_count + reader_id] = 14;
                    return;
                }
            }
        }
    };

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var db = try KvDb.openAt(tmp.dir, .{ .durability = .none, .max_delta_entries = 2048 });

    var errors = [_]u32{0} ** (writer_count + reader_count);
    var ctx = StressCtx{ .db = &db, .errors = &errors };
    var writers: [writer_count]std.Thread = undefined;
    var readers: [reader_count]std.Thread = undefined;

    for (&writers, 0..) |*thread, i| {
        thread.* = try std.Thread.spawn(.{}, StressCtx.writer, .{ &ctx, i });
    }
    for (&readers, 0..) |*thread, i| {
        thread.* = try std.Thread.spawn(.{}, StressCtx.reader, .{ &ctx, i });
    }
    for (&writers) |*thread| thread.join();
    for (&readers) |*thread| thread.join();

    for (errors) |err| try testing.expectEqual(@as(u32, 0), err);

    var writer_id: usize = 0;
    while (writer_id < writer_count) : (writer_id += 1) {
        var i: usize = 0;
        while (i < iterations) : (i += 1) {
            const k = StressCtx.key(writer_id, i);
            if (i % 7 == 0) {
                try testing.expectError(error.NotFound, db.getSize(k));
                continue;
            }
            var buf: [value_size]u8 = undefined;
            try testing.expectEqual(@as(usize, value_size), try db.getInto(k, &buf));
            const expected = StressCtx.fill(writer_id, if (i % 3 == 0) 16 else 0);
            try testing.expectEqualSlices(u8, &expected, &buf);
        }
    }

    try db.checkpoint();
    try db.optimize();
    try db.close();

    var reopened = try KvDb.openAt(tmp.dir, .{ .max_delta_entries = 2048 });
    defer reopened.close() catch unreachable;
    writer_id = 0;
    while (writer_id < writer_count) : (writer_id += 1) {
        var i: usize = 0;
        while (i < iterations) : (i += 1) {
            const k = StressCtx.key(writer_id, i);
            if (i % 7 == 0) {
                try testing.expectError(error.NotFound, reopened.getSize(k));
                continue;
            }
            var buf: [value_size]u8 = undefined;
            try testing.expectEqual(@as(usize, value_size), try reopened.getInto(k, &buf));
        }
    }
}
