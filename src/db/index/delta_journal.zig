const std = @import("std");
const fmt = @import("../format.zig");
const pf = @import("../platform/file.zig");
const idx = @import("index_file.zig");

pub const DELTA_MAGIC: u32 = 0x314c5444; // "DTL1"
pub const JOURNAL_MAGIC: u32 = 0x314c4a44; // "DJL1"
pub const JOURNAL_COMMIT_MAGIC: u32 = 0x31434a44; // "DJC1"
pub const DELTA_HEADER_SIZE: u64 = 64;
pub const JOURNAL_HEADER_SIZE: u32 = 32;
pub const JOURNAL_PAYLOAD_SIZE: u32 = 64;
pub const JOURNAL_FOOTER_SIZE: u32 = 8;
pub const JOURNAL_RECORD_SIZE: u32 = JOURNAL_HEADER_SIZE + JOURNAL_PAYLOAD_SIZE + JOURNAL_FOOTER_SIZE;

pub const DeltaJournalOp = enum(u16) {
    put = 1,
    delete = 2,
    batch_begin = 3,
    batch_commit = 4,
    batch_abort = 5,
};

pub const DeltaHeader = extern struct {
    magic: u32,
    version: u32,
    slot_offset: u64,
    slot_count: u64,
    journal_offset: u64,
    journal_size: u64,
    journal_tail: u64,
    clean: u32,
    flags: u32,
    crc: u32,
};

pub const DeltaJournalRecordHeader = extern struct {
    magic: u32,
    version: u16,
    op: DeltaJournalOp,
    journal_epoch: u64,
    batch_id: u64,
    record_size: u32,
    header_crc: u32,
};

pub const DeltaJournalPayload = extern struct {
    h: u64,
    key_hi: u64,
    key_lo: u64,
    info: fmt.IndexInfo,
};

pub const DeltaJournalRecordFooter = extern struct {
    magic_commit: u32,
    record_crc: u32,
};

pub const JournalRecord = struct {
    op: DeltaJournalOp,
    journal_epoch: u64,
    batch_id: u64,
    key: fmt.Key128,
    h: u64,
    info: fmt.IndexInfo,
};

pub const AppendRecordInput = struct {
    op: DeltaJournalOp,
    key: fmt.Key128,
    info: fmt.IndexInfo = emptyInfo(),
};

pub const AppendOptions = struct {
    durability: fmt.Durability = .async,
    batch_id: u64 = 0,
    data_durable: bool = true,
    defer_header: bool = false,
};

pub const DeltaJournal = struct {
    index: *idx.IndexFile,
    region: idx.RegionDesc,
    header: DeltaHeader,
    append_lock: std.atomic.Mutex = .unlocked,

    pub fn appendPut(self: *DeltaJournal, key: fmt.Key128, info: fmt.IndexInfo, options: AppendOptions) !JournalRecord {
        return appendRecord(self, .put, key, info, options);
    }

    pub fn appendDelete(self: *DeltaJournal, key: fmt.Key128, options: AppendOptions) !JournalRecord {
        const info = fmt.IndexInfo{ .data_db_id = 0, .flags = 1, .offset = 0, .stored_size = 0, .raw_size = 0, .version = 0, .crc = 0, .codec = 0, .reserved = 0 };
        return appendRecord(self, .delete, key, info, options);
    }

    pub fn appendBatchBegin(self: *DeltaJournal, batch_id: u64, options: AppendOptions) !JournalRecord {
        var opts = options;
        opts.batch_id = batch_id;
        return appendRecord(self, .batch_begin, .{ .hi = 0, .lo = 0 }, emptyInfo(), opts);
    }

    pub fn appendBatchCommit(self: *DeltaJournal, batch_id: u64, options: AppendOptions) !JournalRecord {
        var opts = options;
        opts.batch_id = batch_id;
        return appendRecord(self, .batch_commit, .{ .hi = 0, .lo = 0 }, emptyInfo(), opts);
    }

    pub fn appendBatchAbort(self: *DeltaJournal, batch_id: u64, options: AppendOptions) !JournalRecord {
        var opts = options;
        opts.batch_id = batch_id;
        return appendRecord(self, .batch_abort, .{ .hi = 0, .lo = 0 }, emptyInfo(), opts);
    }

    pub fn appendMany(self: *DeltaJournal, allocator: std.mem.Allocator, records: []const AppendRecordInput, options: AppendOptions) !void {
        if (!options.data_durable) {
            for (records) |r| if (r.op == .put) return error.InvalidArgument;
        }
        while (!self.append_lock.tryLock()) std.atomic.spinLoopHint();
        defer self.append_lock.unlock();

        const bytes_len_u64 = @as(u64, records.len) * JOURNAL_RECORD_SIZE;
        if (self.header.journal_tail + bytes_len_u64 > self.header.journal_size) return error.NoSpace;
        const bytes_len = std.math.cast(usize, bytes_len_u64) orelse return error.InvalidArgument;
        var buf = try allocator.alloc(u8, bytes_len);
        defer allocator.free(buf);

        var cursor: usize = 0;
        var tail = self.header.journal_tail;
        for (records) |input| {
            var info = input.info;
            if (input.op == .delete) info.flags |= 1;
            const hval = fmt.mixHash128To64(input.key);
            const epoch = tail / JOURNAL_RECORD_SIZE + 1;
            var payload_buf = encodePayload(.{ .h = hval, .key_hi = input.key.hi, .key_lo = input.key.lo, .info = info });
            var header_buf = encodeHeader(.{ .magic = JOURNAL_MAGIC, .version = 1, .op = input.op, .journal_epoch = epoch, .batch_id = options.batch_id, .record_size = JOURNAL_RECORD_SIZE, .header_crc = 0 });
            const header_crc = fmt.crc32c(&header_buf);
            fmt.writeU32Le(header_buf[28..32], header_crc);
            var footer_buf = encodeFooter(.{ .magic_commit = JOURNAL_COMMIT_MAGIC, .record_crc = recordCrc(&header_buf, &payload_buf) });
            @memcpy(buf[cursor..][0..JOURNAL_HEADER_SIZE], &header_buf);
            cursor += JOURNAL_HEADER_SIZE;
            @memcpy(buf[cursor..][0..JOURNAL_PAYLOAD_SIZE], &payload_buf);
            cursor += JOURNAL_PAYLOAD_SIZE;
            @memcpy(buf[cursor..][0..JOURNAL_FOOTER_SIZE], &footer_buf);
            cursor += JOURNAL_FOOTER_SIZE;
            tail += JOURNAL_RECORD_SIZE;
        }

        const absolute = self.region.offset + self.header.journal_offset + self.header.journal_tail;
        try pf.pwriteAll(self.index.file, absolute, buf);
        self.header.journal_tail += bytes_len_u64;
        self.header.clean = 0;
        if (!options.defer_header) {
            try writeDeltaHeader(self.index.file, self.region.offset, self.header);
            if (options.durability == .sync) {
                try pf.flushData(self.index.file);
                try pf.flushMetadata(self.index.file);
            }
        }
    }

    pub fn scanner(self: *const DeltaJournal) JournalScanner {
        return .{ .file = self.index.file, .region = self.region, .header = self.header, .tail = 0, .last_good_tail = 0 };
    }
};

fn emptyInfo() fmt.IndexInfo {
    return .{ .data_db_id = 0, .flags = 0, .offset = 0, .stored_size = 0, .raw_size = 0, .version = 0, .crc = 0, .codec = 0, .reserved = 0 };
}

pub fn collectCommittedRecords(journal: *const DeltaJournal, allocator: std.mem.Allocator) ![]JournalRecord {
    var committed = std.AutoHashMap(u64, void).init(allocator);
    defer committed.deinit();

    var sc1 = journal.scanner();
    while (true) {
        const rec = sc1.next() catch |err| switch (err) {
            error.Corruption => break,
            else => |e| return e,
        };
        const r = rec orelse break;
        switch (r.op) {
            .batch_commit => if (r.batch_id != 0) try committed.put(r.batch_id, {}),
            .batch_abort => {
                if (r.batch_id != 0) _ = committed.remove(r.batch_id);
            },
            else => {},
        }
    }

    var out = std.ArrayList(JournalRecord).empty;
    errdefer out.deinit(allocator);
    var sc2 = journal.scanner();
    while (true) {
        const rec = sc2.next() catch |err| switch (err) {
            error.Corruption => break,
            else => |e| return e,
        };
        const r = rec orelse break;
        switch (r.op) {
            .put, .delete => {
                if (r.batch_id == 0 or committed.contains(r.batch_id)) {
                    try out.append(allocator, r);
                }
            },
            else => {},
        }
    }
    return out.toOwnedSlice(allocator);
}

pub const JournalScanner = struct {
    file: pf.FileHandle,
    region: idx.RegionDesc,
    header: DeltaHeader,
    tail: u64,
    last_good_tail: u64,

    pub fn next(self: *JournalScanner) !?JournalRecord {
        if (self.tail >= self.header.journal_tail) return null;
        const absolute = self.region.offset + self.header.journal_offset + self.tail;
        var header_buf: [JOURNAL_HEADER_SIZE]u8 = undefined;
        const n = try pf.preadAll(self.file, absolute, &header_buf);
        if (n != header_buf.len) return null;
        const h = decodeHeader(&header_buf) catch return null;
        if (h.magic != JOURNAL_MAGIC or h.version != 1 or h.record_size != JOURNAL_RECORD_SIZE) return error.Corruption;
        var crc_header = header_buf;
        fmt.writeU32Le(crc_header[28..32], 0);
        if (fmt.crc32c(&crc_header) != h.header_crc) return error.Corruption;
        if (self.tail + h.record_size > self.header.journal_tail or self.tail + h.record_size > self.header.journal_size) return null;
        var payload_buf: [JOURNAL_PAYLOAD_SIZE]u8 = undefined;
        var footer_buf: [JOURNAL_FOOTER_SIZE]u8 = undefined;
        if (try pf.preadAll(self.file, absolute + JOURNAL_HEADER_SIZE, &payload_buf) != payload_buf.len) return null;
        if (try pf.preadAll(self.file, absolute + JOURNAL_HEADER_SIZE + JOURNAL_PAYLOAD_SIZE, &footer_buf) != footer_buf.len) return null;
        const footer = decodeFooter(&footer_buf);
        if (footer.magic_commit != JOURNAL_COMMIT_MAGIC) return null;
        if (recordCrc(&header_buf, &payload_buf) != footer.record_crc) return error.Corruption;
        const payload = decodePayload(&payload_buf);
        self.tail += h.record_size;
        self.last_good_tail = self.tail;
        return .{ .op = h.op, .journal_epoch = h.journal_epoch, .batch_id = h.batch_id, .key = .{ .hi = payload.key_hi, .lo = payload.key_lo }, .h = payload.h, .info = payload.info };
    }

    pub fn lastGoodTail(self: *const JournalScanner) u64 {
        return self.last_good_tail;
    }
};

pub fn createActiveDelta(index: *idx.IndexFile, journal_size: u64) !DeltaJournal {
    const region_size = DELTA_HEADER_SIZE + journal_size;
    const id = try idx.allocateRegion(index, .delta, region_size);
    const region = try index.region(id);
    const header = DeltaHeader{ .magic = DELTA_MAGIC, .version = 1, .slot_offset = DELTA_HEADER_SIZE, .slot_count = 0, .journal_offset = DELTA_HEADER_SIZE, .journal_size = journal_size, .journal_tail = 0, .clean = 1, .flags = 0, .crc = 0 };
    try writeDeltaHeader(index.file, region.offset, header);
    try idx.activateRegion(index, id, region_size);
    const active = try index.region(id);
    return .{ .index = index, .region = active, .header = header };
}

pub fn openActive(index: *idx.IndexFile) !DeltaJournal {
    const id = index.activeDeltaRegionId();
    if (id == 0) return error.NotFound;
    const region = try index.region(id);
    const header = try readDeltaHeader(index.file, region.offset);
    return .{ .index = index, .region = region, .header = header };
}

pub fn truncateTail(self: *DeltaJournal, new_tail: u64) !void {
    if (new_tail > self.header.journal_tail) return error.InvalidArgument;
    self.header.journal_tail = new_tail;
    try writeDeltaHeader(self.index.file, self.region.offset, self.header);
    try pf.flushMetadata(self.index.file);
}

fn appendRecord(self: *DeltaJournal, op: DeltaJournalOp, key: fmt.Key128, info_in: fmt.IndexInfo, options: AppendOptions) !JournalRecord {
    if (!options.data_durable and op == .put) return error.InvalidArgument;
    while (!self.append_lock.tryLock()) std.atomic.spinLoopHint();
    defer self.append_lock.unlock();
    if (self.header.journal_tail + JOURNAL_RECORD_SIZE > self.header.journal_size) return error.NoSpace;
    var info = info_in;
    if (op == .delete) info.flags |= 1;
    const hval = fmt.mixHash128To64(key);
    const epoch = self.header.journal_tail / JOURNAL_RECORD_SIZE + 1;
    var payload_buf = encodePayload(.{ .h = hval, .key_hi = key.hi, .key_lo = key.lo, .info = info });
    var header_buf = encodeHeader(.{ .magic = JOURNAL_MAGIC, .version = 1, .op = op, .journal_epoch = epoch, .batch_id = options.batch_id, .record_size = JOURNAL_RECORD_SIZE, .header_crc = 0 });
    const header_crc = fmt.crc32c(&header_buf);
    fmt.writeU32Le(header_buf[28..32], header_crc);
    var footer_buf = encodeFooter(.{ .magic_commit = JOURNAL_COMMIT_MAGIC, .record_crc = recordCrc(&header_buf, &payload_buf) });
    const absolute = self.region.offset + self.header.journal_offset + self.header.journal_tail;
    try pf.pwritevAll(self.index.file, absolute, &.{ .{ .data = &header_buf }, .{ .data = &payload_buf }, .{ .data = &footer_buf } });
    self.header.journal_tail += JOURNAL_RECORD_SIZE;
    self.header.clean = 0;
    if (!options.defer_header) {
        try writeDeltaHeader(self.index.file, self.region.offset, self.header);
        if (options.durability == .sync) {
            try pf.flushData(self.index.file);
            try pf.flushMetadata(self.index.file);
        }
    }
    return .{ .op = op, .journal_epoch = epoch, .batch_id = options.batch_id, .key = key, .h = hval, .info = info };
}

pub fn writeDeltaHeader(file: pf.FileHandle, offset: u64, h: DeltaHeader) !void {
    var b = [_]u8{0} ** DELTA_HEADER_SIZE;
    fmt.writeU32Le(b[0..4], h.magic);
    fmt.writeU32Le(b[4..8], h.version);
    fmt.writeU64Le(b[8..16], h.slot_offset);
    fmt.writeU64Le(b[16..24], h.slot_count);
    fmt.writeU64Le(b[24..32], h.journal_offset);
    fmt.writeU64Le(b[32..40], h.journal_size);
    fmt.writeU64Le(b[40..48], h.journal_tail);
    fmt.writeU32Le(b[48..52], h.clean);
    fmt.writeU32Le(b[52..56], h.flags);
    fmt.writeU32Le(b[56..60], 0);
    const crc = fmt.crc32c(&b);
    fmt.writeU32Le(b[56..60], crc);
    try pf.pwriteAll(file, offset, &b);
}

pub fn readDeltaHeader(file: pf.FileHandle, offset: u64) !DeltaHeader {
    var b: [DELTA_HEADER_SIZE]u8 = undefined;
    if (try pf.preadAll(file, offset, &b) != b.len) return error.Corruption;
    const stored = fmt.readU32Le(b[56..60]);
    var c = b;
    fmt.writeU32Le(c[56..60], 0);
    if (fmt.crc32c(&c) != stored) return error.Corruption;
    const h = DeltaHeader{ .magic = fmt.readU32Le(b[0..4]), .version = fmt.readU32Le(b[4..8]), .slot_offset = fmt.readU64Le(b[8..16]), .slot_count = fmt.readU64Le(b[16..24]), .journal_offset = fmt.readU64Le(b[24..32]), .journal_size = fmt.readU64Le(b[32..40]), .journal_tail = fmt.readU64Le(b[40..48]), .clean = fmt.readU32Le(b[48..52]), .flags = fmt.readU32Le(b[52..56]), .crc = stored };
    if (h.magic != DELTA_MAGIC or h.version != 1 or h.journal_offset < DELTA_HEADER_SIZE or h.journal_tail > h.journal_size) return error.Corruption;
    return h;
}

fn encodeHeader(h: DeltaJournalRecordHeader) [JOURNAL_HEADER_SIZE]u8 {
    var b = [_]u8{0} ** JOURNAL_HEADER_SIZE;
    fmt.writeU32Le(b[0..4], h.magic);
    fmt.writeU16Le(b[4..6], h.version);
    fmt.writeU16Le(b[6..8], @intFromEnum(h.op));
    fmt.writeU64Le(b[8..16], h.journal_epoch);
    fmt.writeU64Le(b[16..24], h.batch_id);
    fmt.writeU32Le(b[24..28], h.record_size);
    fmt.writeU32Le(b[28..32], h.header_crc);
    return b;
}

fn decodeHeader(b: *const [JOURNAL_HEADER_SIZE]u8) !DeltaJournalRecordHeader {
    return .{ .magic = fmt.readU32Le(b[0..4]), .version = fmt.readU16Le(b[4..6]), .op = @enumFromInt(fmt.readU16Le(b[6..8])), .journal_epoch = fmt.readU64Le(b[8..16]), .batch_id = fmt.readU64Le(b[16..24]), .record_size = fmt.readU32Le(b[24..28]), .header_crc = fmt.readU32Le(b[28..32]) };
}

fn encodePayload(p: DeltaJournalPayload) [JOURNAL_PAYLOAD_SIZE]u8 {
    var b = [_]u8{0} ** JOURNAL_PAYLOAD_SIZE;
    fmt.writeU64Le(b[0..8], p.h);
    fmt.writeU64Le(b[8..16], p.key_hi);
    fmt.writeU64Le(b[16..24], p.key_lo);
    fmt.writeU32Le(b[24..28], p.info.data_db_id);
    fmt.writeU32Le(b[28..32], p.info.flags);
    fmt.writeU64Le(b[32..40], p.info.offset);
    fmt.writeU32Le(b[40..44], p.info.stored_size);
    fmt.writeU32Le(b[44..48], p.info.raw_size);
    fmt.writeU64Le(b[48..56], p.info.version);
    fmt.writeU32Le(b[56..60], p.info.crc);
    fmt.writeU16Le(b[60..62], p.info.codec);
    fmt.writeU16Le(b[62..64], p.info.reserved);
    return b;
}

fn decodePayload(b: *const [JOURNAL_PAYLOAD_SIZE]u8) DeltaJournalPayload {
    return .{ .h = fmt.readU64Le(b[0..8]), .key_hi = fmt.readU64Le(b[8..16]), .key_lo = fmt.readU64Le(b[16..24]), .info = .{ .data_db_id = fmt.readU32Le(b[24..28]), .flags = fmt.readU32Le(b[28..32]), .offset = fmt.readU64Le(b[32..40]), .stored_size = fmt.readU32Le(b[40..44]), .raw_size = fmt.readU32Le(b[44..48]), .version = fmt.readU64Le(b[48..56]), .crc = fmt.readU32Le(b[56..60]), .codec = fmt.readU16Le(b[60..62]), .reserved = fmt.readU16Le(b[62..64]) } };
}

fn encodeFooter(f: DeltaJournalRecordFooter) [JOURNAL_FOOTER_SIZE]u8 {
    var b = [_]u8{0} ** JOURNAL_FOOTER_SIZE;
    fmt.writeU32Le(b[0..4], f.magic_commit);
    fmt.writeU32Le(b[4..8], f.record_crc);
    return b;
}

fn decodeFooter(b: *const [JOURNAL_FOOTER_SIZE]u8) DeltaJournalRecordFooter {
    return .{ .magic_commit = fmt.readU32Le(b[0..4]), .record_crc = fmt.readU32Le(b[4..8]) };
}

fn recordCrc(header: *const [JOURNAL_HEADER_SIZE]u8, payload: *const [JOURNAL_PAYLOAD_SIZE]u8) u32 {
    var tmp: [JOURNAL_HEADER_SIZE + JOURNAL_PAYLOAD_SIZE + 4]u8 = undefined;
    @memcpy(tmp[0..JOURNAL_HEADER_SIZE], header);
    @memcpy(tmp[JOURNAL_HEADER_SIZE..][0..JOURNAL_PAYLOAD_SIZE], payload);
    fmt.writeU32Le(tmp[JOURNAL_HEADER_SIZE + JOURNAL_PAYLOAD_SIZE ..][0..4], JOURNAL_COMMIT_MAGIC);
    return fmt.crc32c(&tmp);
}

test "delta journal append scan corruption and truncate tail" {
    const testing = std.testing;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var index = try idx.createAt(tmp.dir, "index.db", [_]u8{0} ** 16);
    defer index.close() catch unreachable;
    var journal = try createActiveDelta(&index, 4096);
    const key: fmt.Key128 = .{ .hi = 1, .lo = 2 };
    const info = fmt.IndexInfo{ .data_db_id = 7, .flags = 0, .offset = 123, .stored_size = 9, .raw_size = 9, .version = 42, .crc = 99, .codec = 0, .reserved = 0 };
    _ = try journal.appendPut(key, info, .{ .durability = .sync });
    _ = try journal.appendDelete(.{ .hi = 3, .lo = 4 }, .{});
    var sc = journal.scanner();
    const r1 = (try sc.next()).?;
    try testing.expectEqual(.put, r1.op);
    try testing.expectEqual(key.hi, r1.key.hi);
    try testing.expectEqual(info.offset, r1.info.offset);
    const r2 = (try sc.next()).?;
    try testing.expectEqual(.delete, r2.op);
    try testing.expect((r2.info.flags & 1) != 0);
    try testing.expectEqual(@as(?JournalRecord, null), try sc.next());
    const last_good = sc.lastGoodTail();

    _ = try journal.appendPut(.{ .hi = 5, .lo = 6 }, info, .{});
    try pf.setLen(index.file, journal.region.offset + journal.header.journal_offset + journal.header.journal_tail - 2);
    var sc2 = journal.scanner();
    _ = try sc2.next();
    _ = try sc2.next();
    try testing.expectEqual(@as(?JournalRecord, null), try sc2.next());
    try testing.expectEqual(last_good, sc2.lastGoodTail());
    try truncateTail(&journal, last_good);
    var sc3 = journal.scanner();
    _ = try sc3.next();
    _ = try sc3.next();
    try testing.expectEqual(@as(?JournalRecord, null), try sc3.next());
}
