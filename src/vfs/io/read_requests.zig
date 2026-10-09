//! Bounded per-volume read workers and detached polling results. No user
//! callback runs on these threads. Terminal jobs retain only their result
//! storage and admission ledger, never a file, volume, or destination lease.
const std = @import("std");
const sync = @import("db_internal").platform.sync;
const data_file = @import("db_internal").data_file;
const registry = @import("../handle_registry.zig");
const file_mod = @import("file_handle.zig");
const errors = @import("../error.zig");
const a = std.heap.smp_allocator;
threadlocal var reported_scratch: usize = 0;

pub const Options = struct {
    workers: u32 = 4,
    max_requests: u32 = 256,
    max_ranges: u32 = 256,
    scratch_bytes: usize = 16 * 1024 * 1024,

    pub fn validate(self: Options) !void {
        if (self.workers == 0 or self.workers > 64 or self.max_requests == 0 or self.max_ranges == 0 or self.scratch_bytes == 0) return error.InvalidArgument;
    }
};
pub const State = enum(u32) { queued, running, done, failed, cancelled };
pub const Range = extern struct { offset: u64, dst: ?*anyopaque, size: u64 };
pub const Result = struct { state: State = .queued, status: errors.Status = .ok, bytes: u64 = 0 };
pub const Snapshot = struct { state: State, status: errors.Status, ranges_total: u32, ranges_done: u32, bytes: u64 };
pub const Stats = struct {
    queued: u64 = 0,
    running: u64 = 0,
    retained: u64 = 0,
    completed: u64 = 0,
    failed: u64 = 0,
    cancelled: u64 = 0,
    rejected: u64 = 0,
    read_bytes: u64 = 0,
    prefetch_bytes: u64 = 0,
    scratch_retained_bytes: u64 = 0,
    scratch_peak_worker_bytes: u64 = 0,
};

pub const Request = struct {
    pool: *Executor,
    file: ?registry.Lease(file_mod.FileHandle),
    ranges: []Range,
    results: []Result,
    priority: i32,
    sequence: u64 = 0,
    prefetch: bool,
    cancel_flag: std.atomic.Value(bool) = .init(false),
    mutex: sync.Mutex = .{},
    changed: sync.Condition = .{},
    state: State = .queued,
    status: errors.Status = .ok,
    ranges_done: u32 = 0,
    bytes: u64 = 0,

    pub fn snapshot(self: *Request) Snapshot {
        self.mutex.lock();
        defer self.mutex.unlock();
        return .{ .state = self.state, .status = self.status, .ranges_total = @intCast(self.ranges.len), .ranges_done = self.ranges_done, .bytes = self.bytes };
    }

    pub fn result(self: *Request, index: u32) !Result {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (index >= self.results.len) return error.InvalidArgument;
        return self.results[index];
    }

    pub fn cancel(self: *Request) void {
        self.cancel_flag.store(true, .release);
        self.pool.cancelQueued(self);
    }

    pub fn wait(self: *Request) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        while (!terminal(self.state)) self.changed.wait(&self.mutex);
    }

    /// Called only after registry.take has drained concurrent ABI calls.
    pub fn destroy(self: *Request) void {
        self.cancel();
        self.wait();
        const pool = self.pool;
        pool.allocator.free(self.ranges);
        pool.allocator.free(self.results);
        pool.allocator.destroy(self);
        pool.mutex.lock();
        pool.stats.retained -= 1;
        pool.mutex.unlock();
        pool.release();
    }

    fn execute(self: *Request) void {
        self.mutex.lock();
        self.state = .running;
        self.mutex.unlock();
        var final_state: State = .done;
        var final_status: errors.Status = .ok;
        for (self.ranges, 0..) |range, i| {
            self.mutex.lock();
            self.results[i].state = .running;
            self.mutex.unlock();
            var completed: usize = 0;
            const size: usize = @intCast(range.size);
            const dst: ?[]u8 = if (self.prefetch) null else if (range.dst) |p| @as([*]u8, @ptrCast(p))[0..size] else &.{};
            var status: errors.Status = .ok;
            self.file.?.ptr.readControlled(range.offset, dst, size, &self.cancel_flag, &completed) catch |e| {
                status = errors.fromError(e);
            };
            const state: State = if (status == .ok) .done else if (status == .cancelled) .cancelled else .failed;
            self.mutex.lock();
            self.results[i] = .{ .state = state, .status = status, .bytes = completed };
            self.bytes += completed;
            if (state == .done) self.ranges_done += 1;
            self.mutex.unlock();
            if (state != .done) {
                final_state = state;
                final_status = status;
                break;
            }
        }
        self.finish(final_state, final_status, true);
    }

    fn finish(self: *Request, state: State, status: errors.Status, was_running: bool) void {
        // This job is either exclusively owned by a worker or atomically
        // removed from its queue. No second finisher can enter.
        self.pool.mutex.lock();
        if (was_running) {
            self.pool.stats.running -= 1;
            const current = data_file.readScratchBytes();
            self.pool.stats.scratch_retained_bytes -= reported_scratch;
            self.pool.stats.scratch_retained_bytes += current;
            self.pool.stats.scratch_peak_worker_bytes = @max(self.pool.stats.scratch_peak_worker_bytes, data_file.readScratchHighWaterBytes());
            reported_scratch = current;
        }
        switch (state) {
            .done => self.pool.stats.completed += 1,
            .failed => self.pool.stats.failed += 1,
            .cancelled => self.pool.stats.cancelled += 1,
            else => unreachable,
        }
        if (self.prefetch) self.pool.stats.prefetch_bytes += self.bytes else self.pool.stats.read_bytes += self.bytes;
        self.pool.mutex.unlock();
        // No volume/file access is permitted after this release. In
        // particular, a completed result must not block mounted updates.
        if (self.file) |lease| lease.release();
        self.file = null;
        self.mutex.lock();
        self.status = status;
        self.state = state;
        self.changed.broadcast();
        self.mutex.unlock();
        // No access to self after unlock: end may immediately destroy it.
    }
};

pub fn terminal(state: State) bool {
    return state == .done or state == .failed or state == .cancelled;
}

pub const Executor = struct {
    allocator: std.mem.Allocator,
    options: Options,
    refs: std.atomic.Value(usize) = .init(1),
    mutex: sync.Mutex = .{},
    work: sync.Condition = .{},
    queue: []?*Request,
    threads: []std.Thread,
    stopping: bool = false,
    sequence: u64 = 0,
    stats: Stats = .{},

    pub fn create(options: Options) !*Executor {
        return createWithAllocator(a, options);
    }

    pub fn createWithAllocator(allocator: std.mem.Allocator, options: Options) !*Executor {
        try options.validate();
        const self = try allocator.create(Executor);
        errdefer allocator.destroy(self);
        const queue = try allocator.alloc(?*Request, options.max_requests);
        errdefer allocator.free(queue);
        @memset(queue, null);
        const threads = try allocator.alloc(std.Thread, options.workers);
        errdefer allocator.free(threads);
        self.* = .{ .allocator = allocator, .options = options, .queue = queue, .threads = threads };
        var started: usize = 0;
        errdefer {
            self.mutex.lock();
            self.stopping = true;
            self.work.broadcast();
            self.mutex.unlock();
            for (threads[0..started]) |t| t.join();
        }
        while (started < threads.len) : (started += 1) threads[started] = try std.Thread.spawn(.{}, worker, .{self});
        return self;
    }

    /// The volume owns one reference. Completed results own the remainder.
    /// File dependencies guarantee there are no unfinished jobs at close.
    pub fn shutdown(self: *Executor) void {
        self.mutex.lock();
        self.stopping = true;
        self.work.broadcast();
        self.mutex.unlock();
        for (self.threads) |t| t.join();
        self.allocator.free(self.threads);
        self.threads = &.{};
        // Keep the bounded queue array until the last result is released;
        // cancel on a detached terminal handle still consults it safely.
        self.release();
    }

    fn release(self: *Executor) void {
        if (self.refs.fetchSub(1, .acq_rel) == 1) {
            const allocator = self.allocator;
            allocator.free(self.queue);
            allocator.destroy(self);
        }
    }

    pub fn snapshot(self: *Executor) Stats {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.stats;
    }

    /// Borrows the submission lease; retains it only for an accepted job.
    pub fn submit(self: *Executor, file: registry.Lease(file_mod.FileHandle), ranges: []const Range, priority: i32, prefetch: bool) !u64 {
        if (ranges.len == 0 or ranges.len > self.options.max_ranges) return error.InvalidArgument;
        for (ranges) |range| {
            const size = std.math.cast(usize, range.size) orelse return error.InvalidArgument;
            if (!prefetch and size != 0) {
                const ptr = range.dst orelse return error.InvalidArgument;
                _ = std.math.add(usize, @intFromPtr(ptr), size) catch return error.InvalidArgument;
            }
        }
        self.mutex.lock();
        if (self.stopping or self.stats.retained >= self.options.max_requests) {
            self.stats.rejected += 1;
            self.mutex.unlock();
            return error.Busy;
        }
        self.stats.retained += 1;
        self.mutex.unlock();
        errdefer {
            self.mutex.lock();
            self.stats.retained -= 1;
            self.mutex.unlock();
        }
        const job = try self.allocator.create(Request);
        errdefer self.allocator.destroy(job);
        const owned = try self.allocator.dupe(Range, ranges);
        errdefer self.allocator.free(owned);
        const results = try self.allocator.alloc(Result, ranges.len);
        errdefer self.allocator.free(results);
        @memset(results, .{});
        job.* = .{ .pool = self, .file = file.retain(), .ranges = owned, .results = results, .priority = priority, .prefetch = prefetch };
        errdefer job.file.?.release();
        const id = try registry.register(job, .request);
        _ = self.refs.fetchAdd(1, .monotonic);
        self.mutex.lock();
        defer self.mutex.unlock();
        job.sequence = self.sequence;
        self.sequence +%= 1;
        for (self.queue) |*slot| if (slot.* == null) {
            slot.* = job;
            self.stats.queued += 1;
            self.work.signal();
            return id;
        };
        unreachable; // retained admission includes queued, running and results
    }

    fn cancelQueued(self: *Executor, job: *Request) void {
        self.mutex.lock();
        for (self.queue) |*slot| if (slot.* == job) {
            slot.* = null;
            self.stats.queued -= 1;
            self.mutex.unlock();
            job.finish(.cancelled, .cancelled, false);
            return;
        };
        self.mutex.unlock();
    }

    fn take(self: *Executor) ?*Request {
        self.mutex.lock();
        defer self.mutex.unlock();
        while (true) {
            var selected: ?usize = null;
            for (self.queue, 0..) |slot, i| if (slot) |job| {
                const old = if (selected) |index| self.queue[index].? else null;
                if (old == null or job.priority > old.?.priority or (job.priority == old.?.priority and job.sequence < old.?.sequence)) selected = i;
            };
            if (selected) |index| {
                const job = self.queue[index].?;
                self.queue[index] = null;
                self.stats.queued -= 1;
                self.stats.running += 1;
                return job;
            }
            if (self.stopping) return null;
            self.work.wait(&self.mutex);
        }
    }
};

fn worker(pool: *Executor) void {
    data_file.configureReadScratchLimit(pool.options.scratch_bytes);
    defer {
        data_file.releaseReadScratch();
        pool.mutex.lock();
        pool.stats.scratch_retained_bytes -= reported_scratch;
        pool.mutex.unlock();
        reported_scratch = 0;
    }
    while (pool.take()) |job| job.execute();
}

test "read executor allocation failures unwind workers and queue" {
    const Check = struct {
        fn run(allocator: std.mem.Allocator) !void {
            const pool = try Executor.createWithAllocator(allocator, .{ .workers = 1, .max_requests = 2, .max_ranges = 2 });
            pool.shutdown();
        }
    };
    try std.testing.checkAllAllocationFailures(std.testing.allocator, Check.run, .{});
}
