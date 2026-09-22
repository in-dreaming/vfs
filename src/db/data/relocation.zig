const std = @import("std");
const fmt = @import("../format.zig");
const kv = @import("../kv_db.zig");
const data_file = @import("data_file.zig");
const alloc_mod = @import("allocator.zig");
const pf = @import("../platform/file.zig");

pub const RelocateResult = enum {
    moved,
    cas_failed,
    deleted,
};

pub fn relocateKey(db: *kv.KvDb, allocator: *alloc_mod.Allocator, key: fmt.Key128, expected_offset: u64) !RelocateResult {
    const size = db.getSize(key) catch |err| switch (err) {
        error.NotFound => return .deleted,
        else => |e| return e,
    };
    const buf = try allocator.allocator.alloc(u8, size);
    defer allocator.allocator.free(buf);
    _ = try db.getInto(key, buf);
    // Relocation stays inside the record's own shard.
    const shard: u32 = switch (db.delta.lookup(key) catch .not_found) {
        .found => |info| info.data_db_id,
        else => blk: {
            const base = db.base orelse break :blk 0;
            const info = base.lookup(key) catch break :blk 0;
            break :blk info.data_db_id;
        },
    };
    const data = try db.dataFile(shard);
    const current_meta = data_file.readMeta(data, expected_offset) catch return .cas_failed;
    if (current_meta.key.hi != key.hi or current_meta.key.lo != key.lo) return .cas_failed;
    const new_rec = try data_file.append(data, key, buf, .{ .version = current_meta.version + 1, .durability = .sync });
    const now = db.delta.lookup(key) catch .not_found;
    switch (now) {
        .found => |info| if (info.offset != expected_offset) {
            try allocator.retire(.{ .offset = new_rec.offset, .size = new_rec.stored_size });
            return .cas_failed;
        },
        .deleted => {
            try allocator.retire(.{ .offset = new_rec.offset, .size = new_rec.stored_size });
            return .deleted;
        },
        .not_found => {},
    }
    const info = fmt.IndexInfo{ .data_db_id = shard, .flags = 0, .offset = new_rec.offset, .stored_size = new_rec.stored_size, .raw_size = new_rec.raw_size, .version = new_rec.version, .crc = new_rec.crc, .codec = 0, .reserved = 0 };
    try db.delta.put(key, info, .{ .durability = .sync, .data_durable = true });
    try allocator.retire(.{ .offset = expected_offset, .size = current_meta.aligned_size });
    return .moved;
}

pub fn safeTruncate(db: *kv.KvDb, allocator: *alloc_mod.Allocator, tail_free: alloc_mod.Block) !bool {
    if (allocator.epoch.readers != 0) return false;
    const len = try pf.len(db.data.file);
    if (tail_free.offset + tail_free.size != len) return false;
    try pf.setLen(db.data.file, tail_free.offset);
    try pf.flushMetadata(db.data.file);
    db.data.logical_tail = @min(db.data.logical_tail, tail_free.offset);
    return true;
}

test "relocation cas and safe truncate" {
    const testing = std.testing;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var db = try kv.KvDb.openAt(tmp.dir, .{});
    defer db.close() catch unreachable;
    var allocator = alloc_mod.Allocator.init(testing.allocator, data_file.RECORD_AREA_OFFSET);
    defer allocator.deinit();
    const key: fmt.Key128 = .{ .hi = 1, .lo = 2 };
    try db.put(key, "abc", .{});
    try db.commitPending(null);
    const meta = try data_file.readMeta(&db.data, data_file.RECORD_AREA_OFFSET);
    try testing.expectEqual(.moved, try relocateKey(&db, &allocator, key, meta.offset));
    var buf: [3]u8 = undefined;
    try testing.expectEqual(@as(usize, 3), try db.getInto(key, &buf));
    try testing.expectEqualStrings("abc", &buf);
    try testing.expect(allocator.retired.items.len > 0);

    try db.put(key, "new", .{});
    try db.commitPending(null);
    try testing.expectEqual(.cas_failed, try relocateKey(&db, &allocator, key, meta.offset));
    try db.delete(key, .{});
    try testing.expectEqual(.deleted, try relocateKey(&db, &allocator, key, meta.offset));

    const before = try pf.len(db.data.file);
    const reader = allocator.epoch.enter();
    _ = reader;
    try testing.expect(!try safeTruncate(&db, &allocator, .{ .offset = before - 16, .size = 16 }));
    allocator.epoch.exit();
    try pf.pwriteAll(db.data.file, before, &([_]u8{0} ** 16));
    try testing.expect(try safeTruncate(&db, &allocator, .{ .offset = before, .size = 16 }));
    try testing.expectEqual(before, try pf.len(db.data.file));
}
