const std = @import("std");
const file_manifest = @import("../format/file_manifest.zig");
const compressor = @import("compressor.zig");
const none = @import("none.zig");
const lz4 = @import("lz4.zig");

pub const NONE_VERSION_HASH: u64 = 0x6e6f6e652d76312d; // "none-v1-" LE-ish diagnostic constant
pub const ZSTD_PLACEHOLDER_VERSION_HASH: u64 = 0x7a7374642d6e2f61; // "zstd-n/a"

/// What the runtime can do with a codec. Drives the diff strategy decision
/// (docs/vfs/diff_patch.md §5.3).
pub const CodecCaps = struct {
    codec: file_manifest.Codec,
    /// Client can re-compress at patch time (logical-block diff is viable).
    runtime_compress: bool,
    /// Client can decompress (required to read pages at all).
    runtime_decompress: bool,
    /// Same input + level -> identical bytes on every host.
    deterministic: bool,
    version_hash: u64,
};

pub fn caps(codec: file_manifest.Codec) CodecCaps {
    return switch (codec) {
        .none => .{ .codec = .none, .runtime_compress = true, .runtime_decompress = true, .deterministic = true, .version_hash = NONE_VERSION_HASH },
        .lz4 => .{ .codec = .lz4, .runtime_compress = true, .runtime_decompress = true, .deterministic = true, .version_hash = lz4.VERSION_HASH },
        // zstd is not implemented in this runtime: it stands in for "cannot
        // compress at runtime" codecs (oodle etc.) in the strategy table.
        .zstd => .{ .codec = .zstd, .runtime_compress = false, .runtime_decompress = false, .deterministic = false, .version_hash = ZSTD_PLACEHOLDER_VERSION_HASH },
        _ => .{ .codec = codec, .runtime_compress = false, .runtime_decompress = false, .deterministic = false, .version_hash = 0 },
    };
}

pub fn codecIdentity(codec: file_manifest.Codec) !compressor.CodecIdentity {
    const c = caps(codec);
    if (!c.runtime_decompress) return error.UnsupportedFeature;
    return .{ .codec = codec, .version_hash = c.version_hash };
}

pub fn decompressPage(allocator: std.mem.Allocator, codec: file_manifest.Codec, stored: []const u8, raw_size: u32, raw_crc: u32) ![]u8 {
    return switch (codec) {
        .none => none.decompressPage(allocator, stored, raw_size, raw_crc),
        .lz4 => lz4.decompressPage(allocator, stored, raw_size, raw_crc),
        else => error.UnsupportedFeature,
    };
}

pub const Compressed = struct {
    /// Codec actually used. `none` when compression did not shrink the page
    /// (store-raw fallback) or the requested codec is `none`.
    codec: file_manifest.Codec,
    bytes: []u8,
};

/// Compresses a raw page. When the compressed output would not be smaller
/// than the input the page is stored raw with `codec = .none` so a reader
/// never pays for a useless decode.
pub fn compressPage(allocator: std.mem.Allocator, codec: file_manifest.Codec, level: i16, raw: []const u8) !Compressed {
    switch (codec) {
        .none => return .{ .codec = .none, .bytes = try allocator.dupe(u8, raw) },
        .lz4 => {
            const out = try lz4.compressPage(allocator, raw, level);
            if (out.len >= raw.len) {
                allocator.free(out);
                return .{ .codec = .none, .bytes = try allocator.dupe(u8, raw) };
            }
            return .{ .codec = .lz4, .bytes = out };
        },
        else => return error.UnsupportedFeature,
    }
}

test "registry supports none and lz4 and rejects zstd" {
    const id = try codecIdentity(.none);
    try std.testing.expectEqual(file_manifest.Codec.none, id.codec);
    const lz = try codecIdentity(.lz4);
    try std.testing.expectEqual(lz4.VERSION_HASH, lz.version_hash);
    try std.testing.expectError(error.UnsupportedFeature, codecIdentity(.zstd));
    try std.testing.expect(caps(.lz4).runtime_compress);
    try std.testing.expect(!caps(.zstd).runtime_compress);
}

test "registry compress page falls back to raw when not smaller" {
    const allocator = std.testing.allocator;
    const random = "q9z!k2@#m8x&v7c*b4n%";
    const c = try compressPage(allocator, .lz4, 4, random);
    defer allocator.free(c.bytes);
    try std.testing.expectEqual(file_manifest.Codec.none, c.codec);
    const text = "abcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabc";
    const d = try compressPage(allocator, .lz4, 4, text);
    defer allocator.free(d.bytes);
    try std.testing.expectEqual(file_manifest.Codec.lz4, d.codec);
    const back = try decompressPage(allocator, .lz4, d.bytes, @intCast(text.len), @import("../format/common.zig").crc32c(text));
    defer allocator.free(back);
    try std.testing.expectEqualSlices(u8, text, back);
}
