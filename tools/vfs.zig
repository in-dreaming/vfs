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
        if (args.len != 6) return usage();
        const file_entry = try std.fmt.parseUnsigned(u64, args[4], 0);
        const input = pack_builder.BuildFileInput{
            .source_path = args[5],
            .virtual_path = args[3],
            .file_entry = file_entry,
            .page_size = pack_builder.DEFAULT_PAGE_SIZE,
        };
        try pack_builder.createPack(args[2], &.{input}, .{});
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
        try w.interface.print("build rebuilt_files={d} skipped_files={d} wrote_pack={}\n", .{ result.rebuilt_files, result.skipped_files, result.wrote_pack });
        try w.interface.flush();
    } else if (std.mem.eql(u8, cmd, "recover-pack")) {
        if (args.len != 3) return usage();
        var report = try pack_tools.recoverPack(args[2], arena);
        defer report.deinit(arena);
        var stdout_buffer: [256]u8 = undefined;
        var w = std.Io.File.stdout().writer(init.io, &stdout_buffer);
        try report.print(&w.interface);
        try w.interface.flush();
        if (!report.ok()) std.process.exit(1);
    } else return usage();
}

fn usage() void {
    std.process.exit(2);
}
