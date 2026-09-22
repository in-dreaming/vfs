//! Per-block diff strategy decision (docs/vfs/diff_patch.md §5.3).
const std = @import("std");
const file_manifest_fmt = @import("../format/file_manifest.zig");
const diff_pack = @import("../format/diff_pack.zig");
const build_cfg = @import("../build/build_cfg.zig");
const registry = @import("../compress/registry.zig");

pub const Strategy = diff_pack.Strategy;

/// Defaults follow docs/vfs/diff_patch.md §5.3 (`min_diff_bytes` 4 KiB,
/// `replace_ratio` 0.9, `max_diff_input_bytes` 64 MiB).
pub const StrategyOptions = struct {
    /// Blocks smaller than this are replaced outright: a diff cannot beat
    /// the descriptor overhead.
    min_block_bytes_for_diff: u64 = 4096,
    /// Above this raw size a logical diff would need too much memory at
    /// patch time (old + new raw resident); fall back to page-level.
    max_logical_block_bytes: u64 = 64 << 20,
    /// A computed delta whose size exceeds this fraction (per mille) of the
    /// replacement payload is discarded in favour of replace.
    max_delta_permille: u32 = 900,
};

pub const Decision = struct {
    strategy: Strategy,
    flags: u32 = 0,
};

/// `old_block == null` means the block (or the whole file) is new.
pub fn decide(old_block: ?file_manifest_fmt.BlockDesc, new_block: file_manifest_fmt.BlockDesc, override: build_cfg.DiffStrategy, options: StrategyOptions) Decision {
    if (old_block == null) return .{ .strategy = .replace, .flags = diff_pack.UNIT_FLAG_NEW_BLOCK };
    const caps = registry.caps(new_block.codec);
    switch (override) {
        .replace => return .{ .strategy = .replace, .flags = diff_pack.UNIT_FLAG_CFG_OVERRIDE },
        .page => return .{ .strategy = .page, .flags = diff_pack.UNIT_FLAG_CFG_OVERRIDE },
        .logical => {
            if (caps.runtime_compress and caps.runtime_decompress and registry.caps(old_block.?.codec).runtime_decompress) {
                return .{ .strategy = .logical, .flags = diff_pack.UNIT_FLAG_CFG_OVERRIDE };
            }
            return .{ .strategy = .page, .flags = diff_pack.UNIT_FLAG_CFG_OVERRIDE | diff_pack.UNIT_FLAG_DOWNGRADED_LAYOUT };
        },
        .auto => {},
    }
    if (new_block.raw_size < options.min_block_bytes_for_diff) return .{ .strategy = .replace };
    const old_caps = registry.caps(old_block.?.codec);
    if (caps.runtime_compress and caps.runtime_decompress and caps.deterministic and old_caps.runtime_decompress) {
        if (new_block.raw_size <= options.max_logical_block_bytes) return .{ .strategy = .logical };
        return .{ .strategy = .page, .flags = diff_pack.UNIT_FLAG_DOWNGRADED_LAYOUT };
    }
    return .{ .strategy = .page };
}

/// Ratio check after the delta was actually computed.
pub fn deltaWorthIt(delta_len: usize, replace_len: usize, options: StrategyOptions) bool {
    if (replace_len == 0) return false;
    return @as(u64, delta_len) * 1000 <= @as(u64, replace_len) * options.max_delta_permille;
}

test "strategy auto rules and overrides" {
    const big: file_manifest_fmt.BlockDesc = .{ .raw_offset = 0, .raw_size = 1 << 20, .page_size = 65536, .page_count = 16, .codec = .lz4 };
    const big_none = blk: {
        var b = big;
        b.codec = .none;
        break :blk b;
    };
    const big_zstd = blk: {
        var b = big;
        b.codec = .zstd;
        break :blk b;
    };
    const tiny: file_manifest_fmt.BlockDesc = .{ .raw_offset = 0, .raw_size = 100, .page_size = 65536, .page_count = 1, .codec = .lz4 };
    try std.testing.expectEqual(Strategy.replace, decide(null, big, .auto, .{}).strategy);
    try std.testing.expectEqual(diff_pack.UNIT_FLAG_NEW_BLOCK, decide(null, big, .auto, .{}).flags);
    try std.testing.expectEqual(Strategy.logical, decide(big, big, .auto, .{}).strategy);
    try std.testing.expectEqual(Strategy.logical, decide(big_none, big_none, .auto, .{}).strategy);
    try std.testing.expectEqual(Strategy.page, decide(big_zstd, big_zstd, .auto, .{}).strategy);
    // old is zstd (cannot decompress at runtime) -> logical impossible even if new is lz4
    try std.testing.expectEqual(Strategy.page, decide(big_zstd, big, .auto, .{}).strategy);
    try std.testing.expectEqual(Strategy.replace, decide(tiny, tiny, .auto, .{}).strategy);
    try std.testing.expectEqual(Strategy.page, decide(big, big, .auto, .{ .max_logical_block_bytes = 1 }).strategy);
    try std.testing.expectEqual(Strategy.replace, decide(big, big, .replace, .{}).strategy);
    try std.testing.expectEqual(Strategy.page, decide(big, big, .page, .{}).strategy);
    const forced = decide(big_zstd, big_zstd, .logical, .{});
    try std.testing.expectEqual(Strategy.page, forced.strategy);
    try std.testing.expect(forced.flags & diff_pack.UNIT_FLAG_DOWNGRADED_LAYOUT != 0);
    try std.testing.expect(deltaWorthIt(100, 1000, .{}));
    try std.testing.expect(deltaWorthIt(900, 1000, .{})); // exactly replace_ratio: still a delta
    try std.testing.expect(!deltaWorthIt(901, 1000, .{}));
    try std.testing.expect(!deltaWorthIt(1, 0, .{}));
}
