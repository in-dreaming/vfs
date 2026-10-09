const std = @import("std");
const volume_mod = @import("../volume/volume.zig");
const file_manifest_fmt = @import("../format/file_manifest.zig");
const page_value_fmt = @import("../format/page_value.zig");
const registry = @import("../compress/registry.zig");
const object_key = @import("../object_key.zig");

const PageSource = struct {
    pack_id: u64,
    pack_generation: u64,
    identity: page_value_fmt.PageIdentity,
    page_key: u64,
    content_hash: [32]u8,
    raw_crc: u32,
    check_ref: bool,
};

/// `vfs_open_*` flag: reads that cover a whole page bypass the page cache and
/// decode straight into the caller's buffer. Intended for one-shot whole-file
/// loads, where caching would only evict pages other readers still want.
pub const OPEN_FLAG_STREAMING: u32 = 1 << 0;

pub const FileHandle = struct {
    volume_lease: ?@import("../handle_registry.zig").Lease(volume_mod.Volume) = null,
    volume_handle: u64,
    volume: *volume_mod.Volume,
    /// Top layer for page resolution: the overlay when one is mounted for
    /// this pack, otherwise the mount the manifest came from. Stable for the
    /// volume's lifetime; only the store serving a page is pinned for I/O.
    mounted: *volume_mod.Volume.MountedPack,
    /// Base layer that implicit page reads fall through to when `mounted`
    /// is an overlay and does not hold the page.
    base: ?*volume_mod.Volume.MountedPack = null,
    pack_id: u64,
    pack_generation: u64,
    file_entry: u64,
    manifest: file_manifest_fmt.DecodedFileManifest,
    size: u64 = 0,
    flags: u32 = 0,

    pub fn close(self: *FileHandle) void {
        defer if (self.volume_lease) |lease| lease.release();
        self.manifest.deinit(std.heap.smp_allocator);
        _ = self.volume.open_file_count.fetchSub(1, .seq_cst);
    }

    pub fn readAt(self: *FileHandle, offset: u64, dst: []u8) !usize {
        var completed: usize = 0;
        try self.readControlled(offset, dst, dst.len, null, &completed);
        return completed;
    }

    /// A null destination warms the normal decoded cache. Cancellation is
    /// cooperative between pages; backend calls and shared loads may finish.
    pub fn readControlled(self: *FileHandle, offset: u64, dst: ?[]u8, size: usize, cancel: ?*const std.atomic.Value(bool), completed: *usize) !void {
        completed.* = 0;
        while (true) {
            var progress: usize = 0;
            var failure: ?anyerror = null;
            self.readOnce(offset + completed.*, if (dst) |buf| buf[completed.*..] else null, size - completed.*, cancel, &progress) catch |e| {
                failure = e;
            };
            completed.* += progress;
            if (failure) |e| {
                if (e != error.CacheBudgetExceeded) return e;
                // readOnce has unwound every store/cache pin. Waiting for a
                // competing read to release decoded memory is now safe even
                // with a one-store budget and foreign PageRefs. Permanent
                // oversized pages use CachePageTooLarge and never retry.
                if (cancel) |flag| if (flag.load(.acquire)) return error.Cancelled;
                @import("../task/scheduler.zig").sleepNs(100 * std.time.ns_per_us);
                continue;
            }
            return;
        }
    }

    fn readOnce(self: *FileHandle, offset: u64, dst: ?[]u8, size: usize, cancel: ?*const std.atomic.Value(bool), completed: *usize) !void {
        completed.* = 0;
        if (cancel) |flag| if (flag.load(.acquire)) return error.Cancelled;
        if (size == 0 or offset >= self.size) return;
        if (dst) |buf| if (buf.len != size) return error.InvalidArgument;
        const available = self.size - offset;
        const wanted = @min(@as(u64, size), available);
        var copied: usize = 0;
        const request_start = offset;
        const request_end = offset + wanted;

        // Writable mounts need a generation guard for the request. Immutable
        // read-only mounts only pin the page source actually being read, so a
        // one-store budget can serve overlay fallbacks and foreign refs.
        if (self.mounted.writable) try self.volume.pinMounted(self.mounted);
        defer if (self.mounted.writable) self.volume.unpinMounted(self.mounted);

        for (self.manifest.blocks, 0..) |block, block_i| {
            if (block.page_size == 0 and block.page_count != 0) return error.Corruption;
            const block_start = block.raw_offset;
            const block_end = block.raw_offset + block.raw_size;
            if (request_end <= block_start or request_start >= block_end) continue;
            const codec_identity = try registry.codecIdentity(block.codec);
            const block_index: u32 = @intCast(block_i);
            const explicit_refs = (block.flags & file_manifest_fmt.BLOCK_FLAG_EXPLICIT_PAGE_REFS) != 0;

            // Skip straight to the first overlapping page instead of scanning.
            var page_index: u32 = if (request_start > block_start) @intCast((request_start - block_start) / block.page_size) else 0;
            while (page_index < block.page_count) : (page_index += 1) {
                if (cancel) |flag| if (flag.load(.acquire)) return error.Cancelled;
                const page_start = block_start + @as(u64, page_index) * @as(u64, block.page_size);
                if (request_end <= page_start) break;
                const page_end = @min(block_end, page_start + block.page_size);
                if (request_start >= page_end) continue;

                const source: PageSource = if (explicit_refs) blk: {
                    const ref = try self.manifest.pageRef(block, page_index);
                    break :blk .{
                        .pack_id = ref.pack_id,
                        .pack_generation = ref.pack_generation,
                        .identity = page_value_fmt.PageIdentity{ .file_entry = ref.file_entry, .block_index = ref.block_index, .page_index = ref.page_index },
                        .page_key = ref.page_key,
                        .content_hash = ref.content_hash,
                        .raw_crc = ref.raw_crc,
                        .check_ref = true,
                    };
                } else blk: {
                    break :blk .{
                        .pack_id = self.pack_id,
                        .pack_generation = self.pack_generation,
                        .identity = page_value_fmt.PageIdentity{ .file_entry = self.file_entry, .block_index = block_index, .page_index = page_index },
                        .page_key = try object_key.pageKey(self.file_entry, block_index, page_index),
                        .content_hash = [_]u8{0} ** 32,
                        .raw_crc = 0,
                        .check_ref = false,
                    };
                };

                const copy_start_abs = @max(request_start, page_start);
                const copy_end_abs = @min(request_end, page_end);
                const page_off: usize = @intCast(copy_start_abs - page_start);
                const copy_len: usize = @intCast(copy_end_abs - copy_start_abs);
                const cache_key: @import("page_cache.zig").PageCacheKey = .{
                    .pack_id = source.pack_id,
                    .pack_generation = source.pack_generation,
                    .file_entry = source.identity.file_entry,
                    .block_index = source.identity.block_index,
                    .page_index = source.identity.page_index,
                    .codec_identity = codec_identity.version_hash,
                };

                const target: []u8 = if (dst) |buf| buf[copied..][0..copy_len] else &.{};
                const prefetch = dst == null;
                const whole_page = page_off == 0 and copy_len == page_end - page_start;
                if (!explicit_refs) {
                    // Implicit key: the page lives in our layer or, for an
                    // overlay, falls through to the base layer. A placeholder
                    // in our layer terminates the search.
                    const streaming = !prefetch and whole_page and (self.flags & OPEN_FLAG_STREAMING) != 0;
                    self.readImplicit(self.mounted, cache_key, source, block.codec, page_off, copy_len, target, streaming, prefetch) catch |e| switch (e) {
                        error.NotFound => {
                            const base = self.base orelse return error.NotFound;
                            var base_key = cache_key;
                            base_key.pack_generation = base.mount_order.load(.acquire);
                            self.readImplicit(base, base_key, source, block.codec, page_off, copy_len, target, streaming, prefetch) catch |e2| switch (e2) {
                                error.PagePlaceholder => return error.NotFound,
                                else => |err| return err,
                            };
                        },
                        error.PagePlaceholder => return error.NotFound,
                        else => |err| return err,
                    };
                } else {
                    const foreign = try self.volume.pinStoreMounted(source.pack_id, source.pack_generation);
                    defer self.volume.unpinMounted(foreign);
                    if (prefetch) {
                        try self.volume.page_cache.prefetchRange(std.heap.smp_allocator, foreign.reader, cache_key, source.identity, block.codec, source.page_key, page_off, copy_len, source.raw_crc, source.content_hash);
                    } else try self.volume.page_cache.copyRange(
                        std.heap.smp_allocator,
                        foreign.reader,
                        cache_key,
                        source.identity,
                        block.codec,
                        source.page_key,
                        page_off,
                        target,
                        source.raw_crc,
                        source.content_hash,
                    );
                }
                copied += copy_len;
                completed.* = copied;
            }
        }
    }

    fn readImplicit(
        self: *FileHandle,
        layer: *volume_mod.Volume.MountedPack,
        cache_key: @import("page_cache.zig").PageCacheKey,
        source: PageSource,
        codec: file_manifest_fmt.Codec,
        page_off: usize,
        size: usize,
        dst: []u8,
        streaming: bool,
        prefetch: bool,
    ) !void {
        try self.volume.pinMounted(layer);
        defer self.volume.unpinMounted(layer);
        if (prefetch) return self.volume.page_cache.prefetchRange(std.heap.smp_allocator, layer.reader, cache_key, source.identity, codec, source.page_key, page_off, size, null, null);
        if (streaming) {
            return self.volume.page_cache.readThrough(layer.reader, cache_key, source.identity, codec, source.page_key, dst);
        }
        return self.volume.page_cache.copyRange(std.heap.smp_allocator, layer.reader, cache_key, source.identity, codec, source.page_key, page_off, dst, null, null);
    }
};
