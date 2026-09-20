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

pub fn customOpsFromRaw(raw: *const RawFileOps) !CustomFileOps {
    if (raw.struct_size < @offsetOf(RawFileOps, "munmap") + @sizeOf(?*const anyopaque)) return error.InvalidArgument;
    if (raw.version != 1) return error.UnsupportedVersion;
    return .{
        .user_data = raw.user_data,
        .open = @ptrCast(raw.open orelse return error.InvalidArgument),
        .close = @ptrCast(raw.close orelse return error.InvalidArgument),
        .read_at = @ptrCast(raw.read_at orelse return error.InvalidArgument),
        .write_at = @ptrCast(raw.write_at orelse return error.InvalidArgument),
        .get_size = @ptrCast(raw.get_size orelse return error.InvalidArgument),
        .set_size = @ptrCast(raw.set_size orelse return error.InvalidArgument),
        .sync = @ptrCast(raw.sync orelse return error.InvalidArgument),
        .preallocate = if (raw.preallocate) |p| @ptrCast(p) else null,
        .mmap = if (raw.mmap) |p| @ptrCast(p) else null,
        .msync = if (raw.msync) |p| @ptrCast(p) else null,
        .munmap = if (raw.munmap) |p| @ptrCast(p) else null,
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
        try std.fs.path.join(std.heap.smp_allocator, &.{ root, path });
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
    try statusToError(ops.open(ops.user_data, joined.ptr, joined.len, flags, &out_file));
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
        const ops = file.custom_ops orelse return error.InvalidArgument;
        var got: u64 = 0;
        try statusToError(ops.read_at(custom, offset, dst.ptr, dst.len, &got));
        return std.math.cast(usize, got) orelse error.InvalidArgument;
    }
    return (try file.file()).readPositional(defaultIo(), &.{dst}, offset);
}

pub fn preadAll(file: FileHandle, offset: u64, dst: []u8) !usize {
    if (file.custom != null) {
        return pread(file, offset, dst);
    }
    return (try file.file()).readPositionalAll(defaultIo(), dst, offset);
}

pub fn pwrite(file: FileHandle, offset: u64, src: []const u8) !usize {
    if (file.custom) |custom| {
        const ops = file.custom_ops orelse return error.InvalidArgument;
        var wrote: u64 = 0;
        try statusToError(ops.write_at(custom, offset, src.ptr, src.len, &wrote));
        return std.math.cast(usize, wrote) orelse error.InvalidArgument;
    }
    return (try file.file()).writePositional(defaultIo(), &.{src}, offset);
}

pub fn pwriteAll(file: FileHandle, offset: u64, src: []const u8) !void {
    if (file.custom != null) {
        const wrote = try pwrite(file, offset, src);
        if (wrote != src.len) return error.IoError;
        return;
    }
    try (try file.file()).writePositionalAll(defaultIo(), src, offset);
}

pub fn pwritevAll(file: FileHandle, offset: u64, vecs: []const IoVec) !void {
    var at = offset;
    for (vecs) |vec| {
        try pwriteAll(file, at, vec.data);
        at += vec.data.len;
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
    if (file.custom) |custom| {
        const ops = file.custom_ops orelse return error.InvalidArgument;
        return statusToError(ops.set_size(custom, new_len));
    }
    try (try file.file()).setLength(defaultIo(), new_len);
}

pub fn preallocate(file: FileHandle, offset: u64, size: u64) !void {
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
    if (file.custom) |custom| return mmapCustom(file, custom, offset, size, MMAP_FLAG_WRITE);
    const map_len = std.math.cast(usize, size) orelse return error.InvalidArgument;
    var map = try (try file.file()).createMemoryMap(defaultIo(), .{
        .len = map_len,
        .offset = offset,
        .protection = .{ .read = true, .write = true, .execute = false },
    });
    try map.read(defaultIo());
    return .{ .map = map };
}

fn mmapCustom(file: FileHandle, custom: *anyopaque, offset: u64, size: u64, flags: u32) !MappedRegion {
    const ops = file.custom_ops orelse return error.InvalidArgument;
    const mmap_fn = ops.mmap orelse return error.Unsupported;
    if (ops.msync == null or ops.munmap == null) return error.Unsupported;
    var mapping: ?*anyopaque = null;
    var data: ?*anyopaque = null;
    var data_len: u64 = 0;
    try statusToError(mmap_fn(custom, offset, size, flags, &mapping, &data, &data_len));
    const n = std.math.cast(usize, data_len) orelse return error.InvalidArgument;
    const ptr = data orelse return error.IoError;
    return .{ .custom_mapping = mapping orelse ptr, .custom_ops = ops, .custom_bytes = @as([*]u8, @ptrCast(ptr))[0..n] };
}

pub fn msync(region: *MappedRegion) !void {
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
