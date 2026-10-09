//! End-to-end contracts for the bounded polling read ABI. Fixtures execute
//! serially; store-budget gates make lifecycle races independent of sleeps.
const std = @import("std");
const abi = @import("../abi.zig");
const errors = @import("../error.zig");
const registry = @import("../handle_registry.zig");
const volume_mod = @import("../volume/volume.zig");
const file_mod = @import("file_handle.zig");
const reads = @import("read_requests.zig");
const fixture = @import("../diff/test_fixture.zig");
const scheduler = @import("../task/scheduler.zig");

const page_size = 4096;
const payload_size = 3 * page_size + 17;
const pack_id: u64 = 0x6a510;
const file_entry: u64 = 0x6a511;
const poison: u8 = 0xa5;

fn payload() [payload_size]u8 {
    var out: [payload_size]u8 = undefined;
    for (&out, 0..) |*byte, i| byte.* = @intCast((i * 29 + i / 17 + 31) % 251);
    return out;
}

fn expectStatus(expected: errors.Status, actual: c_int) !void {
    try std.testing.expectEqual(errors.code(expected), actual);
}

fn expectPoison(bytes: []const u8) !void {
    for (bytes) |byte| try std.testing.expectEqual(poison, byte);
}

const Fixture = struct {
    pack: [:0]const u8,
    volume: u64 = 0,
    file: u64 = 0,

    fn open(comptime tag: []const u8, options: ?*const abi.vfs_open_options_t, flags: u32) !Fixture {
        const pack = "zig-cache-vfs-read-request-" ++ tag;
        const data = payload();
        try fixture.buildPack(std.testing.allocator, pack, pack, &.{.{ .path = "/payload", .file_entry = file_entry, .data = &data, .page_size = page_size, .codec = .lz4 }}, pack_id, 1, 1);
        var self = Fixture{ .pack = pack };
        errdefer self.close();
        try expectStatus(.ok, abi.vfs_open_volume("read-contracts", options, &self.volume));
        try expectStatus(.ok, abi.vfs_mount_pack(self.volume, pack, 1, 0));
        try expectStatus(.ok, abi.vfs_open_entry(self.volume, file_entry, flags, &self.file));
        return self;
    }

    fn close(self: *Fixture) void {
        if (self.file != 0) _ = abi.vfs_close_file(self.file);
        if (self.volume != 0) _ = abi.vfs_close_volume(self.volume);
        fixture.cleanup(self.pack);
        self.file = 0;
        self.volume = 0;
    }
};

fn progress(request: u64) !abi.vfs_request_progress_t {
    var result: abi.vfs_request_progress_t = undefined;
    result.struct_size = @sizeOf(@TypeOf(result));
    try expectStatus(.ok, abi.vfs_request_poll(request, &result));
    return result;
}

fn rangeResult(request: u64, index: u32) !abi.vfs_read_result_t {
    var result: abi.vfs_read_result_t = undefined;
    result.struct_size = @sizeOf(@TypeOf(result));
    try expectStatus(.ok, abi.vfs_request_result(request, index, &result));
    return result;
}

fn stats(volume: u64) !abi.vfs_stats_t {
    var result: abi.vfs_stats_t = undefined;
    result.struct_size = @sizeOf(@TypeOf(result));
    try expectStatus(.ok, abi.vfs_get_stats(volume, &result));
    return result;
}

fn waitDone(request: u64, expected_bytes: u64, expected_ranges: u32) !void {
    try expectStatus(.ok, abi.vfs_request_wait(request, 10_000));
    const p = try progress(request);
    try std.testing.expectEqual(@intFromEnum(reads.State.done), p.state);
    try expectStatus(.ok, p.last_status);
    try std.testing.expectEqual(expected_bytes, p.bytes_read);
    try std.testing.expectEqual(expected_ranges, p.ranges_total);
    try std.testing.expectEqual(expected_ranges, p.ranges_done);
}

test "async reads copy page-spanning ranges and preserve EOF and ordered overlap contracts" {
    var f = try Fixture.open("data", null, 0);
    defer f.close();
    const expected = payload();
    var out: [64]u8 = @splat(poison);
    var request: u64 = 0;
    try expectStatus(.ok, abi.vfs_read_async(f.file, page_size - 7, &out, 33, null, &request));
    defer _ = abi.vfs_request_end(request);
    try waitDone(request, 33, 1);
    try std.testing.expectEqualSlices(u8, expected[page_size - 7 ..][0..33], out[0..33]);
    try expectPoison(out[33..]);
    const r = try rangeResult(request, 0);
    try std.testing.expectEqual(@intFromEnum(reads.State.done), r.state);
    try std.testing.expectEqual(@as(u64, 33), r.bytes_read);
    try expectStatus(.ok, r.last_status);

    var batch_out: [64]u8 = @splat(poison);
    var ranges = [_]abi.vfs_read_range_t{
        .{ .offset = 2, .dst = &batch_out, .size = 16 },
        .{ .offset = page_size + 3, .dst = &batch_out[8], .size = 16 },
        .{ .offset = payload_size - 5, .dst = &batch_out[32], .size = 16 },
        .{ .offset = std.math.maxInt(u64), .dst = &batch_out[48], .size = 8 },
        .{ .offset = 0, .dst = null, .size = 0 },
    };
    var batch: u64 = 0;
    try expectStatus(.ok, abi.vfs_read_batch_async(f.file, &ranges, ranges.len, null, &batch));
    defer _ = abi.vfs_request_end(batch);
    // The ABI owns descriptor copies after submission.
    @memset(&ranges, .{ .offset = 0, .dst = null, .size = 0 });
    try waitDone(batch, 37, 5);
    try std.testing.expectEqualSlices(u8, expected[2..10], batch_out[0..8]);
    try std.testing.expectEqualSlices(u8, expected[page_size + 3 ..][0..16], batch_out[8..24]);
    try expectPoison(batch_out[24..32]);
    try std.testing.expectEqualSlices(u8, expected[payload_size - 5 ..], batch_out[32..37]);
    try expectPoison(batch_out[37..]);
    for ([_]u64{ 16, 16, 5, 0, 0 }, 0..) |count, i| {
        const result = try rangeResult(batch, @intCast(i));
        try std.testing.expectEqual(@intFromEnum(reads.State.done), result.state);
        try std.testing.expectEqual(count, result.bytes_read);
        try expectStatus(.ok, result.last_status);
    }
}

test "prefetch warms shared decoded cache even on a streaming file and releases all page pins" {
    var f = try Fixture.open("prefetch", null, abi.VFS_OPEN_STREAMING);
    defer f.close();
    const before = try stats(f.volume);
    try std.testing.expectEqual(@as(u64, 0), before.cache_resident_bytes);
    var request: u64 = 0;
    try expectStatus(.ok, abi.vfs_prefetch_async(f.file, 0, std.math.maxInt(u64), null, &request));
    defer _ = abi.vfs_request_end(request);
    try waitDone(request, payload_size, 1);
    const warmed = try stats(f.volume);
    try std.testing.expectEqual(@as(u64, payload_size), warmed.bytes_prefetched);
    try std.testing.expectEqual(@as(u64, 0), warmed.bytes_read);
    try std.testing.expectEqual(@as(u64, payload_size), warmed.cache_resident_bytes);
    try std.testing.expectEqual(@as(u64, payload_size), warmed.cache_allocated_bytes);
    try std.testing.expectEqual(@as(u64, 0), warmed.cache_pinned_bytes);
    try std.testing.expectEqual(@as(u64, 0), warmed.cache_inflight_bytes);
    try std.testing.expectEqual(@as(u64, 0), warmed.cache_evicted_pinned_bytes);
    try std.testing.expectEqual(@as(u64, 4), warmed.cache_misses - before.cache_misses);

    var normal_file: u64 = 0;
    try expectStatus(.ok, abi.vfs_open_entry(f.volume, file_entry, 0, &normal_file));
    defer _ = abi.vfs_close_file(normal_file);
    var out: [payload_size]u8 = undefined;
    var read: u64 = 0;
    try expectStatus(.ok, abi.vfs_read_async(normal_file, 0, &out, out.len, null, &read));
    defer _ = abi.vfs_request_end(read);
    try waitDone(read, payload_size, 1);
    const expected = payload();
    try std.testing.expectEqualSlices(u8, &expected, &out);
    const after = try stats(f.volume);
    try std.testing.expectEqual(warmed.cache_misses, after.cache_misses);
    try std.testing.expectEqual(@as(u64, 4), after.cache_hits - warmed.cache_hits);
    try std.testing.expectEqual(@as(u64, payload_size), after.bytes_read);
    try std.testing.expectEqual(@as(u64, 0), after.cache_pinned_bytes);
}

test "completed request metadata survives file close update admission and volume close" {
    var f = try Fixture.open("detached", null, 0);
    defer f.close();
    var out: [19]u8 = undefined;
    var request: u64 = 0;
    try expectStatus(.ok, abi.vfs_read_async(f.file, 7, &out, out.len, null, &request));
    defer _ = abi.vfs_request_end(request);
    try waitDone(request, out.len, 1);
    try expectStatus(.ok, abi.vfs_close_file(f.file));
    f.file = 0;
    {
        const held = try registry.acquire(volume_mod.Volume, f.volume, .volume);
        defer held.release();
        var update = try held.ptr.acquireUpdateLease(pack_id);
        try update.release(false, false);
    }
    const old_volume = f.volume;
    try expectStatus(.ok, abi.vfs_close_volume(f.volume));
    f.volume = 0;
    try waitDone(request, out.len, 1);
    try expectStatus(.ok, abi.vfs_request_cancel(request));
    const result = try rangeResult(request, 0);
    try std.testing.expectEqual(@intFromEnum(reads.State.done), result.state);
    try expectStatus(.ok, result.last_status);
    try std.testing.expectEqual(@as(u64, out.len), result.bytes_read);
    var dead_stats: abi.vfs_stats_t = undefined;
    dead_stats.struct_size = @sizeOf(@TypeOf(dead_stats));
    try expectStatus(.invalid_argument, abi.vfs_get_stats(old_volume, &dead_stats));
    try expectStatus(.ok, abi.vfs_request_end(request));
    try expectStatus(.invalid_argument, abi.vfs_request_end(request));
    try expectStatus(.invalid_argument, abi.vfs_request_wait(request, 0));
    try expectStatus(.invalid_argument, abi.vfs_request_cancel(request));
}

test "completed unreleased requests consume bounded admission until end frees capacity" {
    const options: abi.vfs_open_options_t = .{ .struct_size = @sizeOf(abi.vfs_open_options_t), .flags = 0, .read_workers = 1, .max_requests = 1, .max_ranges_per_request = 2, .read_scratch_bytes = 128 * 1024 };
    var f = try Fixture.open("capacity", &options, 0);
    defer f.close();
    var out: [8]u8 = undefined;
    var request: u64 = 0;
    try expectStatus(.ok, abi.vfs_read_async(f.file, 0, &out, out.len, null, &request));
    defer _ = abi.vfs_request_end(request);
    try waitDone(request, out.len, 1);
    var untouched: [8]u8 = @splat(poison);
    var rejected: u64 = 99;
    try expectStatus(.busy, abi.vfs_read_async(f.file, 0, &untouched, untouched.len, null, &rejected));
    try std.testing.expectEqual(@as(u64, 0), rejected);
    try expectPoison(&untouched);
    rejected = 99;
    try expectStatus(.busy, abi.vfs_prefetch_async(f.file, 0, 1, null, &rejected));
    try std.testing.expectEqual(@as(u64, 0), rejected);
    const full = try stats(f.volume);
    try std.testing.expectEqual(@as(u64, 1), full.requests_retained);
    try std.testing.expectEqual(@as(u64, 1), full.requests_completed);
    try std.testing.expectEqual(@as(u64, 2), full.requests_rejected);
    try std.testing.expectEqual(@as(u64, 0), full.requests_queued + full.requests_running);
    try std.testing.expectEqual(@as(u32, 1), full.worker_limit);
    try std.testing.expectEqual(@as(u32, 1), full.request_limit);
    try std.testing.expectEqual(@as(u32, 2), full.ranges_limit);
    try std.testing.expectEqual(@as(u64, 128 * 1024), full.scratch_limit_per_worker);
    try expectStatus(.ok, abi.vfs_request_end(request));
    try std.testing.expectEqual(@as(u64, 0), (try stats(f.volume)).requests_retained);
    var next: u64 = 0;
    try expectStatus(.ok, abi.vfs_read_async(f.file, 1, &out, out.len, null, &next));
    defer _ = abi.vfs_request_end(next);
    try std.testing.expect(next != request);
    try waitDone(next, out.len, 1);
    try expectStatus(.invalid_argument, abi.vfs_request_cancel(request));
    try expectStatus(.invalid_argument, abi.vfs_request_end(request));
}

test "async read malformed submissions clear output IDs and never touch destinations" {
    const options: abi.vfs_open_options_t = .{ .struct_size = @sizeOf(abi.vfs_open_options_t), .flags = 0, .read_workers = 1, .max_ranges_per_request = 2 };
    var f = try Fixture.open("arguments", &options, 0);
    defer f.close();
    var out: [32]u8 = @splat(poison);
    var request: u64 = 99;
    try expectStatus(.invalid_argument, abi.vfs_read_async(f.file, 0, &out, out.len, null, null));
    try expectStatus(.invalid_argument, abi.vfs_read_async(f.file, 0, null, 1, null, &request));
    try std.testing.expectEqual(@as(u64, 0), request);
    request = 99;
    try expectStatus(.invalid_argument, abi.vfs_read_async(f.volume, 0, &out, 1, null, &request));
    try std.testing.expectEqual(@as(u64, 0), request);
    request = 99;
    try expectStatus(.invalid_argument, abi.vfs_read_async(0, 0, &out, 1, null, &request));
    try std.testing.expectEqual(@as(u64, 0), request);
    request = 99;
    const wrapping: *anyopaque = @ptrFromInt(std.math.maxInt(usize) - 7);
    try expectStatus(.invalid_argument, abi.vfs_read_async(f.file, 0, wrapping, 16, null, &request));
    try std.testing.expectEqual(@as(u64, 0), request);
    var ranges = [_]abi.vfs_read_range_t{
        .{ .offset = 0, .dst = &out, .size = 8 },
        .{ .offset = 8, .dst = null, .size = 8 },
        .{ .offset = 16, .dst = &out[16], .size = 8 },
    };
    request = 99;
    try expectStatus(.invalid_argument, abi.vfs_read_batch_async(f.file, &ranges, 2, null, &request));
    try std.testing.expectEqual(@as(u64, 0), request);
    ranges[1].dst = &out[8];
    request = 99;
    try expectStatus(.invalid_argument, abi.vfs_read_batch_async(f.file, &ranges, 3, null, &request));
    try std.testing.expectEqual(@as(u64, 0), request);
    request = 99;
    try expectStatus(.invalid_argument, abi.vfs_read_batch_async(f.file, &ranges, 0, null, &request));
    try std.testing.expectEqual(@as(u64, 0), request);
    request = 99;
    try expectStatus(.invalid_argument, abi.vfs_read_batch_async(f.file, null, 1, null, &request));
    try std.testing.expectEqual(@as(u64, 0), request);
    for ([_]abi.vfs_read_options_t{
        .{ .struct_size = 7, .flags = 0 },
        .{ .struct_size = @sizeOf(abi.vfs_read_options_t), .flags = 1 },
    }) |bad_options| {
        request = 99;
        try expectStatus(.invalid_argument, abi.vfs_read_async(f.file, 0, &out, out.len, &bad_options, &request));
        try std.testing.expectEqual(@as(u64, 0), request);
        request = 99;
        try expectStatus(.invalid_argument, abi.vfs_prefetch_async(f.file, 0, 8, &bad_options, &request));
        try std.testing.expectEqual(@as(u64, 0), request);
    }
    try expectPoison(&out);
    try std.testing.expectEqual(@as(u64, 0), (try stats(f.volume)).requests_retained);

    // Old eight-byte options prefixes default absent fields; zero-length
    // destinations and enormous offsets remain valid successful EOF reads.
    const prefix = extern struct { struct_size: u32 = 8, flags: u32 = 0 }{};
    try expectStatus(.ok, abi.vfs_read_async(f.file, std.math.maxInt(u64), null, 0, @ptrCast(&prefix), &request));
    defer _ = abi.vfs_request_end(request);
    try waitDone(request, 0, 1);
    const invalid_open: abi.vfs_open_options_t = .{ .struct_size = @sizeOf(abi.vfs_open_options_t), .flags = 0, .read_workers = 65 };
    var invalid_volume: u64 = 99;
    try expectStatus(.invalid_argument, abi.vfs_open_volume("invalid-workers", &invalid_open, &invalid_volume));
    try std.testing.expectEqual(@as(u64, 0), invalid_volume);
}

fn checkOutputPrefixes(comptime T: type, handle: u64) !void {
    for (0..@sizeOf(T) + 9) |size| {
        var storage: [@sizeOf(T) + 16]u8 align(@alignOf(T)) = @splat(poison);
        const out: *T = @ptrCast(&storage);
        out.struct_size = @intCast(size);
        const before = storage;
        const status = if (T == abi.vfs_request_progress_t)
            abi.vfs_request_poll(handle, out)
        else if (T == abi.vfs_read_result_t)
            abi.vfs_request_result(handle, 0, out)
        else
            abi.vfs_get_stats(handle, out);
        try expectStatus(if (size < 8) .invalid_argument else .ok, status);
        const written = if (size < 8) 4 else @min(size, @sizeOf(T));
        try std.testing.expectEqualSlices(u8, before[written..], storage[written..]);
        try std.testing.expectEqual(@as(u32, @intCast(size)), out.struct_size);
        if (T != abi.vfs_stats_t) {
            if (size >= 8) try std.testing.expectEqual(@intFromEnum(reads.State.done), out.state);
        }
    }
}

test "request progress result and stats honor byte-granular versioned output prefixes" {
    var f = try Fixture.open("prefixes", null, 0);
    defer f.close();
    var request: u64 = 0;
    try expectStatus(.ok, abi.vfs_read_async(f.file, 0, null, 0, null, &request));
    defer _ = abi.vfs_request_end(request);
    try waitDone(request, 0, 1);
    try checkOutputPrefixes(abi.vfs_request_progress_t, request);
    try checkOutputPrefixes(abi.vfs_read_result_t, request);
    try checkOutputPrefixes(abi.vfs_stats_t, f.volume);
    try expectStatus(.invalid_argument, abi.vfs_request_poll(request, null));
    try expectStatus(.invalid_argument, abi.vfs_request_result(request, 0, null));
    try expectStatus(.invalid_argument, abi.vfs_get_stats(f.volume, null));
    var result: abi.vfs_read_result_t = undefined;
    @memset(std.mem.asBytes(&result), poison);
    result.struct_size = @sizeOf(@TypeOf(result));
    const before = result;
    try expectStatus(.invalid_argument, abi.vfs_request_result(request, 1, &result));
    try std.testing.expectEqualSlices(u8, std.mem.asBytes(&before), std.mem.asBytes(&result));
    try expectStatus(.invalid_argument, abi.vfs_request_result(f.file, 0, &result));
    try std.testing.expectEqualSlices(u8, std.mem.asBytes(&before), std.mem.asBytes(&result));
    try expectStatus(.invalid_argument, abi.vfs_request_wait(f.file, 0));
    try expectStatus(.invalid_argument, abi.vfs_request_cancel(f.volume));
    try expectStatus(.invalid_argument, abi.vfs_request_end(f.file));
}

/// Occupy the sole store slot with an unrelated pack. A request for the
/// fixture's parked pack sleeps in pinMounted, exposing store_waiters as a
/// deterministic gate without changing any production code.
const StoreGate = struct {
    held: registry.Lease(volume_mod.Volume),
    mounted: *volume_mod.Volume.MountedPack,
    pack: [:0]const u8,
    blocked: bool = true,

    fn open(f: *const Fixture, comptime tag: []const u8) !StoreGate {
        const pack = "zig-cache-vfs-read-request-gate-" ++ tag;
        try fixture.buildPack(std.testing.allocator, pack, pack, &.{.{ .path = "/unrelated", .file_entry = file_entry + 1, .data = "store gate", .page_size = 32 }}, pack_id + 1, 1, 1);
        errdefer fixture.cleanup(pack);
        try expectStatus(.ok, abi.vfs_mount_pack(f.volume, pack, 2, 0));
        const held = try registry.acquire(volume_mod.Volume, f.volume, .volume);
        errdefer held.release();
        const mounted = try held.ptr.pinStoreMounted(pack_id + 1, 1);
        return .{ .held = held, .mounted = mounted, .pack = pack };
    }

    fn waitBlocked(self: *const StoreGate) !void {
        const deadline = scheduler.nowNs() + 10 * std.time.ns_per_s;
        while (self.held.ptr.store_waiters.load(.acquire) == 0) {
            if (scheduler.nowNs() >= deadline) return error.TestUnexpectedResult;
            std.Thread.yield() catch {};
        }
    }

    fn unblock(self: *StoreGate) void {
        if (!self.blocked) return;
        self.blocked = false;
        self.held.ptr.unpinMounted(self.mounted);
    }

    fn close(self: *StoreGate) void {
        self.unblock();
        self.held.release();
    }
};

fn gatedOptions() abi.vfs_open_options_t {
    return .{ .struct_size = @sizeOf(abi.vfs_open_options_t), .flags = 0, .read_workers = 1, .max_open_stores = 1, .max_requests = 8 };
}

fn waitInvalid(comptime T: type, handle: u64, kind: registry.HandleKind) !void {
    const deadline = scheduler.nowNs() + 10 * std.time.ns_per_s;
    while (true) {
        if (registry.acquire(T, handle, kind)) |held| {
            held.release();
        } else |e| {
            if (e != error.InvalidArgument) return e;
            return;
        }
        if (scheduler.nowNs() >= deadline) return error.TestUnexpectedResult;
        std.Thread.yield() catch {};
    }
}

const CloseFile = struct {
    file: u64,
    status: c_int = -1,
    done: std.atomic.Value(bool) = .init(false),

    fn run(self: *@This()) void {
        self.status = abi.vfs_close_file(self.file);
        self.done.store(true, .release);
    }
};

test "queued cancellation and running partial cancellation drain file close and exclude updates" {
    const options = gatedOptions();
    var f = try Fixture.open("cancel-close", &options, 0);
    errdefer f.close();
    var gate = try StoreGate.open(&f, "cancel-close");
    defer {
        gate.close();
        f.close();
        fixture.cleanup(gate.pack);
    }
    var out: [2 * page_size + 17]u8 = @splat(poison);
    var later: [8]u8 = @splat(poison);
    const ranges = [_]abi.vfs_read_range_t{
        .{ .offset = 0, .dst = &out, .size = out.len },
        .{ .offset = 0, .dst = &later, .size = later.len },
    };
    var running: u64 = 0;
    try expectStatus(.ok, abi.vfs_read_batch_async(f.file, &ranges, ranges.len, null, &running));
    defer {
        gate.unblock();
        _ = abi.vfs_request_end(running);
    }
    try gate.waitBlocked();
    try std.testing.expectEqual(@intFromEnum(reads.State.running), (try progress(running)).state);
    try expectStatus(.busy, abi.vfs_request_wait(running, 0));

    var queued_out: [16]u8 = @splat(poison);
    var queued: u64 = 0;
    try expectStatus(.ok, abi.vfs_read_async(f.file, 0, &queued_out, queued_out.len, null, &queued));
    defer _ = abi.vfs_request_end(queued);
    try std.testing.expectEqual(@intFromEnum(reads.State.queued), (try progress(queued)).state);
    try expectStatus(.busy, abi.vfs_request_wait(queued, 0));
    try expectStatus(.ok, abi.vfs_request_cancel(queued));
    try expectStatus(.ok, abi.vfs_request_wait(queued, 0));
    const cancelled = try progress(queued);
    try std.testing.expectEqual(@intFromEnum(reads.State.cancelled), cancelled.state);
    try expectStatus(.cancelled, cancelled.last_status);
    try std.testing.expectEqual(@as(u32, 0), cancelled.ranges_done);
    try std.testing.expectEqual(@as(u64, 0), cancelled.bytes_read);
    try std.testing.expectEqual(@intFromEnum(reads.State.queued), (try rangeResult(queued, 0)).state);
    try expectPoison(&queued_out);
    try expectStatus(.ok, abi.vfs_request_cancel(queued)); // idempotent terminal cancel
    try expectStatus(.ok, abi.vfs_request_cancel(running));
    try expectStatus(.busy, abi.vfs_request_wait(running, 0));

    var closing = CloseFile{ .file = f.file };
    const thread = try std.Thread.spawn(.{}, CloseFile.run, .{&closing});
    var joined = false;
    defer if (!joined) {
        gate.unblock();
        thread.join();
    };
    f.file = 0;
    try waitInvalid(file_mod.FileHandle, closing.file, .file);
    try std.testing.expect(!closing.done.load(.acquire));
    try expectStatus(.busy, abi.vfs_close_volume(f.volume));
    try std.testing.expectError(error.Busy, gate.held.ptr.acquireUpdateLease(pack_id));
    try expectPoison(&out);
    try expectPoison(&later);
    var rejected: u64 = 123;
    try expectStatus(.invalid_argument, abi.vfs_read_async(closing.file, 0, &later, later.len, null, &rejected));
    try std.testing.expectEqual(@as(u64, 0), rejected);
    // Closing this file must not block unrelated registry admissions.
    var independent: u64 = 0;
    try expectStatus(.ok, abi.vfs_open_volume("unrelated-during-read-drain", null, &independent));
    try expectStatus(.ok, abi.vfs_close_volume(independent));

    gate.unblock();
    thread.join();
    joined = true;
    try expectStatus(.ok, closing.status);
    try expectStatus(.ok, abi.vfs_request_wait(running, 10_000));
    const finished = try progress(running);
    try std.testing.expectEqual(@intFromEnum(reads.State.cancelled), finished.state);
    try expectStatus(.cancelled, finished.last_status);
    try std.testing.expectEqual(@as(u64, page_size), finished.bytes_read);
    try std.testing.expectEqual(@as(u32, 0), finished.ranges_done);
    const partial = try rangeResult(running, 0);
    try std.testing.expectEqual(@intFromEnum(reads.State.cancelled), partial.state);
    try expectStatus(.cancelled, partial.last_status);
    try std.testing.expectEqual(@as(u64, page_size), partial.bytes_read);
    try std.testing.expectEqual(@intFromEnum(reads.State.queued), (try rangeResult(running, 1)).state);
    const expected = payload();
    try std.testing.expectEqualSlices(u8, expected[0..page_size], out[0..page_size]);
    try expectPoison(out[page_size..]);
    try expectPoison(&later);
    try expectPoison(&queued_out);
    const counts = try stats(f.volume);
    try std.testing.expectEqual(@as(u64, 2), counts.requests_cancelled);
    try std.testing.expectEqual(@as(u64, 2), counts.requests_retained);
    try std.testing.expectEqual(@as(u64, 0), counts.requests_running + counts.requests_queued);
    // Terminal result handles retain no file/update dependency.
    var update = try gate.held.ptr.acquireUpdateLease(pack_id);
    try update.release(false, false);
}

const EndRequest = struct {
    request: u64,
    status: c_int = -1,
    done: std.atomic.Value(bool) = .init(false),

    fn run(self: *@This()) void {
        self.status = abi.vfs_request_end(self.request);
        self.done.store(true, .release);
    }
};

test "request end invalidates once drains admitted callers and cancels before destination release" {
    const options = gatedOptions();
    var f = try Fixture.open("end-race", &options, 0);
    errdefer f.close();
    var gate = try StoreGate.open(&f, "end-race");
    defer {
        gate.close();
        f.close();
        fixture.cleanup(gate.pack);
    }
    var out: [2 * page_size]u8 = @splat(poison);
    var request: u64 = 0;
    try expectStatus(.ok, abi.vfs_read_async(f.file, 0, &out, out.len, null, &request));
    defer {
        gate.unblock();
        _ = abi.vfs_request_end(request);
    }
    try gate.waitBlocked();
    const held = try registry.acquire(reads.Request, request, .request);
    var held_live = true;
    defer if (held_live) held.release();
    var ending = EndRequest{ .request = request };
    const thread = try std.Thread.spawn(.{}, EndRequest.run, .{&ending});
    var joined = false;
    defer if (!joined) {
        if (held_live) {
            held.release();
            held_live = false;
        }
        gate.unblock();
        thread.join();
    };
    try waitInvalid(reads.Request, request, .request);
    try std.testing.expect(!ending.done.load(.acquire));
    try std.testing.expect(!held.ptr.cancel_flag.load(.acquire));
    try expectStatus(.invalid_argument, abi.vfs_request_end(request));
    try expectStatus(.invalid_argument, abi.vfs_request_cancel(request));
    try expectStatus(.invalid_argument, abi.vfs_request_wait(request, 0));
    var p: abi.vfs_request_progress_t = undefined;
    p.struct_size = @sizeOf(@TypeOf(p));
    try expectStatus(.invalid_argument, abi.vfs_request_poll(request, &p));
    var r: abi.vfs_read_result_t = undefined;
    r.struct_size = @sizeOf(@TypeOf(r));
    try expectStatus(.invalid_argument, abi.vfs_request_result(request, 0, &r));
    // This pointer remains live after releasing admission because the gated
    // worker cannot finish, and destroy must wait for that worker.
    const job = held.ptr;
    held.release();
    held_live = false;
    const deadline = scheduler.nowNs() + 10 * std.time.ns_per_s;
    while (!job.cancel_flag.load(.acquire)) {
        if (scheduler.nowNs() >= deadline) return error.TestUnexpectedResult;
        std.Thread.yield() catch {};
    }
    try std.testing.expect(!ending.done.load(.acquire));
    try expectPoison(&out);
    gate.unblock();
    thread.join();
    joined = true;
    try expectStatus(.ok, ending.status);
    const expected = payload();
    try std.testing.expectEqualSlices(u8, expected[0..page_size], out[0..page_size]);
    try expectPoison(out[page_size..]);
    const counters = try stats(f.volume);
    try std.testing.expectEqual(@as(u64, 0), counters.requests_retained);
    try std.testing.expectEqual(@as(u64, 0), counters.requests_running + counters.requests_queued);
    try std.testing.expectEqual(@as(u64, 1), counters.requests_cancelled);
    try std.testing.expectEqual(@as(u64, page_size), counters.bytes_read);
    // Returning from end releases buffer ownership even for a cancelled job.
    @memset(&out, poison);
    try expectPoison(&out);
}

test "one worker selects queued priorities then FIFO ties and copies options at submission" {
    const options = gatedOptions();
    var f = try Fixture.open("priority", &options, 0);
    errdefer f.close();
    var gate = try StoreGate.open(&f, "priority");
    defer {
        gate.close();
        f.close();
        fixture.cleanup(gate.pack);
    }
    var blocking_out: [1]u8 = undefined;
    var blocker: u64 = 0;
    try expectStatus(.ok, abi.vfs_read_async(f.file, 0, &blocking_out, 1, null, &blocker));
    defer {
        gate.unblock();
        _ = abi.vfs_request_end(blocker);
    }
    try gate.waitBlocked();
    // The single worker serializes writes across these requests. Distinct
    // regions make both priority ordering and FIFO tie-breaking observable.
    var out: [32]u8 = @splat(poison);
    var queued: [4]u64 = @splat(0);
    defer for (queued) |request| if (request != 0) {
        _ = abi.vfs_request_end(request);
    };
    try expectStatus(.ok, abi.vfs_read_async(f.file, 32, &out, out.len, null, &queued[0]));
    try expectStatus(.ok, abi.vfs_read_async(f.file, 64, &out[8], 8, null, &queued[1]));
    var high: abi.vfs_read_options_t = .{ .struct_size = @sizeOf(abi.vfs_read_options_t), .flags = 0, .priority = 10 };
    try expectStatus(.ok, abi.vfs_read_async(f.file, 96, &out, out.len, &high, &queued[2]));
    high.priority = -20;
    var low: abi.vfs_read_options_t = .{ .struct_size = @sizeOf(abi.vfs_read_options_t), .flags = 0, .priority = -10 };
    try expectStatus(.ok, abi.vfs_read_async(f.file, 128, &out[24], 8, &low, &queued[3]));
    low.priority = 20;
    for (queued) |request| try std.testing.expectEqual(@intFromEnum(reads.State.queued), (try progress(request)).state);
    try expectPoison(&out);
    gate.unblock();
    try waitDone(blocker, 1, 1);
    for (queued, [_]u64{ 32, 8, 32, 8 }) |request, bytes| try waitDone(request, bytes, 1);
    const expected = payload();
    try std.testing.expectEqualSlices(u8, expected[32..40], out[0..8]);
    try std.testing.expectEqualSlices(u8, expected[64..72], out[8..16]);
    try std.testing.expectEqualSlices(u8, expected[48..56], out[16..24]);
    try std.testing.expectEqualSlices(u8, expected[128..136], out[24..32]);
}

test "worker resource failure stops a batch and retains only valid completed prefixes" {
    const options: abi.vfs_open_options_t = .{ .struct_size = @sizeOf(abi.vfs_open_options_t), .flags = 0, .read_workers = 1, .page_cache_bytes = page_size - 1 };
    var f = try Fixture.open("resource-limit", &options, 0);
    defer f.close();
    var out: [16]u8 = @splat(poison);
    const ranges = [_]abi.vfs_read_range_t{
        .{ .offset = 0, .dst = null, .size = 0 },
        .{ .offset = 0, .dst = &out, .size = 8 },
        .{ .offset = 8, .dst = &out[8], .size = 8 },
    };
    var request: u64 = 0;
    try expectStatus(.ok, abi.vfs_read_batch_async(f.file, &ranges, ranges.len, null, &request));
    defer _ = abi.vfs_request_end(request);
    // wait reports terminal availability, not the recorded IO error.
    try expectStatus(.ok, abi.vfs_request_wait(request, 10_000));
    const p = try progress(request);
    try std.testing.expectEqual(@intFromEnum(reads.State.failed), p.state);
    try expectStatus(.resource_limit, p.last_status);
    try std.testing.expectEqual(@as(u32, 3), p.ranges_total);
    try std.testing.expectEqual(@as(u32, 1), p.ranges_done);
    try std.testing.expectEqual(@as(u64, 0), p.bytes_read);
    try std.testing.expectEqual(@intFromEnum(reads.State.done), (try rangeResult(request, 0)).state);
    const failed = try rangeResult(request, 1);
    try std.testing.expectEqual(@intFromEnum(reads.State.failed), failed.state);
    try expectStatus(.resource_limit, failed.last_status);
    const skipped = try rangeResult(request, 2);
    try std.testing.expectEqual(@intFromEnum(reads.State.queued), skipped.state);
    try std.testing.expectEqual(@as(u64, 0), skipped.bytes_read);
    try expectPoison(&out);
    try expectStatus(.ok, abi.vfs_request_cancel(request));
    try std.testing.expectEqual(@intFromEnum(reads.State.failed), (try progress(request)).state);
    const count = try stats(f.volume);
    try std.testing.expectEqual(@as(u64, 1), count.requests_failed);
    try std.testing.expectEqual(@as(u64, 0), count.requests_cancelled);
    try std.testing.expectEqual(@as(u64, 0), count.cache_allocated_bytes);
    try std.testing.expectEqual(@as(u64, 0), count.cache_inflight_bytes);
    try std.testing.expect(count.cache_peak_bytes <= count.cache_limit_bytes);
}

test "request allocation failures release admission metadata and borrowed file leases" {
    var f = try Fixture.open("allocation", null, 0);
    defer f.close();
    const held = try registry.acquire(file_mod.FileHandle, f.file, .file);
    defer held.release();
    const Check = struct {
        fn run(allocator: std.mem.Allocator, file: registry.Lease(file_mod.FileHandle)) !void {
            const pool = try reads.Executor.createWithAllocator(allocator, .{ .workers = 1, .max_requests = 1, .max_ranges = 1 });
            defer pool.shutdown();
            const request = pool.submit(file, &.{.{ .offset = 0, .dst = null, .size = 0 }}, 0, false) catch |e| {
                const count = pool.snapshot();
                try std.testing.expectEqual(@as(u64, 0), count.retained);
                try std.testing.expectEqual(@as(u64, 0), count.queued + count.running);
                try std.testing.expectEqual(@as(usize, 1), pool.refs.load(.acquire));
                return e;
            };
            try expectStatus(.ok, abi.vfs_request_end(request));
            const count = pool.snapshot();
            try std.testing.expectEqual(@as(u64, 0), count.retained);
            try std.testing.expectEqual(@as(u64, 0), count.queued + count.running);
            try std.testing.expectEqual(@as(usize, 1), pool.refs.load(.acquire));
        }
    };
    try std.testing.checkAllAllocationFailures(std.testing.allocator, Check.run, .{held});
}

test "worker scratch cap reports permanent resource failure without destination writes" {
    const options: abi.vfs_open_options_t = .{ .struct_size = @sizeOf(abi.vfs_open_options_t), .flags = 0, .read_workers = 1, .read_scratch_bytes = 1 };
    var f = try Fixture.open("scratch-limit", &options, 0);
    defer f.close();
    var out: [32]u8 = @splat(poison);
    var request: u64 = 0;
    try expectStatus(.ok, abi.vfs_read_async(f.file, 0, &out, out.len, null, &request));
    defer _ = abi.vfs_request_end(request);
    try expectStatus(.ok, abi.vfs_request_wait(request, 10_000));
    const p = try progress(request);
    try std.testing.expectEqual(@intFromEnum(reads.State.failed), p.state);
    try expectStatus(.resource_limit, p.last_status);
    try std.testing.expectEqual(@as(u64, 0), p.bytes_read);
    const r = try rangeResult(request, 0);
    try std.testing.expectEqual(@intFromEnum(reads.State.failed), r.state);
    try expectStatus(.resource_limit, r.last_status);
    try std.testing.expectEqual(@as(u64, 0), r.bytes_read);
    try expectPoison(&out);
    const count = try stats(f.volume);
    try std.testing.expectEqual(@as(u64, 1), count.scratch_limit_per_worker);
    try std.testing.expect(count.scratch_peak_worker_bytes <= count.scratch_limit_per_worker);
    try std.testing.expect(count.scratch_retained_bytes <= count.worker_limit * count.scratch_limit_per_worker);
    try std.testing.expectEqual(@as(u64, 0), count.cache_allocated_bytes);
    try std.testing.expectEqual(@as(u64, 0), count.cache_inflight_bytes);
    try std.testing.expectEqual(@as(u64, 1), count.requests_failed);
}

test "synchronous fitting reads remain successful under concurrent two-page cache pressure" {
    const options: abi.vfs_open_options_t = .{ .struct_size = @sizeOf(abi.vfs_open_options_t), .flags = 0, .page_cache_bytes = 2 * page_size };
    var f = try Fixture.open("sync-pressure", &options, 0);
    defer f.close();
    const expected = payload();
    var start: std.atomic.Value(bool) = .init(false);
    var ready: std.atomic.Value(u32) = .init(0);
    const Reader = struct {
        file: u64,
        index: usize,
        expected: *const [payload_size]u8,
        start: *std.atomic.Value(bool),
        ready: *std.atomic.Value(u32),
        status: c_int = -1,
        matched: bool = true,

        fn run(self: *@This()) void {
            defer @import("db_internal").data_file.releaseReadScratch();
            _ = self.ready.fetchAdd(1, .release);
            while (!self.start.load(.acquire)) std.Thread.yield() catch {};
            var out: [1024]u8 = undefined;
            for (0..64) |i| {
                const offset = ((self.index + i) % 3) * page_size + ((i * 67) % 3500);
                var count: u64 = 0;
                self.status = abi.vfs_read_at(self.file, offset, &out, out.len, &count);
                if (self.status != errors.code(.ok)) return;
                const wanted = @min(out.len, payload_size - offset);
                if (count != wanted or !std.mem.eql(u8, self.expected[offset..][0..wanted], out[0..wanted])) {
                    self.matched = false;
                    return;
                }
            }
        }
    };
    var readers: [8]Reader = undefined;
    var threads: [8]std.Thread = undefined;
    var spawned: usize = 0;
    var joined = false;
    defer if (!joined) {
        start.store(true, .release);
        for (threads[0..spawned]) |thread| thread.join();
    };
    for (&readers, 0..) |*reader, i| {
        reader.* = .{ .file = f.file, .index = i, .expected = &expected, .start = &start, .ready = &ready };
        threads[i] = try std.Thread.spawn(.{}, Reader.run, .{reader});
        spawned += 1;
    }
    const deadline = scheduler.nowNs() + 10 * std.time.ns_per_s;
    while (ready.load(.acquire) != readers.len) {
        if (scheduler.nowNs() >= deadline) return error.TestUnexpectedResult;
        std.Thread.yield() catch {};
    }
    start.store(true, .release);
    for (threads) |thread| thread.join();
    joined = true;
    for (readers) |reader| {
        try expectStatus(.ok, reader.status);
        try std.testing.expect(reader.matched);
    }
    const count = try stats(f.volume);
    try std.testing.expect(count.cache_evictions > 0);
    try std.testing.expect(count.cache_peak_bytes <= count.cache_limit_bytes);
    try std.testing.expect(count.cache_allocated_bytes <= count.cache_limit_bytes);
    try std.testing.expectEqual(@as(u64, 0), count.cache_pinned_bytes);
    try std.testing.expectEqual(@as(u64, 0), count.cache_inflight_bytes);
    try std.testing.expectEqual(@as(u64, 0), count.requests_retained);
}
