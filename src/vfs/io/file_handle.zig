const std = @import("std");
const pack_reader = @import("../pack/pack_reader.zig");
const volume_mod = @import("../volume/volume.zig");
const file_manifest_fmt = @import("../format/file_manifest.zig");
const page_value_fmt = @import("../format/page_value.zig");
const registry = @import("../compress/registry.zig");
const object_key = @import("../object_key.zig");
const hash = @import("../hash.zig");

const PageSource = struct {
    reader: *pack_reader.PackReader,
    pack_id: u32,
    pack_generation: u64,
    identity: page_value_fmt.PageIdentity,
    page_key: u64,
    content_hash: [32]u8,
    raw_crc: u32,
    check_ref: bool,
};

pub const FileHandle = struct {
    volume_handle: u64,
    volume: *volume_mod.Volume,
    pack: *pack_reader.PackReader,
    pack_id: u32,
    pack_generation: u64,
    file_entry: u64,
    manifest: file_manifest_fmt.DecodedFileManifest,
    size: u64 = 0,

    pub fn close(self: *FileHandle) void {
        self.manifest.deinit(std.heap.smp_allocator);
        if (self.volume.open_file_count > 0) self.volume.open_file_count -= 1;
    }

    pub fn readAt(self: *FileHandle, offset: u64, dst: []u8) !usize {
        if (dst.len == 0 or offset >= self.size) return 0;
        const available = self.size - offset;
        const wanted = @min(@as(u64, dst.len), available);
        var copied: usize = 0;
        const request_start = offset;
        const request_end = offset + wanted;

        for (self.manifest.blocks, 0..) |block, block_i| {
            if (block.codec != .none) return error.UnsupportedFeature;
            if (block.page_size == 0 and block.page_count != 0) return error.Corruption;
            const block_start = block.raw_offset;
            const block_end = block.raw_offset + block.raw_size;
            if (request_end <= block_start or request_start >= block_end) continue;
            var page_index: u32 = 0;
            while (page_index < block.page_count) : (page_index += 1) {
                const page_start = block_start + @as(u64, page_index) * @as(u64, block.page_size);
                const page_end = @min(block_end, page_start + block.page_size);
                if (request_end <= page_start or request_start >= page_end) continue;
                const codec_identity = try registry.codecIdentity(block.codec);
                const block_index: u32 = @intCast(block_i);
                const source: PageSource = if ((block.flags & file_manifest_fmt.BLOCK_FLAG_EXPLICIT_PAGE_REFS) != 0) blk: {
                    const ref = try self.manifest.pageRef(block, page_index);
                    const mounted = self.volume.findMountedPackContainingGeneration(ref.pack_id, ref.pack_generation) orelse return error.NotFound;
                    break :blk .{
                        .reader = mounted.reader,
                        .pack_id = mounted.meta.pack_id,
                        .pack_generation = mounted.meta.pack_version,
                        .identity = page_value_fmt.PageIdentity{ .file_entry = ref.file_entry, .block_index = ref.block_index, .page_index = ref.page_index },
                        .page_key = ref.page_key,
                        .content_hash = ref.content_hash,
                        .raw_crc = ref.raw_crc,
                        .check_ref = true,
                    };
                } else blk: {
                    break :blk .{
                        .reader = self.pack,
                        .pack_id = self.pack_id,
                        .pack_generation = self.pack_generation,
                        .identity = page_value_fmt.PageIdentity{ .file_entry = self.file_entry, .block_index = block_index, .page_index = page_index },
                        .page_key = try object_key.pageKey(self.file_entry, block_index, page_index),
                        .content_hash = [_]u8{0} ** 32,
                        .raw_crc = 0,
                        .check_ref = false,
                    };
                };
                const page = try self.volume.page_cache.getOrLoadObject(std.heap.smp_allocator, source.reader, .{
                    .pack_id = source.pack_id,
                    .pack_generation = source.pack_generation,
                    .file_entry = source.identity.file_entry,
                    .block_index = source.identity.block_index,
                    .page_index = source.identity.page_index,
                    .codec_identity = codec_identity.version_hash,
                }, source.identity, block.codec, source.page_key);
                if (source.check_ref) {
                    if (hash.crc32c(page) != source.raw_crc) return error.ChecksumMismatch;
                    if (!std.mem.eql(u8, &hash.contentHash(page), &source.content_hash)) return error.ChecksumMismatch;
                }
                const copy_start_abs = @max(request_start, page_start);
                const copy_end_abs = @min(request_end, page_end);
                const page_off: usize = @intCast(copy_start_abs - page_start);
                const copy_len: usize = @intCast(copy_end_abs - copy_start_abs);
                @memcpy(dst[copied..][0..copy_len], page[page_off..][0..copy_len]);
                copied += copy_len;
            }
        }
        return copied;
    }
};
