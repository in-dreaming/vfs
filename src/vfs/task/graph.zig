//! Dependency graph of tasks. Tasks are indexed by `TaskId` (dense u32),
//! dependencies are tracked with an in-degree counter plus a users list so the
//! scheduler discovers ready tasks in O(1) amortised. Tasks may be added while
//! a run is in progress; the graph notifies the attached scheduler.
const std = @import("std");
const resource = @import("resource.zig");
const sync = @import("db_internal").platform.sync;

pub const TaskId = u32;

pub const TaskState = enum(u8) {
    pending,
    ready,
    running,
    finished,
    failed,
    cancelled,
};

pub const TaskDesc = struct {
    /// Caller-defined discriminator interpreted by the executor.
    kind: u16,
    payload: ?*anyopaque = null,
    need: resource.Need = .{},
    /// Higher runs earlier within a resource class.
    priority: i32 = 0,
    /// Free-form labels for traces / debugging.
    label_file_entry: u64 = 0,
    label_index: u32 = 0,
};

pub const Task = struct {
    desc: TaskDesc,
    state: TaskState = .pending,
    remaining_deps: u32 = 0,
    users: std.ArrayList(TaskId) = .empty,
    yields: u32 = 0,
    dispatched_ns: i128 = 0,
    started_ns: i128 = 0,
    finished_ns: i128 = 0,
};

pub const Stats = struct {
    total: u32 = 0,
    pending: u32 = 0,
    ready: u32 = 0,
    running: u32 = 0,
    finished: u32 = 0,
    failed: u32 = 0,
    cancelled: u32 = 0,
};

/// Called by the graph when a task becomes ready outside the scheduler's own
/// completion handling (i.e. `addTask` with no deps during a run).
pub const Listener = struct {
    context: *anyopaque,
    onReady: *const fn (context: *anyopaque, id: TaskId) void,
};

pub const Graph = struct {
    allocator: std.mem.Allocator,
    tasks: std.ArrayList(Task) = .empty,
    lock: sync.Mutex = .{},
    listener: ?Listener = null,
    cancelled: std.atomic.Value(bool) = .init(false),

    pub fn init(allocator: std.mem.Allocator) Graph {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Graph) void {
        for (self.tasks.items) |*t| t.users.deinit(self.allocator);
        self.tasks.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn count(self: *Graph) usize {
        self.lock.lock();
        defer self.lock.unlock();
        return self.tasks.items.len;
    }

    /// Adds a task with no dependencies. Safe during a run: if a scheduler is
    /// attached it is notified immediately.
    pub fn addTask(self: *Graph, desc: TaskDesc) !TaskId {
        return self.addTaskWithDeps(desc, &.{});
    }

    /// Adds a task that depends on `deps`. Dependencies that already finished
    /// are treated as satisfied; a failed/cancelled dependency cancels the new
    /// task immediately.
    pub fn addTaskWithDeps(self: *Graph, desc: TaskDesc, deps: []const TaskId) !TaskId {
        self.lock.lock();
        var notify: ?TaskId = null;
        var listener: ?Listener = null;
        const id: TaskId = blk: {
            defer self.lock.unlock();
            const id: TaskId = @intCast(self.tasks.items.len);
            try self.tasks.append(self.allocator, .{ .desc = desc });
            var remaining: u32 = 0;
            var doomed = false;
            for (deps) |dep| {
                if (dep >= id) return error.InvalidArgument;
                const before = &self.tasks.items[dep];
                switch (before.state) {
                    .finished => {},
                    .failed, .cancelled => doomed = true,
                    else => {
                        try before.users.append(self.allocator, id);
                        remaining += 1;
                    },
                }
            }
            const task = &self.tasks.items[id];
            task.remaining_deps = remaining;
            if (doomed) {
                task.state = .cancelled;
            } else if (remaining == 0 and self.listener != null) {
                task.state = .ready;
                notify = id;
                listener = self.listener;
            }
            break :blk id;
        };
        if (notify) |ready_id| {
            const l = listener.?;
            l.onReady(l.context, ready_id);
        }
        return id;
    }

    /// `before` must complete before `after` starts. Both must exist and
    /// `after` must not have started yet.
    pub fn addDependency(self: *Graph, before: TaskId, after: TaskId) !void {
        self.lock.lock();
        defer self.lock.unlock();
        if (before >= self.tasks.items.len or after >= self.tasks.items.len or before == after) return error.InvalidArgument;
        const a = &self.tasks.items[after];
        if (a.state != .pending) return error.InvalidArgument;
        const b = &self.tasks.items[before];
        switch (b.state) {
            .finished => return,
            .failed, .cancelled => {
                a.state = .cancelled;
                return;
            },
            else => {},
        }
        try b.users.append(self.allocator, after);
        a.remaining_deps += 1;
    }

    pub fn cancel(self: *Graph) void {
        self.cancelled.store(true, .release);
    }

    pub fn isCancelled(self: *const Graph) bool {
        return self.cancelled.load(.acquire);
    }

    pub fn state(self: *Graph, id: TaskId) TaskState {
        self.lock.lock();
        defer self.lock.unlock();
        return self.tasks.items[id].state;
    }

    pub fn stats(self: *Graph) Stats {
        self.lock.lock();
        defer self.lock.unlock();
        var out: Stats = .{ .total = @intCast(self.tasks.items.len) };
        for (self.tasks.items) |t| switch (t.state) {
            .pending => out.pending += 1,
            .ready => out.ready += 1,
            .running => out.running += 1,
            .finished => out.finished += 1,
            .failed => out.failed += 1,
            .cancelled => out.cancelled += 1,
        };
        return out;
    }

    /// Resets every task to pending with its in-degree recomputed from the
    /// users lists. Used before a fresh run of a prebuilt graph.
    pub fn resetForRun(self: *Graph) void {
        self.lock.lock();
        defer self.lock.unlock();
        for (self.tasks.items) |*t| {
            t.state = .pending;
            t.remaining_deps = 0;
            t.yields = 0;
        }
        for (self.tasks.items) |t| {
            for (t.users.items) |u| self.tasks.items[u].remaining_deps += 1;
        }
    }
};

test "graph tracks in-degree and users" {
    var g = Graph.init(std.testing.allocator);
    defer g.deinit();
    const a = try g.addTask(.{ .kind = 1 });
    const b = try g.addTask(.{ .kind = 2 });
    const c = try g.addTaskWithDeps(.{ .kind = 3 }, &.{ a, b });
    try g.addDependency(a, b);
    try std.testing.expectEqual(@as(u32, 0), g.tasks.items[a].remaining_deps);
    try std.testing.expectEqual(@as(u32, 1), g.tasks.items[b].remaining_deps);
    try std.testing.expectEqual(@as(u32, 2), g.tasks.items[c].remaining_deps);
    try std.testing.expectEqual(@as(usize, 2), g.tasks.items[a].users.items.len);
    try std.testing.expectError(error.InvalidArgument, g.addDependency(c, c));
    g.resetForRun();
    try std.testing.expectEqual(@as(u32, 2), g.tasks.items[c].remaining_deps);
}
