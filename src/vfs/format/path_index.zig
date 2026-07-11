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

pub fn collectEntries(allocator: std.mem.Allocator, bytes: []const u8) ![]DecodedEntry {
    const meta = try verify(bytes);
    var out = try allocator.alloc(DecodedEntry, meta.entry_count);
    errdefer {
        for (out) |entry| allocator.free(entry.normalized_path);
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
    const inputs = [_]EntryInput{.{ .normalized_path = "a.txt", .file_entry = 1 }, .{ .normalized_path = "b.txt", .file_entry = 2 }};
    const encoded = try encodePathIndex(allocator, &inputs);
    defer allocator.free(encoded);
    const entries = try collectEntries(allocator, encoded);
    defer freeDecodedEntries(allocator, entries);
    try std.testing.expectEqual(@as(usize, 2), entries.len);
    try std.testing.expectEqualSlices(u8, "a.txt", entries[0].normalized_path);
}

pub fn lookup(bytes: []const u8, normalized_path: []const u8) !?LookupResult {
    const h = hash.hashPath(normalized_path);
    return lookupWithHash(bytes, normalized_path, h);
}

pub fn lookupWithHash(bytes: []const u8, normalized_path: []const u8, path_hash: u64) !?LookupResult {
    const meta = try verify(bytes);
    const bucket = @as(usize, @intCast(path_hash & @as(u64, meta.bucket_count - 1)));
    var cursor = fmt.getU32(bytes, meta.buckets_off + bucket * 4);
    var guard: u32 = 0;
    while (cursor != 0) {
        if (cursor > meta.entry_count) return error.Corruption;
        if (guard > meta.entry_count) return error.Corruption;
        guard += 1;
        const eoff = meta.entries_off + (@as(usize, cursor - 1) * ENTRY_SIZE);
        const entry_hash = fmt.getU64(bytes, eoff + 0);
        const file_entry = fmt.getU64(bytes, eoff + 8);
        const path_off = fmt.getU32(bytes, eoff + 16);
        const path_size = fmt.getU32(bytes, eoff + 20);
        const flags = fmt.getU32(bytes, eoff + 24);
        const next = fmt.getU32(bytes, eoff + 28);
        const start = meta.strings_off + path_off;
        const end = start + path_size;
        if (end > bytes.len) return error.Corruption;
        if (entry_hash == path_hash and std.mem.eql(u8, bytes[start..end], normalized_path)) {
            if (file_entry == 0) return error.Corruption;
            return .{ .file_entry = file_entry, .flags = flags };
        }
        cursor = next;
    }
    return null;
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
    if (entries_off != buckets_off + @as(usize, bucket_count) * 4) return error.Corruption;
    if (strings_off != entries_off + @as(usize, entry_count) * ENTRY_SIZE) return error.Corruption;
    if (bytes.len != strings_off + string_size) return error.Corruption;

    const crc = fmt.getU32(bytes, CRC_OFFSET);
    if (fmt.crc32cWithZeroU32(bytes, CRC_OFFSET) != crc) return error.Corruption;

    var i: usize = 0;
    while (i < entry_count) : (i += 1) {
        const eoff = entries_off + i * ENTRY_SIZE;
        try fmt.requireZero(bytes[eoff + 32 .. eoff + 40]);
        if (fmt.getU64(bytes, eoff + 8) == 0) return error.Corruption;
        const path_off = fmt.getU32(bytes, eoff + 16);
        const path_size = fmt.getU32(bytes, eoff + 20);
        if (@as(usize, path_off) + @as(usize, path_size) > string_size) return error.Corruption;
    }
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
}
