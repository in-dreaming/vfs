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
};

pub export fn db_checkpoint(db: ?*kv_db.KvDb, flags: u32) c_int {
    _ = flags;
    const d = db orelse return @intFromEnum(format.DbStatus.invalid_argument);
    d.checkpoint() catch |err| return @intFromEnum(format.statusFromError(err));
    return @intFromEnum(format.DbStatus.ok);
}

pub export fn db_commit(db: ?*kv_db.KvDb, durability: u32) c_int {
    const d = db orelse return @intFromEnum(format.DbStatus.invalid_argument);
    const dur: format.Durability = switch (durability) {
        0 => .none,
        1 => .async,
        2 => .sync,
        else => .sync,
    };
    d.commitPending(dur) catch |err| return @intFromEnum(format.statusFromError(err));
    return @intFromEnum(format.DbStatus.ok);
}

pub export fn db_verify(db: ?*kv_db.KvDb, flags: u32) c_int {
    _ = flags;
    const d = db orelse return @intFromEnum(format.DbStatus.invalid_argument);
    d.commitPending(null) catch |err| return @intFromEnum(format.statusFromError(err));
    var report = recovery_verify.verifyAt(d.dir, std.heap.smp_allocator) catch |err| return @intFromEnum(format.statusFromError(err));
    defer report.deinit();
    return if (report.ok()) @intFromEnum(format.DbStatus.ok) else @intFromEnum(format.DbStatus.corruption);
}

pub export fn db_recover(path: [*:0]const u8, flags: u32) c_int {
    _ = flags;
    const io = std.Io.Threaded.global_single_threaded.io();
    var dir = std.Io.Dir.openDir(std.Io.Dir.cwd(), io, std.mem.span(path), .{}) catch |err| return @intFromEnum(format.statusFromError(err));
    defer dir.close(io);
    recovery_verify.recoverAt(dir) catch |err| return @intFromEnum(format.statusFromError(err));
    return @intFromEnum(format.DbStatus.ok);
}

pub export fn db_optimize(db: ?*kv_db.KvDb, flags: u32) c_int {
    _ = flags;
    const d = db orelse return @intFromEnum(format.DbStatus.invalid_argument);
    d.optimize() catch |err| return @intFromEnum(format.statusFromError(err));
    return @intFromEnum(format.DbStatus.ok);
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
}
