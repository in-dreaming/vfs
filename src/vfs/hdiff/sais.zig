//! Suffix array construction (SA-IS, Nong/Zhang/Chan) for byte strings.
//! Linear time and O(n) extra memory. Indices are `i32`, so inputs are
//! limited to 2^31-1 bytes; callers shard larger inputs.
const std = @import("std");

pub const Index = i32;
pub const MAX_INPUT: usize = std.math.maxInt(i32);

/// Builds the suffix array of `text` into `sa` (`sa.len == text.len`).
pub fn build(allocator: std.mem.Allocator, text: []const u8, sa: []Index) !void {
    if (text.len != sa.len) return error.InvalidArgument;
    if (text.len > MAX_INPUT) return error.InvalidArgument;
    if (text.len == 0) return;
    if (text.len == 1) {
        sa[0] = 0;
        return;
    }
    const bucket = try allocator.alloc(Index, 256);
    defer allocator.free(bucket);
    try saisMain(allocator, ByteText{ .bytes = text }, sa, 256, bucket);
}

const ByteText = struct {
    bytes: []const u8,
    inline fn at(self: ByteText, i: usize) usize {
        return self.bytes[i];
    }
    inline fn len(self: ByteText) usize {
        return self.bytes.len;
    }
};

const IntText = struct {
    ints: []const Index,
    inline fn at(self: IntText, i: usize) usize {
        return @intCast(self.ints[i]);
    }
    inline fn len(self: IntText) usize {
        return self.ints.len;
    }
};

inline fn isLms(t: []const bool, i: usize) bool {
    return i > 0 and t[i] and !t[i - 1];
}

fn classify(comptime T: type, text: T, t: []bool) void {
    const n = text.len();
    t[n - 1] = false; // last is L (sentinel is smaller)
    var i: usize = n - 1;
    while (i > 0) : (i -= 1) {
        const a = text.at(i - 1);
        const b = text.at(i);
        t[i - 1] = if (a < b) true else if (a > b) false else t[i];
    }
}

fn getBuckets(comptime T: type, text: T, bucket: []Index, k: usize, end: bool) void {
    @memset(bucket[0..k], 0);
    var i: usize = 0;
    while (i < text.len()) : (i += 1) bucket[text.at(i)] += 1;
    var sum: Index = 0;
    i = 0;
    while (i < k) : (i += 1) {
        sum += bucket[i];
        bucket[i] = if (end) sum else sum - bucket[i];
    }
}

fn induceSal(comptime T: type, text: T, sa: []Index, t: []const bool, bucket: []Index, k: usize) void {
    getBuckets(T, text, bucket, k, false);
    const n = text.len();
    // Sentinel suffix (virtual, index n) precedes suffix n-1 which is L.
    var j: usize = n - 1;
    sa[@intCast(bucket[text.at(j)])] = @intCast(j);
    bucket[text.at(j)] += 1;
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const v = sa[i];
        if (v <= 0) continue;
        j = @intCast(v - 1);
        if (!t[j]) {
            sa[@intCast(bucket[text.at(j)])] = @intCast(j);
            bucket[text.at(j)] += 1;
        }
    }
}

fn induceSas(comptime T: type, text: T, sa: []Index, t: []const bool, bucket: []Index, k: usize) void {
    getBuckets(T, text, bucket, k, true);
    const n = text.len();
    var i: usize = n;
    while (i > 0) {
        i -= 1;
        const v = sa[i];
        if (v <= 0) continue;
        const j: usize = @intCast(v - 1);
        if (t[j]) {
            bucket[text.at(j)] -= 1;
            sa[@intCast(bucket[text.at(j)])] = @intCast(j);
        }
    }
}

fn saisMain(allocator: std.mem.Allocator, text: anytype, sa: []Index, k: usize, bucket: []Index) !void {
    const T = @TypeOf(text);
    const n = text.len();
    const t = try allocator.alloc(bool, n);
    defer allocator.free(t);
    classify(T, text, t);

    // Stage 1: place LMS suffixes at bucket ends, induce-sort.
    getBuckets(T, text, bucket, k, true);
    @memset(sa, -1);
    var i: usize = 1;
    while (i < n) : (i += 1) {
        if (isLms(t, i)) {
            bucket[text.at(i)] -= 1;
            sa[@intCast(bucket[text.at(i)])] = @intCast(i);
        }
    }
    induceSal(T, text, sa, t, bucket, k);
    induceSas(T, text, sa, t, bucket, k);

    // Compact sorted LMS substrings into the first n1 slots.
    var n1: usize = 0;
    i = 0;
    while (i < n) : (i += 1) {
        const v = sa[i];
        if (v >= 0 and isLms(t, @intCast(v))) {
            sa[n1] = v;
            n1 += 1;
        }
    }
    @memset(sa[n1..], -1);

    // Name LMS substrings.
    var name: Index = 0;
    var prev: Index = -1;
    i = 0;
    while (i < n1) : (i += 1) {
        const pos: usize = @intCast(sa[i]);
        var diff = false;
        if (prev < 0) {
            diff = true;
        } else {
            const p: usize = @intCast(prev);
            var d: usize = 0;
            while (d < n) : (d += 1) {
                const a = pos + d;
                const b = p + d;
                if (a >= n or b >= n) {
                    diff = true;
                    break;
                }
                if (text.at(a) != text.at(b) or t[a] != t[b]) {
                    diff = true;
                    break;
                }
                if (d > 0 and (isLms(t, a) or isLms(t, b))) break;
            }
        }
        if (diff) {
            name += 1;
            prev = @intCast(pos);
        }
        // store name at sa[n1 + pos/2]
        sa[n1 + pos / 2] = name - 1;
    }
    // Gather names in text order into the tail.
    var j: usize = n;
    i = n;
    while (i > n1) {
        i -= 1;
        if (sa[i] >= 0) {
            j -= 1;
            sa[j] = sa[i];
        }
    }
    const s1 = sa[n - n1 .. n];
    const sa1 = sa[0..n1];

    // Stage 2: recurse or directly sort if names are unique.
    if (@as(usize, @intCast(name)) < n1) {
        const bucket1 = try allocator.alloc(Index, @intCast(name));
        defer allocator.free(bucket1);
        const s1_copy = try allocator.dupe(Index, s1);
        defer allocator.free(s1_copy);
        try saisMain(allocator, IntText{ .ints = s1_copy }, sa1, @intCast(name), bucket1);
    } else {
        i = 0;
        while (i < n1) : (i += 1) sa1[@intCast(s1[i])] = @intCast(i);
    }

    // Stage 3: induce the final order from sorted LMS suffixes.
    // Recover LMS positions in text order into s1.
    getBuckets(T, text, bucket, k, true);
    j = 0;
    i = 1;
    while (i < n) : (i += 1) {
        if (isLms(t, i)) {
            s1[j] = @intCast(i);
            j += 1;
        }
    }
    i = 0;
    while (i < n1) : (i += 1) sa1[i] = s1[@intCast(sa1[i])];
    @memset(sa[n1..], -1);
    i = n1;
    while (i > 0) {
        i -= 1;
        const pos = sa[i];
        sa[i] = -1;
        const c = text.at(@intCast(pos));
        bucket[c] -= 1;
        sa[@intCast(bucket[c])] = pos;
    }
    induceSal(T, text, sa, t, bucket, k);
    induceSas(T, text, sa, t, bucket, k);
}

fn naive(allocator: std.mem.Allocator, text: []const u8) ![]Index {
    const sa = try allocator.alloc(Index, text.len);
    for (sa, 0..) |*v, i| v.* = @intCast(i);
    const Ctx = struct {
        text: []const u8,
        fn lessThan(ctx: @This(), a: Index, b: Index) bool {
            return std.mem.order(u8, ctx.text[@intCast(a)..], ctx.text[@intCast(b)..]) == .lt;
        }
    };
    std.mem.sort(Index, sa, Ctx{ .text = text }, Ctx.lessThan);
    return sa;
}

test "sais matches naive suffix sort on random and degenerate inputs" {
    const allocator = std.testing.allocator;
    var prng = std.Random.DefaultPrng.init(99);
    const rnd = prng.random();
    const cases = [_][]const u8{ "", "a", "aa", "ab", "ba", "banana", "mississippi", "abracadabra", "aaaaaaaaaa", "abababababab" };
    for (cases) |c| {
        const sa = try allocator.alloc(Index, c.len);
        defer allocator.free(sa);
        try build(allocator, c, sa);
        const expect = try naive(allocator, c);
        defer allocator.free(expect);
        try std.testing.expectEqualSlices(Index, expect, sa);
    }
    var round: usize = 0;
    while (round < 40) : (round += 1) {
        const n = rnd.intRangeAtMost(usize, 1, 1500);
        const buf = try allocator.alloc(u8, n);
        defer allocator.free(buf);
        const alphabet: u8 = if (round % 3 == 0) 2 else if (round % 3 == 1) 8 else 255;
        for (buf) |*b| b.* = rnd.uintLessThan(u8, alphabet) + 1;
        const sa = try allocator.alloc(Index, n);
        defer allocator.free(sa);
        try build(allocator, buf, sa);
        const expect = try naive(allocator, buf);
        defer allocator.free(expect);
        try std.testing.expectEqualSlices(Index, expect, sa);
    }
}
