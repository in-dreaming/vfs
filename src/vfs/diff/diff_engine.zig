//! Turns planned units into encoded payloads, in parallel through the task
//! framework. A delta that is not worth it is downgraded to replace here.
const std = @import("std");
const db_internal = @import("db_internal");
const sync = db_internal.platform.sync;
const pack_scan = @import("pack_scan.zig");
const planner = @import("diff_planner.zig");
const strategy_mod = @import("strategy.zig");
const block_codec = @import("block_codec.zig");
const diff_pack = @import("../format/diff_pack.zig");
const hdiff = @import("../hdiff/root.zig");
const task = @import("../task/root.zig");

pub const EncodedUnit = struct {
    desc: diff_pack.UnitDesc,
    shard_hint: u32,
    /// Owned by the result; empty for delete_page.
    payload: []u8,
};

pub const EngineOptions = struct {
    hdiff: hdiff.DiffOptions = .{},
    strategy: strategy_mod.StrategyOptions = .{},
    budget: task.Budget = .{},
};

pub const Result = struct {
    allocator: std.mem.Allocator,
    units: std.ArrayList(EncodedUnit) = .empty,
    downgraded_ratio: u32 = 0,
    payload_bytes: u64 = 0,

    pub fn deinit(self: *Result) void {
        for (self.units.items) |u| if (u.payload.len != 0) self.allocator.free(u.payload);
        self.units.deinit(self.allocator);
        self.* = undefined;
    }
};

const Ctx = struct {
    allocator: std.mem.Allocator,
    base: *const pack_scan.PackImage,
    target: *const pack_scan.PackImage,
    plan: *const planner.Plan,
    options: EngineOptions,
    lock: sync.Mutex = .{},
    result: *Result,

    fn push(self: *Ctx, unit: EncodedUnit) !void {
        self.lock.lock();
        defer self.lock.unlock();
        try self.result.units.append(self.allocator, unit);
        self.result.payload_bytes += unit.payload.len;
    }

    fn pushRawPages(self: *Ctx, pu: planner.PlannedUnit, flags: u32) !void {
        var pi: u32 = 0;
        while (pi < pu.desc.page_count) : (pi += 1) {
            const np = self.target.page(pu.desc.file_entry, pu.desc.block_index, pi) orelse return error.Corruption;
            const d = diff_pack.UnitDesc{
                .kind = .put_page_raw,
                .strategy = .replace,
                .codec = np.codec,
                .flags = flags,
                .file_entry = np.identity.file_entry,
                .block_index = np.identity.block_index,
                .page_index = pi,
                .new_stored_crc = np.stored_crc,
            };
            try self.push(.{ .desc = d, .shard_hint = pu.shard_hint, .payload = try self.allocator.dupe(u8, np.bytes) });
        }
        self.lock.lock();
        defer self.lock.unlock();
        self.result.downgraded_ratio += 1;
    }

    fn rawBlock(self: *Ctx, image: *const pack_scan.PackImage, file_entry: u64, block_index: u32, page_count: u32) ![]u8 {
        var out = std.ArrayList(u8).empty;
        errdefer out.deinit(self.allocator);
        var pi: u32 = 0;
        while (pi < page_count) : (pi += 1) {
            const p = image.page(file_entry, block_index, pi) orelse return error.Corruption;
            const raw = try block_codec.rawFromPageBytes(self.allocator, p.bytes, p.identity);
            defer self.allocator.free(raw);
            try out.appendSlice(self.allocator, raw);
        }
        return out.toOwnedSlice(self.allocator);
    }

    fn run(ctx: *anyopaque, _: *task.Graph, _: task.TaskId, desc: task.TaskDesc) anyerror!task.RunResult {
        const self: *Ctx = @ptrCast(@alignCast(ctx));
        const pu = self.plan.units.items[desc.label_index];
        switch (pu.source) {
            .delete => try self.push(.{ .desc = pu.desc, .shard_hint = pu.shard_hint, .payload = &.{} }),
            .raw_page => |np| try self.push(.{ .desc = pu.desc, .shard_hint = pu.shard_hint, .payload = try self.allocator.dupe(u8, np.bytes) }),
            .page_delta => |pd| {
                const vhdf = try hdiff.createDiff(self.allocator, pd.old.bytes, pd.new.bytes, self.options.hdiff);
                if (!strategy_mod.deltaWorthIt(vhdf.len, pd.new.bytes.len, self.options.strategy)) {
                    self.allocator.free(vhdf);
                    var d = pu.desc;
                    d.kind = .put_page_raw;
                    d.strategy = .replace;
                    d.flags |= diff_pack.UNIT_FLAG_DOWNGRADED_RATIO;
                    d.old_stored_size = 0;
                    d.old_stored_crc = 0;
                    try self.push(.{ .desc = d, .shard_hint = pu.shard_hint, .payload = try self.allocator.dupe(u8, pd.new.bytes) });
                    self.lock.lock();
                    defer self.lock.unlock();
                    self.result.downgraded_ratio += 1;
                    return .done;
                }
                try self.push(.{ .desc = pu.desc, .shard_hint = pu.shard_hint, .payload = vhdf });
            },
            .block_delta => |bd| {
                const old_raw = try self.rawBlock(self.base, pu.desc.file_entry, pu.desc.block_index, bd.old_block.page_count);
                defer self.allocator.free(old_raw);
                const new_raw = try self.rawBlock(self.target, pu.desc.file_entry, pu.desc.block_index, bd.new_block.page_count);
                defer self.allocator.free(new_raw);
                if (new_raw.len != bd.new_block.raw_size) return error.Corruption;
                const vhdf = try hdiff.createDiff(self.allocator, old_raw, new_raw, self.options.hdiff);
                if (!strategy_mod.deltaWorthIt(vhdf.len, @intCast(pu.replace_bytes), self.options.strategy)) {
                    self.allocator.free(vhdf);
                    try self.pushRawPages(pu, pu.desc.flags | diff_pack.UNIT_FLAG_DOWNGRADED_RATIO);
                    return .done;
                }
                try self.push(.{ .desc = pu.desc, .shard_hint = pu.shard_hint, .payload = vhdf });
            },
        }
        return .done;
    }
};

pub fn run(allocator: std.mem.Allocator, base: *const pack_scan.PackImage, target: *const pack_scan.PackImage, plan: *const planner.Plan, options: EngineOptions) !Result {
    var result = Result{ .allocator = allocator };
    errdefer result.deinit();
    var ctx = Ctx{ .allocator = allocator, .base = base, .target = target, .plan = plan, .options = options, .result = &result };

    var graph = task.Graph.init(allocator);
    defer graph.deinit();
    for (plan.units.items, 0..) |pu, i| {
        const need: task.Need = switch (pu.source) {
            .block_delta => |bd| .{ .cpu = 1, .mem_bytes = bd.old_block.raw_size + bd.new_block.raw_size * 2 + 1 },
            .page_delta => |pd| .{ .cpu = 1, .mem_bytes = pd.old.bytes.len + pd.new.bytes.len * 2 + 1 },
            .raw_page => |np| .{ .mem_bytes = np.bytes.len + 1 },
            .delete => .{},
        };
        const prio: i32 = switch (pu.source) {
            .block_delta => 20,
            .page_delta => 10,
            else => 0,
        };
        _ = try graph.addTask(.{ .kind = 1, .need = need, .priority = prio, .label_file_entry = pu.desc.file_entry, .label_index = @intCast(i) });
    }
    var sched = try task.Scheduler.init(allocator, options.budget);
    defer sched.deinit();
    var report = try sched.run(&graph, .{ .context = &ctx, .run = Ctx.run }, .{});
    report.deinit(allocator);

    std.mem.sort(EncodedUnit, result.units.items, {}, unitLessThan);
    return result;
}

fn unitLessThan(_: void, a: EncodedUnit, b: EncodedUnit) bool {
    return planner.unitOrder(a.shard_hint, a.desc, b.shard_hint, b.desc);
}
