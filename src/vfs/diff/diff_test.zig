const std = @import("std");
const fixture = @import("test_fixture.zig");
const pack_scan = @import("pack_scan.zig");
const planner = @import("diff_planner.zig");
const engine = @import("diff_engine.zig");
const writer = @import("diff_pack_writer.zig");
const reader_mod = @import("../patch/diff_pack_reader.zig");
const diff_pack = @import("../format/diff_pack.zig");

test "diff v1->v2 plans logical page and replace units and writes a verifiable DiffPack" {
    const a = std.testing.allocator;
    var ds = try fixture.dataset(a);
    defer ds.deinit();
    const v1 = "zig-cache-vfs-diff-v1";
    const v2 = "zig-cache-vfs-diff-v2";
    const out = "zig-cache-vfs-diff-d12";
    defer fixture.cleanup(v1);
    defer fixture.cleanup(v2);
    defer fixture.cleanup(out);
    try fixture.buildPack(a, "zig-cache-vfs-diff-fx1", v1, ds.v1, 9, 1, 2);
    try fixture.buildPack(a, "zig-cache-vfs-diff-fx2", v2, ds.v2, 9, 2, 2);

    var base = try pack_scan.PackImage.load(a, v1);
    defer base.deinit();
    var target = try pack_scan.PackImage.load(a, v2);
    defer target.deinit();
    var plan = try planner.create(a, &base, &target, .{});
    defer plan.deinit();

    var kinds = [_]u32{0} ** 5;
    var saw_a_logical = false;
    var saw_c_delete = false;
    var saw_f_new = false;
    for (plan.units.items) |u| {
        kinds[@intFromEnum(u.desc.kind)] += 1;
        if (u.desc.file_entry == 101 and u.desc.kind == .put_block_ldelta) saw_a_logical = true;
        if (u.desc.file_entry == 103 and u.desc.kind == .delete_page) saw_c_delete = true;
        if (u.desc.file_entry == 106 and u.desc.kind == .put_page_raw and u.desc.flags & diff_pack.UNIT_FLAG_NEW_BLOCK != 0) saw_f_new = true;
    }
    try std.testing.expect(saw_a_logical);
    try std.testing.expect(saw_c_delete);
    try std.testing.expect(saw_f_new);
    try std.testing.expectEqual(@as(u32, 1), plan.unchanged_files); // d.bin
    // file ops: put a,b,e,f ; delete c
    var puts: u32 = 0;
    var dels: u32 = 0;
    for (plan.file_ops.items) |fo| switch (fo.op.op) {
        .put_file_manifest => puts += 1,
        .delete_file_manifest => dels += 1,
        else => {},
    };
    try std.testing.expectEqual(@as(u32, 4), puts);
    try std.testing.expectEqual(@as(u32, 1), dels);
    try std.testing.expectEqual(@as(usize, 1), plan.path_adds.items.len); // /sub/f.bin
    try std.testing.expectEqual(@as(usize, 1), plan.path_removes.items.len); // /c.bin

    var result = try engine.run(a, &base, &target, &plan, .{ .budget = .{ .cpu = 2, .worker_threads = 2 } });
    defer result.deinit();
    try std.testing.expect(result.units.items.len >= plan.units.items.len);
    const rep = try writer.write(a, out, &base, &target, &plan, &result, .{}, .{ .chunk_nominal_bytes = 4096 });
    try std.testing.expect(rep.chunk_count >= 2);
    try std.testing.expectEqual(result.units.items.len, rep.unit_count);

    try reader_mod.verify(a, out);
    var r = try reader_mod.DiffPackReader.open(a, out, .{ .load = .in_memory });
    defer r.close();
    try std.testing.expect(r.in_memory);
    try std.testing.expectEqual(@as(u64, 1), r.manifest.base_pack_version);
    try std.testing.expectEqual(@as(u64, 2), r.manifest.target_pack_version);
    try std.testing.expectEqual(@as(u32, 2), r.manifest.shard_hint_count);
    try std.testing.expectEqual(rep.unit_count, r.totalUnits());
    try std.testing.expectEqualStrings("sub/f.bin", r.path_delta.?.adds[0].path);
    try std.testing.expectEqualStrings("c.bin", r.path_delta.?.removes[0].path);
    // payloads resolve and a logical unit's VHDF is much smaller than replace
    for (r.unit_tables) |t| for (t.units) |u| {
        const p = try r.payload(u.payload);
        defer r.unpinPayload(u.payload);
        if (u.kind == .put_block_ldelta and u.file_entry == 101) try std.testing.expect(p.len < 3000);
        if (u.kind != .delete_page) try std.testing.expect(p.len > 0);
    };
    // Disk mode with a tiny chunk budget: every chunk is evicted once
    // unpinned, so residency never exceeds one pinned chunk.
    var rd = try reader_mod.DiffPackReader.open(a, out, .{ .load = .disk, .chunk_cache_bytes = 1 });
    defer rd.close();
    try std.testing.expect(!rd.in_memory);
    try std.testing.expectEqual(r.totalUnits(), rd.totalUnits());
    for (rd.unit_tables) |t| for (t.units) |u| {
        if (u.payload.len == 0) continue;
        const p = try rd.payload(u.payload);
        try std.testing.expect(rd.residentChunkBytes() >= p.len);
        rd.unpinPayload(u.payload);
        try std.testing.expectEqual(@as(u64, 0), rd.residentChunkBytes());
    };
}

test "diff same version is rejected and createDiffPack one-shot works" {
    const a = std.testing.allocator;
    var ds = try fixture.dataset(a);
    defer ds.deinit();
    const v2 = "zig-cache-vfs-diff2-v2";
    const v3 = "zig-cache-vfs-diff2-v3";
    const out = "zig-cache-vfs-diff2-d23";
    defer fixture.cleanup(v2);
    defer fixture.cleanup(v3);
    defer fixture.cleanup(out);
    try fixture.buildPack(a, "zig-cache-vfs-diff2-fx2", v2, ds.v2, 9, 2, 1);
    try fixture.buildPack(a, "zig-cache-vfs-diff2-fx3", v3, ds.v3, 9, 3, 3);
    try std.testing.expectError(error.InvalidArgument, writer.createDiffPack(a, v2, v2, out, .{}));
    const rep = try writer.createDiffPack(a, v2, v3, out, .{ .engine = .{ .budget = .{ .cpu = 2, .worker_threads = 2 } } });
    try std.testing.expect(rep.write.unit_count > 0);
    try reader_mod.verify(a, out);
    var r = try reader_mod.DiffPackReader.open(a, out, .{});
    defer r.close();
    // shard hint count follows the target pack (3 shards)
    try std.testing.expectEqual(@as(u32, 3), r.manifest.shard_hint_count);
    var saw_shrink_delete = false;
    var saw_g_new = false;
    for (r.unit_tables) |t| for (t.units) |u| {
        if (u.file_entry == 101 and u.kind == .delete_page and u.page_index == 2) saw_shrink_delete = true;
        if (u.file_entry == 107 and u.kind == .put_page_raw) saw_g_new = true;
    };
    try std.testing.expect(saw_shrink_delete);
    try std.testing.expect(saw_g_new);
}
