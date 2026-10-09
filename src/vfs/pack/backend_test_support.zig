//! Test-only read-only provider around the existing DB in-memory backend. It
//! rejects every write capability and tracks resources across failed opens.
const std = @import("std");
const db = @import("db_internal");
const pf = db.platform.file;

pub const ReadOnlyBackend = struct {
    memory: db.platform.inmemory_file_ops.FileSystem,
    allocator: std.mem.Allocator,
    open_count: usize = 0,
    close_count: usize = 0,
    live_handles: usize = 0,
    live_mappings: usize = 0,
    mutation_count: usize = 0,
    read_count: usize = 0,
    record_read_count: usize = 0,
    max_read: u64 = 17,
    fail_open: bool = false,
    fail_open_after: ?usize = null,
    fail_read: bool = false,

    const Handle = struct { owner: *ReadOnlyBackend, inner: ?*anyopaque, is_data: bool };
    const Mapping = struct { owner: *ReadOnlyBackend, inner: ?*anyopaque };

    pub fn init(allocator: std.mem.Allocator) ReadOnlyBackend {
        return .{ .memory = .init(allocator, false), .allocator = allocator };
    }

    pub fn deinit(self: *ReadOnlyBackend) void {
        std.debug.assert(self.live_handles == 0 and self.live_mappings == 0);
        self.memory.deinit();
    }

    pub fn memoryOps(self: *ReadOnlyBackend) pf.CustomFileOps {
        const raw = self.memory.rawOps();
        return pf.customOpsFromRaw(&raw) catch unreachable;
    }

    /// Copy a closed filesystem pack into an arbitrary opaque provider root.
    /// Further reads do not depend on the source directory.
    pub fn importPack(self: *ReadOnlyBackend, source: []const u8, root: []const u8) !void {
        const io = std.Io.Threaded.global_single_threaded.io();
        const dir = try std.Io.Dir.cwd().openDir(io, source, .{});
        defer dir.close(io);
        try self.importFile(dir, root, "manifest.db");
        try self.importFile(dir, root, "index.db");
        var shard: usize = 0;
        while (true) : (shard += 1) {
            var name_buf: [32]u8 = undefined;
            const name = try std.fmt.bufPrint(&name_buf, "data_{d:0>3}.db", .{shard});
            self.importFile(dir, root, name) catch |err| switch (err) {
                error.FileNotFound => if (shard != 0) break else return err,
                else => return err,
            };
        }
    }

    fn importFile(self: *ReadOnlyBackend, dir: std.Io.Dir, root: []const u8, name: []const u8) !void {
        var source = try pf.openAt(dir, name, .{ .mode = .read_only });
        defer pf.close(&source);
        const n = std.math.cast(usize, try pf.len(source)) orelse return error.NoSpace;
        const bytes = try self.allocator.alloc(u8, n);
        defer self.allocator.free(bytes);
        if (try pf.preadAll(source, 0, bytes) != n) return error.IoError;
        var target = try pf.openIn(.fromCustom(root, self.memoryOps()), name, .{ .mode = .create_read_write });
        defer pf.close(&target);
        try pf.pwriteAll(target, 0, bytes);
    }

    pub fn ops(self: *ReadOnlyBackend) pf.CustomFileOps {
        return .{ .user_data = self, .open = open, .close = close, .read_at = read, .write_at = write, .get_size = size, .set_size = resize, .sync = sync, .preallocate = null, .mmap = map, .msync = null, .munmap = unmap };
    }

    fn handle(raw: ?*anyopaque) *Handle {
        return @ptrCast(@alignCast(raw.?));
    }

    fn open(user: ?*anyopaque, path: [*]const u8, len: u64, flags: u32, out: *?*anyopaque) callconv(.c) c_int {
        const self: *ReadOnlyBackend = @ptrCast(@alignCast(user.?));
        if (flags != pf.OPEN_FLAG_READ_ONLY) {
            self.mutation_count += 1;
            return 9;
        }
        if (self.fail_open) return 3;
        if (self.fail_open_after) |limit| if (self.open_count >= limit) return 3;
        const h = self.allocator.create(Handle) catch return 8;
        const inner = self.memoryOps();
        var inner_handle: ?*anyopaque = null;
        const status = inner.open(inner.user_data, path, len, flags, &inner_handle);
        if (status != 0) {
            self.allocator.destroy(h);
            return status;
        }
        const path_bytes = path[0..@intCast(len)];
        const leaf_offset = if (std.mem.lastIndexOfScalar(u8, path_bytes, '/')) |slash| slash + 1 else 0;
        h.* = .{ .owner = self, .inner = inner_handle, .is_data = std.mem.startsWith(u8, path_bytes[leaf_offset..], "data_") };
        out.* = h;
        self.open_count += 1;
        self.live_handles += 1;
        return 0;
    }

    fn close(raw: ?*anyopaque) callconv(.c) c_int {
        const h = handle(raw);
        const self = h.owner;
        const result = self.memoryOps().close(h.inner);
        self.close_count += 1;
        self.live_handles -= 1;
        self.allocator.destroy(h);
        return result;
    }

    fn read(raw: ?*anyopaque, off: u64, dst: ?*anyopaque, count: u64, out: *u64) callconv(.c) c_int {
        const h = handle(raw);
        h.owner.read_count += 1;
        if (h.is_data and off >= 4096) h.owner.record_read_count += 1;
        if (h.owner.fail_read) return 3;
        return h.owner.memoryOps().read_at(h.inner, off, dst, @min(count, h.owner.max_read), out);
    }

    fn write(raw: ?*anyopaque, _: u64, _: ?*const anyopaque, _: u64, _: *u64) callconv(.c) c_int {
        handle(raw).owner.mutation_count += 1;
        return 10;
    }

    fn size(raw: ?*anyopaque, out: *u64) callconv(.c) c_int {
        const h = handle(raw);
        return h.owner.memoryOps().get_size(h.inner, out);
    }

    fn resize(raw: ?*anyopaque, _: u64) callconv(.c) c_int {
        handle(raw).owner.mutation_count += 1;
        return 10;
    }

    fn sync(raw: ?*anyopaque, _: u32) callconv(.c) c_int {
        handle(raw).owner.mutation_count += 1;
        return 10;
    }

    fn map(raw: ?*anyopaque, off: u64, count: u64, flags: u32, out_mapping: *?*anyopaque, out_data: *?*anyopaque, out_size: *u64) callconv(.c) c_int {
        const h = handle(raw);
        const self = h.owner;
        if (flags != 0) {
            self.mutation_count += 1;
            return 10;
        }
        const m = self.allocator.create(Mapping) catch return 8;
        var inner: ?*anyopaque = null;
        const result = self.memoryOps().mmap.?(h.inner, off, count, flags, &inner, out_data, out_size);
        if (result != 0) {
            self.allocator.destroy(m);
            return result;
        }
        m.* = .{ .owner = self, .inner = inner };
        out_mapping.* = m;
        self.live_mappings += 1;
        return 0;
    }

    fn unmap(raw: ?*anyopaque) callconv(.c) c_int {
        const m: *Mapping = @ptrCast(@alignCast(raw.?));
        const self = m.owner;
        const result = self.memoryOps().munmap.?(m.inner);
        self.live_mappings -= 1;
        self.allocator.destroy(m);
        return result;
    }
};
