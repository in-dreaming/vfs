const std = @import("std");

pub const FileLocation = struct {
    mount_index: usize,
    file_entry: u64,
};

pub const Resolution = union(enum) {
    found: FileLocation,
    tombstone,
    not_found,
};

test "entry resolver resolution type is explicit" {
    const r: Resolution = .{ .found = .{ .mount_index = 1, .file_entry = 2 } };
    try std.testing.expectEqual(@as(u64, 2), r.found.file_entry);
}
