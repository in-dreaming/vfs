const std = @import("std");
const err = @import("error.zig");
const registry = @import("handle_registry.zig");
const volume_mod = @import("volume/volume.zig");
const file_mod = @import("io/file_handle.zig");

pub const vfs_open_options_t = extern struct {
    struct_size: u32,
    flags: u32,
    reserved0: u64,
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
    return .{ .flags = opts.flags };
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
    const h = @intFromPtr(v);
    registry.register(h, .volume) catch |e| {
        v.close();
        std.heap.smp_allocator.destroy(v);
        return setError(e);
    };
    out.* = h;
    return setOk();
}

pub export fn vfs_close_volume(volume: u64) c_int {
    const v = registry.validate(volume_mod.Volume, volume, .volume) catch |e| return setError(e);
    if (v.open_file_count != 0) return setError(error.Busy);
    registry.unregister(volume);
    v.close();
    std.heap.smp_allocator.destroy(v);
    return setOk();
}

pub export fn vfs_mount_pack(volume: u64, pack_path: ?[*:0]const u8, priority: u32, flags: u32) c_int {
    const v = registry.validate(volume_mod.Volume, volume, .volume) catch |e| return setError(e);
    const path = spanZ(pack_path) catch |e| return setError(e);
    v.mountPackWithPriority(path, priority, flags) catch |e| return setError(e);
    return setOk();
}

pub export fn vfs_open_path(volume: u64, path: ?[*:0]const u8, flags: u32, out_file: ?*u64) c_int {
    _ = flags;
    const out = out_file orelse return setStatus(.invalid_argument, "out_file is null");
    out.* = 0;
    const v = registry.validate(volume_mod.Volume, volume, .volume) catch |e| return setError(e);
    const p = spanZ(path) catch |e| return setError(e);
    return openFileHandle(volume, out, v.openPath(volume, p));
}

pub export fn vfs_open_entry(volume: u64, file_entry: u64, flags: u32, out_file: ?*u64) c_int {
    _ = flags;
    const out = out_file orelse return setStatus(.invalid_argument, "out_file is null");
    out.* = 0;
    const v = registry.validate(volume_mod.Volume, volume, .volume) catch |e| return setError(e);
    if (file_entry == 0) return setStatus(.invalid_argument, "file_entry is zero");
    return openFileHandle(volume, out, v.openEntry(volume, file_entry));
}

pub export fn vfs_stat_path(volume: u64, path: ?[*:0]const u8, out_stat: ?*vfs_stat_t) c_int {
    const out = out_stat orelse return setStatus(.invalid_argument, "out_stat is null");
    const requested = out.struct_size;
    @memset(@as([*]u8, @ptrCast(out))[0..@min(@as(usize, @intCast(requested)), @sizeOf(vfs_stat_t))], 0);
    out.struct_size = requested;
    const v = registry.validate(volume_mod.Volume, volume, .volume) catch |e| return setError(e);
    const p = spanZ(path) catch |e| return setError(e);
    const st = v.statPath(p) catch |e| return setError(e);
    fillStat(out, requested, st);
    return setOk();
}

pub export fn vfs_stat_entry(volume: u64, file_entry: u64, out_stat: ?*vfs_stat_t) c_int {
    const out = out_stat orelse return setStatus(.invalid_argument, "out_stat is null");
    const requested = out.struct_size;
    @memset(@as([*]u8, @ptrCast(out))[0..@min(@as(usize, @intCast(requested)), @sizeOf(vfs_stat_t))], 0);
    out.struct_size = requested;
    const v = registry.validate(volume_mod.Volume, volume, .volume) catch |e| return setError(e);
    if (file_entry == 0) return setStatus(.invalid_argument, "file_entry is zero");
    const st = v.statEntry(file_entry) catch |e| return setError(e);
    fillStat(out, requested, st);
    return setOk();
}

pub export fn vfs_read_at(file: u64, offset: u64, dst: ?*anyopaque, size: u64, out_read: ?*u64) c_int {
    const out = out_read orelse return setStatus(.invalid_argument, "out_read is null");
    out.* = 0;
    if (size != 0 and dst == null) return setStatus(.invalid_argument, "dst is null");
    const f = registry.validate(file_mod.FileHandle, file, .file) catch |e| return setError(e);
    const len = std.math.cast(usize, size) orelse return setStatus(.invalid_argument, "size too large");
    var empty: [0]u8 = .{};
    const buf = if (len == 0) empty[0..] else @as([*]u8, @ptrCast(dst.?))[0..len];
    out.* = f.readAt(offset, buf) catch |e| return setError(e);
    return setOk();
}

pub export fn vfs_close_file(file: u64) c_int {
    const f = registry.validate(file_mod.FileHandle, file, .file) catch |e| return setError(e);
    registry.unregister(file);
    f.close();
    std.heap.smp_allocator.destroy(f);
    return setOk();
}

fn openFileHandle(volume_handle: u64, out: *u64, result: anyerror!file_mod.FileHandle) c_int {
    var value = result catch |e| return setError(e);
    const f = std.heap.smp_allocator.create(file_mod.FileHandle) catch {
        value.close();
        return setStatus(.internal_error, "allocation failed");
    };
    f.* = value;
    const h = @intFromPtr(f);
    registry.register(h, .file) catch |e| {
        f.close();
        std.heap.smp_allocator.destroy(f);
        return setError(e);
    };
    _ = volume_handle;
    out.* = h;
    return setOk();
}

fn fillStat(out: *vfs_stat_t, requested: u32, st: @import("pack/pack_reader.zig").Stat) void {
    _ = requested;
    out.flags = 0;
    out.file_entry = st.file_entry;
    out.size = st.size;
    out.page_size = st.page_size;
    out.reserved0 = 0;
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
