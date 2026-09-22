//! Resource classes, per-task needs, budgets and the token pool the scheduler
//! uses to decide whether a ready task may start.
const std = @import("std");

pub const ResourceClass = enum(u8) {
    io_read = 0,
    io_write = 1,
    cpu = 2,
    cpu_codec = 3,
    db_write = 4,
    pack_exclusive = 5,

    pub const count = 6;
};

/// What one task consumes while running.
pub const Need = struct {
    io_read: u8 = 0,
    io_write: u8 = 0,
    cpu: u8 = 0,
    cpu_codec: u8 = 0,
    /// Holds this shard's DB write token (one writer per shard by default).
    db_write_shard: ?u16 = null,
    mem_bytes: u64 = 0,
    /// Mutual exclusion against every other task on `pack_id`.
    pack_exclusive: bool = false,
    /// Shared participation on `pack_id`; blocks exclusive tasks.
    pack_shared: bool = false,
    pack_id: u64 = 0,

    /// The class whose ready queue this task is filed under (its scarcest
    /// dimension by convention).
    pub fn primaryClass(self: Need) ResourceClass {
        if (self.db_write_shard != null) return .db_write;
        if (self.pack_exclusive) return .pack_exclusive;
        if (self.cpu_codec != 0) return .cpu_codec;
        if (self.io_write != 0) return .io_write;
        if (self.io_read != 0) return .io_read;
        return .cpu;
    }
};

pub const Budget = struct {
    io_read: u8 = 4,
    io_write: u8 = 2,
    /// 0 = cpu count - 1 (min 1).
    cpu: u8 = 0,
    /// 0 = same as cpu.
    cpu_codec: u8 = 0,
    db_write_per_shard: u8 = 1,
    mem_bytes: u64 = 256 << 20,
    pack_exclusive: u8 = 1,
    /// 0 = derived from the other limits (capped at 64).
    worker_threads: u8 = 0,

    /// The one-knob form used by CLIs and the C ABI: `n` CPU tokens served
    /// by `n` workers. Returns the budget unchanged for `n == 0` (auto).
    pub fn withThreads(self: Budget, n: u8) Budget {
        var out = self;
        if (n != 0) {
            out.cpu = n;
            out.worker_threads = n;
        }
        return out;
    }

    pub fn resolved(self: Budget) Budget {
        var out = self;
        if (out.cpu == 0) {
            const n = std.Thread.getCpuCount() catch 2;
            out.cpu = @intCast(@max(@as(usize, 1), @min(n -| 1, 255)));
        }
        if (out.cpu_codec == 0) out.cpu_codec = out.cpu;
        if (out.io_read == 0) out.io_read = 1;
        if (out.io_write == 0) out.io_write = 1;
        if (out.db_write_per_shard == 0) out.db_write_per_shard = 1;
        if (out.pack_exclusive == 0) out.pack_exclusive = 1;
        if (out.mem_bytes == 0) out.mem_bytes = 64 << 20;
        if (out.worker_threads == 0) {
            const sum: u32 = @as(u32, out.io_read) + out.io_write + out.cpu + out.cpu_codec + out.pack_exclusive + 2;
            out.worker_threads = @intCast(@min(sum, 64));
        }
        return out;
    }

    pub fn validate(self: Budget) !void {
        _ = self;
    }
};

/// Token accounting. Not thread-safe by itself; the scheduler calls it under
/// its own lock.
pub const Pool = struct {
    allocator: std.mem.Allocator,
    budget: Budget,
    io_read: u8 = 0,
    io_write: u8 = 0,
    cpu: u8 = 0,
    cpu_codec: u8 = 0,
    mem_bytes: u64 = 0,
    pack_exclusive_count: u8 = 0,
    shard_writers: std.AutoHashMapUnmanaged(u16, u8) = .empty,
    pack_exclusive: std.AutoHashMapUnmanaged(u64, void) = .empty,
    pack_shared: std.AutoHashMapUnmanaged(u64, u32) = .empty,

    pub fn init(allocator: std.mem.Allocator, budget: Budget) Pool {
        return .{ .allocator = allocator, .budget = budget.resolved() };
    }

    pub fn deinit(self: *Pool) void {
        self.shard_writers.deinit(self.allocator);
        self.pack_exclusive.deinit(self.allocator);
        self.pack_shared.deinit(self.allocator);
        self.* = undefined;
    }

    /// True if the need can never be satisfied even on an idle pool.
    pub fn exceedsBudget(self: *const Pool, need: Need) bool {
        const b = self.budget;
        if (need.io_read > b.io_read or need.io_write > b.io_write) return true;
        if (need.cpu > b.cpu or need.cpu_codec > b.cpu_codec) return true;
        if (need.mem_bytes > b.mem_bytes) return true;
        return false;
    }

    pub fn canAcquire(self: *const Pool, need: Need) bool {
        const b = self.budget;
        if (@as(u32, self.io_read) + need.io_read > b.io_read) return false;
        if (@as(u32, self.io_write) + need.io_write > b.io_write) return false;
        if (@as(u32, self.cpu) + need.cpu > b.cpu) return false;
        if (@as(u32, self.cpu_codec) + need.cpu_codec > b.cpu_codec) return false;
        if (self.mem_bytes + need.mem_bytes > b.mem_bytes) return false;
        if (need.db_write_shard) |s| {
            const used = self.shard_writers.get(s) orelse 0;
            if (used + 1 > b.db_write_per_shard) return false;
        }
        if (need.pack_exclusive) {
            if (@as(u32, self.pack_exclusive_count) + 1 > b.pack_exclusive) return false;
            if (self.pack_exclusive.contains(need.pack_id)) return false;
            if ((self.pack_shared.get(need.pack_id) orelse 0) != 0) return false;
        }
        if (need.pack_shared and self.pack_exclusive.contains(need.pack_id)) return false;
        return true;
    }

    pub fn acquire(self: *Pool, need: Need) !void {
        self.io_read += need.io_read;
        self.io_write += need.io_write;
        self.cpu += need.cpu;
        self.cpu_codec += need.cpu_codec;
        self.mem_bytes += need.mem_bytes;
        if (need.db_write_shard) |s| {
            const gop = try self.shard_writers.getOrPut(self.allocator, s);
            if (!gop.found_existing) gop.value_ptr.* = 0;
            gop.value_ptr.* += 1;
        }
        if (need.pack_exclusive) {
            self.pack_exclusive_count += 1;
            try self.pack_exclusive.put(self.allocator, need.pack_id, {});
        }
        if (need.pack_shared) {
            const gop = try self.pack_shared.getOrPut(self.allocator, need.pack_id);
            if (!gop.found_existing) gop.value_ptr.* = 0;
            gop.value_ptr.* += 1;
        }
    }

    pub fn release(self: *Pool, need: Need) void {
        self.io_read -= need.io_read;
        self.io_write -= need.io_write;
        self.cpu -= need.cpu;
        self.cpu_codec -= need.cpu_codec;
        self.mem_bytes -= need.mem_bytes;
        if (need.db_write_shard) |s| {
            if (self.shard_writers.getPtr(s)) |p| {
                p.* -= 1;
            }
        }
        if (need.pack_exclusive) {
            self.pack_exclusive_count -= 1;
            _ = self.pack_exclusive.remove(need.pack_id);
        }
        if (need.pack_shared) {
            if (self.pack_shared.getPtr(need.pack_id)) |p| {
                p.* -= 1;
            }
        }
    }
};

test "pool enforces counts memory shard tokens and pack exclusion" {
    var pool = Pool.init(std.testing.allocator, .{ .io_read = 1, .cpu = 2, .mem_bytes = 10, .db_write_per_shard = 1, .pack_exclusive = 1 });
    defer pool.deinit();
    const a: Need = .{ .io_read = 1, .mem_bytes = 6, .pack_shared = true, .pack_id = 7 };
    const b: Need = .{ .io_read = 1 };
    const c: Need = .{ .mem_bytes = 5 };
    const w0: Need = .{ .db_write_shard = 0 };
    const x: Need = .{ .pack_exclusive = true, .pack_id = 7 };
    try std.testing.expect(pool.canAcquire(a));
    try pool.acquire(a);
    try std.testing.expect(!pool.canAcquire(b));
    try std.testing.expect(!pool.canAcquire(c));
    try std.testing.expect(pool.canAcquire(w0));
    try pool.acquire(w0);
    try std.testing.expect(!pool.canAcquire(w0));
    try std.testing.expect(!pool.canAcquire(x));
    pool.release(a);
    try std.testing.expect(pool.canAcquire(x));
    try pool.acquire(x);
    try std.testing.expect(!pool.canAcquire(a));
    pool.release(x);
    pool.release(w0);
    try std.testing.expect(pool.canAcquire(a));
    try std.testing.expectEqual(ResourceClass.db_write, w0.primaryClass());
    try std.testing.expectEqual(ResourceClass.pack_exclusive, x.primaryClass());
    try std.testing.expectEqual(ResourceClass.io_read, a.primaryClass());
    try std.testing.expectEqual(ResourceClass.cpu, c.primaryClass());
}
