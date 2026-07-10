const std = @import("std");
const fmt = @import("../format.zig");
const kv = @import("../kv_db.zig");
const base_mod = @import("base_index.zig");
const delta_mod = @import("delta_index.zig");
const journal_mod = @import("delta_journal.zig");

pub const EntryState = union(enum) {
    put: fmt.IndexInfo,
    deleted,
};

fn keyId(key: fmt.Key128) u128 {
    return (@as(u128, key.hi) << 64) | key.lo;
}

fn keyFromId(id: u128) fmt.Key128 {
    return .{ .hi = @intCast(id >> 64), .lo = @intCast(id & 0xffffffffffffffff) };
}

pub fn run(db: *kv.KvDb, allocator: std.mem.Allocator) !void {
    const out = try collectLiveEntries(db, allocator);
    defer allocator.free(out);
    _ = try base_mod.build(db.index, allocator, out);
}

pub fn collectLiveEntries(db: *kv.KvDb, allocator: std.mem.Allocator) ![]base_mod.BuildEntry {
    var map = std.AutoHashMap(u128, EntryState).init(allocator);
    defer map.deinit();

    var old_base = base_mod.open(db.index) catch null;
    if (old_base) |*base| {
        defer base.close();
        const entries = try base_mod.collectEntries(base, allocator);
        defer allocator.free(entries);
        for (entries) |e| try map.put(keyId(e.key), .{ .put = e.info });
    }

    const records = try journal_mod.collectCommittedRecords(&db.delta.journal, allocator);
    defer allocator.free(records);
    for (records) |rec| {
        switch (rec.op) {
            .put => try map.put(keyId(rec.key), .{ .put = rec.info }),
            .delete => try map.put(keyId(rec.key), .deleted),
            else => {},
        }
    }

    var out = std.ArrayList(base_mod.BuildEntry).empty;
    errdefer out.deinit(allocator);
    var it = map.iterator();
    while (it.next()) |entry| {
        switch (entry.value_ptr.*) {
            .put => |info| try out.append(allocator, .{ .key = keyFromId(entry.key_ptr.*), .info = info }),
            .deleted => {},
        }
    }

    return try out.toOwnedSlice(allocator);
}

test "checkpoint merges delta into new base" {
    const testing = std.testing;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var db = try kv.KvDb.openAt(tmp.dir, .{});
    defer db.close() catch unreachable;
    const a: fmt.Key128 = .{ .hi = 1, .lo = 1 };
    const b: fmt.Key128 = .{ .hi = 2, .lo = 2 };
    const c: fmt.Key128 = .{ .hi = 3, .lo = 3 };
    try db.put(a, "old-a", .{});
    try db.put(b, "old-b", .{});
    try run(&db, testing.allocator);
    try db.put(a, "new-a", .{});
    try db.delete(b, .{});
    try db.put(c, "new-c", .{});
    try run(&db, testing.allocator);
    var buf: [8]u8 = undefined;
    try testing.expectEqual(@as(usize, 5), try db.getInto(a, &buf));
    try testing.expectEqualStrings("new-a", buf[0..5]);
    try testing.expectError(error.NotFound, db.getSize(b));
    try testing.expectEqual(@as(usize, 5), try db.getInto(c, &buf));
    try testing.expectEqualStrings("new-c", buf[0..5]);
}
