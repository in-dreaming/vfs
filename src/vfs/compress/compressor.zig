const std = @import("std");
const file_manifest = @import("../format/file_manifest.zig");

pub const CodecIdentity = struct {
    codec: file_manifest.Codec,
    version_hash: u64,
};

pub const DecompressFn = *const fn (allocator: std.mem.Allocator, stored: []const u8, raw_size: u32, raw_crc: u32) anyerror![]u8;

pub const Compressor = struct {
    codec: file_manifest.Codec,
    version_hash: u64,
    decompress_page: DecompressFn,
};

test "compressor identity is explicit" {
    const id: CodecIdentity = .{ .codec = .none, .version_hash = 1 };
    try std.testing.expectEqual(file_manifest.Codec.none, id.codec);
}
