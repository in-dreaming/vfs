const std = @import("std");
const fmt = @import("format.zig");
const pf = @import("platform/file.zig");

pub const MANIFEST_MAGIC: u32 = 0x31464d44; // "DMF1"
pub const MANIFEST_SUPER_MAGIC: u32 = 0x31534d44; // "DMS1"
pub const MANIFEST_HEADER_SIZE: u64 = 80;
pub const MANIFEST_SUPER_SIZE: u64 = 56;
pub const SUPER_A_OFFSET: u64 = MANIFEST_HEADER_SIZE;
pub const SUPER_B_OFFSET: u64 = SUPER_A_OFFSET + MANIFEST_SUPER_SIZE;
pub const TABLE_OFFSET: u64 = 4096;
pub const TABLE_CAPACITY: u32 = 4096;
pub const TABLE_ENTRY_SIZE: u64 = 16;
pub const ENDIAN_LE: u32 = 0x01020304;

pub const ManifestHeader = extern struct {
    magic: u32,
    major_version: u16,
    minor_version: u16,
    endian: u32,
    header_size: u64,
    superblock_a_offset: u64,
    superblock_b_offset: u64,
    table_offset: u64,
    table_capacity: u32,
    reserved: u32,
    uuid: [16]u8,
    crc: u32,
};

pub const ManifestSuperBlock = extern struct {
    magic: u32,
    version: u32,
    epoch: u64,
    index_file_id: u32,
    data_file_count: u32,
    feature_flags: u64,
    schema_version: u64,
    clean_shutdown: u32,
    flags: u32,
    crc: u32,
};

pub const DataFileEntry = extern struct {
    file_id: u32,
    flags: u32,
    reserved0: u32,
    reserved1: u32,
};

pub const CreateOptions = struct {
    uuid: [16]u8 = [_]u8{0} ** 16,
    index_file_id: u32 = 0,
    initial_data_files: u32 = 1,
    feature_flags: u64 = 0,
    schema_version: u64 = 1,
};

pub const Manifest = struct {
    file: pf.FileHandle,
    uuid: [16]u8,
    super: ManifestSuperBlock,

    pub fn close(self: *Manifest) !void {
        if (!self.file.isOpen()) return;
        try pf.flushMetadata(self.file);
        pf.close(&self.file);
    }

    pub fn indexFileName(_: *const Manifest) []const u8 {
        return "index.db";
    }

    pub fn dataFileCount(self: *const Manifest) u32 {
        return self.super.data_file_count;
    }

    pub fn dataFileId(self: *const Manifest, index: u32) !u32 {
        if (index >= self.super.data_file_count) return error.NotFound;
        const entry = try readEntry(self.file, index);
        return entry.file_id;
    }

    pub fn dataFileName(_: *const Manifest, file_id: u32, buf: []u8) ![]const u8 {
        return std.fmt.bufPrint(buf, "data_{d:0>3}.db", .{file_id});
    }

    pub fn addDataFile(self: *Manifest, file_id: u32) !void {
        if (self.super.data_file_count >= TABLE_CAPACITY) return error.NoSpace;
        try writeEntry(self.file, self.super.data_file_count, .{
            .file_id = file_id,
            .flags = 0,
            .reserved0 = 0,
            .reserved1 = 0,
        });
        try pf.flushData(self.file);
        self.super.data_file_count += 1;
        self.super.epoch += 1;
        try writeSuper(self.file, if (self.super.epoch % 2 == 0) SUPER_A_OFFSET else SUPER_B_OFFSET, self.super);
        try pf.flushMetadata(self.file);
    }
};

pub fn create(path: []const u8, options: CreateOptions) !Manifest {
    var file = try pf.open(path, .{ .mode = .create_read_write, .create_parent_dirs = true });
    errdefer pf.close(&file);
    return initialize(file, options);
}

pub fn createAt(dir: std.Io.Dir, path: []const u8, options: CreateOptions) !Manifest {
    return createIn(.fromOs(dir), path, options);
}

pub fn createIn(dir: pf.Directory, path: []const u8, options: CreateOptions) !Manifest {
    var file = try pf.openIn(dir, path, .{ .mode = .create_read_write });
    errdefer pf.close(&file);
    return initialize(file, options);
}

pub fn open(path: []const u8) !Manifest {
    var file = try pf.open(path, .{ .mode = .read_write });
    errdefer pf.close(&file);
    return load(file);
}

pub fn openAt(dir: std.Io.Dir, path: []const u8) !Manifest {
    return openIn(.fromOs(dir), path);
}

pub fn openIn(dir: pf.Directory, path: []const u8) !Manifest {
    var file = try pf.openIn(dir, path, .{ .mode = .read_write });
    errdefer pf.close(&file);
    return load(file);
}

fn initialize(file: pf.FileHandle, options: CreateOptions) !Manifest {
    if (options.initial_data_files > TABLE_CAPACITY) return error.InvalidArgument;
    try pf.setLen(file, 0);
    try pf.preallocate(file, 0, TABLE_OFFSET + TABLE_ENTRY_SIZE * TABLE_CAPACITY);
    const header = ManifestHeader{
        .magic = MANIFEST_MAGIC,
        .major_version = 1,
        .minor_version = 0,
        .endian = ENDIAN_LE,
        .header_size = MANIFEST_HEADER_SIZE,
        .superblock_a_offset = SUPER_A_OFFSET,
        .superblock_b_offset = SUPER_B_OFFSET,
        .table_offset = TABLE_OFFSET,
        .table_capacity = TABLE_CAPACITY,
        .reserved = 0,
        .uuid = options.uuid,
        .crc = 0,
    };
    try writeHeader(file, header);
    var i: u32 = 0;
    while (i < options.initial_data_files) : (i += 1) {
        try writeEntry(file, i, .{ .file_id = i, .flags = 0, .reserved0 = 0, .reserved1 = 0 });
    }
    const sb = ManifestSuperBlock{
        .magic = MANIFEST_SUPER_MAGIC,
        .version = 1,
        .epoch = 1,
        .index_file_id = options.index_file_id,
        .data_file_count = options.initial_data_files,
        .feature_flags = options.feature_flags,
        .schema_version = options.schema_version,
        .clean_shutdown = 1,
        .flags = 0,
        .crc = 0,
    };
    try writeSuper(file, SUPER_A_OFFSET, sb);
    try writeSuper(file, SUPER_B_OFFSET, sb);
    try pf.flushMetadata(file);
    return .{ .file = file, .uuid = options.uuid, .super = sb };
}

fn load(file: pf.FileHandle) !Manifest {
    const header = try readHeader(file);
    if (header.magic != MANIFEST_MAGIC or header.major_version != 1 or header.endian != ENDIAN_LE) return error.Corruption;
    if (header.header_size != MANIFEST_HEADER_SIZE or header.table_offset != TABLE_OFFSET or header.table_capacity != TABLE_CAPACITY) return error.Corruption;
    const a = readSuper(file, SUPER_A_OFFSET) catch null;
    const b = readSuper(file, SUPER_B_OFFSET) catch null;
    const sb = if (a) |sa| if (b) |sb_b| if (sb_b.epoch > sa.epoch) sb_b else sa else sa else if (b) |sb_b| sb_b else return error.Corruption;
    if (sb.data_file_count > TABLE_CAPACITY) return error.Corruption;
    var i: u32 = 0;
    while (i < sb.data_file_count) : (i += 1) {
        const entry = try readEntry(file, i);
        if (entry.file_id != i and entry.file_id == std.math.maxInt(u32)) return error.Corruption;
    }
    return .{ .file = file, .uuid = header.uuid, .super = sb };
}

fn writeHeader(file: pf.FileHandle, h: ManifestHeader) !void {
    var buf = [_]u8{0} ** MANIFEST_HEADER_SIZE;
    fmt.writeU32Le(buf[0..4], h.magic);
    fmt.writeU16Le(buf[4..6], h.major_version);
    fmt.writeU16Le(buf[6..8], h.minor_version);
    fmt.writeU32Le(buf[8..12], h.endian);
    fmt.writeU64Le(buf[16..24], h.header_size);
    fmt.writeU64Le(buf[24..32], h.superblock_a_offset);
    fmt.writeU64Le(buf[32..40], h.superblock_b_offset);
    fmt.writeU64Le(buf[40..48], h.table_offset);
    fmt.writeU32Le(buf[48..52], h.table_capacity);
    fmt.writeU32Le(buf[52..56], h.reserved);
    @memcpy(buf[56..72], &h.uuid);
    fmt.writeU32Le(buf[72..76], 0);
    const crc = fmt.crc32c(&buf);
    fmt.writeU32Le(buf[72..76], crc);
    try pf.pwriteAll(file, 0, &buf);
}

fn readHeader(file: pf.FileHandle) !ManifestHeader {
    var buf: [MANIFEST_HEADER_SIZE]u8 = undefined;
    try readExact(file, 0, &buf);
    const stored_crc = fmt.readU32Le(buf[72..76]);
    var crc_buf = buf;
    fmt.writeU32Le(crc_buf[72..76], 0);
    if (fmt.crc32c(&crc_buf) != stored_crc) return error.Corruption;
    var uuid: [16]u8 = undefined;
    @memcpy(&uuid, buf[56..72]);
    return .{
        .magic = fmt.readU32Le(buf[0..4]),
        .major_version = fmt.readU16Le(buf[4..6]),
        .minor_version = fmt.readU16Le(buf[6..8]),
        .endian = fmt.readU32Le(buf[8..12]),
        .header_size = fmt.readU64Le(buf[16..24]),
        .superblock_a_offset = fmt.readU64Le(buf[24..32]),
        .superblock_b_offset = fmt.readU64Le(buf[32..40]),
        .table_offset = fmt.readU64Le(buf[40..48]),
        .table_capacity = fmt.readU32Le(buf[48..52]),
        .reserved = fmt.readU32Le(buf[52..56]),
        .uuid = uuid,
        .crc = stored_crc,
    };
}

fn writeSuper(file: pf.FileHandle, offset: u64, sb: ManifestSuperBlock) !void {
    var buf = [_]u8{0} ** MANIFEST_SUPER_SIZE;
    fmt.writeU32Le(buf[0..4], sb.magic);
    fmt.writeU32Le(buf[4..8], sb.version);
    fmt.writeU64Le(buf[8..16], sb.epoch);
    fmt.writeU32Le(buf[16..20], sb.index_file_id);
    fmt.writeU32Le(buf[20..24], sb.data_file_count);
    fmt.writeU64Le(buf[24..32], sb.feature_flags);
    fmt.writeU64Le(buf[32..40], sb.schema_version);
    fmt.writeU32Le(buf[40..44], sb.clean_shutdown);
    fmt.writeU32Le(buf[44..48], sb.flags);
    fmt.writeU32Le(buf[48..52], 0);
    const crc = fmt.crc32c(&buf);
    fmt.writeU32Le(buf[48..52], crc);
    try pf.pwriteAll(file, offset, &buf);
}

fn readSuper(file: pf.FileHandle, offset: u64) !ManifestSuperBlock {
    var buf: [MANIFEST_SUPER_SIZE]u8 = undefined;
    try readExact(file, offset, &buf);
    const stored_crc = fmt.readU32Le(buf[48..52]);
    var crc_buf = buf;
    fmt.writeU32Le(crc_buf[48..52], 0);
    if (fmt.crc32c(&crc_buf) != stored_crc) return error.Corruption;
    const sb = ManifestSuperBlock{
        .magic = fmt.readU32Le(buf[0..4]),
        .version = fmt.readU32Le(buf[4..8]),
        .epoch = fmt.readU64Le(buf[8..16]),
        .index_file_id = fmt.readU32Le(buf[16..20]),
        .data_file_count = fmt.readU32Le(buf[20..24]),
        .feature_flags = fmt.readU64Le(buf[24..32]),
        .schema_version = fmt.readU64Le(buf[32..40]),
        .clean_shutdown = fmt.readU32Le(buf[40..44]),
        .flags = fmt.readU32Le(buf[44..48]),
        .crc = stored_crc,
    };
    if (sb.magic != MANIFEST_SUPER_MAGIC or sb.version != 1) return error.Corruption;
    return sb;
}

fn writeEntry(file: pf.FileHandle, index: u32, entry: DataFileEntry) !void {
    var buf = [_]u8{0} ** TABLE_ENTRY_SIZE;
    fmt.writeU32Le(buf[0..4], entry.file_id);
    fmt.writeU32Le(buf[4..8], entry.flags);
    fmt.writeU32Le(buf[8..12], entry.reserved0);
    fmt.writeU32Le(buf[12..16], entry.reserved1);
    try pf.pwriteAll(file, TABLE_OFFSET + @as(u64, index) * TABLE_ENTRY_SIZE, &buf);
}

fn readEntry(file: pf.FileHandle, index: u32) !DataFileEntry {
    var buf: [TABLE_ENTRY_SIZE]u8 = undefined;
    try readExact(file, TABLE_OFFSET + @as(u64, index) * TABLE_ENTRY_SIZE, &buf);
    return .{
        .file_id = fmt.readU32Le(buf[0..4]),
        .flags = fmt.readU32Le(buf[4..8]),
        .reserved0 = fmt.readU32Le(buf[8..12]),
        .reserved1 = fmt.readU32Le(buf[12..16]),
    };
}

fn readExact(file: pf.FileHandle, offset: u64, dst: []u8) !void {
    if (try pf.preadAll(file, offset, dst) != dst.len) return error.Corruption;
}

comptime {
    std.debug.assert(@sizeOf(ManifestHeader) == MANIFEST_HEADER_SIZE);
    std.debug.assert(@sizeOf(ManifestSuperBlock) == MANIFEST_SUPER_SIZE);
    std.debug.assert(@sizeOf(DataFileEntry) == TABLE_ENTRY_SIZE);
}

test "manifest create open update double superblock corruption handling" {
    const testing = std.testing;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const uuid = [_]u8{ 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15 };

    var m = try createAt(tmp.dir, "manifest.db", .{ .uuid = uuid, .initial_data_files = 1, .feature_flags = 7, .schema_version = 9 });
    try testing.expectEqualSlices(u8, &uuid, &m.uuid);
    try testing.expectEqualStrings("index.db", m.indexFileName());
    try testing.expectEqual(@as(u32, 1), m.dataFileCount());
    try testing.expectEqual(@as(u32, 0), try m.dataFileId(0));
    try m.addDataFile(1);
    try testing.expectEqual(@as(u32, 2), m.dataFileCount());
    var name_buf: [32]u8 = undefined;
    try testing.expectEqualStrings("data_001.db", try m.dataFileName(1, &name_buf));
    try m.close();

    var reopened = try openAt(tmp.dir, "manifest.db");
    try testing.expectEqualSlices(u8, &uuid, &reopened.uuid);
    try testing.expectEqual(@as(u32, 2), reopened.dataFileCount());
    try testing.expectEqual(@as(u32, 1), try reopened.dataFileId(1));

    try pf.pwriteAll(reopened.file, SUPER_A_OFFSET, "BAD!");
    try reopened.close();
    var choose_b = try openAt(tmp.dir, "manifest.db");
    try testing.expectEqual(@as(u32, 1), choose_b.dataFileCount());

    var bad_super: [MANIFEST_SUPER_SIZE]u8 = undefined;
    try readExact(choose_b.file, SUPER_A_OFFSET, &bad_super);
    fmt.writeU64Le(bad_super[8..16], choose_b.super.epoch + 100);
    try pf.pwriteAll(choose_b.file, SUPER_A_OFFSET, &bad_super);
    try choose_b.close();
    var choose_old = try openAt(tmp.dir, "manifest.db");
    try testing.expectEqual(@as(u32, 1), choose_old.dataFileCount());

    try pf.setLen(choose_old.file, 10);
    pf.close(&choose_old.file);
    try testing.expectError(error.Corruption, openAt(tmp.dir, "manifest.db"));
}
