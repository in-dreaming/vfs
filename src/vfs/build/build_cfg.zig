const std = @import("std");
const db_internal = @import("db_internal");
const pf = db_internal.platform.file;
const hash = @import("../hash.zig");
const file_manifest = @import("../format/file_manifest.zig");

/// Minimal dependency-free BuildCfg text format:
///
///   pack_path=zig-cache-vfs-pack
///   pack_id=1
///   pack_version=1
///   pack_name=assets
///   default_page_size=65536
///   default_codec=none
///   default_codec_level=0
///   shards=4
///   default_diff_strategy=auto
///   file=/virtual.txt|1001|source/path.txt
///   file=/other.bin|1002|source.bin|4096|none|0|page
///
/// Empty lines and lines starting with '#' are ignored. Paths must not contain '|'.
/// The optional 7th file field is the diff strategy override
/// (auto | logical | page | replace).
pub const DiffStrategy = enum(u8) {
    auto = 0,
    logical = 1,
    page = 2,
    replace = 3,
};

pub const FileConfig = struct {
    virtual_path: []u8,
    source_path: []u8,
    file_entry: u64,
    page_size: ?u32 = null,
    codec: ?file_manifest.Codec = null,
    codec_level: ?i16 = null,
    diff_strategy: ?DiffStrategy = null,
};

pub const BuildCfg = struct {
    pack_path: []u8,
    pack_id: u64 = 1,
    pack_version: u64 = 1,
    pack_name: []u8,
    default_page_size: u32 = 64 * 1024,
    default_codec: file_manifest.Codec = .none,
    default_codec_level: i16 = 0,
    default_diff_strategy: DiffStrategy = .auto,
    shards: u32 = 1,
    files: []FileConfig,
    raw_hash: [32]u8,

    pub fn deinit(self: *BuildCfg, allocator: std.mem.Allocator) void {
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

pub fn parseFile(allocator: std.mem.Allocator, cfg_path: []const u8) !BuildCfg {
    const bytes = try readFileAlloc(allocator, cfg_path);
    defer allocator.free(bytes);
    return parseBytes(allocator, bytes);
}

pub fn parseBytes(allocator: std.mem.Allocator, bytes: []const u8) !BuildCfg {
    var pack_path: ?[]u8 = null;
    errdefer if (pack_path) |p| allocator.free(p);
    var pack_name = try allocator.dupe(u8, "pack");
    errdefer allocator.free(pack_name);
    var pack_id: u64 = 1;
    var pack_version: u64 = 1;
    var default_page_size: u32 = 64 * 1024;
    var default_codec: file_manifest.Codec = .none;
    var default_codec_level: i16 = 0;
    var default_diff_strategy: DiffStrategy = .auto;
    var shards: u32 = 1;
    var files = std.ArrayList(FileConfig).empty;
    errdefer {
        for (files.items) |file| {
            allocator.free(file.virtual_path);
            allocator.free(file.source_path);
        }
        files.deinit(allocator);
    }

    var lines = std.mem.splitScalar(u8, bytes, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        const eq = std.mem.indexOfScalar(u8, line, '=') orelse return error.InvalidArgument;
        const key = std.mem.trim(u8, line[0..eq], " \t");
        const value = std.mem.trim(u8, line[eq + 1 ..], " \t");
        if (std.mem.eql(u8, key, "pack_path")) {
            if (pack_path) |old| allocator.free(old);
            pack_path = try allocator.dupe(u8, value);
        } else if (std.mem.eql(u8, key, "pack_id")) {
            pack_id = try std.fmt.parseUnsigned(u64, value, 0);
        } else if (std.mem.eql(u8, key, "pack_version")) {
            pack_version = try std.fmt.parseUnsigned(u64, value, 0);
        } else if (std.mem.eql(u8, key, "pack_name")) {
            allocator.free(pack_name);
            pack_name = try allocator.dupe(u8, value);
        } else if (std.mem.eql(u8, key, "default_page_size")) {
            default_page_size = try std.fmt.parseUnsigned(u32, value, 0);
        } else if (std.mem.eql(u8, key, "default_codec")) {
            default_codec = try parseCodec(value);
        } else if (std.mem.eql(u8, key, "default_codec_level")) {
            default_codec_level = try std.fmt.parseInt(i16, value, 0);
        } else if (std.mem.eql(u8, key, "default_diff_strategy")) {
            default_diff_strategy = try parseDiffStrategy(value);
        } else if (std.mem.eql(u8, key, "shards")) {
            shards = try std.fmt.parseUnsigned(u32, value, 0);
            if (shards == 0) return error.InvalidArgument;
        } else if (std.mem.eql(u8, key, "file")) {
            try files.append(allocator, try parseFileConfig(allocator, value));
        } else {
            return error.InvalidArgument;
        }
    }
    if (pack_path == null or files.items.len == 0 or default_page_size == 0) return error.InvalidArgument;
    return .{
        .pack_path = pack_path.?,
        .pack_id = pack_id,
        .pack_version = pack_version,
        .pack_name = pack_name,
        .default_page_size = default_page_size,
        .default_codec = default_codec,
        .default_codec_level = default_codec_level,
        .default_diff_strategy = default_diff_strategy,
        .shards = shards,
        .files = try files.toOwnedSlice(allocator),
        .raw_hash = hash.contentHash(bytes),
    };
}

fn parseFileConfig(allocator: std.mem.Allocator, value: []const u8) !FileConfig {
    var parts = std.mem.splitScalar(u8, value, '|');
    const virtual_path = parts.next() orelse return error.InvalidArgument;
    const file_entry_s = parts.next() orelse return error.InvalidArgument;
    const source_path = parts.next() orelse return error.InvalidArgument;
    const page_size_s = parts.next();
    const codec_s = parts.next();
    const level_s = parts.next();
    const strategy_s = parts.next();
    if (parts.next() != null) return error.InvalidArgument;
    const vp = try allocator.dupe(u8, virtual_path);
    errdefer allocator.free(vp);
    const sp = try allocator.dupe(u8, source_path);
    errdefer allocator.free(sp);
    return .{
        .virtual_path = vp,
        .file_entry = try std.fmt.parseUnsigned(u64, file_entry_s, 0),
        .source_path = sp,
        .page_size = if (page_size_s) |s| if (s.len == 0) null else try std.fmt.parseUnsigned(u32, s, 0) else null,
        .codec = if (codec_s) |s| if (s.len == 0) null else try parseCodec(s) else null,
        .codec_level = if (level_s) |s| if (s.len == 0) null else try std.fmt.parseInt(i16, s, 0) else null,
        .diff_strategy = if (strategy_s) |s| if (s.len == 0) null else try parseDiffStrategy(s) else null,
    };
}

pub fn parseCodec(value: []const u8) !file_manifest.Codec {
    if (std.mem.eql(u8, value, "none")) return .none;
    if (std.mem.eql(u8, value, "lz4")) return .lz4;
    if (std.mem.eql(u8, value, "zstd")) return .zstd;
    return error.InvalidArgument;
}

pub fn parseDiffStrategy(value: []const u8) !DiffStrategy {
    if (std.mem.eql(u8, value, "auto")) return .auto;
    if (std.mem.eql(u8, value, "logical")) return .logical;
    if (std.mem.eql(u8, value, "page")) return .page;
    if (std.mem.eql(u8, value, "replace")) return .replace;
    return error.InvalidArgument;
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

test "build cfg parses minimal text format" {
    const allocator = std.testing.allocator;
    var cfg = try parseBytes(allocator,
        \\pack_path=zig-cache-vfs-cfg-pack
        \\pack_id=9
        \\pack_name=test
        \\default_page_size=4096
        \\default_codec=none
        \\file=/a.txt|10|a.txt
        \\file=/b.txt|11|b.txt|1024|none|0
    );
    defer cfg.deinit(allocator);
    try std.testing.expectEqual(@as(u64, 9), cfg.pack_id);
    try std.testing.expectEqual(@as(usize, 2), cfg.files.len);
    try std.testing.expectEqual(@as(?u32, 1024), cfg.files[1].page_size);
}
