const std = @import("std");
const fmt = @import("../format.zig");
const pf = @import("../platform/file.zig");
const idx = @import("index_file.zig");

pub const MAGIC: u32 = 0x31494242; // "BBI1"
pub const HEADER_SIZE: u64 = 64;
pub const BUCKET_SIZE: u64 = 16;
pub const ENTRY_SIZE: u64 = 64;

pub const BaseIndexHeader = extern struct {
    magic: u32,
    version: u32,
    header_size: u32,
    bucket_bits: u32,
    bucket_count: u32,
    entry_count: u32,
    buckets_offset: u64,
    entries_offset: u64,
    total_size: u64,
    crc: u32,
    reserved: u32,
};

pub const BaseBucket = extern struct {
    begin: u32,
    count: u32,
    crc: u32,
    reserved: u32,
};

pub const BaseEntry = extern struct {
    h: u64,
    key_hi: u64,
    key_lo: u64,
    info: fmt.IndexInfo,
};

pub const BuildEntry = struct {
    key: fmt.Key128,
    info: fmt.IndexInfo,
};

const SortEntry = struct {
    key: fmt.Key128,
    info: fmt.IndexInfo,
    h: u64,
    bucket: u32,
};

pub const BaseIndex = struct {
    mapping: pf.MappedRegion,
    view_offset: usize,
    header: BaseIndexHeader,

    pub fn close(self: *BaseIndex) void {
        pf.munmap(&self.mapping);
    }

    pub fn lookup(self: *const BaseIndex, key: fmt.Key128) !fmt.IndexInfo {
        const h = fmt.mixHash128To64(key);
        const bucket_id = bucketId(h, self.header.bucket_bits);
        const b = try readBucket(self.bytes(), self.header.buckets_offset + @as(u64, bucket_id) * BUCKET_SIZE);
        if (b.count == 0) return error.NotFound;
        const begin = b.begin;
        const end = begin + b.count;
        if (b.count <= 16) {
            var i = begin;
            while (i < end) : (i += 1) {
                const e = try readEntry(self.bytes(), self.header.entries_offset + @as(u64, i) * ENTRY_SIZE);
                if (e.h == h and e.key_hi == key.hi and e.key_lo == key.lo) return e.info;
            }
            return error.NotFound;
        }
        var lo = begin;
        var hi = end;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            const e = try readEntry(self.bytes(), self.header.entries_offset + @as(u64, mid) * ENTRY_SIZE);
            if (e.h < h) lo = mid + 1 else hi = mid;
        }
        var i = lo;
        while (i < end) : (i += 1) {
            const e = try readEntry(self.bytes(), self.header.entries_offset + @as(u64, i) * ENTRY_SIZE);
            if (e.h != h) break;
            if (e.key_hi == key.hi and e.key_lo == key.lo) return e.info;
        }
        return error.NotFound;
    }

    fn bytes(self: *const BaseIndex) []const u8 {
        return self.mapping.bytesConst()[self.view_offset..];
    }
};

pub fn collectEntries(base: *const BaseIndex, allocator: std.mem.Allocator) ![]BuildEntry {
    const out = try allocator.alloc(BuildEntry, base.header.entry_count);
    var i: u32 = 0;
    while (i < base.header.entry_count) : (i += 1) {
        const e = try readEntry(base.bytes(), base.header.entries_offset + @as(u64, i) * ENTRY_SIZE);
        out[i] = .{ .key = .{ .hi = e.key_hi, .lo = e.key_lo }, .info = e.info };
    }
    return out;
}

pub fn build(index: *idx.IndexFile, allocator: std.mem.Allocator, entries: []const BuildEntry) !u32 {
    const bucket_bits = chooseBucketBits(entries.len);
    const bucket_count: u32 = @as(u32, 1) << bucket_bits;
    const total_size = HEADER_SIZE + @as(u64, bucket_count) * BUCKET_SIZE + @as(u64, entries.len) * ENTRY_SIZE;
    const region_id = try idx.allocateRegion(index, .base_index, total_size);
    const region = try index.region(region_id);

    var sorted = try allocator.alloc(SortEntry, entries.len);
    defer allocator.free(sorted);
    for (entries, 0..) |entry, i| {
        const h = fmt.mixHash128To64(entry.key);
        sorted[i] = .{ .key = entry.key, .info = entry.info, .h = h, .bucket = bucketId(h, bucket_bits) };
    }
    std.mem.sort(SortEntry, sorted, {}, lessThan);
    var i: usize = 1;
    while (i < sorted.len) : (i += 1) {
        if (sorted[i - 1].key.hi == sorted[i].key.hi and sorted[i - 1].key.lo == sorted[i].key.lo) return error.DuplicateKey;
    }

    const total_usize: usize = @intCast(total_size);
    var buf = try allocator.alloc(u8, total_usize);
    defer allocator.free(buf);
    @memset(buf, 0);
    const header = BaseIndexHeader{
        .magic = MAGIC,
        .version = 1,
        .header_size = HEADER_SIZE,
        .bucket_bits = bucket_bits,
        .bucket_count = bucket_count,
        .entry_count = @intCast(entries.len),
        .buckets_offset = HEADER_SIZE,
        .entries_offset = HEADER_SIZE + @as(u64, bucket_count) * BUCKET_SIZE,
        .total_size = total_size,
        .crc = 0,
        .reserved = 0,
    };
    writeHeader(buf[0..HEADER_SIZE], header);

    var cursor: u32 = 0;
    var b: u32 = 0;
    while (b < bucket_count) : (b += 1) {
        const begin = cursor;
        while (cursor < sorted.len and sorted[cursor].bucket == b) cursor += 1;
        writeBucket(buf[HEADER_SIZE + @as(u64, b) * BUCKET_SIZE ..][0..BUCKET_SIZE], .{
            .begin = begin,
            .count = cursor - begin,
            .crc = 0,
            .reserved = 0,
        });
    }
    for (sorted, 0..) |e, ei| {
        writeEntry(buf[header.entries_offset + @as(u64, ei) * ENTRY_SIZE ..][0..ENTRY_SIZE], .{
            .h = e.h,
            .key_hi = e.key.hi,
            .key_lo = e.key.lo,
            .info = e.info,
        });
    }
    try pf.pwriteAll(index.file, region.offset, buf);
    try pf.flushData(index.file);
    try verifyBytes(buf);
    try idx.activateRegion(index, region_id, total_size);
    return region_id;
}

pub fn open(index: *const idx.IndexFile) !BaseIndex {
    const region_id = index.activeBaseRegionId();
    if (region_id == 0) return error.NotFound;
    const region = try index.region(region_id);
    const file_len = try pf.len(index.file);
    var map = try pf.mmapReadonly(index.file, 0, file_len);
    errdefer pf.munmap(&map);
    const view_offset = std.math.cast(usize, region.offset) orelse return error.InvalidArgument;
    const used_size = std.math.cast(usize, region.used_size) orelse return error.InvalidArgument;
    if (view_offset + used_size > map.bytesConst().len) return error.Corruption;
    const view = map.bytesConst()[view_offset..][0..used_size];
    const header = try readHeader(view[0..HEADER_SIZE]);
    try verifyBytes(view[0..header.total_size]);
    return .{ .mapping = map, .view_offset = view_offset, .header = header };
}

pub fn verify(base: *const BaseIndex) !void {
    try verifyBytes(base.bytes()[0..base.header.total_size]);
}

fn chooseBucketBits(n: usize) u5 {
    if (n == 0) return 0;
    var buckets: usize = 1;
    var bits: u5 = 0;
    while (buckets < n / 4 + 1 and bits < 20) : ({
        buckets <<= 1;
        bits += 1;
    }) {}
    return bits;
}

fn bucketId(h: u64, bits: u32) u32 {
    if (bits == 0) return 0;
    return @intCast(h >> @intCast(64 - bits));
}

fn lessThan(_: void, a: SortEntry, b: SortEntry) bool {
    if (a.bucket != b.bucket) return a.bucket < b.bucket;
    if (a.h != b.h) return a.h < b.h;
    if (a.key.hi != b.key.hi) return a.key.hi < b.key.hi;
    return a.key.lo < b.key.lo;
}

fn verifyBytes(bytes: []const u8) !void {
    if (bytes.len < HEADER_SIZE) return error.Corruption;
    const header = try readHeader(bytes[0..HEADER_SIZE]);
    if (header.magic != MAGIC or header.version != 1 or header.header_size != HEADER_SIZE) return error.Corruption;
    if (header.bucket_count != (@as(u32, 1) << @intCast(header.bucket_bits))) return error.Corruption;
    if (header.total_size > bytes.len) return error.Corruption;
    var expected_begin: u32 = 0;
    var b: u32 = 0;
    while (b < header.bucket_count) : (b += 1) {
        const bucket = try readBucket(bytes, header.buckets_offset + @as(u64, b) * BUCKET_SIZE);
        if (bucket.begin != expected_begin) return error.Corruption;
        if (@as(u64, bucket.begin) + bucket.count > header.entry_count) return error.Corruption;
        expected_begin += bucket.count;
        var prev: ?BaseEntry = null;
        var i: u32 = bucket.begin;
        while (i < bucket.begin + bucket.count) : (i += 1) {
            const e = try readEntry(bytes, header.entries_offset + @as(u64, i) * ENTRY_SIZE);
            if (bucketId(e.h, header.bucket_bits) != b) return error.Corruption;
            if (prev) |p| {
                if (p.h > e.h or (p.h == e.h and (p.key_hi > e.key_hi or (p.key_hi == e.key_hi and p.key_lo >= e.key_lo)))) return error.Corruption;
            }
            prev = e;
        }
    }
    if (expected_begin != header.entry_count) return error.Corruption;
}

fn writeHeader(dst: []u8, h: BaseIndexHeader) void {
    fmt.writeU32Le(dst[0..4], h.magic);
    fmt.writeU32Le(dst[4..8], h.version);
    fmt.writeU32Le(dst[8..12], h.header_size);
    fmt.writeU32Le(dst[12..16], h.bucket_bits);
    fmt.writeU32Le(dst[16..20], h.bucket_count);
    fmt.writeU32Le(dst[20..24], h.entry_count);
    fmt.writeU64Le(dst[24..32], h.buckets_offset);
    fmt.writeU64Le(dst[32..40], h.entries_offset);
    fmt.writeU64Le(dst[40..48], h.total_size);
    fmt.writeU32Le(dst[48..52], 0);
    fmt.writeU32Le(dst[52..56], h.reserved);
    const crc = fmt.crc32c(dst);
    fmt.writeU32Le(dst[48..52], crc);
}

fn readHeader(src: []const u8) !BaseIndexHeader {
    var tmp: [HEADER_SIZE]u8 = undefined;
    @memcpy(&tmp, src[0..HEADER_SIZE]);
    const stored = fmt.readU32Le(tmp[48..52]);
    fmt.writeU32Le(tmp[48..52], 0);
    if (fmt.crc32c(&tmp) != stored) return error.Corruption;
    return .{
        .magic = fmt.readU32Le(src[0..4]),
        .version = fmt.readU32Le(src[4..8]),
        .header_size = fmt.readU32Le(src[8..12]),
        .bucket_bits = fmt.readU32Le(src[12..16]),
        .bucket_count = fmt.readU32Le(src[16..20]),
        .entry_count = fmt.readU32Le(src[20..24]),
        .buckets_offset = fmt.readU64Le(src[24..32]),
        .entries_offset = fmt.readU64Le(src[32..40]),
        .total_size = fmt.readU64Le(src[40..48]),
        .crc = stored,
        .reserved = fmt.readU32Le(src[52..56]),
    };
}

fn writeBucket(dst: []u8, b: BaseBucket) void {
    fmt.writeU32Le(dst[0..4], b.begin);
    fmt.writeU32Le(dst[4..8], b.count);
    fmt.writeU32Le(dst[8..12], 0);
    fmt.writeU32Le(dst[12..16], b.reserved);
    const crc = fmt.crc32c(dst);
    fmt.writeU32Le(dst[8..12], crc);
}

fn readBucket(bytes: []const u8, off: u64) !BaseBucket {
    if (off + BUCKET_SIZE > bytes.len) return error.Corruption;
    const s = bytes[@intCast(off)..][0..BUCKET_SIZE];
    var tmp: [BUCKET_SIZE]u8 = undefined;
    @memcpy(&tmp, s);
    const stored = fmt.readU32Le(tmp[8..12]);
    fmt.writeU32Le(tmp[8..12], 0);
    if (fmt.crc32c(&tmp) != stored) return error.Corruption;
    return .{ .begin = fmt.readU32Le(s[0..4]), .count = fmt.readU32Le(s[4..8]), .crc = stored, .reserved = fmt.readU32Le(s[12..16]) };
}

fn writeEntry(dst: []u8, e: BaseEntry) void {
    fmt.writeU64Le(dst[0..8], e.h);
    fmt.writeU64Le(dst[8..16], e.key_hi);
    fmt.writeU64Le(dst[16..24], e.key_lo);
    fmt.writeU32Le(dst[24..28], e.info.data_db_id);
    fmt.writeU32Le(dst[28..32], e.info.flags);
    fmt.writeU64Le(dst[32..40], e.info.offset);
    fmt.writeU32Le(dst[40..44], e.info.stored_size);
    fmt.writeU32Le(dst[44..48], e.info.raw_size);
    fmt.writeU64Le(dst[48..56], e.info.version);
    fmt.writeU32Le(dst[56..60], e.info.crc);
    fmt.writeU16Le(dst[60..62], e.info.codec);
    fmt.writeU16Le(dst[62..64], e.info.reserved);
}

fn readEntry(bytes: []const u8, off: u64) !BaseEntry {
    if (off + ENTRY_SIZE > bytes.len) return error.Corruption;
    const s = bytes[@intCast(off)..][0..ENTRY_SIZE];
    return .{
        .h = fmt.readU64Le(s[0..8]),
        .key_hi = fmt.readU64Le(s[8..16]),
        .key_lo = fmt.readU64Le(s[16..24]),
        .info = .{
            .data_db_id = fmt.readU32Le(s[24..28]),
            .flags = fmt.readU32Le(s[28..32]),
            .offset = fmt.readU64Le(s[32..40]),
            .stored_size = fmt.readU32Le(s[40..44]),
            .raw_size = fmt.readU32Le(s[44..48]),
            .version = fmt.readU64Le(s[48..56]),
            .crc = fmt.readU32Le(s[56..60]),
            .codec = fmt.readU16Le(s[60..62]),
            .reserved = fmt.readU16Le(s[62..64]),
        },
    };
}

test "base index builds into index db region and mmap lookup works" {
    const testing = std.testing;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var index = try idx.createAt(tmp.dir, "index.db", [_]u8{0} ** 16);
    defer index.close() catch unreachable;

    _ = try build(&index, testing.allocator, &.{});
    var base = try open(&index);
    try verify(&base);
    try testing.expectError(error.NotFound, base.lookup(.{ .hi = 1, .lo = 2 }));
    base.close();

    const entries = try testing.allocator.alloc(BuildEntry, 1000);
    defer testing.allocator.free(entries);
    for (entries, 0..) |*e, i| {
        e.* = .{
            .key = .{ .hi = @intCast(i / 2), .lo = @intCast(i) },
            .info = .{ .data_db_id = 0, .flags = 0, .offset = @intCast(4096 + i), .stored_size = 10, .raw_size = 10, .version = @intCast(i), .crc = @intCast(i), .codec = 0, .reserved = 0 },
        };
    }
    _ = try build(&index, testing.allocator, entries);
    var base2 = try open(&index);
    defer base2.close();
    for (entries) |e| {
        const got = try base2.lookup(e.key);
        try testing.expectEqual(e.info.offset, got.offset);
    }
    try testing.expectError(error.NotFound, base2.lookup(.{ .hi = 999999, .lo = 1 }));

    var dup = [_]BuildEntry{ entries[0], entries[0] };
    try testing.expectError(error.DuplicateKey, build(&index, testing.allocator, &dup));
}
