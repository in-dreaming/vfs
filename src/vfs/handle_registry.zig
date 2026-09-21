const std = @import("std");
const sync = @import("db_internal").platform.sync;

pub const HandleKind = enum(u8) { volume, file };

/// Readers (every vfs_read_at / stat) take the lock shared; only open/close
/// take it exclusively, so validation never serializes concurrent readers.
var lock: sync.RwLock = .{};
var handles: std.AutoHashMapUnmanaged(u64, HandleKind) = .empty;

pub fn register(handle: u64, kind: HandleKind) !void {
    lock.lock();
    defer lock.unlock();
    try handles.put(std.heap.smp_allocator, handle, kind);
}

pub fn unregister(handle: u64) void {
    lock.lock();
    defer lock.unlock();
    _ = handles.remove(handle);
}

pub fn validate(comptime T: type, handle: u64, kind: HandleKind) !*T {
    if (handle == 0) return error.InvalidArgument;
    lock.lockShared();
    const found = handles.get(handle);
    lock.unlockShared();
    if (found == null or found.? != kind) return error.InvalidArgument;
    return @ptrFromInt(handle);
}

test "vfs handle registry rejects invalid and closed handles" {
    const Obj = struct { value: u32 };
    const obj = try std.heap.smp_allocator.create(Obj);
    defer std.heap.smp_allocator.destroy(obj);
    obj.* = .{ .value = 7 };
    const h = @intFromPtr(obj);
    try register(h, .volume);
    try std.testing.expectEqual(@as(u32, 7), (try validate(Obj, h, .volume)).value);
    unregister(h);
    try std.testing.expectError(error.InvalidArgument, validate(Obj, h, .volume));
}
