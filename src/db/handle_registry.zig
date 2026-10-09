//! Lifetime-safe opaque handles. The map lock protects admission only; each
//! object has its own retain count and drain condition. No I/O, destructor,
//! join or wait runs under the process-wide map lock.
const std = @import("std");
const sync = @import("platform/sync.zig");

pub fn Registry(comptime Kind: type, comptime namespace: u8) type {
    return struct {
        const Self = @This();
        const Entry = struct {
            ptr: *anyopaque,
            kind: Kind,
            mutex: sync.Mutex = .{},
            drained: sync.Condition = .{},
            refs: usize = 0,
        };
        var lock: sync.Mutex = .{};
        var entries: std.AutoHashMapUnmanaged(u64, *Entry) = .empty;
        var next_id: u64 = 1;
        const allocator = std.heap.smp_allocator;

        pub fn Lease(comptime T: type) type {
            return struct {
                entry: *Entry,
                ptr: *T,

                /// Duplicate while the original lease is still live. Retains
                /// remain valid after the public handle has been invalidated.
                pub fn retain(self: @This()) @This() {
                    self.entry.mutex.lock();
                    defer self.entry.mutex.unlock();
                    self.entry.refs += 1;
                    return self;
                }

                /// Exactly once for each acquire/retain; do not use afterward.
                pub fn release(self: @This()) void {
                    self.entry.mutex.lock();
                    defer self.entry.mutex.unlock();
                    std.debug.assert(self.entry.refs != 0);
                    self.entry.refs -= 1;
                    if (self.entry.refs == 0) self.entry.drained.broadcast();
                }
            };
        }

        pub fn register(ptr: anytype, kind: Kind) !u64 {
            const entry = try allocator.create(Entry);
            errdefer allocator.destroy(entry);
            entry.* = .{ .ptr = @ptrCast(ptr), .kind = kind };
            lock.lock();
            defer lock.unlock();
            // Exhaustion fails closed: an ID is never reused, including after
            // unregister or an allocation failure in the hash map.
            if (next_id >= (@as(u64, 1) << 56)) return error.NoSpace;
            const id = (@as(u64, namespace) << 56) | next_id;
            next_id += 1;
            try entries.put(allocator, id, entry);
            return id;
        }

        pub fn acquire(comptime T: type, id: u64, kind: Kind) !Lease(T) {
            lock.lock();
            defer lock.unlock();
            const entry = entries.get(id) orelse return error.InvalidArgument;
            if (entry.kind != kind) return error.InvalidArgument;
            entry.mutex.lock();
            defer entry.mutex.unlock();
            entry.refs += 1;
            return .{ .entry = entry, .ptr = @ptrCast(@alignCast(entry.ptr)) };
        }

        /// Invalidate now, then drain existing operations without holding the
        /// map lock. Exactly one closer receives ownership of the object.
        pub fn take(comptime T: type, id: u64, kind: Kind) !*T {
            return takeImpl(T, id, kind, false);
        }

        /// Used for containers: live operations/dependents return Busy and
        /// leave the public handle valid. This is atomic with acquire.
        pub fn takeIdle(comptime T: type, id: u64, kind: Kind) !*T {
            return takeImpl(T, id, kind, true);
        }

        fn takeImpl(comptime T: type, id: u64, kind: Kind, idle_only: bool) !*T {
            lock.lock();
            const entry = entries.get(id) orelse {
                lock.unlock();
                return error.InvalidArgument;
            };
            if (entry.kind != kind) {
                lock.unlock();
                return error.InvalidArgument;
            }
            entry.mutex.lock();
            if (idle_only and entry.refs != 0) {
                entry.mutex.unlock();
                lock.unlock();
                return error.Busy;
            }
            _ = entries.remove(id);
            lock.unlock();
            while (entry.refs != 0) entry.drained.wait(&entry.mutex);
            entry.mutex.unlock();
            const ptr: *T = @ptrCast(@alignCast(entry.ptr));
            allocator.destroy(entry);
            return ptr;
        }
    };
}

test "opaque registry retains objects and never aliases reused addresses" {
    const R = Registry(enum { a, b }, 0xfe);
    var value: u32 = 7;
    const first = try R.register(&value, .a);
    const lease = try R.acquire(u32, first, .a);
    try std.testing.expectError(error.InvalidArgument, R.acquire(u32, first, .b));
    try std.testing.expectError(error.Busy, R.takeIdle(u32, first, .a));
    const copy = lease.retain();
    lease.release();
    try std.testing.expectEqual(@as(u32, 7), copy.ptr.*);
    copy.release();
    try std.testing.expectEqual(&value, try R.take(u32, first, .a));
    const second = try R.register(&value, .a);
    try std.testing.expect(first != second);
    try std.testing.expectError(error.InvalidArgument, R.acquire(u32, first, .a));
    _ = try R.take(u32, second, .a);
}

test "opaque close drains only its own object and invalidates before drain" {
    const R = Registry(enum { item }, 0xfd);
    const Ctx = struct {
        handle: u64,
        started: std.atomic.Value(bool) = .init(false),
        done: std.atomic.Value(bool) = .init(false),
        fn close(ctx: *@This()) void {
            ctx.started.store(true, .release);
            _ = R.take(u32, ctx.handle, .item) catch unreachable;
            ctx.done.store(true, .release);
        }
    };
    var value: u32 = 1;
    const h = try R.register(&value, .item);
    const lease = try R.acquire(u32, h, .item);
    var ctx = Ctx{ .handle = h };
    const thread = try std.Thread.spawn(.{}, Ctx.close, .{&ctx});
    // Observe admission closing rather than relying on timing/sleeps.
    while (true) {
        if (R.acquire(u32, h, .item)) |r| r.release() else |_| break;
        std.Thread.yield() catch {};
    }
    try std.testing.expect(!ctx.done.load(.acquire));
    const other = try R.register(&value, .item);
    _ = try R.take(u32, other, .item);
    lease.release();
    thread.join();
    try std.testing.expect(ctx.done.load(.acquire));
}
