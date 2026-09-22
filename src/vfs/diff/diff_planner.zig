//! Compares two PackImages and produces the object-level plan: one unit per
//! affected (file, block[, page]) plus file ops and the path delta.
//! Payloads are computed later by diff_engine.
const std = @import("std");
const pack_scan = @import("pack_scan.zig");
const strategy_mod = @import("strategy.zig");
const diff_pack = @import("../format/diff_pack.zig");
const file_manifest_fmt = @import("../format/file_manifest.zig");
const build_cfg = @import("../build/build_cfg.zig");
const object_key = @import("../object_key.zig");
const registry = @import("../compress/registry.zig");

pub const UnitSource = union(enum) {
    /// R: payload = full encoded new page.
    raw_page: *const pack_scan.PageImage,
    /// P: payload = VHDF(old full page bytes -> new full page bytes).
    page_delta: struct { old: *const pack_scan.PageImage, new: *const pack_scan.PageImage },
    /// L: payload = VHDF(old raw block -> new raw block).
    block_delta: struct { old_block: file_manifest_fmt.BlockDesc, new_block: file_manifest_fmt.BlockDesc },
    delete,
};

pub const PlannedUnit = struct {
    desc: diff_pack.UnitDesc,
    source: UnitSource,
    shard_hint: u32,
    /// Size of the replace alternative (sum of new page bytes); used for
    /// the ratio downgrade check.
    replace_bytes: u64,
};

pub const PlannedFileOp = struct {
    op: diff_pack.FileOp,
    payload: []const u8 = &.{},
};

pub const PlanOptions = struct {
    strategy: strategy_mod.StrategyOptions = .{},
    default_override: build_cfg.DiffStrategy = .auto,
    /// Per file_entry override from BuildCfg.
    overrides: ?*const std.AutoHashMapUnmanaged(u64, build_cfg.DiffStrategy) = null,
    /// 0 = target image's shard count.
    shard_hint_count: u32 = 0,
};

pub const Plan = struct {
    allocator: std.mem.Allocator,
    units: std.ArrayList(PlannedUnit) = .empty,
    file_ops: std.ArrayList(PlannedFileOp) = .empty,
    path_adds: std.ArrayList(diff_pack.PathAdd) = .empty,
    path_removes: std.ArrayList(diff_pack.PathRemove) = .empty,
    shard_hint_count: u32 = 1,
    /// Files whose blocks were compared page-by-page and found identical.
    unchanged_files: u32 = 0,

    pub fn deinit(self: *Plan) void {
        self.units.deinit(self.allocator);
        self.file_ops.deinit(self.allocator);
        self.path_adds.deinit(self.allocator);
        self.path_removes.deinit(self.allocator);
        self.* = undefined;
    }
};

fn shardHint(file_entry: u64, block_index: u32, page_index: u32, n: u32) !u32 {
    _ = block_index;
    _ = page_index;
    return object_key.fileShard(file_entry, n);
}

fn sameBlockLayout(a: file_manifest_fmt.BlockDesc, b: file_manifest_fmt.BlockDesc) bool {
    return a.raw_offset == b.raw_offset and a.raw_size == b.raw_size and a.page_size == b.page_size and a.page_count == b.page_count and a.codec == b.codec and a.codec_level == b.codec_level and std.mem.eql(u8, &a.block_hash, &b.block_hash) and a.flags == b.flags;
}

pub fn create(allocator: std.mem.Allocator, base: *const pack_scan.PackImage, target: *const pack_scan.PackImage, options: PlanOptions) !Plan {
    var plan = Plan{ .allocator = allocator, .shard_hint_count = if (options.shard_hint_count == 0) target.shard_count else options.shard_hint_count };
    errdefer plan.deinit();
    const n = plan.shard_hint_count;

    // Files present in target.
    var it = target.files.iterator();
    while (it.next()) |e| {
        const file_entry = e.key_ptr.*;
        const new_file = e.value_ptr;
        const old_file: ?*const pack_scan.FileImage = base.files.getPtr(file_entry);
        const override = if (options.overrides) |m| (m.get(file_entry) orelse options.default_override) else options.default_override;
        if (old_file) |of| {
            if (std.mem.eql(u8, of.manifest_bytes, new_file.manifest_bytes)) {
                // Same manifest: pages should be identical; verify bytes and
                // replace any that differ (defensive).
                var changed = false;
                for (new_file.manifest.blocks, 0..) |blk, bi| {
                    var pi: u32 = 0;
                    while (pi < blk.page_count) : (pi += 1) {
                        const np = target.page(file_entry, @intCast(bi), pi) orelse return error.Corruption;
                        const op = base.page(file_entry, @intCast(bi), pi);
                        if (op != null and std.mem.eql(u8, op.?.bytes, np.bytes)) continue;
                        changed = true;
                        try addRaw(&plan, np, n, diff_pack.Strategy.replace, 0);
                    }
                }
                if (!changed) plan.unchanged_files += 1;
                continue;
            }
            try plan.file_ops.append(allocator, .{ .op = .{
                .op = .put_file_manifest,
                .file_entry = file_entry,
                .old_file_version = of.manifest.header.file_version,
                .new_file_version = new_file.manifest.header.file_version,
                .old_content_hash = of.manifest.header.content_hash,
                .new_content_hash = new_file.manifest.header.content_hash,
            }, .payload = new_file.manifest_bytes });
            for (new_file.manifest.blocks, 0..) |new_blk, bi| {
                const block_index: u32 = @intCast(bi);
                const old_blk: ?file_manifest_fmt.BlockDesc = if (bi < of.manifest.blocks.len) of.manifest.blocks[bi] else null;
                try planBlock(&plan, base, target, file_entry, block_index, old_blk, new_blk, override, options.strategy, n);
            }
            // Blocks that disappeared entirely.
            var bi: usize = new_file.manifest.blocks.len;
            while (bi < of.manifest.blocks.len) : (bi += 1) {
                try addDeletes(&plan, file_entry, @intCast(bi), 0, of.manifest.blocks[bi].page_count, n);
            }
        } else {
            try plan.file_ops.append(allocator, .{ .op = .{
                .op = .put_file_manifest,
                .file_entry = file_entry,
                .new_file_version = new_file.manifest.header.file_version,
                .new_content_hash = new_file.manifest.header.content_hash,
            }, .payload = new_file.manifest_bytes });
            for (new_file.manifest.blocks, 0..) |new_blk, bi| {
                try planBlock(&plan, base, target, file_entry, @intCast(bi), null, new_blk, override, options.strategy, n);
            }
        }
    }

    // Files removed.
    var bit = base.files.iterator();
    while (bit.next()) |e| {
        const file_entry = e.key_ptr.*;
        if (target.files.contains(file_entry)) continue;
        const of = e.value_ptr;
        try plan.file_ops.append(allocator, .{ .op = .{
            .op = .delete_file_manifest,
            .file_entry = file_entry,
            .old_file_version = of.manifest.header.file_version,
            .old_content_hash = of.manifest.header.content_hash,
        } });
        for (of.manifest.blocks, 0..) |blk, bi| try addDeletes(&plan, file_entry, @intCast(bi), 0, blk.page_count, n);
    }

    // Tombstones.
    var tit = target.tombstones.iterator();
    while (tit.next()) |e| {
        const old = base.tombstones.get(e.key_ptr.*);
        if (old != null and std.mem.eql(u8, old.?, e.value_ptr.*)) continue;
        try plan.file_ops.append(allocator, .{ .op = .{ .op = .put_entry_tombstone, .file_entry = e.key_ptr.* }, .payload = e.value_ptr.* });
    }
    var btit = base.tombstones.iterator();
    while (btit.next()) |e| {
        if (target.tombstones.contains(e.key_ptr.*)) continue;
        try plan.file_ops.append(allocator, .{ .op = .{ .op = .delete_entry_tombstone, .file_entry = e.key_ptr.* } });
    }

    // Directory manifest.
    if (target.directory_manifest_bytes) |d| {
        const same = base.directory_manifest_bytes != null and std.mem.eql(u8, base.directory_manifest_bytes.?, d);
        if (!same) try plan.file_ops.append(allocator, .{ .op = .{ .op = .put_directory_manifest, .file_entry = 1 }, .payload = d });
    }

    // Path delta.
    for (target.path_entries) |te| {
        const be = base.pathEntry(te.normalized_path);
        if (be != null and be.?.file_entry == te.file_entry and be.?.flags == te.flags) continue;
        try plan.path_adds.append(allocator, .{ .file_entry = te.file_entry, .flags = te.flags, .path = te.normalized_path });
    }
    for (base.path_entries) |be| {
        if (target.pathEntry(be.normalized_path) != null) continue;
        try plan.path_removes.append(allocator, .{ .path = be.normalized_path });
    }

    std.mem.sort(PlannedUnit, plan.units.items, {}, unitLessThan);
    return plan;
}

/// Canonical unit order inside a DiffPack (docs §7.6): by shard hint, then
/// deletes last, then (file_entry, block, page). Shared with the engine so
/// planned and encoded units sort identically.
pub fn unitOrder(a_hint: u32, a_desc: diff_pack.UnitDesc, b_hint: u32, b_desc: diff_pack.UnitDesc) bool {
    if (a_hint != b_hint) return a_hint < b_hint;
    const a_del = a_desc.kind == .delete_page;
    const b_del = b_desc.kind == .delete_page;
    if (a_del != b_del) return !a_del;
    if (a_desc.file_entry != b_desc.file_entry) return a_desc.file_entry < b_desc.file_entry;
    if (a_desc.block_index != b_desc.block_index) return a_desc.block_index < b_desc.block_index;
    return a_desc.page_index < b_desc.page_index;
}

fn unitLessThan(_: void, a: PlannedUnit, b: PlannedUnit) bool {
    return unitOrder(a.shard_hint, a.desc, b.shard_hint, b.desc);
}

fn addRaw(plan: *Plan, np: *const pack_scan.PageImage, n: u32, strategy: diff_pack.Strategy, flags: u32) !void {
    try plan.units.append(plan.allocator, .{
        .desc = .{
            .kind = .put_page_raw,
            .strategy = strategy,
            .codec = np.codec,
            .flags = flags,
            .file_entry = np.identity.file_entry,
            .block_index = np.identity.block_index,
            .page_index = np.identity.page_index,
            .new_stored_crc = np.stored_crc,
        },
        .source = .{ .raw_page = np },
        .shard_hint = try shardHint(np.identity.file_entry, np.identity.block_index, np.identity.page_index, n),
        .replace_bytes = np.bytes.len,
    });
}

fn addDeletes(plan: *Plan, file_entry: u64, block_index: u32, from: u32, to: u32, n: u32) !void {
    var pi = from;
    while (pi < to) : (pi += 1) {
        try plan.units.append(plan.allocator, .{
            .desc = .{ .kind = .delete_page, .strategy = .none, .codec = .none, .file_entry = file_entry, .block_index = block_index, .page_index = pi },
            .source = .delete,
            .shard_hint = try shardHint(file_entry, block_index, pi, n),
            .replace_bytes = 0,
        });
    }
}

fn planBlock(
    plan: *Plan,
    base: *const pack_scan.PackImage,
    target: *const pack_scan.PackImage,
    file_entry: u64,
    block_index: u32,
    old_blk: ?file_manifest_fmt.BlockDesc,
    new_blk: file_manifest_fmt.BlockDesc,
    override: build_cfg.DiffStrategy,
    sopts: strategy_mod.StrategyOptions,
    n: u32,
) !void {
    if ((new_blk.flags & file_manifest_fmt.BLOCK_FLAG_EXPLICIT_PAGE_REFS) != 0) return error.UnsupportedFeature;
    if (old_blk != null and (old_blk.?.flags & file_manifest_fmt.BLOCK_FLAG_EXPLICIT_PAGE_REFS) != 0) return error.UnsupportedFeature;
    // Identical layout: page-wise compare, replace only what differs.
    if (old_blk != null and sameBlockLayout(old_blk.?, new_blk)) {
        var pi: u32 = 0;
        while (pi < new_blk.page_count) : (pi += 1) {
            const np = target.page(file_entry, block_index, pi) orelse return error.Corruption;
            const op = base.page(file_entry, block_index, pi);
            if (op != null and std.mem.eql(u8, op.?.bytes, np.bytes)) continue;
            try addRaw(plan, np, n, .replace, 0);
        }
        return;
    }
    const decision = strategy_mod.decide(old_blk, new_blk, override, sopts);
    switch (decision.strategy) {
        .logical => {
            var replace_bytes: u64 = 0;
            var pi: u32 = 0;
            var raw_crcs = std.ArrayList(u8).empty;
            defer raw_crcs.deinit(plan.allocator);
            while (pi < new_blk.page_count) : (pi += 1) {
                const np = target.page(file_entry, block_index, pi) orelse return error.Corruption;
                replace_bytes += np.bytes.len;
                var b: [4]u8 = undefined;
                std.mem.writeInt(u32, &b, np.raw_crc, .little);
                try raw_crcs.appendSlice(plan.allocator, &b);
            }
            try plan.units.append(plan.allocator, .{
                .desc = .{
                    .kind = .put_block_ldelta,
                    .strategy = .logical,
                    .codec = new_blk.codec,
                    .codec_level = new_blk.codec_level,
                    .flags = decision.flags,
                    .file_entry = file_entry,
                    .block_index = block_index,
                    .page_index = 0,
                    .page_count = new_blk.page_count,
                    .page_size = new_blk.page_size,
                    .new_raw_size = std.math.cast(u32, new_blk.raw_size) orelse return error.InvalidArgument,
                    .new_stored_crc = @import("../format/common.zig").crc32c(raw_crcs.items),
                    .old_block_hash = old_blk.?.block_hash,
                    .new_block_hash = new_blk.block_hash,
                    .codec_version_hash = registry.caps(new_blk.codec).version_hash,
                },
                .source = .{ .block_delta = .{ .old_block = old_blk.?, .new_block = new_blk } },
                .shard_hint = try shardHint(file_entry, block_index, 0, n),
                .replace_bytes = replace_bytes,
            });
            if (old_blk.?.page_count > new_blk.page_count) try addDeletes(plan, file_entry, block_index, new_blk.page_count, old_blk.?.page_count, n);
        },
        .page => {
            var pi: u32 = 0;
            while (pi < new_blk.page_count) : (pi += 1) {
                const np = target.page(file_entry, block_index, pi) orelse return error.Corruption;
                const op = base.page(file_entry, block_index, pi);
                if (op == null) {
                    try addRaw(plan, np, n, .page, decision.flags | diff_pack.UNIT_FLAG_NEW_BLOCK);
                    continue;
                }
                if (std.mem.eql(u8, op.?.bytes, np.bytes)) continue;
                try plan.units.append(plan.allocator, .{
                    .desc = .{
                        .kind = .put_page_pdelta,
                        .strategy = .page,
                        .codec = np.codec,
                        .flags = decision.flags,
                        .file_entry = file_entry,
                        .block_index = block_index,
                        .page_index = pi,
                        .old_stored_size = op.?.stored_size,
                        .old_stored_crc = op.?.stored_crc,
                        .new_stored_crc = np.stored_crc,
                        .codec_version_hash = registry.caps(np.codec).version_hash,
                    },
                    .source = .{ .page_delta = .{ .old = op.?, .new = np } },
                    .shard_hint = try shardHint(file_entry, block_index, pi, n),
                    .replace_bytes = np.bytes.len,
                });
            }
            if (old_blk != null and old_blk.?.page_count > new_blk.page_count) try addDeletes(plan, file_entry, block_index, new_blk.page_count, old_blk.?.page_count, n);
        },
        .replace, .none => {
            var pi: u32 = 0;
            while (pi < new_blk.page_count) : (pi += 1) {
                const np = target.page(file_entry, block_index, pi) orelse return error.Corruption;
                const op = base.page(file_entry, block_index, pi);
                if (op != null and std.mem.eql(u8, op.?.bytes, np.bytes)) continue;
                try addRaw(plan, np, n, .replace, decision.flags);
            }
            if (old_blk != null and old_blk.?.page_count > new_blk.page_count) try addDeletes(plan, file_entry, block_index, new_blk.page_count, old_blk.?.page_count, n);
        },
        _ => return error.InvalidArgument,
    }
}
