//! 7-bit little-endian varints, plus a signed variant used for cover
//! `old_pos` deltas (sign bit in the first byte's bit 6, as HDiffPatch does).
const std = @import("std");

pub fn write(out: *std.ArrayList(u8), allocator: std.mem.Allocator, value_in: u64) !void {
    var v = value_in;
    while (v >= 0x80) : (v >>= 7) try out.append(allocator, @intCast((v & 0x7f) | 0x80));
    try out.append(allocator, @intCast(v));
}

/// Signed: first byte carries 6 payload bits + sign (bit 6) + continuation (bit 7).
pub fn writeSigned(out: *std.ArrayList(u8), allocator: std.mem.Allocator, value: i64) !void {
    const neg = value < 0;
    var mag: u64 = if (neg) @intCast(-value) else @intCast(value);
    var first: u8 = @intCast(mag & 0x3f);
    mag >>= 6;
    if (neg) first |= 0x40;
    if (mag != 0) first |= 0x80;
    try out.append(allocator, first);
    while (mag != 0) {
        var b: u8 = @intCast(mag & 0x7f);
        mag >>= 7;
        if (mag != 0) b |= 0x80;
        try out.append(allocator, b);
    }
}

pub const Reader = struct {
    bytes: []const u8,
    pos: usize = 0,

    pub fn read(self: *Reader, comptime T: type) !T {
        var shift: u7 = 0;
        var v: u64 = 0;
        while (true) {
            if (self.pos >= self.bytes.len) return error.Corruption;
            const b = self.bytes[self.pos];
            self.pos += 1;
            if (shift >= 64) return error.Corruption;
            v |= @as(u64, b & 0x7f) << @intCast(shift);
            if (b & 0x80 == 0) break;
            shift += 7;
        }
        return std.math.cast(T, v) orelse error.Corruption;
    }

    pub fn readSigned(self: *Reader) !i64 {
        if (self.pos >= self.bytes.len) return error.Corruption;
        const first = self.bytes[self.pos];
        self.pos += 1;
        var mag: u64 = first & 0x3f;
        const neg = (first & 0x40) != 0;
        var shift: u7 = 6;
        var more = (first & 0x80) != 0;
        while (more) {
            if (self.pos >= self.bytes.len) return error.Corruption;
            const b = self.bytes[self.pos];
            self.pos += 1;
            if (shift >= 64) return error.Corruption;
            mag |= @as(u64, b & 0x7f) << @intCast(shift);
            shift += 7;
            more = (b & 0x80) != 0;
        }
        if (mag > std.math.maxInt(i64)) return error.Corruption;
        const m: i64 = @intCast(mag);
        return if (neg) -m else m;
    }

    pub fn atEnd(self: *const Reader) bool {
        return self.pos == self.bytes.len;
    }
};

test "varint roundtrip unsigned and signed" {
    const allocator = std.testing.allocator;
    var out = std.ArrayList(u8).empty;
    defer out.deinit(allocator);
    const values = [_]u64{ 0, 1, 127, 128, 300, 1 << 20, std.math.maxInt(u32), std.math.maxInt(u64) };
    for (values) |v| try write(&out, allocator, v);
    const svalues = [_]i64{ 0, 1, -1, 63, -63, 64, -64, 1 << 30, -(1 << 30), std.math.maxInt(i64), std.math.minInt(i64) + 1 };
    for (svalues) |v| try writeSigned(&out, allocator, v);
    var r = Reader{ .bytes = out.items };
    for (values) |v| try std.testing.expectEqual(v, try r.read(u64));
    for (svalues) |v| try std.testing.expectEqual(v, try r.readSigned());
    try std.testing.expect(r.atEnd());
    var bad = Reader{ .bytes = &.{ 0x80, 0x80 } };
    try std.testing.expectError(error.Corruption, bad.read(u32));
    var overflow = Reader{ .bytes = &.{ 0xff, 0xff, 0x7f } };
    try std.testing.expectError(error.Corruption, overflow.read(u8));
}
