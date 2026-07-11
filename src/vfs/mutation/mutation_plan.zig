const std = @import("std");
const hash = @import("../hash.zig");
const patch_manifest = @import("../format/patch_manifest.zig");
const object_key = @import("../object_key.zig");

pub const MutationOp = enum { add_file, modify_file, delete_file };

pub const FileMutation = struct {
    op: MutationOp,
    file_entry: u64,
    virtual_path: ?[]u8 = null,
    old_file_size: u64 = 0,
    new_file_size: u64 = 0,
    old_content_hash: [32]u8 = [_]u8{0} ** 32,
    new_content_hash: [32]u8 = [_]u8{0} ** 32,
    payload: []u8 = &.{},
    file_manifest_key: u64,

    pub fn deinit(self: *FileMutation, allocator: std.mem.Allocator) void {
        if (self.virtual_path) |p| allocator.free(p);
        allocator.free(self.payload);
    }
};

pub const PackMutationPlan = struct {
    target_pack_path: []u8,
    target_pack_id: u64,
    base_pack_version: u64,
    patch_version: u64,
    files: []FileMutation,
    verify_after_apply: bool = true,

    pub fn deinit(self: *PackMutationPlan, allocator: std.mem.Allocator) void {
        allocator.free(self.target_pack_path);
        for (self.files) |*file| file.deinit(allocator);
        allocator.free(self.files);
        self.* = undefined;
    }
};

pub fn mutationFromPatch(allocator: std.mem.Allocator, file: patch_manifest.FilePatch) !FileMutation {
    return .{
        .op = switch (file.op) {
            .add_file => .add_file,
            .modify_file => .modify_file,
            .delete_file => .delete_file,
            else => return error.UnsupportedVersion,
        },
        .file_entry = file.file_entry,
        .virtual_path = if (file.virtual_path) |p| try allocator.dupe(u8, p) else null,
        .old_file_size = file.old_file_size,
        .new_file_size = file.new_file_size,
        .old_content_hash = file.old_content_hash,
        .new_content_hash = file.new_content_hash,
        .payload = try allocator.dupe(u8, file.payload),
        .file_manifest_key = try object_key.fileManifestKey(file.file_entry),
    };
}

pub fn payloadHashOk(m: FileMutation) bool {
    if (m.op == .delete_file) return true;
    return std.mem.eql(u8, &hash.contentHash(m.payload), &m.new_content_hash);
}
