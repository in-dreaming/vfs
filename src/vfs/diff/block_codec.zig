//! Raw block <-> encoded pages, shared by the diff engine (to obtain the
//! logical bytes of a block) and the patch side (to re-page a patched block).
const std = @import("std");
const file_manifest_fmt = @import("../format/file_manifest.zig");
const page_value_fmt = @import("../format/page_value.zig");
const registry = @import("../compress/registry.zig");
const hash = @import("../hash.zig");

/// Decodes one encoded PageValue and returns its raw (decompressed) bytes.
pub fn rawFromPageBytes(allocator: std.mem.Allocator, bytes: []const u8, identity: page_value_fmt.PageIdentity) ![]u8 {
    const page = try page_value_fmt.decodePageValue(bytes, identity);
    return registry.decompressPage(allocator, page.codec, page.payload, page.raw_size, page.raw_crc);
}

/// Encodes the pages of a raw block. Returns one owned encoded PageValue per
/// page; the caller frees each with `freePages`.
pub fn pagesFromRaw(allocator: std.mem.Allocator, file_entry: u64, block_index: u32, page_size: u32, codec: file_manifest_fmt.Codec, level: i16, raw: []const u8) ![][]u8 {
    if (page_size == 0) return error.InvalidArgument;
    const page_count: usize = if (raw.len == 0) 0 else (raw.len - 1) / page_size + 1;
    const out = try allocator.alloc([]u8, page_count);
    var done: usize = 0;
    errdefer {
        for (out[0..done]) |p| allocator.free(p);
        allocator.free(out);
    }
    while (done < page_count) : (done += 1) {
        const start = done * page_size;
        const end = @min(raw.len, start + page_size);
        const slice = raw[start..end];
        const compressed = try registry.compressPage(allocator, codec, level, slice);
        defer allocator.free(compressed.bytes);
        out[done] = try page_value_fmt.encodePageValue(allocator, .{
            .file_entry = file_entry,
            .block_index = block_index,
            .page_index = @intCast(done),
            .codec = compressed.codec,
            .raw_size = @intCast(slice.len),
            .stored_size = @intCast(compressed.bytes.len),
            .raw_crc = hash.crc32c(slice),
            .stored_crc = hash.crc32c(compressed.bytes),
            .content_hash = hash.contentHash(slice),
            .payload = compressed.bytes,
        });
    }
    return out;
}

pub fn freePages(allocator: std.mem.Allocator, pages: [][]u8) void {
    for (pages) |p| allocator.free(p);
    allocator.free(pages);
}

/// crc32c over the little-endian raw_crc sequence of a block's pages; this is
/// the L unit idempotency fingerprint (docs/vfs/diff_patch.md §9.3).
pub fn rawCrcSequenceHash(raw_crcs: []const u32) u32 {
    var st = @import("db_internal").format.crc32c_impl.init_state;
    for (raw_crcs) |c| {
        var b: [4]u8 = undefined;
        std.mem.writeInt(u32, &b, c, .little);
        st = @import("db_internal").format.crc32c_impl.update(st, &b);
    }
    return @import("db_internal").format.crc32c_impl.finish(st);
}

test "block codec roundtrips raw through lz4 pages" {
    const a = std.testing.allocator;
    var raw: [10000]u8 = undefined;
    for (&raw, 0..) |*b, i| b.* = @intCast((i / 9) % 200);
    const pages = try pagesFromRaw(a, 7, 0, 4096, .lz4, 4, &raw);
    defer freePages(a, pages);
    try std.testing.expectEqual(@as(usize, 3), pages.len);
    var back = std.ArrayList(u8).empty;
    defer back.deinit(a);
    for (pages, 0..) |p, i| {
        const r = try rawFromPageBytes(a, p, .{ .file_entry = 7, .block_index = 0, .page_index = @intCast(i) });
        defer a.free(r);
        try back.appendSlice(a, r);
    }
    try std.testing.expectEqualSlices(u8, &raw, back.items);
    const empty = try pagesFromRaw(a, 7, 0, 4096, .none, 0, "");
    defer freePages(a, empty);
    try std.testing.expectEqual(@as(usize, 0), empty.len);
    try std.testing.expectEqual(rawCrcSequenceHash(&.{ 1, 2 }), rawCrcSequenceHash(&.{ 1, 2 }));
    try std.testing.expect(rawCrcSequenceHash(&.{ 1, 2 }) != rawCrcSequenceHash(&.{ 2, 1 }));
}
