//! Decoded-page cache shared by all file handles of a volume.
//!
//! Design goals (see docs/vfs/multithread_read.md §7.3):
//! - Sharded: the key hash selects one of `SHARD_COUNT` independent shards, each
//!   with its own mutex, hash map and LRU list, so unrelated pages never contend.
//! - Reference counted: a hit pins the entry, drops the shard lock, then copies
//!   to the caller's buffer outside the lock. Eviction only frees entries with
//!   no pins; a pinned victim is unlinked and released by its last unpin.
//! - Verified once: explicit page-ref crc/content-hash checks run when the
//!   page is loaded, not on every hit.
//! - Miss de-duplication: concurrent misses on one key wait for the first
//!   loader instead of each reading and decoding the page.
//! - No lock is held across IO, decoding or checksum work.
const std = @import("std");
const pack_reader = @import("../pack/pack_reader.zig");
const page_value_fmt = @import("../format/page_value.zig");
const file_manifest_fmt = @import("../format/file_manifest.zig");
const page_placeholder_fmt = @import("../format/page_placeholder.zig");
const registry = @import("../compress/registry.zig");
const object_key = @import("../object_key.zig");
const hash = @import("../hash.zig");
const sync = @import("db_internal").platform.sync;

pub const SHARD_COUNT: usize = 64;
pub const DEFAULT_BUDGET_BYTES: usize = 8 * 1024 * 1024;

pub const PageCacheKey = struct {
    pack_id: u32,
    pack_generation: u64,
    file_entry: u64,
    block_index: u32,
    page_index: u32,
    codec_identity: u64,
};

pub const Stats = struct {
    hits: u64 = 0,
    misses: u64 = 0,
    evictions: u64 = 0,
    /// Misses that waited for another thread's in-flight load of the same page.
    coalesced: u64 = 0,
};

const Entry = struct {
    key: PageCacheKey,
    /// Decoded page bytes. Empty while `loading`.
    data: []u8 = &.{},
    /// Pins held by readers (copying) or loaders. The entry may be freed only
    /// when this reaches zero and it is no longer in the shard map.
    refs: u32 = 0,
    /// True while the first reader is fetching/decoding the page.
    loading: bool = true,
    /// Set when a load failed; waiters retry the load themselves.
    failed: bool = false,
    /// True while linked in the shard map / LRU. Cleared by eviction or by
    /// `deinit`; whoever drops the last ref after that frees the entry.
    resident: bool = false,
    /// Explicit-ref crc/hash were checked against the manifest when loaded.
    verified_crc: ?u32 = null,
    verified_hash: ?[32]u8 = null,
    lru_prev: ?*Entry = null,
    lru_next: ?*Entry = null,
};

const Shard = struct {
    lock: sync.Mutex = .{},
    /// Waiters for in-flight loads block here; woken on every load completion.
    load_done: sync.Condition = .{},
    map: std.HashMapUnmanaged(PageCacheKey, *Entry, KeyContext, 80) = .empty,
    lru_head: ?*Entry = null,
    lru_tail: ?*Entry = null,
    used_bytes: usize = 0,
    stats: Stats = .{},
};

const KeyContext = struct {
    pub fn hash(_: KeyContext, key: PageCacheKey) u64 {
        return hashKey(key);
    }
    pub fn eql(_: KeyContext, a: PageCacheKey, b: PageCacheKey) bool {
        return keyEqual(a, b);
    }
};

pub const PageCache = struct {
    budget_bytes: usize = DEFAULT_BUDGET_BYTES,
    /// Bytes resident across all shards. Updated atomically so a shard can
    /// decide to evict without touching the others.
    total_bytes: std.atomic.Value(usize) = .init(0),
    /// Round-robin cursor for cross-shard eviction.
    evict_cursor: std.atomic.Value(usize) = .init(0),
    shards: [SHARD_COUNT]Shard = [_]Shard{.{}} ** SHARD_COUNT,

    pub fn deinit(self: *PageCache, allocator: std.mem.Allocator) void {
        for (&self.shards) |*shard| {
            shard.lock.lock();
            var it = shard.map.valueIterator();
            while (it.next()) |entry_ptr| {
                const entry = entry_ptr.*;
                entry.resident = false;
                if (entry.refs == 0) freeEntry(allocator, entry);
                // Pinned entries are released by their last unpin.
            }
            shard.map.deinit(allocator);
            shard.map = .empty;
            shard.lru_head = null;
            shard.lru_tail = null;
            shard.used_bytes = 0;
            shard.lock.unlock();
        }
        self.* = .{ .budget_bytes = self.budget_bytes };
    }

    /// Aggregate statistics across shards (racy snapshot; for diagnostics).
    pub fn stats(self: *PageCache) Stats {
        var out: Stats = .{};
        for (&self.shards) |*shard| {
            shard.lock.lock();
            out.hits += shard.stats.hits;
            out.misses += shard.stats.misses;
            out.evictions += shard.stats.evictions;
            out.coalesced += shard.stats.coalesced;
            shard.lock.unlock();
        }
        return out;
    }

    pub fn residentBytes(self: *PageCache) usize {
        var out: usize = 0;
        for (&self.shards) |*shard| {
            shard.lock.lock();
            out += shard.used_bytes;
            shard.lock.unlock();
        }
        return out;
    }

    pub fn residentCount(self: *PageCache) usize {
        var out: usize = 0;
        for (&self.shards) |*shard| {
            shard.lock.lock();
            out += shard.map.count();
            shard.lock.unlock();
        }
        return out;
    }

    /// Copy `dst.len` bytes starting at `page_off` of the decoded page into
    /// `dst`, loading and caching the page on a miss.
    pub fn copyRange(
        self: *PageCache,
        allocator: std.mem.Allocator,
        reader: *pack_reader.PackReader,
        key: PageCacheKey,
        expected: page_value_fmt.PageIdentity,
        codec: file_manifest_fmt.Codec,
        page_object_key: u64,
        page_off: usize,
        dst: []u8,
        expect_crc: ?u32,
        expect_hash: ?[32]u8,
    ) !void {
        if (key.file_entry == 0) return error.InvalidArgument;
        const shard = self.shardFor(key);

        while (true) {
            const acquired = try self.acquire(shard, allocator, key);
            const entry = acquired.entry;
            if (acquired.must_load) {
                const loaded = loadPage(allocator, reader, expected, codec, page_object_key, expect_crc, expect_hash);
                if (loaded) |raw| {
                    self.publishLoaded(shard, entry, raw, expect_crc, expect_hash);
                    // We still hold a pin, so our own page cannot be freed
                    // while other shards are trimmed.
                    self.reclaim(allocator, shard);
                } else |err| {
                    self.publishFailed(shard, allocator, entry);
                    return err;
                }
            } else if (acquired.wait_for_load) {
                const usable = self.waitLoaded(shard, allocator, entry);
                if (!usable) continue; // loader failed; retry as loader ourselves
            }
            defer self.unpin(shard, allocator, entry);
            try verifyPinned(entry, expect_crc, expect_hash);
            if (page_off > entry.data.len or dst.len > entry.data.len - page_off) return error.Corruption;
            @memcpy(dst, entry.data[page_off..][0..dst.len]);
            return;
        }
    }

    /// Whole-page read that does not populate the cache: a resident page is
    /// copied out; otherwise the page is decoded straight into `dst` (one
    /// syscall, one crc pass, zero heap allocation). Used for streaming loads.
    pub fn readThrough(
        self: *PageCache,
        reader: *pack_reader.PackReader,
        key: PageCacheKey,
        expected: page_value_fmt.PageIdentity,
        codec: file_manifest_fmt.Codec,
        page_object_key: u64,
        dst: []u8,
    ) !void {
        if (key.file_entry == 0) return error.InvalidArgument;
        const shard = self.shardFor(key);
        {
            shard.lock.lock();
            const hit = shard.map.get(key);
            if (hit) |entry| {
                if (!entry.loading) {
                    entry.refs += 1;
                    shard.stats.hits += 1;
                    lruMoveFront(shard, entry);
                    shard.lock.unlock();
                    defer self.unpin(shard, std.heap.smp_allocator, entry);
                    if (dst.len != entry.data.len) return error.Corruption;
                    @memcpy(dst, entry.data);
                    return;
                }
            }
            shard.stats.misses += 1;
            shard.lock.unlock();
        }
        const page_bytes = try reader.readObjectBorrow(page_object_key);
        if (page_placeholder_fmt.isPlaceholder(page_bytes)) {
            _ = try page_placeholder_fmt.decode(page_bytes, expected);
            return error.PagePlaceholder;
        }
        const page = try page_value_fmt.decodePageValue(page_bytes, expected);
        if (page.codec != codec and page.codec != .none) return error.Corruption;
        if (page.raw_size != dst.len) return error.Corruption;
        if (page.codec == .none) {
            if (page.payload.len != page.raw_size) return error.Corruption;
            @memcpy(dst, page.payload);
            return;
        }
        // Streaming path for compressed pages: decode into a scratch buffer
        // and copy; still bypasses the cache.
        const raw = try registry.decompressPage(std.heap.smp_allocator, page.codec, page.payload, page.raw_size, page.raw_crc);
        defer std.heap.smp_allocator.free(raw);
        @memcpy(dst, raw);
    }

    pub fn getOrLoad(
        self: *PageCache,
        allocator: std.mem.Allocator,
        reader: *pack_reader.PackReader,
        key: PageCacheKey,
        expected: page_value_fmt.PageIdentity,
        codec: file_manifest_fmt.Codec,
        dst: []u8,
    ) !void {
        try self.copyRange(allocator, reader, key, expected, codec, try object_key.pageKey(expected.file_entry, expected.block_index, expected.page_index), 0, dst, null, null);
    }

    /// Insert an already-decoded page. Ownership of `data` moves to the cache.
    pub fn insertOwned(self: *PageCache, allocator: std.mem.Allocator, key: PageCacheKey, data: []u8) !void {
        const shard = self.shardFor(key);
        {
            shard.lock.lock();
            defer shard.lock.unlock();
            if (shard.map.get(key)) |existing| {
                if (!existing.loading) {
                    allocator.free(data);
                    return;
                }
            }
            const entry = try allocator.create(Entry);
            entry.* = .{ .key = key, .data = data, .loading = false, .resident = true };
            errdefer allocator.destroy(entry);
            try shard.map.put(allocator, key, entry);
            lruPushFront(shard, entry);
            self.accountLocked(shard, data.len);
        }
        self.reclaim(allocator, shard);
    }

    // ------------------------------------------------------------------
    // internals
    // ------------------------------------------------------------------

    fn shardFor(self: *PageCache, key: PageCacheKey) *Shard {
        return &self.shards[@intCast(hashKey(key) % SHARD_COUNT)];
    }

    fn accountLocked(self: *PageCache, shard: *Shard, bytes: usize) void {
        shard.used_bytes += bytes;
        _ = self.total_bytes.fetchAdd(bytes, .monotonic);
    }

    fn unaccountLocked(self: *PageCache, shard: *Shard, bytes: usize) void {
        shard.used_bytes -= bytes;
        _ = self.total_bytes.fetchSub(bytes, .monotonic);
    }

    /// Once over budget, evict down to this fraction of it so that a stream of
    /// inserts triggers one reclaim per ~budget/8 bytes rather than one per page.
    fn lowWatermark(self: *const PageCache) usize {
        return self.budget_bytes - self.budget_bytes / 8;
    }

    /// Bring total residency back under budget. Starts with the shard that
    /// just grew (its lock is NOT held on entry), then walks the others
    /// round-robin. Each shard is locked only while its own LRU is trimmed.
    fn reclaim(self: *PageCache, allocator: std.mem.Allocator, hot: *Shard) void {
        if (self.total_bytes.load(.monotonic) <= self.budget_bytes) return;
        const target = self.lowWatermark();
        // Trim the hot shard first, but never below one resident page.
        self.evictShard(allocator, hot, true, target);
        var visited: usize = 0;
        while (visited < SHARD_COUNT and self.total_bytes.load(.monotonic) > target) : (visited += 1) {
            const idx = self.evict_cursor.fetchAdd(1, .monotonic) % SHARD_COUNT;
            const shard = &self.shards[idx];
            if (shard == hot) continue;
            self.evictShard(allocator, shard, false, target);
        }
    }

    fn evictShard(self: *PageCache, allocator: std.mem.Allocator, shard: *Shard, keep_one: bool, target: usize) void {
        shard.lock.lock();
        defer shard.lock.unlock();
        var cursor = shard.lru_tail;
        while (self.total_bytes.load(.monotonic) > target) {
            const victim = cursor orelse break;
            cursor = victim.lru_prev;
            if (victim.loading) continue;
            if (keep_one and victim == shard.lru_head) break;
            lruUnlink(shard, victim);
            _ = shard.map.remove(victim.key);
            self.unaccountLocked(shard, victim.data.len);
            shard.stats.evictions += 1;
            victim.resident = false;
            if (victim.refs == 0) freeEntry(allocator, victim);
        }
    }

    const Acquired = struct {
        entry: *Entry,
        must_load: bool,
        wait_for_load: bool,
    };

    /// Look up or reserve an entry, returning it pinned.
    fn acquire(self: *PageCache, shard: *Shard, allocator: std.mem.Allocator, key: PageCacheKey) !Acquired {
        _ = self;
        shard.lock.lock();
        defer shard.lock.unlock();
        if (shard.map.get(key)) |entry| {
            entry.refs += 1;
            if (entry.loading) {
                shard.stats.coalesced += 1;
                return .{ .entry = entry, .must_load = false, .wait_for_load = true };
            }
            shard.stats.hits += 1;
            lruMoveFront(shard, entry);
            return .{ .entry = entry, .must_load = false, .wait_for_load = false };
        }
        shard.stats.misses += 1;
        const entry = try allocator.create(Entry);
        entry.* = .{ .key = key, .refs = 1, .loading = true, .resident = true };
        errdefer allocator.destroy(entry);
        try shard.map.put(allocator, key, entry);
        return .{ .entry = entry, .must_load = true, .wait_for_load = false };
    }

    /// Block until `entry` finishes loading. Returns false if the load failed
    /// (the entry has been unpinned and the caller should retry).
    fn waitLoaded(self: *PageCache, shard: *Shard, allocator: std.mem.Allocator, entry: *Entry) bool {
        shard.lock.lock();
        while (entry.loading) {
            shard.load_done.wait(&shard.lock);
        }
        if (entry.failed) {
            self.unpinLocked(shard, allocator, entry);
            shard.lock.unlock();
            return false;
        }
        shard.lock.unlock();
        return true;
    }

    fn publishLoaded(self: *PageCache, shard: *Shard, entry: *Entry, raw: []u8, expect_crc: ?u32, expect_hash: ?[32]u8) void {
        shard.lock.lock();
        defer shard.lock.unlock();
        entry.data = raw;
        entry.loading = false;
        entry.verified_crc = expect_crc;
        entry.verified_hash = expect_hash;
        if (entry.resident) {
            lruPushFront(shard, entry);
            self.accountLocked(shard, raw.len);
        }
        shard.load_done.broadcast();
    }

    fn publishFailed(self: *PageCache, shard: *Shard, allocator: std.mem.Allocator, entry: *Entry) void {
        shard.lock.lock();
        defer shard.lock.unlock();
        entry.loading = false;
        entry.failed = true;
        if (entry.resident) {
            entry.resident = false;
            _ = shard.map.remove(entry.key);
        }
        shard.load_done.broadcast();
        self.unpinLocked(shard, allocator, entry);
    }

    fn unpin(self: *PageCache, shard: *Shard, allocator: std.mem.Allocator, entry: *Entry) void {
        shard.lock.lock();
        defer shard.lock.unlock();
        self.unpinLocked(shard, allocator, entry);
    }

    fn unpinLocked(_: *PageCache, _: *Shard, allocator: std.mem.Allocator, entry: *Entry) void {
        std.debug.assert(entry.refs > 0);
        entry.refs -= 1;
        if (entry.refs == 0 and !entry.resident) freeEntry(allocator, entry);
    }
};

fn loadPage(
    allocator: std.mem.Allocator,
    reader: *pack_reader.PackReader,
    expected: page_value_fmt.PageIdentity,
    codec: file_manifest_fmt.Codec,
    page_object_key: u64,
    expect_crc: ?u32,
    expect_hash: ?[32]u8,
) ![]u8 {
    const page_bytes = try reader.readObjectBorrow(page_object_key);
    if (page_placeholder_fmt.isPlaceholder(page_bytes)) {
        _ = try page_placeholder_fmt.decode(page_bytes, expected);
        return error.PagePlaceholder;
    }
    const page = try page_value_fmt.decodePageValue(page_bytes, expected);
    // The block declares the codec the builder asked for; the page header
    // records what was actually stored (a page that did not shrink is kept
    // raw with codec none). Both are legal; the page header is authoritative.
    if (page.codec != codec and page.codec != .none) return error.Corruption;
    const raw = try registry.decompressPage(allocator, page.codec, page.payload, page.raw_size, page.raw_crc);
    errdefer allocator.free(raw);
    if (expect_crc) |crc| {
        if (hash.crc32c(raw) != crc) return error.ChecksumMismatch;
    }
    if (expect_hash) |want| {
        if (!std.mem.eql(u8, &hash.contentHash(raw), &want)) return error.ChecksumMismatch;
    }
    return raw;
}

/// A resident page was verified against the expectations it was loaded with.
/// A later reader with different expectations (another manifest referencing
/// the same page) re-verifies; identical expectations are a no-op.
fn verifyPinned(entry: *Entry, expect_crc: ?u32, expect_hash: ?[32]u8) !void {
    if (expect_crc) |crc| {
        const known = entry.verified_crc orelse hash.crc32c(entry.data);
        if (known != crc) return error.ChecksumMismatch;
    }
    if (expect_hash) |want| {
        if (entry.verified_hash) |known| {
            if (!std.mem.eql(u8, &known, &want)) return error.ChecksumMismatch;
        } else {
            if (!std.mem.eql(u8, &hash.contentHash(entry.data), &want)) return error.ChecksumMismatch;
        }
    }
}

fn freeEntry(allocator: std.mem.Allocator, entry: *Entry) void {
    if (entry.data.len != 0) allocator.free(entry.data);
    allocator.destroy(entry);
}

fn lruPushFront(shard: *Shard, entry: *Entry) void {
    entry.lru_prev = null;
    entry.lru_next = shard.lru_head;
    if (shard.lru_head) |head| head.lru_prev = entry;
    shard.lru_head = entry;
    if (shard.lru_tail == null) shard.lru_tail = entry;
}

fn lruUnlink(shard: *Shard, entry: *Entry) void {
    if (entry.lru_prev) |p| p.lru_next = entry.lru_next else shard.lru_head = entry.lru_next;
    if (entry.lru_next) |n| n.lru_prev = entry.lru_prev else shard.lru_tail = entry.lru_prev;
    entry.lru_prev = null;
    entry.lru_next = null;
}

fn lruMoveFront(shard: *Shard, entry: *Entry) void {
    if (shard.lru_head == entry) return;
    lruUnlink(shard, entry);
    lruPushFront(shard, entry);
}

fn hashKey(key: PageCacheKey) u64 {
    var h = std.hash.Wyhash.init(0x7061676563616368); // "pagecach"
    h.update(std.mem.asBytes(&key.pack_id));
    h.update(std.mem.asBytes(&key.pack_generation));
    h.update(std.mem.asBytes(&key.file_entry));
    h.update(std.mem.asBytes(&key.block_index));
    h.update(std.mem.asBytes(&key.page_index));
    h.update(std.mem.asBytes(&key.codec_identity));
    return h.final();
}

fn keyEqual(a: PageCacheKey, b: PageCacheKey) bool {
    return a.pack_id == b.pack_id and
        a.pack_generation == b.pack_generation and
        a.file_entry == b.file_entry and
        a.block_index == b.block_index and
        a.page_index == b.page_index and
        a.codec_identity == b.codec_identity;
}

test "page cache key includes generation and evicts by budget" {
    var cache: PageCache = .{ .budget_bytes = 4 };
    defer cache.deinit(std.testing.allocator);
    const k1: PageCacheKey = .{ .pack_id = 1, .pack_generation = 1, .file_entry = 1, .block_index = 0, .page_index = 0, .codec_identity = 1 };
    var k2 = k1;
    k2.pack_generation = 2;
    try cache.insertOwned(std.testing.allocator, k1, try std.testing.allocator.dupe(u8, "1234"));
    try std.testing.expectEqual(@as(usize, 1), cache.residentCount());
    // Same page, new generation: a distinct key; the budget forces the old one out.
    try cache.insertOwned(std.testing.allocator, k2, try std.testing.allocator.dupe(u8, "abcd"));
    try std.testing.expectEqual(@as(usize, 1), cache.residentCount());
    try std.testing.expectEqual(@as(u64, 1), cache.stats().evictions);
    try std.testing.expectEqual(@as(usize, 4), cache.residentBytes());
    try std.testing.expect(cache.shardFor(k2).map.get(k2) != null);
    try std.testing.expect(cache.shardFor(k1).map.get(k1) == null);
}

test "page cache misses then hits real pack page and isolates generation" {
    const builder = @import("../build/pack_builder.zig");
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    const pack_path = "zig-cache-vfs-page-cache-pack";
    const source_path = "zig-cache-vfs-page-cache-source.bin";
    _ = std.Io.Dir.cwd().deleteTree(io, pack_path) catch {};
    _ = std.Io.Dir.cwd().deleteFile(io, source_path) catch {};
    defer _ = std.Io.Dir.cwd().deleteTree(io, pack_path) catch {};
    defer _ = std.Io.Dir.cwd().deleteFile(io, source_path) catch {};
    try builder.writeSourceFileForTest(source_path, "abcdefgh");
    try builder.createPack(pack_path, &.{.{ .source_path = source_path, .virtual_path = "/cache.bin", .file_entry = 6001, .page_size = 4 }}, .{});
    var reader = try pack_reader.PackReader.open(allocator, pack_path);
    defer reader.close(allocator);
    var cache: PageCache = .{ .budget_bytes = 16 * SHARD_COUNT };
    defer cache.deinit(allocator);
    const key1: PageCacheKey = .{ .pack_id = 1, .pack_generation = 1, .file_entry = 6001, .block_index = 0, .page_index = 0, .codec_identity = registry.NONE_VERSION_HASH };
    var first: [4]u8 = undefined;
    try cache.getOrLoad(allocator, &reader, key1, .{ .file_entry = 6001, .block_index = 0, .page_index = 0 }, .none, &first);
    try std.testing.expectEqualSlices(u8, "abcd", &first);
    var second: [4]u8 = undefined;
    try cache.getOrLoad(allocator, &reader, key1, .{ .file_entry = 6001, .block_index = 0, .page_index = 0 }, .none, &second);
    try std.testing.expectEqualSlices(u8, "abcd", &second);
    try std.testing.expectEqual(@as(u64, 1), cache.stats().misses);
    try std.testing.expectEqual(@as(u64, 1), cache.stats().hits);
    var key2 = key1;
    key2.pack_generation = 2;
    var third: [4]u8 = undefined;
    try cache.getOrLoad(allocator, &reader, key2, .{ .file_entry = 6001, .block_index = 0, .page_index = 0 }, .none, &third);
    try std.testing.expectEqual(@as(u64, 2), cache.stats().misses);

    // A partial-range hit and an out-of-range request.
    var mid: [2]u8 = undefined;
    try cache.copyRange(allocator, &reader, key1, .{ .file_entry = 6001, .block_index = 0, .page_index = 0 }, .none, try object_key.pageKey(6001, 0, 0), 1, &mid, null, null);
    try std.testing.expectEqualSlices(u8, "bc", &mid);
    var too_far: [4]u8 = undefined;
    try std.testing.expectError(error.Corruption, cache.copyRange(allocator, &reader, key1, .{ .file_entry = 6001, .block_index = 0, .page_index = 0 }, .none, try object_key.pageKey(6001, 0, 0), 2, &too_far, null, null));

    // A failed load (missing page) must not leave a poisoned entry behind.
    const missing: PageCacheKey = .{ .pack_id = 1, .pack_generation = 1, .file_entry = 6001, .block_index = 0, .page_index = 99, .codec_identity = registry.NONE_VERSION_HASH };
    var sink: [4]u8 = undefined;
    try std.testing.expectError(error.NotFound, cache.getOrLoad(allocator, &reader, missing, .{ .file_entry = 6001, .block_index = 0, .page_index = 99 }, .none, &sink));
    try std.testing.expectError(error.NotFound, cache.getOrLoad(allocator, &reader, missing, .{ .file_entry = 6001, .block_index = 0, .page_index = 99 }, .none, &sink));
    try std.testing.expectEqual(@as(usize, 2), cache.residentCount());
}

test "page cache concurrent readers with eviction pressure keep data intact" {
    const builder = @import("../build/pack_builder.zig");
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    const pack_path = "zig-cache-vfs-page-cache-concurrent-pack";
    const source_path = "zig-cache-vfs-page-cache-concurrent-source.bin";
    _ = std.Io.Dir.cwd().deleteTree(io, pack_path) catch {};
    _ = std.Io.Dir.cwd().deleteFile(io, source_path) catch {};
    defer _ = std.Io.Dir.cwd().deleteTree(io, pack_path) catch {};
    defer _ = std.Io.Dir.cwd().deleteFile(io, source_path) catch {};

    const page_size = 64;
    const page_count = 128;
    var payload: [page_size * page_count]u8 = undefined;
    for (&payload, 0..) |*b, i| b.* = @truncate((i / page_size) * 7 + (i % page_size));
    try builder.writeSourceFileForTest(source_path, &payload);
    try builder.createPack(pack_path, &.{.{ .source_path = source_path, .virtual_path = "/c.bin", .file_entry = 6100, .page_size = page_size }}, .{});
    var reader = try pack_reader.PackReader.open(allocator, pack_path);
    defer reader.close(allocator);

    // Budget for ~16 pages total so eviction happens constantly.
    var cache: PageCache = .{ .budget_bytes = page_size * 16 };
    defer cache.deinit(allocator);

    const Ctx = struct {
        cache: *PageCache,
        reader: *pack_reader.PackReader,
        payload: []const u8,
        errors: *std.atomic.Value(u32),

        fn run(ctx: *@This(), seed: u64) void {
            var prng = std.Random.DefaultPrng.init(seed);
            const random = prng.random();
            var round: usize = 0;
            while (round < 2000) : (round += 1) {
                const page: u32 = random.uintLessThan(u32, page_count);
                const off: usize = random.uintLessThan(usize, page_size);
                const len: usize = 1 + random.uintLessThan(usize, page_size - off);
                var buf: [page_size]u8 = undefined;
                const key: PageCacheKey = .{ .pack_id = 1, .pack_generation = 1, .file_entry = 6100, .block_index = 0, .page_index = page, .codec_identity = registry.NONE_VERSION_HASH };
                ctx.cache.copyRange(std.testing.allocator, ctx.reader, key, .{ .file_entry = 6100, .block_index = 0, .page_index = page }, .none, object_key.pageKey(6100, 0, page) catch unreachable, off, buf[0..len], null, null) catch {
                    _ = ctx.errors.fetchAdd(1, .seq_cst);
                    return;
                };
                const expect = ctx.payload[@as(usize, page) * page_size + off ..][0..len];
                if (!std.mem.eql(u8, buf[0..len], expect)) {
                    _ = ctx.errors.fetchAdd(1, .seq_cst);
                    return;
                }
            }
        }
    };
    var errors = std.atomic.Value(u32).init(0);
    var ctx = Ctx{ .cache = &cache, .reader = &reader, .payload = &payload, .errors = &errors };
    var threads: [8]std.Thread = undefined;
    for (&threads, 0..) |*t, i| t.* = try std.Thread.spawn(.{}, Ctx.run, .{ &ctx, @as(u64, i) + 1 });
    for (&threads) |*t| t.join();
    try std.testing.expectEqual(@as(u32, 0), errors.load(.seq_cst));
    try std.testing.expect(cache.residentBytes() <= cache.budget_bytes);
    const s = cache.stats();
    try std.testing.expect(s.evictions > 0);
    try std.testing.expect(s.hits + s.misses + s.coalesced == 8 * 2000);
}
