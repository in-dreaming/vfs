const std = @import("std");
const db_internal = @import("db_internal");
const pf = db_internal.platform.file;
const build_cfg = @import("build_cfg.zig");
const object_key = @import("../object_key.zig");
const hash = @import("../hash.zig");
const fmt = @import("../format/common.zig");
const file_manifest = @import("../format/file_manifest.zig");
const registry = @import("../compress/registry.zig");

pub const PlanFile = struct {
    virtual_path: []u8,
    source_path: []u8,
    file_entry: u64,
    page_size: u32,
    codec: file_manifest.Codec,
    codec_level: i16,
    source_size: u64,
    source_mtime: i128,
    source_hash: [32]u8,
    build_cfg_hash: [32]u8,
    compressor_version_hash: u64,
    estimated_page_count: u32,
    file_manifest_key: u64,
    first_page_key: u64,
};

pub const BuildPlan = struct {
    pack_path: []u8,
    pack_id: u64,
    pack_name: []u8,
    files: []PlanFile,

    pub fn deinit(self: *BuildPlan, allocator: std.mem.Allocator) void {
        allocator.free(self.pack_path);
        allocator.free(self.pack_name);
        for (self.files) |file| {
            allocator.free(file.virtual_path);
            allocator.free(file.source_path);
        }
        allocator.free(self.files);
        self.* = undefined;
    }
};

pub fn create(allocator: std.mem.Allocator, cfg: build_cfg.BuildCfg) !BuildPlan {
    var files = std.ArrayList(PlanFile).empty;
    errdefer {
        for (files.items) |file| {
            allocator.free(file.virtual_path);
            allocator.free(file.source_path);
        }
        files.deinit(allocator);
    }
    for (cfg.files) |file| {
        const page_size = file.page_size orelse cfg.default_page_size;
        const codec = file.codec orelse cfg.default_codec;
        const codec_level = file.codec_level orelse cfg.default_codec_level;
        if (file.file_entry == 0 or page_size == 0) return error.InvalidArgument;
        const codec_id = try registry.codecIdentity(codec);
        const source = try readFileAlloc(allocator, file.source_path);
        defer allocator.free(source);
        const source_size: u64 = source.len;
        const page_count: u32 = if (source.len == 0) 0 else std.math.cast(u32, ((source.len - 1) / page_size) + 1) orelse return error.InvalidArgument;
        const fm_key = try object_key.fileManifestKey(file.file_entry);
        const first_page_key = if (page_count == 0) 0 else try object_key.pageKey(file.file_entry, 0, 0);
        try files.append(allocator, .{
            .virtual_path = try allocator.dupe(u8, file.virtual_path),
            .source_path = try allocator.dupe(u8, file.source_path),
            .file_entry = file.file_entry,
            .page_size = page_size,
            .codec = codec,
            .codec_level = codec_level,
            .source_size = source_size,
            .source_mtime = 0,
            .source_hash = hash.contentHash(source),
            .build_cfg_hash = try fileCfgHash(allocator, file, page_size, codec, codec_level),
            .compressor_version_hash = codec_id.version_hash,
            .estimated_page_count = page_count,
            .file_manifest_key = fm_key,
            .first_page_key = first_page_key,
        });
    }
    return .{
        .pack_path = try allocator.dupe(u8, cfg.pack_path),
        .pack_id = cfg.pack_id,
        .pack_name = try allocator.dupe(u8, cfg.pack_name),
        .files = try files.toOwnedSlice(allocator),
    };
}

fn fileCfgHash(allocator: std.mem.Allocator, file: build_cfg.FileConfig, page_size: u32, codec: file_manifest.Codec, codec_level: i16) ![32]u8 {
    var bytes = std.ArrayList(u8).empty;
    defer bytes.deinit(allocator);
    try bytes.appendSlice(allocator, file.virtual_path);
    try bytes.append(allocator, 0);
    try bytes.appendSlice(allocator, file.source_path);
    try bytes.append(allocator, 0);
    var buf: [8]u8 = undefined;
    fmt.putU64(&buf, 0, file.file_entry);
    try bytes.appendSlice(allocator, &buf);
    var b4: [4]u8 = undefined;
    fmt.putU32(&b4, 0, page_size);
    try bytes.appendSlice(allocator, &b4);
    var b2: [2]u8 = undefined;
    fmt.putU16(&b2, 0, @intFromEnum(codec));
    try bytes.appendSlice(allocator, &b2);
    fmt.putU16(&b2, 0, @bitCast(codec_level));
    try bytes.appendSlice(allocator, &b2);
    return hash.contentHash(bytes.items);
}

fn readFileAlloc(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    var f = try pf.open(path, .{ .mode = .read_only });
    defer pf.close(&f);
    const size = try pf.len(f);
    const buf = try allocator.alloc(u8, size);
    errdefer allocator.free(buf);
    if (try pf.preadAll(f, 0, buf) != buf.len) return error.Corruption;
    return buf;
}

test "build plan resolves metadata keys and rejects unsupported codec" {
    const allocator = std.testing.allocator;
    const builder = @import("pack_builder.zig");
    const source = "zig-cache-vfs-plan-source.bin";
    const io = std.Io.Threaded.global_single_threaded.io();
    _ = std.Io.Dir.cwd().deleteFile(io, source) catch {};
    defer _ = std.Io.Dir.cwd().deleteFile(io, source) catch {};
    try builder.writeSourceFileForTest(source, "abc");
    const cfg_bytes = try std.fmt.allocPrint(allocator,
        "pack_path=zig-cache-vfs-plan-pack\nfile=/a.txt|10|{s}|2|none|0\n",
        .{source},
    );
    defer allocator.free(cfg_bytes);
    var cfg = try build_cfg.parseBytes(allocator, cfg_bytes);
    defer cfg.deinit(allocator);
    var plan = try create(allocator, cfg);
    defer plan.deinit(allocator);
    try std.testing.expectEqual(@as(u32, 2), plan.files[0].estimated_page_count);
}
