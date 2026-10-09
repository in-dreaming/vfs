const std = @import("std");
const pf = @import("db_internal").platform.file;

pub const Snapshot = struct {
    size: u64,
    content_hash: [32]u8,
};

const buffer_size = 64 * 1024;

/// Hash source bytes without retaining them. A caller that reads the source
/// again must compare that pass's size and hash before publishing its output.
pub fn snapshot(path: []const u8) !Snapshot {
    var file = try pf.open(path, .{ .mode = .read_only, .sequential_hint = true });
    defer pf.close(&file);
    return snapshotReader(FileReader{ .file = file });
}

/// Round up without overflowing at u64's upper limit or narrowing unchecked.
pub fn pageCount(size: u64, page_size: u32) !u32 {
    if (page_size == 0) return error.InvalidArgument;
    if (size == 0) return 0;
    return std.math.cast(u32, ((size - 1) / page_size) + 1) orelse error.InvalidArgument;
}

const FileReader = struct {
    file: pf.FileHandle,

    fn len(self: FileReader) !u64 {
        return pf.len(self.file);
    }

    fn preadAll(self: FileReader, offset: u64, bytes: []u8) !usize {
        return pf.preadAll(self.file, offset, bytes);
    }
};

fn snapshotReader(reader: anytype) !Snapshot {
    const size = try reader.len();
    var buffer: [buffer_size]u8 = undefined;
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    var offset: u64 = 0;
    while (offset < size) {
        const count: usize = @intCast(@min(size - offset, buffer.len));
        const bytes = buffer[0..count];
        if (try reader.preadAll(offset, bytes) != count) return error.SourceChanged;
        hasher.update(bytes);
        // count <= size - offset, so this sum cannot overflow.
        offset += count;
    }
    // A successful short last chunk must not silently hide a growing source.
    if (try reader.preadAll(size, buffer[0..1]) != 0) return error.SourceChanged;
    if (try reader.len() != size) return error.SourceChanged;
    var digest: [32]u8 = undefined;
    hasher.final(&digest);
    return .{ .size = size, .content_hash = digest };
}

const TestReader = struct {
    initial_size: u64,
    readable_size: u64,
    final_size: u64,
    length_calls: usize = 0,
    read_calls: usize = 0,
    max_read_size: usize = 0,

    fn len(self: *TestReader) !u64 {
        self.length_calls += 1;
        return if (self.length_calls == 1) self.initial_size else self.final_size;
    }

    fn preadAll(self: *TestReader, offset: u64, bytes: []u8) !usize {
        self.read_calls += 1;
        self.max_read_size = @max(self.max_read_size, bytes.len);
        if (offset >= self.readable_size) return 0;
        const count: usize = @intCast(@min(self.readable_size - offset, bytes.len));
        @memset(bytes[0..count], 0xa5);
        return count;
    }
};

test "build plan source hashing bounds reads and preserves SHA256" {
    const size = 3 * buffer_size + 17;
    var reader = TestReader{ .initial_size = size, .readable_size = size, .final_size = size };
    const result = try snapshotReader(&reader);
    try std.testing.expectEqual(@as(u64, size), result.size);
    try std.testing.expectEqual(@as(usize, buffer_size), reader.max_read_size);
    try std.testing.expectEqual(@as(usize, 5), reader.read_calls);
    const expected_bytes = [_]u8{0xa5} ** size;
    var expected_hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(&expected_bytes, &expected_hash, .{});
    try std.testing.expectEqualSlices(u8, &expected_hash, &result.content_hash);
}

test "build plan source hashing rejects truncation and size changes" {
    var truncated = TestReader{ .initial_size = 100, .readable_size = 99, .final_size = 99 };
    try std.testing.expectError(error.SourceChanged, snapshotReader(&truncated));

    var grown = TestReader{ .initial_size = 100, .readable_size = 101, .final_size = 101 };
    try std.testing.expectError(error.SourceChanged, snapshotReader(&grown));

    // Growth or truncation after the bytes were read is caught by final length.
    var late_growth = TestReader{ .initial_size = 100, .readable_size = 100, .final_size = 101 };
    try std.testing.expectError(error.SourceChanged, snapshotReader(&late_growth));
    var late_truncation = TestReader{ .initial_size = 100, .readable_size = 100, .final_size = 99 };
    try std.testing.expectError(error.SourceChanged, snapshotReader(&late_truncation));

    var empty_growth = TestReader{ .initial_size = 0, .readable_size = 1, .final_size = 1 };
    try std.testing.expectError(error.SourceChanged, snapshotReader(&empty_growth));
}

test "build plan source hashing preserves empty SHA256" {
    var reader = TestReader{ .initial_size = 0, .readable_size = 0, .final_size = 0 };
    const result = try snapshotReader(&reader);
    var expected_hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash("", &expected_hash, .{});
    try std.testing.expectEqual(@as(u64, 0), result.size);
    try std.testing.expectEqualSlices(u8, &expected_hash, &result.content_hash);
}

test "build plan page counts reject overflow without wrapping" {
    try std.testing.expectEqual(@as(u32, 0), try pageCount(0, 1));
    try std.testing.expectEqual(@as(u32, 1), try pageCount(1, 1));
    try std.testing.expectEqual(@as(u32, 1), try pageCount(65536, 65536));
    try std.testing.expectEqual(@as(u32, 2), try pageCount(65537, 65536));
    const max_pages = std.math.maxInt(u32);
    const max_size = @as(u64, max_pages) * max_pages;
    try std.testing.expectEqual(max_pages, try pageCount(max_size, max_pages));
    try std.testing.expectError(error.InvalidArgument, pageCount(max_size + 1, max_pages));
    try std.testing.expectError(error.InvalidArgument, pageCount(std.math.maxInt(u64), 1));
    try std.testing.expectError(error.InvalidArgument, pageCount(0, 0));
}
