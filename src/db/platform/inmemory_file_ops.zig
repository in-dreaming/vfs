const std = @import("std");
const pf = @import("file.zig");

const DB_OK: c_int = 0;
const DB_NOT_FOUND: c_int = 1;
const DB_INVALID_ARGUMENT: c_int = 2;
const DB_IO_ERROR: c_int = 3;
const DB_BUSY: c_int = 7;
const DB_NO_SPACE: c_int = 8;
const DB_UNSUPPORTED: c_int = 10;

const MemFile = struct {
    fs: *FileSystem,
    path: []u8,
    data: std.ArrayList(u8) = .empty,
    dirty: bool = false,
    mapped_count: u32 = 0,

    fn deinit(self: *MemFile, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
        self.data.deinit(allocator);
        allocator.destroy(self);
    }
};

const Mapping = struct {
    file: *MemFile,
};

pub const FileSystem = struct {
    allocator: std.mem.Allocator,
    writeback: bool = true,
    files: std.StringHashMapUnmanaged(*MemFile) = .empty,
    lock: std.atomic.Mutex = .unlocked,

    pub fn init(allocator: std.mem.Allocator, writeback: bool) FileSystem {
        return .{ .allocator = allocator, .writeback = writeback };
    }

    pub fn deinit(self: *FileSystem) void {
        var it = self.files.iterator();
        while (it.next()) |entry| entry.value_ptr.*.deinit(self.allocator);
        self.files.deinit(self.allocator);
    }

    pub fn rawOps(self: *FileSystem) pf.RawFileOps {
        return .{
            .struct_size = @sizeOf(pf.RawFileOps),
            .version = 1,
            .user_data = self,
            .open = @ptrCast(&open),
            .close = @ptrCast(&close),
            .read_at = @ptrCast(&readAt),
            .write_at = @ptrCast(&writeAt),
            .get_size = @ptrCast(&getSize),
            .set_size = @ptrCast(&setSize),
            .sync = @ptrCast(&sync),
            .preallocate = @ptrCast(&preallocate),
            .mmap = @ptrCast(&mmap),
            .msync = @ptrCast(&msync),
            .munmap = @ptrCast(&munmap),
        };
    }

    fn getOrLoad(self: *FileSystem, path: []const u8, create: bool) !*MemFile {
        if (self.files.get(path)) |file| return file;

        const owned_path = try self.allocator.dupe(u8, path);
        errdefer self.allocator.free(owned_path);
        const file = try self.allocator.create(MemFile);
        errdefer self.allocator.destroy(file);
        file.* = .{ .fs = self, .path = owned_path };

        const io = std.Io.Threaded.global_single_threaded.io();
        if (std.Io.Dir.cwd().openFile(io, path, .{ .mode = .read_only, .allow_directory = false })) |disk| {
            defer disk.close(io);
            const size_u64 = try disk.length(io);
            const size = std.math.cast(usize, size_u64) orelse return error.NoSpace;
            try file.data.resize(self.allocator, size);
            if (size != 0) {
                const n = try disk.readPositionalAll(io, file.data.items, 0);
                if (n != size) return error.IoError;
            }
        } else |err| switch (err) {
            error.FileNotFound => if (!create) return error.FileNotFound,
            else => return err,
        }

        try self.files.put(self.allocator, file.path, file);
        return file;
    }

    fn flushFile(self: *FileSystem, file: *MemFile) !void {
        if (!self.writeback or !file.dirty) return;
        const io = std.Io.Threaded.global_single_threaded.io();
        if (std.fs.path.dirname(file.path)) |parent| {
            if (parent.len != 0) try std.Io.Dir.cwd().createDirPath(io, parent);
        }
        var disk = try std.Io.Dir.cwd().createFile(io, file.path, .{ .read = true, .truncate = true });
        errdefer disk.close(io);
        if (file.data.items.len != 0) try disk.writePositionalAll(io, file.data.items, 0);
        try disk.setLength(io, file.data.items.len);
        try disk.sync(io);
        disk.close(io);
        file.dirty = false;
    }
};

fn statusFromError(err: anyerror) c_int {
    return switch (err) {
        error.FileNotFound => DB_NOT_FOUND,
        error.InvalidArgument => DB_INVALID_ARGUMENT,
        error.Busy => DB_BUSY,
        error.NoSpace, error.OutOfMemory => DB_NO_SPACE,
        error.Unsupported => DB_UNSUPPORTED,
        else => DB_IO_ERROR,
    };
}

fn fsFromUser(user: ?*anyopaque) !*FileSystem {
    return @ptrCast(@alignCast(user orelse return error.InvalidArgument));
}

fn fileFromHandle(handle: ?*anyopaque) !*MemFile {
    return @ptrCast(@alignCast(handle orelse return error.InvalidArgument));
}

fn open(user: ?*anyopaque, path_ptr: [*]const u8, path_len: u64, flags: u32, out_file: *?*anyopaque) callconv(.c) c_int {
    const fs = fsFromUser(user) catch |err| return statusFromError(err);
    const n = std.math.cast(usize, path_len) orelse return DB_INVALID_ARGUMENT;
    const path = path_ptr[0..n];
    const create = (flags & pf.OPEN_FLAG_CREATE) != 0;
    while (!fs.lock.tryLock()) std.atomic.spinLoopHint();
    defer fs.lock.unlock();
    const file = fs.getOrLoad(path, create) catch |err| return statusFromError(err);
    out_file.* = file;
    return DB_OK;
}

fn close(handle: ?*anyopaque) callconv(.c) c_int {
    _ = fileFromHandle(handle) catch |err| return statusFromError(err);
    return DB_OK;
}

fn readAt(handle: ?*anyopaque, offset: u64, dst_ptr: ?*anyopaque, size: u64, out_read: *u64) callconv(.c) c_int {
    const file = fileFromHandle(handle) catch |err| return statusFromError(err);
    const dst_len = std.math.cast(usize, size) orelse return DB_INVALID_ARGUMENT;
    const dst_raw = dst_ptr orelse return DB_INVALID_ARGUMENT;
    const dst = @as([*]u8, @ptrCast(dst_raw))[0..dst_len];
    while (!file.fs.lock.tryLock()) std.atomic.spinLoopHint();
    defer file.fs.lock.unlock();
    const off = std.math.cast(usize, offset) orelse return DB_INVALID_ARGUMENT;
    if (off >= file.data.items.len) {
        out_read.* = 0;
        return DB_OK;
    }
    const n = @min(dst.len, file.data.items.len - off);
    @memcpy(dst[0..n], file.data.items[off..][0..n]);
    out_read.* = n;
    return DB_OK;
}

fn writeAt(handle: ?*anyopaque, offset: u64, src_ptr: ?*const anyopaque, size: u64, out_written: *u64) callconv(.c) c_int {
    const file = fileFromHandle(handle) catch |err| return statusFromError(err);
    const src_len = std.math.cast(usize, size) orelse return DB_INVALID_ARGUMENT;
    const src_raw = src_ptr orelse return DB_INVALID_ARGUMENT;
    const src = @as([*]const u8, @ptrCast(src_raw))[0..src_len];
    while (!file.fs.lock.tryLock()) std.atomic.spinLoopHint();
    defer file.fs.lock.unlock();
    const off = std.math.cast(usize, offset) orelse return DB_INVALID_ARGUMENT;
    const end = off + src.len;
    if (end > file.data.items.len) {
        if (file.mapped_count != 0) return DB_BUSY;
        file.data.resize(file.fs.allocator, end) catch |err| return statusFromError(err);
    }
    @memmove(file.data.items[off..end], src);
    file.dirty = true;
    out_written.* = src.len;
    return DB_OK;
}

fn getSize(handle: ?*anyopaque, out_size: *u64) callconv(.c) c_int {
    const file = fileFromHandle(handle) catch |err| return statusFromError(err);
    while (!file.fs.lock.tryLock()) std.atomic.spinLoopHint();
    defer file.fs.lock.unlock();
    out_size.* = file.data.items.len;
    return DB_OK;
}

fn setSize(handle: ?*anyopaque, size: u64) callconv(.c) c_int {
    const file = fileFromHandle(handle) catch |err| return statusFromError(err);
    const n = std.math.cast(usize, size) orelse return DB_INVALID_ARGUMENT;
    while (!file.fs.lock.tryLock()) std.atomic.spinLoopHint();
    defer file.fs.lock.unlock();
    if (file.mapped_count != 0 and n != file.data.items.len) return DB_BUSY;
    file.data.resize(file.fs.allocator, n) catch |err| return statusFromError(err);
    file.dirty = true;
    return DB_OK;
}

fn sync(handle: ?*anyopaque, mode: u32) callconv(.c) c_int {
    _ = mode;
    const file = fileFromHandle(handle) catch |err| return statusFromError(err);
    while (!file.fs.lock.tryLock()) std.atomic.spinLoopHint();
    defer file.fs.lock.unlock();
    file.fs.flushFile(file) catch |err| return statusFromError(err);
    return DB_OK;
}

fn preallocate(handle: ?*anyopaque, offset: u64, size: u64) callconv(.c) c_int {
    const file = fileFromHandle(handle) catch |err| return statusFromError(err);
    const end_u64 = std.math.add(u64, offset, size) catch return DB_INVALID_ARGUMENT;
    const end = std.math.cast(usize, end_u64) orelse return DB_INVALID_ARGUMENT;
    while (!file.fs.lock.tryLock()) std.atomic.spinLoopHint();
    defer file.fs.lock.unlock();
    if (end > file.data.items.len) {
        if (file.mapped_count != 0) return DB_BUSY;
        file.data.resize(file.fs.allocator, end) catch |err| return statusFromError(err);
        file.dirty = true;
    }
    return DB_OK;
}

fn mmap(handle: ?*anyopaque, offset: u64, size: u64, flags: u32, out_mapping: *?*anyopaque, out_data: *?*anyopaque, out_size: *u64) callconv(.c) c_int {
    _ = flags;
    const file = fileFromHandle(handle) catch |err| return statusFromError(err);
    const off = std.math.cast(usize, offset) orelse return DB_INVALID_ARGUMENT;
    const n = std.math.cast(usize, size) orelse return DB_INVALID_ARGUMENT;
    while (!file.fs.lock.tryLock()) std.atomic.spinLoopHint();
    defer file.fs.lock.unlock();
    const end = off + n;
    if (end > file.data.items.len) return DB_INVALID_ARGUMENT;
    const mapping = file.fs.allocator.create(Mapping) catch |err| return statusFromError(err);
    mapping.* = .{ .file = file };
    file.mapped_count += 1;
    out_mapping.* = mapping;
    out_data.* = file.data.items[off..end].ptr;
    out_size.* = n;
    return DB_OK;
}

fn msync(mapping_handle: ?*anyopaque, offset: u64, size: u64, mode: u32) callconv(.c) c_int {
    _ = offset;
    _ = size;
    _ = mode;
    const mapping: *Mapping = @ptrCast(@alignCast(mapping_handle orelse return DB_INVALID_ARGUMENT));
    mapping.file.dirty = true;
    return sync(mapping.file, pf.SYNC_METADATA);
}

fn munmap(mapping_handle: ?*anyopaque) callconv(.c) c_int {
    const mapping: *Mapping = @ptrCast(@alignCast(mapping_handle orelse return DB_INVALID_ARGUMENT));
    const file = mapping.file;
    while (!file.fs.lock.tryLock()) std.atomic.spinLoopHint();
    defer file.fs.lock.unlock();
    if (file.mapped_count > 0) file.mapped_count -= 1;
    file.fs.allocator.destroy(mapping);
    return DB_OK;
}
