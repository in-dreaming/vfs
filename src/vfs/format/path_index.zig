const std = @import("std");
const fmt = @import("common.zig");
const hash = @import("../hash.zig");

pub const MAGIC: u32 = fmt.magic32("VPTH");
pub const VERSION: u16 = 1;
pub const HEADER_SIZE: usize = 48;
pub const ENTRY_SIZE: usize = 40;
const CRC_OFFSET: usize = 44;

pub const EntryInput = struct {
    normalized_path: []const u8,
    file_entry: u64,
    flags: u32 = 0,
    forced_path_hash: ?u64 = null,
};

pub const LookupResult = struct {
    file_entry: u64,
    flags: u32,
};

pub const DecodedEntry = struct {
    normalized_path: []u8,
    path_hash: u64,
    file_entry: u64,
    flags: u32,
};

/// A checked, non-owning view of a path index. The owner must keep the bytes
/// alive and immutable until the view is discarded. Create views with init;
/// lookups then walk one bucket without rechecking the whole index or its CRC.
pub const VerifiedView = struct {
    bytes: []const u8,
    meta: Meta,

    pub fn init(bytes: []const u8) !VerifiedView {
        return .{ .bytes = bytes, .meta = try verify(bytes) };
    }

    pub fn lookup(self: VerifiedView, normalized_path: []const u8) ?LookupResult {
        return self.lookupWithHash(normalized_path, hash.hashPath(normalized_path));
    }

    pub fn lookupWithHash(self: VerifiedView, normalized_path: []const u8, path_hash: u64) ?LookupResult {
        const bucket = @as(usize, @intCast(path_hash & @as(u64, self.meta.bucket_count - 1)));
        var cursor = fmt.getU32(self.bytes, self.meta.buckets_off + bucket * 4);
        while (cursor != 0) {
            const eoff = self.meta.entries_off + (@as(usize, cursor - 1) * ENTRY_SIZE);
            const entry_hash = fmt.getU64(self.bytes, eoff);
            if (entry_hash == path_hash) {
                const path_off = fmt.getU32(self.bytes, eoff + 16);
                const path_size = fmt.getU32(self.bytes, eoff + 20);
                const start = self.meta.strings_off + path_off;
                if (std.mem.eql(u8, self.bytes[start..][0..path_size], normalized_path)) {
                    return .{ .file_entry = fmt.getU64(self.bytes, eoff + 8), .flags = fmt.getU32(self.bytes, eoff + 24) };
                }
            }
            cursor = fmt.getU32(self.bytes, eoff + 28);
        }
        return null;
    }
};

pub fn collectEntries(allocator: std.mem.Allocator, bytes: []const u8) ![]DecodedEntry {
    const meta = try verify(bytes);
    var out = try allocator.alloc(DecodedEntry, meta.entry_count);
    var initialized: usize = 0;
    errdefer {
        for (out[0..initialized]) |entry| allocator.free(entry.normalized_path);
        allocator.free(out);
    }
    var i: usize = 0;
    while (i < meta.entry_count) : (i += 1) {
        const eoff = meta.entries_off + i * ENTRY_SIZE;
        const path_off = fmt.getU32(bytes, eoff + 16);
        const path_size = fmt.getU32(bytes, eoff + 20);
        const start = meta.strings_off + path_off;
        const end = start + path_size;
        out[i] = .{ .normalized_path = try allocator.dupe(u8, bytes[start..end]), .path_hash = fmt.getU64(bytes, eoff + 0), .file_entry = fmt.getU64(bytes, eoff + 8), .flags = fmt.getU32(bytes, eoff + 24) };
        initialized += 1;
    }
    return out;
}

pub fn freeDecodedEntries(allocator: std.mem.Allocator, entries: []DecodedEntry) void {
    for (entries) |entry| allocator.free(entry.normalized_path);
    allocator.free(entries);
}

pub fn encodePathIndex(allocator: std.mem.Allocator, entries: []const EntryInput) ![]u8 {
    if (entries.len > std.math.maxInt(u32)) return error.InvalidArgument;
    var string_size: usize = 0;
    for (entries) |entry| {
        if (entry.file_entry == 0 or entry.normalized_path.len == 0) return error.InvalidArgument;
        string_size = try std.math.add(usize, string_size, entry.normalized_path.len);
    }
    const bucket_count = bucketCount(entries.len);
    const bucket_bytes = bucket_count * 4;
    const entries_bytes = entries.len * ENTRY_SIZE;
    const total = HEADER_SIZE + bucket_bytes + entries_bytes + string_size;
    var out = try allocator.alloc(u8, total);
    errdefer allocator.free(out);
    @memset(out, 0);

    const buckets_off = HEADER_SIZE;
    const entries_off = buckets_off + bucket_bytes;
    const strings_off = entries_off + entries_bytes;

    fmt.putU32(out, 0, MAGIC);
    fmt.putU16(out, 4, VERSION);
    fmt.putU16(out, 6, HEADER_SIZE);
    fmt.putU32(out, 8, @intCast(bucket_count));
    fmt.putU32(out, 12, @intCast(entries.len));
    fmt.putU32(out, 16, @intCast(string_size));
    fmt.putU32(out, 20, @intCast(buckets_off));
    fmt.putU32(out, 24, @intCast(entries_off));
    fmt.putU32(out, 28, @intCast(strings_off));
    fmt.putU32(out, 32, 0);
    fmt.putU32(out, 36, 0);
    fmt.putU32(out, 40, 0);
    fmt.putU32(out, CRC_OFFSET, 0);

    var string_cursor: u32 = 0;
    for (entries, 0..) |entry, i| {
        const path_hash = entry.forced_path_hash orelse hash.hashPath(entry.normalized_path);
        const bucket = @as(usize, @intCast(path_hash & @as(u64, bucket_count - 1)));
        const bucket_slot = buckets_off + bucket * 4;
        const previous_head = fmt.getU32(out, bucket_slot);
        const entry_off = entries_off + i * ENTRY_SIZE;
        fmt.putU64(out, entry_off + 0, path_hash);
        fmt.putU64(out, entry_off + 8, entry.file_entry);
        fmt.putU32(out, entry_off + 16, string_cursor);
        fmt.putU32(out, entry_off + 20, @intCast(entry.normalized_path.len));
        fmt.putU32(out, entry_off + 24, entry.flags);
        fmt.putU32(out, entry_off + 28, previous_head);
        fmt.putU32(out, entry_off + 32, 0);
        fmt.putU32(out, entry_off + 36, 0);
        fmt.putU32(out, bucket_slot, @intCast(i + 1));
        @memcpy(out[strings_off + string_cursor ..][0..entry.normalized_path.len], entry.normalized_path);
        string_cursor += @intCast(entry.normalized_path.len);
    }

    fmt.putU32(out, CRC_OFFSET, fmt.crc32c(out));
    return out;
}

test "path index can collect entries for rewrite" {
    const allocator = std.testing.allocator;
    const inputs = [_]EntryInput{ .{ .normalized_path = "a.txt", .file_entry = 1 }, .{ .normalized_path = "b.txt", .file_entry = 2 } };
    const encoded = try encodePathIndex(allocator, &inputs);
    defer allocator.free(encoded);
    const entries = try collectEntries(allocator, encoded);
    defer freeDecodedEntries(allocator, entries);
    try std.testing.expectEqual(@as(usize, 2), entries.len);
    try std.testing.expectEqualSlices(u8, "a.txt", entries[0].normalized_path);
}

pub fn lookup(bytes: []const u8, normalized_path: []const u8) !?LookupResult {
    return (try VerifiedView.init(bytes)).lookup(normalized_path);
}

pub fn lookupWithHash(bytes: []const u8, normalized_path: []const u8, path_hash: u64) !?LookupResult {
    return (try VerifiedView.init(bytes)).lookupWithHash(normalized_path, path_hash);
}

const Meta = struct {
    bucket_count: u32,
    entry_count: u32,
    string_size: u32,
    buckets_off: usize,
    entries_off: usize,
    strings_off: usize,
};

pub fn verify(bytes: []const u8) !Meta {
    if (bytes.len < HEADER_SIZE) return error.Corruption;
    if (fmt.getU32(bytes, 0) != MAGIC) return error.Corruption;
    if (fmt.getU16(bytes, 4) != VERSION) return error.UnsupportedVersion;
    if (fmt.getU16(bytes, 6) != HEADER_SIZE) return error.Corruption;
    try fmt.requireZero(bytes[32..44]);
    const bucket_count = fmt.getU32(bytes, 8);
    const entry_count = fmt.getU32(bytes, 12);
    const string_size = fmt.getU32(bytes, 16);
    if (bucket_count == 0 or !std.math.isPowerOfTwo(bucket_count)) return error.Corruption;
    const buckets_off = @as(usize, fmt.getU32(bytes, 20));
    const entries_off = @as(usize, fmt.getU32(bytes, 24));
    const strings_off = @as(usize, fmt.getU32(bytes, 28));
    if (buckets_off != HEADER_SIZE) return error.Corruption;
    const bucket_bytes = std.math.mul(usize, bucket_count, 4) catch return error.Corruption;
    const entry_bytes = std.math.mul(usize, entry_count, ENTRY_SIZE) catch return error.Corruption;
    if (entries_off != (std.math.add(usize, buckets_off, bucket_bytes) catch return error.Corruption)) return error.Corruption;
    if (strings_off != (std.math.add(usize, entries_off, entry_bytes) catch return error.Corruption)) return error.Corruption;
    if (bytes.len != (std.math.add(usize, strings_off, string_size) catch return error.Corruption)) return error.Corruption;

    const crc = fmt.getU32(bytes, CRC_OFFSET);
    if (fmt.crc32cWithZeroU32(bytes, CRC_OFFSET) != crc) return error.Corruption;

    var i: usize = 0;
    while (i < entry_count) : (i += 1) {
        const eoff = entries_off + i * ENTRY_SIZE;
        try fmt.requireZero(bytes[eoff + 32 .. eoff + 40]);
        if (fmt.getU64(bytes, eoff + 8) == 0) return error.Corruption;
        const path_off = fmt.getU32(bytes, eoff + 16);
        const path_size = fmt.getU32(bytes, eoff + 20);
        if (path_size == 0 or path_off > string_size or path_size > string_size - path_off) return error.Corruption;
        if (fmt.getU32(bytes, eoff + 28) > entry_count) return error.Corruption;
    }

    // Each bucket has one singly linked chain. Stored-hash membership prevents
    // two different buckets from sharing an entry; revisiting within a chain
    // can only be a cycle. Thus an aggregate visit budget detects cycles and a
    // final count detects orphans without a visited allocation or O(N^2) scans.
    // Compare stored hash bits, not hashPath(path): forced-hash collision tests
    // and the full-path comparison remain valid.
    var visited: usize = 0;
    for (0..bucket_count) |bucket| {
        var cursor = fmt.getU32(bytes, buckets_off + bucket * 4);
        while (cursor != 0) {
            if (cursor > entry_count or visited == entry_count) return error.Corruption;
            const eoff = entries_off + @as(usize, cursor - 1) * ENTRY_SIZE;
            if ((fmt.getU64(bytes, eoff) & @as(u64, bucket_count - 1)) != bucket) return error.Corruption;
            visited += 1;
            cursor = fmt.getU32(bytes, eoff + 28);
        }
    }
    if (visited != entry_count) return error.Corruption;
    return .{ .bucket_count = bucket_count, .entry_count = entry_count, .string_size = string_size, .buckets_off = buckets_off, .entries_off = entries_off, .strings_off = strings_off };
}

fn bucketCount(entry_count: usize) usize {
    var n: usize = 1;
    const wanted = @max(entry_count * 2, 1);
    while (n < wanted) n <<= 1;
    return n;
}

test "path index compares full path under hash collision" {
    const allocator = std.testing.allocator;
    const forced: u64 = 0x1234567812345678;
    const entries = [_]EntryInput{
        .{ .normalized_path = "assets/a.txt", .file_entry = 11, .forced_path_hash = forced },
        .{ .normalized_path = "assets/b.txt", .file_entry = 22, .forced_path_hash = forced },
    };
    const encoded = try encodePathIndex(allocator, &entries);
    defer allocator.free(encoded);

    const a = (try lookupWithHash(encoded, "assets/a.txt", forced)).?;
    const b = (try lookupWithHash(encoded, "assets/b.txt", forced)).?;
    try std.testing.expectEqual(@as(u64, 11), a.file_entry);
    try std.testing.expectEqual(@as(u64, 22), b.file_entry);
    try std.testing.expectEqual(@as(?LookupResult, null), try lookupWithHash(encoded, "assets/c.txt", forced));

    const view = try VerifiedView.init(encoded);
    for (0..128) |_| {
        try std.testing.expectEqual(@as(u64, 11), view.lookupWithHash("assets/a.txt", forced).?.file_entry);
        try std.testing.expectEqual(@as(u64, 22), view.lookupWithHash("assets/b.txt", forced).?.file_entry);
        try std.testing.expectEqual(@as(?LookupResult, null), view.lookupWithHash("assets/c.txt", forced));
    }
}

test "path index rejects CRC-valid out-of-range chain links" {
    const allocator = std.testing.allocator;
    const encoded = try encodePathIndex(allocator, &.{.{ .normalized_path = "a.txt", .file_entry = 1 }});
    defer allocator.free(encoded);
    const entries_off = fmt.getU32(encoded, 24);
    fmt.putU32(encoded, entries_off + 28, 2);
    fmt.putU32(encoded, CRC_OFFSET, fmt.crc32cWithZeroU32(encoded, CRC_OFFSET));
    try std.testing.expectError(error.Corruption, verify(encoded));
}

test "path index rejects CRC-valid malformed buckets chains and ranges" {
    const allocator = std.testing.allocator;
    const entries = [_]EntryInput{
        .{ .normalized_path = "a.txt", .file_entry = 11, .forced_path_hash = 0 },
        .{ .normalized_path = "b.txt", .file_entry = 22, .forced_path_hash = 0 },
    };
    const valid = try encodePathIndex(allocator, &entries);
    defer allocator.free(valid);
    const Mutation = enum {
        head_range,
        link_range,
        self_cycle,
        multi_entry_cycle,
        orphan,
        unreachable_cycle,
        duplicate_head,
        wrong_bucket,
        wrong_hash_membership,
        path_offset,
        path_size,
        empty_path,
        zero_file_entry,
        reserved_entry,
        bucket_offset,
        entry_offset,
        string_offset,
        entry_count,
        bucket_count,
    };
    inline for (std.meta.tags(Mutation)) |mutation| {
        const encoded = try allocator.dupe(u8, valid);
        defer allocator.free(encoded);
        const buckets_off: usize = fmt.getU32(encoded, 20);
        const entries_off: usize = fmt.getU32(encoded, 24);
        const second = entries_off + ENTRY_SIZE;
        const string_size = fmt.getU32(encoded, 16);
        switch (mutation) {
            .head_range => fmt.putU32(encoded, buckets_off, 3),
            .link_range => fmt.putU32(encoded, second + 28, 3),
            .self_cycle => fmt.putU32(encoded, second + 28, 2),
            .multi_entry_cycle => fmt.putU32(encoded, entries_off + 28, 2),
            .orphan => fmt.putU32(encoded, buckets_off, 1),
            .unreachable_cycle => {
                fmt.putU32(encoded, buckets_off, 1);
                fmt.putU32(encoded, second + 28, 2);
            },
            .duplicate_head => fmt.putU32(encoded, buckets_off + 4, 2),
            .wrong_bucket => {
                fmt.putU32(encoded, buckets_off, 0);
                fmt.putU32(encoded, buckets_off + 4, 2);
            },
            .wrong_hash_membership => fmt.putU64(encoded, entries_off, 1),
            .path_offset => fmt.putU32(encoded, entries_off + 16, std.math.maxInt(u32)),
            .path_size => fmt.putU32(encoded, entries_off + 20, string_size + 1),
            .empty_path => fmt.putU32(encoded, entries_off + 20, 0),
            .zero_file_entry => fmt.putU64(encoded, entries_off + 8, 0),
            .reserved_entry => fmt.putU32(encoded, entries_off + 32, 1),
            .bucket_offset => fmt.putU32(encoded, 20, 0),
            .entry_offset => fmt.putU32(encoded, 24, std.math.maxInt(u32)),
            .string_offset => fmt.putU32(encoded, 28, std.math.maxInt(u32)),
            .entry_count => fmt.putU32(encoded, 12, std.math.maxInt(u32)),
            .bucket_count => fmt.putU32(encoded, 8, 0x80000000),
        }
        fmt.putU32(encoded, CRC_OFFSET, fmt.crc32cWithZeroU32(encoded, CRC_OFFSET));
        try std.testing.expectError(error.Corruption, verify(encoded));
        try std.testing.expectError(error.Corruption, VerifiedView.init(encoded));
        // Raw-byte wrappers verify the entire graph even if the queried path
        // would match before a malformed link, or belongs to another bucket.
        try std.testing.expectError(error.Corruption, lookupWithHash(encoded, "b.txt", 0));
        try std.testing.expectError(error.Corruption, lookup(encoded, "missing.txt"));
        try std.testing.expectError(error.Corruption, collectEntries(allocator, encoded));
    }
}

test "path index verified view repeats lookups and supports empty indexes" {
    const allocator = std.testing.allocator;
    const encoded = try encodePathIndex(allocator, &.{
        .{ .normalized_path = "assets/a.txt", .file_entry = 0x1_0000_0001, .flags = 3 },
        .{ .normalized_path = "assets/b.txt", .file_entry = 0x2_0000_0001, .flags = 7 },
    });
    defer allocator.free(encoded);
    const view = try VerifiedView.init(encoded);
    for (0..128) |_| {
        try std.testing.expectEqualDeep(LookupResult{ .file_entry = 0x1_0000_0001, .flags = 3 }, view.lookup("assets/a.txt").?);
        try std.testing.expectEqualDeep(LookupResult{ .file_entry = 0x2_0000_0001, .flags = 7 }, view.lookup("assets/b.txt").?);
        try std.testing.expectEqual(@as(?LookupResult, null), view.lookup("assets/c.txt"));
    }
    const empty = try encodePathIndex(allocator, &.{});
    defer allocator.free(empty);
    const empty_view = try VerifiedView.init(empty);
    try std.testing.expectEqual(@as(?LookupResult, null), empty_view.lookup("anything.txt"));
    try std.testing.expectEqual(@as(?LookupResult, null), empty_view.lookup(""));
}

test "path index verified view accepts valid forward chain links" {
    const allocator = std.testing.allocator;
    const encoded = try encodePathIndex(allocator, &.{
        .{ .normalized_path = "a.txt", .file_entry = 1, .forced_path_hash = 0 },
        .{ .normalized_path = "b.txt", .file_entry = 2, .forced_path_hash = 0 },
    });
    defer allocator.free(encoded);
    const buckets_off: usize = fmt.getU32(encoded, 20);
    const entries_off: usize = fmt.getU32(encoded, 24);
    // Producers need not use the encoder's reverse insertion order.
    fmt.putU32(encoded, buckets_off, 1);
    fmt.putU32(encoded, entries_off + 28, 2);
    fmt.putU32(encoded, entries_off + ENTRY_SIZE + 28, 0);
    fmt.putU32(encoded, CRC_OFFSET, fmt.crc32cWithZeroU32(encoded, CRC_OFFSET));
    const view = try VerifiedView.init(encoded);
    try std.testing.expectEqual(@as(u64, 1), view.lookupWithHash("a.txt", 0).?.file_entry);
    try std.testing.expectEqual(@as(u64, 2), view.lookupWithHash("b.txt", 0).?.file_entry);
    try std.testing.expectEqual(@as(?LookupResult, null), view.lookupWithHash("c.txt", 0));
}

test "path index verifies CRC and version before creating a view" {
    const allocator = std.testing.allocator;
    const encoded = try encodePathIndex(allocator, &.{.{ .normalized_path = "a.txt", .file_entry = 1 }});
    defer allocator.free(encoded);
    encoded[encoded.len - 1] ^= 1;
    try std.testing.expectError(error.Corruption, VerifiedView.init(encoded));
    encoded[encoded.len - 1] ^= 1;
    fmt.putU16(encoded, 4, VERSION + 1);
    fmt.putU32(encoded, CRC_OFFSET, fmt.crc32cWithZeroU32(encoded, CRC_OFFSET));
    try std.testing.expectError(error.UnsupportedVersion, VerifiedView.init(encoded));
}

test "path index collector cleans partial initialization on allocation failure" {
    const allocator = std.testing.allocator;
    const encoded = try encodePathIndex(allocator, &.{
        .{ .normalized_path = "a.txt", .file_entry = 1 },
        .{ .normalized_path = "b.txt", .file_entry = 2 },
    });
    defer allocator.free(encoded);
    const Harness = struct {
        fn collect(failing_allocator: std.mem.Allocator, bytes: []const u8) !void {
            const entries = try collectEntries(failing_allocator, bytes);
            defer freeDecodedEntries(failing_allocator, entries);
            try std.testing.expectEqual(@as(usize, 2), entries.len);
        }
    };
    try std.testing.checkAllAllocationFailures(allocator, Harness.collect, .{encoded});
}
