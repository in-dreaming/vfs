const std = @import("std");
const fmt = @import("../format.zig");
const pf = @import("../platform/file.zig");
const sync = @import("../platform/sync.zig");

pub const RECORD_ALIGNMENT: u64 = 16;
pub const DATA_HEADER_SIZE: u64 = 80;
pub const DATA_SUPERBLOCK_SIZE: u64 = 104;
pub const DATA_SUPERBLOCK_A_OFFSET: u64 = DATA_HEADER_SIZE;
pub const DATA_SUPERBLOCK_B_OFFSET: u64 = DATA_SUPERBLOCK_A_OFFSET + DATA_SUPERBLOCK_SIZE;
pub const CHECKPOINT_AREA_SIZE: u64 = 4096 - DATA_HEADER_SIZE - DATA_SUPERBLOCK_SIZE * 2;
pub const ALLOCATOR_CHECKPOINT_OFFSET: u64 = DATA_SUPERBLOCK_B_OFFSET + DATA_SUPERBLOCK_SIZE;
pub const RECORD_AREA_OFFSET: u64 = 4096;
pub const RECORD_HEADER_SIZE: u32 = 64;
pub const RECORD_FOOTER_SIZE: u32 = 8;

pub const DATA_FILE_MAGIC: u32 = 0x31415444; // "DAT1" little-endian
pub const DATA_SUPER_MAGIC: u32 = 0x31534244; // "DBS1" little-endian
pub const RECORD_MAGIC: u32 = 0x31524344; // "DCR1" little-endian
pub const RECORD_FOOTER_MAGIC: u32 = 0x314d4344; // "DCM1" little-endian
pub const ENDIAN_LE: u32 = 0x01020304;

pub const CreateOptions = struct {
    durability: fmt.Durability = .sync,
    uuid: [16]u8 = [_]u8{0} ** 16,
};

pub const OpenOptions = struct {
    repair_tail: bool = true,
    /// Open the data file without write access. Tail repair results are then
    /// applied in memory only and never persisted.
    read_only: bool = false,
    /// Number of additional read-only OS handles to open for positional reads.
    /// On Windows every synchronous file object serializes its IO inside the
    /// kernel, so concurrent readers on one handle queue up; spreading readers
    /// over several handles restores parallelism. 0 keeps a single handle.
    read_handles: u8 = 0,
};

pub const MAX_READ_HANDLES: usize = 16;

pub const AppendOptions = struct {
    durability: fmt.Durability = .async,
    codec: u16 = 0,
    flags: u16 = 0,
    version: u64,
    txn_id: u64 = 0,
    defer_superblock: bool = false,
};

pub const AppendResult = struct {
    offset: u64,
    stored_size: u32,
    raw_size: u32,
    crc: u32,
    codec: u16,
    version: u64,
};

pub const BatchAppendInput = struct {
    key: fmt.Key128,
    key_bytes: []const u8 = &.{},
    payload: []const u8,
    options: AppendOptions,
};

pub const RecordMeta = struct {
    key: fmt.Key128,
    key_size: u32,
    offset: u64,
    header_size: u32,
    stored_size: u32,
    raw_size: u32,
    payload_crc: u32,
    record_crc: u32,
    flags: u16,
    codec: u16,
    version: u64,
    txn_id: u64,
    total_size: u64,
    aligned_size: u64,
};

pub const DataFileHeader = extern struct {
    magic: u32,
    major_version: u16,
    minor_version: u16,
    endian: u32,
    flags: u32,
    header_size: u64,
    superblock_a_offset: u64,
    superblock_b_offset: u64,
    record_area_offset: u64,
    alignment: u64,
    uuid: [16]u8,
    crc: u32,
};

pub const DataSuperBlock = extern struct {
    magic: u32,
    version: u32,
    epoch: u64,
    file_size: u64,
    logical_tail: u64,
    durable_tail: u64,
    allocator_checkpoint_offset: u64,
    allocator_checkpoint_size: u64,
    allocator_checkpoint_epoch: u64,
    free_bytes: u64,
    pending_free_bytes: u64,
    tail_free_bytes: u64,
    clean_shutdown: u32,
    flags: u32,
    crc: u32,
};

pub const RecordHeader = extern struct {
    magic: u32,
    header_version: u16,
    flags: u16,
    key_hi: u64,
    key_lo: u64,
    version: u64,
    header_size: u32,
    stored_size: u32,
    header_crc: u32,
    raw_size: u32,
    payload_crc: u32,
    key_size: u32,
    txn_id: u64,
};

pub const RecordFooter = extern struct {
    magic_commit: u32,
    record_crc: u32,
};

pub const DataFile = struct {
    file: pf.FileHandle,
    logical_tail: u64,
    epoch: u64,
    append_mutex: sync.Mutex = .{},
    read_only: bool = false,
    read_files: [MAX_READ_HANDLES]pf.FileHandle = undefined,
    read_file_count: u8 = 0,

    pub fn close(self: *DataFile) !void {
        var i: usize = 0;
        while (i < self.read_file_count) : (i += 1) pf.close(&self.read_files[i]);
        self.read_file_count = 0;
        if (!self.file.isOpen()) return;
        if (!self.read_only) try pf.flushMetadata(self.file);
        pf.close(&self.file);
    }

    /// Handle to use for a positional read on the calling thread.
    pub fn readHandle(self: *const DataFile) pf.FileHandle {
        if (self.read_file_count == 0) return self.file;
        return self.read_files[sync.threadSlot() % self.read_file_count];
    }

    /// Single-pass, single-syscall record read. The whole record
    /// `[header][key][payload][footer]` is read into a thread-local scratch
    /// buffer, the header crc / key / footer magic / record crc are verified,
    /// and the payload is returned as a borrowed slice that stays valid until
    /// the next `readRecordBorrow` on the same thread.
    ///
    /// `expected_stored_size` comes from the index entry so the read size is
    /// known before the header is parsed. Only the record crc is verified over
    /// the payload: it covers header bytes (which embed payload_crc), key,
    /// payload and footer magic, so a separate payload_crc pass adds nothing.
    pub fn readRecordBorrow(self: *DataFile, offset: u64, key: fmt.Key128, key_bytes: []const u8, expected_stored_size: u32) ![]const u8 {
        return dataReadRecordBorrow(self, offset, key, key_bytes, expected_stored_size);
    }

    /// Reads and validates only the header plus stored key, returning the
    /// record metadata. Used by size queries that must confirm the raw key
    /// matches without touching the payload.
    pub fn readMetaCheckKey(self: *DataFile, offset: u64, key: fmt.Key128, key_bytes: []const u8) !RecordMeta {
        return dataReadMetaCheckKey(self, offset, key, key_bytes);
    }

    pub fn append(self: *DataFile, key: fmt.Key128, payload: []const u8, options: AppendOptions) !AppendResult {
        return dataAppend(self, key, payload, options);
    }

    pub fn appendRawKey(self: *DataFile, key: fmt.Key128, key_bytes: []const u8, payload: []const u8, options: AppendOptions) !AppendResult {
        return dataAppendRawKey(self, key, key_bytes, payload, options);
    }

    pub fn readMeta(self: *DataFile, offset: u64) !RecordMeta {
        return dataReadMeta(self, offset);
    }

    pub fn readPayload(self: *DataFile, offset: u64, key: fmt.Key128, dst: []u8) !usize {
        return dataReadPayload(self, offset, key, dst);
    }

    pub fn readPayloadRawKey(self: *DataFile, offset: u64, key: fmt.Key128, key_bytes: []const u8, dst: []u8) !usize {
        return dataReadPayloadRawKey(self, offset, key, key_bytes, dst);
    }

    pub fn verifyRecord(self: *DataFile, offset: u64) !RecordMeta {
        return dataVerifyRecord(self, offset);
    }

    /// Reads the raw key bytes stored in the record at `offset` into `dst`.
    /// Returns the key size; `error.BufferTooSmall` if `dst` cannot hold it.
    pub fn readKeyBytes(self: *DataFile, offset: u64, dst: []u8) !usize {
        const fh = self.readHandle();
        const parsed = try readAndValidateHeader(fh, offset);
        if (dst.len < parsed.meta.key_size) return error.BufferTooSmall;
        if (parsed.meta.key_size != 0) try readExact(fh, offset + RECORD_HEADER_SIZE, dst[0..parsed.meta.key_size]);
        return parsed.meta.key_size;
    }
};

pub const AllocatorSuper = struct {
    checkpoint_offset: u64 = 0,
    checkpoint_size: u64 = 0,
    checkpoint_epoch: u64 = 0,
    free_bytes: u64 = 0,
    pending_free_bytes: u64 = 0,
    tail_free_bytes: u64 = 0,
};

pub fn create(path: []const u8, options: CreateOptions) !DataFile {
    var file = try pf.open(path, .{ .mode = .create_read_write, .create_parent_dirs = true });
    errdefer pf.close(&file);
    try initializeNew(file, options);
    return .{ .file = file, .logical_tail = RECORD_AREA_OFFSET, .epoch = 1 };
}

pub fn createAt(dir: std.Io.Dir, path: []const u8, options: CreateOptions) !DataFile {
    return createIn(.fromOs(dir), path, options);
}

pub fn createIn(dir: pf.Directory, path: []const u8, options: CreateOptions) !DataFile {
    var file = try pf.openIn(dir, path, .{ .mode = .create_read_write });
    errdefer pf.close(&file);
    try initializeNew(file, options);
    return .{ .file = file, .logical_tail = RECORD_AREA_OFFSET, .epoch = 1 };
}

pub fn open(path: []const u8, options: OpenOptions) !DataFile {
    return openIn(.fromOs(std.Io.Dir.cwd()), path, options);
}

pub fn openAt(dir: std.Io.Dir, path: []const u8, options: OpenOptions) !DataFile {
    return openIn(.fromOs(dir), path, options);
}

pub fn openIn(dir: pf.Directory, path: []const u8, options: OpenOptions) !DataFile {
    var file = try pf.openIn(dir, path, .{ .mode = if (options.read_only) .read_only else .read_write });
    errdefer pf.close(&file);
    const sb = try loadAndMaybeRepair(file, options);
    var out = DataFile{ .file = file, .logical_tail = sb.logical_tail, .epoch = sb.epoch, .read_only = options.read_only };
    errdefer {
        var i: usize = 0;
        while (i < out.read_file_count) : (i += 1) pf.close(&out.read_files[i]);
    }
    const wanted: usize = @min(@as(usize, options.read_handles), MAX_READ_HANDLES);
    while (out.read_file_count < wanted) {
        // Custom file backends own their handle semantics; only pool OS files.
        if (dir.custom_ops != null) break;
        out.read_files[out.read_file_count] = try pf.openIn(dir, path, .{ .mode = .read_only });
        out.read_file_count += 1;
    }
    return out;
}

fn initializeNew(file: pf.FileHandle, options: CreateOptions) !void {
    try pf.setLen(file, 0);
    try pf.preallocate(file, 0, RECORD_AREA_OFFSET);
    const header = DataFileHeader{
        .magic = DATA_FILE_MAGIC,
        .major_version = 2,
        .minor_version = 0,
        .endian = ENDIAN_LE,
        .flags = 0,
        .header_size = DATA_HEADER_SIZE,
        .superblock_a_offset = DATA_SUPERBLOCK_A_OFFSET,
        .superblock_b_offset = DATA_SUPERBLOCK_B_OFFSET,
        .record_area_offset = RECORD_AREA_OFFSET,
        .alignment = RECORD_ALIGNMENT,
        .uuid = options.uuid,
        .crc = 0,
    };
    try writeHeader(file, header);
    const sb = DataSuperBlock{
        .magic = DATA_SUPER_MAGIC,
        .version = 2,
        .epoch = 1,
        .file_size = RECORD_AREA_OFFSET,
        .logical_tail = RECORD_AREA_OFFSET,
        .durable_tail = RECORD_AREA_OFFSET,
        .allocator_checkpoint_offset = 0,
        .allocator_checkpoint_size = 0,
        .allocator_checkpoint_epoch = 0,
        .free_bytes = 0,
        .pending_free_bytes = 0,
        .tail_free_bytes = 0,
        .clean_shutdown = 1,
        .flags = 0,
        .crc = 0,
    };
    try writeSuper(file, DATA_SUPERBLOCK_A_OFFSET, sb);
    try writeSuper(file, DATA_SUPERBLOCK_B_OFFSET, sb);
    switch (options.durability) {
        .none => {},
        .async => try pf.flushData(file),
        .sync => {
            try pf.flushData(file);
            try pf.flushMetadata(file);
        },
    }
}

fn loadAndMaybeRepair(file: pf.FileHandle, options: OpenOptions) !DataSuperBlock {
    const header = try readHeader(file);
    if (header.magic != DATA_FILE_MAGIC or header.major_version != 2 or header.endian != ENDIAN_LE) return error.Corruption;
    if (header.header_size != DATA_HEADER_SIZE or header.record_area_offset != RECORD_AREA_OFFSET or header.alignment != RECORD_ALIGNMENT) return error.Corruption;

    const a = readSuper(file, DATA_SUPERBLOCK_A_OFFSET) catch null;
    const b = readSuper(file, DATA_SUPERBLOCK_B_OFFSET) catch null;
    var chosen = if (a) |sa| if (b) |sb| if (sb.epoch > sa.epoch) sb else sa else sa else if (b) |sb| sb else return error.Corruption;

    if (options.repair_tail) {
        const scanned_tail = scanTail(file, chosen.logical_tail) catch chosen.logical_tail;
        if (scanned_tail > chosen.logical_tail) {
            chosen.epoch += 1;
            chosen.logical_tail = scanned_tail;
            chosen.file_size = @max(chosen.file_size, scanned_tail);
            chosen.durable_tail = scanned_tail;
            if (!options.read_only) {
                try writeSuper(file, DATA_SUPERBLOCK_A_OFFSET, chosen);
                try writeSuper(file, DATA_SUPERBLOCK_B_OFFSET, chosen);
                try pf.flushMetadata(file);
            }
        }
    }
    return chosen;
}

pub fn append(file: *DataFile, key: fmt.Key128, payload: []const u8, options: AppendOptions) !AppendResult {
    return dataAppend(file, key, payload, options);
}

pub fn appendBatch(file: *DataFile, allocator: std.mem.Allocator, records: []const BatchAppendInput) ![]AppendResult {
    if (records.len == 0) return allocator.alloc(AppendResult, 0);
    file.append_mutex.lock();
    defer file.append_mutex.unlock();

    var total_bytes: u64 = 0;
    var max_durability: fmt.Durability = .none;
    var publish_superblock = false;
    for (records) |rec| {
        if (rec.payload.len > std.math.maxInt(u32)) return error.InvalidArgument;
        if (rec.key_bytes.len > std.math.maxInt(u32)) return error.InvalidArgument;
        const total = @as(u64, RECORD_HEADER_SIZE) + rec.key_bytes.len + rec.payload.len + RECORD_FOOTER_SIZE;
        total_bytes += try fmt.alignUp(total, RECORD_ALIGNMENT);
        if (@intFromEnum(rec.options.durability) > @intFromEnum(max_durability)) max_durability = rec.options.durability;
        if (!rec.options.defer_superblock) publish_superblock = true;
    }

    const write_offset = file.logical_tail;
    const buf_len = std.math.cast(usize, total_bytes) orelse return error.InvalidArgument;
    var buf = try allocator.alloc(u8, buf_len);
    defer allocator.free(buf);
    var results = try allocator.alloc(AppendResult, records.len);
    errdefer allocator.free(results);

    var cursor: usize = 0;
    for (records, 0..) |rec, i| {
        const payload_crc = fmt.crc32c(rec.payload);
        var header_buf = encodeRecordHeader(.{
            .magic = RECORD_MAGIC,
            .header_version = 2,
            .flags = rec.options.flags,
            .key_hi = rec.key.hi,
            .key_lo = rec.key.lo,
            .version = rec.options.version,
            .header_size = RECORD_HEADER_SIZE,
            .stored_size = @intCast(rec.payload.len),
            .raw_size = @intCast(rec.payload.len),
            .header_crc = 0,
            .payload_crc = payload_crc,
            .key_size = @intCast(rec.key_bytes.len),
            .txn_id = rec.options.txn_id,
        });
        const header_crc = fmt.crc32c(&header_buf);
        fmt.writeU32Le(header_buf[40..44], header_crc);
        const record_crc = crcRecord(&header_buf, rec.key_bytes, rec.payload);
        var footer_buf = encodeRecordFooter(.{ .magic_commit = RECORD_FOOTER_MAGIC, .record_crc = record_crc });
        const total = @as(u64, RECORD_HEADER_SIZE) + rec.key_bytes.len + rec.payload.len + RECORD_FOOTER_SIZE;
        const aligned = try fmt.alignUp(total, RECORD_ALIGNMENT);
        const pad_len: usize = @intCast(aligned - total);

        const record_start = cursor;
        @memcpy(buf[cursor..][0..RECORD_HEADER_SIZE], &header_buf);
        cursor += RECORD_HEADER_SIZE;
        @memcpy(buf[cursor..][0..rec.key_bytes.len], rec.key_bytes);
        cursor += rec.key_bytes.len;
        @memcpy(buf[cursor..][0..rec.payload.len], rec.payload);
        cursor += rec.payload.len;
        @memcpy(buf[cursor..][0..RECORD_FOOTER_SIZE], &footer_buf);
        cursor += RECORD_FOOTER_SIZE;
        @memset(buf[cursor..][0..pad_len], 0);
        cursor += pad_len;

        results[i] = .{
            .offset = write_offset + record_start,
            .stored_size = @intCast(rec.payload.len),
            .raw_size = @intCast(rec.payload.len),
            .crc = payload_crc,
            .codec = rec.options.codec,
            .version = rec.options.version,
        };
    }

    try pf.pwriteAll(file.file, write_offset, buf);
    file.logical_tail = write_offset + total_bytes;
    file.epoch += records.len;
    if (publish_superblock) try publishSuper(file, max_durability);
    return results;
}

fn dataAppend(file: *DataFile, key: fmt.Key128, payload: []const u8, options: AppendOptions) !AppendResult {
    return dataAppendRawKey(file, key, &.{}, payload, options);
}

pub fn appendRawKey(file: *DataFile, key: fmt.Key128, key_bytes: []const u8, payload: []const u8, options: AppendOptions) !AppendResult {
    return dataAppendRawKey(file, key, key_bytes, payload, options);
}

fn dataAppendRawKey(file: *DataFile, key: fmt.Key128, key_bytes: []const u8, payload: []const u8, options: AppendOptions) !AppendResult {
    if (payload.len > std.math.maxInt(u32)) return error.InvalidArgument;
    if (key_bytes.len > std.math.maxInt(u32)) return error.InvalidArgument;
    file.append_mutex.lock();
    defer file.append_mutex.unlock();

    const offset = file.logical_tail;
    const payload_crc = fmt.crc32c(payload);
    var header_buf = encodeRecordHeader(.{
        .magic = RECORD_MAGIC,
        .header_version = 2,
        .flags = options.flags,
        .key_hi = key.hi,
        .key_lo = key.lo,
        .version = options.version,
        .header_size = RECORD_HEADER_SIZE,
        .stored_size = @intCast(payload.len),
        .raw_size = @intCast(payload.len),
        .header_crc = 0,
        .payload_crc = payload_crc,
        .key_size = @intCast(key_bytes.len),
        .txn_id = options.txn_id,
    });
    const header_crc = fmt.crc32c(&header_buf);
    fmt.writeU32Le(header_buf[40..44], header_crc);

    const record_crc = crcRecord(&header_buf, key_bytes, payload);
    var footer_buf = encodeRecordFooter(.{ .magic_commit = RECORD_FOOTER_MAGIC, .record_crc = record_crc });
    const total = @as(u64, RECORD_HEADER_SIZE) + key_bytes.len + payload.len + RECORD_FOOTER_SIZE;
    const aligned = try fmt.alignUp(total, RECORD_ALIGNMENT);
    const pad_len: usize = @intCast(aligned - total);
    var pad = [_]u8{0} ** RECORD_ALIGNMENT;

    try pf.pwritevAll(file.file, offset, &.{
        .{ .data = &header_buf },
        .{ .data = key_bytes },
        .{ .data = payload },
        .{ .data = &footer_buf },
        .{ .data = pad[0..pad_len] },
    });

    file.logical_tail = offset + aligned;
    file.epoch += 1;
    if (!options.defer_superblock) {
        try publishSuper(file, options.durability);
    }

    _ = options.codec;
    return .{
        .offset = offset,
        .stored_size = @intCast(payload.len),
        .raw_size = @intCast(payload.len),
        .crc = payload_crc,
        .codec = options.codec,
        .version = options.version,
    };
}

pub fn publishSuper(file: *DataFile, durability: fmt.Durability) !void {
    try publishSuperWithAllocator(file, durability, .{});
}

pub fn publishSuperWithAllocator(file: *DataFile, durability: fmt.Durability, alloc: AllocatorSuper) !void {
    const sb = DataSuperBlock{
        .magic = DATA_SUPER_MAGIC,
        .version = 2,
        .epoch = file.epoch,
        .file_size = @max(try pf.len(file.file), file.logical_tail),
        .logical_tail = file.logical_tail,
        .durable_tail = file.logical_tail,
        .allocator_checkpoint_offset = alloc.checkpoint_offset,
        .allocator_checkpoint_size = alloc.checkpoint_size,
        .allocator_checkpoint_epoch = alloc.checkpoint_epoch,
        .free_bytes = alloc.free_bytes,
        .pending_free_bytes = alloc.pending_free_bytes,
        .tail_free_bytes = alloc.tail_free_bytes,
        .clean_shutdown = 1,
        .flags = 0,
        .crc = 0,
    };
    try writeSuper(file.file, DATA_SUPERBLOCK_A_OFFSET, sb);
    try writeSuper(file.file, DATA_SUPERBLOCK_B_OFFSET, sb);

    switch (durability) {
        .none => {},
        .async => {},
        .sync => {
            try pf.flushData(file.file);
            try pf.flushMetadata(file.file);
        },
    }
}

pub fn currentSuper(file: *DataFile) !DataSuperBlock {
    const a = readSuper(file.file, DATA_SUPERBLOCK_A_OFFSET) catch null;
    const b = readSuper(file.file, DATA_SUPERBLOCK_B_OFFSET) catch null;
    return if (a) |sa| if (b) |sb| if (sb.epoch > sa.epoch) sb else sa else sa else if (b) |sb| sb else error.Corruption;
}

pub fn readMeta(file: *DataFile, offset: u64) !RecordMeta {
    return dataReadMeta(file, offset);
}

fn dataReadMeta(file: *DataFile, offset: u64) !RecordMeta {
    const parsed = try readAndValidateHeader(file.file, offset);
    return parsed.meta;
}

pub fn readPayload(file: *DataFile, offset: u64, key: fmt.Key128, dst: []u8) !usize {
    return dataReadPayload(file, offset, key, dst);
}

fn dataReadPayload(file: *DataFile, offset: u64, key: fmt.Key128, dst: []u8) !usize {
    return dataReadPayloadRawKeyMaybe(file, offset, key, null, dst);
}

pub fn readPayloadRawKey(file: *DataFile, offset: u64, key: fmt.Key128, key_bytes: []const u8, dst: []u8) !usize {
    return dataReadPayloadRawKey(file, offset, key, key_bytes, dst);
}

fn dataReadPayloadRawKey(file: *DataFile, offset: u64, key: fmt.Key128, key_bytes: []const u8, dst: []u8) !usize {
    return dataReadPayloadRawKeyMaybe(file, offset, key, key_bytes, dst);
}

fn dataReadPayloadRawKeyMaybe(file: *DataFile, offset: u64, key: fmt.Key128, maybe_key_bytes: ?[]const u8, dst: []u8) !usize {
    const fh = file.readHandle();
    const parsed = try readAndValidateHeader(fh, offset);
    if (parsed.meta.key.hi != key.hi or parsed.meta.key.lo != key.lo) return error.NotFound;
    if (maybe_key_bytes) |key_bytes| {
        if (key_bytes.len != parsed.meta.key_size) return error.NotFound;
        const stored_key = try std.heap.smp_allocator.alloc(u8, parsed.meta.key_size);
        defer std.heap.smp_allocator.free(stored_key);
        try readExact(fh, offset + RECORD_HEADER_SIZE, stored_key);
        if (!std.mem.eql(u8, stored_key, key_bytes)) return error.NotFound;
    }
    if (dst.len < parsed.meta.raw_size) return error.BufferTooSmall;
    try readExact(fh, offset + RECORD_HEADER_SIZE + parsed.meta.key_size, dst[0..parsed.meta.stored_size]);
    try verifyPayloadAndFooter(fh, offset, parsed.header_buf, dst[0..parsed.meta.stored_size], parsed.meta);
    return parsed.meta.raw_size;
}

/// Thread-local scratch for whole-record reads. It grows to the largest record
/// read on this thread and is intentionally never shrunk; a thread that reads
/// packs keeps at most one page-sized buffer alive.
threadlocal var record_scratch: []u8 = &.{};

fn recordScratch(len: usize) ![]u8 {
    if (record_scratch.len >= len) return record_scratch[0..len];
    const grown = @max(len, @max(record_scratch.len * 2, 4096));
    if (record_scratch.len != 0) {
        record_scratch = try std.heap.smp_allocator.realloc(record_scratch, grown);
    } else {
        record_scratch = try std.heap.smp_allocator.alloc(u8, grown);
    }
    return record_scratch[0..len];
}

fn dataReadRecordBorrow(file: *DataFile, offset: u64, key: fmt.Key128, key_bytes: []const u8, expected_stored_size: u32) ![]const u8 {
    const key_len: u64 = key_bytes.len;
    const total: u64 = @as(u64, RECORD_HEADER_SIZE) + key_len + expected_stored_size + RECORD_FOOTER_SIZE;
    const total_usize = std.math.cast(usize, total) orelse return error.InvalidArgument;
    const buf = try recordScratch(total_usize);
    try readExact(file.readHandle(), offset, buf);

    const header_buf: *const [RECORD_HEADER_SIZE]u8 = buf[0..RECORD_HEADER_SIZE];
    const meta = try parseAndValidateHeader(header_buf, offset);
    if (meta.key.hi != key.hi or meta.key.lo != key.lo) return error.NotFound;
    if (meta.key_size != key_bytes.len) return error.NotFound;
    if (meta.stored_size != expected_stored_size) return error.Corruption;

    const key_start: usize = RECORD_HEADER_SIZE;
    const payload_start: usize = key_start + key_bytes.len;
    const footer_start: usize = payload_start + meta.stored_size;
    const stored_key = buf[key_start..payload_start];
    if (!std.mem.eql(u8, stored_key, key_bytes)) return error.NotFound;
    const payload = buf[payload_start..footer_start];
    const footer = decodeRecordFooter(buf[footer_start..][0..RECORD_FOOTER_SIZE]);
    if (footer.magic_commit != RECORD_FOOTER_MAGIC) return error.Corruption;
    if (crcRecord(header_buf, stored_key, payload) != footer.record_crc) return error.ChecksumMismatch;
    return payload;
}

fn dataReadMetaCheckKey(file: *DataFile, offset: u64, key: fmt.Key128, key_bytes: []const u8) !RecordMeta {
    const total: usize = RECORD_HEADER_SIZE + key_bytes.len;
    const buf = try recordScratch(total);
    try readExact(file.readHandle(), offset, buf);
    const meta = try parseAndValidateHeader(buf[0..RECORD_HEADER_SIZE], offset);
    if (meta.key.hi != key.hi or meta.key.lo != key.lo) return error.NotFound;
    if (meta.key_size != key_bytes.len) return error.NotFound;
    if (!std.mem.eql(u8, buf[RECORD_HEADER_SIZE..total], key_bytes)) return error.NotFound;
    return meta;
}

pub fn verifyRecord(file: *DataFile, offset: u64) !RecordMeta {
    return dataVerifyRecord(file, offset);
}

fn dataVerifyRecord(file: *DataFile, offset: u64) !RecordMeta {
    const parsed = try readAndValidateHeader(file.file, offset);
    const allocator = std.heap.smp_allocator;
    const payload = try allocator.alloc(u8, parsed.meta.stored_size);
    defer allocator.free(payload);
    try readExact(file.file, offset + RECORD_HEADER_SIZE + parsed.meta.key_size, payload);
    try verifyPayloadAndFooter(file.file, offset, parsed.header_buf, payload, parsed.meta);
    return parsed.meta;
}

fn scanTail(file: pf.FileHandle, start_tail: u64) !u64 {
    _ = start_tail;
    var offset: u64 = RECORD_AREA_OFFSET;
    const file_len = try pf.len(file);
    var last_good = RECORD_AREA_OFFSET;
    while (offset + RECORD_HEADER_SIZE + RECORD_FOOTER_SIZE <= file_len) {
        const parsed = readAndValidateHeaderHandle(file, offset) catch break;
        const payload = try std.heap.smp_allocator.alloc(u8, parsed.meta.stored_size);
        defer std.heap.smp_allocator.free(payload);
        readExact(file, offset + RECORD_HEADER_SIZE + parsed.meta.key_size, payload) catch break;
        verifyPayloadAndFooter(file, offset, parsed.header_buf, payload, parsed.meta) catch break;
        last_good = offset + parsed.meta.aligned_size;
        offset = last_good;
    }
    return last_good;
}

const ParsedHeader = struct {
    header_buf: [RECORD_HEADER_SIZE]u8,
    meta: RecordMeta,
};

fn readAndValidateHeader(file: pf.FileHandle, offset: u64) !ParsedHeader {
    return readAndValidateHeaderHandle(file, offset);
}

fn readAndValidateHeaderHandle(file: pf.FileHandle, offset: u64) !ParsedHeader {
    var buf: [RECORD_HEADER_SIZE]u8 = undefined;
    try readExact(file, offset, &buf);
    return .{ .header_buf = buf, .meta = try parseAndValidateHeader(&buf, offset) };
}

fn parseAndValidateHeader(buf: *const [RECORD_HEADER_SIZE]u8, offset: u64) !RecordMeta {
    const magic = fmt.readU32Le(buf[0..4]);
    const header_version = fmt.readU16Le(buf[4..6]);
    const flags = fmt.readU16Le(buf[6..8]);
    const key_hi = fmt.readU64Le(buf[8..16]);
    const key_lo = fmt.readU64Le(buf[16..24]);
    const version = fmt.readU64Le(buf[24..32]);
    const header_size = fmt.readU32Le(buf[32..36]);
    const stored_size = fmt.readU32Le(buf[36..40]);
    const header_crc = fmt.readU32Le(buf[40..44]);
    const raw_size = fmt.readU32Le(buf[44..48]);
    const payload_crc = fmt.readU32Le(buf[48..52]);
    const key_size = fmt.readU32Le(buf[52..56]);
    const codec: u16 = 0;
    const txn_id = fmt.readU64Le(buf[56..64]);
    if (magic != RECORD_MAGIC or header_version != 2 or header_size != RECORD_HEADER_SIZE) return error.Corruption;
    if (stored_size != raw_size) return error.Corruption;
    var crc_buf = buf.*;
    fmt.writeU32Le(crc_buf[40..44], 0);
    if (fmt.crc32c(&crc_buf) != header_crc) return error.Corruption;
    const total = @as(u64, RECORD_HEADER_SIZE) + key_size + stored_size + RECORD_FOOTER_SIZE;
    const aligned = try fmt.alignUp(total, RECORD_ALIGNMENT);
    return .{
        .key = .{ .hi = key_hi, .lo = key_lo },
        .key_size = key_size,
        .offset = offset,
        .header_size = header_size,
        .stored_size = stored_size,
        .raw_size = raw_size,
        .payload_crc = payload_crc,
        .record_crc = 0,
        .flags = flags,
        .codec = codec,
        .version = version,
        .txn_id = txn_id,
        .total_size = total,
        .aligned_size = aligned,
    };
}

fn verifyPayloadAndFooter(file: pf.FileHandle, offset: u64, header_buf: [RECORD_HEADER_SIZE]u8, payload: []const u8, meta_in: RecordMeta) !void {
    if (fmt.crc32c(payload) != meta_in.payload_crc) return error.ChecksumMismatch;
    const key_bytes = try std.heap.smp_allocator.alloc(u8, meta_in.key_size);
    defer std.heap.smp_allocator.free(key_bytes);
    try readExact(file, offset + RECORD_HEADER_SIZE, key_bytes);
    var footer_buf: [RECORD_FOOTER_SIZE]u8 = undefined;
    try readExact(file, offset + RECORD_HEADER_SIZE + meta_in.key_size + meta_in.stored_size, &footer_buf);
    const footer = decodeRecordFooter(&footer_buf);
    if (footer.magic_commit != RECORD_FOOTER_MAGIC) return error.Corruption;
    if (crcRecord(&header_buf, key_bytes, payload) != footer.record_crc) return error.ChecksumMismatch;
}

fn crcRecord(header: *const [RECORD_HEADER_SIZE]u8, key_bytes: []const u8, payload: []const u8) u32 {
    var footer_magic: [4]u8 = undefined;
    fmt.writeU32Le(&footer_magic, RECORD_FOOTER_MAGIC);
    var state = fmt.crc32c_impl.update(fmt.crc32c_impl.init_state, header);
    state = fmt.crc32c_impl.update(state, key_bytes);
    state = fmt.crc32c_impl.update(state, payload);
    state = fmt.crc32c_impl.update(state, &footer_magic);
    return fmt.crc32c_impl.finish(state);
}

fn readExact(file: pf.FileHandle, offset: u64, dst: []u8) !void {
    const n = try pf.preadAll(file, offset, dst);
    if (n != dst.len) return error.UnexpectedEnd;
}

fn encodeRecordHeader(h: RecordHeader) [RECORD_HEADER_SIZE]u8 {
    var buf = [_]u8{0} ** RECORD_HEADER_SIZE;
    fmt.writeU32Le(buf[0..4], h.magic);
    fmt.writeU16Le(buf[4..6], h.header_version);
    fmt.writeU16Le(buf[6..8], h.flags);
    fmt.writeU64Le(buf[8..16], h.key_hi);
    fmt.writeU64Le(buf[16..24], h.key_lo);
    fmt.writeU64Le(buf[24..32], h.version);
    fmt.writeU32Le(buf[32..36], h.header_size);
    fmt.writeU32Le(buf[36..40], h.stored_size);
    fmt.writeU32Le(buf[40..44], h.header_crc);
    fmt.writeU32Le(buf[44..48], h.raw_size);
    fmt.writeU32Le(buf[48..52], h.payload_crc);
    fmt.writeU32Le(buf[52..56], h.key_size);
    fmt.writeU64Le(buf[56..64], h.txn_id);
    return buf;
}

fn encodeRecordFooter(f: RecordFooter) [RECORD_FOOTER_SIZE]u8 {
    var buf = [_]u8{0} ** RECORD_FOOTER_SIZE;
    fmt.writeU32Le(buf[0..4], f.magic_commit);
    fmt.writeU32Le(buf[4..8], f.record_crc);
    return buf;
}

fn decodeRecordFooter(buf: *const [RECORD_FOOTER_SIZE]u8) RecordFooter {
    return .{
        .magic_commit = fmt.readU32Le(buf[0..4]),
        .record_crc = fmt.readU32Le(buf[4..8]),
    };
}

fn writeHeader(file: pf.FileHandle, h: DataFileHeader) !void {
    var buf = [_]u8{0} ** DATA_HEADER_SIZE;
    fmt.writeU32Le(buf[0..4], h.magic);
    fmt.writeU16Le(buf[4..6], h.major_version);
    fmt.writeU16Le(buf[6..8], h.minor_version);
    fmt.writeU32Le(buf[8..12], h.endian);
    fmt.writeU32Le(buf[12..16], h.flags);
    fmt.writeU64Le(buf[16..24], h.header_size);
    fmt.writeU64Le(buf[24..32], h.superblock_a_offset);
    fmt.writeU64Le(buf[32..40], h.superblock_b_offset);
    fmt.writeU64Le(buf[40..48], h.record_area_offset);
    fmt.writeU64Le(buf[48..56], h.alignment);
    @memcpy(buf[56..72], &h.uuid);
    fmt.writeU32Le(buf[72..76], 0);
    const crc = fmt.crc32c(&buf);
    fmt.writeU32Le(buf[72..76], crc);
    try pf.pwriteAll(file, 0, &buf);
}

fn readHeader(file: pf.FileHandle) !DataFileHeader {
    var buf: [DATA_HEADER_SIZE]u8 = undefined;
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
        .flags = fmt.readU32Le(buf[12..16]),
        .header_size = fmt.readU64Le(buf[16..24]),
        .superblock_a_offset = fmt.readU64Le(buf[24..32]),
        .superblock_b_offset = fmt.readU64Le(buf[32..40]),
        .record_area_offset = fmt.readU64Le(buf[40..48]),
        .alignment = fmt.readU64Le(buf[48..56]),
        .uuid = uuid,
        .crc = stored_crc,
    };
}

fn writeSuper(file: pf.FileHandle, offset: u64, sb_in: DataSuperBlock) !void {
    var buf = [_]u8{0} ** DATA_SUPERBLOCK_SIZE;
    fmt.writeU32Le(buf[0..4], sb_in.magic);
    fmt.writeU32Le(buf[4..8], sb_in.version);
    fmt.writeU64Le(buf[8..16], sb_in.epoch);
    fmt.writeU64Le(buf[16..24], sb_in.file_size);
    fmt.writeU64Le(buf[24..32], sb_in.logical_tail);
    fmt.writeU64Le(buf[32..40], sb_in.durable_tail);
    fmt.writeU64Le(buf[40..48], sb_in.allocator_checkpoint_offset);
    fmt.writeU64Le(buf[48..56], sb_in.allocator_checkpoint_size);
    fmt.writeU64Le(buf[56..64], sb_in.allocator_checkpoint_epoch);
    fmt.writeU64Le(buf[64..72], sb_in.free_bytes);
    fmt.writeU64Le(buf[72..80], sb_in.pending_free_bytes);
    fmt.writeU64Le(buf[80..88], sb_in.tail_free_bytes);
    fmt.writeU32Le(buf[88..92], sb_in.clean_shutdown);
    fmt.writeU32Le(buf[92..96], sb_in.flags);
    fmt.writeU32Le(buf[96..100], 0);
    const crc = fmt.crc32c(&buf);
    fmt.writeU32Le(buf[96..100], crc);
    try pf.pwriteAll(file, offset, &buf);
}

fn readSuper(file: pf.FileHandle, offset: u64) !DataSuperBlock {
    var buf: [DATA_SUPERBLOCK_SIZE]u8 = undefined;
    try readExact(file, offset, &buf);
    const stored_crc = fmt.readU32Le(buf[96..100]);
    var crc_buf = buf;
    fmt.writeU32Le(crc_buf[96..100], 0);
    if (fmt.crc32c(&crc_buf) != stored_crc) return error.Corruption;
    const sb = DataSuperBlock{
        .magic = fmt.readU32Le(buf[0..4]),
        .version = fmt.readU32Le(buf[4..8]),
        .epoch = fmt.readU64Le(buf[8..16]),
        .file_size = fmt.readU64Le(buf[16..24]),
        .logical_tail = fmt.readU64Le(buf[24..32]),
        .durable_tail = fmt.readU64Le(buf[32..40]),
        .allocator_checkpoint_offset = fmt.readU64Le(buf[40..48]),
        .allocator_checkpoint_size = fmt.readU64Le(buf[48..56]),
        .allocator_checkpoint_epoch = fmt.readU64Le(buf[56..64]),
        .free_bytes = fmt.readU64Le(buf[64..72]),
        .pending_free_bytes = fmt.readU64Le(buf[72..80]),
        .tail_free_bytes = fmt.readU64Le(buf[80..88]),
        .clean_shutdown = fmt.readU32Le(buf[88..92]),
        .flags = fmt.readU32Le(buf[92..96]),
        .crc = stored_crc,
    };
    if (sb.magic != DATA_SUPER_MAGIC or sb.version != 2 or sb.logical_tail < RECORD_AREA_OFFSET) return error.Corruption;
    return sb;
}

comptime {
    std.debug.assert(@sizeOf(DataFileHeader) == DATA_HEADER_SIZE);
    std.debug.assert(@sizeOf(DataSuperBlock) == DATA_SUPERBLOCK_SIZE);
    std.debug.assert(@sizeOf(RecordHeader) == RECORD_HEADER_SIZE);
    std.debug.assert(@sizeOf(RecordFooter) == RECORD_FOOTER_SIZE);
}

test "data db create append read verify corruption truncation reopen" {
    const testing = std.testing;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var df = try createAt(tmp.dir, "data_000.db", .{ .durability = .sync });
    defer df.close() catch unreachable;

    var raw_header: [DATA_HEADER_SIZE]u8 = undefined;
    try readExact(df.file, 0, &raw_header);
    try testing.expectEqual(DATA_FILE_MAGIC, fmt.readU32Le(raw_header[0..4]));
    var raw_sb: [DATA_SUPERBLOCK_SIZE]u8 = undefined;
    try readExact(df.file, DATA_SUPERBLOCK_A_OFFSET, &raw_sb);
    try testing.expectEqual(DATA_SUPER_MAGIC, fmt.readU32Le(raw_sb[0..4]));

    const key: fmt.Key128 = .{ .hi = 1, .lo = 2 };
    const r1 = try append(&df, key, "hello", .{ .version = 1, .durability = .sync });
    var small: [5]u8 = undefined;
    try testing.expectEqual(@as(usize, 5), try readPayload(&df, r1.offset, key, &small));
    try testing.expectEqualStrings("hello", &small);

    const r2 = try append(&df, .{ .hi = 3, .lo = 4 }, "world!", .{ .version = 2 });
    const r3 = try append(&df, .{ .hi = 5, .lo = 6 }, "again", .{ .version = 3 });
    try testing.expect(r1.offset < r2.offset and r2.offset < r3.offset);
    try testing.expectEqual(@as(u64, 0), r1.offset % RECORD_ALIGNMENT);
    try testing.expectEqual(@as(u64, 0), r2.offset % RECORD_ALIGNMENT);
    try testing.expectEqual(@as(u64, 0), r3.offset % RECORD_ALIGNMENT);

    var too_small: [4]u8 = undefined;
    try testing.expectError(error.BufferTooSmall, readPayload(&df, r1.offset, key, &too_small));

    const big = try testing.allocator.alloc(u8, 8 * 1024 * 1024);
    defer testing.allocator.free(big);
    for (big, 0..) |*b, i| b.* = @intCast(i % 251);
    const big_key: fmt.Key128 = .{ .hi = 0xabc, .lo = 0xdef };
    const rb = try append(&df, big_key, big, .{ .version = 4, .durability = .sync });
    const big_out = try testing.allocator.alloc(u8, big.len);
    defer testing.allocator.free(big_out);
    try testing.expectEqual(big.len, try readPayload(&df, rb.offset, big_key, big_out));
    try testing.expectEqualSlices(u8, big, big_out);

    const tail_before_close = df.logical_tail;
    try df.close();

    var reopened = try openAt(tmp.dir, "data_000.db", .{});
    try testing.expectEqual(tail_before_close, reopened.logical_tail);
    try testing.expect((try pf.len(reopened.file)) >= tail_before_close);
    var reread: [5]u8 = undefined;
    try testing.expectEqual(@as(usize, 5), try readPayload(&reopened, r1.offset, key, &reread));
    try testing.expectEqualStrings("hello", &reread);

    try pf.pwriteAll(reopened.file, r1.offset, "BAD!");
    try testing.expectError(error.Corruption, verifyRecord(&reopened, r1.offset));
    try pf.pwriteAll(reopened.file, r1.offset, raw_header[0..4]); // leave file usable enough for later offsets unrelated to r1

    const corrupt_payload_offset = r2.offset + RECORD_HEADER_SIZE;
    var one: [1]u8 = undefined;
    try readExact(reopened.file, corrupt_payload_offset, &one);
    one[0] ^= 0xff;
    try pf.pwriteAll(reopened.file, corrupt_payload_offset, &one);
    try testing.expectError(error.ChecksumMismatch, verifyRecord(&reopened, r2.offset));

    try pf.setLen(reopened.file, r3.offset + RECORD_HEADER_SIZE + 2);
    try testing.expectError(error.UnexpectedEnd, verifyRecord(&reopened, r3.offset));
    pf.close(&reopened.file);
}

test "data db single-read record borrow validates key footer and crc, read handle pool shares content" {
    const testing = std.testing;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var df = try createAt(tmp.dir, "data_000.db", .{ .durability = .sync });
    const key: fmt.Key128 = .{ .hi = 0x11, .lo = 0x22 };
    const key_bytes = "raw-key";
    const payload = "borrowed-payload-bytes";
    const r = try appendRawKey(&df, key, key_bytes, payload, .{ .version = 1, .durability = .sync });
    const other = try appendRawKey(&df, .{ .hi = 0x33, .lo = 0x44 }, "k2", "second", .{ .version = 1, .durability = .sync });
    try df.close();

    var ro = try openIn(.fromOs(tmp.dir), "data_000.db", .{ .read_only = true, .read_handles = 3 });
    defer ro.close() catch unreachable;
    try testing.expectEqual(@as(u8, 3), ro.read_file_count);

    const got = try ro.readRecordBorrow(r.offset, key, key_bytes, r.stored_size);
    try testing.expectEqualStrings(payload, got);
    const meta = try ro.readMetaCheckKey(r.offset, key, key_bytes);
    try testing.expectEqual(@as(u32, payload.len), meta.raw_size);

    try testing.expectError(error.NotFound, ro.readRecordBorrow(r.offset, .{ .hi = 0x11, .lo = 0x23 }, key_bytes, r.stored_size));
    try testing.expectError(error.NotFound, ro.readRecordBorrow(r.offset, key, "raw-keY", r.stored_size));
    try testing.expectError(error.NotFound, ro.readRecordBorrow(r.offset, key, "raw-ke", r.stored_size));
    try testing.expectError(error.NotFound, ro.readMetaCheckKey(r.offset, key, "raw-keY"));
    try testing.expectError(error.Corruption, ro.readRecordBorrow(r.offset, key, key_bytes, r.stored_size + 1));

    const second = try ro.readRecordBorrow(other.offset, .{ .hi = 0x33, .lo = 0x44 }, "k2", other.stored_size);
    try testing.expectEqualStrings("second", second);

    var rw = try openAt(tmp.dir, "data_000.db", .{});
    defer rw.close() catch unreachable;
    const flip_offset = r.offset + RECORD_HEADER_SIZE + key_bytes.len + 3;
    var one: [1]u8 = undefined;
    try readExact(rw.file, flip_offset, &one);
    one[0] ^= 0x55;
    try pf.pwriteAll(rw.file, flip_offset, &one);
    try testing.expectError(error.ChecksumMismatch, rw.readRecordBorrow(r.offset, key, key_bytes, r.stored_size));
    one[0] ^= 0x55;
    try pf.pwriteAll(rw.file, flip_offset, &one);
    try testing.expectEqualStrings(payload, try rw.readRecordBorrow(r.offset, key, key_bytes, r.stored_size));

    const footer_offset = r.offset + RECORD_HEADER_SIZE + key_bytes.len + payload.len;
    try pf.pwriteAll(rw.file, footer_offset, "XXXX");
    try testing.expectError(error.Corruption, rw.readRecordBorrow(r.offset, key, key_bytes, r.stored_size));
}
