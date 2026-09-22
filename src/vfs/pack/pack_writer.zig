const std = @import("std");
const kv = @import("db_internal").kv_db;
const object_key = @import("../object_key.zig");

pub const ObjectIdentity = struct {
    kind: Kind,
    file_entry: u64 = 0,
    block_index: u32 = 0,
    page_index: u32 = 0,

    pub const Kind = enum(u8) {
        pack_manifest = 1,
        path_index = 2,
        directory_manifest = 3,
        file_manifest = 4,
        page = 5,
        entry_tombstone = 6,
        patch_intent = 7,
        /// Overlay marker that hides a base page (same key as the page).
        page_placeholder = 8,
    };
};

pub const CreateOptions = struct {
    /// Data shards for a brand new pack. Ignored when the pack already exists.
    shards: u32 = 1,
    durability: @import("db_internal").format.Durability = .sync,
};

pub const PackWriter = struct {
    db: kv.KvDb,
    keys: std.AutoHashMap(u64, ObjectIdentity),

    pub fn create(allocator: std.mem.Allocator, output_path: []const u8) !PackWriter {
        return createWithOptions(allocator, output_path, .{});
    }

    pub fn createWithOptions(allocator: std.mem.Allocator, output_path: []const u8, options: CreateOptions) !PackWriter {
        const db = try kv.KvDb.open(output_path, .{ .durability = options.durability, .create_if_missing = true, .mode = .read_write, .data_file_count = options.shards });
        return .{ .db = db, .keys = std.AutoHashMap(u64, ObjectIdentity).init(allocator) };
    }

    pub fn close(self: *PackWriter) !void {
        try self.db.commitPending(.sync);
        try self.db.close();
        self.keys.deinit();
    }

    pub fn abort(self: *PackWriter) void {
        self.db.discardPending();
        self.db.close() catch {};
        self.keys.deinit();
    }

    pub fn putObject(self: *PackWriter, key: u64, identity: ObjectIdentity, data: []const u8) !void {
        if (object_key.isReservedKey(key) and !isReservedIdentity(identity)) return error.KeyCollision;
        if (self.keys.get(key)) |existing| {
            if (!identityEqual(existing, identity)) return error.KeyCollision;
        } else {
            try self.keys.put(key, identity);
        }

        var key_bytes = object_key.encodeDbKey(key);
        // Singletons go to shard 0; everything belonging to a file shares
        // that file's shard (see object_key.fileShard).
        const shard: u32 = if (identity.file_entry == 0) 0 else object_key.fileShard(identity.file_entry, self.db.shardCount());
        try self.db.putBytes(&key_bytes, data, .{ .durability = .sync, .shard = shard });
    }

    pub fn putPackManifest(self: *PackWriter, data: []const u8) !void {
        try self.putObject(object_key.packManifestKey(), .{ .kind = .pack_manifest }, data);
    }

    pub fn putPathIndex(self: *PackWriter, data: []const u8) !void {
        try self.putObject(object_key.pathIndexKey(), .{ .kind = .path_index }, data);
    }

    pub fn putFileManifest(self: *PackWriter, file_entry: u64, data: []const u8) !void {
        try self.putObject(try object_key.fileManifestKey(file_entry), .{ .kind = .file_manifest, .file_entry = file_entry }, data);
    }

    pub fn putPage(self: *PackWriter, file_entry: u64, block_index: u32, page_index: u32, data: []const u8) !void {
        try self.putObject(try object_key.pageKey(file_entry, block_index, page_index), .{ .kind = .page, .file_entry = file_entry, .block_index = block_index, .page_index = page_index }, data);
    }

    pub fn putEntryTombstone(self: *PackWriter, file_entry: u64, data: []const u8) !void {
        try self.putObject(try object_key.entryTombstoneKey(file_entry), .{ .kind = .entry_tombstone, .file_entry = file_entry }, data);
    }

    pub fn putPatchIntent(self: *PackWriter, data: []const u8) !void {
        try self.putObject(object_key.patchIntentKey(), .{ .kind = .patch_intent }, data);
    }

    pub fn putPagePlaceholder(self: *PackWriter, file_entry: u64, block_index: u32, page_index: u32, data: []const u8) !void {
        try self.putObject(try object_key.pageKey(file_entry, block_index, page_index), .{ .kind = .page_placeholder, .file_entry = file_entry, .block_index = block_index, .page_index = page_index }, data);
    }

    pub fn deleteObject(self: *PackWriter, key: u64) !void {
        var key_bytes = object_key.encodeDbKey(key);
        try self.db.deleteBytes(&key_bytes, .{ .durability = .sync });
    }
};

fn isReservedIdentity(identity: ObjectIdentity) bool {
    return switch (identity.kind) {
        .pack_manifest, .path_index, .directory_manifest, .patch_intent => true,
        else => false,
    };
}

fn identityEqual(a: ObjectIdentity, b: ObjectIdentity) bool {
    // A page and its placeholder share one key on purpose (overlay delete).
    const kind_ok = a.kind == b.kind or
        (a.kind == .page and b.kind == .page_placeholder) or
        (a.kind == .page_placeholder and b.kind == .page);
    return kind_ok and
        a.file_entry == b.file_entry and
        a.block_index == b.block_index and
        a.page_index == b.page_index;
}

test "pack writer detects object identity collision before DB write" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = "zig-cache-vfs-writer-collision-test";
    const io = std.Io.Threaded.global_single_threaded.io();
    _ = std.Io.Dir.cwd().deleteTree(io, path) catch {};
    defer _ = std.Io.Dir.cwd().deleteTree(io, path) catch {};

    var writer = try PackWriter.create(allocator, path);
    defer writer.close() catch {};
    try writer.putObject(0xabcdef, .{ .kind = .file_manifest, .file_entry = 1 }, "one");
    try std.testing.expectError(error.KeyCollision, writer.putObject(0xabcdef, .{ .kind = .file_manifest, .file_entry = 2 }, "two"));
}
