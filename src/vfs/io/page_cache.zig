//! Decoded-page cache shared by all file handles of a volume.
//!
//! Design goals (see docs/vfs/multithread_read.md §7.3):
//! - Sharded: the key hash selects one of `SHARD_COUNT` independent shards, each
//!   with its own mutex, hash map and LRU list, so unrelated pages never contend.
//! - Reference counted: a hit pins the entry, drops the shard lock, then copies
//!   to the caller's buffer outside the lock. Eviction only frees entries with
//!   no pins; invalidated pinned entries are released by their last unpin.
//! - Verified once: explicit page-ref crc/content-hash checks run when the
//!   page is loaded, not on every hit.
//! - Miss de-duplication: concurrent misses on one key wait for the first
//!   loader instead of each reading and decoding the page.
//! - No lock is held across IO, decoding or checksum work.
//! - Decoded allocations are reserved before allocation, including streaming
//!   decode scratch, in-flight loads and evicted pages still pinned by readers.
//!   Budget pressure fails admission rather than waiting while holding a store
//!   pin. This is a decoded-payload bound, not a process RSS bound: hash/LRU
//!   metadata, caller buffers, DB record scratch and OS mappings are separate.
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
    pack_id: u64,
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

pub const MemoryStats = struct {
    /// Charged decoded bytes, including reservations made before allocation.
    allocated_bytes: usize = 0,
    peak_allocated_bytes: usize = 0,
    resident_bytes: usize = 0,
    inflight_bytes: usize = 0,
    evicted_pinned_bytes: usize = 0,
    /// Includes resident pins and evicted pins; overlaps the fields above.
    pinned_bytes: usize = 0,
};

const Entry = struct {
    key: PageCacheKey,
    allocator: std.mem.Allocator,
    /// Decoded page bytes. Empty while `loading`.
    data: []u8 = &.{},
    /// Pins held by readers (copying) or loaders. The entry may be freed only
    /// when this reaches zero and it is no longer in the shard map.
    refs: u32 = 0,
    /// True while the first reader is fetching/decoding the page.
    loading: bool = true,
    /// The original load error is delivered to all coalesced waiters.
    load_error: ?anyerror = null,
    retired_charge: bool = false,
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
    /// All charged decoded bytes, not just residency. Never exceeds budget.
    total_bytes: std.atomic.Value(usize) = .init(0),
    peak_bytes: std.atomic.Value(usize) = .init(0),
    inflight_bytes: std.atomic.Value(usize) = .init(0),
    evicted_pinned_bytes: std.atomic.Value(usize) = .init(0),
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
                if (entry.refs == 0) {
                    self.freeEntry(entry);
                } else if (entry.data.len != 0) {
                    entry.retired_charge = true;
                    _ = self.evicted_pinned_bytes.fetchAdd(entry.data.len, .monotonic);
                }
                // Pins remain charged until their final unpin. The owner must
                // keep this PageCache alive until outstanding users finish.
            }
            shard.map.deinit(allocator);
            shard.map = .empty;
            shard.lru_head = null;
            shard.lru_tail = null;
            shard.used_bytes = 0;
            shard.lock.unlock();
        }
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

    /// Racy diagnostic snapshot: independently sampled fields can differ while
    /// another thread publishes or frees a page. allocated/peak are the exact
    /// admission counters; resident + inflight + retired describe that charge.
    pub fn memoryStats(self: *PageCache) MemoryStats {
        var out: MemoryStats = .{
            .allocated_bytes = self.total_bytes.load(.monotonic),
            .peak_allocated_bytes = self.peak_bytes.load(.monotonic),
            .inflight_bytes = self.inflight_bytes.load(.monotonic),
            .evicted_pinned_bytes = self.evicted_pinned_bytes.load(.monotonic),
        };
        out.pinned_bytes = out.evicted_pinned_bytes;
        for (&self.shards) |*shard| {
            shard.lock.lock();
            out.resident_bytes += shard.used_bytes;
            var it = shard.map.valueIterator();
            while (it.next()) |entry_ptr| {
                const entry = entry_ptr.*;
                if (!entry.loading and entry.refs != 0) out.pinned_bytes += entry.data.len;
            }
            shard.lock.unlock();
        }
        return out;
    }

    pub fn allocatedBytes(self: *const PageCache) usize {
        return self.total_bytes.load(.monotonic);
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
        const entry = try self.loadPinned(allocator, reader, key, expected, codec, page_object_key, expect_crc, expect_hash);
        defer self.unpin(self.shardFor(key), entry);
        if (page_off > entry.data.len or dst.len > entry.data.len - page_off) return error.Corruption;
        @memcpy(dst, entry.data[page_off..][0..dst.len]);
    }

    /// Resolve/verify/cache a page without copying a destination. Use
    /// prefetchRange when the caller has a logical manifest span to validate.
    pub fn prefetch(
        self: *PageCache,
        allocator: std.mem.Allocator,
        reader: *pack_reader.PackReader,
        key: PageCacheKey,
        expected: page_value_fmt.PageIdentity,
        codec: file_manifest_fmt.Codec,
        page_object_key: u64,
        expect_crc: ?u32,
        expect_hash: ?[32]u8,
    ) !void {
        try self.prefetchRange(allocator, reader, key, expected, codec, page_object_key, 0, 0, expect_crc, expect_hash);
    }

    /// The copyRange verification and bounds contract without a destination
    /// allocation or copy. A short but otherwise valid VPAG must not satisfy a
    /// larger logical span claimed by a file manifest.
    pub fn prefetchRange(
        self: *PageCache,
        allocator: std.mem.Allocator,
        reader: *pack_reader.PackReader,
        key: PageCacheKey,
        expected: page_value_fmt.PageIdentity,
        codec: file_manifest_fmt.Codec,
        page_object_key: u64,
        page_off: usize,
        size: usize,
        expect_crc: ?u32,
        expect_hash: ?[32]u8,
    ) !void {
        const entry = try self.loadPinned(allocator, reader, key, expected, codec, page_object_key, expect_crc, expect_hash);
        defer self.unpin(self.shardFor(key), entry);
        if (page_off > entry.data.len or size > entry.data.len - page_off) return error.Corruption;
    }

    fn loadPinned(
        self: *PageCache,
        allocator: std.mem.Allocator,
        reader: *pack_reader.PackReader,
        key: PageCacheKey,
        expected: page_value_fmt.PageIdentity,
        codec: file_manifest_fmt.Codec,
        page_object_key: u64,
        expect_crc: ?u32,
        expect_hash: ?[32]u8,
    ) !*Entry {
        if (key.file_entry == 0) return error.InvalidArgument;
        const shard = self.shardFor(key);
        const acquired = try self.acquire(shard, allocator, key);
        const entry = acquired.entry;
        if (acquired.must_load) {
            const raw = loadPage(self, allocator, reader, expected, codec, page_object_key, expect_crc, expect_hash) catch |err| {
                self.publishFailed(shard, entry, err);
                return err;
            };
            self.publishLoaded(shard, entry, raw, expect_crc, expect_hash);
        } else if (acquired.wait_for_load) {
            try self.waitLoaded(shard, entry);
        }
        errdefer self.unpin(shard, entry);
        try verifyPinned(entry, expect_crc, expect_hash);
        return entry;
    }

    /// Whole-page read that does not populate the cache: a resident page is
    /// copied out; otherwise raw pages copy straight into `dst`. Compressed
    /// pages use a charged temporary decoded allocation. Used for streaming
    /// loads; caller destination bytes are outside the cache budget.
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
                    defer self.unpin(shard, entry);
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
        try self.reserveDecoded(page.raw_size);
        defer self.releaseInflight(page.raw_size);
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

    /// Insert an already-decoded page. Ownership moves on success only. The
    /// caller's allocation before this call is outside the cache budget.
    pub fn insertOwned(self: *PageCache, allocator: std.mem.Allocator, key: PageCacheKey, data: []u8) !void {
        if (key.file_entry == 0) return error.InvalidArgument;
        const shard = self.shardFor(key);
        shard.lock.lock();
        if (shard.map.contains(key)) {
            shard.lock.unlock();
            allocator.free(data);
            return;
        }
        shard.lock.unlock();
        try self.reserveDecoded(data.len);
        errdefer self.releaseInflight(data.len);
        shard.lock.lock();
        defer shard.lock.unlock();
        // Another loader may have won admission. Never overwrite its loading
        // placeholder: its waiters and eventual publication still own it.
        if (shard.map.contains(key)) {
            allocator.free(data);
            self.releaseInflight(data.len);
            return;
        }
        const entry = try allocator.create(Entry);
        entry.* = .{ .key = key, .allocator = allocator, .data = data, .loading = false, .resident = true };
        errdefer allocator.destroy(entry);
        try shard.map.put(allocator, key, entry);
        lruPushFront(shard, entry);
        shard.used_bytes += data.len;
        _ = self.inflight_bytes.fetchSub(data.len, .monotonic);
    }

    // ------------------------------------------------------------------
    // internals
    // ------------------------------------------------------------------

    fn shardFor(self: *PageCache, key: PageCacheKey) *Shard {
        return &self.shards[@intCast(hashKey(key) % SHARD_COUNT)];
    }

    /// Nonblocking admission. A miss may hold a store pin, so waiting here
    /// could prevent another operation from obtaining the store it needs to
    /// release memory. The caller may retry CacheBudgetExceeded after releasing
    /// those pins. CachePageTooLarge is permanent for this configured budget.
    fn reserveDecoded(self: *PageCache, bytes: usize) !void {
        if (bytes > self.budget_bytes) return error.CachePageTooLarge;
        if (self.tryReserveDecoded(bytes)) return;
        const target = self.budget_bytes - bytes;
        const start = self.evict_cursor.fetchAdd(1, .monotonic) % SHARD_COUNT;
        var visited: usize = 0;
        while (visited < SHARD_COUNT) : (visited += 1) {
            const idx = (start + visited) % SHARD_COUNT;
            self.evictShard(&self.shards[idx], target);
            if (self.tryReserveDecoded(bytes)) return;
        }
        return error.CacheBudgetExceeded;
    }

    fn tryReserveDecoded(self: *PageCache, bytes: usize) bool {
        var current = self.total_bytes.load(.monotonic);
        while (true) {
            if (current > self.budget_bytes or bytes > self.budget_bytes - current) return false;
            if (self.total_bytes.cmpxchgWeak(current, current + bytes, .monotonic, .monotonic)) |actual| {
                current = actual;
                continue;
            }
            var peak = self.peak_bytes.load(.monotonic);
            while (peak < current + bytes) {
                peak = self.peak_bytes.cmpxchgWeak(peak, current + bytes, .monotonic, .monotonic) orelse break;
            }
            _ = self.inflight_bytes.fetchAdd(bytes, .monotonic);
            return true;
        }
    }

    fn releaseInflight(self: *PageCache, bytes: usize) void {
        _ = self.inflight_bytes.fetchSub(bytes, .monotonic);
        _ = self.total_bytes.fetchSub(bytes, .monotonic);
    }

    fn evictShard(self: *PageCache, shard: *Shard, target: usize) void {
        shard.lock.lock();
        defer shard.lock.unlock();
        var cursor = shard.lru_tail;
        while (self.total_bytes.load(.monotonic) > target) {
            const victim = cursor orelse break;
            cursor = victim.lru_prev;
            // Keeping a pinned entry discoverable avoids duplicate decoding;
            // neither a pin nor an in-flight reservation can be reclaimed.
            if (victim.loading or victim.refs != 0) continue;
            lruUnlink(shard, victim);
            _ = shard.map.remove(victim.key);
            shard.used_bytes -= victim.data.len;
            shard.stats.evictions += 1;
            victim.resident = false;
            self.freeEntry(victim);
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
        entry.* = .{ .key = key, .allocator = allocator, .refs = 1, .loading = true, .resident = true };
        errdefer allocator.destroy(entry);
        try shard.map.put(allocator, key, entry);
        return .{ .entry = entry, .must_load = true, .wait_for_load = false };
    }

    /// A coalesced reader observes the original loader's result. On failure
    /// its pin is released here, without starting an unbounded retry chain.
    fn waitLoaded(self: *PageCache, shard: *Shard, entry: *Entry) !void {
        shard.lock.lock();
        defer shard.lock.unlock();
        while (entry.loading) shard.load_done.wait(&shard.lock);
        if (entry.load_error) |err| {
            self.unpinLocked(entry);
            return err;
        }
    }

    fn publishLoaded(self: *PageCache, shard: *Shard, entry: *Entry, raw: []u8, expect_crc: ?u32, expect_hash: ?[32]u8) void {
        shard.lock.lock();
        defer shard.lock.unlock();
        entry.data = raw;
        entry.loading = false;
        entry.verified_crc = expect_crc;
        entry.verified_hash = expect_hash;
        _ = self.inflight_bytes.fetchSub(raw.len, .monotonic);
        if (entry.resident) {
            lruPushFront(shard, entry);
            shard.used_bytes += raw.len;
        } else {
            entry.retired_charge = true;
            _ = self.evicted_pinned_bytes.fetchAdd(raw.len, .monotonic);
        }
        shard.load_done.broadcast();
    }

    fn publishFailed(self: *PageCache, shard: *Shard, entry: *Entry, err: anyerror) void {
        shard.lock.lock();
        defer shard.lock.unlock();
        entry.loading = false;
        entry.load_error = err;
        if (entry.resident) {
            entry.resident = false;
            _ = shard.map.remove(entry.key);
        }
        shard.load_done.broadcast();
        self.unpinLocked(entry);
    }

    fn unpin(self: *PageCache, shard: *Shard, entry: *Entry) void {
        shard.lock.lock();
        defer shard.lock.unlock();
        self.unpinLocked(entry);
    }

    fn unpinLocked(self: *PageCache, entry: *Entry) void {
        std.debug.assert(entry.refs > 0);
        entry.refs -= 1;
        if (entry.refs == 0 and !entry.resident) self.freeEntry(entry);
    }

    fn freeEntry(self: *PageCache, entry: *Entry) void {
        const bytes = entry.data.len;
        const retired = entry.retired_charge;
        const allocator = entry.allocator;
        if (bytes != 0) allocator.free(entry.data);
        allocator.destroy(entry);
        // Release admission only after the allocation has actually died.
        if (retired) _ = self.evicted_pinned_bytes.fetchSub(bytes, .monotonic);
        _ = self.total_bytes.fetchSub(bytes, .monotonic);
    }
};

fn loadPage(
    cache: *PageCache,
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
    try cache.reserveDecoded(page.raw_size);
    errdefer cache.releaseInflight(page.raw_size);
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

    // Raw streaming borrows the bounded DB scratch and copies directly into
    // caller memory. It needs no decoded allocation, even with zero budget.
    var streaming: PageCache = .{ .budget_bytes = 0 };
    defer streaming.deinit(allocator);
    try streaming.readThrough(&reader, key1, .{ .file_entry = 6001, .block_index = 0, .page_index = 0 }, .none, try object_key.pageKey(6001, 0, 0), &first);
    try std.testing.expectEqualSlices(u8, "abcd", &first);
    try std.testing.expectEqual(@as(usize, 0), streaming.allocatedBytes());
    try std.testing.expectError(error.CachePageTooLarge, streaming.prefetch(allocator, &reader, key1, .{ .file_entry = 6001, .block_index = 0, .page_index = 0 }, .none, try object_key.pageKey(6001, 0, 0), null, null));
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
        admission_retries: *std.atomic.Value(u64),

        fn run(ctx: *@This(), seed: u64) void {
            var prng = std.Random.DefaultPrng.init(seed);
            const random = prng.random();
            var round: usize = 0;
            while (round < 2000) : (round += 1) {
                const page: u32 = random.uintLessThan(u32, page_count);
                const off: usize = random.uintLessThan(usize, page_size);
                const len: usize = 1 + random.uintLessThan(usize, page_size - off);
                var buf: [page_size]u8 = undefined;
                @memset(&buf, 0xa5);
                const key: PageCacheKey = .{ .pack_id = 1, .pack_generation = 1, .file_entry = 6100, .block_index = 0, .page_index = page, .codec_identity = registry.NONE_VERSION_HASH };
                while (true) {
                    ctx.cache.copyRange(std.testing.allocator, ctx.reader, key, .{ .file_entry = 6100, .block_index = 0, .page_index = page }, .none, object_key.pageKey(6100, 0, page) catch unreachable, off, buf[0..len], null, null) catch |err| switch (err) {
                        error.CacheBudgetExceeded => {
                            // Admission is deliberately nonblocking. Competing
                            // readers may consume reclaimed capacity before us.
                            // Retry only after copyRange has released every pin;
                            // the direct PackReader here has no Volume store pin.
                            for (buf[0..len]) |byte| {
                                if (byte != 0xa5) {
                                    _ = ctx.errors.fetchAdd(1, .seq_cst);
                                    return;
                                }
                            }
                            _ = ctx.admission_retries.fetchAdd(1, .monotonic);
                            std.Thread.yield() catch {};
                            continue;
                        },
                        else => {
                            _ = ctx.errors.fetchAdd(1, .seq_cst);
                            return;
                        },
                    };
                    break;
                }
                const expect = ctx.payload[@as(usize, page) * page_size + off ..][0..len];
                if (!std.mem.eql(u8, buf[0..len], expect)) {
                    _ = ctx.errors.fetchAdd(1, .seq_cst);
                    return;
                }
            }
        }
    };
    var errors = std.atomic.Value(u32).init(0);
    var admission_retries = std.atomic.Value(u64).init(0);
    var ctx = Ctx{ .cache = &cache, .reader = &reader, .payload = &payload, .errors = &errors, .admission_retries = &admission_retries };
    var threads: [8]std.Thread = undefined;
    for (&threads, 0..) |*t, i| t.* = try std.Thread.spawn(.{}, Ctx.run, .{ &ctx, @as(u64, i) + 1 });
    for (&threads) |*t| t.join();
    try std.testing.expectEqual(@as(u32, 0), errors.load(.seq_cst));
    try std.testing.expect(cache.residentBytes() <= cache.budget_bytes);
    try std.testing.expect(cache.memoryStats().peak_allocated_bytes <= cache.budget_bytes);
    const s = cache.stats();
    try std.testing.expect(s.evictions > 0);
    try std.testing.expectEqual(@as(u64, 8 * 2000) + admission_retries.load(.monotonic), s.hits + s.misses + s.coalesced);
}

test "cache admission includes inflight and invalidated pinned bytes until freed" {
    const allocator = std.testing.allocator;
    var cache: PageCache = .{ .budget_bytes = 4 };
    defer cache.deinit(allocator);
    try std.testing.expectError(error.CachePageTooLarge, cache.reserveDecoded(5));
    try cache.reserveDecoded(4);
    try std.testing.expectError(error.CacheBudgetExceeded, cache.reserveDecoded(1));
    try std.testing.expectEqual(@as(usize, 4), cache.memoryStats().inflight_bytes);
    try std.testing.expectEqual(@as(usize, 4), cache.allocatedBytes());
    cache.releaseInflight(4);

    const key: PageCacheKey = .{ .pack_id = 1, .pack_generation = 1, .file_entry = 8, .block_index = 0, .page_index = 0, .codec_identity = 1 };
    try cache.insertOwned(allocator, key, try allocator.dupe(u8, "1234"));
    const shard = cache.shardFor(key);
    const pinned = try cache.acquire(shard, allocator, key);
    try std.testing.expectEqual(@as(usize, 4), cache.memoryStats().pinned_bytes);
    try std.testing.expectError(error.CacheBudgetExceeded, cache.reserveDecoded(1));
    cache.deinit(allocator);
    const retired = cache.memoryStats();
    try std.testing.expectEqual(@as(usize, 0), retired.resident_bytes);
    try std.testing.expectEqual(@as(usize, 4), retired.evicted_pinned_bytes);
    try std.testing.expectEqual(@as(usize, 4), retired.allocated_bytes);
    try std.testing.expectError(error.CacheBudgetExceeded, cache.reserveDecoded(1));
    try std.testing.expectEqualSlices(u8, "1234", pinned.entry.data);
    cache.unpin(shard, pinned.entry);
    try std.testing.expectEqual(@as(usize, 0), cache.allocatedBytes());
    try std.testing.expectEqual(@as(usize, 0), cache.memoryStats().evicted_pinned_bytes);
    try cache.reserveDecoded(4);
    cache.releaseInflight(4);
    try std.testing.expectEqual(@as(usize, 4), cache.memoryStats().peak_allocated_bytes);
}

test "cache coalesces publication and propagates load errors without retry" {
    const allocator = std.testing.allocator;
    var cache: PageCache = .{ .budget_bytes = 4 };
    defer cache.deinit(allocator);
    const key: PageCacheKey = .{ .pack_id = 1, .pack_generation = 1, .file_entry = 9, .block_index = 0, .page_index = 0, .codec_identity = 1 };
    const shard = cache.shardFor(key);
    const loader = try cache.acquire(shard, allocator, key);
    const waiter = try cache.acquire(shard, allocator, key);
    try std.testing.expect(loader.must_load);
    try std.testing.expect(waiter.wait_for_load);
    try std.testing.expectEqual(loader.entry, waiter.entry);
    // Insertion must not replace the placeholder owned by these two readers.
    try cache.insertOwned(allocator, key, try allocator.dupe(u8, "abcd"));
    try std.testing.expectEqual(loader.entry, shard.map.get(key).?);
    try std.testing.expectEqual(@as(usize, 0), cache.allocatedBytes());
    try cache.reserveDecoded(4);
    cache.publishLoaded(shard, loader.entry, try allocator.dupe(u8, "1234"), null, null);
    try cache.waitLoaded(shard, waiter.entry);
    try std.testing.expectEqual(@as(usize, 0), cache.memoryStats().inflight_bytes);
    try std.testing.expectEqual(@as(usize, 4), cache.memoryStats().resident_bytes);
    cache.unpin(shard, loader.entry);
    cache.unpin(shard, waiter.entry);
    cache.deinit(allocator);

    const bad_loader = try cache.acquire(shard, allocator, key);
    const bad_waiter = try cache.acquire(shard, allocator, key);
    cache.publishFailed(shard, bad_loader.entry, error.CacheBudgetExceeded);
    try std.testing.expectError(error.CacheBudgetExceeded, cache.waitLoaded(shard, bad_waiter.entry));
    try std.testing.expectEqual(@as(usize, 0), cache.residentCount());
    try std.testing.expectEqual(@as(usize, 0), cache.allocatedBytes());
}

test "cache simultaneous admission never exceeds decoded budget" {
    const Ctx = struct {
        cache: PageCache = .{ .budget_bytes = 12 },
        lock: sync.Mutex = .{},
        ready: sync.Condition = .{},
        done: usize = 0,
        admitted: usize = 0,
        unexpected_error: bool = false,
        release: bool = false,

        fn run(ctx: *@This()) void {
            const admission = ctx.cache.reserveDecoded(3);
            ctx.lock.lock();
            const admitted = if (admission) |_| success: {
                ctx.admitted += 1;
                break :success true;
            } else |err| failure: {
                if (err != error.CacheBudgetExceeded) ctx.unexpected_error = true;
                break :failure false;
            };
            ctx.done += 1;
            ctx.ready.broadcast();
            while (!ctx.release) ctx.ready.wait(&ctx.lock);
            ctx.lock.unlock();
            if (admitted) ctx.cache.releaseInflight(3);
        }
    };
    var ctx: Ctx = .{};
    defer ctx.cache.deinit(std.testing.allocator);
    var threads: [8]std.Thread = undefined;
    var spawned: usize = 0;
    defer {
        ctx.lock.lock();
        ctx.release = true;
        ctx.ready.broadcast();
        ctx.lock.unlock();
        for (threads[0..spawned]) |thread| thread.join();
    }
    for (&threads) |*thread| {
        thread.* = try std.Thread.spawn(.{}, Ctx.run, .{&ctx});
        spawned += 1;
    }
    ctx.lock.lock();
    while (ctx.done != threads.len) ctx.ready.wait(&ctx.lock);
    const admitted = ctx.admitted;
    const unexpected_error = ctx.unexpected_error;
    ctx.lock.unlock();
    try std.testing.expect(!unexpected_error);
    try std.testing.expectEqual(@as(usize, 4), admitted);
    try std.testing.expectEqual(@as(usize, 12), ctx.cache.allocatedBytes());
    try std.testing.expectEqual(@as(usize, 12), ctx.cache.memoryStats().peak_allocated_bytes);
}

test "prefetch shares verification and bounds streaming decode scratch" {
    const builder = @import("../build/pack_builder.zig");
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    const pack_path = "zig-cache-vfs-prefetch-bounded-pack";
    const source_path = "zig-cache-vfs-prefetch-bounded-source.bin";
    _ = std.Io.Dir.cwd().deleteTree(io, pack_path) catch {};
    _ = std.Io.Dir.cwd().deleteFile(io, source_path) catch {};
    defer _ = std.Io.Dir.cwd().deleteTree(io, pack_path) catch {};
    defer _ = std.Io.Dir.cwd().deleteFile(io, source_path) catch {};
    const payload = "abcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabc";
    try builder.writeSourceFileForTest(source_path, payload);
    try builder.createPack(pack_path, &.{.{ .source_path = source_path, .virtual_path = "/bounded.bin", .file_entry = 6701, .page_size = 128, .codec = .lz4 }}, .{});
    var reader = try pack_reader.PackReader.open(allocator, pack_path);
    defer reader.close(allocator);
    const key: PageCacheKey = .{ .pack_id = 1, .pack_generation = 1, .file_entry = 6701, .block_index = 0, .page_index = 0, .codec_identity = (try registry.codecIdentity(.lz4)).version_hash };
    const expected: page_value_fmt.PageIdentity = .{ .file_entry = 6701, .block_index = 0, .page_index = 0 };
    const page_key = try object_key.pageKey(6701, 0, 0);
    const encoded = try reader.readObjectBorrow(page_key);
    try std.testing.expectEqual(file_manifest_fmt.Codec.lz4, (try page_value_fmt.decodePageValue(encoded, expected)).codec);
    var cache: PageCache = .{ .budget_bytes = payload.len };
    defer cache.deinit(allocator);
    const crc = hash.crc32c(payload);
    try std.testing.expectError(error.ChecksumMismatch, cache.prefetch(allocator, &reader, key, expected, .lz4, page_key, crc ^ 1, null));
    try std.testing.expectEqual(@as(usize, 0), cache.allocatedBytes());
    try std.testing.expectEqual(@as(usize, 0), cache.residentCount());
    // Valid CRC/identity do not make a short decoded page satisfy a larger
    // logical span. Exercise the cold load and the subsequently resident hit.
    try std.testing.expectError(error.Corruption, cache.prefetchRange(allocator, &reader, key, expected, .lz4, page_key, 0, payload.len + 1, crc, hash.contentHash(payload)));
    try std.testing.expectError(error.Corruption, cache.prefetchRange(allocator, &reader, key, expected, .lz4, page_key, payload.len, 1, crc, hash.contentHash(payload)));
    try std.testing.expectError(error.Corruption, cache.prefetchRange(allocator, &reader, key, expected, .lz4, page_key, payload.len + 1, 0, crc, hash.contentHash(payload)));
    try std.testing.expectError(error.Corruption, cache.prefetchRange(allocator, &reader, key, expected, .lz4, page_key, 1, std.math.maxInt(usize), crc, hash.contentHash(payload)));
    try cache.prefetchRange(allocator, &reader, key, expected, .lz4, page_key, payload.len, 0, crc, hash.contentHash(payload));
    try cache.prefetchRange(allocator, &reader, key, expected, .lz4, page_key, 1, 3, crc, hash.contentHash(payload));
    try cache.prefetch(allocator, &reader, key, expected, .lz4, page_key, crc, hash.contentHash(payload));
    var part: [3]u8 = undefined;
    try cache.copyRange(allocator, &reader, key, expected, .lz4, page_key, 1, &part, crc, hash.contentHash(payload));
    try std.testing.expectEqualSlices(u8, "bca", &part);
    try std.testing.expectError(error.ChecksumMismatch, cache.prefetch(allocator, &reader, key, expected, .lz4, page_key, crc ^ 1, null));
    cache.deinit(allocator);
    var whole: [payload.len]u8 = undefined;
    try cache.readThrough(&reader, key, expected, .lz4, page_key, &whole);
    try std.testing.expectEqualSlices(u8, payload, &whole);
    try std.testing.expectEqual(@as(usize, 0), cache.allocatedBytes());
    try std.testing.expectEqual(@as(usize, 0), cache.residentCount());
    var tiny: PageCache = .{ .budget_bytes = payload.len - 1 };
    defer tiny.deinit(allocator);
    try std.testing.expectError(error.CachePageTooLarge, tiny.prefetch(allocator, &reader, key, expected, .lz4, page_key, null, null));
    try std.testing.expectError(error.CachePageTooLarge, tiny.readThrough(&reader, key, expected, .lz4, page_key, &whole));
    try std.testing.expectEqual(@as(usize, 0), tiny.allocatedBytes());
    try std.testing.expectEqual(@as(usize, 0), tiny.memoryStats().peak_allocated_bytes);
}

test "invalidating an inflight page retains its reservation through publication" {
    const allocator = std.testing.allocator;
    var cache: PageCache = .{ .budget_bytes = 4 };
    defer cache.deinit(allocator);
    const key: PageCacheKey = .{ .pack_id = 1, .pack_generation = 1, .file_entry = 10, .block_index = 0, .page_index = 0, .codec_identity = 1 };
    const shard = cache.shardFor(key);
    const loader = try cache.acquire(shard, allocator, key);
    const waiter = try cache.acquire(shard, allocator, key);
    try cache.reserveDecoded(4);
    cache.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 4), cache.memoryStats().inflight_bytes);
    try std.testing.expectError(error.CacheBudgetExceeded, cache.reserveDecoded(1));
    cache.publishLoaded(shard, loader.entry, try allocator.dupe(u8, "1234"), null, null);
    try cache.waitLoaded(shard, waiter.entry);
    const memory = cache.memoryStats();
    try std.testing.expectEqual(@as(usize, 0), memory.resident_bytes);
    try std.testing.expectEqual(@as(usize, 0), memory.inflight_bytes);
    try std.testing.expectEqual(@as(usize, 4), memory.evicted_pinned_bytes);
    cache.unpin(shard, loader.entry);
    try std.testing.expectEqual(@as(usize, 4), cache.allocatedBytes());
    cache.unpin(shard, waiter.entry);
    try std.testing.expectEqual(@as(usize, 0), cache.allocatedBytes());
}
