const std = @import("std");
const pack_reader = @import("../pack/pack_reader.zig");
const page_value_fmt = @import("../format/page_value.zig");
const file_manifest_fmt = @import("../format/file_manifest.zig");
const registry = @import("../compress/registry.zig");
const object_key = @import("../object_key.zig");

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

    pub fn deinit(self: *PageCache, allocator: std.mem.Allocator) void {
        for (self.entries.items) |entry| allocator.free(entry.data);
        self.entries.deinit(allocator);
        self.* = .{};
    }

    pub fn getOrLoad(
        self: *PageCache,
        allocator: std.mem.Allocator,
        reader: *pack_reader.PackReader,
        key: PageCacheKey,
        expected: page_value_fmt.PageIdentity,
        codec: file_manifest_fmt.Codec,
    ) ![]const u8 {
        if (key.file_entry == 0) return error.InvalidArgument;
        for (self.entries.items) |*entry| {
            if (keyEqual(entry.key, key)) {
                self.clock += 1;
                entry.last_used = self.clock;
                self.stats.hits += 1;
                return entry.data;
            }
        }
        self.stats.misses += 1;
        const page_bytes = try reader.readObjectAlloc(allocator, try object_key.pageKey(expected.file_entry, expected.block_index, expected.page_index));
        defer allocator.free(page_bytes);
        return self.loadDecoded(allocator, key, expected, codec, page_bytes);
    }

    pub fn getOrLoadObject(
        self: *PageCache,
        allocator: std.mem.Allocator,
        reader: *pack_reader.PackReader,
        key: PageCacheKey,
        expected: page_value_fmt.PageIdentity,
        codec: file_manifest_fmt.Codec,
        page_object_key: u64,
    ) ![]const u8 {
        if (key.file_entry == 0) return error.InvalidArgument;
        for (self.entries.items) |*entry| {
            if (keyEqual(entry.key, key)) {
                self.clock += 1;
                entry.last_used = self.clock;
                self.stats.hits += 1;
                return entry.data;
            }
        }
        self.stats.misses += 1;
        const page_bytes = try reader.readObjectAlloc(allocator, page_object_key);
        defer allocator.free(page_bytes);
        return self.loadDecoded(allocator, key, expected, codec, page_bytes);
    }

    fn loadDecoded(
        self: *PageCache,
        allocator: std.mem.Allocator,
        key: PageCacheKey,
        expected: page_value_fmt.PageIdentity,
        codec: file_manifest_fmt.Codec,
        page_bytes: []const u8,
    ) ![]const u8 {
        const page = try page_value_fmt.decodePageValue(page_bytes, expected);
        const raw = try registry.decompressPage(allocator, codec, page.payload, page.raw_size, page.raw_crc);
        errdefer allocator.free(raw);
        try self.insertOwned(allocator, key, raw);
        return self.entries.items[self.entries.items.len - 1].data;
    }

    fn insertOwned(self: *PageCache, allocator: std.mem.Allocator, key: PageCacheKey, data: []u8) !void {
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
    const first = try cache.getOrLoad(allocator, &reader, key1, .{ .file_entry = 6001, .block_index = 0, .page_index = 0 }, .none);
    try std.testing.expectEqualSlices(u8, "abcd", first);
    const second = try cache.getOrLoad(allocator, &reader, key1, .{ .file_entry = 6001, .block_index = 0, .page_index = 0 }, .none);
    try std.testing.expectEqualSlices(u8, "abcd", second);
    try std.testing.expectEqual(@as(u64, 1), cache.stats.misses);
    try std.testing.expectEqual(@as(u64, 1), cache.stats.hits);
    var key2 = key1;
    key2.pack_generation = 2;
    _ = try cache.getOrLoad(allocator, &reader, key2, .{ .file_entry = 6001, .block_index = 0, .page_index = 0 }, .none);
    try std.testing.expectEqual(@as(u64, 2), cache.stats.misses);
}
