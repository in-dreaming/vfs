const std = @import("std");
const vfs = @import("vfs");
const pack_builder = vfs.build.pack_builder;
const pack_tools = vfs.tools.pack_tools;

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    if (args.len < 2) return usage();
    const cmd = args[1];
    if (std.mem.eql(u8, cmd, "create-pack")) {
        if (args.len != 3) return usage();
        try pack_builder.createPack(args[2], &.{}, .{});
    } else if (std.mem.eql(u8, cmd, "put-file") or std.mem.eql(u8, cmd, "build-simple")) {
        // put-file <pack> <virtual_path> <file_entry> <source> [pack_version]
        if (args.len != 6 and args.len != 7) return usage();
        const file_entry = try std.fmt.parseUnsigned(u64, args[4], 0);
        const input = pack_builder.BuildFileInput{
            .source_path = args[5],
            .virtual_path = args[3],
            .file_entry = file_entry,
            .page_size = pack_builder.DEFAULT_PAGE_SIZE,
        };
        const version: u64 = if (args.len == 7) try std.fmt.parseUnsigned(u64, args[6], 0) else 1;
        try pack_builder.createPack(args[2], &.{input}, .{ .pack_version = version, .build_id = version });
    } else if (std.mem.eql(u8, cmd, "dump-pack")) {
        if (args.len != 3) return usage();
        var stdout_buffer: [256]u8 = undefined;
        var w = std.Io.File.stdout().writer(init.io, &stdout_buffer);
        try pack_tools.dumpPack(&w.interface, args[2], arena);
        try w.interface.flush();
    } else if (std.mem.eql(u8, cmd, "verify-pack")) {
        if (args.len != 3) return usage();
        var report = try pack_tools.verifyPack(args[2], arena);
        defer report.deinit(arena);
        var stdout_buffer: [256]u8 = undefined;
        var w = std.Io.File.stdout().writer(init.io, &stdout_buffer);
        try report.print(&w.interface);
        try w.interface.flush();
        if (!report.ok()) std.process.exit(1);
    } else if (std.mem.eql(u8, cmd, "verify-volume")) {
        if (args.len != 3) return usage();
        var report = try pack_tools.verifyVolume(args[2], arena);
        defer report.deinit(arena);
        var stdout_buffer: [256]u8 = undefined;
        var w = std.Io.File.stdout().writer(init.io, &stdout_buffer);
        try report.print(&w.interface);
        try w.interface.flush();
        if (!report.ok()) std.process.exit(1);
    } else if (std.mem.eql(u8, cmd, "dump-path-index")) {
        if (args.len != 3) return usage();
        var stdout_buffer: [256]u8 = undefined;
        var w = std.Io.File.stdout().writer(init.io, &stdout_buffer);
        try pack_tools.dumpPathIndex(&w.interface, args[2], arena);
        try w.interface.flush();
    } else if (std.mem.eql(u8, cmd, "dump-file")) {
        if (args.len != 4) return usage();
        const file_entry = try std.fmt.parseUnsigned(u64, args[3], 0);
        var stdout_buffer: [256]u8 = undefined;
        var w = std.Io.File.stdout().writer(init.io, &stdout_buffer);
        try pack_tools.dumpFile(&w.interface, args[2], file_entry, arena);
        try w.interface.flush();
    } else if (std.mem.eql(u8, cmd, "extract-file")) {
        if (args.len != 5) return usage();
        const file_entry = try std.fmt.parseUnsigned(u64, args[3], 0);
        try pack_tools.extractFile(args[2], file_entry, args[4], arena);
    } else if (std.mem.eql(u8, cmd, "build")) {
        if (args.len != 3) return usage();
        const result = try pack_builder.buildFromConfig(args[2], arena);
        var stdout_buffer: [256]u8 = undefined;
        var w = std.Io.File.stdout().writer(init.io, &stdout_buffer);
        try w.interface.print("build rebuilt_files={d} skipped_files={d} wrote_pack={} cache_write_failed={}\n", .{ result.rebuilt_files, result.skipped_files, result.wrote_pack, result.cache_write_failed });
        try w.interface.flush();
    } else if (std.mem.eql(u8, cmd, "recover-build")) {
        if (args.len != 3) return usage();
        try pack_builder.recoverBuild(args[2], arena);
    } else if (std.mem.eql(u8, cmd, "recover-pack")) {
        if (args.len != 3) return usage();
        var report = try pack_tools.recoverPack(args[2], arena);
        defer report.deinit(arena);
        var stdout_buffer: [256]u8 = undefined;
        var w = std.Io.File.stdout().writer(init.io, &stdout_buffer);
        try report.print(&w.interface);
        try w.interface.flush();
        if (!report.ok()) std.process.exit(1);
    } else if (std.mem.eql(u8, cmd, "diff-pack")) {
        // diff-pack <base_dir> <target_dir> <out_diff_dir> [--chunk-mb N] [--strategy auto|logical|page|replace] [--threads N]
        if (args.len < 5) return usage();
        var opts: vfs.diff.diff_pack_writer.CreateOptions = .{};
        var i: usize = 5;
        while (i < args.len) : (i += 1) {
            if (std.mem.eql(u8, args[i], "--chunk-mb") and i + 1 < args.len) {
                i += 1;
                opts.write.chunk_nominal_bytes = (try std.fmt.parseUnsigned(u32, args[i], 0)) << 20;
            } else if (std.mem.eql(u8, args[i], "--strategy") and i + 1 < args.len) {
                i += 1;
                opts.plan.default_override = try vfs.build.build_cfg.parseDiffStrategy(args[i]);
            } else if (std.mem.eql(u8, args[i], "--threads") and i + 1 < args.len) {
                i += 1;
                opts.engine.budget = opts.engine.budget.withThreads(try std.fmt.parseUnsigned(u8, args[i], 0));
            } else return usage();
        }
        const rep = try vfs.diff.createDiffPack(arena, args[2], args[3], args[4], opts);
        var stdout_buffer: [256]u8 = undefined;
        var w = std.Io.File.stdout().writer(init.io, &stdout_buffer);
        try w.interface.print("diff-pack units={d} chunks={d} payload_bytes={d} file_ops={d} downgraded={d} unchanged_files={d}\n", .{ rep.write.unit_count, rep.write.chunk_count, rep.write.payload_bytes, rep.write.file_op_count, rep.downgraded_ratio, rep.unchanged_files });
        try w.interface.flush();
    } else if (std.mem.eql(u8, cmd, "dump-diff")) {
        if (args.len != 3) return usage();
        var stdout_buffer: [256]u8 = undefined;
        var w = std.Io.File.stdout().writer(init.io, &stdout_buffer);
        try vfs.tools.diff_tools.dumpDiff(&w.interface, args[2], arena);
        try w.interface.flush();
    } else if (std.mem.eql(u8, cmd, "verify-diff")) {
        if (args.len != 3) return usage();
        try vfs.tools.diff_tools.verifyDiff(args[2], arena);
    } else if (std.mem.eql(u8, cmd, "patch-pack")) {
        // patch-pack <target_dir> <diff_dir>... [--overlay DIR] [--to V] [--in-memory|--disk] [--batch-mb N] [--threads N] [--optimize] [--force] [--verify none|touched|full] [--trace out.json]
        if (args.len < 4) return usage();
        var opts: vfs.patch.PatchOptions = .{};
        var overlay: ?[]const u8 = null;
        var to: ?u64 = null;
        var diffs = std.ArrayList([]const u8).empty;
        var i: usize = 3;
        while (i < args.len) : (i += 1) {
            const s = args[i];
            if (std.mem.eql(u8, s, "--overlay") and i + 1 < args.len) {
                i += 1;
                overlay = args[i];
            } else if (std.mem.eql(u8, s, "--to") and i + 1 < args.len) {
                i += 1;
                to = try std.fmt.parseUnsigned(u64, args[i], 0);
            } else if (std.mem.eql(u8, s, "--in-memory")) {
                opts.diff_load = .in_memory;
            } else if (std.mem.eql(u8, s, "--disk")) {
                opts.diff_load = .disk;
            } else if (std.mem.eql(u8, s, "--batch-mb") and i + 1 < args.len) {
                i += 1;
                opts.writer.batch_bytes = @as(u64, try std.fmt.parseUnsigned(u32, args[i], 0)) << 20;
            } else if (std.mem.eql(u8, s, "--threads") and i + 1 < args.len) {
                i += 1;
                opts.budget = opts.budget.withThreads(try std.fmt.parseUnsigned(u8, args[i], 0));
            } else if (std.mem.eql(u8, s, "--optimize")) {
                opts.optimize_after = true;
            } else if (std.mem.eql(u8, s, "--force")) {
                opts.force = true;
            } else if (std.mem.eql(u8, s, "--verify") and i + 1 < args.len) {
                i += 1;
                opts.verify_after = std.meta.stringToEnum(vfs.patch.VerifyAfter, args[i]) orelse return usage();
            } else if (std.mem.eql(u8, s, "--trace") and i + 1 < args.len) {
                i += 1;
                opts.trace_path = args[i];
            } else if (s.len > 2 and s[0] == '-' and s[1] == '-') {
                return usage();
            } else {
                try diffs.append(arena, s);
            }
        }
        const rep = try vfs.patch.run(arena, args[2], overlay, diffs.items, to, opts);
        var stdout_buffer: [256]u8 = undefined;
        var w = std.Io.File.stdout().writer(init.io, &stdout_buffer);
        try w.interface.print("patch-pack {d}->{d} no_op={} resumed={} units={d} applied={d} skipped={d} pages_written={d} pages_deleted={d} file_ops={d} bytes_written={d} batches={d} yields={d} wall_ms={d}\n", .{
            rep.from_version, rep.to_version, rep.no_op, rep.resumed, rep.units_total, rep.units_applied, rep.units_skipped, rep.pages_written, rep.pages_deleted, rep.file_ops, rep.bytes_written, rep.batches, rep.yields, rep.wall_ns / std.time.ns_per_ms,
        });
        try w.interface.flush();
    } else if (std.mem.eql(u8, cmd, "bench-patch")) {
        // bench-patch <target_dir> <scratch_dir> <diff_dir>...
        if (args.len < 5) return usage();
        var stdout_buffer: [256]u8 = undefined;
        var w = std.Io.File.stdout().writer(init.io, &stdout_buffer);
        try vfs.tools.diff_tools.benchPatch(&w.interface, arena, args[2], args[4..], args[3], vfs.tools.diff_tools.defaultMatrix());
        try w.interface.flush();
    } else return usage();
}

fn usage() void {
    std.debug.print(
        \\usage: vfs <command> ...
        \\  create-pack <pack_dir>
        \\  put-file <pack_dir> <virtual_path> <file_entry> <source> [pack_version]
        \\  build <build.cfg>
        \\  dump-pack <pack_dir>
        \\  verify-pack <pack_dir>
        \\  verify-volume <volume_dir>
        \\  dump-path-index <pack_dir>
        \\  dump-file <pack_dir> <file_entry>
        \\  extract-file <pack_dir> <file_entry> <out_path>
        \\  recover-build <pack_dir> (only after the builder has stopped)
        \\  recover-pack <pack_dir>
        \\  diff-pack <base_dir> <target_dir> <out_diff_dir> [--chunk-mb N] [--strategy auto|logical|page|replace] [--threads N]
        \\  dump-diff <diff_dir>
        \\  verify-diff <diff_dir>
        \\  patch-pack <target_dir> <diff_dir>... [--overlay DIR] [--to V] [--in-memory|--disk] [--batch-mb N] [--threads N] [--optimize] [--force] [--verify none|touched|full] [--trace out.json]
        \\  bench-patch <target_dir> <scratch_dir> <diff_dir>...
        \\
    , .{});
    std.process.exit(2);
}
