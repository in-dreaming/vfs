//! Cover discovery: suffix-array driven longest-match search over `old` for
//! each position in `new`, then dispose (filter short/isolated covers, extend
//! into neighbouring similar bytes, link adjacent covers).
const std = @import("std");
const sais = @import("sais.zig");

pub const Cover = struct {
    old_pos: u64,
    new_pos: u64,
    len: u64,
};

pub const Options = struct {
    /// Shortest match that may become a cover.
    min_match_len: u32 = 8,
    /// Isolated covers with a lower score are dropped (score ~ len - cost).
    min_single_match_score: u32 = 6,
    /// Prefer a candidate this close to the expected continuation of the
    /// previous cover even if a slightly longer match exists elsewhere.
    near_window: u64 = 1 << 16,
    /// Extend a cover boundary while at least this fraction of the extended
    /// bytes are equal (numerator/8).
    extend_min_equal_8ths: u8 = 5,
    /// Max gap (in both old and new) to link two covers into one.
    link_max_gap: u64 = 64,

    pub fn hash(self: Options) u64 {
        var h = std.hash.Wyhash.init(0x6864696666);
        h.update(std.mem.asBytes(&self.min_match_len));
        h.update(std.mem.asBytes(&self.min_single_match_score));
        h.update(std.mem.asBytes(&self.near_window));
        h.update(std.mem.asBytes(&self.extend_min_equal_8ths));
        h.update(std.mem.asBytes(&self.link_max_gap));
        return h.final();
    }
};

const Match = struct { old_pos: usize, len: usize };

/// Suffix-array index over `old` with binary-search longest-match queries.
pub const Index = struct {
    allocator: std.mem.Allocator,
    old: []const u8,
    sa: []sais.Index,

    pub fn build(allocator: std.mem.Allocator, old: []const u8) !Index {
        const sa = try allocator.alloc(sais.Index, old.len);
        errdefer allocator.free(sa);
        try sais.build(allocator, old, sa);
        return .{ .allocator = allocator, .old = old, .sa = sa };
    }

    pub fn deinit(self: *Index) void {
        self.allocator.free(self.sa);
        self.* = undefined;
    }

    fn lcp(a: []const u8, b: []const u8) usize {
        const n = @min(a.len, b.len);
        var i: usize = 0;
        while (i + 8 <= n) : (i += 8) {
            if (std.mem.readInt(u64, a[i..][0..8], .little) != std.mem.readInt(u64, b[i..][0..8], .little)) break;
        }
        while (i < n and a[i] == b[i]) i += 1;
        return i;
    }

    /// Longest match of `pattern` (a suffix of new) inside old. Returns null
    /// when shorter than `min_len`. When `prefer_near` is set, a match at that
    /// exact old position with length >= min_len wins if it is within a small
    /// factor of the best length (keeps old-side locality, cheap cover links).
    pub fn longest(self: *const Index, pattern: []const u8, min_len: usize, prefer_near: ?usize, near_window: u64) ?Match {
        if (self.sa.len == 0 or pattern.len < min_len) return null;
        // Binary search for the insertion point of pattern.
        var lo: usize = 0;
        var hi: usize = self.sa.len;
        while (lo < hi) {
            const mid = (lo + hi) / 2;
            const suf = self.old[@intCast(self.sa[mid])..];
            if (std.mem.order(u8, suf, pattern) == .lt) lo = mid + 1 else hi = mid;
        }
        var best: Match = .{ .old_pos = 0, .len = 0 };
        // Check neighbours around the insertion point; LCP decreases as we
        // move away, so a handful of probes suffices.
        var probes: usize = 0;
        var up = lo;
        var down = lo;
        while (probes < 8) : (probes += 1) {
            var progressed = false;
            if (up < self.sa.len) {
                const p: usize = @intCast(self.sa[up]);
                const l = lcp(self.old[p..], pattern);
                if (l > best.len or (l == best.len and l != 0 and prefer_near != null and p == prefer_near.?)) best = .{ .old_pos = p, .len = l };
                if (l < best.len / 2 and l < min_len) up = self.sa.len else up += 1;
                progressed = true;
            }
            if (down > 0) {
                down -= 1;
                const p: usize = @intCast(self.sa[down]);
                const l = lcp(self.old[p..], pattern);
                if (l > best.len or (l == best.len and l != 0 and prefer_near != null and p == prefer_near.?)) best = .{ .old_pos = p, .len = l };
                if (l < best.len / 2 and l < min_len) down = 0;
                progressed = true;
            }
            if (!progressed) break;
        }
        // Old-side locality: if the expected continuation also matches with
        // a length close to the best, take it.
        if (prefer_near) |np| {
            if (np < self.old.len and best.old_pos != np) {
                const l = lcp(self.old[np..], pattern);
                if (l >= min_len and l + (l / 4) + 1 >= best.len and (np + near_window >= best.old_pos or best.old_pos + near_window >= np)) {
                    best = .{ .old_pos = np, .len = l };
                }
            }
        }
        if (best.len < min_len) return null;
        return best;
    }
};

/// Greedy cover search over `new`.
pub fn search(allocator: std.mem.Allocator, index: *const Index, new: []const u8, options: Options) !std.ArrayList(Cover) {
    var covers = std.ArrayList(Cover).empty;
    errdefer covers.deinit(allocator);
    const min_len: usize = options.min_match_len;
    var pos: usize = 0;
    var expect_old: ?usize = null;
    while (pos + min_len <= new.len) {
        const m = index.longest(new[pos..], min_len, expect_old, options.near_window);
        if (m) |match| {
            try covers.append(allocator, .{ .old_pos = match.old_pos, .new_pos = pos, .len = match.len });
            pos += match.len;
            expect_old = match.old_pos + match.len;
        } else {
            pos += 1;
            if (expect_old) |e| expect_old = e + 1;
        }
    }
    return covers;
}

fn equalRatioOk(old: []const u8, new: []const u8, options: Options) bool {
    var eq: usize = 0;
    for (old, new) |a, b| {
        if (a == b) eq += 1;
    }
    return eq * 8 >= @as(usize, options.extend_min_equal_8ths) * new.len;
}

/// Extend covers into adjacent regions that are "mostly equal" (they cost
/// little in the RLE sub stream), then link covers whose old/new gaps are
/// both small, then drop isolated low-score covers.
pub fn dispose(allocator: std.mem.Allocator, covers: *std.ArrayList(Cover), old: []const u8, new: []const u8, options: Options) !void {
    if (covers.items.len == 0) return;
    // 1. extend forward/backward in 8-byte steps while the window stays similar.
    var i: usize = 0;
    while (i < covers.items.len) : (i += 1) {
        var c = &covers.items[i];
        const prev_end_new: u64 = if (i == 0) 0 else covers.items[i - 1].new_pos + covers.items[i - 1].len;
        const next_start_new: u64 = if (i + 1 < covers.items.len) covers.items[i + 1].new_pos else new.len;
        // backward
        while (c.new_pos > prev_end_new and c.old_pos > 0) {
            const step: u64 = @min(8, @min(c.new_pos - prev_end_new, c.old_pos));
            const o = old[@intCast(c.old_pos - step)..@intCast(c.old_pos)];
            const n = new[@intCast(c.new_pos - step)..@intCast(c.new_pos)];
            if (!equalRatioOk(o, n, options)) break;
            c.old_pos -= step;
            c.new_pos -= step;
            c.len += step;
        }
        // forward
        while (c.new_pos + c.len < next_start_new and c.old_pos + c.len < old.len) {
            const room_new = next_start_new - (c.new_pos + c.len);
            const room_old = old.len - (c.old_pos + c.len);
            const step: u64 = @min(8, @min(room_new, room_old));
            const o = old[@intCast(c.old_pos + c.len)..@intCast(c.old_pos + c.len + step)];
            const n = new[@intCast(c.new_pos + c.len)..@intCast(c.new_pos + c.len + step)];
            if (!equalRatioOk(o, n, options)) break;
            c.len += step;
        }
    }
    // 2. link: merge consecutive covers with identical (old-new) offset and small gaps.
    var out = std.ArrayList(Cover).empty;
    errdefer out.deinit(allocator);
    try out.append(allocator, covers.items[0]);
    i = 1;
    while (i < covers.items.len) : (i += 1) {
        const c = covers.items[i];
        var last = &out.items[out.items.len - 1];
        const last_end_new = last.new_pos + last.len;
        const last_end_old = last.old_pos + last.len;
        const same_shift = (c.new_pos >= c.old_pos) == (last.new_pos >= last.old_pos) and
            (if (c.new_pos >= c.old_pos) c.new_pos - c.old_pos else c.old_pos - c.new_pos) ==
                (if (last.new_pos >= last.old_pos) last.new_pos - last.old_pos else last.old_pos - last.new_pos);
        if (same_shift and c.new_pos >= last_end_new and c.new_pos - last_end_new <= options.link_max_gap and c.old_pos >= last_end_old) {
            last.len = (c.new_pos + c.len) - last.new_pos;
        } else {
            try out.append(allocator, c);
        }
    }
    // 3. filter isolated low-score covers: cost ~ 3 varints (~6 bytes).
    var filtered = std.ArrayList(Cover).empty;
    errdefer filtered.deinit(allocator);
    for (out.items) |c| {
        if (c.len >= options.min_single_match_score + 6) {
            try filtered.append(allocator, c);
        }
    }
    out.deinit(allocator);
    covers.deinit(allocator);
    covers.* = filtered;
}

test "cover search finds moved block and dispose links adjacent covers" {
    const allocator = std.testing.allocator;
    const base = "0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ" ** 4;
    var new_buf: [base.len + 20]u8 = undefined;
    @memcpy(new_buf[0..100], base[0..100]);
    @memcpy(new_buf[100..120], "--inserted-20-bytes-");
    @memcpy(new_buf[120..], base[100..]);
    var idx = try Index.build(allocator, base);
    defer idx.deinit();
    var covers = try search(allocator, &idx, &new_buf, .{});
    defer covers.deinit(allocator);
    try std.testing.expect(covers.items.len >= 2);
    for (covers.items) |c| {
        try std.testing.expectEqualSlices(u8, base[@intCast(c.old_pos)..@intCast(c.old_pos + c.len)], new_buf[@intCast(c.new_pos)..@intCast(c.new_pos + c.len)]);
    }
    try dispose(allocator, &covers, base, &new_buf, .{});
    var covered: u64 = 0;
    var last_end: u64 = 0;
    for (covers.items) |c| {
        try std.testing.expect(c.new_pos >= last_end);
        try std.testing.expect(c.old_pos + c.len <= base.len);
        try std.testing.expect(c.new_pos + c.len <= new_buf.len);
        last_end = c.new_pos + c.len;
        covered += c.len;
    }
    try std.testing.expect(covered >= base.len - 8);
}
