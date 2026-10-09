//! Resource-budgeted DAG scheduler.
//!
//! One dispatcher thread (the caller of `run`) owns the ready queues and the
//! token pool. Workers only execute tasks and post completions. A task may
//! return `.yield` when a resource the scheduler does not model (e.g. staged
//! write memory) is temporarily unavailable; it is requeued with a small
//! priority penalty instead of blocking a worker.
const std = @import("std");
const resource = @import("resource.zig");
const graph_mod = @import("graph.zig");
const worker_pool = @import("worker_pool.zig");
const sync = @import("db_internal").platform.sync;

pub const TaskId = graph_mod.TaskId;
pub const Graph = graph_mod.Graph;
pub const TaskDesc = graph_mod.TaskDesc;

/// Monotonic clock in nanoseconds.
pub fn nowNs() i128 {
    const io = std.Io.Threaded.global_single_threaded.io();
    return @intCast(std.Io.Timestamp.now(io, .awake).nanoseconds);
}

pub fn sleepNs(ns: u64) void {
    const io = std.Io.Threaded.global_single_threaded.io();
    io.sleep(.fromNanoseconds(@intCast(ns)), .awake) catch {};
}

pub const RunResult = enum { done, yield };

pub const Executor = struct {
    context: *anyopaque,
    run: *const fn (context: *anyopaque, graph: *Graph, id: TaskId, desc: TaskDesc) anyerror!RunResult,
};

pub const RunOptions = struct {
    /// Keep executing independent tasks after a failure (users of the failed
    /// task are still cancelled). Default stops dispatching new work.
    continue_on_error: bool = false,
    /// Record per-task dispatch/start/end timestamps.
    trace: bool = false,
    /// Test hook: fail this task instead of running it.
    fail_task: ?TaskId = null,
};

pub const KindStat = struct {
    kind: u16,
    count: u32 = 0,
    yields: u32 = 0,
    total_ns: u64 = 0,
};

pub const TraceRecord = struct {
    id: TaskId,
    kind: u16,
    dispatched_ns: i128,
    started_ns: i128,
    finished_ns: i128,
    thread_slot: u32,
    result: enum(u8) { done, yield, failed },
};

pub const Report = struct {
    finished: u32 = 0,
    failed: u32 = 0,
    cancelled: u32 = 0,
    yields: u32 = 0,
    max_running: u32 = 0,
    max_mem_bytes: u64 = 0,
    first_error: ?anyerror = null,
    wall_ns: u64 = 0,
    dispatch_order: std.ArrayList(TaskId) = .empty,
    kinds: std.ArrayList(KindStat) = .empty,
    trace: std.ArrayList(TraceRecord) = .empty,

    pub fn deinit(self: *Report, allocator: std.mem.Allocator) void {
        self.dispatch_order.deinit(allocator);
        self.kinds.deinit(allocator);
        self.trace.deinit(allocator);
        self.* = .{};
    }

    pub fn kindStat(self: *const Report, kind: u16) ?KindStat {
        for (self.kinds.items) |k| if (k.kind == kind) return k;
        return null;
    }

    /// Dumps the run summary and (when recorded) the per-task trace as one
    /// JSON document. Timestamps are nanoseconds relative to the earliest
    /// dispatch so the output is stable across runs.
    pub fn writeJson(self: *const Report, writer: anytype) !void {
        var t0: i128 = std.math.maxInt(i128);
        for (self.trace.items) |r| t0 = @min(t0, r.dispatched_ns);
        if (self.trace.items.len == 0) t0 = 0;
        try writer.print("{{\"finished\":{d},\"failed\":{d},\"cancelled\":{d},\"yields\":{d},\"max_running\":{d},\"max_mem_bytes\":{d},\"wall_ns\":{d},\"kinds\":[", .{
            self.finished, self.failed, self.cancelled, self.yields, self.max_running, self.max_mem_bytes, self.wall_ns,
        });
        for (self.kinds.items, 0..) |k, i| {
            if (i != 0) try writer.writeAll(",");
            try writer.print("{{\"kind\":{d},\"count\":{d},\"yields\":{d},\"total_ns\":{d}}}", .{ k.kind, k.count, k.yields, k.total_ns });
        }
        try writer.writeAll("],\"trace\":[");
        for (self.trace.items, 0..) |r, i| {
            if (i != 0) try writer.writeAll(",");
            try writer.print("{{\"id\":{d},\"kind\":{d},\"dispatched\":{d},\"started\":{d},\"finished\":{d},\"thread\":{d},\"result\":\"{s}\"}}", .{
                r.id, r.kind, r.dispatched_ns - t0, r.started_ns - t0, r.finished_ns - t0, r.thread_slot, @tagName(r.result),
            });
        }
        try writer.writeAll("]}\n");
    }

    fn bumpKind(self: *Report, allocator: std.mem.Allocator, kind: u16, ns: u64, yielded: bool) !void {
        for (self.kinds.items) |*k| {
            if (k.kind != kind) continue;
            if (yielded) k.yields += 1 else k.count += 1;
            k.total_ns += ns;
            return;
        }
        try self.kinds.append(allocator, .{ .kind = kind, .count = if (yielded) 0 else 1, .yields = if (yielded) 1 else 0, .total_ns = ns });
    }
};

const ReadyItem = struct {
    id: TaskId,
    priority: i32,
    seq: u64,
};

fn readyOrder(_: void, a: ReadyItem, b: ReadyItem) std.math.Order {
    if (a.priority != b.priority) return if (a.priority > b.priority) .lt else .gt;
    return std.math.order(a.seq, b.seq);
}

const ReadyQueue = std.PriorityQueue(ReadyItem, void, readyOrder);

const Completion = struct {
    id: TaskId,
    result: RunResult,
    err: ?anyerror,
    started_ns: i128,
    finished_ns: i128,
    thread_slot: u32,
};

/// Order in which classes are drained each dispatch round. Scarce/serializing
/// classes first so they are never starved by bulk CPU work.
const dispatch_order = [_]resource.ResourceClass{ .db_write, .pack_exclusive, .cpu_codec, .io_write, .io_read, .cpu };

const RunState = struct {
    allocator: std.mem.Allocator,
    graph: *Graph,
    executor: Executor,
    options: RunOptions,
    pool: resource.Pool,
    mutex: sync.Mutex = .{},
    cond: sync.Condition = .{},
    ready: [resource.ResourceClass.count]ReadyQueue,
    completions: std.ArrayList(Completion) = .empty,
    running: u32 = 0,
    seq: u64 = 0,
    stop_dispatch: bool = false,
    report: Report = .{},

    fn pushReadyLocked(self: *RunState, id: TaskId) !void {
        const t = &self.graph.tasks.items[id];
        const class = t.desc.need.primaryClass();
        self.seq += 1;
        try self.ready[@intFromEnum(class)].push(self.allocator, .{ .id = id, .priority = t.desc.priority - @as(i32, @intCast(@min(t.yields, 1000))), .seq = self.seq });
    }

    fn onReady(ctx: *anyopaque, id: TaskId) void {
        const self: *RunState = @ptrCast(@alignCast(ctx));
        self.mutex.lock();
        defer self.mutex.unlock();
        self.pushReadyLocked(id) catch {
            self.graph.lock.lock();
            self.graph.tasks.items[id].state = .failed;
            self.graph.lock.unlock();
            if (self.report.first_error == null) self.report.first_error = error.OutOfMemory;
        };
        self.cond.signal();
    }

    fn workerRun(ctx: *anyopaque, arg: usize) void {
        const self: *RunState = @ptrCast(@alignCast(ctx));
        const id: TaskId = @intCast(arg);
        const desc = blk: {
            self.graph.lock.lock();
            defer self.graph.lock.unlock();
            break :blk self.graph.tasks.items[id].desc;
        };
        const started = nowNs();
        var completion: Completion = .{ .id = id, .result = .done, .err = null, .started_ns = started, .finished_ns = 0, .thread_slot = sync.threadSlot() };
        if (self.options.fail_task != null and self.options.fail_task.? == id) {
            completion.err = error.InjectedFailure;
        } else {
            completion.result = self.executor.run(self.executor.context, self.graph, id, desc) catch |err| blk: {
                completion.err = err;
                break :blk .done;
            };
        }
        completion.finished_ns = nowNs();
        self.mutex.lock();
        self.completions.append(self.allocator, completion) catch {
            // Capacity was reserved at submit time; this cannot fail in practice.
            unreachable;
        };
        // Completion makes this stack-local RunState eligible for retirement.
        // Signal while still holding its mutex: after unlock the dispatcher
        // may consume the last completion and return from run immediately.
        self.cond.signal();
        self.mutex.unlock();
    }
};

pub const Scheduler = struct {
    allocator: std.mem.Allocator,
    budget: resource.Budget,
    workers: *worker_pool.WorkerPool,

    pub fn init(allocator: std.mem.Allocator, budget: resource.Budget) !Scheduler {
        const resolved = budget.resolved();
        try resolved.validate();
        const workers = try worker_pool.WorkerPool.init(allocator, resolved.worker_threads);
        return .{ .allocator = allocator, .budget = resolved, .workers = workers };
    }

    pub fn deinit(self: *Scheduler) void {
        self.workers.deinit();
        self.* = undefined;
    }

    /// Runs every task in `graph` to a terminal state. Tasks added to the
    /// graph while running are picked up. Returns the first task error after
    /// all running tasks have drained.
    pub fn run(self: *Scheduler, graph: *Graph, executor: Executor, options: RunOptions) !Report {
        const wall_start = nowNs();
        var state = RunState{
            .allocator = self.allocator,
            .graph = graph,
            .executor = executor,
            .options = options,
            .pool = resource.Pool.init(self.allocator, self.budget),
            .ready = undefined,
        };
        for (&state.ready) |*q| q.* = .empty;
        defer {
            for (&state.ready) |*q| q.deinit(self.allocator);
            state.completions.deinit(self.allocator);
            state.pool.deinit();
        }
        errdefer state.report.deinit(self.allocator);

        // Seed ready queues and attach for dynamic additions.
        {
            graph.lock.lock();
            defer graph.lock.unlock();
            state.mutex.lock();
            defer state.mutex.unlock();
            for (graph.tasks.items, 0..) |*t, i| {
                if (t.state == .pending and t.remaining_deps == 0) {
                    t.state = .ready;
                    try state.pushReadyLocked(@intCast(i));
                } else if (t.state == .ready) {
                    try state.pushReadyLocked(@intCast(i));
                }
            }
            graph.listener = .{ .context = &state, .onReady = RunState.onReady };
        }
        defer {
            graph.lock.lock();
            graph.listener = null;
            graph.lock.unlock();
        }

        state.mutex.lock();
        defer state.mutex.unlock();
        // Dispatcher bookkeeping can fail after jobs have been submitted.
        // Keep their stack-local context alive until every completion arrives;
        // this cleanup must not allocate or execute further dependent work.
        errdefer drainAfterErrorLocked(&state);
        while (true) {
            // Drain completions first so freed resources are visible to dispatch.
            while (state.completions.items.len != 0) {
                const c = state.completions.orderedRemove(0);
                try self.handleCompletion(&state, c);
            }

            const dispatched = try self.dispatchLocked(&state);

            if (state.running == 0) {
                const remaining = try self.nonTerminalLocked(&state);
                if (remaining == 0) break;
                if (!dispatched) {
                    if (state.stop_dispatch or graph.isCancelled()) {
                        try self.cancelRemainingLocked(&state);
                        break;
                    }
                    // Nothing running, nothing dispatchable: either every ready
                    // task exceeds the budget or there is a dependency cycle.
                    try self.cancelRemainingLocked(&state);
                    if (state.report.first_error == null) state.report.first_error = error.ResourceDeadlock;
                    break;
                }
                continue;
            }
            if (dispatched) continue;
            state.cond.wait(&state.mutex);
        }

        state.report.wall_ns = @intCast(@max(nowNs() - wall_start, 0));
        if (state.report.first_error) |err| return err;
        return state.report;
    }

    fn drainAfterErrorLocked(state: *RunState) void {
        state.stop_dispatch = true;
        while (state.running != 0) {
            if (state.completions.pop()) |completion| {
                state.running -= 1;
                state.graph.lock.lock();
                const t = &state.graph.tasks.items[completion.id];
                t.state = if (completion.err != null) .failed else if (completion.result == .done) .finished else .cancelled;
                state.graph.lock.unlock();
            } else {
                state.cond.wait(&state.mutex);
            }
        }
        state.graph.lock.lock();
        defer state.graph.lock.unlock();
        for (state.graph.tasks.items) |*t| switch (t.state) {
            .pending, .ready, .running => t.state = .cancelled,
            else => {},
        };
        // Token/ready/report storage is disposed by run's existing defers.
        // Do not traverse dependencies or grow arrays on this error path.
    }

    fn nonTerminalLocked(_: *Scheduler, state: *RunState) !u32 {
        state.graph.lock.lock();
        defer state.graph.lock.unlock();
        var n: u32 = 0;
        for (state.graph.tasks.items) |t| switch (t.state) {
            .finished, .failed, .cancelled => {},
            else => n += 1,
        };
        return n;
    }

    fn cancelRemainingLocked(_: *Scheduler, state: *RunState) !void {
        state.graph.lock.lock();
        defer state.graph.lock.unlock();
        for (state.graph.tasks.items) |*t| switch (t.state) {
            .pending, .ready => {
                t.state = .cancelled;
                state.report.cancelled += 1;
            },
            else => {},
        };
        for (&state.ready) |*q| q.clearRetainingCapacity();
    }

    fn dispatchLocked(self: *Scheduler, state: *RunState) !bool {
        if (state.stop_dispatch or state.graph.isCancelled()) return false;
        var dispatched = false;
        var skipped: [16]ReadyItem = undefined;
        for (dispatch_order) |class| {
            const q = &state.ready[@intFromEnum(class)];
            var skipped_n: usize = 0;
            while (q.count() != 0 and skipped_n < skipped.len) {
                const item = q.pop().?;
                const need = blk: {
                    state.graph.lock.lock();
                    defer state.graph.lock.unlock();
                    const t = &state.graph.tasks.items[item.id];
                    if (t.state != .ready) break :blk null;
                    break :blk t.desc.need;
                } orelse continue;
                if (state.pool.exceedsBudget(need)) {
                    state.graph.lock.lock();
                    state.graph.tasks.items[item.id].state = .failed;
                    state.graph.lock.unlock();
                    state.report.failed += 1;
                    if (state.report.first_error == null) state.report.first_error = error.NeedExceedsBudget;
                    try self.cascadeCancel(state, item.id);
                    continue;
                }
                if (!state.pool.canAcquire(need)) {
                    skipped[skipped_n] = item;
                    skipped_n += 1;
                    continue;
                }
                // Reserve completion/report capacity before a job can start.
                // Every submitted job must be able to report without allocation.
                try state.report.dispatch_order.ensureUnusedCapacity(self.allocator, 1);
                try state.completions.ensureUnusedCapacity(self.allocator, state.running + 1);
                try state.pool.acquire(need);
                {
                    state.graph.lock.lock();
                    defer state.graph.lock.unlock();
                    const t = &state.graph.tasks.items[item.id];
                    t.state = .running;
                    t.dispatched_ns = nowNs();
                }
                state.running += 1;
                self.workers.submit(.{ .context = state, .run = RunState.workerRun, .arg = item.id }) catch |err| {
                    // submit transfers ownership only on success. Never wait
                    // for a phantom completion when queue allocation fails.
                    state.running -= 1;
                    state.pool.release(need);
                    state.graph.lock.lock();
                    state.graph.tasks.items[item.id].state = .cancelled;
                    state.graph.lock.unlock();
                    return err;
                };
                state.report.max_running = @max(state.report.max_running, state.running);
                state.report.max_mem_bytes = @max(state.report.max_mem_bytes, state.pool.mem_bytes);
                state.report.dispatch_order.appendAssumeCapacity(item.id);
                dispatched = true;
            }
            for (skipped[0..skipped_n]) |item| try q.push(self.allocator, item);
        }
        return dispatched;
    }

    fn handleCompletion(self: *Scheduler, state: *RunState, c: Completion) !void {
        state.running -= 1;
        var need: resource.Need = undefined;
        var kind: u16 = 0;
        var dispatched_ns: i128 = 0;
        var users_copy: []TaskId = &.{};
        defer self.allocator.free(users_copy);
        {
            state.graph.lock.lock();
            defer state.graph.lock.unlock();
            const t = &state.graph.tasks.items[c.id];
            need = t.desc.need;
            kind = t.desc.kind;
            dispatched_ns = t.dispatched_ns;
            t.started_ns = c.started_ns;
            t.finished_ns = c.finished_ns;
            if (c.err == null and c.result == .done) {
                t.state = .finished;
                users_copy = try self.allocator.dupe(TaskId, t.users.items);
            }
        }
        state.pool.release(need);
        const ns: u64 = @intCast(@max(c.finished_ns - c.started_ns, 0));
        if (state.options.trace) {
            try state.report.trace.append(self.allocator, .{
                .id = c.id,
                .kind = kind,
                .dispatched_ns = dispatched_ns,
                .started_ns = c.started_ns,
                .finished_ns = c.finished_ns,
                .thread_slot = c.thread_slot,
                .result = if (c.err != null) .failed else if (c.result == .yield) .yield else .done,
            });
        }
        if (c.err) |err| {
            try state.report.bumpKind(self.allocator, kind, ns, false);
            {
                state.graph.lock.lock();
                defer state.graph.lock.unlock();
                state.graph.tasks.items[c.id].state = .failed;
            }
            state.report.failed += 1;
            if (state.report.first_error == null) state.report.first_error = err;
            try self.cascadeCancel(state, c.id);
            if (!state.options.continue_on_error) state.stop_dispatch = true;
            return;
        }
        switch (c.result) {
            .yield => {
                try state.report.bumpKind(self.allocator, kind, ns, true);
                state.report.yields += 1;
                state.graph.lock.lock();
                const t = &state.graph.tasks.items[c.id];
                t.yields += 1;
                t.state = .ready;
                state.graph.lock.unlock();
                try state.pushReadyLocked(c.id);
            },
            .done => {
                try state.report.bumpKind(self.allocator, kind, ns, false);
                state.report.finished += 1;
                for (users_copy) |u| {
                    const now_ready = blk: {
                        state.graph.lock.lock();
                        defer state.graph.lock.unlock();
                        const ut = &state.graph.tasks.items[u];
                        if (ut.state != .pending) break :blk false;
                        ut.remaining_deps -= 1;
                        if (ut.remaining_deps == 0) {
                            ut.state = .ready;
                            break :blk true;
                        }
                        break :blk false;
                    };
                    if (now_ready) try state.pushReadyLocked(u);
                }
            },
        }
    }

    fn cascadeCancel(self: *Scheduler, state: *RunState, failed_id: TaskId) !void {
        var stack = std.ArrayList(TaskId).empty;
        defer stack.deinit(self.allocator);
        state.graph.lock.lock();
        defer state.graph.lock.unlock();
        try stack.appendSlice(self.allocator, state.graph.tasks.items[failed_id].users.items);
        while (stack.pop()) |id| {
            const t = &state.graph.tasks.items[id];
            switch (t.state) {
                .pending, .ready => {
                    t.state = .cancelled;
                    state.report.cancelled += 1;
                    try stack.appendSlice(self.allocator, t.users.items);
                },
                else => {},
            }
        }
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const TestExec = struct {
    order: std.ArrayList(TaskId) = .empty,
    lock: sync.Mutex = .{},
    inside: u32 = 0,
    max_inside: u32 = 0,
    yield_until: u32 = 0,
    yields_seen: u32 = 0,
    add_child_on: ?TaskId = null,
    added: ?TaskId = null,
    sleep_ns: u64 = 0,

    fn run(ctx: *anyopaque, graph: *Graph, id: TaskId, desc: TaskDesc) anyerror!RunResult {
        const self: *TestExec = @ptrCast(@alignCast(ctx));
        self.lock.lock();
        self.inside += 1;
        self.max_inside = @max(self.max_inside, self.inside);
        self.lock.unlock();
        defer {
            self.lock.lock();
            self.inside -= 1;
            self.lock.unlock();
        }
        if (self.sleep_ns != 0) sleepNs(self.sleep_ns);
        if (desc.kind == 99) {
            self.lock.lock();
            defer self.lock.unlock();
            if (self.yields_seen < self.yield_until) {
                self.yields_seen += 1;
                return .yield;
            }
        }
        if (desc.kind == 7) return error.TaskBoom;
        if (self.add_child_on != null and self.add_child_on.? == id) {
            const child = try graph.addTaskWithDeps(.{ .kind = 42 }, &.{id});
            self.lock.lock();
            self.added = child;
            self.lock.unlock();
        }
        self.lock.lock();
        defer self.lock.unlock();
        try self.order.append(std.testing.allocator, id);
        return .done;
    }

    fn deinit(self: *TestExec) void {
        self.order.deinit(std.testing.allocator);
    }
};

test "scheduler runs linear graph in dependency order" {
    var g = Graph.init(std.testing.allocator);
    defer g.deinit();
    const a = try g.addTask(.{ .kind = 1, .need = .{ .io_read = 1 } });
    const b = try g.addTaskWithDeps(.{ .kind = 2, .need = .{ .cpu = 1 } }, &.{a});
    const c = try g.addTaskWithDeps(.{ .kind = 3, .need = .{ .db_write_shard = 0 } }, &.{b});
    var exec: TestExec = .{};
    defer exec.deinit();
    var s = try Scheduler.init(std.testing.allocator, .{ .cpu = 2, .worker_threads = 2 });
    defer s.deinit();
    var rep = try s.run(&g, .{ .context = &exec, .run = TestExec.run }, .{});
    defer rep.deinit(std.testing.allocator);
    try std.testing.expectEqualSlices(TaskId, &.{ a, b, c }, exec.order.items);
    try std.testing.expectEqual(@as(u32, 3), rep.finished);
    try std.testing.expectEqual(TaskState.finished, g.state(c));
}

const TaskState = graph_mod.TaskState;

test "scheduler enforces budgets and runs independent tasks concurrently" {
    var g = Graph.init(std.testing.allocator);
    defer g.deinit();
    var i: u32 = 0;
    while (i < 6) : (i += 1) _ = try g.addTask(.{ .kind = 1, .need = .{ .cpu = 1, .mem_bytes = 4 } });
    var exec: TestExec = .{ .sleep_ns = 2_000_000 };
    defer exec.deinit();
    var s = try Scheduler.init(std.testing.allocator, .{ .cpu = 3, .mem_bytes = 8, .worker_threads = 4 });
    defer s.deinit();
    var rep = try s.run(&g, .{ .context = &exec, .run = TestExec.run }, .{});
    defer rep.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u32, 6), rep.finished);
    try std.testing.expect(rep.max_running <= 2); // mem: 8 / 4
    try std.testing.expect(rep.max_mem_bytes <= 8);
    try std.testing.expect(exec.max_inside >= 1);
}

test "scheduler respects per shard write token and pack exclusive" {
    var g = Graph.init(std.testing.allocator);
    defer g.deinit();
    const w1 = try g.addTask(.{ .kind = 1, .need = .{ .db_write_shard = 0, .pack_shared = true, .pack_id = 5 } });
    const w2 = try g.addTask(.{ .kind = 1, .need = .{ .db_write_shard = 0, .pack_shared = true, .pack_id = 5 } });
    const w3 = try g.addTask(.{ .kind = 1, .need = .{ .db_write_shard = 1, .pack_shared = true, .pack_id = 5 } });
    const x = try g.addTaskWithDeps(.{ .kind = 1, .need = .{ .pack_exclusive = true, .pack_id = 5 } }, &.{ w1, w2, w3 });
    var exec: TestExec = .{ .sleep_ns = 1_000_000 };
    defer exec.deinit();
    var s = try Scheduler.init(std.testing.allocator, .{ .cpu = 4, .worker_threads = 4 });
    defer s.deinit();
    var rep = try s.run(&g, .{ .context = &exec, .run = TestExec.run }, .{});
    defer rep.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u32, 4), rep.finished);
    try std.testing.expectEqual(x, exec.order.items[3]);
    try std.testing.expect(rep.max_running <= 2);
}

test "scheduler failure cancels users and reports error" {
    var g = Graph.init(std.testing.allocator);
    defer g.deinit();
    const a = try g.addTask(.{ .kind = 7 });
    const b = try g.addTaskWithDeps(.{ .kind = 1 }, &.{a});
    const c = try g.addTaskWithDeps(.{ .kind = 1 }, &.{b});
    var exec: TestExec = .{};
    defer exec.deinit();
    var s = try Scheduler.init(std.testing.allocator, .{ .cpu = 1, .worker_threads = 1 });
    defer s.deinit();
    try std.testing.expectError(error.TaskBoom, s.run(&g, .{ .context = &exec, .run = TestExec.run }, .{}));
    try std.testing.expectEqual(TaskState.failed, g.state(a));
    try std.testing.expectEqual(TaskState.cancelled, g.state(b));
    try std.testing.expectEqual(TaskState.cancelled, g.state(c));
}

test "scheduler injected failure hook" {
    var g = Graph.init(std.testing.allocator);
    defer g.deinit();
    const a = try g.addTask(.{ .kind = 1 });
    _ = try g.addTaskWithDeps(.{ .kind = 1 }, &.{a});
    var exec: TestExec = .{};
    defer exec.deinit();
    var s = try Scheduler.init(std.testing.allocator, .{ .cpu = 1, .worker_threads = 1 });
    defer s.deinit();
    try std.testing.expectError(error.InjectedFailure, s.run(&g, .{ .context = &exec, .run = TestExec.run }, .{ .fail_task = a }));
}

test "scheduler yields requeue and dynamic tasks are picked up" {
    var g = Graph.init(std.testing.allocator);
    defer g.deinit();
    const y = try g.addTask(.{ .kind = 99 });
    const parent = try g.addTask(.{ .kind = 1 });
    var exec: TestExec = .{ .yield_until = 3, .add_child_on = parent };
    defer exec.deinit();
    var s = try Scheduler.init(std.testing.allocator, .{ .cpu = 2, .worker_threads = 2 });
    defer s.deinit();
    var rep = try s.run(&g, .{ .context = &exec, .run = TestExec.run }, .{ .trace = true });
    defer rep.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u32, 3), rep.yields);
    try std.testing.expectEqual(@as(u32, 3), rep.finished);
    try std.testing.expect(exec.added != null);
    try std.testing.expectEqual(TaskState.finished, g.state(exec.added.?));
    try std.testing.expectEqual(TaskState.finished, g.state(y));
    try std.testing.expectEqual(@as(u32, 3), rep.kindStat(99).?.yields);
    try std.testing.expect(rep.trace.items.len >= 6);
}

test "scheduler reports deadlock when need exceeds budget" {
    var g = Graph.init(std.testing.allocator);
    defer g.deinit();
    _ = try g.addTask(.{ .kind = 1, .need = .{ .mem_bytes = 1 << 40 } });
    var exec: TestExec = .{};
    defer exec.deinit();
    var s = try Scheduler.init(std.testing.allocator, .{ .cpu = 1, .worker_threads = 1 });
    defer s.deinit();
    try std.testing.expectError(error.NeedExceedsBudget, s.run(&g, .{ .context = &exec, .run = TestExec.run }, .{}));
}

test "scheduler safely retires completion signals across repeated windows" {
    const Noop = struct {
        calls: std.atomic.Value(usize) = .init(0),
        fn run(ctx: *anyopaque, _: *Graph, _: TaskId, _: TaskDesc) anyerror!RunResult {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            _ = self.calls.fetchAdd(1, .monotonic);
            return .done;
        }
    };
    for ([_]u8{ 1, 4 }) |workers| {
        var scheduler = try Scheduler.init(std.testing.allocator, .{ .cpu = workers, .worker_threads = workers });
        defer scheduler.deinit();
        var exec: Noop = .{};
        for (0..1000) |window| {
            var graph = Graph.init(std.testing.allocator);
            defer graph.deinit();
            const count = 1 + window % 8;
            for (0..count) |_| _ = try graph.addTask(.{ .kind = 1, .need = .{ .cpu = 1 } });
            const fail = window % 17 == 0;
            if (fail) {
                try std.testing.expectError(error.InjectedFailure, scheduler.run(&graph, .{ .context = &exec, .run = Noop.run }, .{ .fail_task = 0 }));
            } else {
                var report = try scheduler.run(&graph, .{ .context = &exec, .run = Noop.run }, .{});
                defer report.deinit(std.testing.allocator);
                try std.testing.expectEqual(@as(u32, @intCast(count)), report.finished);
            }
            // The next iteration immediately reuses the same run stack,
            // releases graph/report allocations and admits another window.
        }
        try std.testing.expect(exec.calls.load(.monotonic) > 1000);
    }
}

const AllocationFailureObservation = struct { started: u32 = 0 };

fn exerciseSchedulerAllocationFailure(allocator: std.mem.Allocator, observation: *AllocationFailureObservation) !void {
    const Exec = struct {
        active: std.atomic.Value(u32) = .init(0),
        started: std.atomic.Value(u32) = .init(0),
        fn run(ctx: *anyopaque, _: *Graph, _: TaskId, _: TaskDesc) anyerror!RunResult {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            _ = self.active.fetchAdd(1, .acq_rel);
            _ = self.started.fetchAdd(1, .monotonic);
            defer _ = self.active.fetchSub(1, .acq_rel);
            // Keep submitted jobs in flight while later dispatcher bookkeeping
            // allocations fail. Executor itself makes no allocator calls.
            sleepNs(1_000_000);
            return .done;
        }
    };
    var graph = Graph.init(std.testing.allocator);
    defer graph.deinit();
    for (0..8) |_| {
        const first = try graph.addTask(.{ .kind = 1, .need = .{ .cpu = 1 } });
        _ = try graph.addTaskWithDeps(.{ .kind = 2, .need = .{ .cpu = 1 } }, &.{first});
    }
    var scheduler = try Scheduler.init(allocator, .{ .cpu = 4, .worker_threads = 4 });
    defer scheduler.deinit();
    var exec: Exec = .{};
    defer observation.started = exec.started.load(.acquire);
    var report = scheduler.run(&graph, .{ .context = &exec, .run = Exec.run }, .{}) catch |err| {
        try std.testing.expectEqual(@as(u32, 0), exec.active.load(.acquire));
        return err;
    };
    defer report.deinit(allocator);
    try std.testing.expectEqual(@as(u32, 0), exec.active.load(.acquire));
    try std.testing.expectEqual(@as(u32, 16), report.finished);
}

test "scheduler allocation failures drain submitted jobs before returning" {
    var baseline = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    var observation: AllocationFailureObservation = .{};
    try exerciseSchedulerAllocationFailure(baseline.allocator(), &observation);
    try std.testing.expectEqual(baseline.allocated_bytes, baseline.freed_bytes);
    var failed_after_start = false;
    // Worker dequeue timing can change queue-capacity allocation counts.
    // Sweep the observed count plus headroom, allowing non-induced success;
    // this is failure-index coverage, not a deterministic allocation trace.
    for (0..baseline.alloc_index + 16) |fail_index| {
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = fail_index });
        observation = .{};
        if (exerciseSchedulerAllocationFailure(failing.allocator(), &observation)) |_| {
            try std.testing.expect(!failing.has_induced_failure);
        } else |err| {
            try std.testing.expectEqual(error.OutOfMemory, err);
            try std.testing.expect(failing.has_induced_failure);
            if (observation.started != 0) failed_after_start = true;
        }
        try std.testing.expectEqual(failing.allocated_bytes, failing.freed_bytes);
    }
    try std.testing.expect(failed_after_start);
}
