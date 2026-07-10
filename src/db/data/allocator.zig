const std = @import("std");
const fmt = @import("../format.zig");
const pf = @import("../platform/file.zig");

pub const CHECKPOINT_MAGIC: u32 = 0x31414344; // "DCA1"
pub const HEADER_SIZE: u64 = 56;
pub const BLOCK_SIZE: u64 = 16;
pub const MIN_SPLIT_SIZE: u64 = 32;

pub const Block = struct { offset: u64, size: u64 };
const Retired = struct { block: Block, epoch: u64 };

pub const EpochManager = struct {
    current: u64 = 1,
    readers: u64 = 0,

    pub fn enter(self: *EpochManager) u64 {
        self.readers += 1;
        return self.current;
    }

    pub fn exit(self: *EpochManager) void {
        self.readers -= 1;
        self.current += 1;
    }

    pub fn oldest(self: *const EpochManager) u64 {
        return if (self.readers == 0) self.current + 1 else self.current;
    }
};

pub const Allocator = struct {
    allocator: std.mem.Allocator,
    logical_tail: u64,
    free: std.ArrayList(Block) = .empty,
    retired: std.ArrayList(Retired) = .empty,
    quarantine: std.ArrayList(Block) = .empty,
    epoch: EpochManager = .{},

    pub fn init(allocator: std.mem.Allocator, logical_tail: u64) Allocator {
        return .{ .allocator = allocator, .logical_tail = logical_tail };
    }

    pub fn deinit(self: *Allocator) void {
        self.free.deinit(self.allocator);
        self.retired.deinit(self.allocator);
        self.quarantine.deinit(self.allocator);
    }

    pub fn allocate(self: *Allocator, size_in: u64) !Block {
        const size = try fmt.alignUp(size_in, 16);
        var best_i: ?usize = null;
        for (self.free.items, 0..) |b, i| {
            if (b.size >= size and (best_i == null or b.size < self.free.items[best_i.?].size)) best_i = i;
        }
        if (best_i) |i| {
            const b = self.free.orderedRemove(i);
            if (b.size >= size + MIN_SPLIT_SIZE) {
                try self.free.append(self.allocator, .{ .offset = b.offset + size, .size = b.size - size });
                return .{ .offset = b.offset, .size = size };
            }
            return b;
        }
        const out = Block{ .offset = self.logical_tail, .size = size };
        self.logical_tail += size;
        return out;
    }

    pub fn retire(self: *Allocator, block: Block) !void {
        try self.retired.append(self.allocator, .{ .block = block, .epoch = self.epoch.current });
    }

    pub fn reclaim(self: *Allocator) !void {
        const oldest = self.epoch.oldest();
        var i: usize = 0;
        while (i < self.retired.items.len) {
            if (self.retired.items[i].epoch < oldest) {
                const r = self.retired.orderedRemove(i);
                try self.free.append(self.allocator, r.block);
            } else {
                i += 1;
            }
        }
    }

    pub fn quarantineBlock(self: *Allocator, block: Block) !void {
        try self.quarantine.append(self.allocator, block);
    }

    pub fn writeCheckpoint(self: *Allocator, file: pf.FileHandle, offset: u64) !void {
        var header = [_]u8{0} ** HEADER_SIZE;
        fmt.writeU32Le(header[0..4], CHECKPOINT_MAGIC);
        fmt.writeU32Le(header[4..8], 1);
        fmt.writeU64Le(header[8..16], self.epoch.current);
        fmt.writeU64Le(header[16..24], self.logical_tail);
        var free_bytes: u64 = 0;
        for (self.free.items) |b| free_bytes += b.size;
        fmt.writeU64Le(header[24..32], free_bytes);
        fmt.writeU64Le(header[32..40], @intCast(self.retired.items.len));
        fmt.writeU32Le(header[40..44], 1);
        fmt.writeU32Le(header[44..48], @intCast(self.free.items.len));
        fmt.writeU64Le(header[48..56], HEADER_SIZE);
        try pf.pwriteAll(file, offset, &header);
        var buf: [BLOCK_SIZE]u8 = undefined;
        for (self.free.items, 0..) |b, i| {
            fmt.writeU64Le(buf[0..8], b.offset);
            fmt.writeU32Le(buf[8..12], @intCast(b.size));
            fmt.writeU32Le(buf[12..16], sizeClass(b.size));
            try pf.pwriteAll(file, offset + HEADER_SIZE + @as(u64, i) * BLOCK_SIZE, &buf);
        }
        try pf.flushMetadata(file);
    }

    pub fn readCheckpoint(allocator: std.mem.Allocator, file: pf.FileHandle, offset: u64) !Allocator {
        var header: [HEADER_SIZE]u8 = undefined;
        if (try pf.preadAll(file, offset, &header) != header.len) return error.Corruption;
        if (fmt.readU32Le(header[0..4]) != CHECKPOINT_MAGIC) return error.Corruption;
        var out = Allocator.init(allocator, fmt.readU64Le(header[16..24]));
        out.epoch.current = fmt.readU64Le(header[8..16]);
        const count = fmt.readU32Le(header[44..48]);
        var buf: [BLOCK_SIZE]u8 = undefined;
        var i: u32 = 0;
        while (i < count) : (i += 1) {
            if (try pf.preadAll(file, offset + HEADER_SIZE + @as(u64, i) * BLOCK_SIZE, &buf) != buf.len) return error.Corruption;
            try out.free.append(allocator, .{ .offset = fmt.readU64Le(buf[0..8]), .size = fmt.readU32Le(buf[8..12]) });
        }
        return out;
    }
};

fn sizeClass(size: u64) u32 {
    return @intCast(fmt.ceilLog2(size) catch 0);
}

test "allocator epoch retired reclaim split and checkpoint" {
    const testing = std.testing;
    var a = Allocator.init(testing.allocator, 1000);
    defer a.deinit();
    const old = try a.allocate(100);
    try a.retire(old);
    const epoch = a.epoch.enter();
    _ = epoch;
    try a.reclaim();
    const next = try a.allocate(80);
    try testing.expect(next.offset != old.offset);
    a.epoch.exit();
    try a.reclaim();
    const reused = try a.allocate(80);
    try testing.expectEqual(old.offset, reused.offset);

    try a.free.append(testing.allocator, .{ .offset = 5000, .size = 1024 });
    const small = try a.allocate(128);
    try testing.expectEqual(@as(u64, 5000), small.offset);
    try testing.expect(a.free.items.len > 0);

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var f = try pf.openAt(tmp.dir, "alloc.chk", .{ .mode = .create_read_write });
    defer pf.close(&f);
    try a.writeCheckpoint(f, 0);
    var loaded = try Allocator.readCheckpoint(testing.allocator, f, 0);
    defer loaded.deinit();
    try testing.expectEqual(a.logical_tail, loaded.logical_tail);
    try testing.expectEqual(a.free.items.len, loaded.free.items.len);

    try loaded.quarantineBlock(.{ .offset = 999, .size = 16 });
    const q = try loaded.allocate(16);
    try testing.expect(q.offset != 999);
}
