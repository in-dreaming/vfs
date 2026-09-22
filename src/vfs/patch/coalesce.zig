//! Folds the units of a DiffPack chain into one PatchPlan so every touched
//! page is written exactly once (docs/vfs/diff_patch.md §11.2).
//!
//! Grouping: steps are collected per (file_entry, block_index). A block whose
//! chain contains only page-level steps is split into one apply unit per
//! page (each page carrying its own step chain); a block with any logical
//! (L) step becomes one composite unit that replays the whole chain on an
//! in-memory page set.
const std = @import("std");
const diff_pack = @import("../format/diff_pack.zig");
const reader_mod = @import("diff_pack_reader.zig");

pub const Step = struct {
    /// Index into the chain's reader list.
    reader: u32,
    unit: diff_pack.UnitDesc,
};

pub const ApplyUnit = struct {
    file_entry: u64,
    block_index: u32,
    /// Page for per-page units; ignored for composite.
    page_index: u32 = 0,
    composite: bool,
    steps: []Step,
    /// Estimated bytes the unit needs in flight (payload + old + new).
    est_bytes: u64,
    /// True if the last step re-compresses (cpu_codec resource).
    needs_codec: bool,
};

pub const FileOpStep = struct {
    reader: u32,
    op: diff_pack.FileOp,
};

pub const PatchPlan = struct {
    allocator: std.mem.Allocator,
    units: std.ArrayList(ApplyUnit) = .empty,
    /// Final op per (object kind, file_entry).
    file_ops: std.ArrayList(FileOpStep) = .empty,
    /// Normalized path -> file_entry / flags after folding; removed paths map to null.
    path_changes: std.StringArrayHashMapUnmanaged(?diff_pack.PathAdd) = .empty,
    final: diff_pack.DiffManifest,
    first: diff_pack.DiffManifest,
    diff_ids: []u64,

    pub fn deinit(self: *PatchPlan) void {
        for (self.units.items) |u| self.allocator.free(u.steps);
        self.units.deinit(self.allocator);
        self.file_ops.deinit(self.allocator);
        self.path_changes.deinit(self.allocator);
        self.allocator.free(self.diff_ids);
        self.* = undefined;
    }
};

const BlockKey = struct { file_entry: u64, block_index: u32 };
const FileOpKey = struct {
    target: enum(u8) { file_manifest, tombstone, directory_manifest },
    file_entry: u64,
};

fn stepOrder(kind: diff_pack.UnitKind) u8 {
    return switch (kind) {
        .put_block_ldelta => 0,
        .put_page_raw, .put_page_pdelta => 1,
        .delete_page => 2,
        _ => 3,
    };
}

fn stepLessThan(_: void, a: Step, b: Step) bool {
    if (a.reader != b.reader) return a.reader < b.reader;
    const oa = stepOrder(a.unit.kind);
    const ob = stepOrder(b.unit.kind);
    if (oa != ob) return oa < ob;
    return a.unit.page_index < b.unit.page_index;
}

pub fn build(allocator: std.mem.Allocator, readers: []const *reader_mod.DiffPackReader) !PatchPlan {
    if (readers.len == 0) return error.InvalidArgument;
    var plan = PatchPlan{
        .allocator = allocator,
        .final = readers[readers.len - 1].manifest,
        .first = readers[0].manifest,
        .diff_ids = try allocator.alloc(u64, readers.len),
    };
    errdefer plan.deinit();
    for (readers, 0..) |r, i| {
        plan.diff_ids[i] = r.manifest.diff_id;
        if (i > 0 and r.manifest.base_pack_version != readers[i - 1].manifest.target_pack_version) return error.InvalidArgument;
        if (r.manifest.target_pack_id != plan.first.target_pack_id) return error.InvalidArgument;
    }

    // 1. Gather steps per block.
    var blocks = std.AutoArrayHashMapUnmanaged(BlockKey, std.ArrayList(Step)){};
    defer {
        for (blocks.values()) |*l| l.deinit(allocator);
        blocks.deinit(allocator);
    }
    for (readers, 0..) |r, ri| {
        for (r.unit_tables) |t| for (t.units) |u| {
            const gop = try blocks.getOrPut(allocator, .{ .file_entry = u.file_entry, .block_index = u.block_index });
            if (!gop.found_existing) gop.value_ptr.* = .empty;
            try gop.value_ptr.append(allocator, .{ .reader = @intCast(ri), .unit = u });
        };
    }

    // 2. Emit apply units.
    var it = blocks.iterator();
    while (it.next()) |e| {
        const steps = e.value_ptr.items;
        std.mem.sort(Step, steps, {}, stepLessThan);
        var has_l = false;
        for (steps) |s| if (s.unit.kind == .put_block_ldelta) {
            has_l = true;
        };
        if (has_l) {
            var est: u64 = 0;
            var codec = false;
            for (steps) |s| {
                est += s.unit.payload.len;
                if (s.unit.kind == .put_block_ldelta) {
                    est += @as(u64, s.unit.new_raw_size) * 3;
                    codec = true;
                }
            }
            try plan.units.append(allocator, .{
                .file_entry = e.key_ptr.file_entry,
                .block_index = e.key_ptr.block_index,
                .composite = true,
                .steps = try allocator.dupe(Step, steps),
                .est_bytes = est,
                .needs_codec = codec,
            });
            continue;
        }
        // Per page: fold in order; a later raw/delete drops earlier steps.
        var per_page = std.AutoArrayHashMapUnmanaged(u32, std.ArrayList(Step)){};
        defer {
            for (per_page.values()) |*l| l.deinit(allocator);
            per_page.deinit(allocator);
        }
        for (steps) |s| {
            const gop = try per_page.getOrPut(allocator, s.unit.page_index);
            if (!gop.found_existing) gop.value_ptr.* = .empty;
            switch (s.unit.kind) {
                .put_page_raw, .delete_page => gop.value_ptr.clearRetainingCapacity(),
                else => {},
            }
            try gop.value_ptr.append(allocator, s);
        }
        var pit = per_page.iterator();
        while (pit.next()) |pe| {
            var est: u64 = 0;
            for (pe.value_ptr.items) |s| est += @as(u64, s.unit.payload.len) * 2 + s.unit.old_stored_size;
            try plan.units.append(allocator, .{
                .file_entry = e.key_ptr.file_entry,
                .block_index = e.key_ptr.block_index,
                .page_index = pe.key_ptr.*,
                .composite = false,
                .steps = try allocator.dupe(Step, pe.value_ptr.items),
                .est_bytes = est,
                .needs_codec = false,
            });
        }
    }

    // 3. File ops: last one per (object kind, file_entry) wins. FileEntry
    // may be an arbitrary hash (any bit pattern), so the target kind is a
    // separate key field rather than a tag bit folded into the entry.
    var ops = std.AutoArrayHashMapUnmanaged(FileOpKey, FileOpStep){};
    defer ops.deinit(allocator);
    for (readers, 0..) |r, ri| {
        for (r.file_ops) |op| {
            const key: FileOpKey = switch (op.op) {
                .put_file_manifest, .delete_file_manifest => .{ .target = .file_manifest, .file_entry = op.file_entry },
                .put_entry_tombstone, .delete_entry_tombstone => .{ .target = .tombstone, .file_entry = op.file_entry },
                .put_directory_manifest => .{ .target = .directory_manifest, .file_entry = 0 },
                _ => return error.Corruption,
            };
            try ops.put(allocator, key, .{ .reader = @intCast(ri), .op = op });
        }
    }
    for (ops.values()) |v| try plan.file_ops.append(allocator, v);

    // 4. Path delta fold.
    for (readers) |r| {
        const pd = r.path_delta orelse continue;
        for (pd.removes) |rm| try plan.path_changes.put(allocator, rm.path, null);
        for (pd.adds) |ad| try plan.path_changes.put(allocator, ad.path, ad);
    }
    return plan;
}

pub fn lastStep(u: ApplyUnit) Step {
    return u.steps[u.steps.len - 1];
}
