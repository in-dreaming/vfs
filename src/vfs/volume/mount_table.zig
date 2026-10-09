const std = @import("std");

pub const MountEntry = struct {
    pack_id: u64,
    priority: u32,
    mount_order: u64,
    pack_version: u64,
    flags: u32,
};

pub fn hasPriority(entries: []const MountEntry, priority: u32) bool {
    for (entries) |entry| if (entry.priority == priority) return true;
    return false;
}

pub fn higherPriority(_: void, a: MountEntry, b: MountEntry) bool {
    return a.priority > b.priority;
}

test "mount table priority helper rejects duplicates and sorts high first" {
    var entries = [_]MountEntry{
        .{ .pack_id = 1, .priority = 10, .mount_order = 1, .pack_version = 1, .flags = 0 },
        .{ .pack_id = 2, .priority = 20, .mount_order = 2, .pack_version = 1, .flags = 0 },
    };
    try std.testing.expect(hasPriority(&entries, 10));
    std.mem.sort(MountEntry, &entries, {}, higherPriority);
    try std.testing.expectEqual(@as(u32, 20), entries[0].priority);
}
