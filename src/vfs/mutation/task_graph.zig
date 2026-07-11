const std = @import("std");

pub const TaskId = u64;

pub const TaskType = enum {
    read_source,
    hash_page,
    compress_page,
    write_page_kv,
    write_file_manifest,
    write_entry_tombstone,
    update_path_index,
    update_pack_manifest,
    verify_pack,
    flush_pack,
};

pub const TaskState = enum {
    pending,
    ready,
    running,
    finished,
    failed,
    cancelled,
};

pub const ResourceNeed = struct {
    disk_read_tasks: u32 = 0,
    disk_write_tasks: u32 = 0,
    hash_tasks: u32 = 0,
    compress_tasks: u32 = 0,
    db_write_tasks: u32 = 0,
    memory_bytes: u64 = 0,
    pack_exclusive: bool = false,
    pack_shared: bool = false,
};

pub const Task = struct {
    id: TaskId,
    task_type: TaskType,
    pack_id: u64 = 0,
    file_entry: u64 = 0,
    page_index: u32 = 0,
    resources: ResourceNeed = .{},
    deps: std.ArrayList(TaskId) = .empty,
    users: std.ArrayList(TaskId) = .empty,
    state: TaskState = .pending,
};

pub const ResourceTaskGraph = struct {
    tasks: std.ArrayList(Task) = .empty,
    next_id: TaskId = 1,

    pub fn deinit(self: *ResourceTaskGraph, allocator: std.mem.Allocator) void {
        for (self.tasks.items) |*task| {
            task.deps.deinit(allocator);
            task.users.deinit(allocator);
        }
        self.tasks.deinit(allocator);
        self.* = .{};
    }

    pub fn addTask(self: *ResourceTaskGraph, allocator: std.mem.Allocator, task_type: TaskType, pack_id: u64, file_entry: u64, resources: ResourceNeed) !TaskId {
        return self.addPageTask(allocator, task_type, pack_id, file_entry, 0, resources);
    }

    pub fn addPageTask(self: *ResourceTaskGraph, allocator: std.mem.Allocator, task_type: TaskType, pack_id: u64, file_entry: u64, page_index: u32, resources: ResourceNeed) !TaskId {
        const id = self.next_id;
        self.next_id += 1;
        try self.tasks.append(allocator, .{
            .id = id,
            .task_type = task_type,
            .pack_id = pack_id,
            .file_entry = file_entry,
            .page_index = page_index,
            .resources = resources,
        });
        return id;
    }

    pub fn addDependency(self: *ResourceTaskGraph, allocator: std.mem.Allocator, before: TaskId, after: TaskId) !void {
        const before_i = self.indexOf(before) orelse return error.InvalidArgument;
        const after_i = self.indexOf(after) orelse return error.InvalidArgument;
        try self.tasks.items[after_i].deps.append(allocator, before);
        try self.tasks.items[before_i].users.append(allocator, after);
    }

    pub fn indexOf(self: *const ResourceTaskGraph, id: TaskId) ?usize {
        for (self.tasks.items, 0..) |task, i| if (task.id == id) return i;
        return null;
    }

    pub fn resetStates(self: *ResourceTaskGraph) void {
        for (self.tasks.items) |*task| task.state = .pending;
    }
};

test "task graph records dependencies" {
    var graph: ResourceTaskGraph = .{};
    defer graph.deinit(std.testing.allocator);
    const a = try graph.addTask(std.testing.allocator, .read_source, 1, 10, .{});
    const b = try graph.addTask(std.testing.allocator, .hash_page, 1, 10, .{});
    try graph.addDependency(std.testing.allocator, a, b);
    try std.testing.expectEqual(@as(usize, 1), graph.tasks.items[1].deps.items.len);
}
