//! RLE coding for the subDiff stream (byte-wise `new - old` inside covers).
//! Two streams: `ctrl` (type in low 2 bits + length varint) and `code`
//! (literal bytes). Types: run of 0x00, run of 0xFF, run of one byte, literal.
const std = @import("std");
const varint = @import("varint.zig");

pub const Type = enum(u2) { run_0 = 0, run_ff = 1, run_byte = 2, literal = 3 };

pub const Encoded = struct {
    ctrl: std.ArrayList(u8) = .empty,
    code: std.ArrayList(u8) = .empty,

    pub fn deinit(self: *Encoded, allocator: std.mem.Allocator) void {
        self.ctrl.deinit(allocator);
        self.code.deinit(allocator);
    }
};

fn pushCtrl(enc: *Encoded, allocator: std.mem.Allocator, t: Type, len: usize) !void {
    // len >= 1; store (len-1) << 2 | type
    const v: u64 = (@as(u64, len - 1) << 2) | @intFromEnum(t);
    try varint.write(&enc.ctrl, allocator, v);
}

const MIN_RUN: usize = 3;

pub fn encode(allocator: std.mem.Allocator, data: []const u8) !Encoded {
    var enc: Encoded = .{};
    errdefer enc.deinit(allocator);
    var i: usize = 0;
    var lit_start: usize = 0;
    while (i < data.len) {
        // Measure run at i.
        var run: usize = 1;
        while (i + run < data.len and data[i + run] == data[i]) run += 1;
        if (run >= MIN_RUN) {
            if (i > lit_start) {
                try pushCtrl(&enc, allocator, .literal, i - lit_start);
                try enc.code.appendSlice(allocator, data[lit_start..i]);
            }
            const t: Type = if (data[i] == 0) .run_0 else if (data[i] == 0xff) .run_ff else .run_byte;
            try pushCtrl(&enc, allocator, t, run);
            if (t == .run_byte) try enc.code.append(allocator, data[i]);
            i += run;
            lit_start = i;
        } else {
            i += run;
        }
    }
    if (data.len > lit_start) {
        try pushCtrl(&enc, allocator, .literal, data.len - lit_start);
        try enc.code.appendSlice(allocator, data[lit_start..]);
    }
    return enc;
}

/// Streaming decoder: yields one byte per `next()`, exactly `total` bytes.
pub const Decoder = struct {
    ctrl: varint.Reader,
    code: []const u8,
    code_pos: usize = 0,
    remaining_total: u64,
    cur_type: Type = .literal,
    cur_left: usize = 0,
    cur_byte: u8 = 0,

    pub fn init(ctrl: []const u8, code: []const u8, total: u64) Decoder {
        return .{ .ctrl = .{ .bytes = ctrl }, .code = code, .remaining_total = total };
    }

    pub fn next(self: *Decoder) !u8 {
        if (self.remaining_total == 0) return error.Corruption;
        if (self.cur_left == 0) try self.load();
        self.cur_left -= 1;
        self.remaining_total -= 1;
        switch (self.cur_type) {
            .run_0 => return 0,
            .run_ff => return 0xff,
            .run_byte => return self.cur_byte,
            .literal => {
                if (self.code_pos >= self.code.len) return error.Corruption;
                const b = self.code[self.code_pos];
                self.code_pos += 1;
                return b;
            },
        }
    }

    /// Adds `len` decoded bytes to `dst[0..len]` (dst[i] +%= sub[i]).
    pub fn addTo(self: *Decoder, dst: []u8) !void {
        for (dst) |*d| d.* +%= try self.next();
    }

    fn load(self: *Decoder) !void {
        const v = try self.ctrl.read(u64);
        const t: Type = @enumFromInt(@as(u2, @intCast(v & 3)));
        const len = std.math.cast(usize, (v >> 2) + 1) orelse return error.Corruption;
        if (len > self.remaining_total) return error.Corruption;
        self.cur_type = t;
        self.cur_left = len;
        if (t == .run_byte) {
            if (self.code_pos >= self.code.len) return error.Corruption;
            self.cur_byte = self.code[self.code_pos];
            self.code_pos += 1;
        }
    }

    pub fn finished(self: *const Decoder) bool {
        return self.remaining_total == 0 and self.cur_left == 0 and self.ctrl.atEnd() and self.code_pos == self.code.len;
    }
};

test "rle roundtrip mixed runs and literals" {
    const allocator = std.testing.allocator;
    var prng = std.Random.DefaultPrng.init(3);
    const rnd = prng.random();
    var round: usize = 0;
    while (round < 30) : (round += 1) {
        const n = rnd.intRangeAtMost(usize, 0, 3000);
        const buf = try allocator.alloc(u8, n);
        defer allocator.free(buf);
        var i: usize = 0;
        while (i < n) {
            const kind = rnd.uintLessThan(u8, 4);
            const len = @min(n - i, rnd.intRangeAtMost(usize, 1, 40));
            switch (kind) {
                0 => @memset(buf[i .. i + len], 0),
                1 => @memset(buf[i .. i + len], 0xff),
                2 => @memset(buf[i .. i + len], rnd.int(u8)),
                else => rnd.bytes(buf[i .. i + len]),
            }
            i += len;
        }
        var enc = try encode(allocator, buf);
        defer enc.deinit(allocator);
        var dec = Decoder.init(enc.ctrl.items, enc.code.items, n);
        for (buf) |b| try std.testing.expectEqual(b, try dec.next());
        try std.testing.expect(dec.finished());
        try std.testing.expectError(error.Corruption, dec.next());
    }
    // Mostly-zero input compresses well.
    const zeros = [_]u8{0} ** 10000;
    var enc = try encode(allocator, &zeros);
    defer enc.deinit(allocator);
    try std.testing.expect(enc.ctrl.items.len + enc.code.items.len < 8);
}

test "rle decoder rejects truncated streams" {
    var dec = Decoder.init(&.{}, &.{}, 5);
    try std.testing.expectError(error.Corruption, dec.next());
    var dec2 = Decoder.init(&.{0x0b}, &.{}, 3); // literal len 3 but no code bytes
    try std.testing.expectError(error.Corruption, dec2.next());
    var dec3 = Decoder.init(&.{0x3c}, &.{}, 3); // run_0 len 16 > total 3
    try std.testing.expectError(error.Corruption, dec3.next());
}
