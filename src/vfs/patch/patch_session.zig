//! End-to-end patch run (docs/vfs/diff_patch.md §9, §14).
//!
//!   P0 open target (in-place pack or overlay + read-only base), read intent
//!   P1 open DiffPacks     P2 chain + coalesce     P3 build task graph
//!   P4 write intent, run graph, drain shard writers
//!   P5 finalize: path index + PackManifest + intent delete in one Batch
//!   P6 optional verification of touched pages
const std = @import("std");
const db_internal = @import("db_internal");
const kv = db_internal.kv_db;
const batch_mod = db_internal.batch_snapshot;
const fmt_db = db_internal.format;
const sync = db_internal.platform.sync;
const pf = db_internal.platform.file;
const pack_tools = @import("../tools/pack_tools.zig");
const task = @import("../task/root.zig");
const hdiff = @import("../hdiff/root.zig");
const hash = @import("../hash.zig");
const object_key = @import("../object_key.zig");
const diff_pack = @import("../format/diff_pack.zig");
const pack_manifest_fmt = @import("../format/pack_manifest.zig");
const page_value_fmt = @import("../format/page_value.zig");
const file_manifest_fmt = @import("../format/file_manifest.zig");
const page_placeholder_fmt = @import("../format/page_placeholder.zig");
const patch_intent_fmt = @import("../format/patch_intent.zig");
const path_index_fmt = @import("../format/path_index.zig");
const tombstone_fmt = @import("../format/tombstone.zig");
const block_codec = @import("../diff/block_codec.zig");
const registry = @import("../compress/registry.zig");
const reader_mod = @import("diff_pack_reader.zig");
const chain_mod = @import("chain.zig");
const coalesce = @import("coalesce.zig");
const old_view_mod = @import("old_view.zig");
const shard_writer_mod = @import("shard_writer.zig");
const overlay_mod = @import("overlay.zig");

pub const TOOL_VERSION_HASH: u64 = 0x7666735f70617431; // "vfs_pat1"

pub const FaultPoint = union(enum) {
    none,
    after_intent,
    /// Fail when this many apply units have completed.
    after_units: u32,
    after_file_ops: u32,
    before_finalize,
};

pub const IdempotentCheck = enum { header, off };
/// `touched` re-decodes every page this run wrote; `full` additionally runs
/// `pack_tools.verifyPack` over the whole target once it is closed.
pub const VerifyAfter = enum { none, touched, full };

/// Live counters for pollers (the C ABI). Written with relaxed atomics by
/// worker threads; `cancel` is checked before every task.
pub const Progress = struct {
    units_total: std.atomic.Value(u64) = .init(0),
    units_done: std.atomic.Value(u64) = .init(0),
    bytes_written: std.atomic.Value(u64) = .init(0),
    bytes_read: std.atomic.Value(u64) = .init(0),
    cancel: std.atomic.Value(bool) = .init(false),
};

pub const PatchOptions = struct {
    budget: task.Budget = .{},
    diff_load: reader_mod.LoadMode = .auto,
    in_memory_max_bytes: u64 = 512 << 20,
    writer: shard_writer_mod.Options = .{},
    idempotent_check: IdempotentCheck = .header,
    verify_after: VerifyAfter = .touched,
    /// Run `KvDb.optimize` on the target after finalize: reclaims the records
    /// superseded by the patch and rebuilds the base index.
    optimize_after: bool = false,
    /// Accept a PatchIntent left by a different chain to the same version.
    force: bool = false,
    /// Shards for a newly created overlay.
    overlay_shards: u32 = 1,
    fault: FaultPoint = .none,
    /// Record per-task dispatch timings; written as JSON to `trace_path`
    /// when set (bench / experiments).
    trace: bool = false,
    trace_path: ?[]const u8 = null,
    /// Optional live progress / cancellation channel.
    progress: ?*Progress = null,
};

pub const Report = struct {
    from_version: u64 = 0,
    to_version: u64 = 0,
    no_op: bool = false,
    resumed: bool = false,
    units_total: u64 = 0,
    units_applied: u64 = 0,
    units_skipped: u64 = 0,
    pages_written: u64 = 0,
    pages_deleted: u64 = 0,
    file_ops: u64 = 0,
    bytes_written: u64 = 0,
    batches: u64 = 0,
    yields: u64 = 0,
    wall_ns: u64 = 0,
    max_running: u32 = 0,
    max_mem_bytes: u64 = 0,
};

const Kind = enum(u16) { apply = 1, file_op = 2 };

const Pending = struct {
    ops: std.ArrayList(shard_writer_mod.StagedOp) = .empty,
    file_entry: u64,
};

const Session = struct {
    allocator: std.mem.Allocator,
    options: PatchOptions,
    view: old_view_mod.OldView,
    writer: *shard_writer_mod.ShardWriter,
    readers: []const *reader_mod.DiffPackReader,
    plan: *const coalesce.PatchPlan,
    to_version: u64,
    pending: []?Pending,
    lock: sync.Mutex = .{},
    report: *Report,
    touched: std.ArrayList(page_value_fmt.PageIdentity) = .empty,
    units_done: u32 = 0,
    file_ops_done: u32 = 0,

    fn run(ctx: *anyopaque, _: *task.Graph, _: task.TaskId, desc: task.TaskDesc) anyerror!task.RunResult {
        const self: *Session = @ptrCast(@alignCast(ctx));
        if (self.options.progress) |p| if (p.cancel.load(.acquire)) return error.Cancelled;
        switch (@as(Kind, @enumFromInt(desc.kind))) {
            .apply => {
                switch (self.options.fault) {
                    .after_units => |n| {
                        self.lock.lock();
                        const done = self.units_done;
                        self.lock.unlock();
                        if (done >= n) return error.InjectedFailure;
                    },
                    else => {},
                }
                const r = try self.applyUnit(desc.label_index);
                if (r == .done) {
                    self.lock.lock();
                    self.units_done += 1;
                    self.lock.unlock();
                    if (self.options.progress) |p| _ = p.units_done.fetchAdd(1, .monotonic);
                }
                return r;
            },
            .file_op => {
                switch (self.options.fault) {
                    .after_file_ops => |n| {
                        self.lock.lock();
                        const done = self.file_ops_done;
                        self.lock.unlock();
                        if (done >= n) return error.InjectedFailure;
                    },
                    else => {},
                }
                const r = try self.applyFileOp(desc.label_index);
                if (r == .done) {
                    self.lock.lock();
                    self.file_ops_done += 1;
                    self.lock.unlock();
                }
                return r;
            },
        }
    }

    /// Borrows a step's payload from its DiffPack; pinned until `unpin`.
    fn payload(self: *Session, step: coalesce.Step) ![]const u8 {
        const p = try self.readers[step.reader].payload(step.unit.payload);
        if (self.options.progress) |pr| _ = pr.bytes_read.fetchAdd(p.len, .monotonic);
        return p;
    }

    fn unpin(self: *Session, step: coalesce.Step) void {
        self.readers[step.reader].unpinPayload(step.unit.payload);
    }

    // ---- staging with yield support -------------------------------------

    /// Stages a unit's ops atomically into its file shard; yields when the
    /// writer is over its memory watermark.
    fn flushPending(self: *Session, slot: usize) !task.RunResult {
        var p = &self.pending[slot].?;
        switch (try self.writer.stageAll(self.writer.shardOfFile(p.file_entry), p.ops.items)) {
            .would_block => return .yield,
            .staged => {},
        }
        p.ops.deinit(self.allocator);
        self.pending[slot] = null;
        return .done;
    }

    fn discardPending(self: *Session, slot: usize) void {
        if (self.pending[slot]) |*p| {
            for (p.ops.items) |op| if (op.value) |v| self.allocator.free(v);
            p.ops.deinit(self.allocator);
            self.pending[slot] = null;
        }
    }

    fn bump(self: *Session, comptime field: []const u8, n: u64) void {
        if (comptime std.mem.eql(u8, field, "bytes_written")) {
            if (self.options.progress) |p| _ = p.bytes_written.fetchAdd(n, .monotonic);
        }
        self.lock.lock();
        defer self.lock.unlock();
        @field(self.report, field) += n;
    }

    fn deleteOp(self: *Session, identity: page_value_fmt.PageIdentity) !?shard_writer_mod.StagedOp {
        const key = try object_key.pageKey(identity.file_entry, identity.block_index, identity.page_index);
        if (!self.view.isOverlay()) {
            if (self.options.idempotent_check == .header and (try self.view.targetState(key)) == .missing) return null;
            return .{ .key = key, .value = null };
        }
        if (self.options.idempotent_check == .header and !(try self.view.pageVisible(key))) return null;
        const ph = page_placeholder_fmt.encode(.{ .file_entry = identity.file_entry, .block_index = identity.block_index, .page_index = identity.page_index });
        return .{ .key = key, .value = try self.allocator.dupe(u8, &ph) };
    }

    // ---- apply units -------------------------------------------------------

    fn applyUnit(self: *Session, index: u32) !task.RunResult {
        if (self.pending[index] != null) return self.flushPending(index);
        const unit = self.plan.units.items[index];
        var ops = std.ArrayList(shard_writer_mod.StagedOp).empty;
        errdefer {
            for (ops.items) |op| if (op.value) |v| self.allocator.free(v);
            ops.deinit(self.allocator);
        }
        const skipped = if (unit.composite) try self.applyComposite(unit, &ops) else try self.applyPage(unit, &ops);
        if (skipped) {
            self.bump("units_skipped", 1);
            ops.deinit(self.allocator);
            return .done;
        }
        self.bump("units_applied", 1);
        self.pending[index] = .{ .ops = ops, .file_entry = unit.file_entry };
        return self.flushPending(index);
    }

    /// Returns true if the unit was already applied (nothing staged).
    fn applyPage(self: *Session, unit: coalesce.ApplyUnit, ops: *std.ArrayList(shard_writer_mod.StagedOp)) !bool {
        const a = self.allocator;
        const identity: page_value_fmt.PageIdentity = .{ .file_entry = unit.file_entry, .block_index = unit.block_index, .page_index = unit.page_index };
        const key = try object_key.pageKey(identity.file_entry, identity.block_index, identity.page_index);
        const last = coalesce.lastStep(unit);
        if (last.unit.kind == .delete_page) {
            const op = (try self.deleteOp(identity)) orelse return true;
            try ops.append(a, op);
            self.bump("pages_deleted", 1);
            return false;
        }
        if (self.options.idempotent_check == .header) {
            if (try self.view.readTargetObjectAlloc(a, key)) |cur| {
                defer a.free(cur);
                if (page_value_fmt.decodePageValue(cur, identity)) |pv| {
                    if (pv.stored_crc == last.unit.new_stored_crc) return true;
                } else |_| {
                    // A well-formed header naming another object is a key
                    // collision and must never be overwritten; anything else
                    // is damage this unit repairs.
                    try requireSameIdentity(cur, identity);
                }
            }
        }
        var cur: ?[]u8 = null;
        defer if (cur) |c| a.free(c);
        for (unit.steps) |step| {
            const p = try self.payload(step);
            defer self.unpin(step);
            switch (step.unit.kind) {
                .put_page_raw => {
                    _ = try page_value_fmt.decodePageValue(p, identity);
                    if (cur) |c| a.free(c);
                    cur = try a.dupe(u8, p);
                },
                .put_page_pdelta => {
                    if (cur == null) cur = self.view.readPage(a, identity) catch |e| switch (e) {
                        error.NotFound => return error.PreconditionFailed,
                        else => |err| return err,
                    };
                    const old = try page_value_fmt.decodePageValue(cur.?, identity);
                    if (old.stored_crc != step.unit.old_stored_crc) return error.PreconditionFailed;
                    try requireCodecVersion(old.codec, step.unit.codec_version_hash);
                    const new = try hdiff.patchAlloc(a, cur.?, p);
                    errdefer a.free(new);
                    const nv = try page_value_fmt.decodePageValue(new, identity);
                    if (nv.stored_crc != step.unit.new_stored_crc) return error.Corruption;
                    a.free(cur.?);
                    cur = new;
                },
                .delete_page => {
                    if (cur) |c| a.free(c);
                    cur = null;
                },
                else => return error.Corruption,
            }
        }
        const value = cur orelse return error.Corruption;
        cur = null;
        try ops.append(a, .{ .key = key, .value = value });
        self.bump("pages_written", 1);
        self.bump("bytes_written", value.len);
        try self.markTouched(identity);
        return false;
    }

    fn markTouched(self: *Session, identity: page_value_fmt.PageIdentity) !void {
        self.lock.lock();
        defer self.lock.unlock();
        try self.touched.append(self.allocator, identity);
    }

    /// A page delta was computed against pages encoded by one codec build;
    /// applying it to pages of another build would produce garbage that only
    /// the final CRC catches. `none` has no build identity.
    fn requireCodecVersion(codec: file_manifest_fmt.Codec, expected_version_hash: u64) !void {
        if (codec == .none) return;
        if (registry.caps(codec).version_hash != expected_version_hash) return error.CodecMismatch;
    }

    /// Refuses to overwrite a value whose intact header belongs to a
    /// different object (key collision); garbage headers pass.
    fn requireSameIdentity(existing: []const u8, identity: page_value_fmt.PageIdentity) !void {
        const found = page_value_fmt.peekIdentity(existing) orelse return;
        if (found.file_entry != identity.file_entry or found.block_index != identity.block_index or found.page_index != identity.page_index) return error.KeyCollision;
    }

    const BlockState = struct {
        a: std.mem.Allocator,
        view: *const old_view_mod.OldView,
        file_entry: u64,
        block_index: u32,
        pages: std.AutoArrayHashMapUnmanaged(u32, []u8) = .empty,
        deleted: std.AutoHashMapUnmanaged(u32, void) = .empty,

        fn deinit(self: *BlockState) void {
            for (self.pages.values()) |v| self.a.free(v);
            self.pages.deinit(self.a);
            self.deleted.deinit(self.a);
        }

        fn identity(self: *const BlockState, p: u32) page_value_fmt.PageIdentity {
            return .{ .file_entry = self.file_entry, .block_index = self.block_index, .page_index = p };
        }

        /// Current bytes of page `p` (loaded lazily from the old view).
        fn get(self: *BlockState, p: u32) !?[]u8 {
            if (self.pages.get(p)) |v| return v;
            if (self.deleted.contains(p)) return null;
            const bytes = self.view.readPage(self.a, self.identity(p)) catch |e| switch (e) {
                error.NotFound => return null,
                else => |err| return err,
            };
            try self.pages.put(self.a, p, bytes);
            return bytes;
        }

        fn set(self: *BlockState, p: u32, bytes: []u8) !void {
            if (self.pages.fetchSwapRemove(p)) |old| self.a.free(old.value);
            _ = self.deleted.remove(p);
            try self.pages.put(self.a, p, bytes);
        }

        fn remove(self: *BlockState, p: u32) !void {
            if (self.pages.fetchSwapRemove(p)) |old| self.a.free(old.value);
            try self.deleted.put(self.a, p, {});
        }
    };

    fn applyComposite(self: *Session, unit: coalesce.ApplyUnit, ops: *std.ArrayList(shard_writer_mod.StagedOp)) !bool {
        const a = self.allocator;
        if (self.options.idempotent_check == .header) {
            if (try self.blockAlreadyAt(unit)) return true;
        }
        var st = BlockState{ .a = a, .view = &self.view, .file_entry = unit.file_entry, .block_index = unit.block_index };
        defer st.deinit();
        for (unit.steps) |step| {
            const p = try self.payload(step);
            defer self.unpin(step);
            switch (step.unit.kind) {
                .put_block_ldelta => {
                    // Assemble the old logical block: contiguous pages from 0.
                    var old_raw = std.ArrayList(u8).empty;
                    defer old_raw.deinit(a);
                    var old_count: u32 = 0;
                    while (try st.get(old_count)) |bytes| : (old_count += 1) {
                        const raw = try block_codec.rawFromPageBytes(a, bytes, st.identity(old_count));
                        defer a.free(raw);
                        try old_raw.appendSlice(a, raw);
                    }
                    if (!std.mem.eql(u8, &hash.contentHash(old_raw.items), &step.unit.old_block_hash)) return error.PreconditionFailed;
                    const new_raw = try hdiff.patchAlloc(a, old_raw.items, p);
                    defer a.free(new_raw);
                    if (new_raw.len != step.unit.new_raw_size) return error.Corruption;
                    if (!std.mem.eql(u8, &hash.contentHash(new_raw), &step.unit.new_block_hash)) return error.Corruption;
                    const pages = try block_codec.pagesFromRaw(a, unit.file_entry, unit.block_index, step.unit.page_size, step.unit.codec, step.unit.codec_level, new_raw);
                    defer a.free(pages);
                    if (pages.len != step.unit.page_count) {
                        for (pages) |pg| a.free(pg);
                        return error.Corruption;
                    }
                    for (pages, 0..) |pg, i| try st.set(@intCast(i), pg);
                    var extra: u32 = @intCast(pages.len);
                    while (extra < old_count) : (extra += 1) try st.remove(extra);
                },
                .put_page_raw => {
                    _ = try page_value_fmt.decodePageValue(p, st.identity(step.unit.page_index));
                    try st.set(step.unit.page_index, try a.dupe(u8, p));
                },
                .put_page_pdelta => {
                    const cur = (try st.get(step.unit.page_index)) orelse return error.PreconditionFailed;
                    const old = try page_value_fmt.decodePageValue(cur, st.identity(step.unit.page_index));
                    if (old.stored_crc != step.unit.old_stored_crc) return error.PreconditionFailed;
                    try requireCodecVersion(old.codec, step.unit.codec_version_hash);
                    const new = try hdiff.patchAlloc(a, cur, p);
                    errdefer a.free(new);
                    const nv = try page_value_fmt.decodePageValue(new, st.identity(step.unit.page_index));
                    if (nv.stored_crc != step.unit.new_stored_crc) return error.Corruption;
                    try st.set(step.unit.page_index, new);
                },
                .delete_page => try st.remove(step.unit.page_index),
                else => return error.Corruption,
            }
        }
        // Emit: every page in state is a put; every deleted page a delete.
        var it = st.pages.iterator();
        while (it.next()) |e| {
            const idn = st.identity(e.key_ptr.*);
            const key = try object_key.pageKey(idn.file_entry, idn.block_index, idn.page_index);
            // Skip pages identical to the target layer's current bytes.
            if (self.options.idempotent_check == .header) {
                if (try self.view.readTargetObjectAlloc(a, key)) |cur| {
                    defer a.free(cur);
                    if (std.mem.eql(u8, cur, e.value_ptr.*)) continue;
                    try requireSameIdentity(cur, idn);
                }
            }
            try ops.append(a, .{ .key = key, .value = try a.dupe(u8, e.value_ptr.*) });
            self.bump("pages_written", 1);
            self.bump("bytes_written", e.value_ptr.len);
            try self.markTouched(idn);
        }
        var dit = st.deleted.iterator();
        while (dit.next()) |e| {
            if (try self.deleteOp(st.identity(e.key_ptr.*))) |op| {
                try ops.append(a, op);
                self.bump("pages_deleted", 1);
            }
        }
        return false;
    }

    const Expected = union(enum) {
        absent,
        stored_crc: u32,
        /// Page belongs to this L step's output; checked as a group.
        from_l: usize,
    };

    /// Derives the block's expected final state from the step chain and
    /// compares it against the target layer using header-level fingerprints
    /// only (no decompression, no hpatch).
    fn blockAlreadyAt(self: *Session, unit: coalesce.ApplyUnit) !bool {
        const a = self.allocator;
        var expected = std.AutoArrayHashMapUnmanaged(u32, Expected){};
        defer expected.deinit(a);
        for (unit.steps, 0..) |s, si| {
            switch (s.unit.kind) {
                .put_block_ldelta => {
                    var p: u32 = 0;
                    while (p < s.unit.page_count) : (p += 1) try expected.put(a, p, .{ .from_l = si });
                },
                .put_page_raw, .put_page_pdelta => try expected.put(a, s.unit.page_index, .{ .stored_crc = s.unit.new_stored_crc }),
                .delete_page => try expected.put(a, s.unit.page_index, .absent),
                else => return false,
            }
        }
        // Per-L raw_crc sequences, accumulated in page order.
        var l_crcs = std.AutoArrayHashMapUnmanaged(usize, std.ArrayList(u32)){};
        defer {
            for (l_crcs.values()) |*l| l.deinit(a);
            l_crcs.deinit(a);
        }
        var page_indices = std.ArrayList(u32).empty;
        defer page_indices.deinit(a);
        for (expected.keys()) |k| try page_indices.append(a, k);
        std.mem.sort(u32, page_indices.items, {}, std.sort.asc(u32));
        for (page_indices.items) |p| {
            const identity: page_value_fmt.PageIdentity = .{ .file_entry = unit.file_entry, .block_index = unit.block_index, .page_index = p };
            const key = try object_key.pageKey(identity.file_entry, identity.block_index, identity.page_index);
            switch (expected.get(p).?) {
                .absent => if (try self.view.pageVisible(key)) return false,
                .stored_crc => |crc| {
                    const cur = (try self.view.readTargetObjectAlloc(a, key)) orelse return false;
                    defer a.free(cur);
                    const pv = page_value_fmt.decodePageValue(cur, identity) catch return false;
                    if (pv.stored_crc != crc) return false;
                },
                .from_l => |si| {
                    const cur = (try self.view.readTargetObjectAlloc(a, key)) orelse return false;
                    defer a.free(cur);
                    const pv = page_value_fmt.decodePageValue(cur, identity) catch return false;
                    const l = unit.steps[si].unit;
                    if (pv.codec != l.codec and pv.codec != .none) return false;
                    const gop = try l_crcs.getOrPut(a, si);
                    if (!gop.found_existing) gop.value_ptr.* = .empty;
                    try gop.value_ptr.append(a, pv.raw_crc);
                },
            }
        }
        var it = l_crcs.iterator();
        while (it.next()) |e| {
            const l = unit.steps[e.key_ptr.*].unit;
            if (e.value_ptr.items.len != l.page_count) return false;
            if (block_codec.rawCrcSequenceHash(e.value_ptr.items) != l.new_stored_crc) return false;
        }
        return true;
    }

    // ---- file ops ----------------------------------------------------------

    fn applyFileOp(self: *Session, index: u32) !task.RunResult {
        const slot = self.plan.units.items.len + index;
        if (self.pending[slot] != null) return self.flushPending(slot);
        const a = self.allocator;
        const fo = self.plan.file_ops.items[index];
        const p = try self.readers[fo.reader].payload(fo.op.payload);
        defer self.readers[fo.reader].unpinPayload(fo.op.payload);
        var ops = std.ArrayList(shard_writer_mod.StagedOp).empty;
        errdefer {
            for (ops.items) |op| if (op.value) |v| a.free(v);
            ops.deinit(a);
        }
        switch (fo.op.op) {
            .put_file_manifest, .put_entry_tombstone, .put_directory_manifest => {
                const key = switch (fo.op.op) {
                    .put_file_manifest => try object_key.fileManifestKey(fo.op.file_entry),
                    .put_entry_tombstone => try object_key.entryTombstoneKey(fo.op.file_entry),
                    else => object_key.directoryManifestKey(),
                };
                if (try self.view.readTargetObjectAlloc(a, key)) |cur| {
                    defer a.free(cur);
                    if (std.mem.eql(u8, cur, p)) {
                        ops.deinit(a);
                        return .done;
                    }
                }
                try ops.append(a, .{ .key = key, .value = try a.dupe(u8, p) });
            },
            .delete_file_manifest => {
                const key = try object_key.fileManifestKey(fo.op.file_entry);
                if ((try self.view.targetState(key)) == .present) try ops.append(a, .{ .key = key, .value = null });
                if (self.view.isOverlay()) {
                    // Hide the base's manifest.
                    const tkey = try object_key.entryTombstoneKey(fo.op.file_entry);
                    const ts = try tombstone_fmt.encodeEntryTombstone(.{ .file_entry = fo.op.file_entry, .tombstone_version = self.to_version, .reason_flags = 1 });
                    const existing = try self.view.readTargetObjectAlloc(a, tkey);
                    defer if (existing) |e| a.free(e);
                    if (existing == null) try ops.append(a, .{ .key = tkey, .value = try a.dupe(u8, &ts) });
                }
            },
            .delete_entry_tombstone => {
                const key = try object_key.entryTombstoneKey(fo.op.file_entry);
                if ((try self.view.targetState(key)) == .present) try ops.append(a, .{ .key = key, .value = null });
            },
            _ => return error.Corruption,
        }
        if (ops.items.len == 0) {
            ops.deinit(a);
            return .done;
        }
        self.bump("file_ops", 1);
        // Singletons (directory manifest) live in shard 0 like the builder puts them.
        const route_entry: u64 = if (fo.op.op == .put_directory_manifest) 0 else fo.op.file_entry;
        self.pending[slot] = .{ .ops = ops, .file_entry = route_entry };
        return self.flushPending(slot);
    }
};

fn readTargetManifest(db: *kv.KvDb) !pack_manifest_fmt.PackManifest {
    const kb = object_key.encodeDbKey(object_key.packManifestKey());
    return pack_manifest_fmt.decodePackManifest(try db.getBorrowedBytes(&kb));
}

fn readIntent(allocator: std.mem.Allocator, db: *kv.KvDb) !?patch_intent_fmt.Decoded {
    const kb = object_key.encodeDbKey(object_key.patchIntentKey());
    const bytes = db.getBorrowedBytes(&kb) catch |err| switch (err) {
        error.NotFound => return null,
        else => |e| return e,
    };
    return try patch_intent_fmt.decode(allocator, bytes);
}

fn nowUnixMs() u64 {
    const io = std.Io.Threaded.global_single_threaded.io();
    const ns = std.Io.Timestamp.now(io, .real).nanoseconds;
    return @intCast(@max(@divTrunc(ns, std.time.ns_per_ms), 0));
}

fn writeTraceJson(allocator: std.mem.Allocator, path: []const u8, sched_report: *const task.scheduler.Report) !void {
    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    try sched_report.writeJson(&aw.writer);
    var f = try pf.open(path, .{ .mode = .create_read_write, .create_parent_dirs = true });
    defer pf.close(&f);
    try pf.setLen(f, 0);
    try pf.pwriteAll(f, 0, aw.written());
    try pf.flushData(f);
}

/// Name of the exclusive lock file created in the written pack directory
/// for the duration of a run (docs §9.1 P0).
pub const LOCK_FILE_NAME = ".vfs_patch.lock";

/// Held while a pack is being patched so two patchers cannot interleave
/// batches on the same store. Stale locks (crash) are removed on the next
/// run because the on-disk state is fully described by the PatchIntent.
const PatchLock = struct {
    path: []u8,
    file: std.Io.File,

    fn acquire(allocator: std.mem.Allocator, dir: []const u8) !PatchLock {
        const io = std.Io.Threaded.global_single_threaded.io();
        const path = try std.fs.path.join(allocator, &.{ dir, LOCK_FILE_NAME });
        errdefer allocator.free(path);
        // Exclusive create is the atomic "test and set"; a second patcher on
        // the same directory sees PathAlreadyExists.
        const file = std.Io.Dir.cwd().createFile(io, path, .{ .exclusive = true }) catch |e| switch (e) {
            error.PathAlreadyExists => return error.Busy,
            else => |err| return err,
        };
        return .{ .path = path, .file = file };
    }

    fn release(self: *PatchLock, allocator: std.mem.Allocator) void {
        const io = std.Io.Threaded.global_single_threaded.io();
        self.file.close(io);
        std.Io.Dir.cwd().deleteFile(io, self.path) catch {};
        allocator.free(self.path);
        self.* = undefined;
    }
};

/// Applies DiffPacks to `target_path`. With `overlay_path` the target is the
/// overlay (created if missing) and `target_path` is the read-only base.
/// `to_version == null` selects the highest reachable version.
pub fn run(allocator: std.mem.Allocator, target_path: []const u8, overlay_path: ?[]const u8, diff_paths: []const []const u8, to_version: ?u64, options: PatchOptions) !Report {
    const written_dir = overlay_path orelse target_path;
    if (overlay_path) |op| try overlay_mod.openOrCreate(allocator, target_path, op, .{ .shards = options.overlay_shards });
    var lock = try PatchLock.acquire(allocator, written_dir);
    defer lock.release(allocator);

    const report = try runSession(allocator, target_path, overlay_path, diff_paths, to_version, options);

    // The store is closed here, so a full verification can open it itself.
    if (options.verify_after == .full and !report.no_op) {
        var vr = try pack_tools.verifyPack(written_dir, allocator);
        defer vr.deinit(allocator);
        if (!vr.ok()) return error.Corruption;
    }
    return report;
}

fn runSession(allocator: std.mem.Allocator, target_path: []const u8, overlay_path: ?[]const u8, diff_paths: []const []const u8, to_version: ?u64, options: PatchOptions) !Report {
    const wall_start = task.scheduler.nowNs();
    var report: Report = .{};

    // P0 open target.
    var base_db: ?kv.KvDb = null;
    defer if (base_db) |*b| b.close() catch {};
    var target_db: kv.KvDb = undefined;
    if (overlay_path) |op| {
        base_db = try kv.KvDb.open(target_path, .{ .mode = .read_only, .create_if_missing = false, .read_handles = 4 });
        target_db = try kv.KvDb.open(op, .{ .create_if_missing = false, .max_delta_entries = 1 << 16 });
    } else {
        target_db = try kv.KvDb.open(target_path, .{ .create_if_missing = false, .max_delta_entries = 1 << 16 });
    }
    defer target_db.close() catch {};
    const view = old_view_mod.OldView{ .target = &target_db, .base = if (base_db) |*b| b else null };
    const current = try readTargetManifest(&target_db);
    report.from_version = current.pack_version;
    var intent = try readIntent(allocator, &target_db);
    defer if (intent) |*i| i.deinit(allocator);

    // P1 open diffs.
    var readers = std.ArrayList(*reader_mod.DiffPackReader).empty;
    defer {
        for (readers.items) |r| {
            r.close();
            allocator.destroy(r);
        }
        readers.deinit(allocator);
    }
    var manifests = std.ArrayList(diff_pack.DiffManifest).empty;
    defer manifests.deinit(allocator);
    for (diff_paths) |dp| {
        const r = try allocator.create(reader_mod.DiffPackReader);
        errdefer allocator.destroy(r);
        r.* = try reader_mod.DiffPackReader.open(allocator, dp, .{ .load = options.diff_load, .in_memory_max_bytes = options.in_memory_max_bytes });
        errdefer r.close();
        if (r.manifest.target_pack_id != current.pack_id) return error.InvalidArgument;
        // Reserve both slots first so ownership of `r` moves to `readers`
        // only when neither append can fail (avoids a double close).
        try readers.ensureUnusedCapacity(allocator, 1);
        try manifests.ensureUnusedCapacity(allocator, 1);
        readers.appendAssumeCapacity(r);
        manifests.appendAssumeCapacity(r.manifest);
    }
    if (readers.items.len == 0) return error.InvalidArgument;

    // P2 chain + coalesce.
    var target_version: u64 = to_version orelse blk: {
        var best: u64 = 0;
        for (manifests.items) |m| best = @max(best, m.target_pack_version);
        break :blk best;
    };
    if (intent) |i| {
        if (i.intent.from_version != current.pack_version) return error.PatchIntentMismatch;
        if (to_version == null) target_version = i.intent.to_version;
        if (i.intent.to_version != target_version) return error.PatchIntentMismatch;
    }
    report.to_version = target_version;
    if (current.pack_version == target_version) {
        report.no_op = true;
        report.wall_ns = @intCast(@max(task.scheduler.nowNs() - wall_start, 0));
        return report;
    }
    const order = try chain_mod.select(allocator, manifests.items, current.pack_version, target_version);
    defer allocator.free(order);
    var chain = try allocator.alloc(*reader_mod.DiffPackReader, order.len);
    defer allocator.free(chain);
    for (order, 0..) |idx, i| chain[i] = readers.items[idx];
    var plan = try coalesce.build(allocator, chain);
    defer plan.deinit();
    if (!std.mem.eql(u8, &plan.first.base_content_hash, &current.content_hash)) return error.PreconditionFailed;
    if (intent) |i| {
        const same_chain = std.mem.eql(u64, i.intent.diff_ids, plan.diff_ids);
        if (!same_chain and !options.force) return error.PatchIntentMismatch;
        report.resumed = true;
    }
    report.units_total = plan.units.items.len;
    if (options.progress) |p| {
        p.units_total.store(plan.units.items.len, .release);
        if (p.cancel.load(.acquire)) return error.Cancelled;
    }

    // P3 build graph.
    var writer = try shard_writer_mod.ShardWriter.init(allocator, &target_db, options.writer);
    defer writer.deinit();
    const pending = try allocator.alloc(?Pending, plan.units.items.len + plan.file_ops.items.len);
    @memset(pending, null);
    var session = Session{
        .allocator = allocator,
        .options = options,
        .view = view,
        .writer = &writer,
        .readers = chain,
        .plan = &plan,
        .to_version = target_version,
        .pending = pending,
        .report = &report,
    };
    defer {
        for (pending, 0..) |_, i| session.discardPending(i);
        allocator.free(pending);
        session.touched.deinit(allocator);
    }

    var graph = task.Graph.init(allocator);
    defer graph.deinit();
    const resolved = options.budget.resolved();
    var by_file = std.AutoHashMap(u64, std.ArrayList(task.TaskId)).init(allocator);
    defer {
        var it = by_file.valueIterator();
        while (it.next()) |l| l.deinit(allocator);
        by_file.deinit();
    }
    for (plan.units.items, 0..) |u, i| {
        var need: task.Need = .{ .cpu = 1, .mem_bytes = @min(u.est_bytes + 1, resolved.mem_bytes) };
        if (u.needs_codec) {
            need.cpu = 0;
            need.cpu_codec = 1;
        }
        const id = try graph.addTask(.{ .kind = @intFromEnum(Kind.apply), .need = need, .priority = if (u.composite) 20 else 10, .label_file_entry = u.file_entry, .label_index = @intCast(i) });
        const gop = try by_file.getOrPut(u.file_entry);
        if (!gop.found_existing) gop.value_ptr.* = .empty;
        try gop.value_ptr.append(allocator, id);
    }
    for (plan.file_ops.items, 0..) |fo, i| {
        const deps: []const task.TaskId = if (by_file.get(fo.op.file_entry)) |l| l.items else &.{};
        _ = try graph.addTaskWithDeps(.{ .kind = @intFromEnum(Kind.file_op), .need = .{}, .priority = 0, .label_file_entry = fo.op.file_entry, .label_index = @intCast(i) }, deps);
    }

    // P4 intent + run.
    {
        const intent_bytes = try patch_intent_fmt.encode(allocator, .{ .from_version = current.pack_version, .to_version = target_version, .started_unix_ms = nowUnixMs(), .tool_version_hash = TOOL_VERSION_HASH, .diff_ids = plan.diff_ids });
        defer allocator.free(intent_bytes);
        var b = batch_mod.Batch.begin(&target_db, allocator);
        defer b.deinit();
        try b.putBytes(&object_key.encodeDbKey(object_key.patchIntentKey()), intent_bytes, 0);
        try b.commit(.sync);
    }
    if (options.fault == .after_intent) return error.InjectedFailure;

    var sched = try task.Scheduler.init(allocator, options.budget);
    defer sched.deinit();
    var sched_report = try sched.run(&graph, .{ .context = &session, .run = Session.run }, .{ .trace = options.trace or options.trace_path != null });
    defer sched_report.deinit(allocator);
    report.max_running = sched_report.max_running;
    report.max_mem_bytes = sched_report.max_mem_bytes;
    if (options.trace_path) |tp| try writeTraceJson(allocator, tp, &sched_report);
    try writer.drain(.sync);
    report.batches = writer.stats.batches;
    report.yields = writer.stats.yields;
    if (options.fault == .before_finalize) return error.InjectedFailure;
    // A cancel that raced with the last tasks: everything staged so far is
    // committed and idempotent; just do not publish the new version.
    if (options.progress) |p| if (p.cancel.load(.acquire)) return error.Cancelled;

    // P5 finalize.
    {
        const old_pi_bytes = try view.readTargetObjectAlloc(allocator, object_key.pathIndexKey());
        defer if (old_pi_bytes) |b| allocator.free(b);
        var entries = std.StringArrayHashMapUnmanaged(path_index_fmt.EntryInput){};
        defer entries.deinit(allocator);
        var old_entries: []path_index_fmt.DecodedEntry = &.{};
        defer if (old_entries.len != 0) path_index_fmt.freeDecodedEntries(allocator, old_entries);
        if (old_pi_bytes) |b| {
            old_entries = try path_index_fmt.collectEntries(allocator, b);
            for (old_entries) |e| try entries.put(allocator, e.normalized_path, .{ .normalized_path = e.normalized_path, .file_entry = e.file_entry, .flags = e.flags });
        }
        var pit = plan.path_changes.iterator();
        while (pit.next()) |e| {
            if (e.value_ptr.*) |add| {
                try entries.put(allocator, e.key_ptr.*, .{ .normalized_path = add.path, .file_entry = add.file_entry, .flags = add.flags });
            } else {
                _ = entries.swapRemove(e.key_ptr.*);
            }
        }
        const new_pi = try path_index_fmt.encodePathIndex(allocator, entries.values());
        defer allocator.free(new_pi);

        var m = current;
        m.pack_version = plan.final.target_pack_version;
        m.build_id = plan.final.target_build_id;
        m.file_count = plan.final.target_file_count;
        m.tombstone_count = plan.final.target_tombstone_count;
        m.content_hash = plan.final.target_content_hash;
        const manifest_bytes = pack_manifest_fmt.encodePackManifest(m);

        var b = batch_mod.Batch.begin(&target_db, allocator);
        defer b.deinit();
        try b.putBytes(&object_key.encodeDbKey(object_key.pathIndexKey()), new_pi, 0);
        try b.putBytes(&object_key.encodeDbKey(object_key.packManifestKey()), &manifest_bytes, 0);
        try b.deleteBytes(&object_key.encodeDbKey(object_key.patchIntentKey()));
        try b.commit(.sync);
    }

    // P6 optional optimize + verify touched pages (`full` adds a whole-pack
    // verification in `run`, after the store is closed).
    if (options.optimize_after) try target_db.optimize();
    if (options.verify_after != .none) {
        for (session.touched.items) |idn| {
            const bytes = try view.readPage(allocator, idn);
            defer allocator.free(bytes);
            _ = try page_value_fmt.decodePageValue(bytes, idn);
        }
    }
    report.wall_ns = @intCast(@max(task.scheduler.nowNs() - wall_start, 0));
    return report;
}
