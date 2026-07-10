const std = @import("std");
const root = @import("db");
const fmt = root.format;
const kv = root.kv_db;
const verify_mod = root.recovery_verify;
const checkpoint = root.index.checkpoint;
const base_mod = root.index.base_index;
const pf = root.platform.file;

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    if (args.len < 2) return usage();
    const cmd = args[1];
    if (std.mem.eql(u8, cmd, "create")) {
        if (args.len != 3) return usage();
        var db = try kv.KvDb.open(args[2], .{});
        try db.close();
    } else if (std.mem.eql(u8, cmd, "put") or std.mem.eql(u8, cmd, "import")) {
        if (args.len != 6) return usage();
        var db = try kv.KvDb.open(args[2], .{});
        defer db.close() catch {};
        const key = try parseKey(args[3], args[4]);
        const data = try readFileAlloc(arena, args[5]);
        try db.put(key, data, .{});
    } else if (std.mem.eql(u8, cmd, "get")) {
        if (args.len != 6) return usage();
        var db = try kv.KvDb.open(args[2], .{});
        defer db.close() catch {};
        const key = try parseKey(args[3], args[4]);
        const size = try db.getSize(key);
        const buf = try arena.alloc(u8, size);
        _ = try db.getInto(key, buf);
        try writeFile(args[5], buf);
    } else if (std.mem.eql(u8, cmd, "delete")) {
        if (args.len != 5) return usage();
        var db = try kv.KvDb.open(args[2], .{});
        defer db.close() catch {};
        try db.delete(try parseKey(args[3], args[4]), .{});
    } else if (std.mem.eql(u8, cmd, "verify")) {
        if (args.len != 3) return usage();
        const io = init.io;
        var dir = try std.Io.Dir.openDir(std.Io.Dir.cwd(), io, args[2], .{});
        defer dir.close(io);
        var report = try verify_mod.verifyAt(dir, arena);
        defer report.deinit();
        if (!report.ok()) std.process.exit(1);
    } else if (std.mem.eql(u8, cmd, "recover")) {
        if (args.len != 3 and !(args.len == 4 and std.mem.eql(u8, args[3], "--yes"))) return usage();
        const io = init.io;
        var dir = try std.Io.Dir.openDir(std.Io.Dir.cwd(), io, args[2], .{});
        defer dir.close(io);
        if (args.len == 4) {
            try verify_mod.recoverAt(dir);
        } else {
            var report = try verify_mod.verifyAt(dir, arena);
            defer report.deinit();
            var stdout_buffer: [256]u8 = undefined;
            var w = std.Io.File.stdout().writer(init.io, &stdout_buffer);
            try w.interface.print("issues={d} pass --yes to recover\n", .{report.issues.items.len});
            try w.interface.flush();
        }
    } else if (std.mem.eql(u8, cmd, "checkpoint")) {
        if (args.len != 3) return usage();
        var db = try kv.KvDb.open(args[2], .{});
        defer db.close() catch {};
        try checkpoint.run(&db, arena);
    } else if (std.mem.eql(u8, cmd, "dump_manifest")) {
        if (args.len != 3) return usage();
        var db = try kv.KvDb.open(args[2], .{});
        defer db.close() catch {};
        var stdout_buffer: [256]u8 = undefined;
        var w = std.Io.File.stdout().writer(init.io, &stdout_buffer);
        try w.interface.print("uuid=", .{});
        for (db.manifest.uuid) |b| try w.interface.print("{x:0>2}", .{b});
        try w.interface.print(" schema_version={d} data_files={d} index=index.db", .{ db.manifest.super.schema_version, db.manifest.dataFileCount() });
        var i: u32 = 0;
        while (i < db.manifest.dataFileCount()) : (i += 1) {
            var name_buf: [32]u8 = undefined;
            const id = try db.manifest.dataFileId(i);
            try w.interface.print(" data_file={s}", .{try db.manifest.dataFileName(id, &name_buf)});
        }
        try w.interface.print("\n", .{});
        try w.interface.flush();
    } else if (std.mem.eql(u8, cmd, "dump_index")) {
        if (args.len != 3) return usage();
        var db = try kv.KvDb.open(args[2], .{});
        defer db.close() catch {};
        var stdout_buffer: [256]u8 = undefined;
        var w = std.Io.File.stdout().writer(init.io, &stdout_buffer);
        var entry_count: u32 = 0;
        var base = base_mod.open(db.index) catch null;
        if (base) |*b| {
            entry_count = b.header.entry_count;
            b.close();
        }
        try w.interface.print("active_base={d} active_delta={d} base_entries={d} delta_slots={d} journal_tail={d}\n", .{ db.index.activeBaseRegionId(), db.index.activeDeltaRegionId(), entry_count, db.delta.journal.header.slot_count, db.delta.journal.header.journal_tail });
        try w.interface.flush();
    } else if (std.mem.eql(u8, cmd, "optimize")) {
        if (args.len != 3) return usage();
        var db = try kv.KvDb.open(args[2], .{});
        defer db.close() catch {};
        try db.optimize();
    } else if (std.mem.eql(u8, cmd, "bench")) {
        if (args.len != 3 and args.len != 4) return usage();
        const count = if (args.len == 4) try std.fmt.parseUnsigned(u64, args[3], 0) else 1000;
        var db = try kv.KvDb.open(args[2], .{ .max_delta_entries = @max(@as(u64, 1024), count * 2) });
        defer db.close() catch {};
        const t0 = std.Io.Timestamp.now(init.io, .boot);
        var payload = [_]u8{1} ** 128;
        var i: u64 = 0;
        while (i < count) : (i += 1) try db.put(.{ .hi = 0, .lo = i }, &payload, .{ .durability = .none });
        const t_stage = std.Io.Timestamp.now(init.io, .boot);
        try db.commitPending(.sync);
        const t_commit = std.Io.Timestamp.now(init.io, .boot);
        var buf: [128]u8 = undefined;
        i = 0;
        while (i < count) : (i += 1) _ = try db.getInto(.{ .hi = 0, .lo = i }, &buf);
        const t_read = std.Io.Timestamp.now(init.io, .boot);
        var stdout_buffer: [256]u8 = undefined;
        var w = std.Io.File.stdout().writer(init.io, &stdout_buffer);
        try w.interface.print("bench count={d} payload=128B stage_ms={d} commit_ms={d} read_ms={d} total_ms={d}\n", .{
            count,
            t0.durationTo(t_stage).toMilliseconds(),
            t_stage.durationTo(t_commit).toMilliseconds(),
            t_commit.durationTo(t_read).toMilliseconds(),
            t0.durationTo(t_read).toMilliseconds(),
        });
        try w.interface.flush();
    } else if (std.mem.eql(u8, cmd, "bench_write")) {
        if (args.len != 3 and args.len != 4) return usage();
        const count = if (args.len == 4) try std.fmt.parseUnsigned(u64, args[3], 0) else 1000;
        var db = try kv.KvDb.open(args[2], .{ .max_delta_entries = @max(@as(u64, 1024), count * 2), .mode = .write_only });
        defer db.close() catch {};
        const t0 = std.Io.Timestamp.now(init.io, .boot);
        var payload = [_]u8{1} ** 128;
        var i: u64 = 0;
        while (i < count) : (i += 1) try db.put(.{ .hi = 0, .lo = i }, &payload, .{ .durability = .none });
        const t_stage = std.Io.Timestamp.now(init.io, .boot);
        try db.commitPending(.sync);
        const t_commit = std.Io.Timestamp.now(init.io, .boot);
        var stdout_buffer: [256]u8 = undefined;
        var w = std.Io.File.stdout().writer(init.io, &stdout_buffer);
        try w.interface.print("bench_write count={d} payload=128B stage_ms={d} commit_ms={d} total_ms={d}\n", .{
            count,
            t0.durationTo(t_stage).toMilliseconds(),
            t_stage.durationTo(t_commit).toMilliseconds(),
            t0.durationTo(t_commit).toMilliseconds(),
        });
        try w.interface.flush();
    } else if (std.mem.eql(u8, cmd, "bench_read")) {
        if (args.len != 3 and args.len != 4) return usage();
        const count = if (args.len == 4) try std.fmt.parseUnsigned(u64, args[3], 0) else 1000;
        var db = try kv.KvDb.open(args[2], .{ .max_delta_entries = @max(@as(u64, 1024), count * 2), .mode = .read_only });
        defer db.close() catch {};
        const t0 = std.Io.Timestamp.now(init.io, .boot);
        var buf: [128]u8 = undefined;
        var i: u64 = 0;
        while (i < count) : (i += 1) _ = try db.getInto(.{ .hi = 0, .lo = i }, &buf);
        const t_read = std.Io.Timestamp.now(init.io, .boot);
        var stdout_buffer: [256]u8 = undefined;
        var w = std.Io.File.stdout().writer(init.io, &stdout_buffer);
        try w.interface.print("bench_read count={d} payload=128B read_ms={d}\n", .{
            count,
            t0.durationTo(t_read).toMilliseconds(),
        });
        try w.interface.flush();
    } else return usage();
}

fn usage() void {
    std.process.exit(2);
}

fn parseKey(hi_s: []const u8, lo_s: []const u8) !fmt.Key128 {
    return .{ .hi = try std.fmt.parseUnsigned(u64, hi_s, 0), .lo = try std.fmt.parseUnsigned(u64, lo_s, 0) };
}

fn readFileAlloc(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    var f = try pf.open(path, .{ .mode = .read_only });
    defer pf.close(&f);
    const size = try pf.len(f);
    const buf = try allocator.alloc(u8, size);
    if (try pf.preadAll(f, 0, buf) != buf.len) return error.Corruption;
    return buf;
}

fn writeFile(path: []const u8, data: []const u8) !void {
    var f = try pf.open(path, .{ .mode = .create_read_write, .create_parent_dirs = true });
    defer pf.close(&f);
    try pf.setLen(f, 0);
    try pf.pwriteAll(f, 0, data);
    try pf.flushMetadata(f);
}
