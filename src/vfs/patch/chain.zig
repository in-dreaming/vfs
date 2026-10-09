//! Chooses which DiffPacks to apply, and in what order, to go from the
//! target's current version to the requested one: versions are nodes,
//! DiffPacks are edges weighted by payload size, Dijkstra picks the lightest
//! path (docs/vfs/diff_patch.md §11.1).
const std = @import("std");
const diff_pack = @import("../format/diff_pack.zig");

pub const Edge = struct {
    index: usize,
    from: u64,
    to: u64,
    weight: u64,
    diff_id: u64,
};

/// Returns the indices (into `manifests`) of the chosen DiffPacks in apply
/// order. Caller frees.
pub fn select(allocator: std.mem.Allocator, manifests: []const diff_pack.DiffManifest, from: u64, to: u64) ![]usize {
    if (from == to) return allocator.alloc(usize, 0);
    var edges = std.ArrayList(Edge).empty;
    defer edges.deinit(allocator);
    var pack_id: ?u64 = null;
    for (manifests, 0..) |dm, i| {
        if (pack_id != null and pack_id.? != dm.target_pack_id) return error.InvalidArgument;
        pack_id = dm.target_pack_id;
        // +1 so an empty diff still costs something; saturating because the
        // weight comes from a file.
        try edges.append(allocator, .{ .index = i, .from = dm.base_pack_version, .to = dm.target_pack_version, .weight = dm.payload_total_bytes +| 1, .diff_id = dm.diff_id });
    }

    // Dijkstra on the small implicit graph.
    var dist = std.AutoHashMap(u64, u64).init(allocator);
    defer dist.deinit();
    var prev = std.AutoHashMap(u64, Edge).init(allocator);
    defer prev.deinit();
    var done = std.AutoHashMap(u64, void).init(allocator);
    defer done.deinit();
    try dist.put(from, 0);
    while (true) {
        var best: ?u64 = null;
        var best_d: u64 = std.math.maxInt(u64);
        var it = dist.iterator();
        while (it.next()) |e| {
            if (done.contains(e.key_ptr.*)) continue;
            if (e.value_ptr.* < best_d) {
                best_d = e.value_ptr.*;
                best = e.key_ptr.*;
            }
        }
        const u = best orelse break;
        if (u == to) break;
        try done.put(u, {});
        for (edges.items) |e| {
            if (e.from != u) continue;
            const nd = best_d +| e.weight;
            const cur = dist.get(e.to) orelse std.math.maxInt(u64);
            if (nd < cur) {
                try dist.put(e.to, nd);
                try prev.put(e.to, e);
            }
        }
    }
    if (!dist.contains(to)) return error.NoPatchPath;
    var path = std.ArrayList(usize).empty;
    errdefer path.deinit(allocator);
    var cur = to;
    while (cur != from) {
        const e = prev.get(cur) orelse return error.NoPatchPath;
        try path.append(allocator, e.index);
        cur = e.from;
    }
    std.mem.reverse(usize, path.items);
    return path.toOwnedSlice(allocator);
}

/// Reconstruct exactly the chain recorded by a durable PatchIntent. Unrelated
/// candidates (even cheaper ones) cannot replace it during ordinary recovery.
pub fn selectSaved(allocator: std.mem.Allocator, manifests: []const diff_pack.DiffManifest, from: u64, to: u64, diff_ids: []const u64) ![]usize {
    const order = try allocator.alloc(usize, diff_ids.len);
    errdefer allocator.free(order);
    var version = from;
    var pack_id: ?u64 = null;
    for (diff_ids, 0..) |id, step| {
        var found: ?usize = null;
        for (manifests, 0..) |dm, i| {
            if (dm.diff_id != id) continue;
            // Ambiguous IDs must never silently select an arbitrary artifact.
            if (found != null) return error.PatchIntentMismatch;
            found = i;
        }
        const index = found orelse return error.PatchIntentMismatch;
        const dm = manifests[index];
        if (dm.base_pack_version != version) return error.PatchIntentMismatch;
        if (pack_id) |pid| if (dm.target_pack_id != pid) return error.PatchIntentMismatch;
        pack_id = dm.target_pack_id;
        version = dm.target_pack_version;
        order[step] = index;
    }
    if (version != to) return error.PatchIntentMismatch;
    return order;
}

fn m(from: u64, to: u64, bytes: u64) diff_pack.DiffManifest {
    return .{ .diff_id = from * 100 + to, .target_pack_id = 1, .base_pack_version = from, .target_pack_version = to, .target_build_id = to, .shard_hint_count = 1, .unit_count = 0, .chunk_count = 0, .chunk_nominal_bytes = 0, .file_op_count = 0, .target_file_count = 0, .target_tombstone_count = 0, .base_content_hash = [_]u8{0} ** 32, .target_content_hash = [_]u8{0} ** 32, .payload_total_bytes = bytes, .tool_version_hash = 0, .hdiff_options_hash = 0 };
}

test "chain picks lightest path and reports missing path" {
    const a = std.testing.allocator;
    const ms = [_]diff_pack.DiffManifest{ m(1, 2, 100), m(2, 3, 100), m(1, 3, 500), m(3, 4, 10) };
    const p13 = try select(a, &ms, 1, 3);
    defer a.free(p13);
    try std.testing.expectEqualSlices(usize, &.{ 0, 1 }, p13);
    const ms2 = [_]diff_pack.DiffManifest{ m(1, 2, 100), m(2, 3, 100), m(1, 3, 150) };
    const p13b = try select(a, &ms2, 1, 3);
    defer a.free(p13b);
    try std.testing.expectEqualSlices(usize, &.{2}, p13b);
    const p14 = try select(a, &ms, 1, 4);
    defer a.free(p14);
    try std.testing.expectEqualSlices(usize, &.{ 0, 1, 3 }, p14);
    try std.testing.expectError(error.NoPatchPath, select(a, &ms, 4, 1));
    const same = try select(a, &ms, 2, 2);
    defer a.free(same);
    try std.testing.expectEqual(@as(usize, 0), same.len);
}

test "chain resume preserves saved IDs despite a cheaper candidate" {
    const a = std.testing.allocator;
    const ms = [_]diff_pack.DiffManifest{ m(1, 3, 1), m(2, 3, 100), m(1, 2, 100) };
    const saved = try selectSaved(a, &ms, 1, 3, &.{ 102, 203 });
    defer a.free(saved);
    try std.testing.expectEqualSlices(usize, &.{ 2, 1 }, saved);
    // Force deliberately uses ordinary selection instead of saved IDs.
    const fresh = try select(a, &ms, 1, 3);
    defer a.free(fresh);
    try std.testing.expectEqualSlices(usize, &.{0}, fresh);
    try std.testing.expectError(error.PatchIntentMismatch, selectSaved(a, &ms, 1, 3, &.{ 102, 999 }));
    try std.testing.expectError(error.PatchIntentMismatch, selectSaved(a, &ms, 1, 3, &.{ 203, 102 }));
    try std.testing.expectError(error.PatchIntentMismatch, selectSaved(a, &ms, 1, 4, &.{ 102, 203 }));
}
