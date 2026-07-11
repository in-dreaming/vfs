const std = @import("std");

pub const ResourceBudget = struct {
    max_disk_read_tasks: u32 = 4,
    max_disk_write_tasks: u32 = 2,
    max_hash_tasks: u32 = 4,
    max_compress_tasks: u32 = 4,
    max_db_write_tasks: u32 = 1,
    max_inflight_memory_bytes: u64 = 64 * 1024 * 1024,
    max_pack_exclusive_tasks: u32 = 1,

    pub fn validate(self: ResourceBudget) !void {
        if (self.max_disk_read_tasks == 0 or
            self.max_disk_write_tasks == 0 or
            self.max_hash_tasks == 0 or
            self.max_compress_tasks == 0 or
            self.max_db_write_tasks == 0 or
            self.max_pack_exclusive_tasks == 0)
        {
            return error.InvalidArgument;
        }
    }
};

test "resource budget rejects zero limits" {
    try std.testing.expectError(error.InvalidArgument, (ResourceBudget{ .max_db_write_tasks = 0 }).validate());
    try (ResourceBudget{}).validate();
}
