const std = @import("std");
const builtin = @import("builtin");

const Io = std.Io;
const Dir = std.Io.Dir;
const File = std.Io.File;

pub const OPEN_FLAG_CREATE: u32 = 1 << 0;
pub const OPEN_FLAG_READ_ONLY: u32 = 1 << 1;
pub const OPEN_FLAG_READ_WRITE: u32 = 1 << 2;
pub const MMAP_FLAG_WRITE: u32 = 1 << 0;
pub const SYNC_DATA: u32 = 0;
pub const SYNC_METADATA: u32 = 1;

pub const RawFileOps = extern struct {
    struct_size: u32,
    version: u32,
    user_data: ?*anyopaque,
    open: ?*const anyopaque,
    close: ?*const anyopaque,
    read_at: ?*const anyopaque,
    write_at: ?*const anyopaque,
    get_size: ?*const anyopaque,
    set_size: ?*const anyopaque,
    sync: ?*const anyopaque,
    preallocate: ?*const anyopaque,
    mmap: ?*const anyopaque,
    msync: ?*const anyopaque,
    munmap: ?*const anyopaque,
};

pub const CustomOpenFn = *const fn (?*anyopaque, [*]const u8, u64, u32, *?*anyopaque) callconv(.c) c_int;
pub const CustomCloseFn = *const fn (?*anyopaque) callconv(.c) c_int;
pub const CustomReadAtFn = *const fn (?*anyopaque, u64, ?*anyopaque, u64, *u64) callconv(.c) c_int;
pub const CustomWriteAtFn = *const fn (?*anyopaque, u64, ?*const anyopaque, u64, *u64) callconv(.c) c_int;
pub const CustomGetSizeFn = *const fn (?*anyopaque, *u64) callconv(.c) c_int;
pub const CustomSetSizeFn = *const fn (?*anyopaque, u64) callconv(.c) c_int;
pub const CustomSyncFn = *const fn (?*anyopaque, u32) callconv(.c) c_int;
pub const CustomPreallocateFn = *const fn (?*anyopaque, u64, u64) callconv(.c) c_int;
pub const CustomMmapFn = *const fn (?*anyopaque, u64, u64, u32, *?*anyopaque, *?*anyopaque, *u64) callconv(.c) c_int;
pub const CustomMsyncFn = *const fn (?*anyopaque, u64, u64, u32) callconv(.c) c_int;
pub const CustomMunmapFn = *const fn (?*anyopaque) callconv(.c) c_int;

pub const CustomFileOps = struct {
    user_data: ?*anyopaque,
    open: CustomOpenFn,
    close: CustomCloseFn,
    read_at: CustomReadAtFn,
    write_at: CustomWriteAtFn,
    get_size: CustomGetSizeFn,
    set_size: CustomSetSizeFn,
    sync: CustomSyncFn,
    preallocate: ?CustomPreallocateFn,
    mmap: ?CustomMmapFn,
    msync: ?CustomMsyncFn,
    munmap: ?CustomMunmapFn,
};

// The v1 C layout stores function pointers as opaque pointers (alignment 1).
// Some targets, including AArch64, require aligned function addresses. Reject
// malformed tables before asserting that alignment for the typed pointer.
fn rawCallback(comptime T: type, raw: ?*const anyopaque) !T {
    const p = raw orelse return error.InvalidArgument;
    const info = @typeInfo(T).pointer;
    const alignment = info.alignment orelse @alignOf(info.child);
    if (@intFromPtr(p) % alignment != 0) return error.InvalidArgument;
    return @ptrCast(@alignCast(p));
}

pub fn customOpsFromRaw(raw: *const RawFileOps) !CustomFileOps {
    if (raw.struct_size < @offsetOf(RawFileOps, "munmap") + @sizeOf(?*const anyopaque)) return error.InvalidArgument;
    if (raw.version != 1) return error.UnsupportedVersion;
    return .{
        .user_data = raw.user_data,
        .open = try rawCallback(CustomOpenFn, raw.open),
        .close = try rawCallback(CustomCloseFn, raw.close),
        .read_at = try rawCallback(CustomReadAtFn, raw.read_at),
        .write_at = try rawCallback(CustomWriteAtFn, raw.write_at),
        .get_size = try rawCallback(CustomGetSizeFn, raw.get_size),
        .set_size = try rawCallback(CustomSetSizeFn, raw.set_size),
        .sync = try rawCallback(CustomSyncFn, raw.sync),
        .preallocate = if (raw.preallocate) |p| try rawCallback(CustomPreallocateFn, p) else null,
        .mmap = if (raw.mmap) |p| try rawCallback(CustomMmapFn, p) else null,
        .msync = if (raw.msync) |p| try rawCallback(CustomMsyncFn, p) else null,
        .munmap = if (raw.munmap) |p| try rawCallback(CustomMunmapFn, p) else null,
    };
}

pub const Directory = struct {
    os: ?Dir = null,
    custom_root: []const u8 = &.{},
    custom_ops: ?CustomFileOps = null,

    pub fn fromOs(dir: Dir) Directory {
        return .{ .os = dir };
    }

    pub fn fromCustom(root: []const u8, ops: CustomFileOps) Directory {
        return .{ .custom_root = root, .custom_ops = ops };
    }
};

fn defaultIo() Io {
    return std.Io.Threaded.global_single_threaded.io();
}

pub const FileHandle = struct {
    native: ?File,
    custom: ?*anyopaque = null,
    custom_ops: ?CustomFileOps = null,
    writable: bool = false,

    fn file(self: FileHandle) !File {
        return self.native orelse error.InvalidArgument;
    }

    pub fn isOpen(self: FileHandle) bool {
        return self.native != null or self.custom != null;
    }
};

pub const OpenMode = enum {
    read_only,
    read_write,
    create_read_write,
};

pub const OpenOptions = struct {
    mode: OpenMode,
    random_access_hint: bool = true,
    sequential_hint: bool = false,
    direct_io: bool = false,
    create_parent_dirs: bool = false,
};

pub const IoVec = struct {
    data: []const u8,
};

pub const Advice = enum {
    normal,
    random,
    sequential,
    will_need,
    dont_need,
};

pub const MappedRegion = struct {
    map: ?File.MemoryMap = null,
    custom_mapping: ?*anyopaque = null,
    custom_ops: ?CustomFileOps = null,
    custom_bytes: []u8 = &.{},
    writable: bool = false,

    pub fn bytes(self: *MappedRegion) []u8 {
        if (self.map) |*map| return map.memory;
        return self.custom_bytes;
    }

    pub fn bytesConst(self: *const MappedRegion) []const u8 {
        if (self.map) |*map| return map.memory;
        return self.custom_bytes;
    }

    pub fn ptr(self: *MappedRegion) [*]u8 {
        if (self.map) |*map| return map.memory.ptr;
        return self.custom_bytes.ptr;
    }

    pub fn len(self: *const MappedRegion) usize {
        if (self.map) |*map| return map.memory.len;
        return self.custom_bytes.len;
    }
};

pub fn open(path: []const u8, options: OpenOptions) !FileHandle {
    const io = defaultIo();
    if (options.create_parent_dirs) {
        if (std.fs.path.dirname(path)) |parent| {
            if (parent.len != 0) {
                try Dir.cwd().createDirPath(io, parent);
            }
        }
    }
    return openAt(Dir.cwd(), path, options);
}

pub fn openAt(dir: Dir, path: []const u8, options: OpenOptions) !FileHandle {
    return openIn(.fromOs(dir), path, options);
}

pub fn openIn(dir: Directory, path: []const u8, options: OpenOptions) !FileHandle {
    if (dir.custom_ops) |ops| return openCustom(dir.custom_root, ops, path, options);
    const io = defaultIo();
    _ = options.random_access_hint;
    _ = options.sequential_hint;
    _ = options.direct_io;
    const os_dir = dir.os orelse return error.InvalidArgument;
    const file = switch (options.mode) {
        .read_only => try os_dir.openFile(io, path, .{
            .mode = .read_only,
            .allow_directory = false,
        }),
        .read_write => try os_dir.openFile(io, path, .{
            .mode = .read_write,
            .allow_directory = false,
        }),
        .create_read_write => try os_dir.createFile(io, path, .{
            .read = true,
            .truncate = false,
        }),
    };
    return .{ .native = file, .writable = options.mode != .read_only };
}

fn openCustom(root: []const u8, ops: CustomFileOps, path: []const u8, options: OpenOptions) !FileHandle {
    const joined = if (root.len == 0)
        try std.heap.smp_allocator.dupe(u8, path)
    else
        // Provider roots are opaque identifiers, not filesystem paths. Preserve
        // every root byte and use a platform-independent leaf separator.
        try std.mem.concat(std.heap.smp_allocator, u8, &.{ root, "/", path });
    defer std.heap.smp_allocator.free(joined);
    const flags: u32 = switch (options.mode) {
        .read_only => OPEN_FLAG_READ_ONLY,
        .read_write => OPEN_FLAG_READ_WRITE,
        .create_read_write => OPEN_FLAG_READ_WRITE | OPEN_FLAG_CREATE,
    };
    _ = options.random_access_hint;
    _ = options.sequential_hint;
    _ = options.direct_io;
    _ = options.create_parent_dirs;
    var out_file: ?*anyopaque = null;
    statusToError(ops.open(ops.user_data, joined.ptr, joined.len, flags, &out_file)) catch |err| {
        if (out_file) |handle| _ = ops.close(handle);
        return err;
    };
    return .{ .native = null, .custom = out_file orelse return error.IoError, .custom_ops = ops, .writable = options.mode != .read_only };
}

pub fn close(file: *FileHandle) void {
    if (file.native) |native| {
        native.close(defaultIo());
        file.native = null;
    }
    if (file.custom) |custom| {
        if (file.custom_ops) |ops| _ = ops.close(custom);
        file.custom = null;
    }
}

pub fn pread(file: FileHandle, offset: u64, dst: []u8) !usize {
    // Positional reads do not move a shared file offset, so concurrent threads
    // may pread the same OS handle. The Io implementation is used only as the
    // syscall adapter; fileReadPositional ignores the single-threaded scheduler.
    if (file.custom) |custom| {
        _ = std.math.add(u64, offset, dst.len) catch return error.InvalidArgument;
        const ops = file.custom_ops orelse return error.InvalidArgument;
        var got: u64 = 0;
        try statusToError(ops.read_at(custom, offset, dst.ptr, dst.len, &got));
        if (got > dst.len) return error.IoError;
        return @intCast(got);
    }
    return (try file.file()).readPositional(defaultIo(), &.{dst}, offset);
}

pub fn preadAll(file: FileHandle, offset: u64, dst: []u8) !usize {
    if (file.custom != null) {
        _ = std.math.add(u64, offset, dst.len) catch return error.InvalidArgument;
        var total: usize = 0;
        while (total < dst.len) {
            const got = try pread(file, offset + total, dst[total..]);
            if (got == 0) break;
            total += got;
        }
        return total;
    }
    return (try file.file()).readPositionalAll(defaultIo(), dst, offset);
}

pub fn pwrite(file: FileHandle, offset: u64, src: []const u8) !usize {
    if (!file.writable) return error.AccessDenied;
    if (file.custom) |custom| {
        _ = std.math.add(u64, offset, src.len) catch return error.InvalidArgument;
        const ops = file.custom_ops orelse return error.InvalidArgument;
        var wrote: u64 = 0;
        try statusToError(ops.write_at(custom, offset, src.ptr, src.len, &wrote));
        if (wrote > src.len) return error.IoError;
        return @intCast(wrote);
    }
    return (try file.file()).writePositional(defaultIo(), &.{src}, offset);
}

pub fn pwriteAll(file: FileHandle, offset: u64, src: []const u8) !void {
    if (!file.writable) return error.AccessDenied;
    if (file.custom != null) {
        _ = std.math.add(u64, offset, src.len) catch return error.InvalidArgument;
        var total: usize = 0;
        while (total < src.len) {
            const wrote = try pwrite(file, offset + total, src[total..]);
            if (wrote == 0) return error.IoError;
            total += wrote;
        }
        return;
    }
    try (try file.file()).writePositionalAll(defaultIo(), src, offset);
}

pub fn pwritevAll(file: FileHandle, offset: u64, vecs: []const IoVec) !void {
    var at = offset;
    for (vecs) |vec| {
        try pwriteAll(file, at, vec.data);
        at = std.math.add(u64, at, vec.data.len) catch return error.InvalidArgument;
    }
}

pub fn len(file: FileHandle) !u64 {
    if (file.custom) |custom| {
        const ops = file.custom_ops orelse return error.InvalidArgument;
        var out: u64 = 0;
        try statusToError(ops.get_size(custom, &out));
        return out;
    }
    return (try file.file()).length(defaultIo());
}

pub fn setLen(file: FileHandle, new_len: u64) !void {
    if (!file.writable) return error.AccessDenied;
    if (file.custom) |custom| {
        const ops = file.custom_ops orelse return error.InvalidArgument;
        return statusToError(ops.set_size(custom, new_len));
    }
    try (try file.file()).setLength(defaultIo(), new_len);
}

pub fn preallocate(file: FileHandle, offset: u64, size: u64) !void {
    if (!file.writable) return error.AccessDenied;
    if (file.custom) |custom| {
        const ops = file.custom_ops orelse return error.InvalidArgument;
        if (ops.preallocate) |f| return statusToError(f(custom, offset, size));
    }
    const end = try std.math.add(u64, offset, size);
    if (try len(file) < end) {
        try setLen(file, end);
    }
}

/// Data-only flush where the platform backend can provide it. Zig's portable
/// Io abstraction currently exposes a conservative file sync; callers that
/// need durable file length after extension should call flushMetadata as well.
pub fn flushData(file: FileHandle) !void {
    if (!file.writable) return error.AccessDenied;
    if (file.custom) |custom| {
        const ops = file.custom_ops orelse return error.InvalidArgument;
        return statusToError(ops.sync(custom, SYNC_DATA));
    }
    try (try file.file()).sync(defaultIo());
}

/// Metadata-inclusive flush. This is intentionally at least as strong as
/// flushData so DB sync paths have a portable way to make extended length
/// durable before publishing dependent metadata.
pub fn flushMetadata(file: FileHandle) !void {
    if (!file.writable) return error.AccessDenied;
    if (file.custom) |custom| {
        const ops = file.custom_ops orelse return error.InvalidArgument;
        return statusToError(ops.sync(custom, SYNC_METADATA));
    }
    try (try file.file()).sync(defaultIo());
}

pub fn advise(file: FileHandle, offset: u64, size: u64, advice: Advice) void {
    _ = file;
    _ = offset;
    _ = size;
    _ = advice;
    // Advisory hints are best-effort. Unsupported platforms must not make
    // normal DB IO fail, so the portable baseline is a no-op.
}

pub fn mmapReadonly(file: FileHandle, offset: u64, size: u64) !MappedRegion {
    if (file.custom) |custom| return mmapCustom(file, custom, offset, size, 0);
    const map_len = std.math.cast(usize, size) orelse return error.InvalidArgument;
    var map = try (try file.file()).createMemoryMap(defaultIo(), .{
        .len = map_len,
        .offset = offset,
        .protection = .{ .read = true, .write = false, .execute = false },
    });
    try map.read(defaultIo());
    return .{ .map = map };
}

pub fn mmapReadWrite(file: FileHandle, offset: u64, size: u64) !MappedRegion {
    if (!file.writable) return error.AccessDenied;
    if (file.custom) |custom| return mmapCustom(file, custom, offset, size, MMAP_FLAG_WRITE);
    const map_len = std.math.cast(usize, size) orelse return error.InvalidArgument;
    var map = try (try file.file()).createMemoryMap(defaultIo(), .{
        .len = map_len,
        .offset = offset,
        .protection = .{ .read = true, .write = true, .execute = false },
    });
    try map.read(defaultIo());
    return .{ .map = map, .writable = true };
}

fn mmapCustom(file: FileHandle, custom: *anyopaque, offset: u64, size: u64, flags: u32) !MappedRegion {
    const ops = file.custom_ops orelse return error.InvalidArgument;
    const mmap_fn = ops.mmap orelse return error.Unsupported;
    const unmap_fn = ops.munmap orelse return error.Unsupported;
    const writable = (flags & MMAP_FLAG_WRITE) != 0;
    if (writable and ops.msync == null) return error.Unsupported;
    const requested = std.math.cast(usize, size) orelse return error.InvalidArgument;
    _ = std.math.add(u64, offset, size) catch return error.InvalidArgument;
    var mapping: ?*anyopaque = null;
    var data: ?*anyopaque = null;
    var data_len: u64 = 0;
    const status = mmap_fn(custom, offset, size, flags, &mapping, &data, &data_len);
    const handle = mapping orelse data;
    errdefer if (handle) |h| {
        _ = unmap_fn(h);
    };
    try statusToError(status);
    // Providers may map a larger region, but the caller's view is exactly the
    // requested range. Never manufacture a slice from a short/null mapping.
    if (data_len < size) return error.IoError;
    const ptr = data orelse return error.IoError;
    const address = @intFromPtr(ptr);
    _ = std.math.add(usize, address, requested) catch return error.IoError;
    return .{ .custom_mapping = handle, .custom_ops = ops, .custom_bytes = @as([*]u8, @ptrCast(ptr))[0..requested], .writable = writable };
}

pub fn msync(region: *MappedRegion) !void {
    if (!region.writable) return error.AccessDenied;
    if (region.map) |*map| return map.write(defaultIo());
    const ops = region.custom_ops orelse return error.InvalidArgument;
    const f = ops.msync orelse return error.Unsupported;
    try statusToError(f(region.custom_mapping orelse return error.InvalidArgument, 0, region.custom_bytes.len, SYNC_METADATA));
}

pub fn munmap(region: *MappedRegion) void {
    if (region.map) |*map| {
        map.destroy(defaultIo());
    } else if (region.custom_mapping) |mapping| {
        if (region.custom_ops) |ops| {
            if (ops.munmap) |f| _ = f(mapping);
        }
    }
    region.* = undefined;
}

pub fn statusToError(status: c_int) !void {
    return switch (status) {
        0 => {},
        1 => error.FileNotFound,
        2 => error.InvalidArgument,
        3 => error.IoError,
        4, 5 => error.Corruption,
        6 => error.UnsupportedVersion,
        7 => error.Busy,
        8 => error.NoSpace,
        9 => error.AccessDenied,
        10 => error.Unsupported,
        else => error.IoError,
    };
}

test "platform offset IO, vectored write, truncate, mmap, advice, durable reopen" {
    const testing = std.testing;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var fh = try openAt(tmp.dir, "platform_io.bin", .{ .mode = .create_read_write });
    defer close(&fh);

    try pwriteAll(fh, 0, "abc");
    try pwriteAll(fh, 4096, "xyz");

    var a: [3]u8 = undefined;
    var b: [3]u8 = undefined;
    try testing.expectEqual(@as(usize, 3), try preadAll(fh, 0, &a));
    try testing.expectEqualStrings("abc", &a);
    try testing.expectEqual(@as(usize, 3), try preadAll(fh, 4096, &b));
    try testing.expectEqualStrings("xyz", &b);
    try testing.expect((try len(fh)) >= 4099);

    try pwritevAll(fh, 8192, &.{
        .{ .data = "head" },
        .{ .data = "payload" },
        .{ .data = "foot" },
    });
    var joined: [15]u8 = undefined;
    try testing.expectEqual(@as(usize, joined.len), try preadAll(fh, 8192, &joined));
    try testing.expectEqualStrings("headpayloadfoot", &joined);

    try setLen(fh, 5);
    var after_truncate: [8]u8 = undefined;
    try testing.expectEqual(@as(usize, 0), try pread(fh, 4096, &after_truncate));

    try setLen(fh, 4096);
    try pwriteAll(fh, 0, "abcdef");

    var ro = try mmapReadonly(fh, 0, 6);
    defer munmap(&ro);
    try testing.expectEqualStrings("abcdef", ro.bytesConst());

    var rw = try mmapReadWrite(fh, 0, 6);
    rw.bytes()[1] = 'Z';
    try msync(&rw);
    munmap(&rw);

    var mapped_back: [6]u8 = undefined;
    try testing.expectEqual(@as(usize, 6), try preadAll(fh, 0, &mapped_back));
    try testing.expectEqualStrings("aZcdef", &mapped_back);

    advise(fh, 0, 4096, .random);

    try pwriteAll(fh, 16384, "durable");
    try flushData(fh);
    try flushMetadata(fh);
    const durable_len = try len(fh);
    close(&fh);

    var reopened = try openAt(tmp.dir, "platform_io.bin", .{ .mode = .read_write });
    defer close(&reopened);
    try testing.expectEqual(durable_len, try len(reopened));
    var durable: [7]u8 = undefined;
    try testing.expectEqual(@as(usize, durable.len), try preadAll(reopened, 16384, &durable));
    try testing.expectEqualStrings("durable", &durable);
}

test "platform concurrent pread shares one file handle" {
    const testing = std.testing;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var fh = try openAt(tmp.dir, "concurrent.bin", .{ .mode = .create_read_write });
    defer close(&fh);
    try pwriteAll(fh, 0, "AAAAAAAA");
    try pwriteAll(fh, 4096, "BBBBBBBB");
    try flushMetadata(fh);

    const Ctx = struct {
        fh: FileHandle,
        errors: *[4]u32,

        fn reader(ctx: *@This(), id: usize) void {
            var i: usize = 0;
            while (i < 64) : (i += 1) {
                var buf: [8]u8 = undefined;
                const off: u64 = if (id % 2 == 0) 0 else 4096;
                const n = preadAll(ctx.fh, off, &buf) catch {
                    ctx.errors[id] = 1;
                    return;
                };
                if (n != 8) {
                    ctx.errors[id] = 2;
                    return;
                }
                const expect: []const u8 = if (id % 2 == 0) "AAAAAAAA" else "BBBBBBBB";
                if (!std.mem.eql(u8, &buf, expect)) {
                    ctx.errors[id] = 3;
                    return;
                }
            }
        }
    };

    var errors = [_]u32{0} ** 4;
    var ctx = Ctx{ .fh = fh, .errors = &errors };
    var threads: [4]std.Thread = undefined;
    for (&threads, 0..) |*thread, i| thread.* = try std.Thread.spawn(.{}, Ctx.reader, .{ &ctx, i });
    for (&threads) |*thread| thread.join();
    for (errors) |err| try testing.expectEqual(@as(u32, 0), err);
}

test "opaque callback conversion validates target function alignment" {
    // Explicit alignment exercises the Arm64 requirement on x86 hosts too.
    const AlignedFn = *align(4) const fn () callconv(.c) void;
    try std.testing.expectError(error.InvalidArgument, rawCallback(AlignedFn, null));
    try std.testing.expectError(error.InvalidArgument, rawCallback(AlignedFn, @ptrFromInt(0x1001)));
    const aligned = try rawCallback(AlignedFn, @ptrFromInt(0x1000));
    try std.testing.expectEqual(@as(usize, 0x1000), @intFromPtr(aligned));
}

const CallbackProbe = struct {
    bytes: [32]u8 = [_]u8{0} ** 32,
    size: usize = 0,
    max_transfer: usize = 3,
    oversize_count: bool = false,
    zero_write: bool = false,
    short_mapping: bool = false,
    null_mapping_data: bool = false,
    unmaps: usize = 0,
    writes: usize = 0,

    fn ops(self: *CallbackProbe) CustomFileOps {
        return .{ .user_data = self, .open = openFn, .close = closeFn, .read_at = readFn, .write_at = writeFn, .get_size = sizeFn, .set_size = resizeFn, .sync = syncFn, .preallocate = null, .mmap = mapFn, .msync = null, .munmap = unmapFn };
    }

    fn from(handle: ?*anyopaque) *CallbackProbe {
        return @ptrCast(@alignCast(handle.?));
    }

    fn openFn(user: ?*anyopaque, _: [*]const u8, _: u64, _: u32, out: *?*anyopaque) callconv(.c) c_int {
        out.* = user;
        return 0;
    }

    fn closeFn(_: ?*anyopaque) callconv(.c) c_int {
        return 0;
    }

    fn readFn(handle: ?*anyopaque, offset: u64, dst: ?*anyopaque, count: u64, out: *u64) callconv(.c) c_int {
        const self = from(handle);
        if (self.oversize_count) {
            out.* = count + 1;
            return 0;
        }
        if (offset >= self.size) {
            out.* = 0;
            return 0;
        }
        const n = @min(count, self.max_transfer, self.size - @as(usize, @intCast(offset)));
        @memcpy(@as([*]u8, @ptrCast(dst.?))[0..n], self.bytes[@intCast(offset)..][0..n]);
        out.* = n;
        return 0;
    }

    fn writeFn(handle: ?*anyopaque, offset: u64, src: ?*const anyopaque, count: u64, out: *u64) callconv(.c) c_int {
        const self = from(handle);
        self.writes += 1;
        if (self.oversize_count or self.zero_write) {
            out.* = if (self.zero_write) 0 else count + 1;
            return 0;
        }
        if (offset >= self.bytes.len) return 8;
        const n = @min(count, self.max_transfer, self.bytes.len - @as(usize, @intCast(offset)));
        @memcpy(self.bytes[@intCast(offset)..][0..n], @as([*]const u8, @ptrCast(src.?))[0..n]);
        self.size = @max(self.size, @as(usize, @intCast(offset)) + @as(usize, @intCast(n)));
        out.* = n;
        return 0;
    }

    fn sizeFn(handle: ?*anyopaque, out: *u64) callconv(.c) c_int {
        out.* = from(handle).size;
        return 0;
    }

    fn resizeFn(handle: ?*anyopaque, size: u64) callconv(.c) c_int {
        if (size > from(handle).bytes.len) return 8;
        from(handle).size = @intCast(size);
        return 0;
    }

    fn syncFn(_: ?*anyopaque, _: u32) callconv(.c) c_int {
        return 10;
    }

    fn mapFn(handle: ?*anyopaque, offset: u64, size: u64, _: u32, mapping: *?*anyopaque, data: *?*anyopaque, out: *u64) callconv(.c) c_int {
        const self = from(handle);
        if (offset > self.bytes.len or size > self.bytes.len - offset) return 2;
        mapping.* = self;
        data.* = if (self.null_mapping_data) null else self.bytes[@intCast(offset)..].ptr;
        out.* = if (self.short_mapping) size - 1 else size;
        return 0;
    }

    fn unmapFn(handle: ?*anyopaque) callconv(.c) c_int {
        from(handle).unmaps += 1;
        return 0;
    }
};

test "custom positional IO loops short transfers and validates provider counts" {
    var probe = CallbackProbe{};
    var file = try openIn(.fromCustom("opaque://root/../pack", probe.ops()), "leaf", .{ .mode = .read_write });
    defer close(&file);
    try pwriteAll(file, 0, "short-transfers");
    try std.testing.expect(probe.writes > 1);
    var out: [20]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 15), try preadAll(file, 0, &out));
    try std.testing.expectEqualStrings("short-transfers", out[0..15]);
    probe.oversize_count = true;
    try std.testing.expectError(error.IoError, preadAll(file, 0, &out));
    try std.testing.expectError(error.IoError, pwriteAll(file, 0, "bad"));
    probe.oversize_count = false;
    probe.zero_write = true;
    try std.testing.expectError(error.IoError, pwriteAll(file, 0, "zero"));
    try std.testing.expectError(error.InvalidArgument, preadAll(file, std.math.maxInt(u64), &out));
    try std.testing.expectError(error.InvalidArgument, pwriteAll(file, std.math.maxInt(u64), "overflow"));
}

test "custom readonly handles prevent mutations and require only read mapping capabilities" {
    var probe = CallbackProbe{};
    var file = try openIn(.fromCustom("root", probe.ops()), "leaf", .{ .mode = .read_only });
    defer close(&file);
    try std.testing.expectError(error.AccessDenied, pwrite(file, 0, "x"));
    try std.testing.expectError(error.AccessDenied, pwriteAll(file, 0, "x"));
    try std.testing.expectError(error.AccessDenied, setLen(file, 1));
    try std.testing.expectError(error.AccessDenied, preallocate(file, 0, 1));
    try std.testing.expectError(error.AccessDenied, mmapReadWrite(file, 0, 1));
    try std.testing.expectError(error.AccessDenied, flushData(file));
    try std.testing.expectError(error.AccessDenied, flushMetadata(file));
    var mapping = try mmapReadonly(file, 0, 1);
    try std.testing.expectError(error.AccessDenied, msync(&mapping));
    munmap(&mapping);
    try std.testing.expectEqual(@as(usize, 1), probe.unmaps);
    try std.testing.expectEqual(@as(usize, 0), probe.writes);
    file.custom_ops.?.mmap = null;
    try std.testing.expectError(error.Unsupported, mmapReadonly(file, 0, 1));
}

test "custom malformed mappings release provider resources" {
    var probe = CallbackProbe{ .short_mapping = true };
    var file = try openIn(.fromCustom("root", probe.ops()), "leaf", .{ .mode = .read_write });
    defer close(&file);
    try std.testing.expectError(error.IoError, mmapReadonly(file, 0, 4));
    probe.short_mapping = false;
    probe.null_mapping_data = true;
    try std.testing.expectError(error.IoError, mmapReadonly(file, 0, 4));
    try std.testing.expectEqual(@as(usize, 2), probe.unmaps);
    try std.testing.expectError(error.Unsupported, mmapReadWrite(file, 0, 4));
    file.custom_ops.?.munmap = null;
    try std.testing.expectError(error.Unsupported, mmapReadonly(file, 0, 4));
}
