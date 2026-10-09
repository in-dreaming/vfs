const std = @import("std");
const err = @import("error.zig");
const registry = @import("handle_registry.zig");
const volume_mod = @import("volume/volume.zig");
const file_mod = @import("io/file_handle.zig");
const patch_mod = @import("patch/root.zig");
const task_sched = @import("task/scheduler.zig");
const reads = @import("io/read_requests.zig");

pub const vfs_open_options_t = extern struct {
    struct_size: u32,
    flags: u32,
    /// Decoded page cache budget in bytes; 0 = default.
    page_cache_bytes: u64 = 0,
    max_open_stores: u32 = 0,
    /// Extra read-only OS handles per pack data file; 0 = default.
    read_handles: u32 = 0,
    read_workers: u32 = 0,
    max_requests: u32 = 0,
    max_ranges_per_request: u32 = 0,
    reserved: u32 = 0,
    read_scratch_bytes: u64 = 0,
};

pub const vfs_stat_t = extern struct {
    struct_size: u32,
    flags: u32,
    file_entry: u64,
    size: u64,
    page_size: u64,
    reserved0: u64,
};

threadlocal var last_status: c_int = err.code(.ok);
threadlocal var last_error: [256]u8 = [_]u8{0} ** 256;

fn setStatus(status: err.Status, msg: []const u8) c_int {
    last_status = err.code(status);
    @memset(&last_error, 0);
    const n = @min(msg.len, last_error.len - 1);
    @memcpy(last_error[0..n], msg[0..n]);
    return last_status;
}

fn setError(e: anyerror) c_int {
    return setStatus(err.fromError(e), @errorName(e));
}

fn setOk() c_int {
    return setStatus(.ok, "ok");
}

fn spanZ(ptr: ?[*:0]const u8) ![]const u8 {
    const p = ptr orelse return error.InvalidArgument;
    const s = std.mem.span(p);
    if (s.len == 0) return error.InvalidArgument;
    return s;
}

fn optionsFromC(options: ?*const vfs_open_options_t) !volume_mod.OpenOptions {
    const opts = options orelse return .{};
    if (opts.struct_size < @offsetOf(vfs_open_options_t, "flags") + @sizeOf(u32)) return error.InvalidArgument;
    var out = volume_mod.OpenOptions{ .flags = opts.flags };
    if (opts.struct_size >= @offsetOf(vfs_open_options_t, "page_cache_bytes") + @sizeOf(u64) and opts.page_cache_bytes != 0) {
        out.page_cache_bytes = std.math.cast(usize, opts.page_cache_bytes) orelse return error.InvalidArgument;
    }
    if (opts.struct_size >= @offsetOf(vfs_open_options_t, "max_open_stores") + @sizeOf(u32) and opts.max_open_stores != 0) {
        out.max_open_stores = opts.max_open_stores;
    }
    if (opts.struct_size >= @offsetOf(vfs_open_options_t, "read_handles") + @sizeOf(u32) and opts.read_handles != 0) {
        out.read_handles = std.math.cast(u8, opts.read_handles) orelse return error.InvalidArgument;
    }
    inline for (.{ .{ "read_workers", "workers" }, .{ "max_requests", "max_requests" }, .{ "max_ranges_per_request", "max_ranges" } }) |names| {
        if (opts.struct_size >= @offsetOf(vfs_open_options_t, names[0]) + @sizeOf(u32) and @field(opts, names[0]) != 0) @field(out.reads, names[1]) = @field(opts, names[0]);
    }
    if (opts.struct_size >= @offsetOf(vfs_open_options_t, "read_scratch_bytes") + @sizeOf(u64) and opts.read_scratch_bytes != 0) out.reads.scratch_bytes = std.math.cast(usize, opts.read_scratch_bytes) orelse return error.InvalidArgument;
    try out.reads.validate();
    return out;
}

pub export fn vfs_last_status() c_int {
    return last_status;
}

pub export fn vfs_last_error_message() [*:0]const u8 {
    return @ptrCast(&last_error);
}

pub export fn vfs_open_volume(path: ?[*:0]const u8, options: ?*const vfs_open_options_t, out_volume: ?*u64) c_int {
    const out = out_volume orelse return setStatus(.invalid_argument, "out_volume is null");
    out.* = 0;
    const p = spanZ(path) catch |e| return setError(e);
    const opts = optionsFromC(options) catch |e| return setError(e);
    const v = std.heap.smp_allocator.create(volume_mod.Volume) catch return setStatus(.internal_error, "allocation failed");
    v.* = volume_mod.Volume.open(p, opts) catch |e| {
        std.heap.smp_allocator.destroy(v);
        return setError(e);
    };
    const h = registry.register(v, .volume) catch |e| {
        v.close();
        std.heap.smp_allocator.destroy(v);
        return setError(e);
    };
    out.* = h;
    return setOk();
}

pub export fn vfs_close_volume(volume: u64) c_int {
    const v = registry.takeIdle(volume_mod.Volume, volume, .volume) catch |e| return setError(e);
    v.close();
    std.heap.smp_allocator.destroy(v);
    return setOk();
}

pub export fn vfs_mount_pack(volume: u64, pack_path: ?[*:0]const u8, priority: u32, flags: u32) c_int {
    const retained = registry.acquire(volume_mod.Volume, volume, .volume) catch |e| return setError(e);
    defer retained.release();
    const v = retained.ptr;
    const path = spanZ(pack_path) catch |e| return setError(e);
    v.mountPackWithPriority(path, priority, flags) catch |e| return setError(e);
    return setOk();
}

/// Accepted `flags` for vfs_open_path / vfs_open_entry (mirrors vfs.h).
pub const VFS_OPEN_STREAMING: u32 = file_mod.OPEN_FLAG_STREAMING;
const OPEN_FLAGS_MASK: u32 = VFS_OPEN_STREAMING;

pub export fn vfs_open_path(volume: u64, path: ?[*:0]const u8, flags: u32, out_file: ?*u64) c_int {
    const out = out_file orelse return setStatus(.invalid_argument, "out_file is null");
    out.* = 0;
    if ((flags & ~OPEN_FLAGS_MASK) != 0) return setStatus(.invalid_argument, "unknown open flags");
    const retained = registry.acquire(volume_mod.Volume, volume, .volume) catch |e| return setError(e);
    defer retained.release();
    const v = retained.ptr;
    const p = spanZ(path) catch |e| return setError(e);
    return openFileHandle(retained, out, v.openPathWithFlags(volume, p, flags));
}

pub export fn vfs_open_entry(volume: u64, file_entry: u64, flags: u32, out_file: ?*u64) c_int {
    const out = out_file orelse return setStatus(.invalid_argument, "out_file is null");
    out.* = 0;
    if ((flags & ~OPEN_FLAGS_MASK) != 0) return setStatus(.invalid_argument, "unknown open flags");
    const retained = registry.acquire(volume_mod.Volume, volume, .volume) catch |e| return setError(e);
    defer retained.release();
    const v = retained.ptr;
    if (file_entry == 0) return setStatus(.invalid_argument, "file_entry is zero");
    return openFileHandle(retained, out, v.openEntryWithFlags(volume, file_entry, flags));
}

pub export fn vfs_stat_path(volume: u64, path: ?[*:0]const u8, out_stat: ?*vfs_stat_t) c_int {
    const out = out_stat orelse return setStatus(.invalid_argument, "out_stat is null");
    const requested = out.struct_size;
    if (requested < @sizeOf(u32)) return setStatus(.invalid_argument, "struct_size too small");
    @memset(@as([*]u8, @ptrCast(out))[0..@min(@as(usize, @intCast(requested)), @sizeOf(vfs_stat_t))], 0);
    out.struct_size = requested;
    const retained = registry.acquire(volume_mod.Volume, volume, .volume) catch |e| return setError(e);
    defer retained.release();
    const v = retained.ptr;
    const p = spanZ(path) catch |e| return setError(e);
    const st = v.statPath(p) catch |e| return setError(e);
    fillStat(out, requested, st);
    return setOk();
}

pub export fn vfs_stat_entry(volume: u64, file_entry: u64, out_stat: ?*vfs_stat_t) c_int {
    const out = out_stat orelse return setStatus(.invalid_argument, "out_stat is null");
    const requested = out.struct_size;
    if (requested < @sizeOf(u32)) return setStatus(.invalid_argument, "struct_size too small");
    @memset(@as([*]u8, @ptrCast(out))[0..@min(@as(usize, @intCast(requested)), @sizeOf(vfs_stat_t))], 0);
    out.struct_size = requested;
    const retained = registry.acquire(volume_mod.Volume, volume, .volume) catch |e| return setError(e);
    defer retained.release();
    const v = retained.ptr;
    if (file_entry == 0) return setStatus(.invalid_argument, "file_entry is zero");
    const st = v.statEntry(file_entry) catch |e| return setError(e);
    fillStat(out, requested, st);
    return setOk();
}

pub export fn vfs_read_at(file: u64, offset: u64, dst: ?*anyopaque, size: u64, out_read: ?*u64) c_int {
    const out = out_read orelse return setStatus(.invalid_argument, "out_read is null");
    out.* = 0;
    if (size != 0 and dst == null) return setStatus(.invalid_argument, "dst is null");
    const retained = registry.acquire(file_mod.FileHandle, file, .file) catch |e| return setError(e);
    defer retained.release();
    const f = retained.ptr;
    const len = std.math.cast(usize, size) orelse return setStatus(.invalid_argument, "size too large");
    var empty: [0]u8 = .{};
    const buf = if (len == 0) empty[0..] else @as([*]u8, @ptrCast(dst.?))[0..len];
    out.* = f.readAt(offset, buf) catch |e| return setError(e);
    return setOk();
}

pub export fn vfs_close_file(file: u64) c_int {
    const f = registry.take(file_mod.FileHandle, file, .file) catch |e| return setError(e);
    f.close();
    std.heap.smp_allocator.destroy(f);
    return setOk();
}

fn openFileHandle(volume_lease: registry.Lease(volume_mod.Volume), out: *u64, result: anyerror!file_mod.FileHandle) c_int {
    var value = result catch |e| return setError(e);
    const f = std.heap.smp_allocator.create(file_mod.FileHandle) catch {
        value.close();
        return setStatus(.internal_error, "allocation failed");
    };
    f.* = value;
    f.volume_lease = volume_lease.retain();
    const h = registry.register(f, .file) catch |e| {
        f.close();
        std.heap.smp_allocator.destroy(f);
        return setError(e);
    };
    out.* = h;
    return setOk();
}

fn fillStat(out: *vfs_stat_t, requested: u32, st: @import("pack/pack_reader.zig").Stat) void {
    const full: vfs_stat_t = .{ .struct_size = requested, .flags = 0, .file_entry = st.file_entry, .size = st.size, .page_size = st.page_size, .reserved0 = 0 };
    const n = @min(@as(usize, requested), @sizeOf(vfs_stat_t));
    @memcpy(@as([*]u8, @ptrCast(out))[0..n], std.mem.asBytes(&full)[0..n]);
}

// ---- bounded polling read requests -----------------------------------------
pub const vfs_read_range_t = reads.Range;
pub const vfs_read_options_t = extern struct { struct_size: u32, flags: u32, priority: i32 = 0, reserved: u32 = 0 };
pub const vfs_request_progress_t = extern struct { struct_size: u32, state: u32, ranges_total: u32, ranges_done: u32, bytes_read: u64, last_status: i32, reserved: u32 = 0 };
pub const vfs_read_result_t = extern struct { struct_size: u32, state: u32, bytes_read: u64, last_status: i32, reserved: u32 = 0 };
pub const vfs_stats_t = extern struct {
    struct_size: u32,
    flags: u32 = 0,
    cache_hits: u64,
    cache_misses: u64,
    cache_coalesced: u64,
    cache_evictions: u64,
    cache_resident_bytes: u64,
    cache_allocated_bytes: u64,
    cache_peak_bytes: u64,
    cache_inflight_bytes: u64,
    cache_pinned_bytes: u64,
    cache_evicted_pinned_bytes: u64,
    requests_queued: u64,
    requests_running: u64,
    requests_retained: u64,
    requests_completed: u64,
    requests_failed: u64,
    requests_cancelled: u64,
    requests_rejected: u64,
    bytes_read: u64,
    bytes_prefetched: u64,
    open_stores: u64,
    cache_limit_bytes: u64,
    scratch_limit_per_worker: u64,
    worker_limit: u32,
    request_limit: u32,
    ranges_limit: u32,
    backend: u32,
    scratch_retained_bytes: u64,
    scratch_peak_worker_bytes: u64,
};

fn readPriority(options: ?*const vfs_read_options_t, prefetch: bool) !i32 {
    const o = options orelse return if (prefetch) -1 else 0;
    if (o.struct_size < 8 or o.flags != 0) return error.InvalidArgument;
    return if (o.struct_size >= @offsetOf(vfs_read_options_t, "priority") + 4) o.priority else if (prefetch) -1 else 0;
}

fn submitRead(file: u64, ranges: []const reads.Range, options: ?*const vfs_read_options_t, prefetch: bool, out_request: ?*u64) c_int {
    const out = out_request orelse return setError(error.InvalidArgument);
    out.* = 0;
    const priority = readPriority(options, prefetch) catch |e| return setError(e);
    const retained = registry.acquire(file_mod.FileHandle, file, .file) catch |e| return setError(e);
    defer retained.release();
    const pool = retained.ptr.volume.readExecutor() catch |e| return setError(e);
    out.* = pool.submit(retained, ranges, priority, prefetch) catch |e| return setError(e);
    return setOk();
}

pub export fn vfs_read_async(file: u64, offset: u64, dst: ?*anyopaque, size: u64, options: ?*const vfs_read_options_t, out_request: ?*u64) c_int {
    return submitRead(file, &.{.{ .offset = offset, .dst = dst, .size = size }}, options, false, out_request);
}
pub export fn vfs_read_batch_async(file: u64, ranges: ?[*]const vfs_read_range_t, count: u32, options: ?*const vfs_read_options_t, out_request: ?*u64) c_int {
    if (out_request) |out| out.* = 0;
    const items = ranges orelse return setError(error.InvalidArgument);
    if (count == 0) return setError(error.InvalidArgument);
    return submitRead(file, items[0..count], options, false, out_request);
}
pub export fn vfs_prefetch_async(file: u64, offset: u64, size: u64, options: ?*const vfs_read_options_t, out_request: ?*u64) c_int {
    return submitRead(file, &.{.{ .offset = offset, .dst = null, .size = size }}, options, true, out_request);
}

fn outputPrefix(comptime T: type, out: *T, value: *const T) void {
    const n = @min(@as(usize, out.struct_size), @sizeOf(T));
    @memcpy(@as([*]u8, @ptrCast(out))[0..n], std.mem.asBytes(value)[0..n]);
}

pub export fn vfs_request_poll(request: u64, output: ?*vfs_request_progress_t) c_int {
    const out = output orelse return setError(error.InvalidArgument);
    if (out.struct_size < 8) return setError(error.InvalidArgument);
    const lease = registry.acquire(reads.Request, request, .request) catch |e| return setError(e);
    defer lease.release();
    const p = lease.ptr.snapshot();
    const full: vfs_request_progress_t = .{ .struct_size = out.struct_size, .state = @intFromEnum(p.state), .ranges_total = p.ranges_total, .ranges_done = p.ranges_done, .bytes_read = p.bytes, .last_status = err.code(p.status) };
    outputPrefix(vfs_request_progress_t, out, &full);
    return setOk();
}
pub export fn vfs_request_result(request: u64, index: u32, output: ?*vfs_read_result_t) c_int {
    const out = output orelse return setError(error.InvalidArgument);
    if (out.struct_size < 8) return setError(error.InvalidArgument);
    const lease = registry.acquire(reads.Request, request, .request) catch |e| return setError(e);
    defer lease.release();
    const r = lease.ptr.result(index) catch |e| return setError(e);
    const full: vfs_read_result_t = .{ .struct_size = out.struct_size, .state = @intFromEnum(r.state), .bytes_read = r.bytes, .last_status = err.code(r.status) };
    outputPrefix(vfs_read_result_t, out, &full);
    return setOk();
}
pub export fn vfs_request_wait(request: u64, timeout_ms: u32) c_int {
    const deadline = task_sched.nowNs() + @as(i128, timeout_ms) * std.time.ns_per_ms;
    while (true) {
        const lease = registry.acquire(reads.Request, request, .request) catch |e| return setError(e);
        const finished = reads.terminal(lease.ptr.snapshot().state);
        lease.release();
        if (finished) return setOk();
        if (task_sched.nowNs() >= deadline) return setError(error.Busy);
        task_sched.sleepNs(500 * std.time.ns_per_us);
    }
}
pub export fn vfs_request_cancel(request: u64) c_int {
    const lease = registry.acquire(reads.Request, request, .request) catch |e| return setError(e);
    defer lease.release();
    lease.ptr.cancel();
    return setOk();
}
pub export fn vfs_request_end(request: u64) c_int {
    const job = registry.take(reads.Request, request, .request) catch |e| return setError(e);
    job.destroy();
    return setOk();
}
pub export fn vfs_get_stats(volume: u64, output: ?*vfs_stats_t) c_int {
    const out = output orelse return setError(error.InvalidArgument);
    if (out.struct_size < 8) return setError(error.InvalidArgument);
    const lease = registry.acquire(volume_mod.Volume, volume, .volume) catch |e| return setError(e);
    defer lease.release();
    const v = lease.ptr;
    // Update release clears the cache under Volume.lock. Read diagnostics
    // must not race cache reconstruction even though normal IO is admitted.
    v.lock.lock();
    defer v.lock.unlock();
    const c = v.page_cache.stats();
    const m = v.page_cache.memoryStats();
    const r = v.readStats();
    const full: vfs_stats_t = .{
        .struct_size = out.struct_size,
        .cache_hits = c.hits,
        .cache_misses = c.misses,
        .cache_coalesced = c.coalesced,
        .cache_evictions = c.evictions,
        .cache_resident_bytes = m.resident_bytes,
        .cache_allocated_bytes = m.allocated_bytes,
        .cache_peak_bytes = m.peak_allocated_bytes,
        .cache_inflight_bytes = m.inflight_bytes,
        .cache_pinned_bytes = m.pinned_bytes,
        .cache_evicted_pinned_bytes = m.evicted_pinned_bytes,
        .requests_queued = r.queued,
        .requests_running = r.running,
        .requests_retained = r.retained,
        .requests_completed = r.completed,
        .requests_failed = r.failed,
        .requests_cancelled = r.cancelled,
        .requests_rejected = r.rejected,
        .bytes_read = r.read_bytes,
        .bytes_prefetched = r.prefetch_bytes,
        .open_stores = v.readonlyReadyCountLockedForStats(),
        .cache_limit_bytes = v.options.page_cache_bytes,
        .scratch_limit_per_worker = v.options.reads.scratch_bytes,
        .worker_limit = v.options.reads.workers,
        .request_limit = v.options.reads.max_requests,
        .ranges_limit = v.options.reads.max_ranges,
        .backend = if (v.options.file_ops != null) 1 else 0,
        .scratch_retained_bytes = r.scratch_retained_bytes,
        .scratch_peak_worker_bytes = r.scratch_peak_worker_bytes,
    };
    outputPrefix(vfs_stats_t, out, &full);
    return setOk();
}

// ---- patch (polling, background thread) --------------------------------------

pub const vfs_patch_options_t = extern struct {
    struct_size: u32,
    flags: u32,
    threads: u32 = 0,
    batch_bytes: u32 = 0,
    in_memory_max_bytes: u64 = 0,
    verify: u32 = 0,
    reserved: u32 = 0,
    to_version: u64 = 0,
};

pub const vfs_patch_progress_t = extern struct {
    struct_size: u32,
    state: u32,
    units_total: u64,
    units_done: u64,
    bytes_written: u64,
    bytes_read: u64,
    last_status: i32,
    reserved: i32,
    from_version: u64,
    to_version: u64,
};

pub const VFS_PATCH_IN_MEMORY: u32 = 1 << 0;
pub const VFS_PATCH_DISK: u32 = 1 << 1;
pub const VFS_PATCH_FORCE: u32 = 1 << 2;
pub const VFS_PATCH_OPTIMIZE: u32 = 1 << 3;
const PATCH_FLAGS_MASK: u32 = VFS_PATCH_IN_MEMORY | VFS_PATCH_DISK | VFS_PATCH_FORCE | VFS_PATCH_OPTIMIZE;

pub const PatchState = enum(u32) { running = 0, done = 1, failed = 2, cancelled = 3 };

const PatchJob = struct {
    allocator: std.mem.Allocator,
    target: []u8,
    overlay: ?[]u8,
    diffs: [][]u8,
    to_version: ?u64,
    options: patch_mod.PatchOptions,
    volume_lease: ?registry.Lease(volume_mod.Volume) = null,
    update_lease: ?volume_mod.Volume.UpdateLease = null,
    progress: patch_mod.patch_session.Progress = .{},
    state: std.atomic.Value(u32) = .init(@intFromEnum(PatchState.running)),
    last_status: std.atomic.Value(i32) = .init(0),
    from_version: std.atomic.Value(u64) = .init(0),
    result_to_version: std.atomic.Value(u64) = .init(0),
    thread: ?std.Thread = null,

    fn deinit(self: *PatchJob) void {
        self.releaseUpdate(false, false) catch {};
        self.allocator.free(self.target);
        if (self.overlay) |o| self.allocator.free(o);
        for (self.diffs) |d| self.allocator.free(d);
        self.allocator.free(self.diffs);
    }

    fn releaseUpdate(self: *PatchJob, changed: bool, complete: bool) !void {
        defer {
            self.update_lease = null;
            if (self.volume_lease) |lease| lease.release();
            self.volume_lease = null;
        }
        if (self.update_lease) |*lease| try lease.release(changed, complete);
    }

    fn main(self: *PatchJob) void {
        const diffs_const: []const []const u8 = @ptrCast(self.diffs);
        const report = patch_mod.run(self.allocator, self.target, self.overlay, diffs_const, self.to_version, self.options) catch |e| {
            // Cleanup precedes terminal publication. A partially written pack
            // stays blocked but its job and process admission are released.
            self.releaseUpdate(self.progress.mutation_started.load(.acquire), false) catch |refresh_error| {
                self.last_status.store(err.code(err.fromError(refresh_error)), .release);
                self.state.store(@intFromEnum(PatchState.failed), .release);
                return;
            };
            self.last_status.store(err.code(err.fromError(e)), .release);
            const st: PatchState = if (e == error.Cancelled) .cancelled else .failed;
            self.state.store(@intFromEnum(st), .release);
            return;
        };
        self.releaseUpdate(self.progress.mutation_started.load(.acquire), true) catch |e| {
            self.last_status.store(err.code(err.fromError(e)), .release);
            self.state.store(@intFromEnum(PatchState.failed), .release);
            return;
        };
        self.from_version.store(report.from_version, .release);
        self.result_to_version.store(report.to_version, .release);
        self.last_status.store(err.code(.ok), .release);
        self.state.store(@intFromEnum(PatchState.done), .release);
    }

    fn finished(self: *const PatchJob) bool {
        return self.state.load(.acquire) != @intFromEnum(PatchState.running);
    }

    fn join(self: *PatchJob) void {
        if (self.thread) |t| {
            t.join();
            self.thread = null;
        }
    }
};

fn patchOptionsFromC(options: ?*const vfs_patch_options_t) !struct { opts: patch_mod.PatchOptions, to: ?u64 } {
    var out: patch_mod.PatchOptions = .{};
    var to: ?u64 = null;
    const o = options orelse return .{ .opts = out, .to = to };
    if (o.struct_size < @offsetOf(vfs_patch_options_t, "flags") + @sizeOf(u32)) return error.InvalidArgument;
    if ((o.flags & ~PATCH_FLAGS_MASK) != 0) return error.InvalidArgument;
    if ((o.flags & VFS_PATCH_IN_MEMORY) != 0 and (o.flags & VFS_PATCH_DISK) != 0) return error.InvalidArgument;
    if ((o.flags & VFS_PATCH_IN_MEMORY) != 0) out.diff_load = .in_memory;
    if ((o.flags & VFS_PATCH_DISK) != 0) out.diff_load = .disk;
    out.force = (o.flags & VFS_PATCH_FORCE) != 0;
    out.optimize_after = (o.flags & VFS_PATCH_OPTIMIZE) != 0;
    if (o.struct_size >= @offsetOf(vfs_patch_options_t, "threads") + @sizeOf(u32) and o.threads != 0) {
        out.budget = out.budget.withThreads(std.math.cast(u8, o.threads) orelse return error.InvalidArgument);
    }
    if (o.struct_size >= @offsetOf(vfs_patch_options_t, "batch_bytes") + @sizeOf(u32) and o.batch_bytes != 0) out.writer.batch_bytes = o.batch_bytes;
    if (o.struct_size >= @offsetOf(vfs_patch_options_t, "in_memory_max_bytes") + @sizeOf(u64) and o.in_memory_max_bytes != 0) out.in_memory_max_bytes = o.in_memory_max_bytes;
    if (o.struct_size >= @offsetOf(vfs_patch_options_t, "verify") + @sizeOf(u32)) {
        out.verify_after = switch (o.verify) {
            0 => .none,
            1 => .touched,
            2 => .full,
            else => return error.InvalidArgument,
        };
    }
    if (o.struct_size >= @offsetOf(vfs_patch_options_t, "to_version") + @sizeOf(u64) and o.to_version != 0) to = o.to_version;
    return .{ .opts = out, .to = to };
}

pub export fn vfs_patch_begin(target_pack: ?[*:0]const u8, overlay_pack_or_null: ?[*:0]const u8, diff_dirs: ?[*]const ?[*:0]const u8, diff_count: u32, options: ?*const vfs_patch_options_t, out_patch: ?*u64) c_int {
    return patchBegin(target_pack, overlay_pack_or_null, diff_dirs, diff_count, options, out_patch, null, null);
}

/// Mounted update: paths come from the admitted mount, never from caller
/// aliases. The job retains its volume until terminal cleanup has completed.
pub export fn vfs_patch_begin_in_volume(volume: u64, pack_id: u64, diff_dirs: ?[*]const ?[*:0]const u8, diff_count: u32, options: ?*const vfs_patch_options_t, out_patch: ?*u64) c_int {
    const out = out_patch orelse return setStatus(.invalid_argument, "out_patch is null");
    out.* = 0;
    const retained = registry.acquire(volume_mod.Volume, volume, .volume) catch |e| return setError(e);
    const lease = retained.ptr.acquireUpdateLease(pack_id) catch |e| {
        retained.release();
        return setError(e);
    };
    // patchBegin takes ownership on every path, including allocation errors.
    return patchBegin(null, null, diff_dirs, diff_count, options, out_patch, retained, lease);
}

fn patchBegin(target_pack: ?[*:0]const u8, overlay_pack_or_null: ?[*:0]const u8, diff_dirs: ?[*]const ?[*:0]const u8, diff_count: u32, options: ?*const vfs_patch_options_t, out_patch: ?*u64, volume_lease: ?registry.Lease(volume_mod.Volume), update_lease: ?volume_mod.Volume.UpdateLease) c_int {
    var transferred = false;
    var incoming_update = update_lease;
    defer if (!transferred) {
        if (incoming_update) |*lease| lease.release(false, false) catch {};
        if (volume_lease) |lease| lease.release();
    };
    const out = out_patch orelse return setStatus(.invalid_argument, "out_patch is null");
    out.* = 0;
    const allocator = std.heap.smp_allocator;
    const target = if (incoming_update) |*lease| lease.targetPath() else spanZ(target_pack) catch |e| return setError(e);
    if (diff_count == 0) return setStatus(.invalid_argument, "diff_count is zero");
    const dirs = diff_dirs orelse return setStatus(.invalid_argument, "diff_dirs is null");
    const parsed = patchOptionsFromC(options) catch |e| return setError(e);

    const job = allocator.create(PatchJob) catch return setStatus(.internal_error, "allocation failed");
    job.* = .{ .allocator = allocator, .target = &.{}, .overlay = null, .diffs = &.{}, .to_version = parsed.to, .options = parsed.opts, .volume_lease = volume_lease, .update_lease = incoming_update };
    transferred = true;
    var ok = false;
    defer if (!ok) {
        job.deinit();
        allocator.destroy(job);
    };
    job.target = allocator.dupe(u8, target) catch return setStatus(.internal_error, "allocation failed");
    const overlay = if (incoming_update) |*lease| lease.overlayPath() else if (overlay_pack_or_null) |ov| spanZ(ov) catch |e| return setError(e) else null;
    if (overlay) |s| {
        job.overlay = allocator.dupe(u8, s) catch return setStatus(.internal_error, "allocation failed");
    }
    job.diffs = allocator.alloc([]u8, diff_count) catch return setStatus(.internal_error, "allocation failed");
    var filled: usize = 0;
    // Partially filled slices must not be freed as owned strings.
    for (job.diffs) |*d| d.* = &.{};
    while (filled < diff_count) : (filled += 1) {
        const s = spanZ(dirs[filled]) catch |e| return setError(e);
        job.diffs[filled] = allocator.dupe(u8, s) catch return setStatus(.internal_error, "allocation failed");
    }
    job.options.progress = &job.progress;

    const h = registry.register(job, .patch) catch |e| return setError(e);
    job.thread = std.Thread.spawn(.{}, PatchJob.main, .{job}) catch {
        _ = registry.take(PatchJob, h, .patch) catch unreachable;
        return setStatus(.internal_error, "thread spawn failed");
    };
    ok = true;
    out.* = h;
    return setOk();
}

pub export fn vfs_patch_poll(patch: u64, out_progress: ?*vfs_patch_progress_t) c_int {
    const out = out_progress orelse return setStatus(.invalid_argument, "out_progress is null");
    const requested = out.struct_size;
    if (requested < @offsetOf(vfs_patch_progress_t, "state") + @sizeOf(u32)) return setStatus(.invalid_argument, "struct_size too small");
    // Poll retains the job while taking its snapshot. End can invalidate the
    // public handle concurrently, but cannot free this retained object.
    const retained = registry.acquire(PatchJob, patch, .patch) catch |e| return setError(e);
    const job = retained.ptr;
    defer retained.release();
    var full: vfs_patch_progress_t = .{
        .struct_size = requested,
        .state = job.state.load(.acquire),
        .units_total = job.progress.units_total.load(.monotonic),
        .units_done = job.progress.units_done.load(.monotonic),
        .bytes_written = job.progress.bytes_written.load(.monotonic),
        .bytes_read = job.progress.bytes_read.load(.monotonic),
        .last_status = job.last_status.load(.acquire),
        .reserved = 0,
        .from_version = job.from_version.load(.acquire),
        .to_version = job.result_to_version.load(.acquire),
    };
    const n = @min(@as(usize, requested), @sizeOf(vfs_patch_progress_t));
    @memcpy(@as([*]u8, @ptrCast(out))[0..n], @as([*]u8, @ptrCast(&full))[0..n]);
    return setOk();
}

pub export fn vfs_patch_wait(patch: u64, timeout_ms: u32) c_int {
    const deadline = task_sched.nowNs() + @as(i128, timeout_ms) * std.time.ns_per_ms;
    while (true) {
        // Re-acquire per iteration so a concurrent end is not blocked for
        // the whole timeout and is observed as invalid_argument afterwards.
        const retained = registry.acquire(PatchJob, patch, .patch) catch |e| return setError(e);
        const job = retained.ptr;
        const finished = job.finished();
        retained.release();
        if (finished) return setOk();
        if (task_sched.nowNs() >= deadline) return setStatus(.busy, "patch still running");
        task_sched.sleepNs(500 * std.time.ns_per_us);
    }
}

pub export fn vfs_patch_cancel(patch: u64) c_int {
    const retained = registry.acquire(PatchJob, patch, .patch) catch |e| return setError(e);
    const job = retained.ptr;
    defer retained.release();
    job.progress.cancel.store(true, .release);
    return setOk();
}

pub export fn vfs_patch_end(patch: u64) c_int {
    // take() invalidates atomically, then drains this object's existing
    // leases without holding the map lock. Join also holds no registry lock.
    const job = registry.take(PatchJob, patch, .patch) catch |e| return setError(e);
    if (!job.finished()) job.progress.cancel.store(true, .release);
    job.join();
    const st: PatchState = @enumFromInt(job.state.load(.acquire));
    const status: err.Status = switch (st) {
        .done => .ok,
        .cancelled => .cancelled,
        .failed => @enumFromInt(job.last_status.load(.acquire)),
        .running => .internal_error,
    };
    job.deinit();
    std.heap.smp_allocator.destroy(job);
    return setStatus(status, @tagName(status));
}

test "vfs abi patch begin/poll/wait/end applies a diff and reports errors" {
    const fixture = @import("diff/test_fixture.zig");
    const diff_writer = @import("diff/diff_pack_writer.zig");
    const a = std.testing.allocator;
    var ds = try fixture.dataset(a);
    defer ds.deinit();
    const v1 = "zig-cache-vfs-abi-patch-v1";
    const v2 = "zig-cache-vfs-abi-patch-v2";
    const d12 = "zig-cache-vfs-abi-patch-d12";
    defer fixture.cleanup(v1);
    defer fixture.cleanup(v2);
    defer fixture.cleanup(d12);
    try fixture.buildPack(a, "zig-cache-vfs-abi-patch-fx1", v1, ds.v1, 31, 1, 2);
    try fixture.buildPack(a, "zig-cache-vfs-abi-patch-fx2", v2, ds.v2, 31, 2, 2);
    _ = try diff_writer.createDiffPack(a, v1, v2, d12, .{ .engine = .{ .budget = .{ .cpu = 1, .worker_threads = 1 } } });

    var h: u64 = 0;
    const diffs = [_]?[*:0]const u8{d12};
    // error paths
    try std.testing.expectEqual(err.code(.invalid_argument), vfs_patch_begin(null, null, &diffs, 1, null, &h));
    try std.testing.expectEqual(err.code(.invalid_argument), vfs_patch_begin(v1, null, &diffs, 0, null, &h));
    try std.testing.expectEqual(err.code(.invalid_argument), vfs_patch_begin(v1, null, &diffs, 1, null, null));
    var bad_opts: vfs_patch_options_t = .{ .struct_size = @sizeOf(vfs_patch_options_t), .flags = VFS_PATCH_IN_MEMORY | VFS_PATCH_DISK };
    try std.testing.expectEqual(err.code(.invalid_argument), vfs_patch_begin(v1, null, &diffs, 1, &bad_opts, &h));
    var prog: vfs_patch_progress_t = undefined;
    prog.struct_size = @sizeOf(vfs_patch_progress_t);
    try std.testing.expectEqual(err.code(.invalid_argument), vfs_patch_poll(12345, &prog));
    try std.testing.expectEqual(err.code(.invalid_argument), vfs_patch_wait(12345, 0));
    try std.testing.expectEqual(err.code(.invalid_argument), vfs_patch_cancel(12345));
    try std.testing.expectEqual(err.code(.invalid_argument), vfs_patch_end(12345));

    // missing diff directory: begin succeeds, the run fails with not_found
    const missing = [_]?[*:0]const u8{"zig-cache-vfs-abi-patch-missing"};
    try std.testing.expectEqual(err.code(.ok), vfs_patch_begin(v1, null, &missing, 1, null, &h));
    try std.testing.expectEqual(err.code(.ok), vfs_patch_wait(h, 30_000));
    try std.testing.expectEqual(err.code(.ok), vfs_patch_poll(h, &prog));
    try std.testing.expectEqual(@intFromEnum(PatchState.failed), prog.state);
    try std.testing.expectEqual(err.code(.not_found), prog.last_status);
    try std.testing.expectEqual(err.code(.not_found), vfs_patch_end(h));

    // real run
    var opts: vfs_patch_options_t = .{ .struct_size = @sizeOf(vfs_patch_options_t), .flags = VFS_PATCH_IN_MEMORY | VFS_PATCH_OPTIMIZE, .threads = 2, .verify = 1 };
    try std.testing.expectEqual(err.code(.ok), vfs_patch_begin(v1, null, &diffs, 1, &opts, &h));
    try std.testing.expect(h != 0);
    try std.testing.expectEqual(err.code(.ok), vfs_patch_wait(h, 60_000));
    try std.testing.expectEqual(err.code(.ok), vfs_patch_poll(h, &prog));
    try std.testing.expectEqual(@intFromEnum(PatchState.done), prog.state);
    try std.testing.expectEqual(err.code(.ok), prog.last_status);
    try std.testing.expect(prog.units_total > 0);
    try std.testing.expectEqual(prog.units_total, prog.units_done);
    try std.testing.expect(prog.bytes_written > 0 and prog.bytes_read > 0);
    try std.testing.expectEqual(@as(u64, 1), prog.from_version);
    try std.testing.expectEqual(@as(u64, 2), prog.to_version);
    // a truncated progress struct is honoured
    var small: extern struct { struct_size: u32, state: u32 } align(8) = .{ .struct_size = 8, .state = 99 };
    try std.testing.expectEqual(err.code(.ok), vfs_patch_poll(h, @ptrCast(&small)));
    try std.testing.expectEqual(@intFromEnum(PatchState.done), small.state);
    try std.testing.expectEqual(err.code(.ok), vfs_patch_end(h));
    try std.testing.expectEqual(err.code(.invalid_argument), vfs_patch_end(h));

    // the patched pack now serves v2 content through the read ABI
    var volume: u64 = 0;
    try std.testing.expectEqual(err.code(.ok), vfs_open_volume("abi-patch", null, &volume));
    try std.testing.expectEqual(err.code(.ok), vfs_mount_pack(volume, v1, 10, 0));
    for (ds.v2) |spec| {
        var f: u64 = 0;
        const zpath = try a.dupeZ(u8, spec.path);
        defer a.free(zpath);
        try std.testing.expectEqual(err.code(.ok), vfs_open_path(volume, zpath, 0, &f));
        const buf = try a.alloc(u8, spec.data.len + 8);
        defer a.free(buf);
        var n: u64 = 0;
        try std.testing.expectEqual(err.code(.ok), vfs_read_at(f, 0, buf.ptr, buf.len, &n));
        try std.testing.expectEqual(spec.data.len, n);
        try std.testing.expectEqualSlices(u8, spec.data, buf[0..n]);
        try std.testing.expectEqual(err.code(.ok), vfs_close_file(f));
    }
    var f2: u64 = 0;
    try std.testing.expectEqual(err.code(.not_found), vfs_open_path(volume, "/c.bin", 0, &f2));
    try std.testing.expectEqual(err.code(.ok), vfs_close_volume(volume));

    // second run is a no-op that still completes
    try std.testing.expectEqual(err.code(.ok), vfs_patch_begin(v1, null, &diffs, 1, &opts, &h));
    try std.testing.expectEqual(err.code(.ok), vfs_patch_end(h));
}

test "vfs abi patch cancel stops before publishing" {
    const fixture = @import("diff/test_fixture.zig");
    const diff_writer = @import("diff/diff_pack_writer.zig");
    const pack_scan = @import("diff/pack_scan.zig");
    const a = std.testing.allocator;
    var ds = try fixture.dataset(a);
    defer ds.deinit();
    const v1 = "zig-cache-vfs-abi-cancel-v1";
    const v2 = "zig-cache-vfs-abi-cancel-v2";
    const d12 = "zig-cache-vfs-abi-cancel-d12";
    defer fixture.cleanup(v1);
    defer fixture.cleanup(v2);
    defer fixture.cleanup(d12);
    try fixture.buildPack(a, "zig-cache-vfs-abi-cancel-fx1", v1, ds.v1, 32, 1, 1);
    try fixture.buildPack(a, "zig-cache-vfs-abi-cancel-fx2", v2, ds.v2, 32, 2, 1);
    _ = try diff_writer.createDiffPack(a, v1, v2, d12, .{ .engine = .{ .budget = .{ .cpu = 1, .worker_threads = 1 } } });
    // Cancel before the job can start: the flag is observed at the first task boundary.
    const job = try std.heap.smp_allocator.create(PatchJob);
    defer std.heap.smp_allocator.destroy(job);
    job.* = .{ .allocator = std.heap.smp_allocator, .target = try std.heap.smp_allocator.dupe(u8, v1), .overlay = null, .diffs = try std.heap.smp_allocator.alloc([]u8, 1), .to_version = null, .options = .{ .budget = .{ .cpu = 1, .worker_threads = 1 } } };
    job.diffs[0] = try std.heap.smp_allocator.dupe(u8, d12);
    defer job.deinit();
    job.options.progress = &job.progress;
    job.progress.cancel.store(true, .release);
    job.main();
    try std.testing.expectEqual(@intFromEnum(PatchState.cancelled), job.state.load(.acquire));
    try std.testing.expectEqual(err.code(.cancelled), job.last_status.load(.acquire));
    var img = try pack_scan.PackImage.load(a, v1);
    defer img.deinit();
    try std.testing.expectEqual(@as(u64, 1), img.manifest.pack_version);
    // Resume after cancel converges.
    job.progress.cancel.store(false, .release);
    job.state.store(@intFromEnum(PatchState.running), .release);
    job.main();
    try std.testing.expectEqual(@intFromEnum(PatchState.done), job.state.load(.acquire));
}

test "vfs abi handle lifecycle before mount remains safe" {
    var volume: u64 = 0;
    try std.testing.expectEqual(err.code(.invalid_argument), vfs_open_volume(null, null, &volume));
    try std.testing.expectEqual(err.code(.invalid_argument), vfs_open_volume("assets", null, null));
    try std.testing.expectEqual(err.code(.ok), vfs_open_volume("assets", null, &volume));
    try std.testing.expect(volume != 0);
    var file: u64 = 123;
    try std.testing.expectEqual(err.code(.not_found), vfs_open_path(volume, "missing.txt", 0, &file));
    try std.testing.expectEqual(@as(u64, 0), file);
    try std.testing.expectEqual(err.code(.invalid_argument), vfs_open_entry(volume, 0, 0, &file));
    var read: u64 = 1;
    var buf: [8]u8 = undefined;
    try std.testing.expectEqual(err.code(.invalid_argument), vfs_read_at(12345, 0, &buf, buf.len, &read));
    try std.testing.expectEqual(@as(u64, 0), read);
    try std.testing.expectEqual(err.code(.ok), vfs_close_volume(volume));
    try std.testing.expectEqual(err.code(.invalid_argument), vfs_close_volume(volume));
}

test "vfs abi mounts builder pack and reads by path and entry" {
    const builder = @import("build/pack_builder.zig");
    const allocator = std.testing.allocator;
    _ = allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    const pack_path = "zig-cache-vfs-abi-read-pack";
    const source_path = "zig-cache-vfs-abi-read-source.bin";
    _ = std.Io.Dir.cwd().deleteTree(io, pack_path) catch {};
    _ = std.Io.Dir.cwd().deleteFile(io, source_path) catch {};
    defer _ = std.Io.Dir.cwd().deleteTree(io, pack_path) catch {};
    defer _ = std.Io.Dir.cwd().deleteFile(io, source_path) catch {};
    try builder.writeSourceFileForTest(source_path, "0123456789ABCDEF");
    const input = builder.BuildFileInput{ .source_path = source_path, .virtual_path = "/dir/file.bin", .file_entry = 700, .page_size = 4 };
    try builder.createPack(pack_path, &.{input}, .{});

    var volume: u64 = 0;
    try std.testing.expectEqual(err.code(.ok), vfs_open_volume("root", null, &volume));
    defer _ = vfs_close_volume(volume);
    try std.testing.expectEqual(err.code(.ok), vfs_mount_pack(volume, pack_path, 0, 0));

    var stat: vfs_stat_t = .{ .struct_size = @sizeOf(vfs_stat_t), .flags = 0, .file_entry = 0, .size = 0, .page_size = 0, .reserved0 = 0 };
    try std.testing.expectEqual(err.code(.ok), vfs_stat_path(volume, "/dir/file.bin", &stat));
    try std.testing.expectEqual(@as(u64, 700), stat.file_entry);
    try std.testing.expectEqual(@as(u64, 16), stat.size);
    try std.testing.expectEqual(@as(u64, 4), stat.page_size);

    var file_by_path: u64 = 0;
    try std.testing.expectEqual(err.code(.ok), vfs_open_path(volume, "/dir/file.bin", 0, &file_by_path));
    defer _ = vfs_close_file(file_by_path);
    var full: [16]u8 = undefined;
    var n: u64 = 0;
    try std.testing.expectEqual(err.code(.ok), vfs_read_at(file_by_path, 0, &full, full.len, &n));
    try std.testing.expectEqual(@as(u64, 16), n);
    try std.testing.expectEqualSlices(u8, "0123456789ABCDEF", &full);

    var cross: [8]u8 = undefined;
    try std.testing.expectEqual(err.code(.ok), vfs_read_at(file_by_path, 2, &cross, cross.len, &n));
    try std.testing.expectEqual(@as(u64, 8), n);
    try std.testing.expectEqualSlices(u8, "23456789", &cross);
    var tail: [8]u8 = undefined;
    try std.testing.expectEqual(err.code(.ok), vfs_read_at(file_by_path, 14, &tail, tail.len, &n));
    try std.testing.expectEqual(@as(u64, 2), n);
    try std.testing.expectEqualSlices(u8, "EF", tail[0..2]);
    try std.testing.expectEqual(err.code(.ok), vfs_read_at(file_by_path, 16, &tail, tail.len, &n));
    try std.testing.expectEqual(@as(u64, 0), n);
    try std.testing.expectEqual(err.code(.ok), vfs_read_at(file_by_path, 999, &tail, tail.len, &n));
    try std.testing.expectEqual(@as(u64, 0), n);
    var small: [3]u8 = undefined;
    try std.testing.expectEqual(err.code(.ok), vfs_read_at(file_by_path, 0, &small, small.len, &n));
    try std.testing.expectEqual(@as(u64, 3), n);
    try std.testing.expectEqualSlices(u8, "012", &small);

    var file_by_entry: u64 = 0;
    try std.testing.expectEqual(err.code(.ok), vfs_open_entry(volume, 700, 0, &file_by_entry));
    defer _ = vfs_close_file(file_by_entry);
    try std.testing.expectEqual(err.code(.ok), vfs_read_at(file_by_entry, 4, &cross, cross.len, &n));
    try std.testing.expectEqualSlices(u8, "456789AB", &cross);
}

test "vfs open_entry does not depend on path index entry" {
    const io = std.Io.Threaded.global_single_threaded.io();
    const pack_path = "zig-cache-vfs-abi-entry-no-path-pack";
    _ = std.Io.Dir.cwd().deleteTree(io, pack_path) catch {};
    defer _ = std.Io.Dir.cwd().deleteTree(io, pack_path) catch {};
    try createManualPackForTest(pack_path, &.{}, 710, "entry-only", .valid, .valid_manifest);

    var volume: u64 = 0;
    try std.testing.expectEqual(err.code(.ok), vfs_open_volume("root", null, &volume));
    defer _ = vfs_close_volume(volume);
    try std.testing.expectEqual(err.code(.ok), vfs_mount_pack(volume, pack_path, 0, 0));
    var file: u64 = 0;
    try std.testing.expectEqual(err.code(.not_found), vfs_open_path(volume, "/hidden.bin", 0, &file));
    try std.testing.expectEqual(err.code(.ok), vfs_open_entry(volume, 710, 0, &file));
    defer _ = vfs_close_file(file);
    var out: [10]u8 = undefined;
    var n: u64 = 0;
    try std.testing.expectEqual(err.code(.ok), vfs_read_at(file, 0, &out, out.len, &n));
    try std.testing.expectEqualSlices(u8, "entry-only", &out);
}

test "vfs rejects corrupted manifest page identity and checksums" {
    const io = std.Io.Threaded.global_single_threaded.io();
    const cases = [_][]const u8{
        "zig-cache-vfs-abi-corrupt-manifest",
        "zig-cache-vfs-abi-corrupt-page-identity",
        "zig-cache-vfs-abi-corrupt-page-rawcrc",
        "zig-cache-vfs-abi-corrupt-page-storedcrc",
    };
    for (cases) |p| {
        _ = std.Io.Dir.cwd().deleteTree(io, p) catch {};
        defer _ = std.Io.Dir.cwd().deleteTree(io, p) catch {};
    }
    try createManualPackForTest(cases[0], &.{.{ .normalized_path = "bad.bin", .file_entry = 800 }}, 800, "abcd", .valid, .wrong_manifest_entry);
    try expectOpenEntryStatus(cases[0], 800, err.code(.corruption));

    try createManualPackForTest(cases[1], &.{.{ .normalized_path = "bad.bin", .file_entry = 800 }}, 800, "abcd", .wrong_page_identity, .valid_manifest);
    try expectReadStatus(cases[1], 800, err.code(.corruption));

    try createManualPackForTest(cases[2], &.{.{ .normalized_path = "bad.bin", .file_entry = 800 }}, 800, "abcd", .bad_raw_crc, .valid_manifest);
    try expectReadStatus(cases[2], 800, err.code(.checksum_mismatch));

    try createManualPackForTest(cases[3], &.{.{ .normalized_path = "bad.bin", .file_entry = 800 }}, 800, "abcd", .bad_stored_crc, .valid_manifest);
    try expectReadStatus(cases[3], 800, err.code(.checksum_mismatch));
}

test "vfs multi pack overlay priority path entry tombstone and handle lifetime" {
    const builder = @import("build/pack_builder.zig");
    const io = std.Io.Threaded.global_single_threaded.io();
    const paths = [_][]const u8{
        "zig-cache-vfs-overlay-base-pack",
        "zig-cache-vfs-overlay-patch-pack",
        "zig-cache-vfs-overlay-rename-base-pack",
        "zig-cache-vfs-overlay-rename-patch-pack",
        "zig-cache-vfs-overlay-tombstone-pack",
        "zig-cache-vfs-overlay-source-base.bin",
        "zig-cache-vfs-overlay-source-patch.bin",
        "zig-cache-vfs-overlay-source-rename-base.bin",
        "zig-cache-vfs-overlay-source-rename-patch.bin",
        "zig-cache-vfs-overlay-source-dead.bin",
    };
    for (paths) |p| {
        _ = std.Io.Dir.cwd().deleteTree(io, p) catch {};
        _ = std.Io.Dir.cwd().deleteFile(io, p) catch {};
    }
    defer for (paths) |p| {
        _ = std.Io.Dir.cwd().deleteTree(io, p) catch {};
        _ = std.Io.Dir.cwd().deleteFile(io, p) catch {};
    };

    try builder.writeSourceFileForTest(paths[5], "base");
    try builder.writeSourceFileForTest(paths[6], "patch");
    try builder.writeSourceFileForTest(paths[7], "old-visible-entry");
    try builder.writeSourceFileForTest(paths[8], "new-visible-entry");
    try builder.writeSourceFileForTest(paths[9], "dead");
    try builder.createPack(paths[0], &.{.{ .source_path = paths[5], .virtual_path = "/same.txt", .file_entry = 900, .page_size = 4 }}, .{});
    try builder.createPack(paths[1], &.{.{ .source_path = paths[6], .virtual_path = "/same.txt", .file_entry = 900, .page_size = 4 }}, .{});
    try builder.createPack(paths[2], &.{.{ .source_path = paths[7], .virtual_path = "/old.txt", .file_entry = 901, .page_size = 4 }}, .{});
    try builder.createPack(paths[3], &.{.{ .source_path = paths[8], .virtual_path = "/new.txt", .file_entry = 901, .page_size = 4 }}, .{});
    try createTombstonePackForTest(paths[4], 902);
    const dead_pack = "zig-cache-vfs-overlay-dead-base-pack";
    _ = std.Io.Dir.cwd().deleteTree(io, dead_pack) catch {};
    defer _ = std.Io.Dir.cwd().deleteTree(io, dead_pack) catch {};
    try builder.createPack(dead_pack, &.{.{ .source_path = paths[9], .virtual_path = "/dead.txt", .file_entry = 902, .page_size = 4 }}, .{});

    var volume: u64 = 0;
    try std.testing.expectEqual(err.code(.ok), vfs_open_volume("root", null, &volume));
    try std.testing.expectEqual(err.code(.ok), try mountPackForTest(volume, paths[0], 1));
    try std.testing.expectEqual(err.code(.invalid_argument), try mountPackForTest(volume, paths[1], 1));
    try std.testing.expectEqual(err.code(.ok), try mountPackForTest(volume, paths[1], 10));

    var file: u64 = 0;
    try std.testing.expectEqual(err.code(.ok), vfs_open_path(volume, "/same.txt", 0, &file));
    var buf: [32]u8 = undefined;
    var n: u64 = 0;
    try std.testing.expectEqual(err.code(.ok), vfs_read_at(file, 0, &buf, buf.len, &n));
    try std.testing.expectEqualSlices(u8, "patch", buf[0..@intCast(n)]);
    try std.testing.expectEqual(err.code(.busy), vfs_close_volume(volume));
    try std.testing.expectEqual(err.code(.ok), vfs_close_file(file));
    try std.testing.expectEqual(err.code(.ok), vfs_close_volume(volume));

    try std.testing.expectEqual(err.code(.ok), vfs_open_volume("root", null, &volume));
    defer _ = vfs_close_volume(volume);
    try std.testing.expectEqual(err.code(.ok), try mountPackForTest(volume, paths[2], 1));
    try std.testing.expectEqual(err.code(.ok), try mountPackForTest(volume, paths[3], 10));
    try std.testing.expectEqual(err.code(.ok), vfs_open_entry(volume, 901, 0, &file));
    defer _ = vfs_close_file(file);
    try std.testing.expectEqual(err.code(.ok), vfs_read_at(file, 0, &buf, buf.len, &n));
    try std.testing.expectEqualSlices(u8, "new-visible-entry", buf[0..@intCast(n)]);
    var file_from_old_path: u64 = 0;
    try std.testing.expectEqual(err.code(.ok), vfs_open_path(volume, "/old.txt", 0, &file_from_old_path));
    defer _ = vfs_close_file(file_from_old_path);
    try std.testing.expectEqual(err.code(.ok), vfs_read_at(file_from_old_path, 0, &buf, buf.len, &n));
    try std.testing.expectEqualSlices(u8, "new-visible-entry", buf[0..@intCast(n)]);

    var tomb_volume: u64 = 0;
    try std.testing.expectEqual(err.code(.ok), vfs_open_volume("root", null, &tomb_volume));
    defer _ = vfs_close_volume(tomb_volume);
    try std.testing.expectEqual(err.code(.ok), try mountPackForTest(tomb_volume, dead_pack, 1));
    try std.testing.expectEqual(err.code(.ok), try mountPackForTest(tomb_volume, paths[4], 10));
    var missing_file: u64 = 123;
    try std.testing.expectEqual(err.code(.not_found), vfs_open_entry(tomb_volume, 902, 0, &missing_file));
    try std.testing.expectEqual(err.code(.not_found), vfs_open_path(tomb_volume, "/dead.txt", 0, &missing_file));
}

test "vfs read returns unsupported feature for unsupported codec" {
    const io = std.Io.Threaded.global_single_threaded.io();
    const pack_path = "zig-cache-vfs-unsupported-codec-pack";
    _ = std.Io.Dir.cwd().deleteTree(io, pack_path) catch {};
    defer _ = std.Io.Dir.cwd().deleteTree(io, pack_path) catch {};
    try createUnsupportedCodecPackForTest(pack_path, 990, "zzzz");
    var volume: u64 = 0;
    try std.testing.expectEqual(err.code(.ok), vfs_open_volume("root", null, &volume));
    defer _ = vfs_close_volume(volume);
    try std.testing.expectEqual(err.code(.ok), try mountPackForTest(volume, pack_path, 1));
    var file: u64 = 0;
    try std.testing.expectEqual(err.code(.ok), vfs_open_entry(volume, 990, 0, &file));
    defer _ = vfs_close_file(file);
    var buf: [4]u8 = undefined;
    var n: u64 = 99;
    try std.testing.expectEqual(err.code(.unsupported_feature), vfs_read_at(file, 0, &buf, buf.len, &n));
    try std.testing.expectEqual(@as(u64, 0), n);
}

const PageCorruption = enum { valid, wrong_page_identity, bad_raw_crc, bad_stored_crc };
const ManifestCorruption = enum { valid_manifest, wrong_manifest_entry };

fn createManualPackForTest(
    pack_path: []const u8,
    path_entries: []const @import("format/path_index.zig").EntryInput,
    file_entry: u64,
    payload: []const u8,
    page_corruption: PageCorruption,
    manifest_corruption: ManifestCorruption,
) !void {
    const pack_writer = @import("pack/pack_writer.zig");
    const path_index_fmt = @import("format/path_index.zig");
    const file_manifest_fmt = @import("format/file_manifest.zig");
    const page_value_fmt = @import("format/page_value.zig");
    const pack_manifest_fmt = @import("format/pack_manifest.zig");
    const hash = @import("hash.zig");
    const allocator = std.heap.smp_allocator;
    var writer = try pack_writer.PackWriter.create(allocator, pack_path);
    var closed = false;
    errdefer if (!closed) writer.close() catch {};

    const path_index = try path_index_fmt.encodePathIndex(allocator, path_entries);
    defer allocator.free(path_index);
    try writer.putPathIndex(path_index);

    var page_value = try page_value_fmt.encodePageValue(allocator, .{
        .file_entry = if (page_corruption == .wrong_page_identity) file_entry + 1 else file_entry,
        .block_index = 0,
        .page_index = 0,
        .raw_size = @intCast(payload.len),
        .stored_size = @intCast(payload.len),
        .raw_crc = if (page_corruption == .bad_raw_crc) 123 else 0,
        .payload = payload,
    });
    defer allocator.free(page_value);
    if (page_corruption == .bad_stored_crc) page_value[page_value.len - 1] ^= 0xff;
    try writer.putPage(file_entry, 0, 0, page_value);

    const blocks = [_]file_manifest_fmt.BlockDesc{.{ .raw_offset = 0, .raw_size = payload.len, .page_size = @intCast(payload.len), .page_count = 1, .codec = .none, .block_hash = hash.contentHash(payload) }};
    const manifest_value = try file_manifest_fmt.encodeFileManifest(allocator, .{
        .file_entry = if (manifest_corruption == .wrong_manifest_entry) file_entry + 1 else file_entry,
        .file_version = 1,
        .file_size = payload.len,
        .content_hash = hash.contentHash(payload),
        .blocks = &blocks,
    });
    defer allocator.free(manifest_value);
    try writer.putObject(try @import("object_key.zig").fileManifestKey(file_entry), .{ .kind = .file_manifest, .file_entry = file_entry }, manifest_value);

    const pack_manifest = pack_manifest_fmt.encodePackManifest(.{ .pack_id = 1, .pack_version = 1, .build_id = 1, .file_count = 1, .tombstone_count = 0, .content_hash = hash.contentHash(payload) });
    try writer.putPackManifest(&pack_manifest);
    try writer.close();
    closed = true;
}

fn createTombstonePackForTest(pack_path: []const u8, file_entry: u64) !void {
    const pack_writer = @import("pack/pack_writer.zig");
    const path_index_fmt = @import("format/path_index.zig");
    const pack_manifest_fmt = @import("format/pack_manifest.zig");
    const tombstone_fmt = @import("format/tombstone.zig");
    const hash = @import("hash.zig");
    const allocator = std.heap.smp_allocator;
    var writer = try pack_writer.PackWriter.create(allocator, pack_path);
    var closed = false;
    errdefer if (!closed) writer.close() catch {};
    const path_index = try path_index_fmt.encodePathIndex(allocator, &.{});
    defer allocator.free(path_index);
    try writer.putPathIndex(path_index);
    const tombstone = try tombstone_fmt.encodeEntryTombstone(.{ .file_entry = file_entry, .tombstone_version = 1, .reason_flags = 1 });
    try writer.putEntryTombstone(file_entry, &tombstone);
    const pack_manifest = pack_manifest_fmt.encodePackManifest(.{ .pack_id = 1, .pack_version = 1, .build_id = 1, .file_count = 0, .tombstone_count = 1, .content_hash = hash.contentHash(&tombstone) });
    try writer.putPackManifest(&pack_manifest);
    try writer.close();
    closed = true;
}

fn createUnsupportedCodecPackForTest(pack_path: []const u8, file_entry: u64, payload: []const u8) !void {
    const pack_writer = @import("pack/pack_writer.zig");
    const path_index_fmt = @import("format/path_index.zig");
    const file_manifest_fmt = @import("format/file_manifest.zig");
    const page_value_fmt = @import("format/page_value.zig");
    const pack_manifest_fmt = @import("format/pack_manifest.zig");
    const hash = @import("hash.zig");
    const allocator = std.heap.smp_allocator;
    var writer = try pack_writer.PackWriter.create(allocator, pack_path);
    var closed = false;
    errdefer if (!closed) writer.close() catch {};
    const entries = [_]path_index_fmt.EntryInput{.{ .normalized_path = "unsupported.bin", .file_entry = file_entry }};
    const path_index = try path_index_fmt.encodePathIndex(allocator, &entries);
    defer allocator.free(path_index);
    try writer.putPathIndex(path_index);
    const page_value = try page_value_fmt.encodePageValue(allocator, .{ .file_entry = file_entry, .block_index = 0, .page_index = 0, .codec = .zstd, .raw_size = @intCast(payload.len), .stored_size = @intCast(payload.len), .payload = payload });
    defer allocator.free(page_value);
    try writer.putPage(file_entry, 0, 0, page_value);
    const blocks = [_]file_manifest_fmt.BlockDesc{.{ .raw_offset = 0, .raw_size = payload.len, .page_size = @intCast(payload.len), .page_count = 1, .codec = .zstd, .block_hash = hash.contentHash(payload) }};
    const manifest_value = try file_manifest_fmt.encodeFileManifest(allocator, .{ .file_entry = file_entry, .file_version = 1, .file_size = payload.len, .content_hash = hash.contentHash(payload), .blocks = &blocks });
    defer allocator.free(manifest_value);
    try writer.putFileManifest(file_entry, manifest_value);
    const pack_manifest = pack_manifest_fmt.encodePackManifest(.{ .pack_id = 1, .pack_version = 1, .build_id = 1, .file_count = 1, .tombstone_count = 0, .content_hash = hash.contentHash(payload) });
    try writer.putPackManifest(&pack_manifest);
    try writer.close();
    closed = true;
}

fn expectOpenEntryStatus(pack_path: []const u8, file_entry: u64, expected: c_int) !void {
    const z_pack_path = try std.testing.allocator.dupeZ(u8, pack_path);
    defer std.testing.allocator.free(z_pack_path);
    var volume: u64 = 0;
    try std.testing.expectEqual(err.code(.ok), vfs_open_volume("root", null, &volume));
    defer _ = vfs_close_volume(volume);
    try std.testing.expectEqual(err.code(.ok), vfs_mount_pack(volume, z_pack_path.ptr, 0, 0));
    var file: u64 = 0;
    try std.testing.expectEqual(expected, vfs_open_entry(volume, file_entry, 0, &file));
}

fn expectReadStatus(pack_path: []const u8, file_entry: u64, expected: c_int) !void {
    const z_pack_path = try std.testing.allocator.dupeZ(u8, pack_path);
    defer std.testing.allocator.free(z_pack_path);
    var volume: u64 = 0;
    try std.testing.expectEqual(err.code(.ok), vfs_open_volume("root", null, &volume));
    defer _ = vfs_close_volume(volume);
    try std.testing.expectEqual(err.code(.ok), vfs_mount_pack(volume, z_pack_path.ptr, 0, 0));
    var file: u64 = 0;
    try std.testing.expectEqual(err.code(.ok), vfs_open_entry(volume, file_entry, 0, &file));
    defer _ = vfs_close_file(file);
    var buf: [4]u8 = undefined;
    var n: u64 = 99;
    try std.testing.expectEqual(expected, vfs_read_at(file, 0, &buf, buf.len, &n));
    try std.testing.expectEqual(@as(u64, 0), n);
}

fn mountPackForTest(volume: u64, pack_path: []const u8, priority: u32) !c_int {
    const z_pack_path = try std.testing.allocator.dupeZ(u8, pack_path);
    defer std.testing.allocator.free(z_pack_path);
    return vfs_mount_pack(volume, z_pack_path.ptr, priority, 0);
}

test "vfs abi streaming flag reads whole pages without caching and rejects unknown flags" {
    const builder = @import("build/pack_builder.zig");
    const io = std.Io.Threaded.global_single_threaded.io();
    const pack_path = "zig-cache-vfs-abi-streaming-pack";
    const source_path = "zig-cache-vfs-abi-streaming-source.bin";
    _ = std.Io.Dir.cwd().deleteTree(io, pack_path) catch {};
    _ = std.Io.Dir.cwd().deleteFile(io, source_path) catch {};
    defer _ = std.Io.Dir.cwd().deleteTree(io, pack_path) catch {};
    defer _ = std.Io.Dir.cwd().deleteFile(io, source_path) catch {};
    var payload: [4096 * 3 + 100]u8 = undefined;
    for (&payload, 0..) |*b, i| b.* = @truncate(i *% 31);
    try builder.writeSourceFileForTest(source_path, &payload);
    try builder.createPack(pack_path, &.{.{ .source_path = source_path, .virtual_path = "/s.bin", .file_entry = 8201, .page_size = 4096 }}, .{});

    var volume: u64 = 0;
    try std.testing.expectEqual(err.code(.ok), vfs_open_volume("root", null, &volume));
    defer _ = vfs_close_volume(volume);
    try std.testing.expectEqual(err.code(.ok), try mountPackForTest(volume, pack_path, 1));

    var file: u64 = 0;
    try std.testing.expectEqual(err.code(.invalid_argument), vfs_open_entry(volume, 8201, 0x80, &file));
    try std.testing.expectEqual(err.code(.ok), vfs_open_entry(volume, 8201, VFS_OPEN_STREAMING, &file));
    defer _ = vfs_close_file(file);

    const inspection = try registry.acquire(volume_mod.Volume, volume, .volume);
    defer inspection.release();
    const v = inspection.ptr;
    var out: [payload.len]u8 = undefined;
    var n: u64 = 0;
    // Whole-file read: every page (including the short 100-byte tail page) is
    // read in full, so all of them stream past the cache.
    try std.testing.expectEqual(err.code(.ok), vfs_read_at(file, 0, &out, out.len, &n));
    try std.testing.expectEqual(@as(u64, payload.len), n);
    try std.testing.expectEqualSlices(u8, &payload, &out);
    try std.testing.expectEqual(@as(usize, 0), v.page_cache.residentCount());
    // Unaligned read through the same handle touches two partial pages, which
    // go through the cache and must be exact.
    var mid: [5000]u8 = undefined;
    try std.testing.expectEqual(err.code(.ok), vfs_read_at(file, 1000, &mid, mid.len, &n));
    try std.testing.expectEqual(@as(u64, mid.len), n);
    try std.testing.expectEqualSlices(u8, payload[1000..6000], &mid);
    try std.testing.expectEqual(@as(usize, 2), v.page_cache.residentCount());
    // A resident page is served from the cache even on the streaming handle.
    var page1: [4096]u8 = undefined;
    try std.testing.expectEqual(err.code(.ok), vfs_read_at(file, 4096, &page1, page1.len, &n));
    try std.testing.expectEqualSlices(u8, payload[4096..8192], &page1);
}

test "vfs abi concurrent read_at on one volume" {
    const builder = @import("build/pack_builder.zig");
    const io = std.Io.Threaded.global_single_threaded.io();
    const pack_path = "zig-cache-vfs-abi-concurrent-pack";
    const source_path = "zig-cache-vfs-abi-concurrent-source.bin";
    _ = std.Io.Dir.cwd().deleteTree(io, pack_path) catch {};
    _ = std.Io.Dir.cwd().deleteFile(io, source_path) catch {};
    defer _ = std.Io.Dir.cwd().deleteTree(io, pack_path) catch {};
    defer _ = std.Io.Dir.cwd().deleteFile(io, source_path) catch {};
    const payload = "abi-threads";
    try builder.writeSourceFileForTest(source_path, payload);
    try builder.createPack(pack_path, &.{.{ .source_path = source_path, .virtual_path = "/t.bin", .file_entry = 8101, .page_size = 8 }}, .{});

    var opts = vfs_open_options_t{
        .struct_size = @sizeOf(vfs_open_options_t),
        .flags = 0,
        .page_cache_bytes = 0,
        .max_open_stores = 2,
        .read_handles = 0,
    };
    var volume: u64 = 0;
    try std.testing.expectEqual(err.code(.ok), vfs_open_volume("root", &opts, &volume));
    defer _ = vfs_close_volume(volume);
    try std.testing.expectEqual(err.code(.ok), try mountPackForTest(volume, pack_path, 1));

    const Ctx = struct {
        volume: u64,
        errors: *[4]u32,

        fn reader(ctx: *@This(), id: usize) void {
            var file: u64 = 0;
            if (vfs_open_path(ctx.volume, "/t.bin", 0, &file) != err.code(.ok)) {
                ctx.errors[id] = 1;
                return;
            }
            defer _ = vfs_close_file(file);
            var round: usize = 0;
            while (round < 24) : (round += 1) {
                var buf: [16]u8 = undefined;
                var n: u64 = 0;
                if (vfs_read_at(file, 0, &buf, buf.len, &n) != err.code(.ok) or n != 11) {
                    ctx.errors[id] = 2;
                    return;
                }
                if (!std.mem.eql(u8, buf[0..11], "abi-threads")) {
                    ctx.errors[id] = 3;
                    return;
                }
            }
        }
    };

    var errors = [_]u32{0} ** 4;
    var ctx = Ctx{ .volume = volume, .errors = &errors };
    var threads: [4]std.Thread = undefined;
    for (&threads, 0..) |*thread, i| thread.* = try std.Thread.spawn(.{}, Ctx.reader, .{ &ctx, i });
    for (&threads) |*thread| thread.join();
    for (errors) |e| try std.testing.expectEqual(@as(u32, 0), e);
}

test "vfs stat versioned prefixes preserve caller canaries" {
    const builder = @import("build/pack_builder.zig");
    const io = std.Io.Threaded.global_single_threaded.io();
    const pack = "zig-cache-vfs-abi-stat-prefix";
    const source = "zig-cache-vfs-abi-stat-prefix.bin";
    defer std.Io.Dir.cwd().deleteTree(io, pack) catch {};
    defer std.Io.Dir.cwd().deleteFile(io, source) catch {};
    try builder.writeSourceFileForTest(source, "prefix");
    try builder.createPack(pack, &.{.{ .source_path = source, .virtual_path = "/prefix", .file_entry = 8901, .page_size = 8 }}, .{});
    var volume: u64 = 0;
    try std.testing.expectEqual(err.code(.ok), vfs_open_volume("prefix", null, &volume));
    defer _ = vfs_close_volume(volume);
    try std.testing.expectEqual(err.code(.ok), vfs_mount_pack(volume, pack, 1, 0));
    for ([_]u32{ 0, 3, 4, 8, 12, 16, 24, 32, 40, 48 }) |size| {
        var storage: [56]u8 align(8) = @splat(0xa5);
        const out: *vfs_stat_t = @ptrCast(&storage);
        out.struct_size = size;
        const before = storage;
        const expected = if (size < 4) err.code(.invalid_argument) else err.code(.ok);
        try std.testing.expectEqual(expected, vfs_stat_entry(volume, 8901, out));
        const end: usize = if (size < 4) 4 else @min(size, @sizeOf(vfs_stat_t));
        try std.testing.expectEqualSlices(u8, before[end..], storage[end..]);
        try std.testing.expectEqual(size, out.struct_size);
        storage = @splat(0xa5);
        out.struct_size = size;
        try std.testing.expectEqual(expected, vfs_stat_path(volume, "/prefix", out));
        try std.testing.expectEqualSlices(u8, before[end..], storage[end..]);
    }
}

test "vfs ABI file close drains retained reads while volume remains busy" {
    const builder = @import("build/pack_builder.zig");
    const io = std.Io.Threaded.global_single_threaded.io();
    const pack = "zig-cache-vfs-abi-close-drain";
    const source = "zig-cache-vfs-abi-close-drain.bin";
    defer std.Io.Dir.cwd().deleteTree(io, pack) catch {};
    defer std.Io.Dir.cwd().deleteFile(io, source) catch {};
    try builder.writeSourceFileForTest(source, "retained");
    try builder.createPack(pack, &.{.{ .source_path = source, .virtual_path = "/retained", .file_entry = 8902, .page_size = 8 }}, .{ .pack_id = @as(u64, 1) << 40 });
    var volume: u64 = 0;
    try std.testing.expectEqual(err.code(.ok), vfs_open_volume("retained", null, &volume));
    try std.testing.expectEqual(err.code(.ok), vfs_mount_pack(volume, pack, 1, 0));
    var file: u64 = 0;
    try std.testing.expectEqual(err.code(.ok), vfs_open_entry(volume, 8902, 0, &file));
    try std.testing.expectEqual(err.code(.invalid_argument), vfs_close_file(volume));
    try std.testing.expectEqual(err.code(.invalid_argument), vfs_close_volume(file));
    const held = try registry.acquire(file_mod.FileHandle, file, .file);
    const Ctx = struct {
        handle: u64,
        status: c_int = -1,
        done: std.atomic.Value(bool) = .init(false),
        fn run(ctx: *@This()) void {
            ctx.status = vfs_close_file(ctx.handle);
            ctx.done.store(true, .release);
        }
    };
    var ctx = Ctx{ .handle = file };
    const closer = try std.Thread.spawn(.{}, Ctx.run, .{&ctx});
    while (true) {
        if (registry.acquire(file_mod.FileHandle, file, .file)) |lease| lease.release() else |_| break;
        std.Thread.yield() catch {};
    }
    try std.testing.expect(!ctx.done.load(.acquire));
    try std.testing.expectEqual(err.code(.busy), vfs_close_volume(volume));
    var bytes: [8]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 8), try held.ptr.readAt(0, &bytes));
    try std.testing.expectEqualStrings("retained", &bytes);
    var n: u64 = 99;
    try std.testing.expectEqual(err.code(.invalid_argument), vfs_read_at(file, 0, &bytes, bytes.len, &n));
    held.release();
    closer.join();
    try std.testing.expectEqual(err.code(.ok), ctx.status);
    var replacement: u64 = 0;
    try std.testing.expectEqual(err.code(.ok), vfs_open_entry(volume, 8902, 0, &replacement));
    try std.testing.expect(replacement != file);
    try std.testing.expectEqual(err.code(.invalid_argument), vfs_close_file(file));
    try std.testing.expectEqual(err.code(.ok), vfs_close_file(replacement));
    try std.testing.expectEqual(err.code(.ok), vfs_close_volume(volume));
}

test "vfs patch progress versioned prefixes preserve caller canaries" {
    var job: PatchJob = .{ .allocator = std.heap.smp_allocator, .target = &.{}, .overlay = null, .diffs = &.{}, .to_version = null, .options = .{} };
    job.state.store(@intFromEnum(PatchState.done), .release);
    const handle = try registry.register(&job, .patch);
    defer _ = registry.take(PatchJob, handle, .patch) catch unreachable;
    for ([_]u32{ 0, 4, 8, 12, 16, 40, 64, 72 }) |size| {
        var storage: [80]u8 align(8) = @splat(0xa5);
        const out: *vfs_patch_progress_t = @ptrCast(&storage);
        out.struct_size = size;
        const before = storage;
        try std.testing.expectEqual(if (size < 8) err.code(.invalid_argument) else err.code(.ok), vfs_patch_poll(handle, out));
        const end: usize = if (size < 8) 4 else @min(size, @sizeOf(vfs_patch_progress_t));
        try std.testing.expectEqualSlices(u8, before[end..], storage[end..]);
        try std.testing.expectEqual(size, out.struct_size);
    }
}

test "volume patch ABI rejects live handles and releases lease before end on success failure cancel" {
    const builder = @import("build/pack_builder.zig");
    const diff = @import("diff/diff_pack_writer.zig");
    const io = std.Io.Threaded.global_single_threaded.io();
    const a = std.testing.allocator;
    const old = "zig-cache-vfs-abi-volume-old";
    const new = "zig-cache-vfs-abi-volume-new";
    const dp = "zig-cache-vfs-abi-volume-diff";
    const src = "zig-cache-vfs-abi-volume.bin";
    defer std.Io.Dir.cwd().deleteTree(io, old) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, new) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, dp) catch {};
    defer std.Io.Dir.cwd().deleteFile(io, src) catch {};
    try builder.writeSourceFileForTest(src, "before");
    try builder.createPack(old, &.{.{ .source_path = src, .virtual_path = "/f", .file_entry = 94001, .page_size = 4 }}, .{ .pack_id = 940, .pack_version = 1 });
    try builder.writeSourceFileForTest(src, "after-update");
    try builder.createPack(new, &.{.{ .source_path = src, .virtual_path = "/f", .file_entry = 94001, .page_size = 4 }}, .{ .pack_id = 940, .pack_version = 2 });
    _ = try diff.createDiffPack(a, old, new, dp, .{});
    var volume: u64 = 0;
    try std.testing.expectEqual(err.code(.ok), vfs_open_volume("abi-update", null, &volume));
    var volume_open = true;
    defer if (volume_open) {
        _ = vfs_close_volume(volume);
    };
    try std.testing.expectEqual(err.code(.ok), vfs_mount_pack(volume, old, 1, 0));
    const diffs = [_]?[*:0]const u8{dp};
    var job_handle: u64 = 42;
    try std.testing.expectEqual(err.code(.invalid_argument), vfs_patch_begin_in_volume(volume, 940, &diffs, 0, null, &job_handle));
    try std.testing.expectEqual(@as(u64, 0), job_handle);
    var file: u64 = 0;
    try std.testing.expectEqual(err.code(.ok), vfs_open_path(volume, "/f", 0, &file));
    try std.testing.expectEqual(err.code(.busy), vfs_patch_begin_in_volume(volume, 940, &diffs, 1, null, &job_handle));
    try std.testing.expectEqual(err.code(.ok), vfs_close_file(file));
    // Deterministic pre-start cancel exercises cleanup without a thread race.
    const retained = try registry.acquire(volume_mod.Volume, volume, .volume);
    const lease = try retained.ptr.acquireUpdateLease(940);
    var manual = PatchJob{ .allocator = std.heap.smp_allocator, .target = try std.heap.smp_allocator.dupe(u8, lease.targetPath()), .overlay = null, .diffs = try std.heap.smp_allocator.alloc([]u8, 1), .to_version = null, .options = .{}, .volume_lease = retained, .update_lease = lease };
    manual.diffs[0] = try std.heap.smp_allocator.dupe(u8, dp);
    defer manual.deinit();
    manual.options.progress = &manual.progress;
    manual.progress.cancel.store(true, .release);
    try std.testing.expectEqual(err.code(.busy), vfs_close_volume(volume));
    manual.main();
    try std.testing.expectEqual(@intFromEnum(PatchState.cancelled), manual.state.load(.acquire));
    try std.testing.expectEqual(err.code(.ok), vfs_open_path(volume, "/f", 0, &file));
    try std.testing.expectEqual(err.code(.ok), vfs_close_file(file));
    const missing = [_]?[*:0]const u8{"zig-cache-vfs-abi-volume-absent"};
    try std.testing.expectEqual(err.code(.ok), vfs_patch_begin_in_volume(volume, 940, &missing, 1, null, &job_handle));
    try std.testing.expectEqual(err.code(.ok), vfs_patch_wait(job_handle, 30000));
    try std.testing.expectEqual(err.code(.not_found), vfs_patch_end(job_handle));
    try std.testing.expectEqual(err.code(.ok), vfs_open_path(volume, "/f", 0, &file));
    try std.testing.expectEqual(err.code(.ok), vfs_close_file(file));
    // Deterministic failures before and after finalization both release job
    // ownership while keeping the mutated target unreadable until resume.
    for ([_]patch_mod.patch_session.FaultPoint{ .after_intent, .after_finalize_before_optimize }) |fault| {
        const retry_retain = try registry.acquire(volume_mod.Volume, volume, .volume);
        manual.volume_lease = retry_retain;
        manual.update_lease = try retry_retain.ptr.acquireUpdateLease(940);
        manual.progress = .{};
        manual.options.fault = fault;
        manual.state.store(@intFromEnum(PatchState.running), .release);
        manual.main();
        try std.testing.expectEqual(@intFromEnum(PatchState.failed), manual.state.load(.acquire));
        try std.testing.expectEqual(err.code(.busy), vfs_open_path(volume, "/f", 0, &file));
        try std.testing.expect(manual.volume_lease == null and manual.update_lease == null);
    }
    try std.testing.expectEqual(err.code(.ok), vfs_patch_begin_in_volume(volume, 940, &diffs, 1, null, &job_handle));
    try std.testing.expectEqual(err.code(.ok), vfs_patch_wait(job_handle, 30000));
    try std.testing.expectEqual(err.code(.ok), vfs_open_path(volume, "/f", 0, &file));
    var bytes: [20]u8 = undefined;
    var n: u64 = 0;
    try std.testing.expectEqual(err.code(.ok), vfs_read_at(file, 0, &bytes, bytes.len, &n));
    try std.testing.expectEqualStrings("after-update", bytes[0..@intCast(n)]);
    try std.testing.expectEqual(err.code(.ok), vfs_close_file(file));
    // A terminal job no longer retains the Volume, even before patch_end.
    try std.testing.expectEqual(err.code(.ok), vfs_close_volume(volume));
    volume_open = false;
    try std.testing.expectEqual(err.code(.ok), vfs_patch_end(job_handle));
    try std.testing.expectEqual(err.code(.invalid_argument), vfs_patch_end(job_handle));
}
