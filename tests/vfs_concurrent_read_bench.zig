const std = @import("std");
const vfs = @import("vfs");

const builder = vfs.build.pack_builder;
const page_size: u32 = 64 * 1024;
const file_bytes: usize = 8 * 1024 * 1024;
const file_count: usize = 4;

pub fn main(init: std.process.Init) !void {
    var stdout_buf: [512]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(init.io, &stdout_buf);
    const out = &stdout_writer.interface;

    const io = init.io;
    const pack_path = "zig-cache-vfs-concurrent-bench-pack";
    _ = std.Io.Dir.cwd().deleteTree(io, pack_path) catch {};
    defer _ = std.Io.Dir.cwd().deleteTree(io, pack_path) catch {};

    try out.print("cpu threads={d}\n", .{std.Thread.getCpuCount() catch 0});
    try out.print("preparing {d} x {d} MiB pack (page={d} KiB)...\n", .{ file_count, file_bytes / (1024 * 1024), page_size / 1024 });
    try out.flush();
    try preparePack(pack_path);

    var volume = try vfs.volume.volume.Volume.open("bench-root", .{});
    defer volume.close();
    try volume.mountPackWithPriority(pack_path, 1, 0);

    try out.print("\n== disjoint cold (WS 32 MiB, cache 8 MiB, eviction pressure) ==\n", .{});
    try benchDisjointFiles(out, io, &volume, 8 * 1024 * 1024, 2, true);
    try out.print("\n== disjoint cold (WS 32 MiB, cache 64 MiB, no eviction) ==\n", .{});
    try benchDisjointFiles(out, io, &volume, 64 * 1024 * 1024, 1, true);
    try out.print("\n== disjoint warm (WS 32 MiB, cache 64 MiB, memcpy/lock) ==\n", .{});
    try benchDisjointWarm(out, io, &volume, 64 * 1024 * 1024, 4);
    try out.print("\n== same file random warm (cache hits, lock contention) ==\n", .{});
    try benchSameFileRandom(out, io, &volume);
    try out.flush();
}

fn preparePack(pack_path: []const u8) !void {
    const allocator = std.heap.smp_allocator;
    const payload = try allocator.alloc(u8, file_bytes);
    defer allocator.free(payload);
    for (payload, 0..) |*b, i| b.* = @truncate(i *% 131);

    var inputs: [file_count]builder.BuildFileInput = undefined;
    var source_paths: [file_count][64]u8 = undefined;
    var i: usize = 0;
    while (i < file_count) : (i += 1) {
        const source = try std.fmt.bufPrint(&source_paths[i], "zig-cache-vfs-concurrent-bench-{d}.bin", .{i});
        try builder.writeSourceFileForTest(source, payload);
        inputs[i] = .{
            .source_path = source,
            .virtual_path = switch (i) {
                0 => "/a.bin",
                1 => "/b.bin",
                2 => "/c.bin",
                else => "/d.bin",
            },
            .file_entry = 1000 + i,
            .page_size = page_size,
        };
    }
    try builder.createPack(pack_path, &inputs, .{});
    i = 0;
    const io = std.Io.Threaded.global_single_threaded.io();
    while (i < file_count) : (i += 1) {
        const source = try std.fmt.bufPrint(&source_paths[i], "zig-cache-vfs-concurrent-bench-{d}.bin", .{i});
        _ = std.Io.Dir.cwd().deleteFile(io, source) catch {};
    }
}

const Job = struct {
    volume: *vfs.volume.volume.Volume,
    file_entry: u64,
    offset: u64,
    len: u64,
    repeats: u32,
    errors: *std.atomic.Value(u32),

    fn runFullFile(job: *const Job) void {
        var handle = job.volume.openEntry(1, job.file_entry) catch {
            _ = job.errors.fetchAdd(1, .seq_cst);
            return;
        };
        defer handle.close();
        const buf = std.heap.smp_allocator.alloc(u8, page_size) catch {
            _ = job.errors.fetchAdd(1, .seq_cst);
            return;
        };
        defer std.heap.smp_allocator.free(buf);
        var r: u32 = 0;
        while (r < job.repeats) : (r += 1) {
            var off: u64 = 0;
            while (off < job.len) {
                const n = handle.readAt(off, buf) catch {
                    _ = job.errors.fetchAdd(1, .seq_cst);
                    return;
                };
                if (n == 0) break;
                off += n;
            }
        }
    }

    fn runRandomPages(job: *const Job) void {
        var handle = job.volume.openEntry(1, job.file_entry) catch {
            _ = job.errors.fetchAdd(1, .seq_cst);
            return;
        };
        defer handle.close();
        const buf = std.heap.smp_allocator.alloc(u8, page_size) catch {
            _ = job.errors.fetchAdd(1, .seq_cst);
            return;
        };
        defer std.heap.smp_allocator.free(buf);
        const page_count = job.len / page_size;
        var r: u32 = 0;
        while (r < job.repeats) : (r += 1) {
            const page = ((r *% 17) + @as(u32, @truncate(job.offset))) % @as(u32, @intCast(page_count));
            const off = @as(u64, page) * page_size;
            _ = handle.readAt(off, buf) catch {
                _ = job.errors.fetchAdd(1, .seq_cst);
                return;
            };
        }
    }
};

fn benchDisjointFiles(
    out: *std.Io.Writer,
    io: std.Io,
    volume: *vfs.volume.volume.Volume,
    cache_budget: usize,
    repeats: u32,
    flush_each: bool,
) !void {
    const bytes_per_pass = file_count * file_bytes * repeats;
    const thread_counts = [_]u32{ 1, 2, 4 };
    var baseline_ns: u64 = 0;
    for (thread_counts) |threads| {
        if (flush_each) flushCache(volume, cache_budget);
        const before = volume.page_cache.stats;
        const ns = try runDisjoint(io, volume, threads, repeats);
        const mbps = mbPerSec(bytes_per_pass, ns);
        if (threads == 1) baseline_ns = ns;
        const speedup = @as(f64, @floatFromInt(baseline_ns)) / @as(f64, @floatFromInt(ns));
        try out.print("  {d} thread(s): {:.1} ms  {:.1} MiB/s  {:.2}x  hits={d} misses={d} evict={d}\n", .{
            threads,
            @as(f64, @floatFromInt(ns)) / 1e6,
            mbps,
            speedup,
            volume.page_cache.stats.hits - before.hits,
            volume.page_cache.stats.misses - before.misses,
            volume.page_cache.stats.evictions - before.evictions,
        });
        try out.flush();
    }
}

fn benchDisjointWarm(out: *std.Io.Writer, io: std.Io, volume: *vfs.volume.volume.Volume, cache_budget: usize, repeats: u32) !void {
    flushCache(volume, cache_budget);
    _ = try runDisjoint(io, volume, 1, 1);
    try benchDisjointFiles(out, io, volume, cache_budget, repeats, false);
}

fn benchSameFileRandom(out: *std.Io.Writer, io: std.Io, volume: *vfs.volume.volume.Volume) !void {
    const total_pages: u32 = 16384;
    const thread_counts = [_]u32{ 1, 2, 4 };
    var handle = try volume.openEntry(1, 1000);
    var warmup: [page_size]u8 = undefined;
    var off: u64 = 0;
    while (off < file_bytes) : (off += page_size) _ = try handle.readAt(off, &warmup);
    handle.close();

    var baseline_ns: u64 = 0;
    for (thread_counts) |threads| {
        const per = total_pages / threads;
        const before = volume.page_cache.stats;
        const ns = try runRandom(io, volume, threads, per);
        const ops = @as(f64, @floatFromInt(total_pages)) / (@as(f64, @floatFromInt(ns)) / 1e9);
        if (threads == 1) baseline_ns = ns;
        const speedup = @as(f64, @floatFromInt(baseline_ns)) / @as(f64, @floatFromInt(ns));
        try out.print("  {d} thread(s): {:.1} ms  {:.0} pages/s  {:.2}x  hits={d} misses={d}\n", .{
            threads,
            @as(f64, @floatFromInt(ns)) / 1e6,
            ops,
            speedup,
            volume.page_cache.stats.hits - before.hits,
            volume.page_cache.stats.misses - before.misses,
        });
        try out.flush();
    }
}

fn runDisjoint(io: std.Io, volume: *vfs.volume.volume.Volume, threads: u32, repeats: u32) !u64 {
    var errors = std.atomic.Value(u32).init(0);
    var jobs: [file_count]Job = undefined;
    var i: usize = 0;
    while (i < file_count) : (i += 1) {
        jobs[i] = .{
            .volume = volume,
            .file_entry = 1000 + i,
            .offset = 0,
            .len = file_bytes,
            .repeats = repeats,
            .errors = &errors,
        };
    }

    const Worker = struct {
        fn run(slice: []Job) void {
            for (slice) |*job| Job.runFullFile(job);
        }
    };

    const start = nowNs(io);
    if (threads == 1) {
        Worker.run(jobs[0..]);
    } else {
        const per = file_count / threads;
        var spawned: [4]std.Thread = undefined;
        var t: u32 = 0;
        while (t < threads) : (t += 1) {
            const begin = t * per;
            const end = if (t + 1 == threads) file_count else begin + per;
            spawned[t] = try std.Thread.spawn(.{}, Worker.run, .{jobs[begin..end]});
        }
        t = 0;
        while (t < threads) : (t += 1) spawned[t].join();
    }
    const elapsed: u64 = nowNs(io) - start;
    if (errors.load(.seq_cst) != 0) return error.BenchFailed;
    return elapsed;
}

fn runRandom(io: std.Io, volume: *vfs.volume.volume.Volume, threads: u32, repeats: u32) !u64 {
    var errors = std.atomic.Value(u32).init(0);
    var jobs: [4]Job = undefined;
    var spawned: [4]std.Thread = undefined;
    var t: u32 = 0;
    while (t < threads) : (t += 1) {
        jobs[t] = .{
            .volume = volume,
            .file_entry = 1000,
            .offset = t,
            .len = file_bytes,
            .repeats = repeats,
            .errors = &errors,
        };
    }
    const start = nowNs(io);
    if (threads == 1) {
        Job.runRandomPages(&jobs[0]);
    } else {
        t = 0;
        while (t < threads) : (t += 1) {
            spawned[t] = try std.Thread.spawn(.{}, Job.runRandomPages, .{&jobs[t]});
        }
        t = 0;
        while (t < threads) : (t += 1) spawned[t].join();
    }
    const elapsed: u64 = nowNs(io) - start;
    if (errors.load(.seq_cst) != 0) return error.BenchFailed;
    return elapsed;
}

fn nowNs(io: std.Io) u64 {
    return @intCast(std.Io.Clock.awake.now(io).nanoseconds);
}

fn flushCache(volume: *vfs.volume.volume.Volume, budget_bytes: usize) void {
    volume.page_cache.deinit(std.heap.smp_allocator);
    volume.page_cache.budget_bytes = budget_bytes;
}

fn mbPerSec(bytes: usize, ns: u64) f64 {
    const sec = @as(f64, @floatFromInt(ns)) / 1e9;
    return @as(f64, @floatFromInt(bytes)) / (1024.0 * 1024.0) / sec;
}
