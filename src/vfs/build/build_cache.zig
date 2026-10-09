const std = @import("std");
const db_internal = @import("db_internal");
const pf = db_internal.platform.file;
const build_plan = @import("build_plan.zig");

pub const Entry = struct {
    file_entry: u64,
    virtual_path: []u8,
    source_path: []u8,
    source_size: u64,
    source_mtime: i128,
    source_hash: [32]u8,
    build_cfg_hash: [32]u8,
    compressor_version_hash: u64,
    output_manifest_hash: [32]u8,
    page_size: u32,
    codec: u16,
    codec_level: i16,
};

pub const BuildCache = struct {
    entries: []Entry,

    pub fn deinit(self: *BuildCache, allocator: std.mem.Allocator) void {
        for (self.entries) |entry| {
            allocator.free(entry.virtual_path);
            allocator.free(entry.source_path);
        }
        allocator.free(self.entries);
        self.* = undefined;
    }

    pub fn findByFileEntry(self: BuildCache, file_entry: u64) ?Entry {
        for (self.entries) |entry| if (entry.file_entry == file_entry) return entry;
        return null;
    }

    pub fn findBySource(self: BuildCache, source_path: []const u8) ?Entry {
        for (self.entries) |entry| if (std.mem.eql(u8, entry.source_path, source_path)) return entry;
        return null;
    }
};

pub fn cachePath(allocator: std.mem.Allocator, pack_path: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "{s}.vfs_build_cache", .{pack_path});
}

pub fn load(allocator: std.mem.Allocator, pack_path: []const u8) !BuildCache {
    const path = try cachePath(allocator, pack_path);
    defer allocator.free(path);
    const bytes = try readFileAlloc(allocator, path);
    defer allocator.free(bytes);
    return parse(allocator, bytes);
}

pub fn parse(allocator: std.mem.Allocator, bytes: []const u8) !BuildCache {
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    const header = lines.next() orelse return error.Corruption;
    if (!std.mem.eql(u8, std.mem.trim(u8, header, " \r\t"), "VFS_BUILD_CACHE_V1")) return error.Corruption;
    var entries = std.ArrayList(Entry).empty;
    errdefer {
        for (entries.items) |entry| {
            allocator.free(entry.virtual_path);
            allocator.free(entry.source_path);
        }
        entries.deinit(allocator);
    }
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \r\t");
        if (line.len == 0) continue;
        if (!std.mem.startsWith(u8, line, "entry=")) return error.Corruption;
        try entries.append(allocator, try parseEntry(allocator, line["entry=".len..]));
    }
    return .{ .entries = try entries.toOwnedSlice(allocator) };
}

fn parseEntry(allocator: std.mem.Allocator, value: []const u8) !Entry {
    var parts = std.mem.splitScalar(u8, value, '|');
    const file_entry = try std.fmt.parseUnsigned(u64, parts.next() orelse return error.Corruption, 0);
    const virtual_path = parts.next() orelse return error.Corruption;
    const source_path = parts.next() orelse return error.Corruption;
    const source_size = try std.fmt.parseUnsigned(u64, parts.next() orelse return error.Corruption, 0);
    const source_mtime = try std.fmt.parseInt(i128, parts.next() orelse return error.Corruption, 0);
    const source_hash = try parseHex32(parts.next() orelse return error.Corruption);
    const build_cfg_hash = try parseHex32(parts.next() orelse return error.Corruption);
    const compressor_version_hash = try std.fmt.parseUnsigned(u64, parts.next() orelse return error.Corruption, 16);
    const output_manifest_hash = try parseHex32(parts.next() orelse return error.Corruption);
    const page_size = try std.fmt.parseUnsigned(u32, parts.next() orelse return error.Corruption, 0);
    const codec = try std.fmt.parseUnsigned(u16, parts.next() orelse return error.Corruption, 0);
    const codec_level = try std.fmt.parseInt(i16, parts.next() orelse return error.Corruption, 0);
    if (parts.next() != null) return error.Corruption;
    return .{
        .file_entry = file_entry,
        .virtual_path = try allocator.dupe(u8, virtual_path),
        .source_path = try allocator.dupe(u8, source_path),
        .source_size = source_size,
        .source_mtime = source_mtime,
        .source_hash = source_hash,
        .build_cfg_hash = build_cfg_hash,
        .compressor_version_hash = compressor_version_hash,
        .output_manifest_hash = output_manifest_hash,
        .page_size = page_size,
        .codec = codec,
        .codec_level = codec_level,
    };
}

pub fn write(allocator: std.mem.Allocator, pack_path: []const u8, entries: []const Entry) !void {
    const path = try cachePath(allocator, pack_path);
    defer allocator.free(path);
    var bytes = std.ArrayList(u8).empty;
    defer bytes.deinit(allocator);
    try bytes.appendSlice(allocator, "VFS_BUILD_CACHE_V1\n");
    for (entries) |entry| {
        var source_hash_hex: [64]u8 = undefined;
        var cfg_hash_hex: [64]u8 = undefined;
        var manifest_hash_hex: [64]u8 = undefined;
        hex32(&source_hash_hex, entry.source_hash);
        hex32(&cfg_hash_hex, entry.build_cfg_hash);
        hex32(&manifest_hash_hex, entry.output_manifest_hash);
        const line = try std.fmt.allocPrint(allocator, "entry={d}|{s}|{s}|{d}|{d}|{s}|{s}|{x}|{s}|{d}|{d}|{d}\n", .{
            entry.file_entry,
            entry.virtual_path,
            entry.source_path,
            entry.source_size,
            entry.source_mtime,
            &source_hash_hex,
            &cfg_hash_hex,
            entry.compressor_version_hash,
            &manifest_hash_hex,
            entry.page_size,
            entry.codec,
            entry.codec_level,
        });
        defer allocator.free(line);
        try bytes.appendSlice(allocator, line);
    }
    try writeFile(path, bytes.items);
}

pub fn matchesPlan(entry: Entry, plan: build_plan.PlanFile) bool {
    return entry.file_entry == plan.file_entry and
        std.mem.eql(u8, entry.virtual_path, plan.virtual_path) and
        std.mem.eql(u8, entry.source_path, plan.source_path) and
        entry.source_size == plan.source_size and
        entry.source_mtime == plan.source_mtime and
        std.mem.eql(u8, &entry.source_hash, &plan.source_hash) and
        std.mem.eql(u8, &entry.build_cfg_hash, &plan.build_cfg_hash) and
        entry.compressor_version_hash == plan.compressor_version_hash and
        entry.page_size == plan.page_size and
        entry.codec == @intFromEnum(plan.codec) and
        entry.codec_level == plan.codec_level;
}

pub fn entryFromPlan(allocator: std.mem.Allocator, plan: build_plan.PlanFile, output_manifest_hash: [32]u8) !Entry {
    return .{
        .file_entry = plan.file_entry,
        .virtual_path = try allocator.dupe(u8, plan.virtual_path),
        .source_path = try allocator.dupe(u8, plan.source_path),
        .source_size = plan.source_size,
        .source_mtime = plan.source_mtime,
        .source_hash = plan.source_hash,
        .build_cfg_hash = plan.build_cfg_hash,
        .compressor_version_hash = plan.compressor_version_hash,
        .output_manifest_hash = output_manifest_hash,
        .page_size = plan.page_size,
        .codec = @intFromEnum(plan.codec),
        .codec_level = plan.codec_level,
    };
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

fn writeFile(path: []const u8, data: []const u8) !void {
    var f = try pf.open(path, .{ .mode = .create_read_write, .create_parent_dirs = true });
    defer pf.close(&f);
    try pf.setLen(f, 0);
    try pf.pwriteAll(f, 0, data);
    try pf.flushMetadata(f);
}

fn hex32(out: *[64]u8, bytes: [32]u8) void {
    const alphabet = "0123456789abcdef";
    for (bytes, 0..) |b, i| {
        out[i * 2] = alphabet[b >> 4];
        out[i * 2 + 1] = alphabet[b & 0xf];
    }
}

fn parseHex32(s: []const u8) ![32]u8 {
    if (s.len != 64) return error.Corruption;
    var out: [32]u8 = undefined;
    for (&out, 0..) |*b, i| {
        b.* = (try hexNibble(s[i * 2]) << 4) | try hexNibble(s[i * 2 + 1]);
    }
    return out;
}

fn hexNibble(c: u8) !u8 {
    return switch (c) {
        '0'...'9' => c - '0',
        'a'...'f' => c - 'a' + 10,
        'A'...'F' => c - 'A' + 10,
        else => error.Corruption,
    };
}

test "build cache damaged input returns corruption" {
    try std.testing.expectError(error.Corruption, parse(std.testing.allocator, "bad"));
}
