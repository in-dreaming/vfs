const std = @import("std");
const file_manifest = @import("../format/file_manifest.zig");
const compressor = @import("compressor.zig");
const none = @import("none.zig");

pub const NONE_VERSION_HASH: u64 = 0x6e6f6e652d76312d; // "none-v1-" LE-ish diagnostic constant

pub fn codecIdentity(codec: file_manifest.Codec) !compressor.CodecIdentity {
    return switch (codec) {
        .none => .{ .codec = .none, .version_hash = NONE_VERSION_HASH },
        else => error.UnsupportedFeature,
    };
}

pub fn decompressPage(allocator: std.mem.Allocator, codec: file_manifest.Codec, stored: []const u8, raw_size: u32, raw_crc: u32) ![]u8 {
    return switch (codec) {
        .none => none.decompressPage(allocator, stored, raw_size, raw_crc),
        else => error.UnsupportedFeature,
    };
}

test "registry supports none and rejects lz4 zstd" {
    const id = try codecIdentity(.none);
    try std.testing.expectEqual(file_manifest.Codec.none, id.codec);
    try std.testing.expectError(error.UnsupportedFeature, codecIdentity(.lz4));
    try std.testing.expectError(error.UnsupportedFeature, codecIdentity(.zstd));
}
