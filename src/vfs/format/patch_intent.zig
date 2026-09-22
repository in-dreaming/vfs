//! "VPIN": written to the target pack when a patch run starts and deleted in
//! the same batch that commits the final PackManifest. Its presence on open
//! means "a patch from `from_version` to `to_version` is in progress".
const std = @import("std");
const fmt = @import("common.zig");

pub const MAGIC: u32 = fmt.magic32("VPIN");
pub const VERSION: u16 = 1;
pub const HEADER_SIZE: usize = 48;
pub const MAX_CHAIN: usize = 64;

pub const PatchIntent = struct {
    from_version: u64,
    to_version: u64,
    started_unix_ms: u64,
    tool_version_hash: u64,
    diff_ids: []const u64,
};

pub fn encodedSize(chain_len: usize) usize {
    return HEADER_SIZE + chain_len * 8;
}

pub fn encode(allocator: std.mem.Allocator, input: PatchIntent) ![]u8 {
    if (input.diff_ids.len == 0 or input.diff_ids.len > MAX_CHAIN) return error.InvalidArgument;
    const out = try allocator.alloc(u8, encodedSize(input.diff_ids.len));
    @memset(out, 0);
    fmt.putU32(out, 0, MAGIC);
    fmt.putU16(out, 4, VERSION);
    fmt.putU16(out, 6, HEADER_SIZE);
    fmt.putU64(out, 8, input.from_version);
    fmt.putU64(out, 16, input.to_version);
    fmt.putU64(out, 24, input.started_unix_ms);
    fmt.putU64(out, 32, input.tool_version_hash);
    fmt.putU32(out, 40, @intCast(input.diff_ids.len));
    for (input.diff_ids, 0..) |id, i| fmt.putU64(out, HEADER_SIZE + i * 8, id);
    fmt.putU32(out, 44, fmt.crc32cWithZeroU32(out, 44));
    return out;
}

pub const Decoded = struct {
    intent: PatchIntent,
    ids: []u64,

    pub fn deinit(self: *Decoded, allocator: std.mem.Allocator) void {
        allocator.free(self.ids);
        self.* = undefined;
    }
};

pub fn decode(allocator: std.mem.Allocator, bytes: []const u8) !Decoded {
    if (bytes.len < HEADER_SIZE) return error.Corruption;
    if (fmt.getU32(bytes, 0) != MAGIC) return error.Corruption;
    if (fmt.getU16(bytes, 4) != VERSION) return error.UnsupportedVersion;
    if (fmt.getU16(bytes, 6) != HEADER_SIZE) return error.Corruption;
    const n = fmt.getU32(bytes, 40);
    if (n == 0 or n > MAX_CHAIN or bytes.len != encodedSize(n)) return error.Corruption;
    if (fmt.getU32(bytes, 44) != fmt.crc32cWithZeroU32(bytes, 44)) return error.Corruption;
    const ids = try allocator.alloc(u64, n);
    for (ids, 0..) |*id, i| id.* = fmt.getU64(bytes, HEADER_SIZE + i * 8);
    return .{ .intent = .{
        .from_version = fmt.getU64(bytes, 8),
        .to_version = fmt.getU64(bytes, 16),
        .started_unix_ms = fmt.getU64(bytes, 24),
        .tool_version_hash = fmt.getU64(bytes, 32),
        .diff_ids = ids,
    }, .ids = ids };
}

test "patch intent roundtrip and rejects" {
    const a = std.testing.allocator;
    const enc = try encode(a, .{ .from_version = 1, .to_version = 3, .started_unix_ms = 42, .tool_version_hash = 7, .diff_ids = &.{ 100, 200 } });
    defer a.free(enc);
    var dec = try decode(a, enc);
    defer dec.deinit(a);
    try std.testing.expectEqual(@as(u64, 3), dec.intent.to_version);
    try std.testing.expectEqualSlices(u64, &.{ 100, 200 }, dec.intent.diff_ids);
    try std.testing.expectError(error.InvalidArgument, encode(a, .{ .from_version = 1, .to_version = 3, .started_unix_ms = 0, .tool_version_hash = 0, .diff_ids = &.{} }));
    var i: usize = 0;
    while (i < enc.len) : (i += 1) {
        const bad = try a.dupe(u8, enc);
        defer a.free(bad);
        bad[i] ^= 0x01;
        try std.testing.expect(std.meta.isError(decode(a, bad)));
    }
}
