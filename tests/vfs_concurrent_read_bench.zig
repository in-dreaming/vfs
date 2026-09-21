//! Sequential vs concurrent VFS read benchmark.
//!
//! Scenarios (see docs/vfs/multithread_read.md §9.1):
//! - cold / warm reads of disjoint files (per-miss-byte throughput reported)
//! - same-file random warm reads (page cache hit contention)
//! - "optimized" pack (objects in the base index, the production layout)
//! - explicit page refs (writable pack output; per-hit crc/hash history)
//! - the C ABI path (handle registry + vfs_read_at)
//! - whole-file streaming reads with a tiny cache (miss path, no cache benefit)
//!
//! Run with: zig build bench-read -Doptimize=ReleaseFast [-- <max_threads>]
const std = @import("std");
const vfs = @import("vfs");

const builder = vfs.build.pack_builder;
const Volume = vfs.volume.volume.Volume;
const abi = vfs.abi;
const kv = @import("db_internal").kv_db;

const page_size: u32 = 64 * 1024;
// 8 x 4 MiB = 512 pages: stays under the default delta-index capacity of a
// freshly built (non-optimized) pack while giving 8 threads disjoint files.
const file_bytes: usize = 4 * 1024 * 1024;
const file_count: usize = 8;
const default_thread_counts = [_]u32{ 1, 2, 4, 8 };

var thread_counts_buf: [8]u32 = undefined;
var thread_counts: []const u32 = &default_thread_counts;

pub fn main(init: std.process.Init) !void {
    var stdout_buf: [1024]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(init.io, &stdout_buf);
    const out = &stdout_writer.interface;
    const io = init.io;

    try selectThreadCounts(init);

    const pack_path = "zig-cache-vfs-concurrent-bench-pack";
    const opt_pack_path = "zig-cache-vfs-concurrent-bench-pack-opt";
    const ref_pack_path = "zig-cache-vfs-concurrent-bench-pack-ref";
    for ([_][]const u8{ pack_path, opt_pack_path, ref_pack_path }) |p| _ = std.Io.Dir.cwd().deleteTree(io, p) catch {};
    defer for ([_][]const u8{ pack_path, opt_pack_path, ref_pack_path }) |p| {
        _ = std.Io.Dir.cwd().deleteTree(io, p) catch {};
    };

    try out.print("cpu threads={d}  bench threads={any}  crc32c hardware={}\n", .{ std.Thread.getCpuCount() catch 0, thread_counts, @import("db_internal").format.crc32c_impl.has_hardware });
    try out.print("preparing {d} x {d} MiB packs (page={d} KiB)...\n", .{ file_count, file_bytes / (1024 * 1024), page_size / 1024 });
    try out.flush();
    try preparePack(pack_path);
    try preparePack(opt_pack_path);
    try optimizePack(opt_pack_path);
    try prepareExplicitRefPack(ref_pack_path);

    const warm_repeats: u32 = 16;
    {
        var volume = try Volume.open("bench-root", .{});
        defer volume.close();
        try volume.mountPackWithPriority(pack_path, 1, 0);

        try out.print("\n== delta pack | disjoint cold (WS {d} MiB, cache 8 MiB, eviction pressure) ==\n", .{file_count * file_bytes / (1024 * 1024)});
        try benchDisjointFiles(out, io, &volume, 8 * 1024 * 1024, 1, true, 0);
        try out.print("\n== delta pack | disjoint cold (WS {d} MiB, cache 128 MiB, no eviction) ==\n", .{file_count * file_bytes / (1024 * 1024)});
        try benchDisjointFiles(out, io, &volume, 128 * 1024 * 1024, 1, true, 0);
        try out.print("\n== delta pack | disjoint warm x{d} (cache 128 MiB, memcpy/lock) ==\n", .{warm_repeats});
        try benchDisjointWarm(out, io, &volume, 128 * 1024 * 1024, warm_repeats);
        try out.print("\n== delta pack | same file random warm (cache hits, lock contention) ==\n", .{});
        try benchSameFileRandom(out, io, &volume);
        try out.print("\n== delta pack | whole-file loads, cache 1 MiB (miss path + eviction) ==\n", .{});
        try benchDisjointFiles(out, io, &volume, 1024 * 1024, 1, true, 0);
        try out.print("\n== delta pack | whole-file loads with VFS_OPEN_STREAMING (cache bypass) ==\n", .{});
        try benchDisjointFiles(out, io, &volume, 1024 * 1024, 1, true, vfs.io.file_handle.OPEN_FLAG_STREAMING);
    }

    try out.print("\n== read handle pool sensitivity | cold disjoint, streaming, cache 1 MiB ==\n", .{});
    for ([_]u8{ 0, 1, 4, 8 }) |handles| {
        var volume = try Volume.open("bench-root-handles", .{ .read_handles = handles });
        defer volume.close();
        try volume.mountPackWithPriority(pack_path, 1, 0);
        try out.print("  -- read_handles={d} --\n", .{handles});
        try benchDisjointFiles(out, io, &volume, 1024 * 1024, 1, true, vfs.io.file_handle.OPEN_FLAG_STREAMING);
    }

    {
        var volume = try Volume.open("bench-root-opt", .{});
        defer volume.close();
        try volume.mountPackWithPriority(opt_pack_path, 1, 0);
        try out.print("\n== optimized pack (base index) | disjoint cold (cache 128 MiB) ==\n", .{});
        try benchDisjointFiles(out, io, &volume, 128 * 1024 * 1024, 1, true, 0);
        try out.print("\n== optimized pack (base index) | whole-file loads, cache 1 MiB ==\n", .{});
        try benchDisjointFiles(out, io, &volume, 1024 * 1024, 1, true, 0);
    }

    {
        var volume = try Volume.open("bench-root-ref", .{});
        defer volume.close();
        try volume.mountPackWithPriority(ref_pack_path, 1, 0);
        try out.print("\n== explicit page refs | disjoint cold (cache 128 MiB) ==\n", .{});
        try benchDisjointFiles(out, io, &volume, 128 * 1024 * 1024, 1, true, 0);
        try out.print("\n== explicit page refs | disjoint warm x{d} (verified once at load) ==\n", .{warm_repeats});
        try benchDisjointWarm(out, io, &volume, 128 * 1024 * 1024, warm_repeats);
    }

    try out.print("\n== C ABI | disjoint warm via vfs_read_at (handle registry + volume) ==\n", .{});
    try benchAbiWarm(out, io, pack_path);
    try out.flush();
}

fn selectThreadCounts(init: std.process.Init) !void {
    var args = try init.minimal.args.iterateAllocator(init.arena.allocator());
    _ = args.next();
    const arg = args.next() orelse return;
    const max_threads = std.fmt.parseInt(u32, arg, 10) catch return;
    var n: usize = 0;
    var t: u32 = 1;
    while (t <= max_threads and n < thread_counts_buf.len) : (t *= 2) {
        thread_counts_buf[n] = t;
        n += 1;
    }
    if (n != 0) thread_counts = thread_counts_buf[0..n];
}

fn fillPayload(payload: []u8, seed: usize) void {
    for (payload, 0..) |*b, i| b.* = @truncate((i +% seed * 977) *% 131);
}

fn preparePack(pack_path: []const u8) !void {
    const allocator = std.heap.smp_allocator;
    const payload = try allocator.alloc(u8, file_bytes);
    defer allocator.free(payload);

    var inputs: [file_count]builder.BuildFileInput = undefined;
    var source_paths: [file_count][64]u8 = undefined;
    var virtual_paths: [file_count][16]u8 = undefined;
    var i: usize = 0;
    while (i < file_count) : (i += 1) {
        fillPayload(payload, i);
        const source = try std.fmt.bufPrint(&source_paths[i], "zig-cache-vfs-concurrent-bench-{d}.bin", .{i});
        try builder.writeSourceFileForTest(source, payload);
        inputs[i] = .{
            .source_path = source,
            .virtual_path = try std.fmt.bufPrint(&virtual_paths[i], "/f{d}.bin", .{i}),
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

fn optimizePack(pack_path: []const u8) !void {
    var db = try kv.KvDb.open(pack_path, .{ .mode = .read_write, .create_if_missing = false, .max_delta_entries = 4096 });
    defer db.close() catch {};
    try db.optimize();
}

/// Files written through the writable-pack path get BLOCK_FLAG_EXPLICIT_PAGE_REFS
/// manifests, so every page read carries a crc + content-hash expectation.
fn prepareExplicitRefPack(pack_path: []const u8) !void {
    const allocator = std.heap.smp_allocator;
    const payload = try allocator.alloc(u8, file_bytes);
    defer allocator.free(payload);
    var volume = try Volume.open("bench-ref-writer", .{});
    defer volume.close();
    try volume.setWritablePack(pack_path);
    var i: usize = 0;
    while (i < file_count) : (i += 1) {
        fillPayload(payload, i);
        try volume.writeFileByEntry(1000 + i, payload, .{ .page_size = page_size });
    }
}

const Job = struct {
    volume: *Volume,
    file_entry: u64,
    offset: u64,
    len: u64,
    repeats: u32,
    errors: *std.atomic.Value(u32),
    open_flags: u32 = 0,

    fn runFullFile(job: *const Job) void {
        var handle = job.volume.openEntryWithFlags(1, job.file_entry, job.open_flags) catch {
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
    volume: *Volume,
    cache_budget: usize,
    repeats: u32,
    flush_each: bool,
    open_flags: u32,
) !void {
    const bytes_per_pass = file_count * file_bytes * repeats;
    var baseline_ns: u64 = 0;
    for (thread_counts) |threads| {
        if (flush_each) flushCache(volume, cache_budget);
        const before = volume.page_cache.stats();
        const ns = try runDisjoint(io, volume, threads, repeats, open_flags);
        const after = volume.page_cache.stats();
        const misses = after.misses - before.misses;
        const miss_bytes = misses * page_size;
        const mbps = mbPerSec(bytes_per_pass, ns);
        if (threads == 1) baseline_ns = ns;
        const speedup = @as(f64, @floatFromInt(baseline_ns)) / @as(f64, @floatFromInt(ns));
        try out.print("  {d:>2} thread(s): {d:>8.1} ms  {d:>8.1} MiB/s  {d:>5.2}x  hits={d:<5} misses={d:<5} coalesced={d:<4} evict={d:<5}", .{
            threads,
            @as(f64, @floatFromInt(ns)) / 1e6,
            mbps,
            speedup,
            after.hits - before.hits,
            misses,
            after.coalesced - before.coalesced,
            after.evictions - before.evictions,
        });
        if (misses != 0) {
            try out.print("  miss-path {d:>8.1} MiB/s  {d:>6.1} us/page", .{ mbPerSec(miss_bytes, ns), @as(f64, @floatFromInt(ns)) / 1000.0 / @as(f64, @floatFromInt(misses)) });
        }
        try out.print("\n", .{});
        try out.flush();
    }
}

fn benchDisjointWarm(out: *std.Io.Writer, io: std.Io, volume: *Volume, cache_budget: usize, repeats: u32) !void {
    flushCache(volume, cache_budget);
    _ = try runDisjoint(io, volume, 1, 1, 0);
    try benchDisjointFiles(out, io, volume, cache_budget, repeats, false, 0);
}

fn benchSameFileRandom(out: *std.Io.Writer, io: std.Io, volume: *Volume) !void {
    const total_pages: u32 = 65536;
    var handle = try volume.openEntry(1, 1000);
    var warmup: [page_size]u8 = undefined;
    var off: u64 = 0;
    while (off < file_bytes) : (off += page_size) _ = try handle.readAt(off, &warmup);
    handle.close();

    var baseline_ns: u64 = 0;
    for (thread_counts) |threads| {
        const per = total_pages / threads;
        const before = volume.page_cache.stats();
        const ns = try runRandom(io, volume, threads, per);
        const after = volume.page_cache.stats();
        const ops = @as(f64, @floatFromInt(total_pages)) / (@as(f64, @floatFromInt(ns)) / 1e9);
        if (threads == 1) baseline_ns = ns;
        const speedup = @as(f64, @floatFromInt(baseline_ns)) / @as(f64, @floatFromInt(ns));
        try out.print("  {d:>2} thread(s): {d:>8.1} ms  {d:>9.0} pages/s  {d:>8.1} MiB/s  {d:>5.2}x  hits={d} misses={d}\n", .{
            threads,
            @as(f64, @floatFromInt(ns)) / 1e6,
            ops,
            mbPerSec(@as(usize, total_pages) * page_size, ns),
            speedup,
            after.hits - before.hits,
            after.misses - before.misses,
        });
        try out.flush();
    }
}

fn runDisjoint(io: std.Io, volume: *Volume, threads: u32, repeats: u32, open_flags: u32) !u64 {
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
            .open_flags = open_flags,
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
        const n: usize = @min(threads, file_count);
        const per = file_count / n;
        var spawned: [file_count]std.Thread = undefined;
        var t: usize = 0;
        while (t < n) : (t += 1) {
            const begin = t * per;
            const end = if (t + 1 == n) file_count else begin + per;
            spawned[t] = try std.Thread.spawn(.{}, Worker.run, .{jobs[begin..end]});
        }
        t = 0;
        while (t < n) : (t += 1) spawned[t].join();
    }
    const elapsed: u64 = nowNs(io) - start;
    if (errors.load(.seq_cst) != 0) return error.BenchFailed;
    return elapsed;
}

fn runRandom(io: std.Io, volume: *Volume, threads: u32, repeats: u32) !u64 {
    var errors = std.atomic.Value(u32).init(0);
    var jobs: [16]Job = undefined;
    var spawned: [16]std.Thread = undefined;
    const n: usize = @min(threads, jobs.len);
    var t: usize = 0;
    while (t < n) : (t += 1) {
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
    if (n == 1) {
        Job.runRandomPages(&jobs[0]);
    } else {
        t = 0;
        while (t < n) : (t += 1) {
            spawned[t] = try std.Thread.spawn(.{}, Job.runRandomPages, .{&jobs[t]});
        }
        t = 0;
        while (t < n) : (t += 1) spawned[t].join();
    }
    const elapsed: u64 = nowNs(io) - start;
    if (errors.load(.seq_cst) != 0) return error.BenchFailed;
    return elapsed;
}

// ---------------------------------------------------------------------------
// C ABI path
// ---------------------------------------------------------------------------

const AbiJob = struct {
    volume: u64,
    file_entry: u64,
    repeats: u32,
    errors: *std.atomic.Value(u32),

    fn run(job: *const AbiJob) void {
        var file: u64 = 0;
        if (abi.vfs_open_entry(job.volume, job.file_entry, 0, &file) != 0) {
            _ = job.errors.fetchAdd(1, .seq_cst);
            return;
        }
        defer _ = abi.vfs_close_file(file);
        const buf = std.heap.smp_allocator.alloc(u8, page_size) catch {
            _ = job.errors.fetchAdd(1, .seq_cst);
            return;
        };
        defer std.heap.smp_allocator.free(buf);
        var r: u32 = 0;
        while (r < job.repeats) : (r += 1) {
            var off: u64 = 0;
            while (off < file_bytes) {
                var n: u64 = 0;
                if (abi.vfs_read_at(file, off, buf.ptr, buf.len, &n) != 0 or n == 0) {
                    _ = job.errors.fetchAdd(1, .seq_cst);
                    return;
                }
                off += n;
            }
        }
    }
};

fn benchAbiWarm(out: *std.Io.Writer, io: std.Io, pack_path: []const u8) !void {
    const z_pack = try std.heap.smp_allocator.dupeZ(u8, pack_path);
    defer std.heap.smp_allocator.free(z_pack);
    var volume: u64 = 0;
    if (abi.vfs_open_volume("abi-bench", null, &volume) != 0) return error.BenchFailed;
    defer _ = abi.vfs_close_volume(volume);
    if (abi.vfs_mount_pack(volume, z_pack.ptr, 1, 0) != 0) return error.BenchFailed;
    const v: *Volume = @ptrFromInt(volume);
    flushCache(v, 128 * 1024 * 1024);

    const repeats: u32 = 16;
    var errors = std.atomic.Value(u32).init(0);
    // warm
    {
        var i: usize = 0;
        while (i < file_count) : (i += 1) {
            const job = AbiJob{ .volume = volume, .file_entry = 1000 + i, .repeats = 1, .errors = &errors };
            job.run();
        }
        if (errors.load(.seq_cst) != 0) return error.BenchFailed;
    }
    var baseline_ns: u64 = 0;
    for (thread_counts) |threads| {
        var jobs: [file_count]AbiJob = undefined;
        var i: usize = 0;
        while (i < file_count) : (i += 1) jobs[i] = .{ .volume = volume, .file_entry = 1000 + i, .repeats = repeats, .errors = &errors };
        const Worker = struct {
            fn run(slice: []AbiJob) void {
                for (slice) |*job| job.run();
            }
        };
        const start = nowNs(io);
        if (threads == 1) {
            Worker.run(jobs[0..]);
        } else {
            const n: usize = @min(threads, file_count);
            const per = file_count / n;
            var spawned: [file_count]std.Thread = undefined;
            var t: usize = 0;
            while (t < n) : (t += 1) {
                const begin = t * per;
                const end = if (t + 1 == n) file_count else begin + per;
                spawned[t] = try std.Thread.spawn(.{}, Worker.run, .{jobs[begin..end]});
            }
            t = 0;
            while (t < n) : (t += 1) spawned[t].join();
        }
        const ns = nowNs(io) - start;
        if (errors.load(.seq_cst) != 0) return error.BenchFailed;
        if (threads == 1) baseline_ns = ns;
        const speedup = @as(f64, @floatFromInt(baseline_ns)) / @as(f64, @floatFromInt(ns));
        try out.print("  {d:>2} thread(s): {d:>8.1} ms  {d:>8.1} MiB/s  {d:>5.2}x\n", .{
            threads,
            @as(f64, @floatFromInt(ns)) / 1e6,
            mbPerSec(file_count * file_bytes * repeats, ns),
            speedup,
        });
        try out.flush();
    }
}

fn nowNs(io: std.Io) u64 {
    return @intCast(std.Io.Clock.awake.now(io).nanoseconds);
}

fn flushCache(volume: *Volume, budget_bytes: usize) void {
    volume.page_cache.deinit(std.heap.smp_allocator);
    volume.page_cache.budget_bytes = budget_bytes;
}

fn mbPerSec(bytes: usize, ns: u64) f64 {
    const sec = @as(f64, @floatFromInt(ns)) / 1e9;
    return @as(f64, @floatFromInt(bytes)) / (1024.0 * 1024.0) / sec;
}
