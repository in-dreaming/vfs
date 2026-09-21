const std = @import("std");

pub const ABI_VERSION: u32 = 2;
pub const FORMAT_VERSION: u32 = 2;
pub const MANIFEST_MAGIC: u64 = magic("DBMANV1!");
pub const INDEX_MAGIC: u64 = magic("DBIDXV1!");
pub const DATA_MAGIC: u64 = magic("DBDATV1!");

pub const Key128 = extern struct {
    hi: u64,
    lo: u64,
};

pub const IndexInfo = extern struct {
    data_db_id: u32,
    flags: u32,
    offset: u64,
    stored_size: u32,
    raw_size: u32,
    version: u64,
    crc: u32,
    codec: u16,
    reserved: u16,
};

pub const Durability = enum(c_int) {
    none = 0,
    async = 1,
    sync = 2,
};

pub const DbStatus = enum(c_int) {
    ok = 0,
    not_found = 1,
    invalid_argument = 2,
    io_error = 3,
    corruption = 4,
    checksum_mismatch = 5,
    unsupported_version = 6,
    busy = 7,
    no_space = 8,
    permission_denied = 9,
    unsupported = 10,
    internal_error = 100,
};

pub const Error = error{
    NotFound,
    InvalidArgument,
    IoError,
    Corruption,
    ChecksumMismatch,
    UnsupportedVersion,
    Busy,
    NoSpace,
    PermissionDenied,
    Unsupported,
    Overflow,
};

pub fn statusFromError(err: anyerror) DbStatus {
    return switch (err) {
        error.NotFound, error.FileNotFound => .not_found,
        error.InvalidArgument => .invalid_argument,
        error.Corruption => .corruption,
        error.ChecksumMismatch => .checksum_mismatch,
        error.UnsupportedVersion => .unsupported_version,
        error.Unsupported => .unsupported,
        error.Busy, error.DeviceBusy, error.FileBusy, error.WouldBlock => .busy,
        error.NoSpace, error.NoSpaceLeft => .no_space,
        error.PermissionDenied, error.AccessDenied => .permission_denied,
        else => .io_error,
    };
}

pub fn magic(comptime s: []const u8) u64 {
    comptime {
        if (s.len != 8) @compileError("DB magic must be exactly 8 bytes");
    }
    var out: u64 = 0;
    inline for (s, 0..) |c, i| {
        out |= @as(u64, c) << @intCast(i * 8);
    }
    return out;
}

pub fn writeU16Le(dst: *[2]u8, value: u16) void {
    std.mem.writeInt(u16, dst, value, .little);
}

pub fn readU16Le(src: *const [2]u8) u16 {
    return std.mem.readInt(u16, src, .little);
}

pub fn writeU32Le(dst: *[4]u8, value: u32) void {
    std.mem.writeInt(u32, dst, value, .little);
}

pub fn readU32Le(src: *const [4]u8) u32 {
    return std.mem.readInt(u32, src, .little);
}

pub fn writeU64Le(dst: *[8]u8, value: u64) void {
    std.mem.writeInt(u64, dst, value, .little);
}

pub fn readU64Le(src: *const [8]u8) u64 {
    return std.mem.readInt(u64, src, .little);
}

pub fn alignUp(value: u64, alignment: u64) Error!u64 {
    if (alignment == 0 or !std.math.isPowerOfTwo(alignment)) return error.InvalidArgument;
    const add = checkedAdd(value, alignment - 1) catch return error.Overflow;
    return add & ~(alignment - 1);
}

pub fn ceilLog2(value: u64) Error!u6 {
    if (value == 0) return error.InvalidArgument;
    if (value <= 1) return 0;
    return @as(u6, @intCast(64 - @clz(value - 1)));
}

pub fn checkedAdd(a: u64, b: u64) Error!u64 {
    return std.math.add(u64, a, b) catch error.Overflow;
}

pub fn checkedMul(a: u64, b: u64) Error!u64 {
    return std.math.mul(u64, a, b) catch error.Overflow;
}

pub const crc32c_impl = @import("crc32c.zig");

/// CRC32C (Castagnoli) in reflected bit order.
///
/// Parameters:
/// - polynomial: 0x1EDC6F41 normal, 0x82F63B78 reflected
/// - init: 0xffffffff
/// - refin/refout: true
/// - xorout: 0xffffffff
///
/// Standard vector: crc32c("123456789") == 0xe3069283.
/// Backed by a hardware instruction when the target supports one; see crc32c.zig.
pub fn crc32c(bytes: []const u8) u32 {
    return crc32c_impl.hash(bytes);
}

/// Continue a CRC32C whose final value was `previous` over `bytes`, as if the
/// two byte ranges had been hashed as one contiguous buffer.
pub fn crc32cContinue(previous: u32, bytes: []const u8) u32 {
    return crc32c_impl.hashContinue(previous, bytes);
}

fn mix64(x: u64) u64 {
    var z = x;
    z = (z ^ (z >> 30)) *% 0xbf58476d1ce4e5b9;
    z = (z ^ (z >> 27)) *% 0x94d049bb133111eb;
    return z ^ (z >> 31);
}

/// Deterministic Key128 -> hash64 mixer for bucket selection.
///
/// V1 algorithm:
/// h = splitmix64(key.hi ^ rotl(key.lo, 32) ^ 0x9e3779b97f4a7c15)
///
/// It uses fixed constants only: no process address, random seed, CPU endian,
/// or platform-specific state can affect the result.
pub fn mixHash128To64(key: Key128) u64 {
    return mix64(key.hi ^ std.math.rotl(u64, key.lo, 32) ^ 0x9e3779b97f4a7c15);
}

pub fn hashBytes128(bytes: []const u8) Key128 {
    var hi_hasher = std.hash.Wyhash.init(0x44424b4559324849);
    hi_hasher.update(bytes);
    var lo_hasher = std.hash.Wyhash.init(0x44424b4559324c4f);
    lo_hasher.update(bytes);
    return .{ .hi = hi_hasher.final(), .lo = lo_hasher.final() };
}

comptime {
    std.debug.assert(@sizeOf(Key128) == 16);
    std.debug.assert(@alignOf(Key128) == 8);
    std.debug.assert(@sizeOf(IndexInfo) == 40);
    std.debug.assert(@alignOf(IndexInfo) == 8);
}

test "disk struct size and alignment are fixed" {
    try std.testing.expectEqual(@as(usize, 16), @sizeOf(Key128));
    try std.testing.expectEqual(@as(usize, 8), @alignOf(Key128));
    try std.testing.expectEqual(@as(usize, 40), @sizeOf(IndexInfo));
    try std.testing.expectEqual(@as(usize, 8), @alignOf(IndexInfo));
}

test "little-endian helpers encode and decode fixed-width integers" {
    var b16: [2]u8 = undefined;
    var b32: [4]u8 = undefined;
    var b64: [8]u8 = undefined;

    writeU16Le(&b16, 0x1234);
    writeU32Le(&b32, 0x12345678);
    writeU64Le(&b64, 0x0123456789abcdef);

    try std.testing.expectEqualSlices(u8, &.{ 0x34, 0x12 }, &b16);
    try std.testing.expectEqualSlices(u8, &.{ 0x78, 0x56, 0x34, 0x12 }, &b32);
    try std.testing.expectEqualSlices(u8, &.{ 0xef, 0xcd, 0xab, 0x89, 0x67, 0x45, 0x23, 0x01 }, &b64);

    try std.testing.expectEqual(@as(u16, 0x1234), readU16Le(&b16));
    try std.testing.expectEqual(@as(u32, 0x12345678), readU32Le(&b32));
    try std.testing.expectEqual(@as(u64, 0x0123456789abcdef), readU64Le(&b64));
}

test "crc32c fixed vectors" {
    try std.testing.expectEqual(@as(u32, 0x00000000), crc32c(""));
    try std.testing.expectEqual(@as(u32, 0xe3069283), crc32c("123456789"));
    try std.testing.expectEqual(crc32c("123456789"), crc32cContinue(crc32c("1234"), "56789"));
}

test {
    _ = crc32c_impl;
}

test "mixHash128To64 fixed vectors" {
    const cases = [_]struct { key: Key128, hash: u64 }{
        .{ .key = .{ .hi = 0x0000000000000000, .lo = 0x0000000000000000 }, .hash = 0xe220a8397b1dcdaf },
        .{ .key = .{ .hi = 0x0000000000000000, .lo = 0x0000000000000001 }, .hash = 0x219fc13d6bc5b015 },
        .{ .key = .{ .hi = 0x0000000000000001, .lo = 0x0000000000000000 }, .hash = 0xe4d971771b652c20 },
        .{ .key = .{ .hi = 0x0123456789abcdef, .lo = 0xfedcba9876543210 }, .hash = 0xa1decf60443515f2 },
        .{ .key = .{ .hi = 0xffffffffffffffff, .lo = 0x0123456789abcdef }, .hash = 0xace379eefab563b2 },
        .{ .key = .{ .hi = 0x13579bdf2468ace0, .lo = 0x02468ace13579bdf }, .hash = 0x65508f90307064bb },
        .{ .key = .{ .hi = 0xaaaaaaaaaaaaaaaa, .lo = 0x0123456789abcdef }, .hash = 0xd601db2081b505af },
        .{ .key = .{ .hi = 0xdeadbeefcafebabe, .lo = 0x1122334455667788 }, .hash = 0x4da28b137d6ae086 },
    };
    for (cases) |case| {
        try std.testing.expectEqual(case.hash, mixHash128To64(case.key));
    }
}

test "alignment and checked arithmetic helpers" {
    const expected = [_]struct { value: u64, aligned: u64 }{
        .{ .value = 0, .aligned = 0 },
        .{ .value = 1, .aligned = 4096 },
        .{ .value = 15, .aligned = 4096 },
        .{ .value = 16, .aligned = 4096 },
        .{ .value = 17, .aligned = 4096 },
        .{ .value = 4095, .aligned = 4096 },
        .{ .value = 4096, .aligned = 4096 },
        .{ .value = 4097, .aligned = 8192 },
    };
    for (expected) |case| {
        try std.testing.expectEqual(case.aligned, try alignUp(case.value, 4096));
    }

    try std.testing.expectEqual(@as(u6, 0), try ceilLog2(1));
    try std.testing.expectEqual(@as(u6, 1), try ceilLog2(2));
    try std.testing.expectEqual(@as(u6, 2), try ceilLog2(3));
    try std.testing.expectEqual(@as(u6, 12), try ceilLog2(4096));
    try std.testing.expectError(error.InvalidArgument, ceilLog2(0));
    try std.testing.expectError(error.InvalidArgument, alignUp(1, 0));
    try std.testing.expectError(error.InvalidArgument, alignUp(1, 3));
    try std.testing.expectError(error.Overflow, checkedAdd(std.math.maxInt(u64), 1));
    try std.testing.expectError(error.Overflow, checkedMul(std.math.maxInt(u64), 2));
}
