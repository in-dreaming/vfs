const std = @import("std");

pub fn normalizeVirtualPath(allocator: std.mem.Allocator, virtual_path: []const u8) ![]u8 {
    if (virtual_path.len == 0) return error.InvalidArgument;
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);

    var i: usize = 0;
    while (i < virtual_path.len and (virtual_path[i] == '/' or virtual_path[i] == '\\')) i += 1;
    var segment_start = i;
    while (i <= virtual_path.len) : (i += 1) {
        if (i == virtual_path.len or virtual_path[i] == '/' or virtual_path[i] == '\\') {
            const segment = virtual_path[segment_start..i];
            if (segment.len != 0) {
                if (std.mem.eql(u8, segment, ".") or std.mem.eql(u8, segment, "..")) return error.InvalidArgument;
                if (out.items.len != 0) try out.append(allocator, '/');
                try out.appendSlice(allocator, segment);
            }
            segment_start = i + 1;
        } else if (virtual_path[i] == 0) {
            return error.InvalidArgument;
        }
    }
    if (out.items.len == 0) return error.InvalidArgument;
    return out.toOwnedSlice(allocator);
}

test "path normalization strips root and rejects traversal" {
    const allocator = std.testing.allocator;
    const p = try normalizeVirtualPath(allocator, "\\assets//hero.png");
    defer allocator.free(p);
    try std.testing.expectEqualSlices(u8, "assets/hero.png", p);
    try std.testing.expectError(error.InvalidArgument, normalizeVirtualPath(allocator, "/assets/../secret"));
}
