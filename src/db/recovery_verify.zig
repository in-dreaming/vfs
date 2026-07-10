const std = @import("std");
const fmt = @import("format.zig");
const kv = @import("kv_db.zig");
const data_mod = @import("data/data_file.zig");
const alloc_mod = @import("data/allocator.zig");
const index_mod = @import("index/index_file.zig");
const base_mod = @import("index/base_index.zig");
const delta_mod = @import("index/delta_index.zig");
const journal_mod = @import("index/delta_journal.zig");
const checkpoint_mod = @import("index/checkpoint.zig");
const pf = @import("platform/file.zig");

pub const VerifyIssueKind = enum {
    corruption,
    checksum_mismatch,
    dangling_index,
    orphan_record,
    duplicate_key,
    invalid_superblock,
    invalid_region,
    invalid_record,
};

pub const VerifyIssue = struct {
    kind: VerifyIssueKind,
    file_id: u32,
    offset: u64,
    key: ?fmt.Key128,
    message_code: u32,
};

pub const VerifyReport = struct {
    allocator: std.mem.Allocator,
    issues: std.ArrayList(VerifyIssue),

    pub fn init(allocator: std.mem.Allocator) VerifyReport {
        return .{ .allocator = allocator, .issues = .empty };
    }

    pub fn deinit(self: *VerifyReport) void {
        self.issues.deinit(self.allocator);
    }

    pub fn ok(self: *const VerifyReport) bool {
        return self.issues.items.len == 0;
    }

    fn add(self: *VerifyReport, issue: VerifyIssue) !void {
        try self.issues.append(self.allocator, issue);
    }
};

pub fn recoverAt(dir: std.Io.Dir) !void {
    var db = try kv.KvDb.openAt(dir, .{});
    try delta_mod.recover(&db.delta);
    try db.close();
}

pub fn verifyAt(dir: std.Io.Dir, allocator: std.mem.Allocator) !VerifyReport {
    var report = VerifyReport.init(allocator);
    var db = kv.KvDb.openAt(dir, .{}) catch |err| {
        try report.add(.{ .kind = if (err == error.Corruption) .corruption else .invalid_superblock, .file_id = 0, .offset = 0, .key = null, .message_code = 1 });
        return report;
    };
    defer db.close() catch {};

    index_mod.verify(db.index) catch |err| {
        _ = @errorName(err);
        try report.add(.{ .kind = .invalid_region, .file_id = 0, .offset = 0, .key = null, .message_code = 2 });
    };

    var live_offsets = std.AutoHashMap(u64, fmt.Key128).init(allocator);
    defer live_offsets.deinit();

    const live_entries = checkpoint_mod.collectLiveEntries(&db, allocator) catch |err| {
        try report.add(.{ .kind = if (err == error.Corruption) .corruption else .invalid_record, .file_id = 0, .offset = 0, .key = null, .message_code = 3 });
        return report;
    };
    defer allocator.free(live_entries);
    for (live_entries) |e| try live_offsets.put(e.info.offset, e.key);

    var free_blocks = std.ArrayList(alloc_mod.Block).empty;
    defer free_blocks.deinit(allocator);
    const sb = data_mod.currentSuper(&db.data) catch |err| {
        try report.add(.{ .kind = if (err == error.Corruption) .corruption else .invalid_superblock, .file_id = 0, .offset = 0, .key = null, .message_code = 8 });
        return report;
    };
    if (sb.allocator_checkpoint_offset != 0 or sb.allocator_checkpoint_size != 0) {
        if (sb.allocator_checkpoint_offset < data_mod.ALLOCATOR_CHECKPOINT_OFFSET or sb.allocator_checkpoint_offset + sb.allocator_checkpoint_size > data_mod.RECORD_AREA_OFFSET) {
            try report.add(.{ .kind = .invalid_superblock, .file_id = 0, .offset = sb.allocator_checkpoint_offset, .key = null, .message_code = 9 });
        } else {
            var data_allocator = alloc_mod.Allocator.readCheckpoint(allocator, db.data.file, sb.allocator_checkpoint_offset) catch |err| {
                try report.add(.{ .kind = if (err == error.Corruption) .corruption else .invalid_superblock, .file_id = 0, .offset = sb.allocator_checkpoint_offset, .key = null, .message_code = 10 });
                return report;
            };
            defer data_allocator.deinit();
            for (data_allocator.free.items) |b| try free_blocks.append(allocator, b);
        }
    }

    var it = live_offsets.iterator();
    while (it.next()) |entry| {
        const meta = data_mod.verifyRecord(&db.data, entry.key_ptr.*) catch |err| {
            try report.add(.{ .kind = if (err == error.ChecksumMismatch) .checksum_mismatch else .dangling_index, .file_id = 0, .offset = entry.key_ptr.*, .key = entry.value_ptr.*, .message_code = 4 });
            continue;
        };
        if (meta.key.hi != entry.value_ptr.hi or meta.key.lo != entry.value_ptr.lo) {
            try report.add(.{ .kind = .dangling_index, .file_id = 0, .offset = entry.key_ptr.*, .key = entry.value_ptr.*, .message_code = 5 });
        }
    }

    var off = data_mod.RECORD_AREA_OFFSET;
    while (off < db.data.logical_tail) {
        const meta = data_mod.verifyRecord(&db.data, off) catch |err| {
            try report.add(.{ .kind = if (err == error.ChecksumMismatch) .checksum_mismatch else .invalid_record, .file_id = 0, .offset = off, .key = null, .message_code = 6 });
            break;
        };
        if (!live_offsets.contains(off) and !blockCovers(free_blocks.items, off, meta.aligned_size)) {
            try report.add(.{ .kind = .orphan_record, .file_id = 0, .offset = off, .key = meta.key, .message_code = 7 });
        }
        off += meta.aligned_size;
    }

    return report;
}

fn blockCovers(blocks: []const alloc_mod.Block, offset: u64, size: u64) bool {
    for (blocks) |b| {
        if (b.offset <= offset and offset + size <= b.offset + b.size) return true;
    }
    return false;
}

test "recovery verify clean orphan dirty replay and checksum" {
    const testing = std.testing;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var db = try kv.KvDb.openAt(tmp.dir, .{});
    const key: fmt.Key128 = .{ .hi = 1, .lo = 2 };
    try db.put(key, "abc", .{});
    var report = try verifyAt(tmp.dir, testing.allocator);
    defer report.deinit();
    try testing.expect(report.ok());

    _ = try data_mod.append(&db.data, .{ .hi = 9, .lo = 9 }, "orphan", .{ .version = 1 });
    var report2 = try verifyAt(tmp.dir, testing.allocator);
    defer report2.deinit();
    try testing.expect(!report2.ok());
    try testing.expectEqual(.orphan_record, report2.issues.items[0].kind);

    try db.close();
    var db2 = try kv.KvDb.openAt(tmp.dir, .{});
    try db2.put(.{ .hi = 3, .lo = 4 }, "xyz", .{});
    db2.delta.journal.header.clean = 0;
    try journal_mod.writeDeltaHeader(db2.index.file, db2.delta.journal.region.offset, db2.delta.journal.header);
    try db2.close();
    try recoverAt(tmp.dir);
    var db3 = try kv.KvDb.openAt(tmp.dir, .{});
    var buf: [3]u8 = undefined;
    try testing.expectEqual(@as(usize, 3), try db3.getInto(.{ .hi = 3, .lo = 4 }, &buf));

    const corrupt_off = data_mod.RECORD_AREA_OFFSET + data_mod.RECORD_HEADER_SIZE;
    try pf.pwriteAll(db3.data.file, corrupt_off, "Z");
    var report3 = try verifyAt(tmp.dir, testing.allocator);
    defer report3.deinit();
    try testing.expect(!report3.ok());
    try db3.close();
}

test "crash matrix detects data record truncated mid write" {
    const testing = std.testing;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var db = try kv.KvDb.openAt(tmp.dir, .{});
    defer db.close() catch {};

    const key: fmt.Key128 = .{ .hi = 11, .lo = 22 };
    try db.put(key, "payload-that-will-be-cut", .{});
    try db.commitPending(.sync);

    const truncated_len = data_mod.RECORD_AREA_OFFSET + data_mod.RECORD_HEADER_SIZE + 3;
    try pf.setLen(db.data.file, truncated_len);
    try pf.flushMetadata(db.data.file);

    var report = try verifyAt(tmp.dir, testing.allocator);
    defer report.deinit();
    try testing.expect(!report.ok());
}

test "crash matrix recovers index journal tail with partial batch commit" {
    const testing = std.testing;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var db = try kv.KvDb.openAt(tmp.dir, .{});
    defer db.close() catch {};

    const good_key: fmt.Key128 = .{ .hi = 1, .lo = 1 };
    try db.put(good_key, "good", .{});
    try db.commitPending(.sync);

    const bad_key: fmt.Key128 = .{ .hi = 2, .lo = 2 };
    const r = try data_mod.append(&db.data, bad_key, "bad", .{ .version = 1, .durability = .sync });
    const info = fmt.IndexInfo{ .data_db_id = 0, .flags = 0, .offset = r.offset, .stored_size = r.stored_size, .raw_size = r.raw_size, .version = r.version, .crc = r.crc, .codec = r.codec, .reserved = 0 };

    const batch_id = db.nextBatchIdNoLock();
    _ = try db.delta.journal.appendBatchBegin(batch_id, .{ .durability = .none });
    _ = try db.delta.journal.appendPut(bad_key, info, .{ .durability = .none, .batch_id = batch_id, .data_durable = true });
    const commit_start = db.delta.journal.header.journal_tail;
    _ = try db.delta.journal.appendBatchCommit(batch_id, .{ .durability = .none });

    var zero_footer = [_]u8{0} ** journal_mod.JOURNAL_FOOTER_SIZE;
    const footer_off = db.delta.journal.region.offset + db.delta.journal.header.journal_offset + commit_start + journal_mod.JOURNAL_HEADER_SIZE + journal_mod.JOURNAL_PAYLOAD_SIZE;
    try pf.pwriteAll(db.delta.journal.index.file, footer_off, &zero_footer);
    db.delta.journal.header.clean = 0;
    try journal_mod.writeDeltaHeader(db.delta.journal.index.file, db.delta.journal.region.offset, db.delta.journal.header);

    try delta_mod.recover(&db.delta);

    try testing.expectEqual(@as(u64, 4), try db.getSize(good_key));
    try testing.expectError(error.NotFound, db.getSize(bad_key));
    try testing.expectEqual(commit_start, db.delta.journal.header.journal_tail);
}

test "optimize folds deletes into base and persists allocator free holes" {
    const testing = std.testing;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var db = try kv.KvDb.openAt(tmp.dir, .{ .max_delta_entries = 128 });
    const keep: fmt.Key128 = .{ .hi = 10, .lo = 1 };
    const overwrite: fmt.Key128 = .{ .hi = 10, .lo = 2 };
    const deleted_tail: fmt.Key128 = .{ .hi = 10, .lo = 3 };

    try db.put(keep, "keep", .{});
    try db.put(overwrite, "old-value", .{});
    try db.commitPending(.sync);
    const tail_before_overwrite = db.data.logical_tail;

    try db.put(overwrite, "new-value", .{});
    try db.put(deleted_tail, "tail-delete", .{});
    try db.commitPending(.sync);
    try db.delete(deleted_tail, .{});
    try db.commitPending(.sync);
    const tail_before_optimize = db.data.logical_tail;

    var before = try verifyAt(tmp.dir, testing.allocator);
    defer before.deinit();
    try testing.expect(!before.ok());

    try db.optimize();
    try testing.expect(db.data.logical_tail < tail_before_optimize);
    try testing.expect(db.data.logical_tail >= tail_before_overwrite);
    try testing.expectError(error.NotFound, db.getSize(deleted_tail));
    var buf: [16]u8 = undefined;
    try testing.expectEqual(@as(usize, 9), try db.getInto(overwrite, &buf));
    try testing.expectEqualStrings("new-value", buf[0..9]);

    var after = try verifyAt(tmp.dir, testing.allocator);
    defer after.deinit();
    try testing.expect(after.ok());

    const sb = try data_mod.currentSuper(&db.data);
    try testing.expect(sb.allocator_checkpoint_offset != 0);
    try testing.expect(sb.allocator_checkpoint_size != 0);
    try testing.expect(sb.free_bytes > 0);

    try db.close();
    var reopened = try kv.KvDb.openAt(tmp.dir, .{ .max_delta_entries = 128 });
    defer reopened.close() catch unreachable;
    try testing.expectError(error.NotFound, reopened.getSize(deleted_tail));
    try testing.expectEqual(@as(usize, 9), try reopened.getInto(overwrite, &buf));
    var reopened_report = try verifyAt(tmp.dir, testing.allocator);
    defer reopened_report.deinit();
    try testing.expect(reopened_report.ok());
}
