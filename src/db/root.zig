const std = @import("std");

pub const format = @import("format.zig");
pub const batch_snapshot = @import("batch_snapshot.zig");
pub const kv_db = @import("kv_db.zig");
pub const manifest = @import("manifest.zig");
pub const recovery_verify = @import("recovery_verify.zig");

pub const data = struct {
    pub const allocator = @import("data/allocator.zig");
    pub const data_file = @import("data/data_file.zig");
    pub const relocation = @import("data/relocation.zig");
};

pub const index = struct {
    pub const base_index = @import("index/base_index.zig");
    pub const checkpoint = @import("index/checkpoint.zig");
    pub const delta_index = @import("index/delta_index.zig");
    pub const delta_journal = @import("index/delta_journal.zig");
    pub const index_file = @import("index/index_file.zig");
};

pub const platform = struct {
    pub const file = @import("platform/file.zig");
    pub const inmemory_file_ops = @import("platform/inmemory_file_ops.zig");
    pub const sync = @import("platform/sync.zig");
};

comptime {
    _ = batch_snapshot.db_batch_begin;
    _ = batch_snapshot.db_batch_put;
    _ = batch_snapshot.db_batch_delete;
    _ = batch_snapshot.db_batch_commit;
    _ = batch_snapshot.db_batch_rollback;
    _ = batch_snapshot.db_snapshot_begin;
    _ = batch_snapshot.db_snapshot_get_size;
    _ = batch_snapshot.db_snapshot_get_into;
    _ = batch_snapshot.db_snapshot_end;
}

pub export fn db_checkpoint(handle: u64, flags: u32) c_int {
    _ = flags;
    const retained = kv_db.acquireHandle(kv_db.KvDb, handle, .db) catch |err| return kv_db.setLastError(err);
    defer retained.release();
    const d = retained.ptr;
    if (d.dir.custom_ops != null) return kv_db.setLastStatus(.unsupported, "checkpoint with custom file_ops is not supported yet");
    d.checkpoint() catch |err| return kv_db.setLastError(err);
    return kv_db.setOk();
}

pub export fn db_commit(handle: u64, durability: u32) c_int {
    const retained = kv_db.acquireHandle(kv_db.KvDb, handle, .db) catch |err| return kv_db.setLastError(err);
    defer retained.release();
    const d = retained.ptr;
    const dur: format.Durability = switch (durability) {
        0 => .none,
        1 => .async,
        2 => .sync,
        else => .sync,
    };
    d.commitPending(dur) catch |err| return kv_db.setLastError(err);
    return kv_db.setOk();
}

pub export fn db_verify(handle: u64, flags: u32) c_int {
    _ = flags;
    const retained = kv_db.acquireHandle(kv_db.KvDb, handle, .db) catch |err| return kv_db.setLastError(err);
    defer retained.release();
    const d = retained.ptr;
    d.commitPending(null) catch |err| return kv_db.setLastError(err);
    var report = recovery_verify.verifyIn(d.dir, std.heap.smp_allocator) catch |err| return kv_db.setLastError(err);
    defer report.deinit();
    return if (report.ok()) kv_db.setOk() else kv_db.setLastStatus(.corruption, "verify failed");
}

pub export fn db_recover(path: [*:0]const u8, flags: u32, context: ?*const kv_db.db_context_t) c_int {
    _ = flags;
    if (context) |ctx| if (ctx.file_ops != null) return kv_db.setLastStatus(.unsupported, "custom file_ops are not supported by recover yet");
    const io = std.Io.Threaded.global_single_threaded.io();
    var dir = std.Io.Dir.openDir(std.Io.Dir.cwd(), io, std.mem.span(path), .{}) catch |err| return kv_db.setLastError(err);
    defer dir.close(io);
    recovery_verify.recoverAt(dir) catch |err| return kv_db.setLastError(err);
    return kv_db.setOk();
}

pub export fn db_optimize(handle: u64, flags: u32) c_int {
    _ = flags;
    const retained = kv_db.acquireHandle(kv_db.KvDb, handle, .db) catch |err| return kv_db.setLastError(err);
    defer retained.release();
    const d = retained.ptr;
    if (d.dir.custom_ops != null) return kv_db.setLastStatus(.unsupported, "optimize with custom file_ops is not supported yet");
    d.optimize() catch |err| return kv_db.setLastError(err);
    return kv_db.setOk();
}

test {
    _ = batch_snapshot;
    _ = data.allocator;
    _ = data.data_file;
    _ = data.relocation;
    _ = format;
    _ = kv_db;
    _ = index.base_index;
    _ = index.checkpoint;
    _ = index.delta_index;
    _ = index.delta_journal;
    _ = index.index_file;
    _ = manifest;
    _ = recovery_verify;
    _ = platform.file;
    _ = platform.inmemory_file_ops;
    _ = platform.sync;
}

test "root maintenance ABI works with custom InMemoryFileOps except recover unsupported" {
    const testing = std.testing;
    const io = std.Io.Threaded.global_single_threaded.io();
    const path: [:0]const u8 = "zig-cache/db_root_inmemory_maintenance";
    _ = std.Io.Dir.cwd().deleteTree(io, path) catch {};
    defer _ = std.Io.Dir.cwd().deleteTree(io, path) catch {};

    var fs = platform.inmemory_file_ops.FileSystem.init(std.heap.smp_allocator, true);
    defer fs.deinit();
    var raw = fs.rawOps();
    const ctx = kv_db.db_context_t{
        .struct_size = @sizeOf(kv_db.db_context_t),
        .version = 1,
        .user_data = null,
        .hash_fn = null,
        .file_ops = @ptrCast(&raw),
    };

    const db = kv_db.db_create(path.ptr, null, &ctx);
    try testing.expect(db != 0);
    try testing.expectEqual(@as(c_int, @intFromEnum(format.DbStatus.ok)), kv_db.db_put(db, "root-key", 8, "root-value", 10, 0));
    try testing.expectEqual(@as(c_int, @intFromEnum(format.DbStatus.ok)), db_commit(db, 2));
    try testing.expectEqual(@as(c_int, @intFromEnum(format.DbStatus.ok)), db_verify(db, 0));
    try testing.expectEqual(@as(c_int, @intFromEnum(format.DbStatus.unsupported)), db_checkpoint(db, 0));
    try testing.expectEqual(@as(c_int, @intFromEnum(format.DbStatus.unsupported)), db_optimize(db, 0));
    try testing.expectEqual(@as(c_int, @intFromEnum(format.DbStatus.ok)), kv_db.db_close(db));

    try testing.expectEqual(@as(c_int, @intFromEnum(format.DbStatus.unsupported)), db_recover(path.ptr, 0, &ctx));
}
