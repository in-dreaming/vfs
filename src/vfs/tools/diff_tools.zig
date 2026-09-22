//! CLI-facing helpers for diff/patch: dump-diff, verify-diff, bench-patch.
const std = @import("std");
const reader_mod = @import("../patch/diff_pack_reader.zig");
const diff_pack = @import("../format/diff_pack.zig");
const patch_session = @import("../patch/patch_session.zig");
const pf = @import("db_internal").platform.file;

pub fn dumpDiff(writer: anytype, path: []const u8, allocator: std.mem.Allocator) !void {
    var r = try reader_mod.DiffPackReader.open(allocator, path, .{ .load = .disk });
    defer r.close();
    const m = r.manifest;
    try writer.print("diff id=0x{x} pack_id={d} {d}->{d} build_id={d} units={d} chunks={d} chunk_nominal={d} file_ops={d} payload_bytes={d} shard_hints={d} flags=0x{x}\n", .{
        m.diff_id, m.target_pack_id, m.base_pack_version, m.target_pack_version, m.target_build_id, m.unit_count, m.chunk_count, m.chunk_nominal_bytes, m.file_op_count, m.payload_total_bytes, m.shard_hint_count, m.flags,
    });
    var chunk_units = std.AutoArrayHashMapUnmanaged(u32, struct { units: u32 = 0, bytes: u64 = 0 }){};
    defer chunk_units.deinit(allocator);
    for (r.unit_tables) |t| {
        var raw: u32 = 0;
        var pdelta: u32 = 0;
        var ldelta: u32 = 0;
        var del: u32 = 0;
        var down_ratio: u32 = 0;
        var down_layout: u32 = 0;
        var cfg_override: u32 = 0;
        var new_block: u32 = 0;
        var bytes: u64 = 0;
        for (t.units) |u| {
            switch (u.kind) {
                .put_page_raw => raw += 1,
                .put_page_pdelta => pdelta += 1,
                .put_block_ldelta => ldelta += 1,
                .delete_page => del += 1,
                _ => {},
            }
            if (u.flags & diff_pack.UNIT_FLAG_DOWNGRADED_RATIO != 0) down_ratio += 1;
            if (u.flags & diff_pack.UNIT_FLAG_DOWNGRADED_LAYOUT != 0) down_layout += 1;
            if (u.flags & diff_pack.UNIT_FLAG_CFG_OVERRIDE != 0) cfg_override += 1;
            if (u.flags & diff_pack.UNIT_FLAG_NEW_BLOCK != 0) new_block += 1;
            bytes += u.payload.len;
            if (u.payload.len != 0) {
                const gop = try chunk_units.getOrPut(allocator, u.payload.chunk_id);
                if (!gop.found_existing) gop.value_ptr.* = .{};
                gop.value_ptr.units += 1;
                gop.value_ptr.bytes += u.payload.len;
            }
        }
        try writer.print("shard {d}: units={d} raw={d} pdelta={d} ldelta={d} delete={d} downgraded_ratio={d} downgraded_layout={d} cfg_override={d} new_block={d} payload_bytes={d}\n", .{
            t.shard, t.units.len, raw, pdelta, ldelta, del, down_ratio, down_layout, cfg_override, new_block, bytes,
        });
    }
    var cit = chunk_units.iterator();
    while (cit.next()) |e| try writer.print("chunk {d}: units={d} payload_bytes={d}\n", .{ e.key_ptr.*, e.value_ptr.units, e.value_ptr.bytes });
    for (r.file_ops) |op| {
        try writer.print("file_op {s} file_entry={d} old_v={d} new_v={d} payload={d}\n", .{ @tagName(op.op), op.file_entry, op.old_file_version, op.new_file_version, op.payload.len });
    }
    if (r.path_delta) |pd| {
        for (pd.adds) |ad| try writer.print("path + {s} -> {d}\n", .{ ad.path, ad.file_entry });
        for (pd.removes) |rm| try writer.print("path - {s}\n", .{rm.path});
    }
}

pub fn verifyDiff(path: []const u8, allocator: std.mem.Allocator) !void {
    return reader_mod.verify(allocator, path);
}

pub const BenchCase = struct {
    name: []const u8,
    options: patch_session.PatchOptions,
};

/// Default experiment matrix (docs/vfs/diff_patch.md §15 E1-E4, E6): diff
/// load mode, batch size, worker threads, intermediate durability and the
/// idempotent-check cost, each varied against the same baseline.
pub fn defaultMatrix() []const BenchCase {
    return &.{
        .{ .name = "in_memory/batch16M/auto/none", .options = .{ .diff_load = .in_memory, .writer = .{ .batch_bytes = 16 << 20 } } },
        .{ .name = "disk/batch16M/auto/none", .options = .{ .diff_load = .disk, .writer = .{ .batch_bytes = 16 << 20 } } },
        .{ .name = "in_memory/batch4M/auto/none", .options = .{ .diff_load = .in_memory, .writer = .{ .batch_bytes = 4 << 20 } } },
        .{ .name = "in_memory/batch64M/auto/none", .options = .{ .diff_load = .in_memory, .writer = .{ .batch_bytes = 64 << 20 } } },
        .{ .name = "in_memory/batch16M/t1/none", .options = .{ .diff_load = .in_memory, .writer = .{ .batch_bytes = 16 << 20 }, .budget = .{ .cpu = 1, .worker_threads = 1 } } },
        .{ .name = "in_memory/batch16M/t2/none", .options = .{ .diff_load = .in_memory, .writer = .{ .batch_bytes = 16 << 20 }, .budget = .{ .cpu = 2, .worker_threads = 2 } } },
        .{ .name = "in_memory/batch16M/t8/none", .options = .{ .diff_load = .in_memory, .writer = .{ .batch_bytes = 16 << 20 }, .budget = .{ .cpu = 8, .worker_threads = 8 } } },
        .{ .name = "in_memory/batch16M/auto/async", .options = .{ .diff_load = .in_memory, .writer = .{ .batch_bytes = 16 << 20, .intermediate_durability = .async } } },
        .{ .name = "in_memory/batch16M/auto/idempotent_off", .options = .{ .diff_load = .in_memory, .writer = .{ .batch_bytes = 16 << 20 }, .idempotent_check = .off } },
    };
}

fn copyTree(allocator: std.mem.Allocator, src: []const u8, dst: []const u8) !void {
    const io = std.Io.Threaded.global_single_threaded.io();
    _ = std.Io.Dir.cwd().deleteTree(io, dst) catch {};
    try std.Io.Dir.cwd().createDirPath(io, dst);
    const names = [_][]const u8{ "manifest.db", "index.db" };
    for (names) |n| try copyOne(allocator, src, dst, n);
    var i: u32 = 0;
    while (i < 256) : (i += 1) {
        var buf: [32]u8 = undefined;
        const n = try std.fmt.bufPrint(&buf, "data_{d:0>3}.db", .{i});
        copyOne(allocator, src, dst, n) catch |e| switch (e) {
            error.FileNotFound => break,
            else => |err| return err,
        };
    }
}

fn copyOne(allocator: std.mem.Allocator, src_dir: []const u8, dst_dir: []const u8, name: []const u8) !void {
    const sp = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ src_dir, name });
    defer allocator.free(sp);
    const dp = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ dst_dir, name });
    defer allocator.free(dp);
    var sf = try pf.open(sp, .{ .mode = .read_only });
    defer pf.close(&sf);
    const len = try pf.len(sf);
    const buf = try allocator.alloc(u8, len);
    defer allocator.free(buf);
    if (try pf.preadAll(sf, 0, buf) != buf.len) return error.Corruption;
    var df = try pf.open(dp, .{ .mode = .create_read_write, .create_parent_dirs = true });
    defer pf.close(&df);
    try pf.setLen(df, 0);
    try pf.pwriteAll(df, 0, buf);
    try pf.flushData(df);
}

/// Copies the target pack to a scratch directory for every case and patches
/// it, printing one line per case.
pub fn benchPatch(writer: anytype, allocator: std.mem.Allocator, target: []const u8, diffs: []const []const u8, scratch: []const u8, cases: []const BenchCase) !void {
    const io = std.Io.Threaded.global_single_threaded.io();
    for (cases) |c| {
        try copyTree(allocator, target, scratch);
        const rep = patch_session.run(allocator, scratch, null, diffs, null, c.options) catch |err| {
            try writer.print("{s}: error {s}\n", .{ c.name, @errorName(err) });
            continue;
        };
        try writer.print("{s}: {d}->{d} wall_ms={d} units={d} applied={d} skipped={d} pages_written={d} bytes_written={d} batches={d} yields={d} max_running={d} max_mem={d}\n", .{
            c.name, rep.from_version, rep.to_version, rep.wall_ns / std.time.ns_per_ms, rep.units_total, rep.units_applied, rep.units_skipped, rep.pages_written, rep.bytes_written, rep.batches, rep.yields, rep.max_running, rep.max_mem_bytes,
        });
    }
    _ = std.Io.Dir.cwd().deleteTree(io, scratch) catch {};
}

test "dump and bench run against a generated diff" {
    const a = std.testing.allocator;
    const fixture = @import("../diff/test_fixture.zig");
    const diff_writer = @import("../diff/diff_pack_writer.zig");
    var ds = try fixture.dataset(a);
    defer ds.deinit();
    const v1 = "zig-cache-vfs-dt-v1";
    const v2 = "zig-cache-vfs-dt-v2";
    const d12 = "zig-cache-vfs-dt-d12";
    const scratch = "zig-cache-vfs-dt-scratch";
    defer fixture.cleanup(v1);
    defer fixture.cleanup(v2);
    defer fixture.cleanup(d12);
    defer fixture.cleanup(scratch);
    try fixture.buildPack(a, "zig-cache-vfs-dt-fx1", v1, ds.v1, 5, 1, 2);
    try fixture.buildPack(a, "zig-cache-vfs-dt-fx2", v2, ds.v2, 5, 2, 2);
    _ = try diff_writer.createDiffPack(a, v1, v2, d12, .{ .engine = .{ .budget = .{ .cpu = 1, .worker_threads = 1 } } });
    var w = std.Io.Writer.Allocating.init(a);
    defer w.deinit();
    try dumpDiff(&w.writer, d12, a);
    try verifyDiff(d12, a);
    try std.testing.expect(std.mem.indexOf(u8, w.written(), "ldelta=") != null);
    const cases = [_]BenchCase{
        .{ .name = "mem", .options = .{ .diff_load = .in_memory, .budget = .{ .cpu = 1, .worker_threads = 1 } } },
        .{ .name = "disk", .options = .{ .diff_load = .disk, .budget = .{ .cpu = 1, .worker_threads = 1 } } },
    };
    try benchPatch(&w.writer, a, v1, &.{d12}, scratch, &cases);
    try std.testing.expect(std.mem.indexOf(u8, w.written(), "mem: 1->2") != null);
    try std.testing.expect(std.mem.indexOf(u8, w.written(), "disk: 1->2") != null);
}
