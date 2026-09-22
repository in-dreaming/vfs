//! Byte-level diff/patch (HDiffPatch-style algorithm, custom VHDF container).
//!
//! VHDF layout:
//!   [0]  magic 'VHDF'   u32
//!   [4]  version        u16 = 1
//!   [6]  flags          u16   bit0..3: stream i is lz4-compressed
//!   [8]  old_size       u64
//!   [16] new_size       u64
//!   [24] new_crc        u32   crc32c(new)
//!   [28] cover_count    u32
//!   [32] 4 x { raw_size u32, stored_size u32 }   covers, rle_ctrl, rle_code, new_data
//!   [64] header_crc     u32
//!   [68] streams (in order)
const std = @import("std");
const fmt = @import("../format/common.zig");
const lz4 = @import("../compress/lz4.zig");
const varint = @import("varint.zig");
const rle = @import("rle.zig");
const cover_mod = @import("cover.zig");

pub const MAGIC: u32 = fmt.magic32("VHDF");
pub const VERSION: u16 = 1;
pub const HEADER_SIZE: usize = 68;
pub const Cover = cover_mod.Cover;

pub const DiffOptions = struct {
    cover: cover_mod.Options = .{},
    /// lz4-compress the four streams when it helps.
    compress_streams: bool = true,
    lz4_level: i16 = 4,

    pub fn hash(self: DiffOptions) u64 {
        var h = std.hash.Wyhash.init(self.cover.hash());
        h.update(std.mem.asBytes(&self.compress_streams));
        h.update(std.mem.asBytes(&self.lz4_level));
        return h.final();
    }
};

pub const Header = struct {
    flags: u16,
    old_size: u64,
    new_size: u64,
    new_crc: u32,
    cover_count: u32,
    raw_sizes: [4]u32,
    stored_sizes: [4]u32,
};

fn encodeHeader(h: Header) [HEADER_SIZE]u8 {
    var b = [_]u8{0} ** HEADER_SIZE;
    fmt.putU32(&b, 0, MAGIC);
    fmt.putU16(&b, 4, VERSION);
    fmt.putU16(&b, 6, h.flags);
    fmt.putU64(&b, 8, h.old_size);
    fmt.putU64(&b, 16, h.new_size);
    fmt.putU32(&b, 24, h.new_crc);
    fmt.putU32(&b, 28, h.cover_count);
    var i: usize = 0;
    while (i < 4) : (i += 1) {
        fmt.putU32(&b, 32 + i * 8, h.raw_sizes[i]);
        fmt.putU32(&b, 36 + i * 8, h.stored_sizes[i]);
    }
    fmt.putU32(&b, 64, fmt.crc32cWithZeroU32(&b, 64));
    return b;
}

pub fn decodeHeader(bytes: []const u8) !Header {
    if (bytes.len < HEADER_SIZE) return error.Corruption;
    const b = bytes[0..HEADER_SIZE];
    if (fmt.getU32(b, 0) != MAGIC) return error.Corruption;
    if (fmt.getU16(b, 4) != VERSION) return error.UnsupportedVersion;
    if (fmt.getU32(b, 64) != fmt.crc32cWithZeroU32(b, 64)) return error.ChecksumMismatch;
    var h: Header = .{
        .flags = fmt.getU16(b, 6),
        .old_size = fmt.getU64(b, 8),
        .new_size = fmt.getU64(b, 16),
        .new_crc = fmt.getU32(b, 24),
        .cover_count = fmt.getU32(b, 28),
        .raw_sizes = undefined,
        .stored_sizes = undefined,
    };
    var total: u64 = HEADER_SIZE;
    var i: usize = 0;
    while (i < 4) : (i += 1) {
        h.raw_sizes[i] = fmt.getU32(b, 32 + i * 8);
        h.stored_sizes[i] = fmt.getU32(b, 36 + i * 8);
        total += h.stored_sizes[i];
        const is_lz4 = (h.flags >> @intCast(i)) & 1 == 1;
        if (!is_lz4 and h.raw_sizes[i] != h.stored_sizes[i]) return error.Corruption;
    }
    if (h.flags >> 4 != 0) return error.Corruption;
    if (total != bytes.len) return error.Corruption;
    // Every cover is three varints of at least one byte each, so the cover
    // count is bounded by the cover stream; this caps the decoder's scratch.
    if (@as(u64, h.cover_count) * 3 > h.raw_sizes[0]) return error.Corruption;
    return h;
}

/// Produces a VHDF diff that transforms `old` into `new`.
pub fn diff(allocator: std.mem.Allocator, old: []const u8, new: []const u8, options: DiffOptions) ![]u8 {
    // 1. covers
    var covers = std.ArrayList(Cover).empty;
    defer covers.deinit(allocator);
    if (old.len != 0 and new.len >= options.cover.min_match_len) {
        var index = try cover_mod.Index.build(allocator, old);
        defer index.deinit();
        covers = try cover_mod.search(allocator, &index, new, options.cover);
        try cover_mod.dispose(allocator, &covers, old, new, options.cover);
    }

    // 2. streams
    var cover_stream = std.ArrayList(u8).empty;
    defer cover_stream.deinit(allocator);
    var sub = std.ArrayList(u8).empty;
    defer sub.deinit(allocator);
    var new_data = std.ArrayList(u8).empty;
    defer new_data.deinit(allocator);
    var last_old_end: i64 = 0;
    var last_new_end: u64 = 0;
    for (covers.items) |c| {
        try varint.writeSigned(&cover_stream, allocator, @as(i64, @intCast(c.old_pos)) - last_old_end);
        try varint.write(&cover_stream, allocator, c.new_pos - last_new_end);
        try varint.write(&cover_stream, allocator, c.len);
        try new_data.appendSlice(allocator, new[@intCast(last_new_end)..@intCast(c.new_pos)]);
        var i: u64 = 0;
        try sub.ensureUnusedCapacity(allocator, @intCast(c.len));
        while (i < c.len) : (i += 1) sub.appendAssumeCapacity(new[@intCast(c.new_pos + i)] -% old[@intCast(c.old_pos + i)]);
        last_old_end = @intCast(c.old_pos + c.len);
        last_new_end = c.new_pos + c.len;
    }
    try new_data.appendSlice(allocator, new[@intCast(last_new_end)..]);
    var enc = try rle.encode(allocator, sub.items);
    defer enc.deinit(allocator);

    // 3. serialize (optionally lz4 each stream)
    const raws = [4][]const u8{ cover_stream.items, enc.ctrl.items, enc.code.items, new_data.items };
    var stored: [4][]u8 = undefined;
    var stored_owned = [_]bool{false} ** 4;
    defer for (stored, 0..) |s, i| if (stored_owned[i]) allocator.free(s);
    var flags: u16 = 0;
    for (raws, 0..) |raw, i| {
        if (raw.len > std.math.maxInt(u32)) return error.InvalidArgument;
        stored[i] = @constCast(raw);
        if (options.compress_streams and raw.len >= 32) {
            const c = try lz4.compressPage(allocator, raw, options.lz4_level);
            if (c.len < raw.len) {
                stored[i] = c;
                stored_owned[i] = true;
                flags |= @as(u16, 1) << @intCast(i);
            } else allocator.free(c);
        }
    }
    var header = Header{
        .flags = flags,
        .old_size = old.len,
        .new_size = new.len,
        .new_crc = fmt.crc32c(new),
        .cover_count = @intCast(covers.items.len),
        .raw_sizes = undefined,
        .stored_sizes = undefined,
    };
    var total: usize = HEADER_SIZE;
    for (raws, 0..) |raw, i| {
        header.raw_sizes[i] = @intCast(raw.len);
        header.stored_sizes[i] = @intCast(stored[i].len);
        total += stored[i].len;
    }
    const out = try allocator.alloc(u8, total);
    errdefer allocator.free(out);
    @memcpy(out[0..HEADER_SIZE], &encodeHeader(header));
    var pos: usize = HEADER_SIZE;
    for (stored) |s| {
        @memcpy(out[pos..][0..s.len], s);
        pos += s.len;
    }
    return out;
}

const Streams = struct {
    allocator: std.mem.Allocator,
    data: [4][]const u8,
    owned: [4]bool,

    fn load(allocator: std.mem.Allocator, header: Header, bytes: []const u8) !Streams {
        var self: Streams = .{ .allocator = allocator, .data = undefined, .owned = [_]bool{false} ** 4 };
        var pos: usize = HEADER_SIZE;
        var loaded: usize = 0;
        errdefer for (self.data[0..loaded], 0..) |d, i| if (self.owned[i]) allocator.free(d);
        while (loaded < 4) : (loaded += 1) {
            const stored = bytes[pos..][0..header.stored_sizes[loaded]];
            pos += stored.len;
            if ((header.flags >> @intCast(loaded)) & 1 == 1) {
                const raw = try allocator.alloc(u8, header.raw_sizes[loaded]);
                errdefer allocator.free(raw);
                if (try lz4.decompressBlock(stored, raw) != raw.len) return error.Corruption;
                self.data[loaded] = raw;
                self.owned[loaded] = true;
            } else {
                self.data[loaded] = stored;
            }
        }
        return self;
    }

    fn deinit(self: *Streams) void {
        for (self.data, 0..) |d, i| if (self.owned[i]) self.allocator.free(d);
        self.* = undefined;
    }
};

/// Applies `diff_bytes` to `old`, writing exactly `header.new_size` bytes
/// into `out` (which must be that long). Verifies size and crc.
pub fn patch(allocator: std.mem.Allocator, old: []const u8, diff_bytes: []const u8, out: []u8) !void {
    const header = try decodeHeader(diff_bytes);
    if (header.old_size != old.len) return error.PreconditionFailed;
    if (header.new_size != out.len) return error.InvalidArgument;
    var streams = try Streams.load(allocator, header, diff_bytes);
    defer streams.deinit();

    var covers = varint.Reader{ .bytes = streams.data[0] };
    const new_data = streams.data[3];
    var nd_pos: usize = 0;
    var out_pos: u64 = 0;
    var old_end: i64 = 0;
    var sub_total: u64 = 0;
    // Pass 1 would be needed to know sub_total for the RLE decoder; instead we
    // decode covers into a small list first (cover_count is bounded by header).
    const list = try allocator.alloc(Cover, header.cover_count);
    defer allocator.free(list);
    // Every field below comes from the (unauthenticated) cover stream; all
    // arithmetic is checked so a flipped bit yields Corruption, not a panic.
    for (list) |*c| {
        const d_old = try covers.readSigned();
        const d_new = try covers.read(u64);
        const len = try covers.read(u64);
        if (len == 0 or len > old.len) return error.Corruption;
        const old_pos_i = std.math.add(i64, old_end, d_old) catch return error.Corruption;
        if (old_pos_i < 0) return error.Corruption;
        const old_pos: u64 = @intCast(old_pos_i);
        if (d_new > out.len) return error.Corruption;
        const new_pos = out_pos + d_new; // out_pos <= out.len, d_new <= out.len: no overflow
        if (old_pos > old.len - len or new_pos > out.len - len) return error.Corruption;
        c.* = .{ .old_pos = old_pos, .new_pos = new_pos, .len = len };
        old_end = @intCast(old_pos + len); // <= old.len, fits i64
        out_pos = new_pos + len;
        sub_total += len; // bounded by cover_count * out.len; cannot overflow u64 in practice
    }
    if (!covers.atEnd()) return error.Corruption;

    var sub = rle.Decoder.init(streams.data[1], streams.data[2], sub_total);
    out_pos = 0;
    for (list) |c| {
        const gap: usize = @intCast(c.new_pos - out_pos);
        if (nd_pos + gap > new_data.len) return error.Corruption;
        @memcpy(out[@intCast(out_pos)..][0..gap], new_data[nd_pos..][0..gap]);
        nd_pos += gap;
        const dst = out[@intCast(c.new_pos)..][0..@intCast(c.len)];
        @memcpy(dst, old[@intCast(c.old_pos)..][0..@intCast(c.len)]);
        try sub.addTo(dst);
        out_pos = c.new_pos + c.len;
    }
    const tail: usize = @intCast(out.len - out_pos);
    if (nd_pos + tail != new_data.len) return error.Corruption;
    @memcpy(out[@intCast(out_pos)..], new_data[nd_pos..]);
    if (!sub.finished()) return error.Corruption;
    if (fmt.crc32c(out) != header.new_crc) return error.ChecksumMismatch;
}

/// Convenience: allocate and return the patched output.
pub fn patchAlloc(allocator: std.mem.Allocator, old: []const u8, diff_bytes: []const u8) ![]u8 {
    const header = try decodeHeader(diff_bytes);
    const out = try allocator.alloc(u8, std.math.cast(usize, header.new_size) orelse return error.InvalidArgument);
    errdefer allocator.free(out);
    try patch(allocator, old, diff_bytes, out);
    return out;
}

// ---------------------------------------------------------------------------

fn roundtrip(allocator: std.mem.Allocator, old: []const u8, new: []const u8, options: DiffOptions) !usize {
    const d = try diff(allocator, old, new, options);
    defer allocator.free(d);
    const out = try patchAlloc(allocator, old, d);
    defer allocator.free(out);
    try std.testing.expectEqualSlices(u8, new, out);
    return d.len;
}

test "hdiff roundtrip edge cases" {
    const a = std.testing.allocator;
    _ = try roundtrip(a, "", "", .{});
    _ = try roundtrip(a, "", "hello world", .{});
    _ = try roundtrip(a, "hello world", "", .{});
    _ = try roundtrip(a, "same same same same", "same same same same", .{});
    _ = try roundtrip(a, "completely different", "nothing in common here!", .{});
    _ = try roundtrip(a, "ab", "abc", .{});
}

test "hdiff roundtrip structured edits and ratio" {
    const allocator = std.testing.allocator;
    var prng = std.Random.DefaultPrng.init(2024);
    const rnd = prng.random();
    const n: usize = 1 << 20;
    const old = try allocator.alloc(u8, n);
    defer allocator.free(old);
    rnd.bytes(old);

    // 1% scattered byte changes
    const new1 = try allocator.dupe(u8, old);
    defer allocator.free(new1);
    var k: usize = 0;
    while (k < n / 100) : (k += 1) new1[rnd.uintLessThan(usize, n)] +%= 1;
    const size1 = try roundtrip(allocator, old, new1, .{});
    try std.testing.expect(size1 < n / 10);

    // insert 4 KiB in the middle + delete 2 KiB near the end + move a block
    var new2 = std.ArrayList(u8).empty;
    defer new2.deinit(allocator);
    try new2.appendSlice(allocator, old[0 .. n / 2]);
    var ins: [4096]u8 = undefined;
    rnd.bytes(&ins);
    try new2.appendSlice(allocator, &ins);
    try new2.appendSlice(allocator, old[n / 2 .. n - 8192]);
    try new2.appendSlice(allocator, old[n - 6144 ..]);
    try new2.appendSlice(allocator, old[1000..9000]); // moved copy
    const size2 = try roundtrip(allocator, old, new2.items, .{});
    try std.testing.expect(size2 < 4096 + n / 50);

    // uncompressed streams also roundtrip
    _ = try roundtrip(allocator, old[0..70000], new1[0..70000], .{ .compress_streams = false });
    // small min match
    _ = try roundtrip(allocator, old[0..5000], new2.items[0..6000], .{ .cover = .{ .min_match_len = 4, .min_single_match_score = 1 } });
}

test "hdiff text edits" {
    const allocator = std.testing.allocator;
    const old = "The quick brown fox jumps over the lazy dog. " ** 50;
    const new = "The quick brown cat jumps over the lazy dog! " ** 50 ++ "appended tail";
    const size = try roundtrip(allocator, old, new, .{});
    try std.testing.expect(size < old.len / 4);
}

test "hdiff rejects corrupted containers and wrong old" {
    const allocator = std.testing.allocator;
    const old = "0123456789abcdefghijklmnopqrstuvwxyz" ** 8;
    const new = "0123456789abcdefghijklmnopqrstuvwxyz" ** 7 ++ "ZZZZZZZZZZ" ++ "0123456789abcdefghijklmnopqrstuvwxyz";
    const d = try diff(allocator, old, new, .{});
    defer allocator.free(d);
    try std.testing.expectError(error.PreconditionFailed, patchAlloc(allocator, old[1..], d));
    const out = try allocator.alloc(u8, new.len);
    defer allocator.free(out);
    try std.testing.expectError(error.InvalidArgument, patch(allocator, old, d, out[0 .. new.len - 1]));
    try std.testing.expectError(error.Corruption, patchAlloc(allocator, old, d[0 .. d.len - 1]));
    // header field flips
    var i: usize = 0;
    while (i < HEADER_SIZE) : (i += 1) {
        const bad = try allocator.dupe(u8, d);
        defer allocator.free(bad);
        bad[i] ^= 0x01;
        try std.testing.expect(std.meta.isError(patchAlloc(allocator, old, bad)));
    }
    // payload flips must never panic; most are caught by crc
    i = HEADER_SIZE;
    var caught: usize = 0;
    while (i < d.len) : (i += 7) {
        const bad = try allocator.dupe(u8, d);
        defer allocator.free(bad);
        bad[i] ^= 0x40;
        if (patchAlloc(allocator, old, bad)) |o| {
            allocator.free(o);
        } else |_| caught += 1;
    }
    try std.testing.expect(caught > 0);
}
