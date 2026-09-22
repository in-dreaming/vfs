//! Test-only helpers: build packs from in-memory file specs and generate
//! versioned datasets exercising every diff path.
const std = @import("std");
const pack_builder = @import("../build/pack_builder.zig");
const file_manifest_fmt = @import("../format/file_manifest.zig");

pub const FileSpec = struct {
    path: []const u8,
    file_entry: u64,
    data: []const u8,
    page_size: u32 = 4096,
    codec: file_manifest_fmt.Codec = .none,
    level: i16 = 0,
};

pub fn cleanup(path: []const u8) void {
    const io = std.Io.Threaded.global_single_threaded.io();
    _ = std.Io.Dir.cwd().deleteTree(io, path) catch {};
}

pub fn buildPack(allocator: std.mem.Allocator, scratch_prefix: []const u8, pack_path: []const u8, files: []const FileSpec, pack_id: u64, pack_version: u64, shards: u32) !void {
    cleanup(pack_path);
    var inputs = std.ArrayList(pack_builder.BuildFileInput).empty;
    defer inputs.deinit(allocator);
    var names = std.ArrayList([]u8).empty;
    defer {
        const io = std.Io.Threaded.global_single_threaded.io();
        for (names.items) |n| {
            _ = std.Io.Dir.cwd().deleteFile(io, n) catch {};
            allocator.free(n);
        }
        names.deinit(allocator);
    }
    for (files, 0..) |f, i| {
        const name = try std.fmt.allocPrint(allocator, "{s}-src-{d}.bin", .{ scratch_prefix, i });
        try names.append(allocator, name);
        try pack_builder.writeSourceFileForTest(name, f.data);
        try inputs.append(allocator, .{ .source_path = name, .virtual_path = f.path, .file_entry = f.file_entry, .page_size = f.page_size, .codec = f.codec, .codec_level = f.level });
    }
    try pack_builder.createPack(pack_path, inputs.items, .{ .pack_id = pack_id, .pack_version = pack_version, .build_id = pack_version, .shards = shards });
}

/// Three versions of a small dataset:
///   v1: A(lz4, 3 pages), B(none, 2 pages), C(lz4, 1 page), D(none, 1 page), E(none, 0 bytes)
///   v2: A page 1 edited (logical), B grows to 3 pages (page_size 4096, none -> logical),
///       C deleted, D unchanged, E gets content, F added (lz4)
///   v3: A shrinks to 2 pages, B page 0 edited, F edited, D edited (small -> replace), G added (none, 5 pages)
pub const Dataset = struct {
    allocator: std.mem.Allocator,
    bufs: std.ArrayList([]u8) = .empty,
    v1: []FileSpec = &.{},
    v2: []FileSpec = &.{},
    v3: []FileSpec = &.{},

    pub fn deinit(self: *Dataset) void {
        for (self.bufs.items) |b| self.allocator.free(b);
        self.bufs.deinit(self.allocator);
        self.allocator.free(self.v1);
        self.allocator.free(self.v2);
        self.allocator.free(self.v3);
        self.* = undefined;
    }

    fn pattern(self: *Dataset, len: usize, seed: u64, period: usize) ![]u8 {
        const b = try self.allocator.alloc(u8, len);
        for (b, 0..) |*x, i| x.* = @intCast(((i / period) * 7 + seed * 13 + (i % 5)) % 251);
        try self.bufs.append(self.allocator, b);
        return b;
    }

    fn edited(self: *Dataset, src: []const u8, at: usize, len: usize) ![]u8 {
        const b = try self.allocator.dupe(u8, src);
        var i: usize = 0;
        while (i < len and at + i < b.len) : (i += 1) b[at + i] = b[at + i] ^ 0x5a;
        try self.bufs.append(self.allocator, b);
        return b;
    }

    fn concat(self: *Dataset, a: []const u8, b: []const u8) ![]u8 {
        const out = try self.allocator.alloc(u8, a.len + b.len);
        @memcpy(out[0..a.len], a);
        @memcpy(out[a.len..], b);
        try self.bufs.append(self.allocator, out);
        return out;
    }
};

pub fn dataset(allocator: std.mem.Allocator) !Dataset {
    var d = Dataset{ .allocator = allocator };
    errdefer d.deinit();
    const a1 = try d.pattern(3 * 4096 - 100, 1, 16);
    const b1 = try d.pattern(2 * 4096, 2, 9);
    const c1 = try d.pattern(1000, 3, 3);
    const d1 = try d.pattern(600, 4, 1);
    const e1: []u8 = &.{};

    const a2 = try d.edited(a1, 4096 + 500, 300);
    const b2 = try d.concat(b1, try d.pattern(3000, 22, 11));
    const e2 = try d.pattern(5000, 5, 7);
    const f2 = try d.pattern(2 * 4096 + 10, 6, 13);

    const a3 = a2[0 .. 2 * 4096 - 50];
    const b3 = try d.edited(b2, 100, 64);
    const f3 = try d.edited(f2, 4096 + 1, 2000);
    const d3 = try d.edited(d1, 10, 5);
    const g3 = try d.pattern(5 * 4096, 9, 31);

    d.v1 = try allocator.dupe(FileSpec, &.{
        .{ .path = "/a.bin", .file_entry = 101, .data = a1, .codec = .lz4, .level = 4 },
        .{ .path = "/b.bin", .file_entry = 102, .data = b1 },
        .{ .path = "/c.bin", .file_entry = 103, .data = c1, .codec = .lz4 },
        .{ .path = "/d.bin", .file_entry = 104, .data = d1 },
        .{ .path = "/e.bin", .file_entry = 105, .data = e1 },
    });
    d.v2 = try allocator.dupe(FileSpec, &.{
        .{ .path = "/a.bin", .file_entry = 101, .data = a2, .codec = .lz4, .level = 4 },
        .{ .path = "/b.bin", .file_entry = 102, .data = b2 },
        .{ .path = "/d.bin", .file_entry = 104, .data = d1 },
        .{ .path = "/e.bin", .file_entry = 105, .data = e2 },
        .{ .path = "/sub/f.bin", .file_entry = 106, .data = f2, .codec = .lz4, .level = 2 },
    });
    d.v3 = try allocator.dupe(FileSpec, &.{
        .{ .path = "/a.bin", .file_entry = 101, .data = a3, .codec = .lz4, .level = 4 },
        .{ .path = "/b.bin", .file_entry = 102, .data = b3 },
        .{ .path = "/d.bin", .file_entry = 104, .data = d3 },
        .{ .path = "/e.bin", .file_entry = 105, .data = e2 },
        .{ .path = "/sub/f.bin", .file_entry = 106, .data = f3, .codec = .lz4, .level = 2 },
        .{ .path = "/g.bin", .file_entry = 107, .data = g3 },
    });
    return d;
}
