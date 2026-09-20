const std = @import("std");
const vfs = @import("vfs");

const builder = vfs.build.pack_builder;
const pack_tools = vfs.tools.pack_tools;
const abi = vfs.abi;
const err = vfs.errors;

test "pack write then mount and read back" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    const pack_path = "zig-cache-vfs-pack-roundtrip";
    const source_path = "zig-cache-vfs-pack-roundtrip-source.bin";
    const payload = "hello-vfs-pack";

    _ = std.Io.Dir.cwd().deleteTree(io, pack_path) catch {};
    _ = std.Io.Dir.cwd().deleteFile(io, source_path) catch {};
    defer _ = std.Io.Dir.cwd().deleteTree(io, pack_path) catch {};
    defer _ = std.Io.Dir.cwd().deleteFile(io, source_path) catch {};

    try builder.writeSourceFileForTest(source_path, payload);
    try builder.createPack(pack_path, &.{.{
        .source_path = source_path,
        .virtual_path = "/textures/a.bin",
        .file_entry = 1001,
        .page_size = 4,
    }}, .{});

    var report = try pack_tools.verifyPack(pack_path, allocator);
    defer report.deinit(allocator);
    try std.testing.expect(report.ok());

    var volume: u64 = 0;
    try std.testing.expectEqual(err.code(.ok), abi.vfs_open_volume("runtime", null, &volume));
    defer _ = abi.vfs_close_volume(volume);
    try std.testing.expectEqual(err.code(.ok), abi.vfs_mount_pack(volume, pack_path, 10, 0));

    var st: abi.vfs_stat_t = .{
        .struct_size = @sizeOf(abi.vfs_stat_t),
        .flags = 0,
        .file_entry = 0,
        .size = 0,
        .page_size = 0,
        .reserved0 = 0,
    };
    try std.testing.expectEqual(err.code(.ok), abi.vfs_stat_path(volume, "/textures/a.bin", &st));
    try std.testing.expectEqual(@as(u64, 1001), st.file_entry);
    try std.testing.expectEqual(@as(u64, payload.len), st.size);

    var file: u64 = 0;
    try std.testing.expectEqual(err.code(.ok), abi.vfs_open_path(volume, "/textures/a.bin", 0, &file));
    defer _ = abi.vfs_close_file(file);

    var buf: [32]u8 = undefined;
    var n: u64 = 0;
    try std.testing.expectEqual(err.code(.ok), abi.vfs_read_at(file, 0, &buf, buf.len, &n));
    try std.testing.expectEqual(@as(u64, payload.len), n);
    try std.testing.expectEqualSlices(u8, payload, buf[0..payload.len]);

    var file_by_entry: u64 = 0;
    try std.testing.expectEqual(err.code(.ok), abi.vfs_open_entry(volume, 1001, 0, &file_by_entry));
    defer _ = abi.vfs_close_file(file_by_entry);
    n = 0;
    try std.testing.expectEqual(err.code(.ok), abi.vfs_read_at(file_by_entry, 0, &buf, buf.len, &n));
    try std.testing.expectEqualSlices(u8, payload, buf[0..payload.len]);
}
