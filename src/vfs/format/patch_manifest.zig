const std = @import("std");
const fmt = @import("common.zig");
const hash = @import("../hash.zig");

pub const MAGIC: u32 = fmt.magic32("VPCH");
pub const VERSION: u16 = 1;
pub const HEADER_SIZE: usize = 64;
pub const FILE_DESC_SIZE: usize = 112;
const CRC_OFFSET: usize = 60;

pub const PatchOp = enum(u16) {
    add_file = 1,
    modify_file = 2,
    delete_file = 3,
    _,
};

pub const FilePatchInput = struct {
    file_entry: u64,
    virtual_path: ?[]const u8 = null,
    op: PatchOp,
    old_file_size: u64 = 0,
    new_file_size: u64 = 0,
    old_content_hash: [32]u8 = [_]u8{0} ** 32,
    new_content_hash: [32]u8 = [_]u8{0} ** 32,
    payload: []const u8 = &.{},
};

pub const PatchInput = struct {
    target_pack_id: u64,
    base_pack_version: u64,
    patch_version: u64,
    files: []const FilePatchInput,
};

pub const FilePatch = struct {
    file_entry: u64,
    virtual_path: ?[]u8,
    op: PatchOp,
    old_file_size: u64,
    new_file_size: u64,
    old_content_hash: [32]u8,
    new_content_hash: [32]u8,
    payload: []u8,
};

pub const DecodedPatchManifest = struct {
    target_pack_id: u64,
    base_pack_version: u64,
    patch_version: u64,
    files: []FilePatch,

    pub fn deinit(self: *DecodedPatchManifest, allocator: std.mem.Allocator) void {
        for (self.files) |file| {
            if (file.virtual_path) |p| allocator.free(p);
            allocator.free(file.payload);
        }
        allocator.free(self.files);
        self.* = undefined;
    }
};

pub fn encode(allocator: std.mem.Allocator, input: PatchInput) ![]u8 {
    if (input.files.len > std.math.maxInt(u32)) return error.InvalidArgument;
    var string_size: usize = 0;
    var payload_size: usize = 0;
    for (input.files) |file| {
        if (file.file_entry == 0) return error.InvalidArgument;
        if (file.virtual_path) |path| string_size += path.len;
        if (file.op != .delete_file and file.payload.len != file.new_file_size) return error.InvalidArgument;
        if (file.op != .delete_file and !std.mem.eql(u8, &hash.contentHash(file.payload), &file.new_content_hash)) return error.ChecksumMismatch;
        payload_size += file.payload.len;
    }
    const desc_off = HEADER_SIZE;
    const strings_off = desc_off + input.files.len * FILE_DESC_SIZE;
    const payload_off = strings_off + string_size;
    const total = payload_off + payload_size;
    var out = try allocator.alloc(u8, total);
    errdefer allocator.free(out);
    @memset(out, 0);
    fmt.putU32(out, 0, MAGIC);
    fmt.putU16(out, 4, VERSION);
    fmt.putU16(out, 6, HEADER_SIZE);
    fmt.putU64(out, 8, input.target_pack_id);
    fmt.putU64(out, 16, input.base_pack_version);
    fmt.putU64(out, 24, input.patch_version);
    fmt.putU32(out, 32, @intCast(input.files.len));
    fmt.putU32(out, 36, @intCast(desc_off));
    fmt.putU32(out, 40, @intCast(strings_off));
    fmt.putU32(out, 44, @intCast(string_size));
    fmt.putU32(out, 48, @intCast(payload_off));
    fmt.putU32(out, 52, @intCast(payload_size));
    fmt.putU32(out, CRC_OFFSET, 0);

    var string_cursor: u32 = 0;
    var payload_cursor: u32 = 0;
    for (input.files, 0..) |file, i| {
        const off = desc_off + i * FILE_DESC_SIZE;
        fmt.putU64(out, off + 0, file.file_entry);
        fmt.putU16(out, off + 8, @intFromEnum(file.op));
        fmt.putU64(out, off + 16, file.old_file_size);
        fmt.putU64(out, off + 24, file.new_file_size);
        @memcpy(out[off + 32 .. off + 64][0..32], &file.old_content_hash);
        @memcpy(out[off + 64 .. off + 96][0..32], &file.new_content_hash);
        if (file.virtual_path) |path| {
            fmt.putU32(out, off + 96, string_cursor);
            fmt.putU32(out, off + 100, @intCast(path.len));
            @memcpy(out[strings_off + string_cursor ..][0..path.len], path);
            string_cursor += @intCast(path.len);
        } else {
            fmt.putU32(out, off + 96, 0);
            fmt.putU32(out, off + 100, 0);
        }
        fmt.putU32(out, off + 104, payload_cursor);
        fmt.putU32(out, off + 108, @intCast(file.payload.len));
        @memcpy(out[payload_off + payload_cursor ..][0..file.payload.len], file.payload);
        payload_cursor += @intCast(file.payload.len);
    }
    fmt.putU32(out, CRC_OFFSET, fmt.crc32cWithZeroU32(out, CRC_OFFSET));
    return out;
}

pub fn decode(allocator: std.mem.Allocator, bytes: []const u8) !DecodedPatchManifest {
    if (bytes.len < HEADER_SIZE) return error.Corruption;
    if (fmt.getU32(bytes, 0) != MAGIC) return error.Corruption;
    if (fmt.getU16(bytes, 4) != VERSION) return error.UnsupportedVersion;
    if (fmt.getU16(bytes, 6) != HEADER_SIZE) return error.Corruption;
    try fmt.requireZero(bytes[56..60]);
    const crc = fmt.getU32(bytes, CRC_OFFSET);
    if (fmt.crc32cWithZeroU32(bytes, CRC_OFFSET) != crc) return error.Corruption;
    const file_count = fmt.getU32(bytes, 32);
    const desc_off = fmt.getU32(bytes, 36);
    const strings_off = fmt.getU32(bytes, 40);
    const string_size = fmt.getU32(bytes, 44);
    const payload_off = fmt.getU32(bytes, 48);
    const payload_size = fmt.getU32(bytes, 52);
    if (desc_off != HEADER_SIZE) return error.Corruption;
    if (strings_off != desc_off + @as(usize, file_count) * FILE_DESC_SIZE) return error.Corruption;
    if (payload_off != strings_off + string_size) return error.Corruption;
    if (bytes.len != payload_off + payload_size) return error.Corruption;
    var files = try allocator.alloc(FilePatch, file_count);
    errdefer {
        for (files[0..]) |file| {
            if (file.virtual_path) |p| allocator.free(p);
            allocator.free(file.payload);
        }
        allocator.free(files);
    }
    for (files, 0..) |*file, i| {
        file.* = undefined;
        const off = desc_off + i * FILE_DESC_SIZE;
        const file_entry = fmt.getU64(bytes, off);
        if (file_entry == 0) return error.Corruption;
        try fmt.requireZero(bytes[off + 10 .. off + 16]);
        const path_off = fmt.getU32(bytes, off + 96);
        const path_size = fmt.getU32(bytes, off + 100);
        const pay_off = fmt.getU32(bytes, off + 104);
        const pay_size = fmt.getU32(bytes, off + 108);
        if (@as(usize, path_off) + path_size > string_size) return error.Corruption;
        if (@as(usize, pay_off) + pay_size > payload_size) return error.Corruption;
        var old_hash: [32]u8 = undefined;
        var new_hash: [32]u8 = undefined;
        @memcpy(&old_hash, bytes[off + 32 .. off + 64][0..32]);
        @memcpy(&new_hash, bytes[off + 64 .. off + 96][0..32]);
        const payload = try allocator.dupe(u8, bytes[payload_off + pay_off ..][0..pay_size]);
        errdefer allocator.free(payload);
        const op: PatchOp = @enumFromInt(fmt.getU16(bytes, off + 8));
        if (op != .delete_file and !std.mem.eql(u8, &hash.contentHash(payload), &new_hash)) return error.ChecksumMismatch;
        file.* = .{
            .file_entry = file_entry,
            .virtual_path = if (path_size == 0) null else try allocator.dupe(u8, bytes[strings_off + path_off ..][0..path_size]),
            .op = op,
            .old_file_size = fmt.getU64(bytes, off + 16),
            .new_file_size = fmt.getU64(bytes, off + 24),
            .old_content_hash = old_hash,
            .new_content_hash = new_hash,
            .payload = payload,
        };
    }
    return .{
        .target_pack_id = fmt.getU64(bytes, 8),
        .base_pack_version = fmt.getU64(bytes, 16),
        .patch_version = fmt.getU64(bytes, 24),
        .files = files,
    };
}

test "patch manifest encodes decodes and validates payload hash" {
    const allocator = std.testing.allocator;
    const payload = "patch-data";
    const h = hash.contentHash(payload);
    const encoded = try encode(allocator, .{ .target_pack_id = 1, .base_pack_version = 2, .patch_version = 3, .files = &.{.{ .file_entry = 1, .virtual_path = "/a.txt", .op = .add_file, .new_file_size = payload.len, .new_content_hash = h, .payload = payload }} });
    defer allocator.free(encoded);
    var decoded = try decode(allocator, encoded);
    defer decoded.deinit(allocator);
    try std.testing.expectEqual(@as(u64, 3), decoded.patch_version);
    try std.testing.expectEqualSlices(u8, payload, decoded.files[0].payload);
    var bad = try allocator.dupe(u8, encoded);
    defer allocator.free(bad);
    bad[bad.len - 1] ^= 0xff;
    try std.testing.expectError(error.Corruption, decode(allocator, bad));
}
