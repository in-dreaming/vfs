const std = @import("std");
const fmt = @import("../format.zig");
const pf = @import("../platform/file.zig");
const idx = @import("index_file.zig");
const journal_mod = @import("delta_journal.zig");

pub const SLOT_SIZE: u64 = 64;
const SLOT_SIZE_USIZE: usize = 64;
pub const TOMBSTONE_FLAG: u32 = 1;
const SLOT_LOCK_COUNT: usize = 256;

pub const DeltaSlotState = enum(u8) {
    empty = 0,
    occupied = 1,
    tombstone = 2,
};

pub const LookupResult = union(enum) {
    found: fmt.IndexInfo,
    deleted,
    not_found,
};

pub const PublishEntry = struct {
    key: fmt.Key128,
    info: fmt.IndexInfo,
    deleted: bool = false,
};

const Slot = struct {
    state: DeltaSlotState,
    h: u64,
    key: fmt.Key128,
    info: fmt.IndexInfo,
};

pub const DeltaIndex = struct {
    journal: journal_mod.DeltaJournal,
    mapping: ?pf.MappedRegion = null,
    slot_view_offset: usize = 0,
    slot_view_len: usize = 0,
    slots_dirty: bool = false,
    writer_lock: std.atomic.Mutex = .unlocked,
    slot_locks: [SLOT_LOCK_COUNT]std.atomic.Mutex = [_]std.atomic.Mutex{.unlocked} ** SLOT_LOCK_COUNT,
    used_slots: u64 = 0,
    writable: bool = true,

    pub fn lookup(self: *DeltaIndex, key: fmt.Key128) !LookupResult {
        if (self.writable) return lookupProtected(self, key);
        return lookupNoLock(self, key);
    }

    pub fn put(self: *DeltaIndex, key: fmt.Key128, info: fmt.IndexInfo, options: journal_mod.AppendOptions) !void {
        lockMutex(&self.writer_lock);
        defer self.writer_lock.unlock();
        try ensureLoadRoom(self);
        _ = try self.journal.appendPut(key, info, options);
        try publishSlot(self, key, info, .occupied);
    }

    pub fn delete(self: *DeltaIndex, key: fmt.Key128, options: journal_mod.AppendOptions) !void {
        lockMutex(&self.writer_lock);
        defer self.writer_lock.unlock();
        try ensureLoadRoom(self);
        _ = try self.journal.appendDelete(key, options);
        const info = fmt.IndexInfo{ .data_db_id = 0, .flags = TOMBSTONE_FLAG, .offset = 0, .stored_size = 0, .raw_size = 0, .version = 0, .crc = 0, .codec = 0, .reserved = 0 };
        try publishSlot(self, key, info, .tombstone);
    }

    pub fn publishCommittedPut(self: *DeltaIndex, key: fmt.Key128, info: fmt.IndexInfo) !void {
        lockMutex(&self.writer_lock);
        defer self.writer_lock.unlock();
        try ensureLoadRoom(self);
        try publishSlot(self, key, info, .occupied);
    }

    pub fn publishCommittedDelete(self: *DeltaIndex, key: fmt.Key128) !void {
        lockMutex(&self.writer_lock);
        defer self.writer_lock.unlock();
        try ensureLoadRoom(self);
        const info = fmt.IndexInfo{ .data_db_id = 0, .flags = TOMBSTONE_FLAG, .offset = 0, .stored_size = 0, .raw_size = 0, .version = 0, .crc = 0, .codec = 0, .reserved = 0 };
        try publishSlot(self, key, info, .tombstone);
    }

    pub fn ensureRoomFor(self: *DeltaIndex, additional: u64) !void {
        if ((self.used_slots + additional) * 100 > self.journal.header.slot_count * 70) return error.NeedCheckpoint;
    }

    pub fn publishCommittedMany(self: *DeltaIndex, entries: []const PublishEntry) !void {
        lockMutex(&self.writer_lock);
        defer self.writer_lock.unlock();
        try self.ensureRoomFor(entries.len);
        for (entries) |entry| {
            if (entry.deleted) {
                try publishSlot(self, entry.key, entry.info, .tombstone);
            } else {
                try publishSlot(self, entry.key, entry.info, .occupied);
            }
        }
    }

    pub fn close(self: *DeltaIndex) !void {
        defer self.unmap();
        if (self.writable) {
            try flushMappedSlots(self);
            try pf.flushData(self.journal.index.file);
            self.journal.header.clean = 1;
            try journal_mod.writeDeltaHeader(self.journal.index.file, self.journal.region.offset, self.journal.header);
            try pf.flushMetadata(self.journal.index.file);
        }
    }

    fn unmap(self: *DeltaIndex) void {
        if (self.mapping) |*mapping| {
            pf.munmap(mapping);
            self.mapping = null;
            self.slot_view_offset = 0;
            self.slot_view_len = 0;
            self.slots_dirty = false;
        }
    }
};

fn lockMutex(m: *std.atomic.Mutex) void {
    while (!m.tryLock()) std.atomic.spinLoopHint();
}

pub fn create(index: *idx.IndexFile, slot_count: u64, journal_size: u64) !DeltaIndex {
    if (slot_count == 0 or !std.math.isPowerOfTwo(slot_count)) return error.InvalidArgument;
    const slot_bytes = slot_count * SLOT_SIZE;
    const journal_offset = journal_mod.DELTA_HEADER_SIZE + slot_bytes;
    const region_size = journal_offset + journal_size;
    const id = try idx.allocateRegion(index, .delta, region_size);
    const region = try index.region(id);
    const header = journal_mod.DeltaHeader{ .magic = journal_mod.DELTA_MAGIC, .version = 1, .slot_offset = journal_mod.DELTA_HEADER_SIZE, .slot_count = slot_count, .journal_offset = journal_offset, .journal_size = journal_size, .journal_tail = 0, .clean = 1, .flags = 0, .crc = 0 };
    try journal_mod.writeDeltaHeader(index.file, region.offset, header);
    try zeroSlots(index.file, region.offset + header.slot_offset, slot_count);
    try idx.activateRegion(index, id, region_size);
    const active = try index.region(id);
    var di = DeltaIndex{ .journal = .{ .index = index, .region = active, .header = header }, .used_slots = 0, .writable = true };
    try attachMapping(&di, true);
    try markDirty(&di);
    return di;
}

pub fn open(index: *idx.IndexFile) !DeltaIndex {
    const j = try journal_mod.openActive(index);
    var di = DeltaIndex{ .journal = j, .writable = true };
    try attachMapping(&di, true);
    if (di.journal.header.clean == 0) {
        try recover(&di);
    } else {
        di.used_slots = try countUsedSlots(&di);
    }
    try markDirty(&di);
    return di;
}

pub fn openReadOnly(index: *idx.IndexFile) !DeltaIndex {
    const j = try journal_mod.openActive(index);
    var di = DeltaIndex{ .journal = j, .writable = false };
    if (di.journal.header.clean == 0) return error.Busy;
    try attachMapping(&di, false);
    di.used_slots = try countUsedSlots(&di);
    return di;
}

fn attachMapping(self: *DeltaIndex, writable: bool) !void {
    const file_len = try pf.len(self.journal.index.file);
    var map = if (writable)
        try pf.mmapReadWrite(self.journal.index.file, 0, file_len)
    else
        try pf.mmapReadonly(self.journal.index.file, 0, file_len);
    errdefer pf.munmap(&map);

    const slot_abs = self.journal.region.offset + self.journal.header.slot_offset;
    const slot_bytes = self.journal.header.slot_count * SLOT_SIZE;
    const view_offset = std.math.cast(usize, slot_abs) orelse return error.InvalidArgument;
    const view_len = std.math.cast(usize, slot_bytes) orelse return error.InvalidArgument;
    if (view_offset + view_len > map.bytesConst().len) return error.Corruption;
    self.mapping = map;
    self.slot_view_offset = view_offset;
    self.slot_view_len = view_len;
}

fn markDirty(self: *DeltaIndex) !void {
    self.journal.header.clean = 0;
    try journal_mod.writeDeltaHeader(self.journal.index.file, self.journal.region.offset, self.journal.header);
    try pf.flushMetadata(self.journal.index.file);
}

pub fn recover(self: *DeltaIndex) !void {
    try zeroMappedSlots(self);
    self.used_slots = 0;
    const records = try journal_mod.collectCommittedRecords(&self.journal, std.heap.smp_allocator);
    defer std.heap.smp_allocator.free(records);
    for (records) |r| {
        switch (r.op) {
            .put => try publishSlotNoJournal(self, r.key, r.info, .occupied),
            .delete => try publishSlotNoJournal(self, r.key, r.info, .tombstone),
            else => {},
        }
    }
    var scanner = self.journal.scanner();
    while (true) {
        const next_record = scanner.next() catch |err| switch (err) {
            error.Corruption => break,
            else => |e| return e,
        };
        if (next_record == null) break;
    }
    self.journal.header.journal_tail = scanner.lastGoodTail();
    try flushMappedSlots(self);
    try pf.flushData(self.journal.index.file);
    self.journal.header.clean = 1;
    try journal_mod.writeDeltaHeader(self.journal.index.file, self.journal.region.offset, self.journal.header);
    try pf.flushMetadata(self.journal.index.file);
}

fn ensureLoadRoom(self: *DeltaIndex) !void {
    if ((self.used_slots + 1) * 100 > self.journal.header.slot_count * 70) return error.NeedCheckpoint;
}

fn countUsedSlots(self: *DeltaIndex) !u64 {
    var used: u64 = 0;
    var i: u64 = 0;
    while (i < self.journal.header.slot_count) : (i += 1) {
        const s = try readSlot(self, i);
        if (s.state != .empty) used += 1;
    }
    return used;
}

fn lookupProtected(self: *DeltaIndex, key: fmt.Key128) !LookupResult {
    return lookupWithReader(self, key, readSlotProtected);
}

fn lookupNoLock(self: *DeltaIndex, key: fmt.Key128) !LookupResult {
    return lookupWithReader(self, key, readSlot);
}

fn lookupWithReader(self: *DeltaIndex, key: fmt.Key128, comptime reader: fn (*DeltaIndex, u64) anyerror!Slot) !LookupResult {
    const h = fmt.mixHash128To64(key);
    var idx_slot = h & (self.journal.header.slot_count - 1);
    var probed: u64 = 0;
    while (probed < self.journal.header.slot_count) : (probed += 1) {
        const s = try reader(self, idx_slot);
        switch (s.state) {
            .empty => return .not_found,
            .occupied => if (s.h == h and s.key.hi == key.hi and s.key.lo == key.lo) return .{ .found = s.info },
            .tombstone => if (s.h == h and s.key.hi == key.hi and s.key.lo == key.lo) return .deleted,
        }
        idx_slot = (idx_slot + 1) & (self.journal.header.slot_count - 1);
    }
    return .not_found;
}

fn publishSlot(self: *DeltaIndex, key: fmt.Key128, info: fmt.IndexInfo, state: DeltaSlotState) !void {
    try publishSlotNoJournal(self, key, info, state);
}

fn publishSlotNoJournal(self: *DeltaIndex, key: fmt.Key128, info: fmt.IndexInfo, state: DeltaSlotState) !void {
    const h = fmt.mixHash128To64(key);
    var idx_slot = h & (self.journal.header.slot_count - 1);
    var first_tombstone: ?u64 = null;
    var probed: u64 = 0;
    while (probed < self.journal.header.slot_count) : (probed += 1) {
        const s = try readSlot(self, idx_slot);
        switch (s.state) {
            .empty => {
                const target = first_tombstone orelse idx_slot;
                try writeSlotProtected(self, target, .{ .state = state, .h = h, .key = key, .info = info });
                if (first_tombstone == null) self.used_slots += 1;
                return;
            },
            .occupied, .tombstone => {
                if (s.h == h and s.key.hi == key.hi and s.key.lo == key.lo) {
                    try writeSlotProtected(self, idx_slot, .{ .state = state, .h = h, .key = key, .info = info });
                    return;
                }
                if (s.state == .tombstone and first_tombstone == null) first_tombstone = idx_slot;
            },
        }
        idx_slot = (idx_slot + 1) & (self.journal.header.slot_count - 1);
    }
    if (first_tombstone) |target| {
        try writeSlotProtected(self, target, .{ .state = state, .h = h, .key = key, .info = info });
        return;
    }
    return error.NeedCheckpoint;
}

fn slotOffset(self: *const DeltaIndex, slot_index: u64) u64 {
    return self.journal.region.offset + self.journal.header.slot_offset + slot_index * SLOT_SIZE;
}

fn readSlot(self: *const DeltaIndex, slot_index: u64) !Slot {
    if (self.mapping) |*mapping| {
        const offset = slotByteOffset(slot_index);
        if (offset + SLOT_SIZE_USIZE > self.slot_view_len) return error.Corruption;
        const view = mapping.bytesConst()[self.slot_view_offset + offset ..][0..SLOT_SIZE_USIZE];
        return decodeSlot(view);
    }
    var b: [SLOT_SIZE]u8 = undefined;
    if (try pf.preadAll(self.journal.index.file, slotOffset(self, slot_index), &b) != b.len) return error.Corruption;
    return decodeSlot(&b);
}

fn writeSlot(self: *DeltaIndex, slot_index: u64, s: Slot) !void {
    const b = encodeSlot(s);
    if (self.mapping) |*mapping| {
        const offset = slotByteOffset(slot_index);
        if (offset + SLOT_SIZE_USIZE > self.slot_view_len) return error.Corruption;
        const dst = mapping.bytes()[self.slot_view_offset + offset ..][0..SLOT_SIZE_USIZE];
        @memcpy(dst, b[0..]);
        self.slots_dirty = true;
        return;
    }
    try pf.pwriteAll(self.journal.index.file, slotOffset(self, slot_index), &b);
}

fn slotByteOffset(slot_index: u64) usize {
    return @as(usize, @intCast(slot_index)) * SLOT_SIZE_USIZE;
}

fn slotLock(self: *DeltaIndex, slot_index: u64) *std.atomic.Mutex {
    return &self.slot_locks[@as(usize, @intCast(slot_index % SLOT_LOCK_COUNT))];
}

fn readSlotProtected(self: *DeltaIndex, slot_index: u64) !Slot {
    const m = slotLock(self, slot_index);
    lockMutex(m);
    defer m.unlock();
    return readSlot(self, slot_index);
}

fn writeSlotProtected(self: *DeltaIndex, slot_index: u64, s: Slot) !void {
    const m = slotLock(self, slot_index);
    lockMutex(m);
    defer m.unlock();
    try writeSlot(self, slot_index, s);
}

fn zeroSlots(file: pf.FileHandle, offset: u64, slot_count: u64) !void {
    var zero = [_]u8{0} ** SLOT_SIZE;
    var i: u64 = 0;
    while (i < slot_count) : (i += 1) {
        try pf.pwriteAll(file, offset + i * SLOT_SIZE, &zero);
    }
}

fn zeroMappedSlots(self: *DeltaIndex) !void {
    if (self.mapping) |*mapping| {
        const slots = mapping.bytes()[self.slot_view_offset..][0..self.slot_view_len];
        @memset(slots, 0);
        self.slots_dirty = true;
    } else {
        try zeroSlots(self.journal.index.file, self.journal.region.offset + self.journal.header.slot_offset, self.journal.header.slot_count);
    }
}

fn flushMappedSlots(self: *DeltaIndex) !void {
    if (!self.slots_dirty) return;
    if (self.mapping) |*mapping| {
        const src = mapping.bytesConst()[self.slot_view_offset..][0..self.slot_view_len];
        try pf.pwriteAll(self.journal.index.file, self.journal.region.offset + self.journal.header.slot_offset, src);
    }
    self.slots_dirty = false;
}

fn encodeSlot(s: Slot) [SLOT_SIZE]u8 {
    var b = [_]u8{0} ** SLOT_SIZE;
    b[0] = @intFromEnum(s.state);
    fmt.writeU64Le(b[8..16], s.h);
    fmt.writeU64Le(b[16..24], s.key.hi);
    fmt.writeU64Le(b[24..32], s.key.lo);
    fmt.writeU32Le(b[32..36], s.info.data_db_id);
    fmt.writeU32Le(b[36..40], s.info.flags);
    fmt.writeU64Le(b[40..48], s.info.offset);
    fmt.writeU32Le(b[48..52], s.info.stored_size);
    fmt.writeU32Le(b[52..56], s.info.raw_size);
    fmt.writeU32Le(b[56..60], s.info.crc);
    fmt.writeU16Le(b[60..62], s.info.codec);
    fmt.writeU16Le(b[62..64], s.info.reserved);
    return b;
}

fn decodeSlot(b: *const [SLOT_SIZE]u8) !Slot {
    const state: DeltaSlotState = @enumFromInt(b[0]);
    return .{ .state = state, .h = fmt.readU64Le(b[8..16]), .key = .{ .hi = fmt.readU64Le(b[16..24]), .lo = fmt.readU64Le(b[24..32]) }, .info = .{ .data_db_id = fmt.readU32Le(b[32..36]), .flags = fmt.readU32Le(b[36..40]), .offset = fmt.readU64Le(b[40..48]), .stored_size = fmt.readU32Le(b[48..52]), .raw_size = fmt.readU32Le(b[52..56]), .version = 0, .crc = fmt.readU32Le(b[56..60]), .codec = fmt.readU16Le(b[60..62]), .reserved = fmt.readU16Le(b[62..64]) } };
}

test "delta index put delete lookup load and recovery replay" {
    const testing = std.testing;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var index = try idx.createAt(tmp.dir, "index.db", [_]u8{0} ** 16);
    defer index.close() catch unreachable;
    var di = try create(&index, 8, 4096);
    try testing.expect(di.mapping != null);
    const k1: fmt.Key128 = .{ .hi = 1, .lo = 2 };
    const info1 = fmt.IndexInfo{ .data_db_id = 1, .flags = 0, .offset = 11, .stored_size = 1, .raw_size = 1, .version = 1, .crc = 1, .codec = 0, .reserved = 0 };
    try testing.expectEqual(.not_found, try di.lookup(k1));
    try di.put(k1, info1, .{});
    try testing.expectEqual(@as(u64, 11), (try di.lookup(k1)).found.offset);
    var info2 = info1;
    info2.offset = 22;
    try di.put(k1, info2, .{});
    try testing.expectEqual(@as(u64, 22), (try di.lookup(k1)).found.offset);
    try di.delete(k1, .{});
    try testing.expectEqual(.deleted, try di.lookup(k1));

    const k2: fmt.Key128 = .{ .hi = 9, .lo = 9 };
    try di.put(k2, info1, .{});
    const tail = di.journal.header.journal_tail;
    di.journal.header.clean = 0;
    try journal_mod.writeDeltaHeader(index.file, di.journal.region.offset, di.journal.header);
    var recovered = try open(&index);
    try testing.expectEqual(.deleted, try recovered.lookup(k1));
    try testing.expectEqual(@as(u64, 11), (try recovered.lookup(k2)).found.offset);
    try testing.expectEqual(tail, recovered.journal.header.journal_tail);

    var small = try create(&index, 2, 128);
    try small.put(.{ .hi = 100, .lo = 0 }, info1, .{});
    try testing.expectError(error.NeedCheckpoint, small.put(.{ .hi = 101, .lo = 0 }, info1, .{}));
}

test "delta index slot table is mmap backed and persists without heap mirror" {
    const testing = std.testing;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var index = try idx.createAt(tmp.dir, "index.db", [_]u8{1} ** 16);
    defer index.close() catch unreachable;

    var di = try create(&index, 16, 4096);
    const key: fmt.Key128 = .{ .hi = 111, .lo = 222 };
    const info = fmt.IndexInfo{ .data_db_id = 1, .flags = 0, .offset = 1234, .stored_size = 8, .raw_size = 8, .version = 1, .crc = 77, .codec = 0, .reserved = 0 };
    try di.put(key, info, .{});
    try testing.expect(di.mapping != null);
    try testing.expect(di.slots_dirty);
    try testing.expectEqual(@as(u64, 1234), (try di.lookup(key)).found.offset);
    try di.close();

    var reopened = try open(&index);
    defer reopened.close() catch unreachable;
    try testing.expect(reopened.mapping != null);
    try testing.expect(!reopened.slots_dirty);
    try testing.expectEqual(@as(u64, 1234), (try reopened.lookup(key)).found.offset);
}
