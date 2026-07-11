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
const hash = @import("../hash.zig");
const path_mod = @import("../path.zig");
const object_key = @import("../object_key.zig");
const registry = @import("../compress/registry.zig");
const fmt = @import("../format/common.zig");

pub const OpenOptions = struct {
    flags: u32 = 0,
};

pub const Volume = struct {
    pub const MountedPack = struct {
        meta: mount_table.MountEntry,
        reader: *pack_reader.PackReader,
        path: []u8,
        writable: bool = false,
    };

    root_path: []u8,
    options: OpenOptions,
    mounts: std.ArrayList(MountedPack) = .empty,
    page_cache: page_cache_mod.PageCache = .{},
    next_mount_order: u64 = 1,
    open_file_count: usize = 0,
    writable_path: []u8 = &.{},

    pub fn open(path: []const u8, options: OpenOptions) !Volume {
        if (path.len == 0) return error.InvalidArgument;
        const owned = try std.heap.smp_allocator.dupe(u8, path);
        return .{ .root_path = owned, .options = options };
    }

    pub fn close(self: *Volume) void {
        for (self.mounts.items) |mounted| {
            mounted.reader.close(std.heap.smp_allocator);
            std.heap.smp_allocator.destroy(mounted.reader);
            std.heap.smp_allocator.free(mounted.path);
        }
        self.mounts.deinit(std.heap.smp_allocator);
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
        if (pack_path.len == 0) return error.InvalidArgument;
        for (self.mounts.items) |mounted| if (mounted.meta.priority == priority) return error.InvalidArgument;
        const reader = try std.heap.smp_allocator.create(pack_reader.PackReader);
        errdefer std.heap.smp_allocator.destroy(reader);
        reader.* = try pack_reader.PackReader.open(std.heap.smp_allocator, pack_path);
        errdefer reader.close(std.heap.smp_allocator);
        const owned_path = try std.heap.smp_allocator.dupe(u8, pack_path);
        errdefer std.heap.smp_allocator.free(owned_path);
        try self.mounts.append(std.heap.smp_allocator, .{
            .meta = .{ .pack_id = @intCast(reader.manifest.pack_id), .priority = priority, .mount_order = self.next_mount_order, .pack_version = reader.manifest.pack_version, .flags = flags },
            .reader = reader,
            .path = owned_path,
        });
        self.next_mount_order += 1;
        std.mem.sort(MountedPack, self.mounts.items, {}, mountedHigherPriority);
    }

    pub const WriteOptions = struct {
        page_size: u32 = 64 * 1024,
    };

    pub fn setWritablePack(self: *Volume, pack_path: []const u8) !void {
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
        try self.mountPackWithPriority(pack_path, priority, 1);
        for (self.mounts.items) |*mounted| {
            if (mounted.meta.priority == priority) {
                mounted.writable = true;
                break;
            }
        }
        self.writable_path = try std.heap.smp_allocator.dupe(u8, pack_path);
    }

    pub fn findMountedPack(self: *Volume, pack_id: u32, pack_generation: u64) ?*MountedPack {
        for (self.mounts.items) |*mounted| {
            if (mounted.meta.pack_id == pack_id and mounted.meta.pack_version == pack_generation) return mounted;
        }
        return null;
    }

    pub fn findMountedPackContainingGeneration(self: *Volume, pack_id: u32, pack_generation: u64) ?*MountedPack {
        if (self.findMountedPack(pack_id, pack_generation)) |mounted| return mounted;
        for (self.mounts.items) |*mounted| {
            if (mounted.meta.pack_id == pack_id and mounted.meta.pack_version >= pack_generation) return mounted;
        }
        return null;
    }

    pub fn writeFileByEntry(self: *Volume, file_entry: u64, data: []const u8, options: WriteOptions) !void {
        try self.writeFileInternal(null, file_entry, data, options);
    }

    pub fn writeFileByPath(self: *Volume, virtual_path: []const u8, file_entry: u64, data: []const u8, options: WriteOptions) !void {
        try self.writeFileInternal(virtual_path, file_entry, data, options);
    }

    pub fn deleteEntry(self: *Volume, file_entry: u64) !void {
        if (file_entry == 0) return error.InvalidArgument;
        const mounted = self.writableMount() orelse return error.PermissionDenied;
        var writer = try pack_writer.PackWriter.create(std.heap.smp_allocator, mounted.path);
        var closed = false;
        errdefer if (!closed) writer.close() catch {};
        const tombstone = try tombstone_fmt.encodeEntryTombstone(.{ .file_entry = file_entry, .tombstone_version = 1, .reason_flags = 1 });
        try writer.putEntryTombstone(file_entry, &tombstone);
        const manifest = pack_manifest_fmt.encodePackManifest(.{ .pack_id = 1, .pack_version = mounted.reader.manifest.pack_version + 1, .build_id = mounted.reader.manifest.build_id + 1, .file_count = mounted.reader.manifest.file_count, .tombstone_count = mounted.reader.manifest.tombstone_count + 1, .content_hash = hash.contentHash(&tombstone) });
        try writer.putPackManifest(&manifest);
        try writer.close();
        closed = true;
        try self.refreshWritableMount();
    }

    fn writeFileInternal(self: *Volume, virtual_path: ?[]const u8, file_entry: u64, data: []const u8, options: WriteOptions) !void {
        if (file_entry == 0 or options.page_size == 0) return error.InvalidArgument;
        const mounted = self.writableMount() orelse return error.PermissionDenied;
        var old = self.resolveVisibleFile(file_entry) catch |e| switch (e) {
            error.NotFound => null,
            else => |err| return err,
        };
        defer if (old) |*resolved| resolved.deinit();

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
            if (try self.reusablePageRef(old, mounted, new_generation, page_index, payload, payload_hash, payload_crc)) |ref| {
                try page_refs.append(std.heap.smp_allocator, ref);
                continue;
            }
            const page_value = try page_value_fmt.encodePageValue(std.heap.smp_allocator, .{ .file_entry = file_entry, .block_index = 0, .page_index = page_index, .raw_size = @intCast(payload.len), .stored_size = @intCast(payload.len), .content_hash = payload_hash, .payload = payload });
            defer std.heap.smp_allocator.free(page_value);
            try writer.putPage(file_entry, 0, page_index, page_value);
            const key = try object_key.pageKey(file_entry, 0, page_index);
            try page_refs.append(std.heap.smp_allocator, .{
                .pack_id = mounted.meta.pack_id,
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
            .flags = file_manifest_fmt.BLOCK_FLAG_EXPLICIT_PAGE_REFS,
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
        const manifest = pack_manifest_fmt.encodePackManifest(.{ .pack_id = 1, .pack_version = mounted.reader.manifest.pack_version + 1, .build_id = mounted.reader.manifest.build_id + 1, .file_count = mounted.reader.manifest.file_count + @as(u64, if (existed) 0 else 1), .tombstone_count = mounted.reader.manifest.tombstone_count, .content_hash = hash.contentHash(data) });
        try writer.putPackManifest(&manifest);
        try writer.close();
        closed = true;
        try self.refreshWritableMount();
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
        for (self.mounts.items) |*mounted| {
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
            error.NotFound => return null,
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
                .pack_id = owner.meta.pack_id,
                .pack_generation = owner.meta.pack_version,
                .file_entry = manifest.header.file_entry,
                .block_index = block_index,
                .page_index = page_index,
                .page_key = key,
            };
        };
        const mounted = self.findMountedPackContainingGeneration(page_ref.pack_id, page_ref.pack_generation) orelse return error.NotFound;
        const page_bytes = try mounted.reader.readObjectAlloc(std.heap.smp_allocator, page_ref.page_key);
        defer std.heap.smp_allocator.free(page_bytes);
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
        for (self.mounts.items) |*mounted| if (mounted.writable) return mounted;
        return null;
    }

    fn refreshWritableMount(self: *Volume) !void {
        const mounted = self.writableMount() orelse return error.PermissionDenied;
        mounted.reader.close(std.heap.smp_allocator);
        mounted.reader.* = try pack_reader.PackReader.open(std.heap.smp_allocator, mounted.path);
        mounted.meta.pack_version = mounted.reader.manifest.pack_version;
        mounted.meta.mount_order = self.next_mount_order;
        self.next_mount_order += 1;
        self.page_cache.deinit(std.heap.smp_allocator);
    }

    pub fn openPath(self: *Volume, volume_handle: u64, path: []const u8) !file_handle.FileHandle {
        for (self.mounts.items) |mounted| {
            const file_entry = mounted.reader.resolvePath(std.heap.smp_allocator, path) catch |e| switch (e) {
                error.NotFound => continue,
                else => |err| return err,
            };
            return self.openEntry(volume_handle, file_entry);
        }
        return error.NotFound;
    }

    pub fn openEntry(self: *Volume, volume_handle: u64, file_entry: u64) !file_handle.FileHandle {
        if (file_entry == 0) return error.InvalidArgument;
        for (self.mounts.items) |mounted| {
            if (try mounted.reader.hasEntryTombstone(std.heap.smp_allocator, file_entry)) return error.NotFound;
            const manifest = mounted.reader.readFileManifest(std.heap.smp_allocator, file_entry) catch |e| switch (e) {
                error.NotFound => continue,
                else => |err| return err,
            };
            self.open_file_count += 1;
            return .{ .volume_handle = volume_handle, .volume = self, .pack = mounted.reader, .pack_id = mounted.meta.pack_id, .pack_generation = mounted.meta.mount_order, .file_entry = file_entry, .size = manifest.header.file_size, .manifest = manifest };
        }
        return error.NotFound;
    }

    pub fn statPath(self: *Volume, path: []const u8) !pack_reader.Stat {
        for (self.mounts.items) |mounted| {
            const file_entry = mounted.reader.resolvePath(std.heap.smp_allocator, path) catch |e| switch (e) {
                error.NotFound => continue,
                else => |err| return err,
            };
            return self.statEntry(file_entry);
        }
        return error.NotFound;
    }

    pub fn statEntry(self: *Volume, file_entry: u64) !pack_reader.Stat {
        if (file_entry == 0) return error.InvalidArgument;
        for (self.mounts.items) |mounted| {
            if (try mounted.reader.hasEntryTombstone(std.heap.smp_allocator, file_entry)) return error.NotFound;
            return mounted.reader.statEntry(std.heap.smp_allocator, file_entry) catch |e| switch (e) {
                error.NotFound => continue,
                else => |err| return err,
            };
        }
        return error.NotFound;
    }
};

fn mountedHigherPriority(_: void, a: Volume.MountedPack, b: Volume.MountedPack) bool {
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
