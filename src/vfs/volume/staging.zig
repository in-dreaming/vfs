const std = @import("std");
const db_internal = @import("db_internal");
const pf = db_internal.platform.file;
const volume_mod = @import("volume.zig");
const pack_reader = @import("../pack/pack_reader.zig");
const volume_manifest = @import("../format/volume_manifest.zig");
const volume_transaction = @import("../format/volume_transaction.zig");

pub const MANIFEST_FILE = "vfs_volume_manifest.bin";
pub const TRANSACTION_FILE = "vfs_volume_transaction.bin";

pub const CommitOptions = struct {
    use_inmemory_file_ops: bool = false,
};

const FaultInjection = struct {
    fail_after_prepared: bool = false,
    fail_after_committed: bool = false,
};

pub fn writeManifest(root_path: []const u8, allocator: std.mem.Allocator, manifest: volume_manifest.VolumeManifest) !void {
    const bytes = try volume_manifest.encode(allocator, manifest);
    defer allocator.free(bytes);
    try writeMetaFile(root_path, MANIFEST_FILE, bytes);
}

pub fn loadManifest(root_path: []const u8, allocator: std.mem.Allocator) !?volume_manifest.DecodedVolumeManifest {
    const bytes = readMetaFile(root_path, MANIFEST_FILE, allocator) catch |e| switch (e) {
        error.FileNotFound => return null,
        else => |err| return err,
    };
    defer allocator.free(bytes);
    return try volume_manifest.decode(allocator, bytes);
}

pub fn writeTransaction(root_path: []const u8, allocator: std.mem.Allocator, tx: volume_transaction.VolumeTransaction) !void {
    const bytes = try volume_transaction.encode(allocator, tx);
    defer allocator.free(bytes);
    try writeMetaFile(root_path, TRANSACTION_FILE, bytes);
}

pub fn loadTransaction(root_path: []const u8, allocator: std.mem.Allocator) !?volume_transaction.DecodedVolumeTransaction {
    const bytes = readMetaFile(root_path, TRANSACTION_FILE, allocator) catch |e| switch (e) {
        error.FileNotFound => return null,
        else => |err| return err,
    };
    defer allocator.free(bytes);
    return try volume_transaction.decode(allocator, bytes);
}

pub fn commit(root_path: []const u8, allocator: std.mem.Allocator, tx: volume_transaction.VolumeTransaction, options: CommitOptions) !void {
    return commitInternal(root_path, allocator, tx, options, .{});
}

fn commitInternal(root_path: []const u8, allocator: std.mem.Allocator, tx: volume_transaction.VolumeTransaction, options: CommitOptions, fault: FaultInjection) !void {
    if (options.use_inmemory_file_ops) return error.UnsupportedFeature;
    try verifyMounts(tx.mounts);
    var prepared = tx;
    prepared.state = .prepared;
    try writeTransaction(root_path, allocator, prepared);
    if (fault.fail_after_prepared) return error.TestCrashAfterPrepared;
    var committed = tx;
    committed.state = .committed;
    try writeTransaction(root_path, allocator, committed);
    if (fault.fail_after_committed) return error.TestCrashAfterCommitted;
    try writeManifest(root_path, allocator, .{ .volume_id = tx.volume_id, .current_version = tx.to_version, .writable_pack_id = tx.writable_pack_id, .mounts = tx.mounts });
}

pub fn recover(root_path: []const u8, allocator: std.mem.Allocator) !void {
    var tx_opt = try loadTransaction(root_path, allocator);
    if (tx_opt == null) return;
    defer tx_opt.?.deinit(allocator);
    const tx = tx_opt.?;
    if (tx.state != .committed) return;
    var manifest_opt = try loadManifest(root_path, allocator);
    defer if (manifest_opt) |*m| m.deinit(allocator);
    if (manifest_opt == null or manifest_opt.?.current_version < tx.to_version) {
        const inputs = try mountInputsFromRecords(allocator, tx.mounts);
        defer freeMountInputs(allocator, inputs);
        try writeManifest(root_path, allocator, .{ .volume_id = tx.volume_id, .current_version = tx.to_version, .writable_pack_id = tx.writable_pack_id, .mounts = inputs });
    }
}

pub fn openVolume(root_path: []const u8, allocator: std.mem.Allocator) !volume_mod.Volume {
    try recover(root_path, allocator);
    var v = try volume_mod.Volume.open(root_path, .{});
    errdefer v.close();
    var manifest_opt = try loadManifest(root_path, allocator);
    if (manifest_opt) |*manifest| {
        defer manifest.deinit(allocator);
        for (manifest.mounts) |mount| try v.mountPackWithPriority(mount.path, mount.priority, mount.flags);
    }
    return v;
}

pub fn verifyVolumeManifest(root_path: []const u8, allocator: std.mem.Allocator) !bool {
    var manifest_opt = try loadManifest(root_path, allocator);
    if (manifest_opt == null) return false;
    defer manifest_opt.?.deinit(allocator);
    const manifest = manifest_opt.?;
    for (manifest.mounts) |mount| {
        var reader = pack_reader.PackReader.open(allocator, mount.path) catch return false;
        defer reader.close(allocator);
        if (reader.manifest.pack_id != mount.pack_id or reader.manifest.pack_version != mount.pack_generation) return false;
    }
    return true;
}

fn verifyMounts(mounts: []const volume_manifest.MountInput) !void {
    for (mounts) |mount| {
        var reader = try pack_reader.PackReader.open(std.heap.smp_allocator, mount.path);
        defer reader.close(std.heap.smp_allocator);
        if (reader.manifest.pack_id != mount.pack_id or reader.manifest.pack_version != mount.pack_generation) return error.InvalidArgument;
    }
}

fn mountInputsFromRecords(allocator: std.mem.Allocator, records: []const volume_manifest.MountRecord) ![]volume_manifest.MountInput {
    const inputs = try allocator.alloc(volume_manifest.MountInput, records.len);
    errdefer freeMountInputs(allocator, inputs);
    for (records, 0..) |record, i| {
        inputs[i] = .{
            .pack_id = record.pack_id,
            .pack_generation = record.pack_generation,
            .priority = record.priority,
            .flags = record.flags,
            .path = try allocator.dupe(u8, record.path),
        };
    }
    return inputs;
}

fn freeMountInputs(allocator: std.mem.Allocator, inputs: []volume_manifest.MountInput) void {
    for (inputs) |input| allocator.free(input.path);
    allocator.free(inputs);
}

fn metaPath(allocator: std.mem.Allocator, root_path: []const u8, name: []const u8) ![]u8 {
    return std.fs.path.join(allocator, &.{ root_path, name });
}

fn writeMetaFile(root_path: []const u8, name: []const u8, bytes: []const u8) !void {
    const path = try metaPath(std.heap.smp_allocator, root_path, name);
    defer std.heap.smp_allocator.free(path);
    const io = std.Io.Threaded.global_single_threaded.io();
    var atomic_file = try std.Io.Dir.cwd().createFileAtomic(io, path, .{ .make_path = true, .replace = true });
    defer atomic_file.deinit(io);
    try atomic_file.file.writePositionalAll(io, bytes, 0);
    try atomic_file.file.sync(io);
    try atomic_file.replace(io);
}

fn readMetaFile(root_path: []const u8, name: []const u8, allocator: std.mem.Allocator) ![]u8 {
    const path = try metaPath(allocator, root_path, name);
    defer allocator.free(path);
    var file = try pf.open(path, .{ .mode = .read_only });
    defer pf.close(&file);
    const size = try pf.len(file);
    const bytes = try allocator.alloc(u8, size);
    errdefer allocator.free(bytes);
    if (try pf.preadAll(file, 0, bytes) != bytes.len) return error.Corruption;
    return bytes;
}

test "volume staging commit recover and unsupported inmemory path" {
    const builder = @import("../build/pack_builder.zig");
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    const root = "zig-cache-vfs-volume-staging-root";
    const pack_old = "zig-cache-vfs-volume-staging-pack-old";
    const pack_new = "zig-cache-vfs-volume-staging-pack-new";
    const source = "zig-cache-vfs-volume-staging-source.txt";
    _ = std.Io.Dir.cwd().deleteTree(io, root) catch {};
    _ = std.Io.Dir.cwd().deleteTree(io, pack_old) catch {};
    _ = std.Io.Dir.cwd().deleteTree(io, pack_new) catch {};
    _ = std.Io.Dir.cwd().deleteFile(io, source) catch {};
    defer _ = std.Io.Dir.cwd().deleteTree(io, root) catch {};
    defer _ = std.Io.Dir.cwd().deleteTree(io, pack_old) catch {};
    defer _ = std.Io.Dir.cwd().deleteTree(io, pack_new) catch {};
    defer _ = std.Io.Dir.cwd().deleteFile(io, source) catch {};

    try builder.writeSourceFileForTest(source, "old");
    try builder.createPack(pack_old, &.{.{ .source_path = source, .virtual_path = "/a.txt", .file_entry = 4001, .page_size = 4 }}, .{ .pack_id = 41, .pack_version = 1 });
    try builder.writeSourceFileForTest(source, "new");
    try builder.createPack(pack_new, &.{.{ .source_path = source, .virtual_path = "/a.txt", .file_entry = 4001, .page_size = 4 }}, .{ .pack_id = 41, .pack_version = 2 });

    const old_mounts = [_]volume_manifest.MountInput{.{ .pack_id = 41, .pack_generation = 1, .priority = 1, .path = pack_old }};
    try writeManifest(root, allocator, .{ .volume_id = 1, .current_version = 1, .mounts = &old_mounts });

    var v = try openVolume(root, allocator);
    var h = try v.openPath(1, "/a.txt");
    var buf: [8]u8 = undefined;
    const old_n = try h.readAt(0, &buf);
    h.close();
    v.close();
    try std.testing.expectEqualSlices(u8, "old", buf[0..old_n]);

    const new_mounts = [_]volume_manifest.MountInput{.{ .pack_id = 41, .pack_generation = 2, .priority = 1, .path = pack_new }};
    try writeTransaction(root, allocator, .{ .volume_id = 1, .from_version = 1, .to_version = 2, .state = .prepared, .mounts = &new_mounts });
    v = try openVolume(root, allocator);
    h = try v.openPath(1, "/a.txt");
    const still_old_n = try h.readAt(0, &buf);
    h.close();
    v.close();
    try std.testing.expectEqualSlices(u8, "old", buf[0..still_old_n]);

    const invalid_multi_pack = [_]volume_manifest.MountInput{
        .{ .pack_id = 41, .pack_generation = 2, .priority = 1, .path = pack_new },
        .{ .pack_id = 42, .pack_generation = 2, .priority = 2, .path = "zig-cache-vfs-volume-staging-missing-pack" },
    };
    try std.testing.expectError(error.FileNotFound, commit(root, allocator, .{ .volume_id = 1, .from_version = 1, .to_version = 2, .state = .prepared, .mounts = &invalid_multi_pack }, .{}));
    v = try openVolume(root, allocator);
    h = try v.openPath(1, "/a.txt");
    const failed_commit_n = try h.readAt(0, &buf);
    h.close();
    v.close();
    try std.testing.expectEqualSlices(u8, "old", buf[0..failed_commit_n]);

    try std.testing.expectError(error.TestCrashAfterPrepared, commitInternal(root, allocator, .{ .volume_id = 1, .from_version = 1, .to_version = 2, .state = .prepared, .mounts = &new_mounts }, .{}, .{ .fail_after_prepared = true }));
    v = try openVolume(root, allocator);
    h = try v.openPath(1, "/a.txt");
    const prepared_crash_n = try h.readAt(0, &buf);
    h.close();
    v.close();
    try std.testing.expectEqualSlices(u8, "old", buf[0..prepared_crash_n]);

    try std.testing.expectError(error.TestCrashAfterCommitted, commitInternal(root, allocator, .{ .volume_id = 1, .from_version = 1, .to_version = 2, .state = .prepared, .mounts = &new_mounts }, .{}, .{ .fail_after_committed = true }));
    v = try openVolume(root, allocator);
    h = try v.openPath(1, "/a.txt");
    const new_n = try h.readAt(0, &buf);
    h.close();
    v.close();
    try std.testing.expectEqualSlices(u8, "new", buf[0..new_n]);
    try std.testing.expect(try verifyVolumeManifest(root, allocator));
    const bad_generation = [_]volume_manifest.MountInput{.{ .pack_id = 41, .pack_generation = 99, .priority = 1, .path = pack_new }};
    try writeManifest(root, allocator, .{ .volume_id = 1, .current_version = 99, .mounts = &bad_generation });
    try std.testing.expect(!(try verifyVolumeManifest(root, allocator)));
    try writeManifest(root, allocator, .{ .volume_id = 1, .current_version = 2, .mounts = &new_mounts });
    try std.testing.expectError(error.UnsupportedFeature, commit(root, allocator, .{ .volume_id = 1, .from_version = 2, .to_version = 3, .state = .prepared, .mounts = &new_mounts }, .{ .use_inmemory_file_ops = true }));
}
