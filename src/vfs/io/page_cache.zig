const std = @import("std");
const pack_reader = @import("../pack/pack_reader.zig");
const page_value_fmt = @import("../format/page_value.zig");
const file_manifest_fmt = @import("../format/file_manifest.zig");
const registry = @import("../compress/registry.zig");
const object_key = @import("../object_key.zig");
const hash = @import("../hash.zig");

pub const PageCacheKey = struct {
    pack_id: u32,
    pack_generation: u64,
    file_entry: u64,
    block_index: u32,
    page_index: u32,
    codec_identity: u64,
};

const Entry = struct {
    key: PageCacheKey,
    data: []u8,
    last_used: u64,
};

pub const Stats = struct {
    hits: u64 = 0,
    misses: u64 = 0,
    evictions: u64 = 0,
};

pub const PageCache = struct {
    budget_bytes: usize = 8 * 1024 * 1024,
    used_bytes: usize = 0,
    clock: u64 = 1,
    entries: std.ArrayList(Entry) = .empty,
    stats: Stats = .{},
    lock: std.atomic.Mutex = .unlocked,

    pub fn deinit(self: *PageCache, allocator: std.mem.Allocator) void {
        lockMutex(&self.lock);
        for (self.entries.items) |entry| allocator.free(entry.data);
        self.entries.deinit(allocator);
        self.lock.unlock();
        self.* = .{};
    }

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
        if (try self.copyHit(key, page_off, dst, expect_crc, expect_hash)) return;

        self.noteMiss();
        const page_bytes = try reader.readObjectAlloc(allocator, page_object_key);
        defer allocator.free(page_bytes);
        const page = try page_value_fmt.decodePageValue(page_bytes, expected);
        const raw = try registry.decompressPage(allocator, codec, page.payload, page.raw_size, page.raw_crc);
        errdefer allocator.free(raw);

        lockMutex(&self.lock);
        defer self.lock.unlock();
        if (self.findLocked(key)) |entry| {
            allocator.free(raw);
            try copyFromEntry(entry, page_off, dst, expect_crc, expect_hash);
            self.clock += 1;
            entry.last_used = self.clock;
            self.stats.hits += 1;
            return;
        }
        try self.insertOwnedLocked(allocator, key, raw);
        const stored = &self.entries.items[self.entries.items.len - 1];
        try copyFromEntry(stored, page_off, dst, expect_crc, expect_hash);
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

    fn copyHit(self: *PageCache, key: PageCacheKey, page_off: usize, dst: []u8, expect_crc: ?u32, expect_hash: ?[32]u8) !bool {
        lockMutex(&self.lock);
        defer self.lock.unlock();
        if (self.findLocked(key)) |entry| {
            try copyFromEntry(entry, page_off, dst, expect_crc, expect_hash);
            self.clock += 1;
            entry.last_used = self.clock;
            self.stats.hits += 1;
            return true;
        }
        return false;
    }

    fn noteMiss(self: *PageCache) void {
        lockMutex(&self.lock);
        defer self.lock.unlock();
        self.stats.misses += 1;
    }

    fn findLocked(self: *PageCache, key: PageCacheKey) ?*Entry {
        for (self.entries.items) |*entry| {
            if (keyEqual(entry.key, key)) return entry;
        }
        return null;
    }

    fn insertOwned(self: *PageCache, allocator: std.mem.Allocator, key: PageCacheKey, data: []u8) !void {
        lockMutex(&self.lock);
        defer self.lock.unlock();
        try self.insertOwnedLocked(allocator, key, data);
    }

    fn insertOwnedLocked(self: *PageCache, allocator: std.mem.Allocator, key: PageCacheKey, data: []u8) !void {
        while (self.entries.items.len != 0 and self.used_bytes + data.len > self.budget_bytes) {
            self.evictOne(allocator);
        }
        self.clock += 1;
        try self.entries.append(allocator, .{ .key = key, .data = data, .last_used = self.clock });
        self.used_bytes += data.len;
    }

    fn evictOne(self: *PageCache, allocator: std.mem.Allocator) void {
        var victim: usize = 0;
        var oldest = self.entries.items[0].last_used;
        for (self.entries.items, 0..) |entry, i| {
            if (entry.last_used < oldest) {
                oldest = entry.last_used;
                victim = i;
            }
        }
        const removed = self.entries.swapRemove(victim);
        self.used_bytes -= removed.data.len;
        allocator.free(removed.data);
        self.stats.evictions += 1;
    }
};

fn copyFromEntry(entry: *Entry, page_off: usize, dst: []u8, expect_crc: ?u32, expect_hash: ?[32]u8) !void {
    if (expect_crc) |crc| {
        if (hash.crc32c(entry.data) != crc) return error.ChecksumMismatch;
    }
    if (expect_hash) |want| {
        if (!std.mem.eql(u8, &hash.contentHash(entry.data), &want)) return error.ChecksumMismatch;
    }
    if (page_off > entry.data.len or dst.len > entry.data.len - page_off) return error.Corruption;
    @memcpy(dst, entry.data[page_off..][0..dst.len]);
}

fn keyEqual(a: PageCacheKey, b: PageCacheKey) bool {
    return a.pack_id == b.pack_id and
        a.pack_generation == b.pack_generation and
        a.file_entry == b.file_entry and
        a.block_index == b.block_index and
        a.page_index == b.page_index and
        a.codec_identity == b.codec_identity;
}

fn lockMutex(m: *std.atomic.Mutex) void {
    while (!m.tryLock()) std.atomic.spinLoopHint();
}

test "page cache key includes generation and evicts by budget" {
    var cache: PageCache = .{ .budget_bytes = 4 };
    defer cache.deinit(std.testing.allocator);
    try cache.insertOwned(std.testing.allocator, .{ .pack_id = 1, .pack_generation = 1, .file_entry = 1, .block_index = 0, .page_index = 0, .codec_identity = 1 }, try std.testing.allocator.dupe(u8, "1234"));
    try cache.insertOwned(std.testing.allocator, .{ .pack_id = 1, .pack_generation = 2, .file_entry = 1, .block_index = 0, .page_index = 0, .codec_identity = 1 }, try std.testing.allocator.dupe(u8, "abcd"));
    try std.testing.expectEqual(@as(usize, 1), cache.entries.items.len);
    try std.testing.expectEqual(@as(u64, 1), cache.stats.evictions);
    try std.testing.expectEqual(@as(u64, 2), cache.entries.items[0].key.pack_generation);
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
    var cache: PageCache = .{ .budget_bytes = 16 };
    defer cache.deinit(allocator);
    const key1: PageCacheKey = .{ .pack_id = 1, .pack_generation = 1, .file_entry = 6001, .block_index = 0, .page_index = 0, .codec_identity = registry.NONE_VERSION_HASH };
    var first: [4]u8 = undefined;
    try cache.getOrLoad(allocator, &reader, key1, .{ .file_entry = 6001, .block_index = 0, .page_index = 0 }, .none, &first);
    try std.testing.expectEqualSlices(u8, "abcd", &first);
    var second: [4]u8 = undefined;
    try cache.getOrLoad(allocator, &reader, key1, .{ .file_entry = 6001, .block_index = 0, .page_index = 0 }, .none, &second);
    try std.testing.expectEqualSlices(u8, "abcd", &second);
    try std.testing.expectEqual(@as(u64, 1), cache.stats.misses);
    try std.testing.expectEqual(@as(u64, 1), cache.stats.hits);
    var key2 = key1;
    key2.pack_generation = 2;
    var third: [4]u8 = undefined;
    try cache.getOrLoad(allocator, &reader, key2, .{ .file_entry = 6001, .block_index = 0, .page_index = 0 }, .none, &third);
    try std.testing.expectEqual(@as(u64, 2), cache.stats.misses);
}
