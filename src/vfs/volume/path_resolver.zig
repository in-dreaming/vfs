const std = @import("std");

pub const PathResolution = union(enum) {
    found: u64,
    not_found,
};

test "path resolver resolution type is explicit" {
    const r: PathResolution = .{ .found = 7 };
    try std.testing.expectEqual(@as(u64, 7), r.found);
}
