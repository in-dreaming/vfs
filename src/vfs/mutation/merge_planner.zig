const std = @import("std");
const patch_manifest = @import("../format/patch_manifest.zig");
const mutation_plan = @import("mutation_plan.zig");

pub fn createPlan(allocator: std.mem.Allocator, target_pack_path: []const u8, patch: patch_manifest.DecodedPatchManifest) !mutation_plan.PackMutationPlan {
    var files = std.ArrayList(mutation_plan.FileMutation).empty;
    errdefer {
        for (files.items) |*file| file.deinit(allocator);
        files.deinit(allocator);
    }
    for (patch.files) |file| {
        try coalesceOne(allocator, &files, try mutation_plan.mutationFromPatch(allocator, file));
    }
    return .{
        .target_pack_path = try allocator.dupe(u8, target_pack_path),
        .target_pack_id = patch.target_pack_id,
        .base_pack_version = patch.base_pack_version,
        .patch_version = patch.patch_version,
        .files = try files.toOwnedSlice(allocator),
    };
}

fn coalesceOne(allocator: std.mem.Allocator, files: *std.ArrayList(mutation_plan.FileMutation), incoming: mutation_plan.FileMutation) !void {
    for (files.items, 0..) |*existing, i| {
        if (existing.file_entry != incoming.file_entry) continue;
        if (existing.op == .add_file and incoming.op == .delete_file) {
            existing.deinit(allocator);
            _ = files.swapRemove(i);
            var tmp = incoming;
            tmp.deinit(allocator);
            return;
        }
        if (existing.op == .delete_file and incoming.op == .add_file) {
            var next = incoming;
            next.op = .modify_file;
            if (next.old_file_size == 0) {
                next.old_file_size = existing.old_file_size;
                next.old_content_hash = existing.old_content_hash;
            }
            existing.deinit(allocator);
            existing.* = next;
            return;
        }
        existing.deinit(allocator);
        existing.* = incoming;
        return;
    }
    try files.append(allocator, incoming);
}

test "merge planner coalesces simple file mutations" {
    const allocator = std.testing.allocator;
    const h1 = @import("../hash.zig").contentHash("one");
    const h2 = @import("../hash.zig").contentHash("two");
    const encoded = try patch_manifest.encode(allocator, .{ .target_pack_id = 1, .base_pack_version = 1, .patch_version = 2, .files = &.{
        .{ .file_entry = 1, .op = .modify_file, .new_file_size = 3, .new_content_hash = h1, .payload = "one" },
        .{ .file_entry = 1, .op = .modify_file, .new_file_size = 3, .new_content_hash = h2, .payload = "two" },
        .{ .file_entry = 2, .op = .add_file, .new_file_size = 3, .new_content_hash = h1, .payload = "one" },
        .{ .file_entry = 2, .op = .delete_file },
    } });
    defer allocator.free(encoded);
    var patch = try patch_manifest.decode(allocator, encoded);
    defer patch.deinit(allocator);
    var plan = try createPlan(allocator, "pack", patch);
    defer plan.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 1), plan.files.len);
    try std.testing.expectEqualSlices(u8, "two", plan.files[0].payload);
}
