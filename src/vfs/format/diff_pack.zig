//! DiffPack on-disk objects (docs/vfs/diff_patch.md §7).
//!
//!   DiffManifest  "VDFM"  singleton, 188 bytes
//!   FileOpTable   "VDFO"  header 24 + n * 112
//!   UnitTable     "VDUT"  header 24 + n * 128 (one per shard hint)
//!   PathDelta     "VDPI"  header 32 + adds + removes + strings
//!   Chunk         "VDCK"  header 32 + payload
const std = @import("std");
const fmt = @import("common.zig");
const file_manifest = @import("file_manifest.zig");

// ---------------------------------------------------------------------------
// DiffManifest
// ---------------------------------------------------------------------------

pub const MANIFEST_MAGIC: u32 = fmt.magic32("VDFM");
pub const MANIFEST_VERSION: u16 = 1;
pub const MANIFEST_SIZE: usize = 188;
const MANIFEST_CRC: usize = 184;

pub const MANIFEST_FLAG_HAS_PATH_DELTA: u32 = 1 << 0;
pub const MANIFEST_FLAG_HAS_DIRECTORY_MANIFEST: u32 = 1 << 1;

/// Upper bound on `shard_hint_count`: one UnitTable object per hint, so a
/// corrupt manifest must not be able to demand an unbounded number of them.
/// Comfortably above any realistic data-file count of a pack.
pub const MAX_SHARD_HINTS: u32 = 4096;

pub const DiffManifest = struct {
    diff_id: u64,
    target_pack_id: u64,
    base_pack_version: u64,
    target_pack_version: u64,
    target_build_id: u64,
    flags: u32 = 0,
    shard_hint_count: u32,
    unit_count: u64,
    chunk_count: u32,
    chunk_nominal_bytes: u32,
    file_op_count: u64,
    target_file_count: u64,
    target_tombstone_count: u64,
    base_content_hash: [32]u8,
    target_content_hash: [32]u8,
    payload_total_bytes: u64,
    tool_version_hash: u64,
    hdiff_options_hash: u64,
};

pub fn encodeManifest(m: DiffManifest) [MANIFEST_SIZE]u8 {
    var out = [_]u8{0} ** MANIFEST_SIZE;
    fmt.putU32(&out, 0, MANIFEST_MAGIC);
    fmt.putU16(&out, 4, MANIFEST_VERSION);
    fmt.putU16(&out, 6, MANIFEST_SIZE);
    fmt.putU64(&out, 8, m.diff_id);
    fmt.putU64(&out, 16, m.target_pack_id);
    fmt.putU64(&out, 24, m.base_pack_version);
    fmt.putU64(&out, 32, m.target_pack_version);
    fmt.putU64(&out, 40, m.target_build_id);
    fmt.putU32(&out, 48, m.flags);
    fmt.putU32(&out, 52, m.shard_hint_count);
    fmt.putU64(&out, 56, m.unit_count);
    fmt.putU32(&out, 64, m.chunk_count);
    fmt.putU32(&out, 68, m.chunk_nominal_bytes);
    fmt.putU64(&out, 72, m.file_op_count);
    fmt.putU64(&out, 80, m.target_file_count);
    fmt.putU64(&out, 88, m.target_tombstone_count);
    @memcpy(out[96..128], &m.base_content_hash);
    @memcpy(out[128..160], &m.target_content_hash);
    fmt.putU64(&out, 160, m.payload_total_bytes);
    fmt.putU64(&out, 168, m.tool_version_hash);
    fmt.putU64(&out, 176, m.hdiff_options_hash);
    fmt.putU32(&out, MANIFEST_CRC, fmt.crc32cWithZeroU32(&out, MANIFEST_CRC));
    return out;
}

pub fn decodeManifest(bytes: []const u8) !DiffManifest {
    if (bytes.len != MANIFEST_SIZE) return error.Corruption;
    if (fmt.getU32(bytes, 0) != MANIFEST_MAGIC) return error.Corruption;
    if (fmt.getU16(bytes, 4) != MANIFEST_VERSION) return error.UnsupportedVersion;
    if (fmt.getU16(bytes, 6) != MANIFEST_SIZE) return error.Corruption;
    if (fmt.getU32(bytes, MANIFEST_CRC) != fmt.crc32cWithZeroU32(bytes, MANIFEST_CRC)) return error.Corruption;
    var m: DiffManifest = undefined;
    m.diff_id = fmt.getU64(bytes, 8);
    m.target_pack_id = fmt.getU64(bytes, 16);
    m.base_pack_version = fmt.getU64(bytes, 24);
    m.target_pack_version = fmt.getU64(bytes, 32);
    m.target_build_id = fmt.getU64(bytes, 40);
    m.flags = fmt.getU32(bytes, 48);
    m.shard_hint_count = fmt.getU32(bytes, 52);
    m.unit_count = fmt.getU64(bytes, 56);
    m.chunk_count = fmt.getU32(bytes, 64);
    m.chunk_nominal_bytes = fmt.getU32(bytes, 68);
    m.file_op_count = fmt.getU64(bytes, 72);
    m.target_file_count = fmt.getU64(bytes, 80);
    m.target_tombstone_count = fmt.getU64(bytes, 88);
    @memcpy(&m.base_content_hash, bytes[96..128]);
    @memcpy(&m.target_content_hash, bytes[128..160]);
    m.payload_total_bytes = fmt.getU64(bytes, 160);
    m.tool_version_hash = fmt.getU64(bytes, 168);
    m.hdiff_options_hash = fmt.getU64(bytes, 176);
    if (m.shard_hint_count == 0 or m.shard_hint_count > MAX_SHARD_HINTS) return error.Corruption;
    return m;
}

// ---------------------------------------------------------------------------
// Payload reference (shared)
// ---------------------------------------------------------------------------

pub const PayloadRef = struct {
    chunk_id: u32,
    offset: u32,
    len: u32,

    pub const none: PayloadRef = .{ .chunk_id = 0, .offset = 0, .len = 0 };
};

// ---------------------------------------------------------------------------
// FileOpTable
// ---------------------------------------------------------------------------

pub const FILE_OP_MAGIC: u32 = fmt.magic32("VDFO");
pub const FILE_OP_VERSION: u16 = 1;
pub const FILE_OP_HEADER_SIZE: usize = 24;
pub const FILE_OP_SIZE: usize = 112;

pub const FileOpKind = enum(u8) {
    put_file_manifest = 1,
    delete_file_manifest = 2,
    put_entry_tombstone = 3,
    delete_entry_tombstone = 4,
    put_directory_manifest = 5,
    _,
};

pub const FileOp = struct {
    op: FileOpKind,
    file_entry: u64,
    old_file_version: u64 = 0,
    new_file_version: u64 = 0,
    old_content_hash: [32]u8 = [_]u8{0} ** 32,
    new_content_hash: [32]u8 = [_]u8{0} ** 32,
    payload: PayloadRef = PayloadRef.none,
};

pub fn encodeFileOps(allocator: std.mem.Allocator, ops: []const FileOp) ![]u8 {
    const out = try allocator.alloc(u8, FILE_OP_HEADER_SIZE + ops.len * FILE_OP_SIZE);
    @memset(out, 0);
    fmt.putU32(out, 0, FILE_OP_MAGIC);
    fmt.putU16(out, 4, FILE_OP_VERSION);
    fmt.putU16(out, 6, FILE_OP_HEADER_SIZE);
    fmt.putU32(out, 8, @intCast(ops.len));
    fmt.putU32(out, 12, FILE_OP_SIZE);
    for (ops, 0..) |op, i| {
        const b = out[FILE_OP_HEADER_SIZE + i * FILE_OP_SIZE ..][0..FILE_OP_SIZE];
        b[0] = @intFromEnum(op.op);
        fmt.putU64(b, 8, op.file_entry);
        fmt.putU64(b, 16, op.old_file_version);
        fmt.putU64(b, 24, op.new_file_version);
        @memcpy(b[32..64], &op.old_content_hash);
        @memcpy(b[64..96], &op.new_content_hash);
        fmt.putU32(b, 96, op.payload.chunk_id);
        fmt.putU32(b, 100, op.payload.offset);
        fmt.putU32(b, 104, op.payload.len);
    }
    fmt.putU32(out, 20, fmt.crc32cWithZeroU32(out, 20));
    return out;
}

pub fn decodeFileOps(allocator: std.mem.Allocator, bytes: []const u8) ![]FileOp {
    if (bytes.len < FILE_OP_HEADER_SIZE) return error.Corruption;
    if (fmt.getU32(bytes, 0) != FILE_OP_MAGIC) return error.Corruption;
    if (fmt.getU16(bytes, 4) != FILE_OP_VERSION) return error.UnsupportedVersion;
    if (fmt.getU16(bytes, 6) != FILE_OP_HEADER_SIZE or fmt.getU32(bytes, 12) != FILE_OP_SIZE) return error.Corruption;
    const n = fmt.getU32(bytes, 8);
    if (bytes.len != FILE_OP_HEADER_SIZE + @as(usize, n) * FILE_OP_SIZE) return error.Corruption;
    try fmt.requireZero(bytes[16..20]);
    if (fmt.getU32(bytes, 20) != fmt.crc32cWithZeroU32(bytes, 20)) return error.Corruption;
    const ops = try allocator.alloc(FileOp, n);
    errdefer allocator.free(ops);
    for (ops, 0..) |*op, i| {
        const b = bytes[FILE_OP_HEADER_SIZE + i * FILE_OP_SIZE ..][0..FILE_OP_SIZE];
        try fmt.requireZero(b[1..8]);
        try fmt.requireZero(b[108..112]);
        const kind: FileOpKind = @enumFromInt(b[0]);
        switch (kind) {
            .put_file_manifest, .delete_file_manifest, .put_entry_tombstone, .delete_entry_tombstone, .put_directory_manifest => {},
            _ => return error.Corruption,
        }
        op.* = .{
            .op = kind,
            .file_entry = fmt.getU64(b, 8),
            .old_file_version = fmt.getU64(b, 16),
            .new_file_version = fmt.getU64(b, 24),
            .payload = .{ .chunk_id = fmt.getU32(b, 96), .offset = fmt.getU32(b, 100), .len = fmt.getU32(b, 104) },
        };
        @memcpy(&op.old_content_hash, b[32..64]);
        @memcpy(&op.new_content_hash, b[64..96]);
    }
    return ops;
}

// ---------------------------------------------------------------------------
// UnitTable
// ---------------------------------------------------------------------------

pub const UNIT_MAGIC: u32 = fmt.magic32("VDUT");
pub const UNIT_VERSION: u16 = 1;
pub const UNIT_HEADER_SIZE: usize = 24;
pub const UNIT_SIZE: usize = 128;

pub const UnitKind = enum(u8) {
    put_page_raw = 1,
    put_page_pdelta = 2,
    put_block_ldelta = 3,
    delete_page = 4,
    _,
};

pub const Strategy = enum(u8) {
    none = 0,
    logical = 1,
    page = 2,
    replace = 3,
    _,
};

pub const UNIT_FLAG_SEGMENTED: u32 = 1 << 0;
pub const UNIT_FLAG_DOWNGRADED_RATIO: u32 = 1 << 1;
pub const UNIT_FLAG_DOWNGRADED_LAYOUT: u32 = 1 << 2;
pub const UNIT_FLAG_CFG_OVERRIDE: u32 = 1 << 3;
pub const UNIT_FLAG_NEW_BLOCK: u32 = 1 << 4;

pub const UnitDesc = struct {
    kind: UnitKind,
    strategy: Strategy,
    codec: file_manifest.Codec,
    codec_level: i16 = 0,
    flags: u32 = 0,
    file_entry: u64,
    block_index: u32,
    page_index: u32 = 0,
    page_count: u32 = 1,
    /// New block layout for L units: page size used to re-split.
    page_size: u32 = 0,
    old_stored_size: u32 = 0,
    old_stored_crc: u32 = 0,
    new_stored_crc: u32 = 0,
    new_raw_size: u32 = 0,
    old_block_hash: [32]u8 = [_]u8{0} ** 32,
    new_block_hash: [32]u8 = [_]u8{0} ** 32,
    codec_version_hash: u64 = 0,
    payload: PayloadRef = PayloadRef.none,
};

pub fn encodeUnits(allocator: std.mem.Allocator, shard: u32, units: []const UnitDesc) ![]u8 {
    const out = try allocator.alloc(u8, UNIT_HEADER_SIZE + units.len * UNIT_SIZE);
    @memset(out, 0);
    fmt.putU32(out, 0, UNIT_MAGIC);
    fmt.putU16(out, 4, UNIT_VERSION);
    fmt.putU16(out, 6, UNIT_HEADER_SIZE);
    fmt.putU32(out, 8, shard);
    fmt.putU32(out, 12, @intCast(units.len));
    fmt.putU32(out, 16, UNIT_SIZE);
    for (units, 0..) |u, i| {
        const b = out[UNIT_HEADER_SIZE + i * UNIT_SIZE ..][0..UNIT_SIZE];
        b[0] = @intFromEnum(u.kind);
        b[1] = @intFromEnum(u.strategy);
        fmt.putU16(b, 2, @intFromEnum(u.codec));
        fmt.putU32(b, 4, u.flags);
        fmt.putU64(b, 8, u.file_entry);
        fmt.putU32(b, 16, u.block_index);
        fmt.putU32(b, 20, u.page_index);
        fmt.putU32(b, 24, u.page_count);
        fmt.putU32(b, 28, u.old_stored_size);
        fmt.putU32(b, 32, u.old_stored_crc);
        fmt.putU32(b, 36, u.new_stored_crc);
        @memcpy(b[40..72], &u.old_block_hash);
        @memcpy(b[72..104], &u.new_block_hash);
        fmt.putU64(b, 104, u.codec_version_hash);
        fmt.putU32(b, 112, u.payload.chunk_id);
        fmt.putU32(b, 116, u.payload.offset);
        fmt.putU32(b, 120, u.payload.len);
        fmt.putU16(b, 124, @bitCast(u.codec_level));
        // [126..128] reserved
        // page_size / new_raw_size share the two remaining 4-byte fields we
        // carve out of the old reserved space: put them after codec_level is
        // not possible (only 2 bytes). Store them in the (unused for P/R)
        // old_stored_* fields when kind == put_block_ldelta.
        if (u.kind == .put_block_ldelta) {
            fmt.putU32(b, 28, u.page_size);
            fmt.putU32(b, 32, u.new_raw_size);
        }
    }
    fmt.putU32(out, 20, fmt.crc32cWithZeroU32(out, 20));
    return out;
}

pub const DecodedUnits = struct {
    shard: u32,
    units: []UnitDesc,

    pub fn deinit(self: *DecodedUnits, allocator: std.mem.Allocator) void {
        allocator.free(self.units);
        self.* = undefined;
    }
};

pub fn decodeUnits(allocator: std.mem.Allocator, bytes: []const u8) !DecodedUnits {
    if (bytes.len < UNIT_HEADER_SIZE) return error.Corruption;
    if (fmt.getU32(bytes, 0) != UNIT_MAGIC) return error.Corruption;
    if (fmt.getU16(bytes, 4) != UNIT_VERSION) return error.UnsupportedVersion;
    if (fmt.getU16(bytes, 6) != UNIT_HEADER_SIZE or fmt.getU32(bytes, 16) != UNIT_SIZE) return error.Corruption;
    const shard = fmt.getU32(bytes, 8);
    const n = fmt.getU32(bytes, 12);
    if (bytes.len != UNIT_HEADER_SIZE + @as(usize, n) * UNIT_SIZE) return error.Corruption;
    if (fmt.getU32(bytes, 20) != fmt.crc32cWithZeroU32(bytes, 20)) return error.Corruption;
    const units = try allocator.alloc(UnitDesc, n);
    errdefer allocator.free(units);
    for (units, 0..) |*u, i| {
        const b = bytes[UNIT_HEADER_SIZE + i * UNIT_SIZE ..][0..UNIT_SIZE];
        try fmt.requireZero(b[126..128]);
        const kind: UnitKind = @enumFromInt(b[0]);
        switch (kind) {
            .put_page_raw, .put_page_pdelta, .put_block_ldelta, .delete_page => {},
            _ => return error.Corruption,
        }
        const strategy: Strategy = @enumFromInt(b[1]);
        switch (strategy) {
            .none, .logical, .page, .replace => {},
            _ => return error.Corruption,
        }
        u.* = .{
            .kind = kind,
            .strategy = strategy,
            .codec = @enumFromInt(fmt.getU16(b, 2)),
            .codec_level = @bitCast(fmt.getU16(b, 124)),
            .flags = fmt.getU32(b, 4),
            .file_entry = fmt.getU64(b, 8),
            .block_index = fmt.getU32(b, 16),
            .page_index = fmt.getU32(b, 20),
            .page_count = fmt.getU32(b, 24),
            .codec_version_hash = fmt.getU64(b, 104),
            .payload = .{ .chunk_id = fmt.getU32(b, 112), .offset = fmt.getU32(b, 116), .len = fmt.getU32(b, 120) },
        };
        if (kind == .put_block_ldelta) {
            u.page_size = fmt.getU32(b, 28);
            u.new_raw_size = fmt.getU32(b, 32);
        } else {
            u.old_stored_size = fmt.getU32(b, 28);
            u.old_stored_crc = fmt.getU32(b, 32);
        }
        u.new_stored_crc = fmt.getU32(b, 36);
        @memcpy(&u.old_block_hash, b[40..72]);
        @memcpy(&u.new_block_hash, b[72..104]);
        if (u.file_entry == 0) return error.Corruption;
    }
    return .{ .shard = shard, .units = units };
}

// ---------------------------------------------------------------------------
// PathDelta
// ---------------------------------------------------------------------------

pub const PATH_DELTA_MAGIC: u32 = fmt.magic32("VDPI");
pub const PATH_DELTA_VERSION: u16 = 1;
pub const PATH_DELTA_HEADER_SIZE: usize = 32;
const PATH_ADD_SIZE: usize = 24;
const PATH_REMOVE_SIZE: usize = 16;

pub const PathAdd = struct { file_entry: u64, flags: u32 = 0, path: []const u8 };
pub const PathRemove = struct { path: []const u8 };

pub const PathDelta = struct {
    adds: []const PathAdd,
    removes: []const PathRemove,
};

pub fn encodePathDelta(allocator: std.mem.Allocator, d: PathDelta) ![]u8 {
    var strings: usize = 0;
    for (d.adds) |a| strings += a.path.len;
    for (d.removes) |r| strings += r.path.len;
    const total = PATH_DELTA_HEADER_SIZE + d.adds.len * PATH_ADD_SIZE + d.removes.len * PATH_REMOVE_SIZE + strings;
    const out = try allocator.alloc(u8, total);
    @memset(out, 0);
    fmt.putU32(out, 0, PATH_DELTA_MAGIC);
    fmt.putU16(out, 4, PATH_DELTA_VERSION);
    fmt.putU16(out, 6, PATH_DELTA_HEADER_SIZE);
    fmt.putU32(out, 8, @intCast(d.adds.len));
    fmt.putU32(out, 12, @intCast(d.removes.len));
    fmt.putU32(out, 16, @intCast(strings));
    const str_off: usize = PATH_DELTA_HEADER_SIZE + d.adds.len * PATH_ADD_SIZE + d.removes.len * PATH_REMOVE_SIZE;
    var cursor: usize = 0;
    for (d.adds, 0..) |a, i| {
        const b = out[PATH_DELTA_HEADER_SIZE + i * PATH_ADD_SIZE ..][0..PATH_ADD_SIZE];
        fmt.putU64(b, 0, a.file_entry);
        fmt.putU32(b, 8, @intCast(cursor));
        fmt.putU32(b, 12, @intCast(a.path.len));
        fmt.putU32(b, 16, a.flags);
        @memcpy(out[str_off + cursor ..][0..a.path.len], a.path);
        cursor += a.path.len;
    }
    const rem_base = PATH_DELTA_HEADER_SIZE + d.adds.len * PATH_ADD_SIZE;
    for (d.removes, 0..) |r, i| {
        const b = out[rem_base + i * PATH_REMOVE_SIZE ..][0..PATH_REMOVE_SIZE];
        fmt.putU32(b, 0, @intCast(cursor));
        fmt.putU32(b, 4, @intCast(r.path.len));
        @memcpy(out[str_off + cursor ..][0..r.path.len], r.path);
        cursor += r.path.len;
    }
    fmt.putU32(out, 28, fmt.crc32cWithZeroU32(out, 28));
    return out;
}

pub const DecodedPathDelta = struct {
    adds: []PathAdd,
    removes: []PathRemove,
    strings: []u8,

    pub fn deinit(self: *DecodedPathDelta, allocator: std.mem.Allocator) void {
        allocator.free(self.adds);
        allocator.free(self.removes);
        allocator.free(self.strings);
        self.* = undefined;
    }
};

pub fn decodePathDelta(allocator: std.mem.Allocator, bytes: []const u8) !DecodedPathDelta {
    if (bytes.len < PATH_DELTA_HEADER_SIZE) return error.Corruption;
    if (fmt.getU32(bytes, 0) != PATH_DELTA_MAGIC) return error.Corruption;
    if (fmt.getU16(bytes, 4) != PATH_DELTA_VERSION) return error.UnsupportedVersion;
    if (fmt.getU16(bytes, 6) != PATH_DELTA_HEADER_SIZE) return error.Corruption;
    const add_n = fmt.getU32(bytes, 8);
    const rem_n = fmt.getU32(bytes, 12);
    const str_n = fmt.getU32(bytes, 16);
    try fmt.requireZero(bytes[20..28]);
    const expect = PATH_DELTA_HEADER_SIZE + @as(usize, add_n) * PATH_ADD_SIZE + @as(usize, rem_n) * PATH_REMOVE_SIZE + str_n;
    if (bytes.len != expect) return error.Corruption;
    if (fmt.getU32(bytes, 28) != fmt.crc32cWithZeroU32(bytes, 28)) return error.Corruption;
    const str_off = expect - str_n;
    const strings = try allocator.dupe(u8, bytes[str_off..]);
    errdefer allocator.free(strings);
    const adds = try allocator.alloc(PathAdd, add_n);
    errdefer allocator.free(adds);
    for (adds, 0..) |*a, i| {
        const b = bytes[PATH_DELTA_HEADER_SIZE + i * PATH_ADD_SIZE ..][0..PATH_ADD_SIZE];
        try fmt.requireZero(b[20..24]);
        const off = fmt.getU32(b, 8);
        const len = fmt.getU32(b, 12);
        if (@as(usize, off) + len > strings.len) return error.Corruption;
        a.* = .{ .file_entry = fmt.getU64(b, 0), .flags = fmt.getU32(b, 16), .path = strings[off .. off + len] };
        if (a.file_entry == 0) return error.Corruption;
    }
    const removes = try allocator.alloc(PathRemove, rem_n);
    errdefer allocator.free(removes);
    const rem_base = PATH_DELTA_HEADER_SIZE + @as(usize, add_n) * PATH_ADD_SIZE;
    for (removes, 0..) |*r, i| {
        const b = bytes[rem_base + i * PATH_REMOVE_SIZE ..][0..PATH_REMOVE_SIZE];
        try fmt.requireZero(b[8..16]);
        const off = fmt.getU32(b, 0);
        const len = fmt.getU32(b, 4);
        if (@as(usize, off) + len > strings.len) return error.Corruption;
        r.* = .{ .path = strings[off .. off + len] };
    }
    return .{ .adds = adds, .removes = removes, .strings = strings };
}

// ---------------------------------------------------------------------------
// Chunk
// ---------------------------------------------------------------------------

pub const CHUNK_MAGIC: u32 = fmt.magic32("VDCK");
pub const CHUNK_VERSION: u16 = 1;
pub const CHUNK_HEADER_SIZE: usize = 32;
pub const CHUNK_ALIGN: usize = 16;

pub const ChunkHeader = struct {
    chunk_id: u32,
    shard: u32,
    payload_bytes: u32,
    payload_crc: u32,
};

pub fn encodeChunk(allocator: std.mem.Allocator, chunk_id: u32, shard: u32, payload: []const u8) ![]u8 {
    if (payload.len > std.math.maxInt(u32)) return error.InvalidArgument;
    const out = try allocator.alloc(u8, CHUNK_HEADER_SIZE + payload.len);
    @memset(out[0..CHUNK_HEADER_SIZE], 0);
    fmt.putU32(out, 0, CHUNK_MAGIC);
    fmt.putU16(out, 4, CHUNK_VERSION);
    fmt.putU16(out, 6, CHUNK_HEADER_SIZE);
    fmt.putU32(out, 8, chunk_id);
    fmt.putU32(out, 12, shard);
    fmt.putU32(out, 16, @intCast(payload.len));
    fmt.putU32(out, 20, fmt.crc32c(payload));
    @memcpy(out[CHUNK_HEADER_SIZE..], payload);
    fmt.putU32(out, 28, fmt.crc32cWithZeroU32(out[0..CHUNK_HEADER_SIZE], 28));
    return out;
}

pub const DecodedChunk = struct {
    header: ChunkHeader,
    payload: []const u8,
};

/// Validates header + payload crc; returns a borrowed payload slice.
pub fn decodeChunk(bytes: []const u8, expected_chunk_id: u32) !DecodedChunk {
    if (bytes.len < CHUNK_HEADER_SIZE) return error.Corruption;
    if (fmt.getU32(bytes, 0) != CHUNK_MAGIC) return error.Corruption;
    if (fmt.getU16(bytes, 4) != CHUNK_VERSION) return error.UnsupportedVersion;
    if (fmt.getU16(bytes, 6) != CHUNK_HEADER_SIZE) return error.Corruption;
    try fmt.requireZero(bytes[24..28]);
    if (fmt.getU32(bytes, 28) != fmt.crc32cWithZeroU32(bytes[0..CHUNK_HEADER_SIZE], 28)) return error.Corruption;
    const h: ChunkHeader = .{ .chunk_id = fmt.getU32(bytes, 8), .shard = fmt.getU32(bytes, 12), .payload_bytes = fmt.getU32(bytes, 16), .payload_crc = fmt.getU32(bytes, 20) };
    if (h.chunk_id != expected_chunk_id) return error.Corruption;
    if (bytes.len != CHUNK_HEADER_SIZE + h.payload_bytes) return error.Corruption;
    const payload = bytes[CHUNK_HEADER_SIZE..];
    if (fmt.crc32c(payload) != h.payload_crc) return error.ChecksumMismatch;
    return .{ .header = h, .payload = payload };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

fn flipAll(allocator: std.mem.Allocator, bytes: []const u8, comptime decodeFn: anytype) !void {
    var i: usize = 0;
    while (i < bytes.len) : (i += 1) {
        const bad = try allocator.dupe(u8, bytes);
        defer allocator.free(bad);
        bad[i] ^= 0x01;
        try std.testing.expect(std.meta.isError(decodeFn(allocator, bad)));
    }
}

test "diff manifest roundtrip and flips" {
    var m: DiffManifest = .{ .diff_id = 1, .target_pack_id = 2, .base_pack_version = 3, .target_pack_version = 4, .target_build_id = 5, .shard_hint_count = 2, .unit_count = 6, .chunk_count = 7, .chunk_nominal_bytes = 8 << 20, .file_op_count = 9, .target_file_count = 10, .target_tombstone_count = 11, .base_content_hash = [_]u8{1} ** 32, .target_content_hash = [_]u8{2} ** 32, .payload_total_bytes = 12, .tool_version_hash = 13, .hdiff_options_hash = 14 };
    m.flags = MANIFEST_FLAG_HAS_PATH_DELTA;
    const enc = encodeManifest(m);
    const dec = try decodeManifest(&enc);
    try std.testing.expectEqual(m.target_pack_version, dec.target_pack_version);
    try std.testing.expectEqual(m.hdiff_options_hash, dec.hdiff_options_hash);
    try std.testing.expectEqualSlices(u8, &m.target_content_hash, &dec.target_content_hash);
    var i: usize = 0;
    while (i < MANIFEST_SIZE) : (i += 1) {
        var bad = enc;
        bad[i] ^= 0x01;
        try std.testing.expect(std.meta.isError(decodeManifest(&bad)));
    }
}

test "file op table roundtrip and flips" {
    const a = std.testing.allocator;
    const ops = [_]FileOp{
        .{ .op = .put_file_manifest, .file_entry = 10, .new_file_version = 2, .payload = .{ .chunk_id = 1, .offset = 16, .len = 80 } },
        .{ .op = .delete_file_manifest, .file_entry = 11, .old_file_version = 1 },
        .{ .op = .put_entry_tombstone, .file_entry = 11, .payload = .{ .chunk_id = 1, .offset = 96, .len = 40 } },
    };
    const enc = try encodeFileOps(a, &ops);
    defer a.free(enc);
    try std.testing.expectEqual(FILE_OP_HEADER_SIZE + 3 * FILE_OP_SIZE, enc.len);
    const dec = try decodeFileOps(a, enc);
    defer a.free(dec);
    try std.testing.expectEqual(FileOpKind.put_entry_tombstone, dec[2].op);
    try std.testing.expectEqual(@as(u32, 96), dec[2].payload.offset);
    try flipAll(a, enc, decodeFileOps);
}

test "unit table roundtrip for every kind and flips" {
    const a = std.testing.allocator;
    const units = [_]UnitDesc{
        .{ .kind = .put_page_raw, .strategy = .replace, .codec = .lz4, .codec_level = 4, .file_entry = 1, .block_index = 0, .page_index = 3, .new_stored_crc = 0xabc, .payload = .{ .chunk_id = 0, .offset = 0, .len = 200 } },
        .{ .kind = .put_page_pdelta, .strategy = .page, .codec = .zstd, .file_entry = 2, .block_index = 1, .page_index = 0, .old_stored_size = 1000, .old_stored_crc = 7, .new_stored_crc = 8, .codec_version_hash = 99, .payload = .{ .chunk_id = 0, .offset = 208, .len = 50 } },
        .{ .kind = .put_block_ldelta, .strategy = .logical, .codec = .lz4, .codec_level = 1, .flags = UNIT_FLAG_SEGMENTED, .file_entry = 3, .block_index = 0, .page_count = 5, .page_size = 65536, .new_raw_size = 300000, .old_block_hash = [_]u8{9} ** 32, .new_block_hash = [_]u8{8} ** 32, .payload = .{ .chunk_id = 1, .offset = 0, .len = 1234 } },
        .{ .kind = .delete_page, .strategy = .none, .codec = .none, .file_entry = 4, .block_index = 0, .page_index = 9 },
    };
    const enc = try encodeUnits(a, 3, &units);
    defer a.free(enc);
    try std.testing.expectEqual(UNIT_HEADER_SIZE + 4 * UNIT_SIZE, enc.len);
    var dec = try decodeUnits(a, enc);
    defer dec.deinit(a);
    try std.testing.expectEqual(@as(u32, 3), dec.shard);
    try std.testing.expectEqual(@as(i16, 4), dec.units[0].codec_level);
    try std.testing.expectEqual(@as(u32, 1000), dec.units[1].old_stored_size);
    try std.testing.expectEqual(@as(u32, 65536), dec.units[2].page_size);
    try std.testing.expectEqual(@as(u32, 300000), dec.units[2].new_raw_size);
    try std.testing.expectEqual(UNIT_FLAG_SEGMENTED, dec.units[2].flags);
    try std.testing.expectEqualSlices(u8, &units[2].new_block_hash, &dec.units[2].new_block_hash);
    try std.testing.expectEqual(UnitKind.delete_page, dec.units[3].kind);
    try flipAll(a, enc, decodeUnits);
}

test "path delta roundtrip and flips" {
    const a = std.testing.allocator;
    const enc = try encodePathDelta(a, .{
        .adds = &.{ .{ .file_entry = 5, .path = "textures/a.png" }, .{ .file_entry = 6, .path = "b", .flags = 2 } },
        .removes = &.{.{ .path = "old/c.bin" }},
    });
    defer a.free(enc);
    var dec = try decodePathDelta(a, enc);
    defer dec.deinit(a);
    try std.testing.expectEqualStrings("textures/a.png", dec.adds[0].path);
    try std.testing.expectEqualStrings("b", dec.adds[1].path);
    try std.testing.expectEqual(@as(u32, 2), dec.adds[1].flags);
    try std.testing.expectEqualStrings("old/c.bin", dec.removes[0].path);
    try flipAll(a, enc, decodePathDelta);
    const empty = try encodePathDelta(a, .{ .adds = &.{}, .removes = &.{} });
    defer a.free(empty);
    var dec_empty = try decodePathDelta(a, empty);
    defer dec_empty.deinit(a);
    try std.testing.expectEqual(@as(usize, 0), dec_empty.adds.len);
}

test "chunk roundtrip and flips" {
    const a = std.testing.allocator;
    const payload = "chunk payload bytes 0123456789";
    const enc = try encodeChunk(a, 4, 1, payload);
    defer a.free(enc);
    const dec = try decodeChunk(enc, 4);
    try std.testing.expectEqualStrings(payload, dec.payload);
    try std.testing.expectEqual(@as(u32, 1), dec.header.shard);
    try std.testing.expectError(error.Corruption, decodeChunk(enc, 5));
    var i: usize = 0;
    while (i < enc.len) : (i += 1) {
        const bad = try a.dupe(u8, enc);
        defer a.free(bad);
        bad[i] ^= 0x01;
        try std.testing.expect(std.meta.isError(decodeChunk(bad, 4)));
    }
}
