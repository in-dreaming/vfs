const std = @import("std");
const pack_reader = @import("../pack/pack_reader.zig");
const file_handle = @import("../io/file_handle.zig");
const mount_table = @import("mount_table.zig");
const page_cache_mod = @import("../io/page_cache.zig");
const pack_writer = @import("../pack/pack_writer.zig");
const path_index_fmt = @import("../format/path_index.zig");
const file_manifest_fmt = @import("../format/file_manifest.zig");
const page_value_fmt = @import("../format/page_value.zig");
const pack_manifest_fmt = @import("../format/pack_manifest.zig");
const tombstone_fmt = @import("../format/tombstone.zig");
const page_placeholder_fmt = @import("../format/page_placeholder.zig");
const hash = @import("../hash.zig");
const path_mod = @import("../path.zig");
const object_key = @import("../object_key.zig");
const registry = @import("../compress/registry.zig");
const fmt = @import("../format/common.zig");
const sync = @import("db_internal").platform.sync;

pub const DEFAULT_MAX_OPEN_STORES: u32 = 16;

pub const OpenOptions = struct {
    flags: u32 = 0,
    max_open_stores: u32 = DEFAULT_MAX_OPEN_STORES,
    /// Extra read-only OS handles per pack data file (see PackReader.OpenOptions).
    read_handles: u8 = pack_reader.DEFAULT_READ_HANDLES,
    /// Decoded page cache budget for this volume.
    page_cache_bytes: usize = page_cache_mod.DEFAULT_BUDGET_BYTES,
};

/// Sentinel added to `MountedPack.pin_count` while a store is being parked or
/// its reader replaced. A fast-path pin that observes a count at or above it
/// backs off to the locked slow path.
const PIN_PARKING: u32 = 1 << 31;

pub const Volume = struct {
    /// Heap node with a stable address for the lifetime of the volume, so file
    /// handles can cache a pointer instead of searching the mount table.
    pub const MountedPack = struct {
        meta: mount_table.MountEntry,
        reader: *pack_reader.PackReader,
        path: []u8,
        writable: bool = false,
        /// Readers currently using `reader`. Modified without the volume lock
        /// on the fast path; see `pinFast` / `drainPinsLocked`.
        pin_count: std.atomic.Value(u32) = .init(0),
        last_used: u64 = 0,
        /// Generation readers key their page-ref lookups and cache entries by.
        /// Mirrors `meta.pack_version` / `meta.mount_order`, which only change
        /// for the writable mount and only after its pins are drained.
        pack_version: std.atomic.Value(u64) = .init(0),
        mount_order: std.atomic.Value(u64) = .init(0),

        /// Lock-free pin when the store is ready and not being parked.
        fn pinFast(self: *MountedPack) ?*pack_reader.PackReader {
            const prev = self.pin_count.fetchAdd(1, .acquire);
            if (prev < PIN_PARKING and self.reader.isReady()) return self.reader;
            _ = self.pin_count.fetchSub(1, .release);
            return null;
        }

        fn unpin(self: *MountedPack) u32 {
            return self.pin_count.fetchSub(1, .release);
        }
    };

    /// Immutable, priority-ordered view of the mount table published to
    /// readers with a single atomic store. Lists are retired (not freed)
    /// until `close`, so a reader may keep using one without any lock.
    const MountList = struct {
        items: []*MountedPack,
    };

    root_path: []u8,
    options: OpenOptions,
    /// Write-side mount table, sorted by descending priority. Nodes are only
    /// freed in `close`.
    mounts: std.ArrayList(*MountedPack) = .empty,
    /// Read-side view; see `MountList`.
    published: std.atomic.Value(?*const MountList) = .init(null),
    retired_lists: std.ArrayList(*MountList) = .empty,
    page_cache: page_cache_mod.PageCache = .{},
    next_mount_order: u64 = 1,
    open_file_count: std.atomic.Value(usize) = .init(0),
    writable_path: []u8 = &.{},
    /// Serializes mount / write / park / refresh. Readers never take it; they
    /// use `published` and per-mount atomic pins.
    lock: sync.Mutex = .{},
    store_clock: u64 = 1,
    store_available: sync.Condition = .{},
    store_notify_lock: sync.Mutex = .{},
    store_epoch: u64 = 0,
    store_waiters: std.atomic.Value(u32) = .init(0),

    pub fn open(path: []const u8, options: OpenOptions) !Volume {
        if (path.len == 0) return error.InvalidArgument;
        const owned = try std.heap.smp_allocator.dupe(u8, path);
        var opts = options;
        if (opts.max_open_stores == 0) opts.max_open_stores = DEFAULT_MAX_OPEN_STORES;
        if (opts.page_cache_bytes == 0) opts.page_cache_bytes = page_cache_mod.DEFAULT_BUDGET_BYTES;
        return .{ .root_path = owned, .options = opts, .page_cache = .{ .budget_bytes = opts.page_cache_bytes } };
    }

    pub fn close(self: *Volume) void {
        for (self.mounts.items) |mounted| {
            mounted.reader.close(std.heap.smp_allocator);
            std.heap.smp_allocator.destroy(mounted.reader);
            std.heap.smp_allocator.free(mounted.path);
            std.heap.smp_allocator.destroy(mounted);
        }
        self.mounts.deinit(std.heap.smp_allocator);
        for (self.retired_lists.items) |list| {
            std.heap.smp_allocator.free(list.items);
            std.heap.smp_allocator.destroy(list);
        }
        self.retired_lists.deinit(std.heap.smp_allocator);
        self.published.store(null, .release);
        self.page_cache.deinit(std.heap.smp_allocator);
        if (self.writable_path.len != 0) std.heap.smp_allocator.free(self.writable_path);
        if (self.root_path.len != 0) {
            std.heap.smp_allocator.free(self.root_path);
            self.root_path = &.{};
        }
    }

    pub fn mountPack(self: *Volume, pack_path: []const u8, _: u32, _: u32) !void {
        return self.mountPackWithPriority(pack_path, 0, 0);
    }

    pub fn mountPackWithPriority(self: *Volume, pack_path: []const u8, priority: u32, flags: u32) !void {
        self.lock.lock();
        defer self.lock.unlock();
        try self.mountPackWithPriorityLocked(pack_path, priority, flags);
        try self.evictReadonlyLocked();
    }

    fn mountPackWithPriorityLocked(self: *Volume, pack_path: []const u8, priority: u32, flags: u32) !void {
        if (pack_path.len == 0) return error.InvalidArgument;
        for (self.mounts.items) |mounted| if (mounted.meta.priority == priority) return error.InvalidArgument;
        const reader = try std.heap.smp_allocator.create(pack_reader.PackReader);
        errdefer std.heap.smp_allocator.destroy(reader);
        reader.* = try pack_reader.PackReader.openWithOptions(std.heap.smp_allocator, pack_path, .{ .read_handles = self.options.read_handles });
        errdefer reader.close(std.heap.smp_allocator);
        try self.checkOverlayLayeringLocked(reader.manifest, priority);
        const owned_path = try std.heap.smp_allocator.dupe(u8, pack_path);
        errdefer std.heap.smp_allocator.free(owned_path);
        const node = try std.heap.smp_allocator.create(MountedPack);
        errdefer std.heap.smp_allocator.destroy(node);
        self.store_clock += 1;
        node.* = .{
            .meta = .{ .pack_id = reader.manifest.pack_id, .priority = priority, .mount_order = self.next_mount_order, .pack_version = reader.manifest.pack_version, .flags = flags },
            .reader = reader,
            .path = owned_path,
            .last_used = self.store_clock,
            .pack_version = .init(reader.manifest.pack_version),
            .mount_order = .init(self.next_mount_order),
        };
        try self.mounts.append(std.heap.smp_allocator, node);
        errdefer _ = self.mounts.pop();
        self.next_mount_order += 1;
        std.mem.sort(*MountedPack, self.mounts.items, {}, mountedHigherPriority);
        try self.publishMountsLocked();
    }

    /// Overlay layering rules for mounts sharing a pack_id: an overlay must sit
    /// above exactly one non-overlay base whose pack_version equals the
    /// overlay's recorded base version; two overlays of one pack are rejected.
    /// Plain (non-overlay) packs that happen to share a pack_id are left to
    /// the existing priority semantics.
    fn checkOverlayLayeringLocked(self: *Volume, incoming: pack_manifest_fmt.PackManifest, priority: u32) !void {
        for (self.mounts.items) |mounted| {
            if (mounted.meta.pack_id != incoming.pack_id) continue;
            const existing = mounted.reader.manifest;
            if (incoming.isOverlay() and existing.isOverlay()) return error.InvalidArgument;
            if (incoming.isOverlay()) {
                if (incoming.base_pack_version != existing.pack_version) return error.InvalidArgument;
                if (priority <= mounted.meta.priority) return error.InvalidArgument;
            } else if (existing.isOverlay()) {
                if (existing.base_pack_version != incoming.pack_version) return error.InvalidArgument;
                if (priority >= mounted.meta.priority) return error.InvalidArgument;
            }
        }
    }

    /// The base layer under an overlay mount (same pack_id, lower priority).
    pub fn baseLayerOf(self: *Volume, mounted: *MountedPack) ?*MountedPack {
        if (!mounted.reader.manifest.isOverlay()) return null;
        for (self.currentMounts()) |candidate| {
            if (candidate == mounted) continue;
            if (candidate.meta.pack_id == mounted.meta.pack_id and !candidate.reader.manifest.isOverlay()) return candidate;
        }
        return null;
    }

    /// The overlay layer above a base mount, if one is mounted.
    pub fn overlayLayerOf(self: *Volume, mounted: *MountedPack) ?*MountedPack {
        if (mounted.reader.manifest.isOverlay()) return null;
        for (self.currentMounts()) |candidate| {
            if (candidate == mounted) continue;
            if (candidate.meta.pack_id == mounted.meta.pack_id and candidate.reader.manifest.isOverlay()) return candidate;
        }
        return null;
    }

    /// Snapshot `self.mounts` into a fresh immutable list and publish it.
    fn publishMountsLocked(self: *Volume) !void {
        const list = try std.heap.smp_allocator.create(MountList);
        errdefer std.heap.smp_allocator.destroy(list);
        list.* = .{ .items = try std.heap.smp_allocator.dupe(*MountedPack, self.mounts.items) };
        errdefer std.heap.smp_allocator.free(list.items);
        try self.retired_lists.append(std.heap.smp_allocator, list);
        self.published.store(list, .release);
    }

    /// Lock-free, priority-ordered view of the mount table.
    fn currentMounts(self: *Volume) []const *MountedPack {
        const list = self.published.load(.acquire) orelse return &.{};
        return list.items;
    }

    fn findInList(list: []const *MountedPack, pack_id: u64, pack_generation: u64) ?*MountedPack {
        for (list) |mounted| {
            if (mounted.meta.pack_id == pack_id and mounted.pack_version.load(.acquire) == pack_generation) return mounted;
        }
        for (list) |mounted| {
            if (mounted.meta.pack_id == pack_id and mounted.pack_version.load(.acquire) >= pack_generation) return mounted;
        }
        for (list) |mounted| {
            if (mounted.meta.pack_id == pack_id) return mounted;
        }
        return null;
    }

    pub const WriteOptions = struct {
        page_size: u32 = 64 * 1024,
    };

    pub fn setWritablePack(self: *Volume, pack_path: []const u8) !void {
        self.lock.lock();
        defer self.lock.unlock();
        if (self.writable_path.len != 0) return error.InvalidArgument;
        var existing = pack_reader.PackReader.open(std.heap.smp_allocator, pack_path) catch |e| switch (e) {
            error.NotFound, error.FileNotFound => null,
            else => |err| return err,
        };
        if (existing) |*reader| {
            reader.close(std.heap.smp_allocator);
        } else {
            try createEmptyPack(pack_path);
        }
        const priority = std.math.maxInt(u32);
        try self.mountPackWithPriorityLocked(pack_path, priority, 1);
        for (self.mounts.items) |mounted| {
            if (mounted.meta.priority == priority) {
                mounted.writable = true;
                break;
            }
        }
        self.writable_path = try std.heap.smp_allocator.dupe(u8, pack_path);
    }

    pub fn findMountedPack(self: *Volume, pack_id: u64, pack_generation: u64) ?*MountedPack {
        for (self.mounts.items) |mounted| {
            if (mounted.meta.pack_id == pack_id and mounted.meta.pack_version == pack_generation) return mounted;
        }
        return null;
    }

    pub fn findMountedPackContainingGeneration(self: *Volume, pack_id: u64, pack_generation: u64) ?*MountedPack {
        if (self.findMountedPack(pack_id, pack_generation)) |mounted| return mounted;
        for (self.mounts.items) |mounted| {
            if (mounted.meta.pack_id == pack_id and mounted.meta.pack_version >= pack_generation) return mounted;
        }
        return null;
    }

    pub fn writeFileByEntry(self: *Volume, file_entry: u64, data: []const u8, options: WriteOptions) !void {
        self.lock.lock();
        defer self.lock.unlock();
        try self.writeFileInternal(null, file_entry, data, options);
    }

    pub fn writeFileByPath(self: *Volume, virtual_path: []const u8, file_entry: u64, data: []const u8, options: WriteOptions) !void {
        self.lock.lock();
        defer self.lock.unlock();
        try self.writeFileInternal(virtual_path, file_entry, data, options);
    }

    pub fn deleteEntry(self: *Volume, file_entry: u64) !void {
        self.lock.lock();
        defer self.lock.unlock();
        if (file_entry == 0) return error.InvalidArgument;
        const mounted = self.writableMount() orelse return error.PermissionDenied;
        var writer = try pack_writer.PackWriter.create(std.heap.smp_allocator, mounted.path);
        var closed = false;
        errdefer if (!closed) writer.close() catch {};
        const tombstone = try tombstone_fmt.encodeEntryTombstone(.{ .file_entry = file_entry, .tombstone_version = 1, .reason_flags = 1 });
        try writer.putEntryTombstone(file_entry, &tombstone);
        const manifest = pack_manifest_fmt.encodePackManifest(.{ .pack_id = mounted.meta.pack_id, .pack_version = mounted.reader.manifest.pack_version + 1, .build_id = mounted.reader.manifest.build_id + 1, .file_count = mounted.reader.manifest.file_count, .tombstone_count = mounted.reader.manifest.tombstone_count + 1, .content_hash = hash.contentHash(&tombstone) });
        try writer.putPackManifest(&manifest);
        try writer.close();
        closed = true;
        try self.refreshWritableMount();
        try self.evictReadonlyLocked();
    }

    fn writeFileInternal(self: *Volume, virtual_path: ?[]const u8, file_entry: u64, data: []const u8, options: WriteOptions) !void {
        if (file_entry == 0 or options.page_size == 0) return error.InvalidArgument;
        const mounted = self.writableMount() orelse return error.PermissionDenied;
        var old = self.resolveVisibleFile(file_entry) catch |e| switch (e) {
            error.NotFound => null,
            else => |err| return err,
        };
        defer if (old) |*resolved| resolved.deinit();

        // Existing explicit PageRef records encode only u32 IDs. Preserve
        // wider pack identities by writing ordinary implicit pages instead.
        const ref_pack_id = std.math.cast(u32, mounted.meta.pack_id);
        var writer = try pack_writer.PackWriter.create(std.heap.smp_allocator, mounted.path);
        var closed = false;
        errdefer if (!closed) writer.close() catch {};
        const page_count: u32 = if (data.len == 0) 0 else std.math.cast(u32, ((data.len - 1) / options.page_size) + 1) orelse return error.InvalidArgument;
        const new_generation = mounted.reader.manifest.pack_version + 1;
        var page_refs = std.ArrayList(file_manifest_fmt.PageRef).empty;
        defer page_refs.deinit(std.heap.smp_allocator);
        var page_index: u32 = 0;
        while (page_index < page_count) : (page_index += 1) {
            const start: usize = @as(usize, page_index) * @as(usize, options.page_size);
            const end = @min(data.len, start + options.page_size);
            const payload = data[start..end];
            const payload_hash = hash.contentHash(payload);
            const payload_crc = hash.crc32c(payload);
            if (ref_pack_id != null) {
                if (try self.reusablePageRef(old, mounted, new_generation, page_index, payload, payload_hash, payload_crc)) |ref| {
                    try page_refs.append(std.heap.smp_allocator, ref);
                    continue;
                }
            }
            const page_value = try page_value_fmt.encodePageValue(std.heap.smp_allocator, .{ .file_entry = file_entry, .block_index = 0, .page_index = page_index, .raw_size = @intCast(payload.len), .stored_size = @intCast(payload.len), .content_hash = payload_hash, .payload = payload });
            defer std.heap.smp_allocator.free(page_value);
            try writer.putPage(file_entry, 0, page_index, page_value);
            const key = try object_key.pageKey(file_entry, 0, page_index);
            if (ref_pack_id) |id| try page_refs.append(std.heap.smp_allocator, .{
                .pack_id = id,
                .pack_generation = new_generation,
                .file_entry = file_entry,
                .block_index = 0,
                .page_index = page_index,
                .page_key = key,
                .raw_hash = payload_hash,
                .content_hash = payload_hash,
                .raw_crc = payload_crc,
            });
        }
        const blocks = if (data.len == 0) &[_]file_manifest_fmt.BlockDesc{} else &[_]file_manifest_fmt.BlockDesc{.{
            .raw_offset = 0,
            .raw_size = data.len,
            .page_size = options.page_size,
            .page_count = page_count,
            .codec = .none,
            .block_hash = hash.contentHash(data),
            .flags = if (ref_pack_id != null) file_manifest_fmt.BLOCK_FLAG_EXPLICIT_PAGE_REFS else 0,
            .page_ref_offset = 0,
        }};
        const file_manifest = try file_manifest_fmt.encodeFileManifest(std.heap.smp_allocator, .{ .file_entry = file_entry, .file_version = new_generation, .file_size = data.len, .content_hash = hash.contentHash(data), .blocks = blocks, .page_refs = page_refs.items });
        defer std.heap.smp_allocator.free(file_manifest);
        try writer.putFileManifest(file_entry, file_manifest);
        if (virtual_path) |vp| try rewriteWritablePathIndex(&writer, mounted.reader, vp, file_entry);
        const existed = blk: {
            var existing = mounted.reader.readFileManifest(std.heap.smp_allocator, file_entry) catch |e| switch (e) {
                error.NotFound => break :blk false,
                else => |err| return err,
            };
            existing.deinit(std.heap.smp_allocator);
            break :blk true;
        };
        const manifest = pack_manifest_fmt.encodePackManifest(.{ .pack_id = mounted.meta.pack_id, .pack_version = mounted.reader.manifest.pack_version + 1, .build_id = mounted.reader.manifest.build_id + 1, .file_count = mounted.reader.manifest.file_count + @as(u64, if (existed) 0 else 1), .tombstone_count = mounted.reader.manifest.tombstone_count, .content_hash = hash.contentHash(data) });
        try writer.putPackManifest(&manifest);
        try writer.close();
        closed = true;
        try self.refreshWritableMount();
        try self.evictReadonlyLocked();
    }

    const ResolvedFile = struct {
        mounted: *MountedPack,
        manifest: file_manifest_fmt.DecodedFileManifest,

        fn deinit(self: *ResolvedFile) void {
            self.manifest.deinit(std.heap.smp_allocator);
        }
    };

    const LoadedPage = struct {
        raw: []u8,
        ref: file_manifest_fmt.PageRef,

        fn deinit(self: *LoadedPage) void {
            std.heap.smp_allocator.free(self.raw);
        }
    };

    fn resolveVisibleFile(self: *Volume, file_entry: u64) !ResolvedFile {
        if (file_entry == 0) return error.InvalidArgument;
        for (self.mounts.items) |mounted| {
            try mounted.reader.ensureReady();
            if (try mounted.reader.hasEntryTombstone(std.heap.smp_allocator, file_entry)) return error.NotFound;
            const manifest = mounted.reader.readFileManifest(std.heap.smp_allocator, file_entry) catch |e| switch (e) {
                error.NotFound => continue,
                else => |err| return err,
            };
            return .{ .mounted = mounted, .manifest = manifest };
        }
        return error.NotFound;
    }

    fn reusablePageRef(
        self: *Volume,
        old: ?ResolvedFile,
        target: *MountedPack,
        target_generation: u64,
        page_index: u32,
        payload: []const u8,
        payload_hash: [32]u8,
        payload_crc: u32,
    ) !?file_manifest_fmt.PageRef {
        var resolved = old orelse return null;
        if (resolved.manifest.blocks.len == 0) return null;
        const block = resolved.manifest.blocks[0];
        if (block.page_size == 0 or page_index >= block.page_count) return null;
        var loaded = self.loadPageFromManifest(resolved.mounted, &resolved.manifest, 0, page_index) catch |e| switch (e) {
            error.NotFound, error.UnsupportedFeature => return null,
            else => |err| return err,
        };
        defer loaded.deinit();
        if (!std.mem.eql(u8, loaded.raw, payload)) return null;
        if (!std.mem.eql(u8, &hash.contentHash(loaded.raw), &payload_hash) or hash.crc32c(loaded.raw) != payload_crc) return null;
        var ref = loaded.ref;
        if (ref.pack_id == target.meta.pack_id and ref.pack_generation == target.meta.pack_version) {
            ref.pack_generation = target_generation;
        }
        return ref;
    }

    fn loadPageFromManifest(self: *Volume, owner: *MountedPack, manifest: *const file_manifest_fmt.DecodedFileManifest, block_index: u32, page_index: u32) !LoadedPage {
        if (block_index >= manifest.blocks.len) return error.NotFound;
        const block = manifest.blocks[block_index];
        if (page_index >= block.page_count) return error.NotFound;
        const page_ref = if ((block.flags & file_manifest_fmt.BLOCK_FLAG_EXPLICIT_PAGE_REFS) != 0)
            try manifest.pageRef(block, page_index)
        else blk: {
            const key = try object_key.pageKey(manifest.header.file_entry, block_index, page_index);
            break :blk file_manifest_fmt.PageRef{
                .pack_id = std.math.cast(u32, owner.meta.pack_id) orelse return error.UnsupportedFeature,
                .pack_generation = owner.meta.pack_version,
                .file_entry = manifest.header.file_entry,
                .block_index = block_index,
                .page_index = page_index,
                .page_key = key,
            };
        };
        var mounted = self.findMountedPackContainingGeneration(page_ref.pack_id, page_ref.pack_generation) orelse return error.NotFound;
        try mounted.reader.ensureReady();
        const page_bytes = mounted.reader.readObjectAlloc(std.heap.smp_allocator, page_ref.page_key) catch |e| switch (e) {
            error.NotFound => blk: {
                // Overlay layer without this page: fall through to its base.
                mounted = self.baseLayerOf(mounted) orelse return error.NotFound;
                try mounted.reader.ensureReady();
                break :blk try mounted.reader.readObjectAlloc(std.heap.smp_allocator, page_ref.page_key);
            },
            else => |err| return err,
        };
        defer std.heap.smp_allocator.free(page_bytes);
        if (page_placeholder_fmt.isPlaceholder(page_bytes)) return error.NotFound;
        const page = try page_value_fmt.decodePageValue(page_bytes, .{ .file_entry = page_ref.file_entry, .block_index = page_ref.block_index, .page_index = page_ref.page_index });
        const raw = try registry.decompressPage(std.heap.smp_allocator, page.codec, page.payload, page.raw_size, page.raw_crc);
        errdefer std.heap.smp_allocator.free(raw);
        const raw_hash = hash.contentHash(raw);
        const raw_crc = hash.crc32c(raw);
        if ((block.flags & file_manifest_fmt.BLOCK_FLAG_EXPLICIT_PAGE_REFS) != 0) {
            if (raw_crc != page_ref.raw_crc) return error.ChecksumMismatch;
            if (!std.mem.eql(u8, &raw_hash, &page_ref.content_hash)) return error.ChecksumMismatch;
        }
        var normalized_ref = page_ref;
        normalized_ref.raw_hash = raw_hash;
        normalized_ref.content_hash = page.content_hash;
        normalized_ref.raw_crc = page.raw_crc;
        return .{ .raw = raw, .ref = normalized_ref };
    }

    fn writableMount(self: *Volume) ?*MountedPack {
        for (self.mounts.items) |mounted| if (mounted.writable) return mounted;
        return null;
    }

    // ------------------------------------------------------------------
    // Store pinning
    // ------------------------------------------------------------------

    /// Resolve the mount that serves `pack_id`/`pack_generation` (a page ref
    /// may point at an older generation of a pack that has since been
    /// refreshed) and pin it. The returned node stays valid for the volume's
    /// lifetime; `unpinMounted` must be called once per successful pin.
    pub fn pinStoreMounted(self: *Volume, pack_id: u64, pack_generation: u64) !*MountedPack {
        const mounted = findInList(self.currentMounts(), pack_id, pack_generation) orelse return error.NotFound;
        try self.pinMounted(mounted);
        return mounted;
    }

    /// Pin one page source. Slow-path contenders sleep until a store becomes
    /// idle, rather than spending a fixed spin budget against busy readers.
    /// Callers must not retain an unrelated read-only store while acquiring.
    pub fn pinMounted(self: *Volume, mounted: *MountedPack) !void {
        if (mounted.pinFast() != null) return;
        while (true) {
            self.lock.lock();
            self.store_notify_lock.lock();
            const observed = self.store_epoch;
            self.store_notify_lock.unlock();
            self.pinMountedLocked(mounted) catch |e| {
                self.lock.unlock();
                if (e != error.Busy) return e;
                // An epoch prevents a lost wake between the failed attempt
                // and waiting. Notification never needs the volume lock:
                // the releasing reader may still hold a writable generation
                // pin which an updater is draining under that lock.
                self.store_notify_lock.lock();
                _ = self.store_waiters.fetchAdd(1, .release);
                while (self.store_epoch == observed) self.store_available.wait(&self.store_notify_lock);
                _ = self.store_waiters.fetchSub(1, .release);
                self.store_notify_lock.unlock();
                continue;
            };
            self.lock.unlock();
            return;
        }
    }

    pub fn unpinMounted(self: *Volume, mounted: *MountedPack) void {
        const previous = mounted.unpin();
        if (previous == 1 and !mounted.writable) {
            self.store_notify_lock.lock();
            defer self.store_notify_lock.unlock();
            self.store_epoch +%= 1;
            self.store_available.broadcast();
        }
    }

    pub fn readonlyReadyCount(self: *Volume) usize {
        self.lock.lock();
        defer self.lock.unlock();
        return self.readonlyReadyCountLocked();
    }

    fn findMountedPackById(self: *Volume, pack_id: u64) ?*MountedPack {
        for (self.mounts.items) |mounted| {
            if (mounted.meta.pack_id == pack_id) return mounted;
        }
        return null;
    }

    /// Slow path, exclusive lock held: make room under `max_open_stores`,
    /// unpark the store and pin it.
    fn pinMountedLocked(self: *Volume, mounted: *MountedPack) !void {
        if (!mounted.writable and !mounted.reader.isReady()) {
            while (self.readonlyReadyCountLocked() >= self.options.max_open_stores) {
                const victim = self.lruIdleReadonlyLocked() orelse return error.Busy;
                self.parkLocked(victim) catch |e| switch (e) {
                    // A fast-path reader pinned the victim after the LRU scan;
                    // it is no longer idle, so the next scan picks another.
                    error.Busy => continue,
                    else => |err| return err,
                };
            }
        }
        try mounted.reader.ensureReady();
        _ = mounted.pin_count.fetchAdd(1, .acquire);
        self.store_clock += 1;
        mounted.last_used = self.store_clock;
    }

    fn readonlyReadyCountLocked(self: *const Volume) usize {
        var n: usize = 0;
        for (self.mounts.items) |mounted| {
            if (!mounted.writable and mounted.reader.isReady()) n += 1;
        }
        return n;
    }

    fn lruIdleReadonlyLocked(self: *Volume) ?*MountedPack {
        var victim: ?*MountedPack = null;
        var oldest: u64 = std.math.maxInt(u64);
        for (self.mounts.items) |mounted| {
            if (mounted.writable or !mounted.reader.isReady() or mounted.pin_count.load(.acquire) != 0) continue;
            if (mounted.last_used <= oldest) {
                oldest = mounted.last_used;
                victim = mounted;
            }
        }
        return victim;
    }

    /// Park an idle store. Fails with Busy if a fast-path reader pinned it
    /// between the LRU scan and now; callers simply pick another victim.
    fn parkLocked(_: *Volume, mounted: *MountedPack) !void {
        if (mounted.pin_count.cmpxchgStrong(0, PIN_PARKING, .acq_rel, .acquire) != null) return error.Busy;
        defer _ = mounted.pin_count.fetchSub(PIN_PARKING, .release);
        try mounted.reader.park();
    }

    fn evictReadonlyLocked(self: *Volume) !void {
        var attempts: usize = 0;
        while (self.readonlyReadyCountLocked() > self.options.max_open_stores) {
            const victim = self.lruIdleReadonlyLocked() orelse break;
            self.parkLocked(victim) catch |e| switch (e) {
                error.Busy => {
                    attempts += 1;
                    if (attempts > self.mounts.items.len) break;
                    continue;
                },
                else => |err| return err,
            };
        }
    }

    /// Block until no fast-path reader is using `mounted`, then hold it in the
    /// PARKING state so none can start. Exclusive lock must be held.
    fn drainPinsLocked(mounted: *MountedPack) void {
        var spins: u32 = 0;
        while (mounted.pin_count.cmpxchgWeak(0, PIN_PARKING, .acq_rel, .acquire) != null) {
            spins += 1;
            if (spins < 64) std.atomic.spinLoopHint() else std.Thread.yield() catch {};
        }
    }

    fn releaseDrainedLocked(mounted: *MountedPack) void {
        _ = mounted.pin_count.fetchSub(PIN_PARKING, .release);
    }

    fn refreshWritableMount(self: *Volume) !void {
        const mounted = self.writableMount() orelse return error.PermissionDenied;
        drainPinsLocked(mounted);
        defer releaseDrainedLocked(mounted);
        mounted.reader.close(std.heap.smp_allocator);
        mounted.reader.* = try pack_reader.PackReader.openWithOptions(std.heap.smp_allocator, mounted.path, .{ .read_handles = self.options.read_handles });
        mounted.meta.pack_version = mounted.reader.manifest.pack_version;
        mounted.meta.mount_order = self.next_mount_order;
        mounted.pack_version.store(mounted.meta.pack_version, .release);
        mounted.mount_order.store(mounted.meta.mount_order, .release);
        self.next_mount_order += 1;
        self.page_cache.deinit(std.heap.smp_allocator);
    }

    // ------------------------------------------------------------------
    // Read path (lock-free: published mount list + atomic pins)
    // ------------------------------------------------------------------

    fn resolvePathEntry(self: *Volume, path: []const u8) !u64 {
        for (self.currentMounts()) |mounted| {
            // The path index lives in memory, but the pin keeps a writable-pack
            // refresh from freeing it underneath us.
            try self.pinMounted(mounted);
            defer self.unpinMounted(mounted);
            const file_entry = mounted.reader.resolvePath(std.heap.smp_allocator, path) catch |e| switch (e) {
                error.NotFound => continue,
                else => |err| return err,
            };
            return file_entry;
        }
        return error.NotFound;
    }

    pub fn openPath(self: *Volume, volume_handle: u64, path: []const u8) !file_handle.FileHandle {
        return self.openPathWithFlags(volume_handle, path, 0);
    }

    pub fn openPathWithFlags(self: *Volume, volume_handle: u64, path: []const u8, flags: u32) !file_handle.FileHandle {
        const file_entry = try self.resolvePathEntry(path);
        return self.openEntryWithFlags(volume_handle, file_entry, flags);
    }

    pub fn openEntry(self: *Volume, volume_handle: u64, file_entry: u64) !file_handle.FileHandle {
        return self.openEntryWithFlags(volume_handle, file_entry, 0);
    }

    pub fn openEntryWithFlags(self: *Volume, volume_handle: u64, file_entry: u64, flags: u32) !file_handle.FileHandle {
        if (file_entry == 0) return error.InvalidArgument;
        for (self.currentMounts()) |mounted| {
            try self.pinMounted(mounted);
            defer self.unpinMounted(mounted);
            const reader = mounted.reader;
            if (try reader.hasEntryTombstone(std.heap.smp_allocator, file_entry)) return error.NotFound;
            const manifest = reader.readFileManifest(std.heap.smp_allocator, file_entry) catch |e| switch (e) {
                error.NotFound => continue,
                else => |err| return err,
            };
            // Page resolution always starts at the overlay layer (if any) and
            // falls through to the base, regardless of which layer held the
            // FileManifest: an overlay may override pages of a file whose
            // manifest it did not touch.
            var top = mounted;
            var base: ?*MountedPack = null;
            if (mounted.reader.manifest.isOverlay()) {
                base = self.baseLayerOf(mounted);
            } else if (self.overlayLayerOf(mounted)) |ov| {
                top = ov;
                base = mounted;
            }
            _ = self.open_file_count.fetchAdd(1, .seq_cst);
            return .{
                .volume_handle = volume_handle,
                .volume = self,
                .mounted = top,
                .base = base,
                .pack_id = top.meta.pack_id,
                .pack_generation = top.mount_order.load(.acquire),
                .file_entry = file_entry,
                .size = manifest.header.file_size,
                .manifest = manifest,
                .flags = flags,
            };
        }
        return error.NotFound;
    }

    pub fn statPath(self: *Volume, path: []const u8) !pack_reader.Stat {
        const file_entry = try self.resolvePathEntry(path);
        return self.statEntry(file_entry);
    }

    pub fn statEntry(self: *Volume, file_entry: u64) !pack_reader.Stat {
        if (file_entry == 0) return error.InvalidArgument;
        for (self.currentMounts()) |mounted| {
            try self.pinMounted(mounted);
            defer self.unpinMounted(mounted);
            const reader = mounted.reader;
            if (try reader.hasEntryTombstone(std.heap.smp_allocator, file_entry)) return error.NotFound;
            return reader.statEntry(std.heap.smp_allocator, file_entry) catch |e| switch (e) {
                error.NotFound => continue,
                else => |err| return err,
            };
        }
        return error.NotFound;
    }
};

fn mountedHigherPriority(_: void, a: *Volume.MountedPack, b: *Volume.MountedPack) bool {
    return a.meta.priority > b.meta.priority;
}

fn createEmptyPack(pack_path: []const u8) !void {
    var writer = try pack_writer.PackWriter.create(std.heap.smp_allocator, pack_path);
    var closed = false;
    errdefer if (!closed) writer.close() catch {};
    const path_index = try path_index_fmt.encodePathIndex(std.heap.smp_allocator, &.{});
    defer std.heap.smp_allocator.free(path_index);
    try writer.putPathIndex(path_index);
    const manifest = pack_manifest_fmt.encodePackManifest(.{ .pack_id = 1, .pack_version = 1, .build_id = 1, .file_count = 0, .tombstone_count = 0, .content_hash = hash.contentHash("") });
    try writer.putPackManifest(&manifest);
    try writer.close();
    closed = true;
}

fn rewriteWritablePathIndex(writer: *pack_writer.PackWriter, reader: *pack_reader.PackReader, virtual_path: []const u8, file_entry: u64) !void {
    const allocator = std.heap.smp_allocator;
    const normalized = try path_mod.normalizeVirtualPath(allocator, virtual_path);
    defer allocator.free(normalized);
    const existing = try path_index_fmt.collectEntries(allocator, reader.path_index);
    defer path_index_fmt.freeDecodedEntries(allocator, existing);
    var inputs = std.ArrayList(path_index_fmt.EntryInput).empty;
    defer inputs.deinit(allocator);
    var replaced = false;
    for (existing) |entry| {
        if (std.mem.eql(u8, entry.normalized_path, normalized)) {
            try inputs.append(allocator, .{ .normalized_path = normalized, .file_entry = file_entry, .flags = entry.flags });
            replaced = true;
        } else {
            try inputs.append(allocator, .{ .normalized_path = entry.normalized_path, .file_entry = entry.file_entry, .flags = entry.flags });
        }
    }
    if (!replaced) try inputs.append(allocator, .{ .normalized_path = normalized, .file_entry = file_entry });
    const encoded = try path_index_fmt.encodePathIndex(allocator, inputs.items);
    defer allocator.free(encoded);
    try writer.putPathIndex(encoded);
}
test "volume owns copied root path" {
    var v = try Volume.open("assets", .{});
    defer v.close();
    try std.testing.expectEqualStrings("assets", v.root_path);
}

test "volume writable out pack whole-file rewrite and tombstone overlay" {
    const builder = @import("../build/pack_builder.zig");
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    const writable_path = "zig-cache-vfs-writable-out-pack";
    const base_path = "zig-cache-vfs-writable-base-pack";
    const source_path = "zig-cache-vfs-writable-base-source.bin";
    _ = std.Io.Dir.cwd().deleteTree(io, writable_path) catch {};
    _ = std.Io.Dir.cwd().deleteTree(io, base_path) catch {};
    _ = std.Io.Dir.cwd().deleteFile(io, source_path) catch {};
    defer _ = std.Io.Dir.cwd().deleteTree(io, writable_path) catch {};
    defer _ = std.Io.Dir.cwd().deleteTree(io, base_path) catch {};
    defer _ = std.Io.Dir.cwd().deleteFile(io, source_path) catch {};

    var v = try Volume.open("root", .{});
    defer v.close();
    try std.testing.expectError(error.PermissionDenied, v.writeFileByEntry(1001, "nope", .{ .page_size = 4 }));
    try v.setWritablePack(writable_path);
    try v.writeFileByEntry(1001, "hello", .{ .page_size = 4 });
    var handle = try v.openEntry(1, 1001);
    var buf: [32]u8 = undefined;
    var n = try handle.readAt(0, &buf);
    try std.testing.expectEqualSlices(u8, "hello", buf[0..n]);
    handle.close();

    try v.writeFileByPath("/new.txt", 1002, "path-data", .{ .page_size = 4 });
    handle = try v.openPath(1, "/new.txt");
    n = try handle.readAt(0, &buf);
    try std.testing.expectEqualSlices(u8, "path-data", buf[0..n]);
    handle.close();

    try builder.writeSourceFileForTest(source_path, "old-data");
    try builder.createPack(base_path, &.{.{ .source_path = source_path, .virtual_path = "/old.txt", .file_entry = 1003, .page_size = 4 }}, .{});
    try v.mountPackWithPriority(base_path, 1, 0);
    try v.writeFileByEntry(1003, "new-data", .{ .page_size = 4 });
    handle = try v.openEntry(1, 1003);
    n = try handle.readAt(0, &buf);
    try std.testing.expectEqualSlices(u8, "new-data", buf[0..n]);
    handle.close();
    handle = try v.openPath(1, "/old.txt");
    n = try handle.readAt(0, &buf);
    try std.testing.expectEqualSlices(u8, "new-data", buf[0..n]);
    handle.close();

    try v.deleteEntry(1003);
    try std.testing.expectError(error.NotFound, v.openEntry(1, 1003));
    try std.testing.expectError(error.NotFound, v.openPath(1, "/old.txt"));
    try optimizeDbForTest(writable_path);
    try builder.verifyPackDb(writable_path, allocator);
}

test "volume page-level incremental uses explicit refs and fails on missing or corrupt refs" {
    const builder = @import("../build/pack_builder.zig");
    const pack_tools = @import("../tools/pack_tools.zig");
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    const base_path = "zig-cache-vfs-page-incremental-base";
    const writable_path = "zig-cache-vfs-page-incremental-writable";
    const source_path = "zig-cache-vfs-page-incremental-source.bin";
    _ = std.Io.Dir.cwd().deleteTree(io, base_path) catch {};
    _ = std.Io.Dir.cwd().deleteTree(io, writable_path) catch {};
    _ = std.Io.Dir.cwd().deleteFile(io, source_path) catch {};
    defer _ = std.Io.Dir.cwd().deleteTree(io, base_path) catch {};
    defer _ = std.Io.Dir.cwd().deleteTree(io, writable_path) catch {};
    defer _ = std.Io.Dir.cwd().deleteFile(io, source_path) catch {};

    try builder.writeSourceFileForTest(source_path, "aaaabbbbcccc");
    try builder.createPack(base_path, &.{.{ .source_path = source_path, .virtual_path = "/big.bin", .file_entry = 3001, .page_size = 4 }}, .{ .pack_id = 10, .pack_version = 1 });

    var v = try Volume.open("root", .{});
    defer v.close();
    try v.setWritablePack(writable_path);
    try v.mountPackWithPriority(base_path, 1, 0);
    try v.writeFileByEntry(3001, "aaaaXXXXcccc", .{ .page_size = 4 });

    var out_reader = try pack_reader.PackReader.open(allocator, writable_path);
    defer out_reader.close(allocator);
    var manifest = try out_reader.readFileManifest(allocator, 3001);
    defer manifest.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 1), manifest.blocks.len);
    try std.testing.expect((manifest.blocks[0].flags & file_manifest_fmt.BLOCK_FLAG_EXPLICIT_PAGE_REFS) != 0);
    try std.testing.expectEqual(@as(usize, 3), manifest.page_refs.len);
    try std.testing.expectEqual(@as(u32, 10), manifest.page_refs[0].pack_id);
    try std.testing.expectEqual(@as(u32, 1), manifest.page_refs[1].pack_id);
    try std.testing.expectEqual(@as(u32, 10), manifest.page_refs[2].pack_id);
    try std.testing.expectError(error.NotFound, out_reader.readObjectAlloc(allocator, try object_key.pageKey(3001, 0, 0)));
    const changed_page = try out_reader.readObjectAlloc(allocator, try object_key.pageKey(3001, 0, 1));
    allocator.free(changed_page);
    try std.testing.expectError(error.NotFound, out_reader.readObjectAlloc(allocator, try object_key.pageKey(3001, 0, 2)));

    var handle = try v.openEntry(1, 3001);
    var buf: [16]u8 = undefined;
    const incremental_n = try handle.readAt(0, &buf);
    handle.close();
    try std.testing.expectEqualSlices(u8, "aaaaXXXXcccc", buf[0..incremental_n]);

    // Close/reopen the writable output as a read-only mount. With a strict
    // one-store budget, foreign-page reads must release the unused top store.
    var bounded = try Volume.open("bounded-foreign", .{ .max_open_stores = 1 });
    defer bounded.close();
    try bounded.mountPackWithPriority(base_path, 1, 0);
    try bounded.mountPackWithPriority(writable_path, 2, 0);
    var foreign_handle = try bounded.openEntry(1, 3001);
    defer foreign_handle.close();
    const foreign_n = try foreign_handle.readAt(0, &buf);
    try std.testing.expectEqualSlices(u8, "aaaaXXXXcccc", buf[0..foreign_n]);
    try std.testing.expect(bounded.readonlyReadyCount() <= 1);

    var missing = try Volume.open("missing-base", .{});
    defer missing.close();
    try missing.mountPackWithPriority(writable_path, 0, 0);
    handle = try missing.openEntry(1, 3001);
    try std.testing.expectError(error.NotFound, handle.readAt(0, &buf));
    handle.close();

    try mutateDbObjectForTest(writable_path, try object_key.fileManifestKey(3001), struct {
        fn f(bytes: []u8) !void {
            const second_ref = file_manifest_fmt.HEADER_SIZE + file_manifest_fmt.BLOCK_DESC_SIZE + file_manifest_fmt.PAGE_REF_SIZE;
            fmt.putU64(bytes, second_ref + 16, 9999);
            fmt.putU32(bytes, 76, fmt.crc32cWithZeroU32(bytes, 76));
        }
    }.f);
    var ref_report = try pack_tools.verifyPack(writable_path, allocator);
    defer ref_report.deinit(allocator);
    try expectVerifyIssueForTest(ref_report, .page_ref_identity_mismatch);

    var corrupt = try Volume.open("corrupt-ref", .{});
    defer corrupt.close();
    try corrupt.mountPackWithPriority(writable_path, 2, 0);
    try corrupt.mountPackWithPriority(base_path, 1, 0);
    handle = try corrupt.openEntry(1, 3001);
    try std.testing.expectError(error.Corruption, handle.readAt(4, buf[0..4]));
    handle.close();
}

test "volume concurrent readers share one pack store" {
    const builder = @import("../build/pack_builder.zig");
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    const pack_path = "zig-cache-vfs-concurrent-pack";
    const source_path = "zig-cache-vfs-concurrent-source.bin";
    _ = std.Io.Dir.cwd().deleteTree(io, pack_path) catch {};
    _ = std.Io.Dir.cwd().deleteFile(io, source_path) catch {};
    defer _ = std.Io.Dir.cwd().deleteTree(io, pack_path) catch {};
    defer _ = std.Io.Dir.cwd().deleteFile(io, source_path) catch {};
    const payload = "concurrent-read-payload!!";
    try builder.writeSourceFileForTest(source_path, payload);
    try builder.createPack(pack_path, &.{.{ .source_path = source_path, .virtual_path = "/c.bin", .file_entry = 8001, .page_size = 8 }}, .{});

    var v = try Volume.open("concurrent-root", .{});
    defer v.close();
    try v.mountPackWithPriority(pack_path, 1, 0);

    const Ctx = struct {
        volume: *Volume,
        errors: *[4]u32,
        payload: []const u8,

        fn reader(ctx: *@This(), id: usize) void {
            var handle = ctx.volume.openPath(1, "/c.bin") catch {
                ctx.errors[id] = 1;
                return;
            };
            defer handle.close();
            var round: usize = 0;
            while (round < 32) : (round += 1) {
                var buf: [32]u8 = undefined;
                const n = handle.readAt(0, &buf) catch {
                    ctx.errors[id] = 2;
                    return;
                };
                if (n != ctx.payload.len or !std.mem.eql(u8, buf[0..n], ctx.payload)) {
                    ctx.errors[id] = 3;
                    return;
                }
            }
        }
    };

    var errors = [_]u32{0} ** 4;
    var ctx = Ctx{ .volume = &v, .errors = &errors, .payload = payload };
    var threads: [4]std.Thread = undefined;
    for (&threads, 0..) |*thread, i| thread.* = try std.Thread.spawn(.{}, Ctx.reader, .{ &ctx, i });
    for (&threads) |*thread| thread.join();
    for (errors) |e| try std.testing.expectEqual(@as(u32, 0), e);
    _ = allocator;
}

test "volume parks idle readonly stores under max_open_stores" {
    const builder = @import("../build/pack_builder.zig");
    const io = std.Io.Threaded.global_single_threaded.io();
    const n_packs = 4;
    var pack_paths: [n_packs][64]u8 = undefined;
    var source_paths: [n_packs][64]u8 = undefined;
    var pack_slices: [n_packs][]u8 = undefined;
    var i: usize = 0;
    while (i < n_packs) : (i += 1) {
        pack_slices[i] = std.fmt.bufPrint(&pack_paths[i], "zig-cache-vfs-store-gc-{d}", .{i}) catch unreachable;
        const source = std.fmt.bufPrint(&source_paths[i], "zig-cache-vfs-store-gc-src-{d}.bin", .{i}) catch unreachable;
        _ = std.Io.Dir.cwd().deleteTree(io, pack_slices[i]) catch {};
        _ = std.Io.Dir.cwd().deleteFile(io, source) catch {};
        var payload: [8]u8 = undefined;
        @memset(&payload, @as(u8, 'A') + @as(u8, @intCast(i)));
        try builder.writeSourceFileForTest(source, &payload);
        try builder.createPack(pack_slices[i], &.{.{
            .source_path = source,
            .virtual_path = "/f.bin",
            .file_entry = 9000 + i,
            .page_size = 8,
        }}, .{ .pack_id = @intCast(20 + i) });
    }
    defer {
        var j: usize = 0;
        while (j < n_packs) : (j += 1) {
            _ = std.Io.Dir.cwd().deleteTree(io, pack_slices[j]) catch {};
            const source = std.fmt.bufPrint(&source_paths[j], "zig-cache-vfs-store-gc-src-{d}.bin", .{j}) catch unreachable;
            _ = std.Io.Dir.cwd().deleteFile(io, source) catch {};
        }
    }

    var v = try Volume.open("gc-root", .{ .max_open_stores = 2 });
    defer v.close();
    i = 0;
    while (i < n_packs) : (i += 1) {
        try v.mountPackWithPriority(pack_slices[i], @intCast(i + 1), 0);
    }
    try std.testing.expect(v.readonlyReadyCount() <= 2);

    i = 0;
    while (i < n_packs) : (i += 1) {
        var handle = try v.openEntry(1, 9000 + i);
        var buf: [8]u8 = undefined;
        const n = try handle.readAt(0, &buf);
        handle.close();
        var expect: [8]u8 = undefined;
        @memset(&expect, @as(u8, 'A') + @as(u8, @intCast(i)));
        try std.testing.expectEqualSlices(u8, &expect, buf[0..n]);
        try std.testing.expect(v.readonlyReadyCount() <= 2);
    }
}

test "volume concurrent readers across many packs with max_open_stores=1 exercise park/pin protocol" {
    const builder = @import("../build/pack_builder.zig");
    const io = std.Io.Threaded.global_single_threaded.io();
    const n_packs = 6;
    const page = 64;
    const pages = 4;
    var pack_paths: [n_packs][64]u8 = undefined;
    var source_paths: [n_packs][64]u8 = undefined;
    var pack_slices: [n_packs][]u8 = undefined;
    var payloads: [n_packs][page * pages]u8 = undefined;
    var i: usize = 0;
    while (i < n_packs) : (i += 1) {
        pack_slices[i] = std.fmt.bufPrint(&pack_paths[i], "zig-cache-vfs-park-stress-{d}", .{i}) catch unreachable;
        const source = std.fmt.bufPrint(&source_paths[i], "zig-cache-vfs-park-stress-src-{d}.bin", .{i}) catch unreachable;
        _ = std.Io.Dir.cwd().deleteTree(io, pack_slices[i]) catch {};
        _ = std.Io.Dir.cwd().deleteFile(io, source) catch {};
        for (&payloads[i], 0..) |*b, j| b.* = @truncate(j *% (i + 3));
        try builder.writeSourceFileForTest(source, &payloads[i]);
        try builder.createPack(pack_slices[i], &.{.{ .source_path = source, .virtual_path = "/f.bin", .file_entry = 9100 + i, .page_size = page }}, .{ .pack_id = @intCast(40 + i) });
    }
    defer {
        var j: usize = 0;
        while (j < n_packs) : (j += 1) {
            _ = std.Io.Dir.cwd().deleteTree(io, pack_slices[j]) catch {};
            const source = std.fmt.bufPrint(&source_paths[j], "zig-cache-vfs-park-stress-src-{d}.bin", .{j}) catch unreachable;
            _ = std.Io.Dir.cwd().deleteFile(io, source) catch {};
        }
    }

    // A tiny page cache forces the DB read path on almost every request.
    var v = try Volume.open("park-stress", .{ .max_open_stores = 1, .page_cache_bytes = page * 2 });
    defer v.close();
    i = 0;
    while (i < n_packs) : (i += 1) try v.mountPackWithPriority(pack_slices[i], @intCast(i + 1), 0);

    const Ctx = struct {
        volume: *Volume,
        payloads: *const [n_packs][page * pages]u8,
        errors: *std.atomic.Value(u32),

        fn run(ctx: *@This(), seed: u64) void {
            var prng = std.Random.DefaultPrng.init(seed);
            const random = prng.random();
            // Nearly every open parks one store and unparks another (close +
            // reopen of DB files), so keep the round count modest.
            var round: usize = 0;
            while (round < 100) : (round += 1) {
                const which = random.uintLessThan(usize, n_packs);
                var handle = ctx.volume.openEntry(1, 9100 + which) catch {
                    _ = ctx.errors.fetchAdd(1, .seq_cst);
                    return;
                };
                defer handle.close();
                const off = random.uintLessThan(usize, page * pages - 1);
                const len = 1 + random.uintLessThan(usize, page * pages - off);
                var buf: [page * pages]u8 = undefined;
                const n = handle.readAt(off, buf[0..len]) catch {
                    _ = ctx.errors.fetchAdd(1, .seq_cst);
                    return;
                };
                if (n != len or !std.mem.eql(u8, buf[0..n], ctx.payloads[which][off .. off + len])) {
                    _ = ctx.errors.fetchAdd(1, .seq_cst);
                    return;
                }
            }
        }
    };
    var errors = std.atomic.Value(u32).init(0);
    var ctx = Ctx{ .volume = &v, .payloads = &payloads, .errors = &errors };
    var threads: [8]std.Thread = undefined;
    for (&threads, 0..) |*t, k| t.* = try std.Thread.spawn(.{}, Ctx.run, .{ &ctx, @as(u64, k) + 11 });
    for (&threads) |*t| t.join();
    try std.testing.expectEqual(@as(u32, 0), errors.load(.seq_cst));
    try std.testing.expect(v.readonlyReadyCount() <= 1);
    for (v.mounts.items) |mounted| try std.testing.expectEqual(@as(u32, 0), mounted.pin_count.load(.acquire));
}

fn optimizeDbForTest(path: []const u8) !void {
    const db_internal = @import("db_internal");
    var db = try db_internal.kv_db.KvDb.open(path, .{});
    defer db.close() catch {};
    try db.optimize();
}

fn mutateDbObjectForTest(pack_path: []const u8, key: u64, mutator: *const fn ([]u8) anyerror!void) !void {
    const db_internal = @import("db_internal");
    var db = try db_internal.kv_db.KvDb.open(pack_path, .{ .mode = .read_write, .create_if_missing = false });
    defer db.close() catch {};
    var raw = object_key.encodeDbKey(key);
    const size = try db.getSizeBytes(&raw);
    const bytes = try std.testing.allocator.alloc(u8, size);
    defer std.testing.allocator.free(bytes);
    _ = try db.getIntoBytes(&raw, bytes);
    try mutator(bytes);
    try db.putBytes(&raw, bytes, .{ .durability = .sync });
    try db.commitPending(.sync);
    try db.optimize();
}

fn expectVerifyIssueForTest(report: anytype, kind: anytype) !void {
    for (report.issues.items) |issue| if (issue.kind == kind) return;
    return error.TestExpectedEqual;
}

test "u64 pack identities remain distinct and unencodable foreign refs are copied" {
    const builder = @import("../build/pack_builder.zig");
    const io = std.Io.Threaded.global_single_threaded.io();
    const high_path = "zig-cache-vfs-wide-id-high";
    const low_path = "zig-cache-vfs-wide-id-low";
    const writable_path = "zig-cache-vfs-wide-id-writable";
    const source = "zig-cache-vfs-wide-id.bin";
    defer std.Io.Dir.cwd().deleteTree(io, high_path) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, low_path) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, writable_path) catch {};
    defer std.Io.Dir.cwd().deleteFile(io, source) catch {};
    const high_id: u64 = (@as(u64, 1) << 40) | 7;
    try builder.writeSourceFileForTest(source, "high");
    try builder.createPack(high_path, &.{.{ .source_path = source, .virtual_path = "/high", .file_entry = 8903, .page_size = 4 }}, .{ .pack_id = high_id });
    try builder.writeSourceFileForTest(source, "low!");
    try builder.createPack(low_path, &.{.{ .source_path = source, .virtual_path = "/low", .file_entry = 8904, .page_size = 4 }}, .{ .pack_id = 7 });
    var volume = try Volume.open("wide", .{ .max_open_stores = 1 });
    defer volume.close();
    try volume.mountPackWithPriority(high_path, 1, 0);
    try volume.mountPackWithPriority(low_path, 2, 0);
    const high = volume.findMountedPack(high_id, 1).?;
    const low = volume.findMountedPack(7, 1).?;
    try std.testing.expect(high != low);
    var file = try volume.openPath(0, "/high");
    var bytes: [4]u8 = undefined;
    _ = try file.readAt(0, &bytes);
    file.close();
    try std.testing.expectEqualStrings("high", &bytes);
    try volume.setWritablePack(writable_path);
    try volume.writeFileByEntry(8903, "high", .{ .page_size = 4 });
    file = try volume.openEntry(0, 8903);
    defer file.close();
    try std.testing.expectEqual(@as(u32, 1), file.manifest.page_refs[0].pack_id);
    _ = try file.readAt(0, &bytes);
    try std.testing.expectEqualStrings("high", &bytes);
    // A high-ID destination uses the existing implicit-page encoding rather
    // than truncating its ID to fit an explicit PageRef.
    var destination = try Volume.open("wide-destination", .{});
    defer destination.close();
    try destination.setWritablePack(high_path);
    try destination.writeFileByEntry(8903, "edit", .{ .page_size = 4 });
    try std.testing.expectEqual(high_id, destination.writableMount().?.reader.manifest.pack_id);
    var edited = try destination.openEntry(0, 8903);
    _ = try edited.readAt(0, &bytes);
    try std.testing.expectEqualStrings("edit", &bytes);
    try std.testing.expectEqual(@as(u32, 0), edited.manifest.blocks[0].flags & file_manifest_fmt.BLOCK_FLAG_EXPLICIT_PAGE_REFS);
    edited.close();
    try destination.deleteEntry(8903);
    try std.testing.expectEqual(high_id, destination.writableMount().?.reader.manifest.pack_id);
}

test "store availability wake never takes the updater lock under an outer writable pin" {
    const builder = @import("../build/pack_builder.zig");
    const io = std.Io.Threaded.global_single_threaded.io();
    const r_path = "zig-cache-vfs-pin-order-r";
    const s_path = "zig-cache-vfs-pin-order-s";
    const w_path = "zig-cache-vfs-pin-order-w";
    const source = "zig-cache-vfs-pin-order.bin";
    defer std.Io.Dir.cwd().deleteTree(io, r_path) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, s_path) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, w_path) catch {};
    defer std.Io.Dir.cwd().deleteFile(io, source) catch {};
    try builder.writeSourceFileForTest(source, "pin");
    try builder.createPack(r_path, &.{.{ .source_path = source, .virtual_path = "/r", .file_entry = 8905, .page_size = 4 }}, .{ .pack_id = 50 });
    try builder.createPack(s_path, &.{.{ .source_path = source, .virtual_path = "/s", .file_entry = 8906, .page_size = 4 }}, .{ .pack_id = 51 });
    var volume = try Volume.open("pin-order", .{ .max_open_stores = 1 });
    defer volume.close();
    try volume.setWritablePack(w_path);
    try volume.mountPackWithPriority(r_path, 1, 0);
    try volume.mountPackWithPriority(s_path, 2, 0);
    const writable = volume.writableMount().?;
    const r = volume.findMountedPack(50, 1).?;
    const s = volume.findMountedPack(51, 1).?;
    try volume.pinMounted(writable);
    try volume.pinMounted(r);
    const Ctx = struct {
        volume: *Volume,
        mounted: *Volume.MountedPack,
        locked: std.atomic.Value(bool) = .init(false),
        fn waiter(ctx: *@This()) void {
            ctx.volume.pinMounted(ctx.mounted) catch unreachable;
            ctx.volume.unpinMounted(ctx.mounted);
        }
        fn updater(ctx: *@This()) void {
            ctx.volume.lock.lock();
            defer ctx.volume.lock.unlock();
            ctx.locked.store(true, .release);
            Volume.drainPinsLocked(ctx.mounted);
            Volume.releaseDrainedLocked(ctx.mounted);
        }
    };
    var waiting = Ctx{ .volume = &volume, .mounted = s };
    const waiter = try std.Thread.spawn(.{}, Ctx.waiter, .{&waiting});
    while (volume.store_waiters.load(.acquire) == 0) std.Thread.yield() catch {};
    var updating = Ctx{ .volume = &volume, .mounted = writable };
    const updater = try std.Thread.spawn(.{}, Ctx.updater, .{&updating});
    while (!updating.locked.load(.acquire)) std.Thread.yield() catch {};
    // This is the exact nesting of a writable file's foreign-page read. The
    // updater owns Volume.lock and awaits our outer pin, so notifying an idle
    // foreign store must not acquire that lock before we can drop the outer.
    volume.unpinMounted(r);
    volume.unpinMounted(writable);
    updater.join();
    waiter.join();
    try std.testing.expect(volume.readonlyReadyCount() <= 1);
}
