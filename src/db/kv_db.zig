const std = @import("std");
const db_build_options = @import("db_build_options");
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
const sync = @import("platform/sync.zig");
const inmemory_file_ops = @import("platform/inmemory_file_ops.zig");
const KEY_LOCK_COUNT: usize = 256;

pub const OpenOptions = struct {
    durability: fmt.Durability = .sync,
    max_delta_entries: u64 = 1024,
    mode: AccessMode = .read_write,
    create_if_missing: bool = true,
    hash_fn: ?DbHashFn = null,
    hash_user_data: ?*anyopaque = null,
    file_ops: ?pf.CustomFileOps = null,
    /// Read-only stores may open extra OS handles on the data file so that
    /// concurrent positional reads are not serialized on one file object
    /// (Windows synchronous handles). 0 = single handle. Ignored unless
    /// `mode == .read_only`.
    read_handles: u8 = 0,
    /// Number of `data_NNN.db` shards to create for a brand new store. Ignored
    /// when opening an existing store (the manifest is authoritative). Must be
    /// >= 1.
    data_file_count: u32 = 1,
};

pub const MAX_DATA_FILES: u32 = 256;

pub const AccessMode = enum(u32) {
    read_only = 0,
    write_only = 1,
    read_write = 2,
};

pub const PutOptions = struct {
    durability: fmt.Durability = .sync,
    flags: u32 = 0,
    /// Target data shard. `null` = `KvDb.defaultShard(key)`.
    shard: ?u32 = null,
};

pub const DeleteOptions = struct {
    durability: fmt.Durability = .sync,
};

const PendingOp = union(enum) {
    put: struct { key: fmt.Key128, key_bytes: []u8, data: []u8, flags: u32, durability: fmt.Durability, shard: u32 },
    delete: struct { key: fmt.Key128, durability: fmt.Durability },
};

pub const DbHashFn = *const fn (?*anyopaque, ?*const anyopaque, u64, *u64, *u64) callconv(.c) c_int;

pub const KvDb = struct {
    dir: pf.Directory,
    owns_dir: bool = false,
    owned_root: []u8 = &.{},
    manifest: manifest_mod.Manifest,
    /// Shard 0 (`data_000.db`). Kept as a value so single-shard code paths
    /// and tests are unchanged.
    data: data_mod.DataFile,
    /// Shards 1..n-1 in manifest table order; `extra_data[i]` is shard `i+1`.
    extra_data: []data_mod.DataFile = &.{},
    index: *index_mod.IndexFile,
    delta: delta_mod.DeltaIndex,
    /// Active base index, mapped once at open (and re-mapped after checkpoint /
    /// optimize) instead of being mmap'ed, verified and unmapped on every
    /// lookup. `null` when the store has no base region yet.
    base: ?base_mod.BaseIndex = null,
    /// Guards base/delta mapping replacement in read-write mode. Read-only stores never
    /// replace it and skip the lock entirely.
    base_lock: sync.RwLock = .{},
    batch_counter: u64 = 1,
    key_locks: [KEY_LOCK_COUNT]std.atomic.Mutex = [_]std.atomic.Mutex{.unlocked} ** KEY_LOCK_COUNT,
    batch_lock: sync.Mutex = .{},
    pending_lock: sync.Mutex = .{},
    maintenance_lock: sync.Mutex = .{},
    pending: std.ArrayList(PendingOp) = .empty,
    mode: AccessMode = .read_write,
    hash_fn: ?DbHashFn = null,
    hash_user_data: ?*anyopaque = null,
    reopen_path: []u8 = &.{},
    reopen_options: OpenOptions = .{},
    parked: std.atomic.Value(bool) = .init(false),
    park_lock: sync.Mutex = .{},

    pub fn openAt(dir: std.Io.Dir, options: OpenOptions) !KvDb {
        return openIn(.fromOs(dir), options);
    }

    pub fn openIn(dir: pf.Directory, options: OpenOptions) !KvDb {
        if (options.data_file_count == 0 or options.data_file_count > MAX_DATA_FILES) return error.InvalidArgument;
        var man = manifest_mod.openIn(dir, "manifest.db") catch |err| switch (err) {
            error.FileNotFound => if (options.mode == .read_only or !options.create_if_missing) return err else try manifest_mod.createIn(dir, "manifest.db", .{ .initial_data_files = options.data_file_count }),
            else => |e| return e,
        };
        errdefer man.close() catch {};
        const data_options: data_mod.OpenOptions = .{
            .read_only = options.mode == .read_only,
            .read_handles = if (options.mode == .read_only) options.read_handles else 0,
        };
        const shard_count = man.dataFileCount();
        if (shard_count == 0 or shard_count > MAX_DATA_FILES) return error.Corruption;
        var data = try openOrCreateData(dir, &man, 0, data_options, options);
        errdefer data.close() catch {};
        const extra = try std.heap.smp_allocator.alloc(data_mod.DataFile, shard_count - 1);
        var extra_opened: usize = 0;
        errdefer {
            for (extra[0..extra_opened]) |*d| d.close() catch {};
            std.heap.smp_allocator.free(extra);
        }
        while (extra_opened < extra.len) : (extra_opened += 1) {
            extra[extra_opened] = try openOrCreateData(dir, &man, @intCast(extra_opened + 1), data_options, options);
        }
        const index_ptr = try std.heap.smp_allocator.create(index_mod.IndexFile);
        errdefer std.heap.smp_allocator.destroy(index_ptr);
        index_ptr.* = index_mod.openIn(dir, "index.db") catch |err| switch (err) {
            error.FileNotFound => if (options.mode == .read_only or !options.create_if_missing) return err else try index_mod.createIn(dir, "index.db", [_]u8{0} ** 16),
            else => |e| return e,
        };
        errdefer index_ptr.close() catch {};
        const delta_entries = pow2AtLeast(options.max_delta_entries);
        var delta = if (options.mode == .read_only)
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
        errdefer delta.close() catch {};
        const base = try openBaseIndex(index_ptr);
        return .{ .dir = dir, .manifest = man, .data = data, .extra_data = extra, .index = index_ptr, .delta = delta, .base = base, .mode = options.mode, .hash_fn = options.hash_fn, .hash_user_data = options.hash_user_data };
    }

    fn openOrCreateData(dir: pf.Directory, man: *const manifest_mod.Manifest, table_index: u32, data_options: data_mod.OpenOptions, options: OpenOptions) !data_mod.DataFile {
        const file_id = try man.dataFileId(table_index);
        var name_buf: [32]u8 = undefined;
        const name = try man.dataFileName(file_id, &name_buf);
        return data_mod.openIn(dir, name, data_options) catch |err| switch (err) {
            error.FileNotFound => if (options.mode == .read_only or !options.create_if_missing) return err else try data_mod.createIn(dir, name, .{ .durability = options.durability }),
            else => |e| return e,
        };
    }

    /// Number of data shards (`data_NNN.db` files) in this store.
    pub fn shardCount(self: *const KvDb) u32 {
        return @intCast(self.extra_data.len + 1);
    }

    /// Data file backing shard `id`.
    pub fn dataFile(self: *KvDb, id: u32) !*data_mod.DataFile {
        if (id == 0) return &self.data;
        if (id - 1 >= self.extra_data.len) return error.Corruption;
        return &self.extra_data[id - 1];
    }

    /// Deterministic shard for a key when the caller does not pin one.
    pub fn defaultShard(self: *const KvDb, key: fmt.Key128) u32 {
        return shardForKey(key, self.shardCount());
    }

    pub fn shardForKey(key: fmt.Key128, shard_count: u32) u32 {
        if (shard_count <= 1) return 0;
        return @intCast(fmt.mixHash128To64(key) % shard_count);
    }

    /// Same routing as `defaultShard` for a store without a custom hash_fn;
    /// lets tooling compute a key's shard without opening the store.
    pub fn shardForKeyBytes(key_bytes: []const u8, shard_count: u32) u32 {
        return shardForKey(fmt.hashBytes128(key_bytes), shard_count);
    }

    fn openBaseIndex(index: *const index_mod.IndexFile) !?base_mod.BaseIndex {
        return base_mod.open(index) catch |err| switch (err) {
            // Matches the historical lookup semantics: a missing or unreadable
            // base region behaves like an empty base.
            error.NotFound, error.Corruption => null,
            else => |e| return e,
        };
    }

    /// Re-map the active base index after checkpoint/optimize rebuilt it.
    fn refreshBase(self: *KvDb) !void {
        var fresh = try openBaseIndex(self.index);
        errdefer if (fresh) |*b| b.close();
        self.base_lock.lock();
        defer self.base_lock.unlock();
        if (self.base) |*old| old.close();
        self.base = fresh;
    }

    pub fn open(path: []const u8, options: OpenOptions) !KvDb {
        const io = std.Io.Threaded.global_single_threaded.io();
        if (options.create_if_missing) _ = std.Io.Dir.cwd().createDirPath(io, path) catch {};
        const dir = try std.Io.Dir.openDir(std.Io.Dir.cwd(), io, path, .{});
        var db = try openIn(.fromOs(dir), options);
        errdefer db.close() catch {};
        db.owns_dir = true;
        db.reopen_path = try std.heap.smp_allocator.dupe(u8, path);
        db.reopen_options = options;
        return db;
    }

    pub fn openCustom(path: []const u8, ops: pf.CustomFileOps, options: OpenOptions) !KvDb {
        const root = try std.heap.smp_allocator.dupe(u8, path);
        errdefer std.heap.smp_allocator.free(root);
        var db = try openIn(.fromCustom(root, ops), options);
        db.owned_root = root;
        return db;
    }

    pub fn close(self: *KvDb) !void {
        if (!self.isParked()) {
            if (self.canWrite()) try self.commitPending(null);
            try self.closeFiles();
        }
        self.freePending();
        self.pending.deinit(std.heap.smp_allocator);
        if (self.owned_root.len != 0) {
            std.heap.smp_allocator.free(self.owned_root);
            self.owned_root = &.{};
        }
        if (self.reopen_path.len != 0) {
            std.heap.smp_allocator.free(self.reopen_path);
            self.reopen_path = &.{};
        }
        self.parked.store(false, .release);
    }

    pub fn isParked(self: *const KvDb) bool {
        return self.parked.load(.acquire);
    }

    pub fn park(self: *KvDb) !void {
        self.park_lock.lock();
        defer self.park_lock.unlock();
        if (self.isParked()) return;
        if (self.mode != .read_only) return error.PermissionDenied;
        if (self.reopen_path.len == 0) return error.InvalidArgument;
        // Publish "parked" before the files go away so readers racing on the
        // fast path observe Busy instead of a closed handle. Callers (Volume)
        // additionally guarantee no reader is pinned while parking.
        self.parked.store(true, .seq_cst);
        self.closeFiles() catch |err| {
            self.parked.store(false, .seq_cst);
            return err;
        };
    }

    pub fn ensureReady(self: *KvDb) !void {
        if (!self.isParked()) return;
        self.park_lock.lock();
        defer self.park_lock.unlock();
        if (!self.isParked()) return;
        try self.reopenFiles();
        self.parked.store(false, .seq_cst);
    }

    fn closeFiles(self: *KvDb) !void {
        if (self.base) |*b| b.close();
        self.base = null;
        try self.delta.close();
        try self.index.close();
        std.heap.smp_allocator.destroy(self.index);
        self.index = undefined;
        try self.data.close();
        for (self.extra_data) |*d| try d.close();
        std.heap.smp_allocator.free(self.extra_data);
        self.extra_data = &.{};
        try self.manifest.close();
        if (self.owns_dir) if (self.dir.os) |dir| dir.close(std.Io.Threaded.global_single_threaded.io());
        self.owns_dir = false;
        self.dir = .{};
    }

    fn reopenFiles(self: *KvDb) !void {
        const io = std.Io.Threaded.global_single_threaded.io();
        const dir = try std.Io.Dir.openDir(std.Io.Dir.cwd(), io, self.reopen_path, .{});
        const fresh = openIn(.fromOs(dir), self.reopen_options) catch |err| {
            dir.close(io);
            return err;
        };
        self.dir = fresh.dir;
        self.owns_dir = true;
        self.manifest = fresh.manifest;
        self.data = fresh.data;
        self.extra_data = fresh.extra_data;
        self.index = fresh.index;
        self.delta = fresh.delta;
        self.base = fresh.base;
        self.mode = fresh.mode;
        self.hash_fn = fresh.hash_fn;
        self.hash_user_data = fresh.hash_user_data;
    }

    pub fn discardPending(self: *KvDb) void {
        self.pending_lock.lock();
        defer self.pending_lock.unlock();
        self.freePending();
        self.pending.clearRetainingCapacity();
    }

    /// Reads never observe staged (uncommitted) writes, so a read-write store
    /// flushes them first. A read-only store cannot have any and skips the lock.
    fn prepareRead(self: *KvDb) !void {
        try self.requireRead();
        if (self.canWrite()) try self.commitPending(null);
    }

    pub fn getSize(self: *KvDb, key: fmt.Key128) !u64 {
        try self.prepareRead();
        const info = try self.lookupInfo(key);
        return info.raw_size;
    }

    pub fn getInto(self: *KvDb, key: fmt.Key128, dst: []u8) !usize {
        try self.prepareRead();
        const info = try self.lookupInfo(key);
        return data_mod.readPayload(try self.dataFile(info.data_db_id), info.offset, key, dst);
    }

    /// Index lookup by raw key, with the stored key bytes confirmed against
    /// `key_bytes` (hash collisions report NotFound). Reads only header+key.
    pub fn lookupBytes(self: *KvDb, key_bytes: []const u8) !fmt.IndexInfo {
        const key = try self.keyFromBytes(key_bytes);
        try self.prepareRead();
        const info = try self.lookupInfo(key);
        if (key_bytes.len != 0) _ = try (try self.dataFile(info.data_db_id)).readMetaCheckKey(info.offset, key, key_bytes);
        return info;
    }

    pub fn getSizeBytes(self: *KvDb, key_bytes: []const u8) !u64 {
        const info = try self.lookupBytes(key_bytes);
        return info.raw_size;
    }

    pub fn getIntoBytes(self: *KvDb, key_bytes: []const u8, dst: []u8) !usize {
        const key = try self.keyFromBytes(key_bytes);
        try self.prepareRead();
        const info = try self.lookupInfo(key);
        if (dst.len < info.raw_size) return error.BufferTooSmall;
        const payload = try (try self.dataFile(info.data_db_id)).readRecordBorrow(info.offset, key, key_bytes, info.stored_size);
        @memcpy(dst[0..payload.len], payload);
        return payload.len;
    }

    /// Single-syscall value read. The returned slice lives in a thread-local
    /// scratch buffer and is valid until the next borrowed/positional read on
    /// the same thread. Callers that need to keep the bytes must copy them.
    pub fn getBorrowedBytes(self: *KvDb, key_bytes: []const u8) ![]const u8 {
        const key = try self.keyFromBytes(key_bytes);
        try self.prepareRead();
        const info = try self.lookupInfo(key);
        return (try self.dataFile(info.data_db_id)).readRecordBorrow(info.offset, key, key_bytes, info.stored_size);
    }

    /// Reads the raw key bytes persisted with the record that `info` points at.
    /// Returns the number of bytes written into `dst`.
    pub fn readKeyBytes(self: *KvDb, info: fmt.IndexInfo, dst: []u8) !usize {
        try self.requireRead();
        return (try self.dataFile(info.data_db_id)).readKeyBytes(info.offset, dst);
    }

    pub const LiveEntry = base_mod.BuildEntry;

    /// Every live (non-deleted, committed) key with its index entry. Reads
    /// base index + committed journal; staged (uncommitted) puts are flushed
    /// first on a writable store.
    pub fn collectLiveKeys(self: *KvDb, allocator: std.mem.Allocator) ![]LiveEntry {
        try self.prepareRead();
        self.batch_lock.lock();
        defer self.batch_lock.unlock();
        return checkpoint_mod.collectLiveEntries(self, allocator);
    }

    pub fn put(self: *KvDb, key: fmt.Key128, data: []const u8, options: PutOptions) !void {
        try self.requireWrite();
        const shard = try self.resolveShard(key, options.shard);
        const owned_key = try std.heap.smp_allocator.alloc(u8, 0);
        errdefer std.heap.smp_allocator.free(owned_key);
        const owned = try std.heap.smp_allocator.dupe(u8, data);
        errdefer std.heap.smp_allocator.free(owned);
        self.pending_lock.lock();
        defer self.pending_lock.unlock();
        try self.pending.append(std.heap.smp_allocator, .{ .put = .{ .key = key, .key_bytes = owned_key, .data = owned, .flags = options.flags, .durability = options.durability, .shard = shard } });
    }

    pub fn putBytes(self: *KvDb, key_bytes: []const u8, data: []const u8, options: PutOptions) !void {
        try self.requireWrite();
        const key = try self.keyFromBytes(key_bytes);
        const shard = try self.resolveShard(key, options.shard);
        const owned_key = try std.heap.smp_allocator.dupe(u8, key_bytes);
        errdefer std.heap.smp_allocator.free(owned_key);
        const owned_data = try std.heap.smp_allocator.dupe(u8, data);
        errdefer std.heap.smp_allocator.free(owned_data);
        self.pending_lock.lock();
        defer self.pending_lock.unlock();
        try self.pending.append(std.heap.smp_allocator, .{ .put = .{ .key = key, .key_bytes = owned_key, .data = owned_data, .flags = options.flags, .durability = options.durability, .shard = shard } });
    }

    pub fn resolveShard(self: *const KvDb, key: fmt.Key128, requested: ?u32) !u32 {
        if (requested) |s| {
            if (s >= self.shardCount()) return error.InvalidArgument;
            return s;
        }
        return self.defaultShard(key);
    }

    pub fn putNoLock(self: *KvDb, key: fmt.Key128, data: []const u8, options: PutOptions) !void {
        const shard = try self.resolveShard(key, options.shard);
        const r = try data_mod.append(try self.dataFile(shard), key, data, .{ .version = self.nextVersionNoLock(key), .durability = options.durability });
        const info = fmt.IndexInfo{ .data_db_id = shard, .flags = options.flags, .offset = r.offset, .stored_size = r.stored_size, .raw_size = r.raw_size, .version = r.version, .crc = r.crc, .codec = r.codec, .reserved = 0 };
        try self.delta.put(key, info, .{ .durability = options.durability, .data_durable = true });
    }

    pub fn delete(self: *KvDb, key: fmt.Key128, options: DeleteOptions) !void {
        try self.requireWrite();
        self.pending_lock.lock();
        defer self.pending_lock.unlock();
        try self.pending.append(std.heap.smp_allocator, .{ .delete = .{ .key = key, .durability = options.durability } });
    }

    pub fn deleteBytes(self: *KvDb, key_bytes: []const u8, options: DeleteOptions) !void {
        const key = try self.keyFromBytes(key_bytes);
        try self.delete(key, options);
    }

    pub fn deleteNoLock(self: *KvDb, key: fmt.Key128, options: DeleteOptions) !void {
        try self.delta.delete(key, .{ .durability = options.durability });
    }

    pub fn checkpoint(self: *KvDb) !void {
        try self.requireWrite();
        try self.commitPending(null);
        self.batch_lock.lock();
        defer self.batch_lock.unlock();
        self.maintenance_lock.lock();
        defer self.maintenance_lock.unlock();
        try checkpoint_mod.run(self, std.heap.smp_allocator);
        try self.refreshBase();
    }

    pub fn optimize(self: *KvDb) !void {
        try self.requireWrite();
        try self.commitPending(null);
        self.batch_lock.lock();
        defer self.batch_lock.unlock();
        self.maintenance_lock.lock();
        defer self.maintenance_lock.unlock();
        try self.optimizeNoConcurrentAccess(std.heap.smp_allocator);
        try self.refreshBase();
    }

    pub fn nextBatchId(self: *KvDb) u64 {
        self.batch_lock.lock();
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
        self.batch_lock.lock();
    }

    pub fn endBatchCommit(self: *KvDb) void {
        self.batch_lock.unlock();
    }

    pub fn keyLock(self: *KvDb, key: fmt.Key128) *std.atomic.Mutex {
        const h = fmt.mixHash128To64(key);
        return &self.key_locks[@as(usize, @intCast(h % KEY_LOCK_COUNT))];
    }

    pub fn keyFromBytes(self: *const KvDb, key_bytes: []const u8) !fmt.Key128 {
        const primary = if (self.hash_fn) |hash_fn| blk: {
            var hi: u64 = 0;
            var lo: u64 = 0;
            const ptr: ?*const anyopaque = if (key_bytes.len == 0) null else @ptrCast(key_bytes.ptr);
            const rc = hash_fn(self.hash_user_data, ptr, key_bytes.len, &hi, &lo);
            if (rc != 0) return error.InvalidArgument;
            break :blk fmt.Key128{ .hi = hi, .lo = lo };
        } else fmt.hashBytes128(key_bytes);
        if (self.hash_fn != null) {
            const discriminator = fmt.hashBytes128(key_bytes);
            return .{ .hi = primary.hi, .lo = primary.lo ^ discriminator.lo };
        }
        return primary;
    }

    pub fn getInfo(self: *KvDb, allocator: std.mem.Allocator) !DbInfo {
        self.batch_lock.lock();
        defer self.batch_lock.unlock();
        var out = DbInfo{
            .abi_version = fmt.ABI_VERSION,
            .format_version = fmt.FORMAT_VERSION,
            .open_mode = @intFromEnum(self.mode),
            .feature_flags = 0x1,
            .key_count = 0,
            .value_count = 0,
            .data_bytes = blk: {
                var total: u64 = pf.len(self.data.file) catch 0;
                for (self.extra_data) |*d| total += pf.len(d.file) catch 0;
                break :blk total;
            },
            .index_bytes = pf.len(self.index.file) catch 0,
            .delta_entries = self.delta.used_slots,
            .pending_ops = 0,
            .free_bytes = 0,
            .tail_free_bytes = 0,
            .mmap_index_bytes = pf.len(self.index.file) catch 0,
        };
        self.pending_lock.lock();
        out.pending_ops = self.pending.items.len;
        self.pending_lock.unlock();
        if (data_mod.currentSuper(&self.data)) |sb| {
            out.free_bytes = sb.free_bytes;
            out.tail_free_bytes = sb.tail_free_bytes;
        } else |_| {}
        if (checkpoint_mod.collectLiveEntries(self, allocator)) |entries| {
            out.key_count = entries.len;
            out.value_count = entries.len;
            allocator.free(entries);
        } else |_| {}
        return out;
    }

    pub fn commitPending(self: *KvDb, durability_override: ?fmt.Durability) !void {
        self.pending_lock.lock();
        if (self.pending.items.len == 0) {
            self.pending_lock.unlock();
            return;
        }
        self.pending_lock.unlock();

        self.batch_lock.lock();
        defer self.batch_lock.unlock();
        self.pending_lock.lock();
        defer self.pending_lock.unlock();
        if (self.pending.items.len == 0) return;
        try self.requireWrite();
        try self.reserveCommit(@intCast(self.pending.items.len));

        const batch_id = self.nextBatchIdNoLock();
        const durability = durability_override orelse pendingMaxDurability(self.pending.items);
        _ = try self.delta.journal.appendBatchBegin(batch_id, .{ .durability = .none, .defer_header = true });
        errdefer _ = self.delta.journal.appendBatchAbort(batch_id, .{ .durability = durability }) catch {};

        var data_inputs = std.ArrayList(ShardedAppendInput).empty;
        defer data_inputs.deinit(std.heap.smp_allocator);
        for (self.pending.items) |op| switch (op) {
            .put => |p| try data_inputs.append(std.heap.smp_allocator, .{
                .shard = p.shard,
                .input = .{
                    .key = p.key,
                    .key_bytes = p.key_bytes,
                    .payload = p.data,
                    .options = .{ .version = self.nextVersionNoLock(p.key), .durability = .none, .defer_superblock = true },
                },
            }),
            .delete => {},
        };
        var appended = try self.appendSharded(std.heap.smp_allocator, data_inputs.items);
        defer appended.deinit(std.heap.smp_allocator);

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
                const r = appended.results[put_i];
                put_i += 1;
                const info = fmt.IndexInfo{ .data_db_id = p.shard, .flags = p.flags, .offset = r.offset, .stored_size = r.stored_size, .raw_size = r.raw_size, .version = r.version, .crc = r.crc, .codec = r.codec, .reserved = 0 };
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
        try self.flushShardsForCommit(appended.touched_shards, durability);
        _ = try self.delta.journal.appendBatchCommit(batch_id, .{ .durability = durability });
        try self.delta.publishCommittedMany(published.items);
        self.freePending();
        self.pending.clearRetainingCapacity();
    }

    /// Called with batch_lock held, before writing any part of the new batch.
    /// Checkpoint only committed state, then reserve the entire atomic batch.
    pub fn reserveCommit(self: *KvDb, operations: u64) !void {
        const record_count = try std.math.add(u64, operations, 2);
        const journal_bytes = try std.math.mul(u64, record_count, journal_mod.JOURNAL_RECORD_SIZE);
        const slots_needed = try std.math.add(u64, self.delta.used_slots, operations);
        const slot_limit = self.delta.journal.header.slot_count / 10 * 7 + self.delta.journal.header.slot_count % 10 * 7 / 10;
        if (slots_needed <= slot_limit and journal_bytes <= self.delta.journal.header.journal_size - self.delta.journal.header.journal_tail) return;

        var slots = self.delta.journal.header.slot_count;
        while (operations > slots / 10 * 7 + slots % 10 * 7 / 10) {
            slots = try std.math.mul(u64, slots, 2);
        }
        const journal_size = @max(self.delta.journal.header.journal_size, journal_bytes);
        self.maintenance_lock.lock();
        defer self.maintenance_lock.unlock();
        self.base_lock.lock();
        defer self.base_lock.unlock();

        // Publishing the new base first is safe: replaying the old delta over
        // that base is idempotent. Never activate the empty delta first.
        // Existing commits have already published shard superblocks. Flush
        // those writes without reading tails that concurrent batch appends own.
        try pf.flushMetadata(self.data.file);
        for (self.extra_data) |*data| try pf.flushMetadata(data.file);
        try checkpoint_mod.run(self, std.heap.smp_allocator);
        var fresh_base = try base_mod.open(self.index);
        errdefer fresh_base.close();
        const fresh_delta = try delta_mod.create(self.index, slots, journal_size);
        // Activation has completed; swapping and disposing must not fail.
        self.delta.unmap();
        if (self.base) |*base| base.close();
        self.delta = fresh_delta;
        self.base = fresh_base;
    }

    pub const ShardedAppendInput = struct {
        shard: u32,
        input: data_mod.BatchAppendInput,
    };

    pub const ShardedAppendResult = struct {
        /// Aligned with the input slice order.
        results: []data_mod.AppendResult,
        /// Bitmask-like list of shards that received at least one record.
        touched_shards: []u32,

        pub fn deinit(self: *ShardedAppendResult, allocator: std.mem.Allocator) void {
            allocator.free(self.results);
            allocator.free(self.touched_shards);
            self.* = undefined;
        }
    };

    /// Groups records by shard and appends each group to its data file.
    /// Only each data file's own `append_mutex` is taken, so callers that
    /// target disjoint shards proceed in parallel. Records are not yet
    /// indexed; the caller must journal + publish them afterwards.
    pub fn appendSharded(self: *KvDb, allocator: std.mem.Allocator, inputs: []const ShardedAppendInput) !ShardedAppendResult {
        const results = try allocator.alloc(data_mod.AppendResult, inputs.len);
        errdefer allocator.free(results);
        var touched = std.ArrayList(u32).empty;
        errdefer touched.deinit(allocator);
        if (inputs.len == 0) return .{ .results = results, .touched_shards = try touched.toOwnedSlice(allocator) };

        const n = self.shardCount();
        var shard: u32 = 0;
        while (shard < n) : (shard += 1) {
            var group = std.ArrayList(data_mod.BatchAppendInput).empty;
            defer group.deinit(allocator);
            var positions = std.ArrayList(usize).empty;
            defer positions.deinit(allocator);
            var prealloc_bytes: u64 = 0;
            for (inputs, 0..) |in, i| {
                if (in.shard != shard) continue;
                try group.append(allocator, in.input);
                try positions.append(allocator, i);
                const total = @as(u64, data_mod.RECORD_HEADER_SIZE) + in.input.key_bytes.len + in.input.payload.len + data_mod.RECORD_FOOTER_SIZE;
                prealloc_bytes += try fmt.alignUp(total, data_mod.RECORD_ALIGNMENT);
            }
            if (group.items.len == 0) continue;
            const file = try self.dataFile(shard);
            if (prealloc_bytes != 0) pf.preallocate(file.file, file.logical_tail, prealloc_bytes) catch {};
            const group_results = try data_mod.appendBatch(file, allocator, group.items);
            defer allocator.free(group_results);
            for (group_results, positions.items) |r, pos| results[pos] = r;
            try touched.append(allocator, shard);
        }
        return .{ .results = results, .touched_shards = try touched.toOwnedSlice(allocator) };
    }

    pub fn flushDataForCommit(self: *KvDb, durability: fmt.Durability) !void {
        try data_mod.publishSuper(&self.data, durability);
        for (self.extra_data) |*d| try data_mod.publishSuper(d, durability);
    }

    pub fn flushShardsForCommit(self: *KvDb, shards: []const u32, durability: fmt.Durability) !void {
        for (shards) |s| try data_mod.publishSuper(try self.dataFile(s), durability);
    }

    fn freePending(self: *KvDb) void {
        for (self.pending.items) |op| switch (op) {
            .put => |p| {
                std.heap.smp_allocator.free(p.key_bytes);
                std.heap.smp_allocator.free(p.data);
            },
            .delete => {},
        };
    }

    fn lookupMetaNoLock(self: *KvDb, key: fmt.Key128) !data_mod.RecordMeta {
        const info = try self.lookupInfo(key);
        return data_mod.readMeta(try self.dataFile(info.data_db_id), info.offset);
    }

    /// delta first, then the cached base index. Lock-free for read-only stores;
    /// a read-write store takes `base_lock` shared so checkpoint/optimize can
    /// swap the mapping underneath concurrent readers.
    fn lookupInfo(self: *KvDb, key: fmt.Key128) !fmt.IndexInfo {
        if (self.mode != .read_only) self.base_lock.lockShared();
        defer if (self.mode != .read_only) self.base_lock.unlockShared();
        return self.lookupInfoUnlocked(key);
    }

    fn lookupInfoUnlocked(self: *KvDb, key: fmt.Key128) !fmt.IndexInfo {
        switch (try self.delta.lookup(key)) {
            .found => |info| return info,
            .deleted => return error.NotFound,
            .not_found => {},
        }
        const base = &(self.base orelse return error.NotFound);
        return base.lookup(key);
    }

    pub const KeyState = enum { live, deleted, unknown };

    /// What the index knows about `key`: a live entry, a delete tombstone
    /// (not yet checkpointed away), or nothing. Verification uses this to
    /// tell superseded/deleted records (normal garbage) from orphans.
    pub fn keyState(self: *KvDb, key: fmt.Key128) !KeyState {
        if (self.mode != .read_only) self.base_lock.lockShared();
        defer if (self.mode != .read_only) self.base_lock.unlockShared();
        switch (try self.delta.lookup(key)) {
            .found => return .live,
            .deleted => return .deleted,
            .not_found => {},
        }
        const info = self.lookupInfoUnlocked(key) catch |e| switch (e) {
            error.NotFound => return .unknown,
            else => |err| return err,
        };
        _ = info;
        return .live;
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
        if (self.isParked()) return error.Busy;
        if (!self.canRead()) return error.PermissionDenied;
    }

    fn optimizeNoConcurrentAccess(self: *KvDb, allocator: std.mem.Allocator) !void {
        const live_entries = try checkpoint_mod.collectLiveEntries(self, allocator);
        defer allocator.free(live_entries);

        var seen_live_total: usize = 0;
        var shard: u32 = 0;
        while (shard < self.shardCount()) : (shard += 1) {
            seen_live_total += try self.optimizeShard(allocator, shard, live_entries);
        }
        if (seen_live_total != live_entries.len) return error.Corruption;

        _ = try base_mod.build(self.index, allocator, live_entries);
        const slot_count = self.delta.journal.header.slot_count;
        const journal_size = self.delta.journal.header.journal_size;
        var fresh_delta = try delta_mod.create(self.index, slot_count, journal_size);
        errdefer fresh_delta.close() catch {};
        try self.delta.close();
        self.delta = fresh_delta;
    }

    /// Rebuilds the free list / tail of one data shard. Returns how many live
    /// entries were found in it.
    fn optimizeShard(self: *KvDb, allocator: std.mem.Allocator, shard: u32, live_entries: []const base_mod.BuildEntry) !usize {
        const data = try self.dataFile(shard);
        var live_offsets = std.AutoHashMap(u64, void).init(allocator);
        defer live_offsets.deinit();
        for (live_entries) |entry| if (entry.info.data_db_id == shard) try live_offsets.put(entry.info.offset, {});

        var free_blocks = std.ArrayList(alloc_mod.Block).empty;
        defer free_blocks.deinit(allocator);

        var seen_live: usize = 0;
        var off = data_mod.RECORD_AREA_OFFSET;
        while (off < data.logical_tail) {
            const meta = try data_mod.verifyRecord(data, off);
            if (live_offsets.contains(off)) {
                seen_live += 1;
            } else {
                try free_blocks.append(allocator, .{ .offset = off, .size = meta.aligned_size });
            }
            off += meta.aligned_size;
        }
        if (off != data.logical_tail or seen_live != live_offsets.count()) return error.Corruption;

        var free_len = coalesceBlocks(free_blocks.items);
        free_blocks.shrinkRetainingCapacity(free_len);
        var new_tail = data.logical_tail;
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
        data_allocator.epoch.current = data.epoch + 1;
        for (free_blocks.items) |b| try data_allocator.free.append(allocator, b);

        if (new_tail != data.logical_tail) {
            try pf.setLen(data.file, new_tail);
            try pf.flushMetadata(data.file);
            data.logical_tail = new_tail;
        }
        data.epoch += 1;
        var alloc_super = data_mod.AllocatorSuper{
            .checkpoint_offset = 0,
            .checkpoint_size = 0,
            .checkpoint_epoch = data_allocator.epoch.current,
            .free_bytes = free_bytes,
            .pending_free_bytes = 0,
            .tail_free_bytes = tail_free_bytes,
        };
        if (checkpoint_size != 0) {
            try data_allocator.writeCheckpoint(data.file, data_mod.ALLOCATOR_CHECKPOINT_OFFSET);
            alloc_super.checkpoint_offset = data_mod.ALLOCATOR_CHECKPOINT_OFFSET;
            alloc_super.checkpoint_size = checkpoint_size;
        }
        try data_mod.publishSuperWithAllocator(data, .sync, alloc_super);
        return seen_live;
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

pub const DbInfo = struct {
    abi_version: u32,
    format_version: u32,
    open_mode: u32,
    feature_flags: u64,
    key_count: u64,
    value_count: u64,
    data_bytes: u64,
    index_bytes: u64,
    delta_entries: u64,
    pending_ops: u64,
    free_bytes: u64,
    tail_free_bytes: u64,
    mmap_index_bytes: u64,
};

pub const db_open_options_t = extern struct {
    struct_size: u32,
    flags: u32,
    durability: u32,
    reserved0: u32,
    max_delta_entries: u64,
    data_file_target_size: u64,
    /// Number of data shards to create (create only). 0 = 1.
    data_file_count: u32,
    reserved1: u32,
};

pub const db_file_ops_t = extern struct {
    struct_size: u32,
    version: u32,
    user_data: ?*anyopaque,
    open: ?*const anyopaque,
    close: ?*const anyopaque,
    read_at: ?*const anyopaque,
    write_at: ?*const anyopaque,
    get_size: ?*const anyopaque,
    set_size: ?*const anyopaque,
    sync: ?*const anyopaque,
    preallocate: ?*const anyopaque,
    mmap: ?*const anyopaque,
    msync: ?*const anyopaque,
    munmap: ?*const anyopaque,
};

pub const db_context_t = extern struct {
    struct_size: u32,
    version: u32,
    user_data: ?*anyopaque,
    hash_fn: ?DbHashFn,
    file_ops: ?*const db_file_ops_t,
};

pub const db_info_t = extern struct {
    struct_size: u32,
    abi_version: u32,
    format_version: u32,
    open_mode: u32,
    feature_flags: u64,
    key_count: u64,
    value_count: u64,
    data_bytes: u64,
    index_bytes: u64,
    delta_entries: u64,
    pending_ops: u64,
    free_bytes: u64,
    tail_free_bytes: u64,
    mmap_index_bytes: u64,
};

pub const HandleKind = enum(u8) { db, batch, snapshot };
pub const handle_registry = @import("handle_registry.zig").Registry(HandleKind, 1);
pub const HandleLease = handle_registry.Lease(KvDb);

threadlocal var last_status: c_int = @intFromEnum(fmt.DbStatus.ok);
threadlocal var last_error: [256]u8 = [_]u8{0} ** 256;

fn toStatus(err: anyerror) c_int {
    return @intFromEnum(fmt.statusFromError(err));
}

pub fn setLastStatus(status: fmt.DbStatus, msg: []const u8) c_int {
    last_status = @intFromEnum(status);
    @memset(&last_error, 0);
    const n = @min(msg.len, last_error.len - 1);
    @memcpy(last_error[0..n], msg[0..n]);
    return last_status;
}

pub fn setLastError(err: anyerror) c_int {
    return setLastStatus(fmt.statusFromError(err), @errorName(err));
}

pub fn setOk() c_int {
    return setLastStatus(.ok, "ok");
}

pub const registerHandle = handle_registry.register;
pub const acquireHandle = handle_registry.acquire;
pub const takeHandle = handle_registry.take;

pub fn keySlice(ptr: ?*const anyopaque, size: u64) ![]const u8 {
    const len = std.math.cast(usize, size) orelse return error.InvalidArgument;
    if (len == 0) return &.{};
    const p = ptr orelse return error.InvalidArgument;
    return @as([*]const u8, @ptrCast(p))[0..len];
}

pub fn mutSlice(ptr: ?*anyopaque, size: u64) ![]u8 {
    const len = std.math.cast(usize, size) orelse return error.InvalidArgument;
    if (len == 0) return &.{};
    const p = ptr orelse return error.InvalidArgument;
    return @as([*]u8, @ptrCast(p))[0..len];
}

pub fn dataSlice(ptr: ?*const anyopaque, size: u64) ![]const u8 {
    const len = std.math.cast(usize, size) orelse return error.InvalidArgument;
    if (len == 0) return &.{};
    const p = ptr orelse return error.InvalidArgument;
    return @as([*]const u8, @ptrCast(p))[0..len];
}

fn fieldFits(comptime T: type, comptime field: []const u8, len: usize) bool {
    inline for (@typeInfo(T).@"struct".fields) |f| {
        if (std.mem.eql(u8, f.name, field)) {
            return @offsetOf(T, field) + @sizeOf(f.type) <= len;
        }
    }
    unreachable;
}

fn optionsFromC(options: ?*const db_open_options_t, context: ?*const db_context_t, create_if_missing: bool) !OpenOptions {
    var custom_file_ops: ?pf.CustomFileOps = null;
    var hash_fn: ?DbHashFn = null;
    var hash_user_data: ?*anyopaque = null;
    if (context) |ctx| {
        if (ctx.struct_size < @offsetOf(db_context_t, "file_ops") + @sizeOf(?*const db_file_ops_t)) return error.InvalidArgument;
        if (ctx.version != 1) return error.UnsupportedVersion;
        hash_fn = ctx.hash_fn;
        hash_user_data = ctx.user_data;
        if (ctx.file_ops) |ops| {
            custom_file_ops = try pf.customOpsFromRaw(@ptrCast(ops));
        }
    }
    const o = options orelse return .{ .create_if_missing = create_if_missing, .hash_fn = hash_fn, .hash_user_data = hash_user_data, .file_ops = custom_file_ops };
    const data_file_count: u32 = if (fieldFits(db_open_options_t, "data_file_count", o.struct_size) and o.data_file_count != 0) o.data_file_count else 1;
    return .{ .durability = switch (o.durability) {
        0 => .none,
        1 => .async,
        2 => .sync,
        else => .sync,
    }, .max_delta_entries = if (o.max_delta_entries == 0) 1024 else o.max_delta_entries, .mode = switch (o.flags & 0x3) {
        1 => .read_only,
        2 => .write_only,
        else => .read_write,
    }, .create_if_missing = create_if_missing, .hash_fn = hash_fn, .hash_user_data = hash_user_data, .file_ops = custom_file_ops, .data_file_count = data_file_count };
}

fn openImpl(path: [*:0]const u8, options: ?*const db_open_options_t, context: ?*const db_context_t, create_if_missing: bool) u64 {
    const p = std.mem.span(path);
    const opts = optionsFromC(options, context, create_if_missing) catch |err| {
        _ = setLastError(err);
        return 0;
    };
    const db = std.heap.smp_allocator.create(KvDb) catch {
        _ = setLastStatus(.no_space, "allocation failed");
        return 0;
    };
    db.* = if (opts.file_ops) |ops|
        KvDb.openCustom(p, ops, opts) catch |err| {
            std.heap.smp_allocator.destroy(db);
            _ = setLastError(err);
            return 0;
        }
    else
        KvDb.open(p, opts) catch |err| {
            std.heap.smp_allocator.destroy(db);
            _ = setLastError(err);
            return 0;
        };
    const h = registerHandle(db, .db) catch |err| {
        db.close() catch {};
        std.heap.smp_allocator.destroy(db);
        _ = setLastError(err);
        return 0;
    };
    _ = setOk();
    return h;
}

pub fn db_create(path: [*:0]const u8, options: ?*const db_open_options_t, context: ?*const db_context_t) callconv(.c) u64 {
    return openImpl(path, options, context, true);
}

pub fn db_open(path: [*:0]const u8, options: ?*const db_open_options_t, context: ?*const db_context_t) callconv(.c) u64 {
    return openImpl(path, options, context, false);
}

pub fn db_close(handle: u64) callconv(.c) c_int {
    const d = handle_registry.takeIdle(KvDb, handle, .db) catch |err| return setLastError(err);
    d.close() catch |err| {
        std.heap.smp_allocator.destroy(d);
        return setLastError(err);
    };
    std.heap.smp_allocator.destroy(d);
    return setOk();
}

pub fn db_last_status() callconv(.c) c_int {
    return last_status;
}

pub fn db_last_error_message() callconv(.c) [*:0]const u8 {
    return @ptrCast(&last_error);
}

pub fn db_get_info(handle: u64, out_info: ?*db_info_t) callconv(.c) c_int {
    const retained = acquireHandle(KvDb, handle, .db) catch |err| return setLastError(err);
    defer retained.release();
    const d = retained.ptr;
    const out = out_info orelse return setLastStatus(.invalid_argument, "out_info is null");
    const got = d.getInfo(std.heap.smp_allocator) catch |err| return setLastError(err);
    const requested = out.struct_size;
    if (requested < @sizeOf(u32)) return setLastStatus(.invalid_argument, "db_info_t struct_size is too small");
    const fill_len = @min(@as(usize, @intCast(requested)), @sizeOf(db_info_t));
    @memset(@as([*]u8, @ptrCast(out))[0..fill_len], 0);
    out.struct_size = requested;
    if (fieldFits(db_info_t, "abi_version", fill_len)) out.abi_version = got.abi_version;
    if (fieldFits(db_info_t, "format_version", fill_len)) out.format_version = got.format_version;
    if (fieldFits(db_info_t, "open_mode", fill_len)) out.open_mode = got.open_mode;
    if (fieldFits(db_info_t, "feature_flags", fill_len)) out.feature_flags = got.feature_flags;
    if (fieldFits(db_info_t, "key_count", fill_len)) out.key_count = got.key_count;
    if (fieldFits(db_info_t, "value_count", fill_len)) out.value_count = got.value_count;
    if (fieldFits(db_info_t, "data_bytes", fill_len)) out.data_bytes = got.data_bytes;
    if (fieldFits(db_info_t, "index_bytes", fill_len)) out.index_bytes = got.index_bytes;
    if (fieldFits(db_info_t, "delta_entries", fill_len)) out.delta_entries = got.delta_entries;
    if (fieldFits(db_info_t, "pending_ops", fill_len)) out.pending_ops = got.pending_ops;
    if (fieldFits(db_info_t, "free_bytes", fill_len)) out.free_bytes = got.free_bytes;
    if (fieldFits(db_info_t, "tail_free_bytes", fill_len)) out.tail_free_bytes = got.tail_free_bytes;
    if (fieldFits(db_info_t, "mmap_index_bytes", fill_len)) out.mmap_index_bytes = got.mmap_index_bytes;
    return setOk();
}

pub fn db_get_size(handle: u64, key: ?*const anyopaque, key_size: u64, out_size: ?*u64) callconv(.c) c_int {
    const retained = acquireHandle(KvDb, handle, .db) catch |err| return setLastError(err);
    defer retained.release();
    const d = retained.ptr;
    const out = out_size orelse return setLastStatus(.invalid_argument, "out_size is null");
    const k = keySlice(key, key_size) catch |err| return setLastError(err);
    out.* = d.getSizeBytes(k) catch |err| return setLastError(err);
    return setOk();
}

pub fn db_get_into(handle: u64, key: ?*const anyopaque, key_size: u64, dst: ?*anyopaque, dst_size: u64, out_written: ?*u64) callconv(.c) c_int {
    const retained = acquireHandle(KvDb, handle, .db) catch |err| return setLastError(err);
    defer retained.release();
    const d = retained.ptr;
    const out = out_written orelse return setLastStatus(.invalid_argument, "out_written is null");
    const k = keySlice(key, key_size) catch |err| return setLastError(err);
    const slice = mutSlice(dst, dst_size) catch |err| return setLastError(err);
    out.* = d.getIntoBytes(k, slice) catch |err| return setLastError(err);
    return setOk();
}

pub fn db_put(handle: u64, key: ?*const anyopaque, key_size: u64, data: ?*const anyopaque, size: u64, flags: u32) callconv(.c) c_int {
    const retained = acquireHandle(KvDb, handle, .db) catch |err| return setLastError(err);
    defer retained.release();
    const d = retained.ptr;
    const k = keySlice(key, key_size) catch |err| return setLastError(err);
    const slice = dataSlice(data, size) catch |err| return setLastError(err);
    d.putBytes(k, slice, .{ .flags = flags }) catch |err| return setLastError(err);
    return setOk();
}

pub fn db_delete(handle: u64, key: ?*const anyopaque, key_size: u64) callconv(.c) c_int {
    const retained = acquireHandle(KvDb, handle, .db) catch |err| return setLastError(err);
    defer retained.release();
    const d = retained.ptr;
    const k = keySlice(key, key_size) catch |err| return setLastError(err);
    d.deleteBytes(k, .{}) catch |err| return setLastError(err);
    return setOk();
}

comptime {
    if (db_build_options.enable_abi_exports) {
        @export(&db_create, .{ .name = "db_create" });
        @export(&db_open, .{ .name = "db_open" });
        @export(&db_close, .{ .name = "db_close" });
        @export(&db_last_status, .{ .name = "db_last_status" });
        @export(&db_last_error_message, .{ .name = "db_last_error_message" });
        @export(&db_get_info, .{ .name = "db_get_info" });
        @export(&db_get_size, .{ .name = "db_get_size" });
        @export(&db_get_into, .{ .name = "db_get_into" });
        @export(&db_put, .{ .name = "db_put" });
        @export(&db_delete, .{ .name = "db_delete" });
    }
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

test "c abi v2 handle raw key custom hash collision get info and unsupported file ops" {
    const testing = std.testing;
    const io = std.Io.Threaded.global_single_threaded.io();
    const path: [:0]const u8 = "zig-cache/db_abi_v2_unit";
    _ = std.Io.Dir.cwd().deleteTree(io, path) catch {};
    defer _ = std.Io.Dir.cwd().deleteTree(io, path) catch {};

    var bad_size: u64 = 0;
    try testing.expectEqual(@as(c_int, @intFromEnum(fmt.DbStatus.invalid_argument)), db_get_size(12345, "x", 1, &bad_size));

    const missing = db_open(path.ptr, null, null);
    try testing.expectEqual(@as(u64, 0), missing);
    try testing.expectEqual(@as(c_int, @intFromEnum(fmt.DbStatus.not_found)), db_last_status());

    const db = db_create(path.ptr, null, null);
    try testing.expect(db != 0);
    const key = [_]u8{ 'a', 0, 'b' };
    try testing.expectEqual(@as(c_int, @intFromEnum(fmt.DbStatus.ok)), db_put(db, &key, key.len, "value", 5, 0));
    var size: u64 = 0;
    try testing.expectEqual(@as(c_int, @intFromEnum(fmt.DbStatus.ok)), db_get_size(db, &key, key.len, &size));
    try testing.expectEqual(@as(u64, 5), size);
    var buf: [16]u8 = undefined;
    var written: u64 = 0;
    try testing.expectEqual(@as(c_int, @intFromEnum(fmt.DbStatus.ok)), db_get_into(db, &key, key.len, &buf, buf.len, &written));
    try testing.expectEqual(@as(u64, 5), written);
    try testing.expectEqualStrings("value", buf[0..5]);
    var inf = db_info_t{ .struct_size = @sizeOf(db_info_t), .abi_version = 0, .format_version = 0, .open_mode = 0, .feature_flags = 0, .key_count = 0, .value_count = 0, .data_bytes = 0, .index_bytes = 0, .delta_entries = 0, .pending_ops = 0, .free_bytes = 0, .tail_free_bytes = 0, .mmap_index_bytes = 0 };
    try testing.expectEqual(@as(c_int, @intFromEnum(fmt.DbStatus.ok)), db_get_info(db, &inf));
    try testing.expectEqual(fmt.ABI_VERSION, inf.abi_version);
    try testing.expect(inf.data_bytes > 0);
    try testing.expectEqual(@as(c_int, @intFromEnum(fmt.DbStatus.ok)), db_close(db));

    const db2 = db_open(path.ptr, null, null);
    try testing.expect(db2 != 0);
    try testing.expectEqual(@as(c_int, @intFromEnum(fmt.DbStatus.ok)), db_get_into(db2, &key, key.len, &buf, buf.len, &written));
    try testing.expectEqualStrings("value", buf[0..5]);
    try testing.expectEqual(@as(c_int, @intFromEnum(fmt.DbStatus.ok)), db_close(db2));

    const collide_path: [:0]const u8 = "zig-cache/db_abi_v2_collision";
    _ = std.Io.Dir.cwd().deleteTree(io, collide_path) catch {};
    defer _ = std.Io.Dir.cwd().deleteTree(io, collide_path) catch {};
    const S = struct {
        fn hash(_: ?*anyopaque, _: ?*const anyopaque, _: u64, out_hi: *u64, out_lo: *u64) callconv(.c) c_int {
            out_hi.* = 0xaaaa;
            out_lo.* = 0xbbbb;
            return 0;
        }
    };
    const ctx = db_context_t{ .struct_size = @sizeOf(db_context_t), .version = 1, .user_data = null, .hash_fn = S.hash, .file_ops = null };
    const cdb = db_create(collide_path.ptr, null, &ctx);
    try testing.expect(cdb != 0);
    try testing.expectEqual(@as(c_int, @intFromEnum(fmt.DbStatus.ok)), db_put(cdb, "same-hash-A", 11, "A", 1, 0));
    try testing.expectEqual(@as(c_int, @intFromEnum(fmt.DbStatus.ok)), db_put(cdb, "same-hash-B", 11, "B", 1, 0));
    try testing.expectEqual(@as(c_int, @intFromEnum(fmt.DbStatus.ok)), db_get_into(cdb, "same-hash-A", 11, &buf, buf.len, &written));
    try testing.expectEqualStrings("A", buf[0..1]);
    try testing.expectEqual(@as(c_int, @intFromEnum(fmt.DbStatus.ok)), db_get_into(cdb, "same-hash-B", 11, &buf, buf.len, &written));
    try testing.expectEqualStrings("B", buf[0..1]);
    try testing.expectEqual(@as(c_int, @intFromEnum(fmt.DbStatus.ok)), db_delete(cdb, "same-hash-A", 11));
    try testing.expectEqual(@as(c_int, @intFromEnum(fmt.DbStatus.not_found)), db_get_size(cdb, "same-hash-A", 11, &size));
    try testing.expectEqual(@as(c_int, @intFromEnum(fmt.DbStatus.ok)), db_get_into(cdb, "same-hash-B", 11, &buf, buf.len, &written));
    try testing.expectEqualStrings("B", buf[0..1]);
    try testing.expectEqual(@as(c_int, @intFromEnum(fmt.DbStatus.ok)), db_close(cdb));

    var ops = db_file_ops_t{ .struct_size = @sizeOf(db_file_ops_t), .version = 1, .user_data = null, .open = null, .close = null, .read_at = null, .write_at = null, .get_size = null, .set_size = null, .sync = null, .preallocate = null, .mmap = null, .msync = null, .munmap = null };
    const invalid_ctx = db_context_t{ .struct_size = @sizeOf(db_context_t), .version = 1, .user_data = null, .hash_fn = null, .file_ops = &ops };
    try testing.expectEqual(@as(u64, 0), db_create("zig-cache/db_abi_v2_invalid_file_ops", null, &invalid_ctx));
    try testing.expectEqual(@as(c_int, @intFromEnum(fmt.DbStatus.invalid_argument)), db_last_status());
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

test "c abi custom InMemoryFileOps writeback and mmap capability" {
    const testing = std.testing;
    const io = std.Io.Threaded.global_single_threaded.io();

    const path1: [:0]const u8 = "zig-cache/db_inmemory_file_ops_new";
    _ = std.Io.Dir.cwd().deleteTree(io, path1) catch {};
    defer _ = std.Io.Dir.cwd().deleteTree(io, path1) catch {};

    var fs1 = inmemory_file_ops.FileSystem.init(std.heap.smp_allocator, true);
    defer fs1.deinit();
    var raw1 = fs1.rawOps();
    const ctx1 = db_context_t{ .struct_size = @sizeOf(db_context_t), .version = 1, .user_data = null, .hash_fn = null, .file_ops = @ptrCast(&raw1) };
    const mem_db = db_create(path1.ptr, null, &ctx1);
    try testing.expect(mem_db != 0);
    try testing.expectEqual(@as(c_int, @intFromEnum(fmt.DbStatus.ok)), db_put(mem_db, "key", 3, "memory-value", 12, 0));
    try testing.expectEqual(@as(c_int, @intFromEnum(fmt.DbStatus.ok)), db_close(mem_db));

    const disk_db = db_open(path1.ptr, null, null);
    try testing.expect(disk_db != 0);
    var buf: [32]u8 = undefined;
    var written: u64 = 0;
    try testing.expectEqual(@as(c_int, @intFromEnum(fmt.DbStatus.ok)), db_get_into(disk_db, "key", 3, &buf, buf.len, &written));
    try testing.expectEqual(@as(u64, 12), written);
    try testing.expectEqualStrings("memory-value", buf[0..12]);
    try testing.expectEqual(@as(c_int, @intFromEnum(fmt.DbStatus.ok)), db_close(disk_db));

    const path2: [:0]const u8 = "zig-cache/db_inmemory_file_ops_modify";
    _ = std.Io.Dir.cwd().deleteTree(io, path2) catch {};
    defer _ = std.Io.Dir.cwd().deleteTree(io, path2) catch {};
    const base_db = db_create(path2.ptr, null, null);
    try testing.expect(base_db != 0);
    try testing.expectEqual(@as(c_int, @intFromEnum(fmt.DbStatus.ok)), db_put(base_db, "key", 3, "base", 4, 0));
    try testing.expectEqual(@as(c_int, @intFromEnum(fmt.DbStatus.ok)), db_close(base_db));

    var fs2 = inmemory_file_ops.FileSystem.init(std.heap.smp_allocator, true);
    defer fs2.deinit();
    var raw2 = fs2.rawOps();
    const ctx2 = db_context_t{ .struct_size = @sizeOf(db_context_t), .version = 1, .user_data = null, .hash_fn = null, .file_ops = @ptrCast(&raw2) };
    const edit_db = db_open(path2.ptr, null, &ctx2);
    try testing.expect(edit_db != 0);
    try testing.expectEqual(@as(c_int, @intFromEnum(fmt.DbStatus.ok)), db_put(edit_db, "key", 3, "edited", 6, 0));
    try testing.expectEqual(@as(c_int, @intFromEnum(fmt.DbStatus.ok)), db_close(edit_db));

    const check_db = db_open(path2.ptr, null, null);
    try testing.expect(check_db != 0);
    try testing.expectEqual(@as(c_int, @intFromEnum(fmt.DbStatus.ok)), db_get_into(check_db, "key", 3, &buf, buf.len, &written));
    try testing.expectEqualStrings("edited", buf[0..6]);
    try testing.expectEqual(@as(c_int, @intFromEnum(fmt.DbStatus.ok)), db_close(check_db));

    const path3: [:0]const u8 = "zig-cache/db_inmemory_file_ops_missing_mmap";
    _ = std.Io.Dir.cwd().deleteTree(io, path3) catch {};
    defer _ = std.Io.Dir.cwd().deleteTree(io, path3) catch {};
    var fs3 = inmemory_file_ops.FileSystem.init(std.heap.smp_allocator, false);
    defer fs3.deinit();
    var raw3 = fs3.rawOps();
    raw3.mmap = null;
    const ctx3 = db_context_t{ .struct_size = @sizeOf(db_context_t), .version = 1, .user_data = null, .hash_fn = null, .file_ops = @ptrCast(&raw3) };
    try testing.expectEqual(@as(u64, 0), db_create(path3.ptr, null, &ctx3));
    try testing.expectEqual(@as(c_int, @intFromEnum(fmt.DbStatus.unsupported)), db_last_status());
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
    var db = try KvDb.openAt(tmp.dir, .{ .durability = .none, .max_delta_entries = 16 });

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

test "kv db read-only park releases files and ensureReady rereads" {
    const testing = std.testing;
    const io = std.Io.Threaded.global_single_threaded.io();
    const pack_path = "zig-cache-kv-park-db";
    _ = std.Io.Dir.cwd().deleteTree(io, pack_path) catch {};
    defer _ = std.Io.Dir.cwd().deleteTree(io, pack_path) catch {};

    const key = fmt.Key128{ .hi = 9, .lo = 8 };
    {
        var db = try KvDb.open(pack_path, .{ .durability = .sync });
        defer db.close() catch unreachable;
        try db.put(key, "park-value", .{ .durability = .sync });
        try db.commitPending(.sync);
    }

    var db = try KvDb.open(pack_path, .{ .mode = .read_only, .create_if_missing = false });
    defer db.close() catch unreachable;
    var buf: [16]u8 = undefined;
    try testing.expectEqual(@as(usize, 10), try db.getInto(key, &buf));
    try testing.expectEqualStrings("park-value", buf[0..10]);
    try db.park();
    try testing.expect(db.isParked());
    try testing.expectError(error.Busy, db.getInto(key, &buf));
    try db.ensureReady();
    try testing.expect(!db.isParked());
    try testing.expectEqual(@as(usize, 10), try db.getInto(key, &buf));
    try testing.expectEqualStrings("park-value", buf[0..10]);

    var writable = try KvDb.open(pack_path, .{ .create_if_missing = false });
    defer writable.close() catch {};
    try testing.expectError(error.PermissionDenied, writable.park());
}

test "kv db multi shard put get delete overwrite optimize verify and reopen" {
    const testing = std.testing;
    const batch_mod = @import("batch_snapshot.zig");
    const verify_mod = @import("recovery_verify.zig");
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var db = try KvDb.openAt(tmp.dir, .{ .data_file_count = 4, .max_delta_entries = 256 });
    try testing.expectEqual(@as(u32, 4), db.shardCount());

    var shards_seen = [_]bool{false} ** 4;
    var i: u64 = 0;
    while (i < 64) : (i += 1) {
        var key_bytes: [8]u8 = undefined;
        std.mem.writeInt(u64, &key_bytes, 1000 + i, .little);
        var value: [16]u8 = undefined;
        const v = try std.fmt.bufPrint(&value, "value-{d}", .{i});
        try db.putBytes(&key_bytes, v, .{});
    }
    try db.commitPending(.sync);
    i = 0;
    while (i < 64) : (i += 1) {
        var key_bytes: [8]u8 = undefined;
        std.mem.writeInt(u64, &key_bytes, 1000 + i, .little);
        const info = try db.lookupBytes(&key_bytes);
        shards_seen[info.data_db_id] = true;
        const got = try db.getBorrowedBytes(&key_bytes);
        var expect: [16]u8 = undefined;
        try testing.expectEqualStrings(try std.fmt.bufPrint(&expect, "value-{d}", .{i}), got);
        var key_back: [16]u8 = undefined;
        const n = try db.readKeyBytes(info, &key_back);
        try testing.expectEqualSlices(u8, &key_bytes, key_back[0..n]);
    }
    for (shards_seen) |seen| try testing.expect(seen);

    // Pinned-shard batch lands in that shard.
    var b = try batch_mod.Batch.beginWithOptions(&db, testing.allocator, .{ .shard = 3 });
    defer b.deinit();
    var pinned_key: [8]u8 = undefined;
    std.mem.writeInt(u64, &pinned_key, 77, .little);
    try b.putBytes(&pinned_key, "pinned", 0);
    try b.commit(.sync);
    try testing.expectEqual(@as(u32, 3), (try db.lookupBytes(&pinned_key)).data_db_id);
    try testing.expectError(error.InvalidArgument, batch_mod.Batch.beginWithOptions(&db, testing.allocator, .{ .shard = 4 }));

    // Overwrite + delete across shards, then optimize and verify.
    var k5: [8]u8 = undefined;
    std.mem.writeInt(u64, &k5, 1005, .little);
    try db.putBytes(&k5, "overwritten", .{});
    var k6: [8]u8 = undefined;
    std.mem.writeInt(u64, &k6, 1006, .little);
    try db.deleteBytes(&k6, .{});
    try db.commitPending(.sync);
    try db.optimize();
    try testing.expectEqualStrings("overwritten", try db.getBorrowedBytes(&k5));
    try testing.expectError(error.NotFound, db.getSizeBytes(&k6));
    const live = try db.collectLiveKeys(testing.allocator);
    defer testing.allocator.free(live);
    try testing.expectEqual(@as(usize, 64), live.len); // 64 original - 1 deleted + 1 pinned
    try db.close();

    var report = try verify_mod.verifyAt(tmp.dir, testing.allocator);
    defer report.deinit();
    try testing.expect(report.ok());

    var reopened = try KvDb.openAt(tmp.dir, .{ .create_if_missing = false });
    defer reopened.close() catch {};
    try testing.expectEqual(@as(u32, 4), reopened.shardCount());
    try testing.expectEqualStrings("pinned", try reopened.getBorrowedBytes(&pinned_key));
    try testing.expectEqualStrings("overwritten", try reopened.getBorrowedBytes(&k5));
}

test "kv db parallel batches on disjoint shards commit correctly" {
    const testing = std.testing;
    const batch_mod = @import("batch_snapshot.zig");
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var db = try KvDb.openAt(tmp.dir, .{ .data_file_count = 3, .max_delta_entries = 1024 });
    defer db.close() catch {};

    const Worker = struct {
        fn run(d: *KvDb, shard: u32, err_out: *?anyerror) void {
            var round: u32 = 0;
            while (round < 8) : (round += 1) {
                var b = batch_mod.Batch.beginWithOptions(d, std.heap.smp_allocator, .{ .shard = shard }) catch |e| {
                    err_out.* = e;
                    return;
                };
                defer b.deinit();
                var j: u32 = 0;
                while (j < 16) : (j += 1) {
                    var key_bytes: [8]u8 = undefined;
                    std.mem.writeInt(u64, &key_bytes, (@as(u64, shard) << 32) | (round * 16 + j), .little);
                    var value: [24]u8 = undefined;
                    const v = std.fmt.bufPrint(&value, "s{d}-r{d}-j{d}", .{ shard, round, j }) catch unreachable;
                    b.putBytes(&key_bytes, v, 0) catch |e| {
                        err_out.* = e;
                        return;
                    };
                }
                b.commit(.none) catch |e| {
                    err_out.* = e;
                    return;
                };
            }
        }
    };

    var errs = [_]?anyerror{null} ** 3;
    var threads: [3]std.Thread = undefined;
    for (&threads, 0..) |*t, s| t.* = try std.Thread.spawn(.{}, Worker.run, .{ &db, @as(u32, @intCast(s)), &errs[s] });
    for (threads) |t| t.join();
    for (errs) |e| try testing.expect(e == null);

    var shard: u32 = 0;
    while (shard < 3) : (shard += 1) {
        var n: u32 = 0;
        while (n < 128) : (n += 1) {
            var key_bytes: [8]u8 = undefined;
            std.mem.writeInt(u64, &key_bytes, (@as(u64, shard) << 32) | n, .little);
            const info = try db.lookupBytes(&key_bytes);
            try testing.expectEqual(shard, info.data_db_id);
            var expect: [24]u8 = undefined;
            try testing.expectEqualStrings(try std.fmt.bufPrint(&expect, "s{d}-r{d}-j{d}", .{ shard, n / 16, n % 16 }), try db.getBorrowedBytes(&key_bytes));
        }
    }
}

test "pending commits cross delta capacity and reopen" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var db = try KvDb.openAt(tmp.dir, .{ .max_delta_entries = 16 });
    var closed = false;
    defer if (!closed) db.close() catch {};
    for (0..80) |i| try db.put(.{ .hi = 0, .lo = i }, "value", .{});
    try db.commitPending(.sync);
    for (80..160) |i| try db.put(.{ .hi = 0, .lo = i }, "value", .{});
    try db.commitPending(.sync);
    try db.checkpoint();
    try db.close();
    closed = true;
    var reopened = try KvDb.openAt(tmp.dir, .{ .create_if_missing = false });
    defer reopened.close() catch {};
    for (0..160) |i| try std.testing.expectEqual(@as(u64, 5), try reopened.getSize(.{ .hi = 0, .lo = i }));
}

test "explicit batches reserve whole delta and preserve checkpoint deletes" {
    const testing = std.testing;
    const batch_mod = @import("batch_snapshot.zig");
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var db = try KvDb.openAt(tmp.dir, .{ .max_delta_entries = 16 });
    var closed = false;
    defer if (!closed) db.close() catch {};
    try db.put(.{ .hi = 0, .lo = 9999 }, "old", .{});
    try db.commitPending(.sync);
    try db.checkpoint();
    var batch = batch_mod.Batch.begin(&db, testing.allocator);
    defer batch.deinit();
    try batch.delete(.{ .hi = 0, .lo = 9999 });
    for (0..1000) |i| try batch.put(.{ .hi = 0, .lo = i }, "batch", 0);
    try batch.commit(.sync);
    // Rebuild the active slot table from its journal, as dirty-open recovery does.
    try delta_mod.recover(&db.delta);
    for (0..1000) |i| try testing.expectEqual(@as(u64, 5), try db.getSize(.{ .hi = 0, .lo = i }));
    // Force a second rollover, merging the delete into the base.
    for (1000..2000) |i| try db.put(.{ .hi = 0, .lo = i }, "pending", .{});
    try db.commitPending(.sync);
    try testing.expectError(error.NotFound, db.getSize(.{ .hi = 0, .lo = 9999 }));
    try db.close();
    closed = true;
    var reopened = try KvDb.openAt(tmp.dir, .{ .create_if_missing = false });
    defer reopened.close() catch {};
    try testing.expectError(error.NotFound, reopened.getSize(.{ .hi = 0, .lo = 9999 }));
    for (0..1000) |i| try testing.expectEqual(@as(u64, 5), try reopened.getSize(.{ .hi = 0, .lo = i }));
    for (1000..2000) |i| try testing.expectEqual(@as(u64, 7), try reopened.getSize(.{ .hi = 0, .lo = i }));
}

test "commit rolls over exhausted journal with few delta keys" {
    const testing = std.testing;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var db = try KvDb.openAt(tmp.dir, .{});
    defer db.close() catch {};
    // Use a small valid journal to exercise exhaustion without thousands of IOs.
    const small = try delta_mod.create(db.index, 1024, 6 * journal_mod.JOURNAL_RECORD_SIZE);
    db.delta.unmap();
    db.delta = small;
    const original_region = db.index.activeDeltaRegionId();
    for (0..3) |_| {
        try db.put(.{ .hi = 0, .lo = 1 }, "update", .{});
        try db.commitPending(.sync);
    }
    try testing.expect(db.index.activeDeltaRegionId() != original_region);
    try testing.expectEqual(@as(u64, 6), try db.getSize(.{ .hi = 0, .lo = 1 }));
}
