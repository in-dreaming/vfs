const std = @import("std");
const task_graph = @import("task_graph.zig");
const budget_mod = @import("resource_budget.zig");

pub const RunOptions = struct {
    fail_task_id: ?task_graph.TaskId = null,
    worker_count: u32 = 0,
};

pub const Executor = struct {
    context: *anyopaque,
    runTask: *const fn (context: *anyopaque, task: task_graph.Task) anyerror!void,
};

pub const RunReport = struct {
    dispatch_order: std.ArrayList(task_graph.TaskId) = .empty,
    finished_count: u32 = 0,
    failed_count: u32 = 0,
    cancelled_count: u32 = 0,
    max_disk_read_tasks: u32 = 0,
    max_disk_write_tasks: u32 = 0,
    max_hash_tasks: u32 = 0,
    max_compress_tasks: u32 = 0,
    max_db_write_tasks: u32 = 0,
    max_inflight_memory_bytes: u64 = 0,
    max_pack_exclusive_tasks: u32 = 0,

    pub fn deinit(self: *RunReport, allocator: std.mem.Allocator) void {
        self.dispatch_order.deinit(allocator);
        self.* = .{};
    }
};

const ResourceUse = struct {
    disk_read_tasks: u32 = 0,
    disk_write_tasks: u32 = 0,
    hash_tasks: u32 = 0,
    compress_tasks: u32 = 0,
    db_write_tasks: u32 = 0,
    memory_bytes: u64 = 0,
    pack_exclusive_tasks: u32 = 0,
};

const PackSharedUse = struct {
    pack_id: u64,
    count: u32,
};

pub fn run(allocator: std.mem.Allocator, graph: *task_graph.ResourceTaskGraph, budget: budget_mod.ResourceBudget, options: RunOptions) !RunReport {
    return runWithExecutor(allocator, graph, budget, options, null);
}

pub fn runWithExecutor(allocator: std.mem.Allocator, graph: *task_graph.ResourceTaskGraph, budget: budget_mod.ResourceBudget, options: RunOptions, executor: ?Executor) !RunReport {
    try budget.validate();
    graph.resetStates();
    var report: RunReport = .{};
    errdefer report.deinit(allocator);
    var pool = try ThreadPool.init(allocator, workerCount(options, budget), executor);
    defer pool.deinit();
    var running_use: ResourceUse = .{};
    var running_shared = std.ArrayList(PackSharedUse).empty;
    defer running_shared.deinit(allocator);
    var running_exclusive = std.AutoHashMap(u64, void).init(allocator);
    defer running_exclusive.deinit();
    var running_count: usize = 0;

    while (true) {
        markReady(graph);
        if (allTerminal(graph)) break;

        var dispatched = false;
        for (graph.tasks.items, 0..) |task, i| {
            if (task.state != .ready) continue;
            if (!canAcquire(task, budget, running_use, &running_shared, &running_exclusive)) continue;
            try acquire(allocator, task, &running_use, &running_shared, &running_exclusive);
            updateMax(&report, running_use);
            graph.tasks.items[i].state = .running;
            try report.dispatch_order.append(allocator, graph.tasks.items[i].id);
            dispatched = true;
            if (options.fail_task_id != null and graph.tasks.items[i].id == options.fail_task_id.?) {
                release(allocator, graph.tasks.items[i], &running_use, &running_shared, &running_exclusive);
                graph.tasks.items[i].state = .failed;
                report.failed_count += 1;
                try cancelUsers(graph, graph.tasks.items[i].id, &report);
                continue;
            }
            try pool.submit(i, graph.tasks.items[i]);
            running_count += 1;
        }
        if (dispatched) continue;
        if (running_count == 0) return error.ResourceDeadlock;

        const done = try pool.waitCompletion();
        running_count -= 1;
        release(allocator, graph.tasks.items[done.task_index], &running_use, &running_shared, &running_exclusive);
        if (done.err) |err| {
            graph.tasks.items[done.task_index].state = .failed;
            report.failed_count += 1;
            try cancelUsers(graph, graph.tasks.items[done.task_index].id, &report);
            return err;
        } else {
            if (graph.tasks.items[done.task_index].state == .running) {
                graph.tasks.items[done.task_index].state = .finished;
                report.finished_count += 1;
            }
        }
    }
    return report;
}

fn workerCount(options: RunOptions, budget: budget_mod.ResourceBudget) u32 {
    if (options.worker_count != 0) return options.worker_count;
    return @max(@as(u32, 1), @min(@as(u32, 32), budget.max_disk_read_tasks + budget.max_disk_write_tasks + budget.max_hash_tasks + budget.max_compress_tasks + budget.max_db_write_tasks + budget.max_pack_exclusive_tasks));
}

const Job = struct {
    task_index: usize,
    task: task_graph.Task,
};

const Completion = struct {
    task_index: usize,
    err: ?anyerror = null,
};

const ThreadPool = struct {
    allocator: std.mem.Allocator,
    state: *PoolState,
    threads: []std.Thread = &.{},

    fn init(allocator: std.mem.Allocator, count: u32, executor: ?Executor) !ThreadPool {
        const state = try allocator.create(PoolState);
        errdefer allocator.destroy(state);
        state.* = .{ .allocator = allocator, .executor = executor };
        var pool: ThreadPool = .{ .allocator = allocator, .state = state };
        pool.threads = try allocator.alloc(std.Thread, count);
        errdefer allocator.free(pool.threads);
        var started: usize = 0;
        errdefer {
            pool.state.mutex.lockUncancelable(pool.state.io);
            pool.state.stopping = true;
            pool.state.mutex.unlock(pool.state.io);
            for (pool.threads[0..started]) |_| pool.state.job_sem.post(pool.state.io);
            for (pool.threads[0..started]) |thread| thread.join();
            pool.state.jobs.deinit(allocator);
            pool.state.completions.deinit(allocator);
        }
        while (started < count) : (started += 1) {
            pool.threads[started] = try std.Thread.spawn(.{}, workerMain, .{pool.state});
        }
        return pool;
    }

    fn deinit(self: *ThreadPool) void {
        self.state.mutex.lockUncancelable(self.state.io);
        self.state.stopping = true;
        self.state.mutex.unlock(self.state.io);
        for (self.threads) |_| self.state.job_sem.post(self.state.io);
        for (self.threads) |thread| thread.join();
        self.allocator.free(self.threads);
        self.state.jobs.deinit(self.allocator);
        self.state.completions.deinit(self.allocator);
        self.allocator.destroy(self.state);
        self.* = undefined;
    }

    fn submit(self: *ThreadPool, task_index: usize, task: task_graph.Task) !void {
        self.state.mutex.lockUncancelable(self.state.io);
        defer self.state.mutex.unlock(self.state.io);
        try self.state.completions.ensureUnusedCapacity(self.allocator, 1);
        try self.state.jobs.append(self.allocator, .{ .task_index = task_index, .task = task });
        self.state.job_sem.post(self.state.io);
    }

    fn waitCompletion(self: *ThreadPool) !Completion {
        self.state.completion_sem.waitUncancelable(self.state.io);
        self.state.mutex.lockUncancelable(self.state.io);
        defer self.state.mutex.unlock(self.state.io);
        return self.state.completions.orderedRemove(0);
    }
};

const PoolState = struct {
    allocator: std.mem.Allocator,
    executor: ?Executor,
    io: std.Io = std.Io.Threaded.global_single_threaded.io(),
    mutex: std.Io.Mutex = .init,
    job_sem: std.Io.Semaphore = .{},
    completion_sem: std.Io.Semaphore = .{},
    jobs: std.ArrayList(Job) = .empty,
    completions: std.ArrayList(Completion) = .empty,
    stopping: bool = false,
};

fn workerMain(state: *PoolState) void {
    while (true) {
        const job = takeJob(state) orelse return;
        var completion: Completion = .{ .task_index = job.task_index };
        if (state.executor) |exec| {
            exec.runTask(exec.context, job.task) catch |err| {
                completion.err = err;
            };
        }
        state.mutex.lockUncancelable(state.io);
        state.completions.appendAssumeCapacity(completion);
        state.mutex.unlock(state.io);
        state.completion_sem.post(state.io);
    }
}

fn takeJob(state: *PoolState) ?Job {
    while (true) {
        state.job_sem.waitUncancelable(state.io);
        state.mutex.lockUncancelable(state.io);
        if (state.jobs.items.len != 0) {
            const job = state.jobs.orderedRemove(0);
            state.mutex.unlock(state.io);
            return job;
        }
        if (state.stopping) {
            state.mutex.unlock(state.io);
            return null;
        }
        state.mutex.unlock(state.io);
    }
}

fn lockMutex(m: *std.atomic.Mutex) void {
    while (!m.tryLock()) std.atomic.spinLoopHint();
}

fn markReady(graph: *task_graph.ResourceTaskGraph) void {
    for (graph.tasks.items) |*task| {
        if (task.state != .pending) continue;
        var ready = true;
        for (task.deps.items) |dep| {
            const i = graph.indexOf(dep) orelse {
                ready = false;
                break;
            };
            if (graph.tasks.items[i].state != .finished) {
                ready = false;
                break;
            }
        }
        if (ready) task.state = .ready;
    }
}

fn allTerminal(graph: *const task_graph.ResourceTaskGraph) bool {
    for (graph.tasks.items) |task| switch (task.state) {
        .finished, .failed, .cancelled => {},
        else => return false,
    };
    return true;
}

fn canAcquire(task: task_graph.Task, budget: budget_mod.ResourceBudget, use: ResourceUse, shared: *std.ArrayList(PackSharedUse), exclusive: *std.AutoHashMap(u64, void)) bool {
    const r = task.resources;
    if (use.disk_read_tasks + r.disk_read_tasks > budget.max_disk_read_tasks) return false;
    if (use.disk_write_tasks + r.disk_write_tasks > budget.max_disk_write_tasks) return false;
    if (use.hash_tasks + r.hash_tasks > budget.max_hash_tasks) return false;
    if (use.compress_tasks + r.compress_tasks > budget.max_compress_tasks) return false;
    if (use.db_write_tasks + r.db_write_tasks > budget.max_db_write_tasks) return false;
    if (use.memory_bytes + r.memory_bytes > budget.max_inflight_memory_bytes) return false;
    if (r.pack_exclusive and use.pack_exclusive_tasks + 1 > budget.max_pack_exclusive_tasks) return false;
    if (task.pack_id != 0) {
        if (r.pack_exclusive and (sharedCount(shared, task.pack_id) != 0 or exclusive.contains(task.pack_id))) return false;
        if (r.pack_shared and exclusive.contains(task.pack_id)) return false;
    }
    return true;
}

fn acquire(allocator: std.mem.Allocator, task: task_graph.Task, use: *ResourceUse, shared: *std.ArrayList(PackSharedUse), exclusive: *std.AutoHashMap(u64, void)) !void {
    const r = task.resources;
    use.disk_read_tasks += r.disk_read_tasks;
    use.disk_write_tasks += r.disk_write_tasks;
    use.hash_tasks += r.hash_tasks;
    use.compress_tasks += r.compress_tasks;
    use.db_write_tasks += r.db_write_tasks;
    use.memory_bytes += r.memory_bytes;
    if (r.pack_exclusive) {
        use.pack_exclusive_tasks += 1;
        try exclusive.put(task.pack_id, {});
    }
    if (r.pack_shared) try addShared(allocator, shared, task.pack_id);
}

fn release(allocator: std.mem.Allocator, task: task_graph.Task, use: *ResourceUse, shared: *std.ArrayList(PackSharedUse), exclusive: *std.AutoHashMap(u64, void)) void {
    const r = task.resources;
    use.disk_read_tasks -= r.disk_read_tasks;
    use.disk_write_tasks -= r.disk_write_tasks;
    use.hash_tasks -= r.hash_tasks;
    use.compress_tasks -= r.compress_tasks;
    use.db_write_tasks -= r.db_write_tasks;
    use.memory_bytes -= r.memory_bytes;
    if (r.pack_exclusive) {
        use.pack_exclusive_tasks -= 1;
        _ = exclusive.remove(task.pack_id);
    }
    if (r.pack_shared) removeShared(shared, task.pack_id);
    _ = allocator;
}

fn sharedCount(shared: *std.ArrayList(PackSharedUse), pack_id: u64) u32 {
    for (shared.items) |item| if (item.pack_id == pack_id) return item.count;
    return 0;
}

fn addShared(allocator: std.mem.Allocator, shared: *std.ArrayList(PackSharedUse), pack_id: u64) !void {
    for (shared.items) |*item| {
        if (item.pack_id == pack_id) {
            item.count += 1;
            return;
        }
    }
    try shared.append(allocator, .{ .pack_id = pack_id, .count = 1 });
}

fn removeShared(shared: *std.ArrayList(PackSharedUse), pack_id: u64) void {
    for (shared.items, 0..) |*item, i| {
        if (item.pack_id != pack_id) continue;
        item.count -= 1;
        if (item.count == 0) _ = shared.swapRemove(i);
        return;
    }
}

fn updateMax(report: *RunReport, use: ResourceUse) void {
    report.max_disk_read_tasks = @max(report.max_disk_read_tasks, use.disk_read_tasks);
    report.max_disk_write_tasks = @max(report.max_disk_write_tasks, use.disk_write_tasks);
    report.max_hash_tasks = @max(report.max_hash_tasks, use.hash_tasks);
    report.max_compress_tasks = @max(report.max_compress_tasks, use.compress_tasks);
    report.max_db_write_tasks = @max(report.max_db_write_tasks, use.db_write_tasks);
    report.max_inflight_memory_bytes = @max(report.max_inflight_memory_bytes, use.memory_bytes);
    report.max_pack_exclusive_tasks = @max(report.max_pack_exclusive_tasks, use.pack_exclusive_tasks);
}

fn cancelUsers(graph: *task_graph.ResourceTaskGraph, failed_id: task_graph.TaskId, report: *RunReport) !void {
    const i = graph.indexOf(failed_id) orelse return error.InvalidArgument;
    for (graph.tasks.items[i].users.items) |user| try cancelRecursive(graph, user, report);
}

fn cancelRecursive(graph: *task_graph.ResourceTaskGraph, id: task_graph.TaskId, report: *RunReport) !void {
    const i = graph.indexOf(id) orelse return error.InvalidArgument;
    if (graph.tasks.items[i].state == .cancelled) return;
    if (graph.tasks.items[i].state == .finished or graph.tasks.items[i].state == .failed) return;
    graph.tasks.items[i].state = .cancelled;
    report.cancelled_count += 1;
    for (graph.tasks.items[i].users.items) |user| try cancelRecursive(graph, user, report);
}

test "scheduler runs linear graph in dependency order" {
    var graph: task_graph.ResourceTaskGraph = .{};
    defer graph.deinit(std.testing.allocator);
    const a = try graph.addTask(std.testing.allocator, .read_source, 1, 1, .{ .disk_read_tasks = 1, .pack_shared = true });
    const b = try graph.addTask(std.testing.allocator, .hash_page, 1, 1, .{ .hash_tasks = 1, .memory_bytes = 4 });
    const c = try graph.addTask(std.testing.allocator, .write_page_kv, 1, 1, .{ .disk_write_tasks = 1, .db_write_tasks = 1, .pack_shared = true });
    try graph.addDependency(std.testing.allocator, a, b);
    try graph.addDependency(std.testing.allocator, b, c);
    var report = try run(std.testing.allocator, &graph, .{}, .{});
    defer report.deinit(std.testing.allocator);
    try std.testing.expectEqualSlices(task_graph.TaskId, &.{ a, b, c }, report.dispatch_order.items);
}

test "scheduler enforces hash compress db memory and pack exclusive budgets" {
    var graph: task_graph.ResourceTaskGraph = .{};
    defer graph.deinit(std.testing.allocator);
    const h1 = try graph.addTask(std.testing.allocator, .hash_page, 1, 1, .{ .hash_tasks = 1, .memory_bytes = 5, .pack_shared = true });
    const h2 = try graph.addTask(std.testing.allocator, .hash_page, 1, 2, .{ .hash_tasks = 1, .memory_bytes = 5, .pack_shared = true });
    const h3 = try graph.addTask(std.testing.allocator, .hash_page, 1, 3, .{ .hash_tasks = 1, .memory_bytes = 5, .pack_shared = true });
    const c1 = try graph.addTask(std.testing.allocator, .compress_page, 1, 1, .{ .compress_tasks = 1, .memory_bytes = 5, .pack_shared = true });
    const c2 = try graph.addTask(std.testing.allocator, .compress_page, 1, 2, .{ .compress_tasks = 1, .memory_bytes = 5, .pack_shared = true });
    const w1 = try graph.addTask(std.testing.allocator, .write_page_kv, 1, 1, .{ .db_write_tasks = 1, .disk_write_tasks = 1, .pack_shared = true });
    const w2 = try graph.addTask(std.testing.allocator, .write_page_kv, 1, 2, .{ .db_write_tasks = 1, .disk_write_tasks = 1, .pack_shared = true });
    const x = try graph.addTask(std.testing.allocator, .update_pack_manifest, 1, 0, .{ .pack_exclusive = true, .db_write_tasks = 1 });
    const shared_ids = [_]task_graph.TaskId{ h1, h2, h3, c1, c2, w1, w2 };
    for (&shared_ids) |id| try graph.addDependency(std.testing.allocator, id, x);
    var report = try run(std.testing.allocator, &graph, .{ .max_hash_tasks = 2, .max_compress_tasks = 1, .max_db_write_tasks = 1, .max_disk_write_tasks = 1, .max_inflight_memory_bytes = 10 }, .{});
    defer report.deinit(std.testing.allocator);
    try std.testing.expect(report.max_hash_tasks <= 2);
    try std.testing.expect(report.max_hash_tasks > 1);
    try std.testing.expect(report.max_compress_tasks <= 1);
    try std.testing.expect(report.max_db_write_tasks <= 1);
    try std.testing.expect(report.max_inflight_memory_bytes <= 10);
    try std.testing.expectEqual(x, report.dispatch_order.items[report.dispatch_order.items.len - 1]);
}

test "scheduler failure cancels dependent tasks" {
    var graph: task_graph.ResourceTaskGraph = .{};
    defer graph.deinit(std.testing.allocator);
    const a = try graph.addTask(std.testing.allocator, .read_source, 1, 1, .{ .disk_read_tasks = 1 });
    const b = try graph.addTask(std.testing.allocator, .write_file_manifest, 1, 1, .{ .db_write_tasks = 1 });
    try graph.addDependency(std.testing.allocator, a, b);
    var report = try run(std.testing.allocator, &graph, .{}, .{ .fail_task_id = a });
    defer report.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u32, 1), report.failed_count);
    try std.testing.expectEqual(@as(u32, 1), report.cancelled_count);
}

test "scheduler executes ready tasks on worker pool concurrently" {
    var graph: task_graph.ResourceTaskGraph = .{};
    defer graph.deinit(std.testing.allocator);
    _ = try graph.addTask(std.testing.allocator, .hash_page, 1, 1, .{ .hash_tasks = 1, .memory_bytes = 1, .pack_shared = true });
    _ = try graph.addTask(std.testing.allocator, .hash_page, 1, 2, .{ .hash_tasks = 1, .memory_bytes = 1, .pack_shared = true });

    var barrier: BarrierExecutor = .{ .target = 2 };
    var report = try runWithExecutor(
        std.testing.allocator,
        &graph,
        .{ .max_hash_tasks = 2, .max_inflight_memory_bytes = 2 },
        .{ .worker_count = 2 },
        .{ .context = &barrier, .runTask = BarrierExecutor.runTask },
    );
    defer report.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u32, 2), report.finished_count);
    try std.testing.expectEqual(@as(u32, 2), report.max_hash_tasks);
    try std.testing.expect(barrier.max_inside >= 2);
}

test "scheduler worker pool still respects memory budget" {
    var graph: task_graph.ResourceTaskGraph = .{};
    defer graph.deinit(std.testing.allocator);
    _ = try graph.addTask(std.testing.allocator, .hash_page, 1, 1, .{ .hash_tasks = 1, .memory_bytes = 6, .pack_shared = true });
    _ = try graph.addTask(std.testing.allocator, .hash_page, 1, 2, .{ .hash_tasks = 1, .memory_bytes = 6, .pack_shared = true });

    var counter: CountingExecutor = .{};
    var report = try runWithExecutor(
        std.testing.allocator,
        &graph,
        .{ .max_hash_tasks = 2, .max_inflight_memory_bytes = 6 },
        .{ .worker_count = 2 },
        .{ .context = &counter, .runTask = CountingExecutor.runTask },
    );
    defer report.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u32, 2), report.finished_count);
    try std.testing.expectEqual(@as(u64, 6), report.max_inflight_memory_bytes);
    try std.testing.expectEqual(@as(u32, 1), counter.max_inside);
}

const BarrierExecutor = struct {
    mutex: std.atomic.Mutex = .unlocked,
    target: u32,
    inside: u32 = 0,
    max_inside: u32 = 0,
    released: bool = false,

    fn runTask(ctx: *anyopaque, _: task_graph.Task) !void {
        const self: *BarrierExecutor = @ptrCast(@alignCast(ctx));
        lockMutex(&self.mutex);
        self.inside += 1;
        self.max_inside = @max(self.max_inside, self.inside);
        if (self.inside >= self.target) {
            self.released = true;
        }
        while (!self.released) {
            self.mutex.unlock();
            std.Thread.yield() catch {};
            lockMutex(&self.mutex);
        }
        self.inside -= 1;
        self.mutex.unlock();
    }
};

const CountingExecutor = struct {
    mutex: std.atomic.Mutex = .unlocked,
    inside: u32 = 0,
    max_inside: u32 = 0,

    fn runTask(ctx: *anyopaque, _: task_graph.Task) !void {
        const self: *CountingExecutor = @ptrCast(@alignCast(ctx));
        lockMutex(&self.mutex);
        self.inside += 1;
        self.max_inside = @max(self.max_inside, self.inside);
        self.inside -= 1;
        self.mutex.unlock();
    }
};
