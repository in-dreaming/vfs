const std = @import("std");
const builtin = @import("builtin");

const Io = std.Io;
const Dir = std.Io.Dir;
const File = std.Io.File;

fn defaultIo() Io {
    return std.Io.Threaded.global_single_threaded.io();
}

pub const FileHandle = struct {
    native: ?File,
    writable: bool = false,

    fn file(self: FileHandle) !File {
        return self.native orelse error.InvalidArgument;
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
    map: File.MemoryMap,

    pub fn bytes(self: *MappedRegion) []u8 {
        return self.map.memory;
    }

    pub fn bytesConst(self: *const MappedRegion) []const u8 {
        return self.map.memory;
    }

    pub fn ptr(self: *MappedRegion) [*]u8 {
        return self.map.memory.ptr;
    }

    pub fn len(self: *const MappedRegion) usize {
        return self.map.memory.len;
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
    const io = defaultIo();
    _ = options.random_access_hint;
    _ = options.sequential_hint;
    _ = options.direct_io;
    const file = switch (options.mode) {
        .read_only => try dir.openFile(io, path, .{
            .mode = .read_only,
            .allow_directory = false,
        }),
        .read_write => try dir.openFile(io, path, .{
            .mode = .read_write,
            .allow_directory = false,
        }),
        .create_read_write => try dir.createFile(io, path, .{
            .read = true,
            .truncate = false,
        }),
    };
    return .{ .native = file, .writable = options.mode != .read_only };
}

pub fn close(file: *FileHandle) void {
    if (file.native) |native| {
        native.close(defaultIo());
        file.native = null;
    }
}

pub fn pread(file: FileHandle, offset: u64, dst: []u8) !usize {
    return (try file.file()).readPositional(defaultIo(), &.{dst}, offset);
}

pub fn preadAll(file: FileHandle, offset: u64, dst: []u8) !usize {
    return (try file.file()).readPositionalAll(defaultIo(), dst, offset);
}

pub fn pwrite(file: FileHandle, offset: u64, src: []const u8) !usize {
    return (try file.file()).writePositional(defaultIo(), &.{src}, offset);
}

pub fn pwriteAll(file: FileHandle, offset: u64, src: []const u8) !void {
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
    return (try file.file()).length(defaultIo());
}

pub fn setLen(file: FileHandle, new_len: u64) !void {
    try (try file.file()).setLength(defaultIo(), new_len);
}

pub fn preallocate(file: FileHandle, offset: u64, size: u64) !void {
    const end = try std.math.add(u64, offset, size);
    if (try len(file) < end) {
        try setLen(file, end);
    }
}

/// Data-only flush where the platform backend can provide it. Zig's portable
/// Io abstraction currently exposes a conservative file sync; callers that
/// need durable file length after extension should call flushMetadata as well.
pub fn flushData(file: FileHandle) !void {
    try (try file.file()).sync(defaultIo());
}

/// Metadata-inclusive flush. This is intentionally at least as strong as
/// flushData so DB sync paths have a portable way to make extended length
/// durable before publishing dependent metadata.
pub fn flushMetadata(file: FileHandle) !void {
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
    const map_len = std.math.cast(usize, size) orelse return error.InvalidArgument;
    var map = try (try file.file()).createMemoryMap(defaultIo(), .{
        .len = map_len,
        .offset = offset,
        .protection = .{ .read = true, .write = true, .execute = false },
    });
    try map.read(defaultIo());
    return .{ .map = map };
}

pub fn msync(region: *MappedRegion) !void {
    try region.map.write(defaultIo());
}

pub fn munmap(region: *MappedRegion) void {
    region.map.destroy(defaultIo());
    region.* = undefined;
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
