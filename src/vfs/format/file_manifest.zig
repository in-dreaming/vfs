const std = @import("std");
const fmt = @import("common.zig");

pub const MAGIC: u32 = fmt.magic32("VFMF");
pub const VERSION: u16 = 1;
pub const HEADER_SIZE: usize = 80;
pub const BLOCK_DESC_SIZE: usize = 80;
pub const PAGE_REF_SIZE: usize = 112;
const CRC_OFFSET: usize = 76;
pub const BLOCK_FLAG_EXPLICIT_PAGE_REFS: u32 = 1 << 0;

pub const Codec = enum(u16) {
    none = 0,
    lz4 = 1,
    zstd = 2,
    _,
};

pub const BlockDesc = struct {
    raw_offset: u64,
    raw_size: u64,
    page_size: u32,
    page_count: u32,
    codec: Codec = .none,
    codec_level: i16 = 0,
    codec_flags: u32 = 0,
    block_hash: [32]u8 = [_]u8{0} ** 32,
    flags: u32 = 0,
    page_ref_offset: u64 = 0,
};

pub const PageRef = struct {
    pack_id: u32,
    pack_generation: u64,
    file_entry: u64,
    block_index: u32,
    page_index: u32,
    page_key: u64,
    raw_hash: [32]u8 = [_]u8{0} ** 32,
    content_hash: [32]u8 = [_]u8{0} ** 32,
    raw_crc: u32 = 0,
};

pub const FileManifest = struct {
    file_entry: u64,
    file_version: u64,
    file_size: u64,
    content_hash: [32]u8 = [_]u8{0} ** 32,
    flags: u32 = 0,
    blocks: []const BlockDesc,
    page_refs: []const PageRef = &.{},
    manifest_crc: u32 = 0,
};

pub const DecodedFileManifest = struct {
    header: FileManifest,
    blocks: []BlockDesc,
    page_refs: []PageRef,

    pub fn deinit(self: *DecodedFileManifest, allocator: std.mem.Allocator) void {
        allocator.free(self.blocks);
        allocator.free(self.page_refs);
        self.* = undefined;
    }

    pub fn pageRef(self: DecodedFileManifest, block: BlockDesc, page_index: u32) !PageRef {
        if ((block.flags & BLOCK_FLAG_EXPLICIT_PAGE_REFS) == 0) return error.InvalidArgument;
        if (page_index >= block.page_count) return error.InvalidArgument;
        const start = std.math.cast(usize, block.page_ref_offset) orelse return error.Corruption;
        const idx = start + page_index;
        if (idx >= self.page_refs.len) return error.Corruption;
        return self.page_refs[idx];
    }
};

pub fn encodedSize(block_count: usize, page_ref_count: usize) usize {
    return HEADER_SIZE + block_count * BLOCK_DESC_SIZE + page_ref_count * PAGE_REF_SIZE;
}

pub fn encodeFileManifest(allocator: std.mem.Allocator, manifest: FileManifest) ![]u8 {
    if (manifest.file_entry == 0) return error.InvalidArgument;
    if (manifest.blocks.len > std.math.maxInt(u32)) return error.InvalidArgument;
    if (manifest.page_refs.len > std.math.maxInt(u32)) return error.InvalidArgument;
    try validatePageRefRanges(manifest.blocks, manifest.page_refs.len);
    var out = try allocator.alloc(u8, encodedSize(manifest.blocks.len, manifest.page_refs.len));
    errdefer allocator.free(out);
    @memset(out, 0);
    fmt.putU32(out, 0, MAGIC);
    fmt.putU16(out, 4, VERSION);
    fmt.putU16(out, 6, HEADER_SIZE);
    fmt.putU64(out, 8, manifest.file_entry);
    fmt.putU64(out, 16, manifest.file_version);
    fmt.putU64(out, 24, manifest.file_size);
    @memcpy(out[32..64][0..32], &manifest.content_hash);
    fmt.putU32(out, 64, @intCast(manifest.blocks.len));
    fmt.putU32(out, 68, manifest.flags);
    fmt.putU32(out, 72, 0);
    fmt.putU32(out, CRC_OFFSET, 0);

    for (manifest.blocks, 0..) |block, i| {
        encodeBlock(out[HEADER_SIZE + i * BLOCK_DESC_SIZE ..][0..BLOCK_DESC_SIZE], block);
    }
    const refs_start = HEADER_SIZE + manifest.blocks.len * BLOCK_DESC_SIZE;
    for (manifest.page_refs, 0..) |ref, i| {
        encodePageRef(out[refs_start + i * PAGE_REF_SIZE ..][0..PAGE_REF_SIZE], ref);
    }
    fmt.putU32(out, CRC_OFFSET, fmt.crc32c(out));
    return out;
}

pub fn decodeFileManifest(allocator: std.mem.Allocator, bytes: []const u8, expected_file_entry: ?u64) !DecodedFileManifest {
    if (bytes.len < HEADER_SIZE) return error.Corruption;
    if (fmt.getU32(bytes, 0) != MAGIC) return error.Corruption;
    if (fmt.getU16(bytes, 4) != VERSION) return error.UnsupportedVersion;
    if (fmt.getU16(bytes, 6) != HEADER_SIZE) return error.Corruption;
    const file_entry = fmt.getU64(bytes, 8);
    if (file_entry == 0) return error.Corruption;
    if (expected_file_entry) |expected| if (expected != file_entry) return error.Corruption;
    const block_count = fmt.getU32(bytes, 64);
    try fmt.requireZero(bytes[72..76]);
    const stored_crc = fmt.getU32(bytes, CRC_OFFSET);
    const tmp = try allocator.dupe(u8, bytes);
    defer allocator.free(tmp);
    fmt.putU32(tmp, CRC_OFFSET, 0);
    if (fmt.crc32c(tmp) != stored_crc) return error.Corruption;

    var content_hash: [32]u8 = undefined;
    @memcpy(&content_hash, bytes[32..64][0..32]);
    const blocks = try allocator.alloc(BlockDesc, block_count);
    errdefer allocator.free(blocks);
    for (blocks, 0..) |*block, i| {
        block.* = try decodeBlock(bytes[HEADER_SIZE + i * BLOCK_DESC_SIZE ..][0..BLOCK_DESC_SIZE]);
    }
    const page_ref_count = try requiredPageRefCount(blocks);
    const size = encodedSize(block_count, page_ref_count);
    if (bytes.len != size) return error.Corruption;
    const page_refs = try allocator.alloc(PageRef, page_ref_count);
    errdefer allocator.free(page_refs);
    const refs_start = HEADER_SIZE + @as(usize, block_count) * BLOCK_DESC_SIZE;
    for (page_refs, 0..) |*ref, i| {
        ref.* = try decodePageRef(bytes[refs_start + i * PAGE_REF_SIZE ..][0..PAGE_REF_SIZE]);
    }
    return .{
        .blocks = blocks,
        .page_refs = page_refs,
        .header = .{
            .file_entry = file_entry,
            .file_version = fmt.getU64(bytes, 16),
            .file_size = fmt.getU64(bytes, 24),
            .content_hash = content_hash,
            .flags = fmt.getU32(bytes, 68),
            .blocks = blocks,
            .page_refs = page_refs,
            .manifest_crc = stored_crc,
        },
    };
}

fn encodeBlock(out: []u8, block: BlockDesc) void {
    fmt.putU64(out, 0, block.raw_offset);
    fmt.putU64(out, 8, block.raw_size);
    fmt.putU32(out, 16, block.page_size);
    fmt.putU32(out, 20, block.page_count);
    fmt.putU16(out, 24, @intFromEnum(block.codec));
    fmt.putU16(out, 26, @bitCast(block.codec_level));
    fmt.putU32(out, 28, block.codec_flags);
    @memcpy(out[32..64][0..32], &block.block_hash);
    fmt.putU32(out, 64, block.flags);
    fmt.putU64(out, 72, block.page_ref_offset);
}

fn decodeBlock(bytes: []const u8) !BlockDesc {
    try fmt.requireZero(bytes[68..72]);
    var h: [32]u8 = undefined;
    @memcpy(&h, bytes[32..64][0..32]);
    return .{
        .raw_offset = fmt.getU64(bytes, 0),
        .raw_size = fmt.getU64(bytes, 8),
        .page_size = fmt.getU32(bytes, 16),
        .page_count = fmt.getU32(bytes, 20),
        .codec = @enumFromInt(fmt.getU16(bytes, 24)),
        .codec_level = @bitCast(fmt.getU16(bytes, 26)),
        .codec_flags = fmt.getU32(bytes, 28),
        .block_hash = h,
        .flags = fmt.getU32(bytes, 64),
        .page_ref_offset = fmt.getU64(bytes, 72),
    };
}

fn encodePageRef(out: []u8, ref: PageRef) void {
    fmt.putU32(out, 0, ref.pack_id);
    fmt.putU32(out, 4, 0);
    fmt.putU64(out, 8, ref.pack_generation);
    fmt.putU64(out, 16, ref.file_entry);
    fmt.putU32(out, 24, ref.block_index);
    fmt.putU32(out, 28, ref.page_index);
    fmt.putU64(out, 32, ref.page_key);
    @memcpy(out[40..72][0..32], &ref.raw_hash);
    @memcpy(out[72..104][0..32], &ref.content_hash);
    fmt.putU32(out, 104, ref.raw_crc);
    fmt.putU32(out, 108, 0);
}

fn decodePageRef(bytes: []const u8) !PageRef {
    try fmt.requireZero(bytes[4..8]);
    try fmt.requireZero(bytes[108..112]);
    var raw_hash: [32]u8 = undefined;
    var content_hash: [32]u8 = undefined;
    @memcpy(&raw_hash, bytes[40..72][0..32]);
    @memcpy(&content_hash, bytes[72..104][0..32]);
    const ref: PageRef = .{
        .pack_id = fmt.getU32(bytes, 0),
        .pack_generation = fmt.getU64(bytes, 8),
        .file_entry = fmt.getU64(bytes, 16),
        .block_index = fmt.getU32(bytes, 24),
        .page_index = fmt.getU32(bytes, 28),
        .page_key = fmt.getU64(bytes, 32),
        .raw_hash = raw_hash,
        .content_hash = content_hash,
        .raw_crc = fmt.getU32(bytes, 104),
    };
    if (ref.pack_id == 0 or ref.pack_generation == 0 or ref.file_entry == 0) return error.Corruption;
    return ref;
}

fn validatePageRefRanges(blocks: []const BlockDesc, page_ref_count: usize) !void {
    const required = try requiredPageRefCount(blocks);
    if (required != page_ref_count) return error.InvalidArgument;
}

fn requiredPageRefCount(blocks: []const BlockDesc) !usize {
    var required: usize = 0;
    for (blocks) |block| {
        if ((block.flags & BLOCK_FLAG_EXPLICIT_PAGE_REFS) != 0) {
            const start = std.math.cast(usize, block.page_ref_offset) orelse return error.Corruption;
            const count: usize = block.page_count;
            required = @max(required, start + count);
        } else if (block.page_ref_offset != 0) {
            return error.Corruption;
        }
    }
    return required;
}

test "file manifest roundtrips with multiple blocks and pages" {
    const allocator = std.testing.allocator;
    const blocks = [_]BlockDesc{
        .{ .raw_offset = 0, .raw_size = 8192, .page_size = 4096, .page_count = 2 },
        .{ .raw_offset = 8192, .raw_size = 4096, .page_size = 1024, .page_count = 4, .codec = .zstd, .codec_level = 3, .codec_flags = 1, .flags = 2 },
    };
    var content_hash = [_]u8{0} ** 32;
    content_hash[31] = 0x55;
    const encoded = try encodeFileManifest(allocator, .{ .file_entry = 123, .file_version = 2, .file_size = 12288, .content_hash = content_hash, .blocks = &blocks });
    defer allocator.free(encoded);
    var decoded = try decodeFileManifest(allocator, encoded, 123);
    defer decoded.deinit(allocator);
    try std.testing.expectEqual(@as(u64, 123), decoded.header.file_entry);
    try std.testing.expectEqual(@as(usize, 2), decoded.blocks.len);
    try std.testing.expectEqual(@as(u32, 4), decoded.blocks[1].page_count);
    try std.testing.expectEqual(Codec.zstd, decoded.blocks[1].codec);
    try std.testing.expectError(error.Corruption, decodeFileManifest(allocator, encoded, 456));
}

test "file manifest roundtrips explicit page refs" {
    const allocator = std.testing.allocator;
    var h = [_]u8{0x11} ** 32;
    h[31] = 0x22;
    const refs = [_]PageRef{
        .{ .pack_id = 7, .pack_generation = 9, .file_entry = 123, .block_index = 0, .page_index = 0, .page_key = 0xabc, .raw_hash = h, .content_hash = h, .raw_crc = 0x12345678 },
        .{ .pack_id = 7, .pack_generation = 9, .file_entry = 123, .block_index = 0, .page_index = 1, .page_key = 0xabd, .raw_hash = h, .content_hash = h, .raw_crc = 0x23456789 },
    };
    const blocks = [_]BlockDesc{
        .{ .raw_offset = 0, .raw_size = 8, .page_size = 4, .page_count = 2, .flags = BLOCK_FLAG_EXPLICIT_PAGE_REFS, .page_ref_offset = 0 },
    };
    const encoded = try encodeFileManifest(allocator, .{ .file_entry = 123, .file_version = 3, .file_size = 8, .content_hash = h, .blocks = &blocks, .page_refs = &refs });
    defer allocator.free(encoded);
    var decoded = try decodeFileManifest(allocator, encoded, 123);
    defer decoded.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 2), decoded.page_refs.len);
    const ref = try decoded.pageRef(decoded.blocks[0], 1);
    try std.testing.expectEqual(@as(u64, 0xabd), ref.page_key);
    try std.testing.expectError(error.InvalidArgument, encodeFileManifest(allocator, .{ .file_entry = 123, .file_version = 3, .file_size = 8, .blocks = &blocks, .page_refs = refs[0..1] }));
}
