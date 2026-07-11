const std = @import("std");
const fmt = @import("format/common.zig");

const FNV_OFFSET: u64 = 0xcbf29ce484222325;
const FNV_PRIME: u64 = 0x100000001b3;

pub const Hasher64 = struct {
    value: u64 = FNV_OFFSET,

    pub fn update(self: *Hasher64, bytes: []const u8) void {
        for (bytes) |b| {
            self.value ^= b;
            self.value *%= FNV_PRIME;
        }
    }

    pub fn updateU32Le(self: *Hasher64, value: u32) void {
        var b = [_]u8{0} ** 4;
        fmt.putU32(&b, 0, value);
        self.update(&b);
    }

    pub fn updateU64Le(self: *Hasher64, value: u64) void {
        var b = [_]u8{0} ** 8;
        fmt.putU64(&b, 0, value);
        self.update(&b);
    }

    pub fn final(self: Hasher64) u64 {
        return self.value;
    }
};

pub fn hash64(domain: []const u8, payload: []const u8) u64 {
    var h: Hasher64 = .{};
    h.update(domain);
    h.update(&.{0});
    h.update(payload);
    return h.final();
}

pub fn hashPath(normalized_path: []const u8) u64 {
    return hash64("vfs.path.v1", normalized_path);
}

pub fn hashIdentity1(domain: []const u8, a: u64) u64 {
    var h: Hasher64 = .{};
    h.update(domain);
    h.update(&.{0});
    h.updateU64Le(a);
    return h.final();
}

pub fn hashIdentity3(domain: []const u8, a: u64, b: u32, c: u32) u64 {
    var h: Hasher64 = .{};
    h.update(domain);
    h.update(&.{0});
    h.updateU64Le(a);
    h.updateU32Le(b);
    h.updateU32Le(c);
    return h.final();
}

pub fn crc32c(bytes: []const u8) u32 {
    return fmt.crc32c(bytes);
}

pub fn contentHash(bytes: []const u8) [32]u8 {
    var out: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &out, .{});
    return out;
}

test "domain separated hash is stable and domain-sensitive" {
    try std.testing.expectEqual(hash64("vfs.path.v1", "assets/a.txt"), hash64("vfs.path.v1", "assets/a.txt"));
    try std.testing.expect(hash64("vfs.path.v1", "assets/a.txt") != hash64("vfs.page.v1", "assets/a.txt"));
    try std.testing.expectEqual(@as(u32, 0xe3069283), crc32c("123456789"));
    const digest = contentHash("abc");
    try std.testing.expectEqualSlices(u8, &.{
        0xba, 0x78, 0x16, 0xbf, 0x8f, 0x01, 0xcf, 0xea,
        0x41, 0x41, 0x40, 0xde, 0x5d, 0xae, 0x22, 0x23,
        0xb0, 0x03, 0x61, 0xa3, 0x96, 0x17, 0x7a, 0x9c,
        0xb4, 0x10, 0xff, 0x61, 0xf2, 0x00, 0x15, 0xad,
    }, &digest);
}
