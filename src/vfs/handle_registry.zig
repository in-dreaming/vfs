const std = @import("std");

pub const HandleKind = enum(u8) { volume, file };

var lock: std.atomic.Mutex = .unlocked;
var handles: std.AutoHashMapUnmanaged(u64, HandleKind) = .empty;

fn lockMutex(m: *std.atomic.Mutex) void {
    while (!m.tryLock()) std.atomic.spinLoopHint();
}

pub fn register(handle: u64, kind: HandleKind) !void {
    lockMutex(&lock);
    defer lock.unlock();
    try handles.put(std.heap.smp_allocator, handle, kind);
}

pub fn unregister(handle: u64) void {
    lockMutex(&lock);
    defer lock.unlock();
    _ = handles.remove(handle);
}

pub fn validate(comptime T: type, handle: u64, kind: HandleKind) !*T {
    if (handle == 0) return error.InvalidArgument;
    lockMutex(&lock);
    const found = handles.get(handle);
    lock.unlock();
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
