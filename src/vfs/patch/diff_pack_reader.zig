//! Read side of a DiffPack. Opens the store either fully in memory
//! (InMemoryFileOps, read-only) or on disk, decodes all tables eagerly and
//! chunks lazily through a pinned, byte-budgeted cache (see `chunk`).
const std = @import("std");
const db_internal = @import("db_internal");
const kv = db_internal.kv_db;
const pf = db_internal.platform.file;
const inmemory = db_internal.platform.inmemory_file_ops;
const sync = db_internal.platform.sync;
const diff_pack = @import("../format/diff_pack.zig");
const object_key = @import("../object_key.zig");

pub const LoadMode = enum { auto, in_memory, disk };

pub const OpenOptions = struct {
    load: LoadMode = .auto,
    /// `auto` loads in memory only if the store's files total at most this.
    in_memory_max_bytes: u64 = 512 << 20,
    /// Decoded chunks kept resident; unpinned chunks are evicted once the
    /// total exceeds this. A single chunk larger than the budget still
    /// loads (it is evicted as soon as it is unpinned).
    chunk_cache_bytes: u64 = 64 << 20,
};

const ChunkEntry = struct {
    bytes: []u8,
    /// Outstanding `payload`/`chunk` borrows; never evicted while > 0.
    pins: u32,
};

pub const DiffPackReader = struct {
    allocator: std.mem.Allocator,
    path: []u8,
    db: kv.KvDb,
    mem_fs: ?*inmemory.FileSystem = null,
    mem_raw: ?*pf.RawFileOps = null,
    in_memory: bool = false,
    manifest: diff_pack.DiffManifest,
    file_ops: []diff_pack.FileOp,
    /// Indexed by shard hint.
    unit_tables: []diff_pack.DecodedUnits,
    path_delta: ?diff_pack.DecodedPathDelta = null,
    chunk_lock: sync.Mutex = .{},
    chunks: std.AutoArrayHashMapUnmanaged(u32, ChunkEntry) = .empty,
    chunk_cache_bytes: u64 = 64 << 20,
    chunk_resident_bytes: u64 = 0,

    pub fn open(allocator: std.mem.Allocator, path: []const u8, options: OpenOptions) !DiffPackReader {
        const use_memory = switch (options.load) {
            .in_memory => true,
            .disk => false,
            .auto => (try storeBytes(path)) <= options.in_memory_max_bytes,
        };
        var self: DiffPackReader = .{
            .allocator = allocator,
            .path = try allocator.dupe(u8, path),
            .db = undefined,
            .manifest = undefined,
            .file_ops = &.{},
            .unit_tables = &.{},
            .chunk_cache_bytes = options.chunk_cache_bytes,
        };
        errdefer allocator.free(self.path);
        if (use_memory) {
            const fs = try allocator.create(inmemory.FileSystem);
            errdefer allocator.destroy(fs);
            fs.* = inmemory.FileSystem.init(allocator, false);
            errdefer fs.deinit();
            const raw = try allocator.create(pf.RawFileOps);
            errdefer allocator.destroy(raw);
            raw.* = fs.rawOps();
            const ops = try pf.customOpsFromRaw(raw);
            self.db = try kv.KvDb.openCustom(path, ops, .{ .mode = .read_only, .create_if_missing = false });
            self.mem_fs = fs;
            self.mem_raw = raw;
            self.in_memory = true;
        } else {
            self.db = try kv.KvDb.open(path, .{ .mode = .read_only, .create_if_missing = false, .read_handles = 4 });
        }
        errdefer self.closeDb();

        const manifest_bytes = try self.readObjectAlloc(object_key.diffManifestKey());
        defer allocator.free(manifest_bytes);
        self.manifest = try diff_pack.decodeManifest(manifest_bytes);

        const ops_bytes = try self.readObjectAlloc(object_key.diffFileOpTableKey());
        defer allocator.free(ops_bytes);
        self.file_ops = try diff_pack.decodeFileOps(allocator, ops_bytes);
        errdefer allocator.free(self.file_ops);
        if (self.file_ops.len != self.manifest.file_op_count) return error.Corruption;

        // One unit table per shard hint; the count comes from the file, so
        // bound it before trusting it for an allocation.
        if (self.manifest.shard_hint_count == 0 or self.manifest.shard_hint_count > diff_pack.MAX_SHARD_HINTS) return error.Corruption;
        self.unit_tables = try allocator.alloc(diff_pack.DecodedUnits, self.manifest.shard_hint_count);
        var decoded: usize = 0;
        errdefer {
            for (self.unit_tables[0..decoded]) |*t| t.deinit(allocator);
            allocator.free(self.unit_tables);
        }
        var total_units: u64 = 0;
        while (decoded < self.unit_tables.len) : (decoded += 1) {
            const bytes = try self.readObjectAlloc(object_key.diffUnitTableKey(@intCast(decoded)));
            defer allocator.free(bytes);
            var table = try diff_pack.decodeUnits(allocator, bytes);
            if (table.shard != decoded) {
                table.deinit(allocator);
                return error.Corruption;
            }
            self.unit_tables[decoded] = table;
            total_units += table.units.len;
        }
        if (total_units != self.manifest.unit_count) return error.Corruption;

        if (self.manifest.flags & diff_pack.MANIFEST_FLAG_HAS_PATH_DELTA != 0) {
            const pd_bytes = try self.readObjectAlloc(object_key.diffPathDeltaKey());
            defer allocator.free(pd_bytes);
            self.path_delta = try diff_pack.decodePathDelta(allocator, pd_bytes);
        }
        return self;
    }

    fn closeDb(self: *DiffPackReader) void {
        self.db.close() catch {};
        if (self.mem_fs) |fs| {
            fs.deinit();
            self.allocator.destroy(fs);
        }
        if (self.mem_raw) |raw| self.allocator.destroy(raw);
    }

    pub fn close(self: *DiffPackReader) void {
        for (self.chunks.values()) |e| self.allocator.free(e.bytes);
        self.chunks.deinit(self.allocator);
        if (self.path_delta) |*pd| pd.deinit(self.allocator);
        for (self.unit_tables) |*t| t.deinit(self.allocator);
        self.allocator.free(self.unit_tables);
        self.allocator.free(self.file_ops);
        self.closeDb();
        self.allocator.free(self.path);
        self.* = undefined;
    }

    fn readObjectAlloc(self: *DiffPackReader, key: u64) ![]u8 {
        const kb = object_key.encodeDbKey(key);
        return self.allocator.dupe(u8, try self.db.getBorrowedBytes(&kb));
    }

    /// Whole decoded chunk payload (header verified), pinned: the slice stays
    /// valid until the matching `unpin`. Cached across pins; thread-safe.
    /// Unpinned chunks are evicted oldest-first once the resident total
    /// exceeds `chunk_cache_bytes`, so `.disk` mode really is bounded.
    pub fn chunk(self: *DiffPackReader, chunk_id: u32) ![]const u8 {
        self.chunk_lock.lock();
        defer self.chunk_lock.unlock();
        if (self.chunks.getPtr(chunk_id)) |e| {
            e.pins += 1;
            return e.bytes;
        }
        const bytes = try self.readObjectAlloc(object_key.diffChunkKey(chunk_id));
        defer self.allocator.free(bytes);
        const decoded = try diff_pack.decodeChunk(bytes, chunk_id);
        const owned = try self.allocator.dupe(u8, decoded.payload);
        errdefer self.allocator.free(owned);
        try self.chunks.put(self.allocator, chunk_id, .{ .bytes = owned, .pins = 1 });
        self.chunk_resident_bytes += owned.len;
        self.evictLocked();
        return owned;
    }

    /// Releases one pin taken by `chunk`/`payload`.
    pub fn unpin(self: *DiffPackReader, chunk_id: u32) void {
        self.chunk_lock.lock();
        defer self.chunk_lock.unlock();
        const e = self.chunks.getPtr(chunk_id) orelse return;
        std.debug.assert(e.pins > 0);
        e.pins -= 1;
        if (e.pins == 0 and self.chunk_resident_bytes > self.chunk_cache_bytes) self.evictLocked();
    }

    /// Drops unpinned chunks (insertion order = oldest first) until under
    /// budget. Chunks are appended in unit order, so this approximates LRU
    /// for the sequential access pattern of a patch run.
    fn evictLocked(self: *DiffPackReader) void {
        var i: usize = 0;
        while (self.chunk_resident_bytes > self.chunk_cache_bytes and i < self.chunks.count()) {
            const e = self.chunks.values()[i];
            if (e.pins != 0) {
                i += 1;
                continue;
            }
            self.chunk_resident_bytes -= e.bytes.len;
            self.allocator.free(e.bytes);
            self.chunks.orderedRemoveAt(i);
        }
    }

    /// Payload bytes of a unit / file op, pinned in the chunk cache; the
    /// caller must `unpin(ref.chunk_id)` once done (no-op for empty refs).
    pub fn payload(self: *DiffPackReader, ref: diff_pack.PayloadRef) ![]const u8 {
        if (ref.len == 0) return &.{};
        const c = try self.chunk(ref.chunk_id);
        if (@as(usize, ref.offset) + ref.len > c.len) {
            self.unpin(ref.chunk_id);
            return error.Corruption;
        }
        return c[ref.offset .. ref.offset + ref.len];
    }

    /// Releases the pin taken by a successful `payload`.
    pub fn unpinPayload(self: *DiffPackReader, ref: diff_pack.PayloadRef) void {
        if (ref.len == 0) return;
        self.unpin(ref.chunk_id);
    }

    /// Bytes currently held by the chunk cache (for tests / diagnostics).
    pub fn residentChunkBytes(self: *DiffPackReader) u64 {
        self.chunk_lock.lock();
        defer self.chunk_lock.unlock();
        return self.chunk_resident_bytes;
    }

    pub fn totalUnits(self: *const DiffPackReader) usize {
        var n: usize = 0;
        for (self.unit_tables) |t| n += t.units.len;
        return n;
    }
};

fn storeBytes(path: []const u8) !u64 {
    var total: u64 = 0;
    const names = [_][]const u8{ "manifest.db", "index.db", "data_000.db" };
    var buf: [1024]u8 = undefined;
    for (names) |n| {
        const p = try std.fmt.bufPrint(&buf, "{s}/{s}", .{ path, n });
        var f = pf.open(p, .{ .mode = .read_only }) catch |e| switch (e) {
            error.FileNotFound => continue,
            else => |err| return err,
        };
        defer pf.close(&f);
        total += try pf.len(f);
    }
    return total;
}

/// Structural verification: every payload ref lies inside its chunk, every
/// chunk decodes, and VHDF headers parse.
pub fn verify(allocator: std.mem.Allocator, path: []const u8) !void {
    var r = try DiffPackReader.open(allocator, path, .{ .load = .disk });
    defer r.close();
    const hdiff = @import("../hdiff/root.zig");
    var cid: u32 = 0;
    while (cid < r.manifest.chunk_count) : (cid += 1) {
        _ = try r.chunk(cid);
        r.unpin(cid);
    }
    for (r.unit_tables) |t| for (t.units) |u| {
        const p = try r.payload(u.payload);
        defer r.unpinPayload(u.payload);
        switch (u.kind) {
            .put_page_raw => if (p.len == 0) return error.Corruption,
            .put_page_pdelta, .put_block_ldelta => _ = try hdiff.decodeHeader(p),
            .delete_page => if (p.len != 0) return error.Corruption,
            _ => return error.Corruption,
        }
    };
    for (r.file_ops) |op| {
        const p = try r.payload(op.payload);
        defer r.unpinPayload(op.payload);
        switch (op.op) {
            .put_file_manifest, .put_entry_tombstone, .put_directory_manifest => if (p.len == 0) return error.Corruption,
            .delete_file_manifest, .delete_entry_tombstone => if (p.len != 0) return error.Corruption,
            _ => return error.Corruption,
        }
    }
}
