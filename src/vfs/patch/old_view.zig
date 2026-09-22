//! Layered read view of the patch target (docs/vfs/diff_patch.md §8.3):
//! [target (in-place pack or overlay), base?]. Reads see committed state only;
//! staged batch contents are invisible, so this is always the "old" view.
const std = @import("std");
const db_internal = @import("db_internal");
const kv = db_internal.kv_db;
const object_key = @import("../object_key.zig");
const page_placeholder_fmt = @import("../format/page_placeholder.zig");
const page_value_fmt = @import("../format/page_value.zig");

pub const Found = enum { present, placeholder, missing };

pub const OldView = struct {
    /// Writable target layer (in-place pack or overlay).
    target: *kv.KvDb,
    /// Read-only base under an overlay; null in in-place mode.
    base: ?*kv.KvDb,

    pub fn isOverlay(self: *const OldView) bool {
        return self.base != null;
    }

    /// Reads an object through the layers into an owned buffer.
    /// A placeholder in the target layer terminates the search as NotFound.
    pub fn readObjectAlloc(self: *const OldView, allocator: std.mem.Allocator, key: u64) ![]u8 {
        const kb = object_key.encodeDbKey(key);
        if (self.target.getBorrowedBytes(&kb)) |bytes| {
            if (page_placeholder_fmt.isPlaceholder(bytes)) return error.NotFound;
            return allocator.dupe(u8, bytes);
        } else |err| switch (err) {
            error.NotFound => {},
            else => |e| return e,
        }
        const base = self.base orelse return error.NotFound;
        const bytes = try base.getBorrowedBytes(&kb);
        if (page_placeholder_fmt.isPlaceholder(bytes)) return error.NotFound;
        return allocator.dupe(u8, bytes);
    }

    /// Object bytes from the target layer only (null if absent or placeholder).
    pub fn readTargetObjectAlloc(self: *const OldView, allocator: std.mem.Allocator, key: u64) !?[]u8 {
        const kb = object_key.encodeDbKey(key);
        const bytes = self.target.getBorrowedBytes(&kb) catch |err| switch (err) {
            error.NotFound => return null,
            else => |e| return e,
        };
        if (page_placeholder_fmt.isPlaceholder(bytes)) return null;
        return try allocator.dupe(u8, bytes);
    }

    /// What the *target layer only* holds for a key (idempotency checks).
    pub fn targetState(self: *const OldView, key: u64) !Found {
        const kb = object_key.encodeDbKey(key);
        const bytes = self.target.getBorrowedBytes(&kb) catch |err| switch (err) {
            error.NotFound => return .missing,
            else => |e| return e,
        };
        return if (page_placeholder_fmt.isPlaceholder(bytes)) .placeholder else .present;
    }

    /// Whether a page is visible through the layers.
    pub fn pageVisible(self: *const OldView, key: u64) !bool {
        switch (try self.targetState(key)) {
            .present => return true,
            .placeholder => return false,
            .missing => {},
        }
        const base = self.base orelse return false;
        const kb = object_key.encodeDbKey(key);
        const bytes = base.getBorrowedBytes(&kb) catch |err| switch (err) {
            error.NotFound => return false,
            else => |e| return e,
        };
        return !page_placeholder_fmt.isPlaceholder(bytes);
    }

    pub fn readPage(self: *const OldView, allocator: std.mem.Allocator, identity: page_value_fmt.PageIdentity) ![]u8 {
        return self.readObjectAlloc(allocator, try object_key.pageKey(identity.file_entry, identity.block_index, identity.page_index));
    }
};
