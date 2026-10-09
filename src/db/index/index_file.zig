const std = @import("std");
const fmt = @import("../format.zig");
const pf = @import("../platform/file.zig");

pub const INDEX_MAGIC: u32 = 0x31584449; // "IDX1"
pub const INDEX_SUPER_MAGIC: u32 = 0x31535849; // "IXS1"
pub const HEADER_SIZE: u64 = 96;
pub const SUPER_SIZE: u64 = 72;
pub const SUPER_A_OFFSET: u64 = HEADER_SIZE;
pub const SUPER_B_OFFSET: u64 = SUPER_A_OFFSET + SUPER_SIZE;
pub const REGION_DIR_OFFSET: u64 = 4096;
pub const REGION_CAPACITY: u32 = 4096;
pub const REGION_DESC_SIZE: u64 = 56;
pub const REGION_AREA_OFFSET: u64 = 262144;
pub const ALIGNMENT: u64 = 65536;
pub const ENDIAN_LE: u32 = 0x01020304;

pub const RegionType = enum(u32) {
    free = 0,
    base_index = 1,
    delta = 2,
    old_base = 3,
    reserved = 4,
};

pub const RegionState = enum(u32) {
    free = 0,
    building = 1,
    active = 2,
    checkpointing = 3,
    retired = 4,
    pending_reclaim = 5,
};

pub const IndexFileHeader = extern struct {
    magic: u32,
    major_version: u16,
    minor_version: u16,
    endian: u32,
    pointer_size: u32,
    file_header_size: u64,
    superblock_a_offset: u64,
    superblock_b_offset: u64,
    region_directory_offset: u64,
    region_capacity: u32,
    region_desc_size: u32,
    region_area_offset: u64,
    alignment: u64,
    uuid: [16]u8,
    crc: u32,
};

pub const IndexSuperBlock = extern struct {
    magic: u32,
    version: u32,
    epoch: u64,
    file_size: u64,
    active_base_region_id: u32,
    active_delta_region_id: u32,
    checkpoint_delta_region_id: u32,
    reserved0: u32,
    region_directory_epoch: u64,
    last_committed_journal_epoch: u64,
    clean_shutdown: u32,
    flags: u32,
    crc: u32,
};

pub const RegionDesc = extern struct {
    id: u32,
    region_type: RegionType,
    state: RegionState,
    flags: u32,
    offset: u64,
    size: u64,
    used_size: u64,
    epoch: u64,
    crc: u32,
    reserved: u32,
};

pub const IndexFile = struct {
    file: pf.FileHandle,
    super: IndexSuperBlock,

    pub fn close(self: *IndexFile) !void {
        if (!self.file.isOpen()) return;
        if (self.file.writable) try pf.flushMetadata(self.file);
        pf.close(&self.file);
    }

    pub fn activeBaseRegionId(self: *const IndexFile) u32 {
        return self.super.active_base_region_id;
    }

    pub fn activeDeltaRegionId(self: *const IndexFile) u32 {
        return self.super.active_delta_region_id;
    }

    pub fn checkpointDeltaRegionId(self: *const IndexFile) u32 {
        return self.super.checkpoint_delta_region_id;
    }

    pub fn region(self: *const IndexFile, id: u32) !RegionDesc {
        return readRegion(self.file, id);
    }
};

pub fn createAt(dir: std.Io.Dir, path: []const u8, uuid: [16]u8) !IndexFile {
    return createIn(.fromOs(dir), path, uuid);
}

pub fn createIn(dir: pf.Directory, path: []const u8, uuid: [16]u8) !IndexFile {
    var file = try pf.openIn(dir, path, .{ .mode = .create_read_write });
    errdefer pf.close(&file);
    try pf.setLen(file, 0);
    try pf.preallocate(file, 0, REGION_AREA_OFFSET);
    const header = IndexFileHeader{
        .magic = INDEX_MAGIC,
        .major_version = 1,
        .minor_version = 0,
        .endian = ENDIAN_LE,
        .pointer_size = @sizeOf(usize),
        .file_header_size = HEADER_SIZE,
        .superblock_a_offset = SUPER_A_OFFSET,
        .superblock_b_offset = SUPER_B_OFFSET,
        .region_directory_offset = REGION_DIR_OFFSET,
        .region_capacity = REGION_CAPACITY,
        .region_desc_size = REGION_DESC_SIZE,
        .region_area_offset = REGION_AREA_OFFSET,
        .alignment = ALIGNMENT,
        .uuid = uuid,
        .crc = 0,
    };
    try writeHeader(file, header);
    var i: u32 = 0;
    while (i < REGION_CAPACITY) : (i += 1) try writeRegion(file, .{
        .id = i,
        .region_type = .free,
        .state = .free,
        .flags = 0,
        .offset = 0,
        .size = 0,
        .used_size = 0,
        .epoch = 0,
        .crc = 0,
        .reserved = 0,
    });
    const sb = IndexSuperBlock{
        .magic = INDEX_SUPER_MAGIC,
        .version = 1,
        .epoch = 1,
        .file_size = REGION_AREA_OFFSET,
        .active_base_region_id = 0,
        .active_delta_region_id = 0,
        .checkpoint_delta_region_id = 0,
        .reserved0 = 0,
        .region_directory_epoch = 1,
        .last_committed_journal_epoch = 0,
        .clean_shutdown = 1,
        .flags = 0,
        .crc = 0,
    };
    try writeSuper(file, SUPER_A_OFFSET, sb);
    try writeSuper(file, SUPER_B_OFFSET, sb);
    try pf.flushMetadata(file);
    return .{ .file = file, .super = sb };
}

pub fn openAt(dir: std.Io.Dir, path: []const u8) !IndexFile {
    return openIn(.fromOs(dir), path);
}

pub fn openIn(dir: pf.Directory, path: []const u8) !IndexFile {
    return openInMode(dir, path, .read_write);
}

pub fn openInMode(dir: pf.Directory, path: []const u8, mode: pf.OpenMode) !IndexFile {
    if (mode == .create_read_write) return error.InvalidArgument;
    var file = try pf.openIn(dir, path, .{ .mode = mode });
    errdefer pf.close(&file);
    const header = try readHeader(file);
    if (header.magic != INDEX_MAGIC or header.major_version != 1 or header.endian != ENDIAN_LE) return error.Corruption;
    const a = readSuper(file, SUPER_A_OFFSET) catch null;
    const b = readSuper(file, SUPER_B_OFFSET) catch null;
    const sb = if (a) |sa| if (b) |sb_b| if (sb_b.epoch > sa.epoch) sb_b else sa else sa else if (b) |sb_b| sb_b else return error.Corruption;
    var index = IndexFile{ .file = file, .super = sb };
    try verify(&index);
    return index;
}

pub fn allocateRegion(index: *IndexFile, kind: RegionType, size: u64) !u32 {
    const aligned_size = try fmt.alignUp(size, ALIGNMENT);
    const file_len = try pf.len(index.file);
    const offset = try fmt.alignUp(file_len, ALIGNMENT);
    var id: u32 = 1;
    while (id < REGION_CAPACITY) : (id += 1) {
        const r = readRegion(index.file, id) catch |err| switch (err) {
            error.Corruption => RegionDesc{
                .id = id,
                .region_type = .free,
                .state = .free,
                .flags = 0,
                .offset = 0,
                .size = 0,
                .used_size = 0,
                .epoch = 0,
                .crc = 0,
                .reserved = 0,
            },
            else => |e| return e,
        };
        if (r.state == .free) {
            try pf.preallocate(index.file, offset, aligned_size);
            try writeRegion(index.file, .{
                .id = id,
                .region_type = kind,
                .state = .building,
                .flags = 0,
                .offset = offset,
                .size = aligned_size,
                .used_size = 0,
                .epoch = index.super.region_directory_epoch + 1,
                .crc = 0,
                .reserved = 0,
            });
            try pf.flushData(index.file);
            index.super.region_directory_epoch += 1;
            index.super.file_size = @max(try pf.len(index.file), offset + aligned_size);
            return id;
        }
    }
    return error.NoSpace;
}

pub fn activateRegion(index: *IndexFile, id: u32, used_size: u64) !void {
    var r = try readRegion(index.file, id);
    if (r.state != .building and r.state != .checkpointing) return error.InvalidArgument;
    r.state = .active;
    r.used_size = used_size;
    r.epoch = index.super.region_directory_epoch + 1;
    try writeRegion(index.file, r);
    var next = index.super;
    next.region_directory_epoch += 1;
    switch (r.region_type) {
        .base_index => next.active_base_region_id = id,
        .delta => next.active_delta_region_id = id,
        else => {},
    }
    try commitSuper(index, next);
}

pub fn verify(index: *const IndexFile) !void {
    const file_len = try pf.len(index.file);
    inline for (.{ index.super.active_base_region_id, index.super.active_delta_region_id, index.super.checkpoint_delta_region_id }) |id| {
        if (id != 0) {
            const r = try readRegion(index.file, id);
            if (r.state == .building or r.used_size > r.size) return error.Corruption;
            if (r.offset < REGION_AREA_OFFSET or r.offset > file_len or r.size > file_len - r.offset) return error.Corruption;
        }
    }
}

fn commitSuper(index: *IndexFile, candidate: IndexSuperBlock) !void {
    var next = candidate;
    next.epoch += 1;
    const off = if (next.epoch % 2 == 0) SUPER_A_OFFSET else SUPER_B_OFFSET;
    try writeSuper(index.file, off, next);
    try pf.flushMetadata(index.file);
    index.super = next;
}

fn writeHeader(file: pf.FileHandle, h: IndexFileHeader) !void {
    var b = [_]u8{0} ** HEADER_SIZE;
    fmt.writeU32Le(b[0..4], h.magic);
    fmt.writeU16Le(b[4..6], h.major_version);
    fmt.writeU16Le(b[6..8], h.minor_version);
    fmt.writeU32Le(b[8..12], h.endian);
    fmt.writeU32Le(b[12..16], h.pointer_size);
    fmt.writeU64Le(b[16..24], h.file_header_size);
    fmt.writeU64Le(b[24..32], h.superblock_a_offset);
    fmt.writeU64Le(b[32..40], h.superblock_b_offset);
    fmt.writeU64Le(b[40..48], h.region_directory_offset);
    fmt.writeU32Le(b[48..52], h.region_capacity);
    fmt.writeU32Le(b[52..56], h.region_desc_size);
    fmt.writeU64Le(b[56..64], h.region_area_offset);
    fmt.writeU64Le(b[64..72], h.alignment);
    @memcpy(b[72..88], &h.uuid);
    fmt.writeU32Le(b[88..92], 0);
    const crc = fmt.crc32c(&b);
    fmt.writeU32Le(b[88..92], crc);
    try pf.pwriteAll(file, 0, &b);
}

fn readHeader(file: pf.FileHandle) !IndexFileHeader {
    var b: [HEADER_SIZE]u8 = undefined;
    try readExact(file, 0, &b);
    const stored = fmt.readU32Le(b[88..92]);
    var c = b;
    fmt.writeU32Le(c[88..92], 0);
    if (fmt.crc32c(&c) != stored) return error.Corruption;
    return .{
        .magic = fmt.readU32Le(b[0..4]),
        .major_version = fmt.readU16Le(b[4..6]),
        .minor_version = fmt.readU16Le(b[6..8]),
        .endian = fmt.readU32Le(b[8..12]),
        .pointer_size = fmt.readU32Le(b[12..16]),
        .file_header_size = fmt.readU64Le(b[16..24]),
        .superblock_a_offset = fmt.readU64Le(b[24..32]),
        .superblock_b_offset = fmt.readU64Le(b[32..40]),
        .region_directory_offset = fmt.readU64Le(b[40..48]),
        .region_capacity = fmt.readU32Le(b[48..52]),
        .region_desc_size = fmt.readU32Le(b[52..56]),
        .region_area_offset = fmt.readU64Le(b[56..64]),
        .alignment = fmt.readU64Le(b[64..72]),
        .uuid = b[72..88].*,
        .crc = stored,
    };
}

fn writeSuper(file: pf.FileHandle, offset: u64, sb: IndexSuperBlock) !void {
    var b = [_]u8{0} ** SUPER_SIZE;
    fmt.writeU32Le(b[0..4], sb.magic);
    fmt.writeU32Le(b[4..8], sb.version);
    fmt.writeU64Le(b[8..16], sb.epoch);
    fmt.writeU64Le(b[16..24], sb.file_size);
    fmt.writeU32Le(b[24..28], sb.active_base_region_id);
    fmt.writeU32Le(b[28..32], sb.active_delta_region_id);
    fmt.writeU32Le(b[32..36], sb.checkpoint_delta_region_id);
    fmt.writeU32Le(b[36..40], sb.reserved0);
    fmt.writeU64Le(b[40..48], sb.region_directory_epoch);
    fmt.writeU64Le(b[48..56], sb.last_committed_journal_epoch);
    fmt.writeU32Le(b[56..60], sb.clean_shutdown);
    fmt.writeU32Le(b[60..64], sb.flags);
    fmt.writeU32Le(b[64..68], 0);
    const crc = fmt.crc32c(&b);
    fmt.writeU32Le(b[64..68], crc);
    try pf.pwriteAll(file, offset, &b);
}

fn readSuper(file: pf.FileHandle, offset: u64) !IndexSuperBlock {
    var b: [SUPER_SIZE]u8 = undefined;
    try readExact(file, offset, &b);
    const stored = fmt.readU32Le(b[64..68]);
    var c = b;
    fmt.writeU32Le(c[64..68], 0);
    if (fmt.crc32c(&c) != stored) return error.Corruption;
    const sb = IndexSuperBlock{
        .magic = fmt.readU32Le(b[0..4]),
        .version = fmt.readU32Le(b[4..8]),
        .epoch = fmt.readU64Le(b[8..16]),
        .file_size = fmt.readU64Le(b[16..24]),
        .active_base_region_id = fmt.readU32Le(b[24..28]),
        .active_delta_region_id = fmt.readU32Le(b[28..32]),
        .checkpoint_delta_region_id = fmt.readU32Le(b[32..36]),
        .reserved0 = fmt.readU32Le(b[36..40]),
        .region_directory_epoch = fmt.readU64Le(b[40..48]),
        .last_committed_journal_epoch = fmt.readU64Le(b[48..56]),
        .clean_shutdown = fmt.readU32Le(b[56..60]),
        .flags = fmt.readU32Le(b[60..64]),
        .crc = stored,
    };
    if (sb.magic != INDEX_SUPER_MAGIC or sb.version != 1) return error.Corruption;
    return sb;
}

fn writeRegion(file: pf.FileHandle, r: RegionDesc) !void {
    var b = [_]u8{0} ** REGION_DESC_SIZE;
    fmt.writeU32Le(b[0..4], r.id);
    fmt.writeU32Le(b[4..8], @intFromEnum(r.region_type));
    fmt.writeU32Le(b[8..12], @intFromEnum(r.state));
    fmt.writeU32Le(b[12..16], r.flags);
    fmt.writeU64Le(b[16..24], r.offset);
    fmt.writeU64Le(b[24..32], r.size);
    fmt.writeU64Le(b[32..40], r.used_size);
    fmt.writeU64Le(b[40..48], r.epoch);
    fmt.writeU32Le(b[48..52], 0);
    fmt.writeU32Le(b[52..56], r.reserved);
    const crc = fmt.crc32c(&b);
    fmt.writeU32Le(b[48..52], crc);
    try pf.pwriteAll(file, REGION_DIR_OFFSET + @as(u64, r.id) * REGION_DESC_SIZE, &b);
}

fn readRegion(file: pf.FileHandle, id: u32) !RegionDesc {
    if (id >= REGION_CAPACITY) return error.InvalidArgument;
    var b: [REGION_DESC_SIZE]u8 = undefined;
    try readExact(file, REGION_DIR_OFFSET + @as(u64, id) * REGION_DESC_SIZE, &b);
    const stored = fmt.readU32Le(b[48..52]);
    var c = b;
    fmt.writeU32Le(c[48..52], 0);
    if (fmt.crc32c(&c) != stored) return error.Corruption;
    return .{
        .id = fmt.readU32Le(b[0..4]),
        .region_type = std.enums.fromInt(RegionType, fmt.readU32Le(b[4..8])) orelse return error.Corruption,
        .state = std.enums.fromInt(RegionState, fmt.readU32Le(b[8..12])) orelse return error.Corruption,
        .flags = fmt.readU32Le(b[12..16]),
        .offset = fmt.readU64Le(b[16..24]),
        .size = fmt.readU64Le(b[24..32]),
        .used_size = fmt.readU64Le(b[32..40]),
        .epoch = fmt.readU64Le(b[40..48]),
        .crc = stored,
        .reserved = fmt.readU32Le(b[52..56]),
    };
}

fn readExact(file: pf.FileHandle, offset: u64, dst: []u8) !void {
    if (try pf.preadAll(file, offset, dst) != dst.len) return error.Corruption;
}

comptime {
    std.debug.assert(@sizeOf(IndexFileHeader) == HEADER_SIZE);
    std.debug.assert(@sizeOf(IndexSuperBlock) == SUPER_SIZE);
    std.debug.assert(@sizeOf(RegionDesc) == REGION_DESC_SIZE);
}

test "index file container superblocks and region lifecycle" {
    const testing = std.testing;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var idx = try createAt(tmp.dir, "index.db", [_]u8{0} ** 16);
    try verify(&idx);
    try idx.close();

    var opened = try openAt(tmp.dir, "index.db");
    try testing.expectEqual(@as(u32, 0), opened.activeBaseRegionId());
    const base_id = try allocateRegion(&opened, .base_index, 8192);
    try testing.expectEqual(.building, (try opened.region(base_id)).state);
    try activateRegion(&opened, base_id, 128);
    try testing.expectEqual(base_id, opened.activeBaseRegionId());
    try testing.expectEqual(.active, (try opened.region(base_id)).state);
    const delta_id = try allocateRegion(&opened, .delta, 16384);
    try activateRegion(&opened, delta_id, 256);
    try testing.expectEqual(delta_id, opened.activeDeltaRegionId());
    try opened.close();

    var corrupt_a = try openAt(tmp.dir, "index.db");
    try pf.pwriteAll(corrupt_a.file, SUPER_A_OFFSET, "BAD!");
    try corrupt_a.close();
    var choose_b = try openAt(tmp.dir, "index.db");
    _ = choose_b.activeBaseRegionId();

    var bad_super: [SUPER_SIZE]u8 = undefined;
    try readExact(choose_b.file, SUPER_A_OFFSET, &bad_super);
    fmt.writeU64Le(bad_super[8..16], choose_b.super.epoch + 100);
    try pf.pwriteAll(choose_b.file, SUPER_A_OFFSET, &bad_super);
    try choose_b.close();
    var choose_old = try openAt(tmp.dir, "index.db");
    _ = choose_old.activeDeltaRegionId();

    try pf.pwriteAll(choose_old.file, SUPER_A_OFFSET, "BAD!");
    try pf.pwriteAll(choose_old.file, SUPER_B_OFFSET, "BAD!");
    pf.close(&choose_old.file);
    try testing.expectError(error.Corruption, openAt(tmp.dir, "index.db"));
}
