//! Reusable fixed-size worker pool. Jobs are opaque `(context, fn)` pairs so
//! the pool has no knowledge of tasks or schedulers and can outlive a run.
const std = @import("std");
const sync = @import("db_internal").platform.sync;

pub const Job = struct {
    context: *anyopaque,
    run: *const fn (context: *anyopaque, arg: usize) void,
    arg: usize,
};

pub const WorkerPool = struct {
    allocator: std.mem.Allocator,
    threads: []std.Thread,
    mutex: sync.Mutex = .{},
    cond: sync.Condition = .{},
    queue: std.ArrayList(Job) = .empty,
    head: usize = 0,
    stopping: bool = false,

    pub fn init(allocator: std.mem.Allocator, count: u32) !*WorkerPool {
        const self = try allocator.create(WorkerPool);
        errdefer allocator.destroy(self);
        self.* = .{ .allocator = allocator, .threads = &.{} };
        self.threads = try allocator.alloc(std.Thread, @max(count, 1));
        var started: usize = 0;
        errdefer {
            self.mutex.lock();
            self.stopping = true;
            self.mutex.unlock();
            self.cond.broadcast();
            for (self.threads[0..started]) |t| t.join();
            allocator.free(self.threads);
        }
        while (started < self.threads.len) : (started += 1) {
            self.threads[started] = try std.Thread.spawn(.{}, workerMain, .{self});
        }
        return self;
    }

    pub fn deinit(self: *WorkerPool) void {
        self.mutex.lock();
        self.stopping = true;
        self.mutex.unlock();
        self.cond.broadcast();
        for (self.threads) |t| t.join();
        self.allocator.free(self.threads);
        self.queue.deinit(self.allocator);
        const allocator = self.allocator;
        allocator.destroy(self);
    }

    pub fn workerCount(self: *const WorkerPool) u32 {
        return @intCast(self.threads.len);
    }

    pub fn submit(self: *WorkerPool, job: Job) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.head != 0 and self.head * 2 >= self.queue.items.len) {
            const remaining = self.queue.items.len - self.head;
            std.mem.copyForwards(Job, self.queue.items[0..remaining], self.queue.items[self.head..]);
            self.queue.shrinkRetainingCapacity(remaining);
            self.head = 0;
        }
        try self.queue.append(self.allocator, job);
        self.cond.signal();
    }

    fn take(self: *WorkerPool) ?Job {
        self.mutex.lock();
        defer self.mutex.unlock();
        while (true) {
            if (self.head < self.queue.items.len) {
                const job = self.queue.items[self.head];
                self.head += 1;
                return job;
            }
            if (self.stopping) return null;
            self.cond.wait(&self.mutex);
        }
    }
};

fn workerMain(pool: *WorkerPool) void {
    while (pool.take()) |job| job.run(job.context, job.arg);
}

test "worker pool runs submitted jobs on multiple threads" {
    const Ctx = struct {
        counter: std.atomic.Value(u32) = .init(0),
        fn run(ctx: *anyopaque, arg: usize) void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            _ = self.counter.fetchAdd(@intCast(arg), .monotonic);
        }
    };
    var ctx: Ctx = .{};
    var pool = try WorkerPool.init(std.testing.allocator, 3);
    defer pool.deinit();
    var i: usize = 0;
    while (i < 100) : (i += 1) try pool.submit(.{ .context = &ctx, .run = Ctx.run, .arg = 1 });
    var spins: u32 = 0;
    while (ctx.counter.load(.acquire) != 100 and spins < 100_000) : (spins += 1) std.Thread.yield() catch {};
    try std.testing.expectEqual(@as(u32, 100), ctx.counter.load(.acquire));
}
