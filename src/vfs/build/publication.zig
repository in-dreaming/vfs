//! Offline directory publication. The output must be absent or a valid pack.
//! A sibling transaction directory is acquired exclusively, so concurrent
//! builders fail closed. Recovery is explicit and requires a stopped builder.
//! Live multi-pack updates must instead use volume/staging.zig and immutable
//! generation paths: two portable directory renames are not atomic to readers.
const std = @import("std");
const reader_mod = @import("../pack/pack_reader.zig");
const pf = @import("db_internal").platform.file;
const magic = "VFS offline pack publication v1\n";

pub const Publication = struct {
    allocator: std.mem.Allocator,
    output: []u8,
    transaction: []u8,
    stage: []u8,
    backup: []u8,
    marker: []u8,
    owned: bool = false,
    moved_old: bool = false,
    published: bool = false,

    pub fn init(allocator: std.mem.Allocator, output: []const u8) !Publication {
        // Reject directory aliases before normalization; never rename a parent.
        const name = std.fs.path.basename(output);
        if (output.len == 0 or name.len == 0 or std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) return error.InvalidArgument;
        const cwd_path = try std.Io.Dir.cwd().realPathFileAlloc(std.Io.Threaded.global_single_threaded.io(), ".", allocator);
        defer allocator.free(cwd_path);
        const normalized = try std.fs.path.resolve(allocator, &.{ cwd_path, output });
        errdefer allocator.free(normalized);
        if (std.fs.path.dirname(normalized) == null or std.mem.eql(u8, normalized, "/")) return error.InvalidArgument;
        const tx = try std.fmt.allocPrint(allocator, "{s}.vfs-build", .{normalized});
        errdefer allocator.free(tx);
        const stage = try std.fs.path.join(allocator, &.{ tx, "stage" });
        errdefer allocator.free(stage);
        const backup = try std.fs.path.join(allocator, &.{ tx, "previous" });
        errdefer allocator.free(backup);
        const marker = try std.fs.path.join(allocator, &.{ tx, "owner" });
        return .{ .allocator = allocator, .output = normalized, .transaction = tx, .stage = stage, .backup = backup, .marker = marker };
    }

    pub fn deinit(self: *Publication) void {
        for ([_][]u8{ self.output, self.transaction, self.stage, self.backup, self.marker }) |path| self.allocator.free(path);
    }

    pub fn begin(self: *Publication) !void {
        const io = std.Io.Threaded.global_single_threaded.io();
        const cwd = std.Io.Dir.cwd();
        try checkOutput(self.allocator, self.output);
        try cwd.createDirPath(io, std.fs.path.dirname(self.output).?);
        cwd.createDir(io, self.transaction, .default_dir) catch |err| switch (err) {
            error.PathAlreadyExists => return error.BuildRecoveryRequired,
            else => return err,
        };
        self.owned = true;
        errdefer self.cancel() catch {};
        var marker = try pf.open(self.marker, .{ .mode = .create_read_write });
        defer pf.close(&marker);
        try pf.pwriteAll(marker, 0, magic);
        try pf.flushMetadata(marker);
    }

    pub fn publish(self: *Publication) !void {
        const io = std.Io.Threaded.global_single_threaded.io();
        const cwd = std.Io.Dir.cwd();
        // Recheck immediately before moving the destination. Callers must not
        // mutate packs concurrently with offline construction.
        try checkOutput(self.allocator, self.output);
        if (try exists(self.output)) {
            try cwd.renamePreserve(self.output, cwd, self.backup, io);
            self.moved_old = true;
        }
        cwd.renamePreserve(self.stage, cwd, self.output, io) catch |err| {
            if (self.moved_old) {
                cwd.renamePreserve(self.backup, cwd, self.output, io) catch return error.BuildRecoveryRequired;
                self.moved_old = false;
            }
            return err;
        };
        self.published = true;
        // A cleanup error cannot undo an already published pack. Retain the
        // transaction for explicit recovery rather than reporting build failure.
        self.cleanup() catch return;
        self.owned = false;
    }

    fn cleanup(self: *Publication) !void {
        const io = std.Io.Threaded.global_single_threaded.io();
        const cwd = std.Io.Dir.cwd();
        // Keep ownership evidence until disposable children are gone. A
        // partially deleted backup must never block recovery of a valid output.
        try cwd.deleteTree(io, self.stage);
        try cwd.deleteTree(io, self.backup);
        try cwd.deleteFile(io, self.marker);
        try cwd.deleteDir(io, self.transaction);
    }

    pub fn cancel(self: *Publication) !void {
        if (!self.owned or self.published) return;
        const io = std.Io.Threaded.global_single_threaded.io();
        const cwd = std.Io.Dir.cwd();
        if (self.moved_old) {
            try cwd.renamePreserve(self.backup, cwd, self.output, io);
            self.moved_old = false;
        }
        try self.cleanup();
        self.owned = false;
    }
};

/// Call only after the interrupted builder has stopped. Never guess ownership
/// from a suffix alone. Preserve ambiguous states for manual inspection.
pub fn recover(output: []const u8, allocator: std.mem.Allocator) !void {
    var p = try Publication.init(allocator, output);
    defer p.deinit();
    if (!try exists(p.transaction)) return;
    const io = std.Io.Threaded.global_single_threaded.io();
    const cwd = std.Io.Dir.cwd();
    const stat = try cwd.statFile(io, p.transaction, .{ .follow_symlinks = false });
    if (stat.kind != .directory) return error.BuildRecoveryRequired;
    {
        var marker = pf.open(p.marker, .{ .mode = .read_only }) catch |err| switch (err) {
            error.FileNotFound => {
                // The final cleanup rmdir may have been interrupted after
                // removing the marker. Only remove an EMPTY directory here.
                cwd.deleteDir(io, p.transaction) catch return error.BuildRecoveryRequired;
                return;
            },
            else => return err,
        };
        defer pf.close(&marker);
        var bytes: [magic.len]u8 = undefined;
        if (try pf.len(marker) != magic.len or try pf.preadAll(marker, 0, &bytes) != magic.len or !std.mem.eql(u8, &bytes, magic)) return error.BuildRecoveryRequired;
    }
    if (try exists(p.backup)) {
        if (try exists(p.output)) {
            // The stage name disappears only when publication completed.
            if (try exists(p.stage)) return error.BuildRecoveryRequired;
            try checkOutput(allocator, p.output);
        } else {
            try checkOutput(allocator, p.backup);
            try cwd.renamePreserve(p.backup, cwd, p.output, io);
        }
    } else {
        try checkOutput(allocator, p.output);
    }
    try p.cleanup();
}

fn exists(path: []const u8) !bool {
    const io = std.Io.Threaded.global_single_threaded.io();
    _ = std.Io.Dir.cwd().statFile(io, path, .{ .follow_symlinks = false }) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return err,
    };
    return true;
}

fn checkOutput(allocator: std.mem.Allocator, path: []const u8) !void {
    if (!try exists(path)) return;
    const io = std.Io.Threaded.global_single_threaded.io();
    const stat = try std.Io.Dir.cwd().statFile(io, path, .{ .follow_symlinks = false });
    if (stat.kind != .directory) return error.InvalidOutputPath;
    var reader = reader_mod.PackReader.open(allocator, path) catch return error.InvalidOutputPath;
    reader.close(allocator);
}

test "publication rollback and interrupted rename recovery preserve the old pack" {
    const builder = @import("pack_builder.zig");
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    const cwd = std.Io.Dir.cwd();
    const out = "zig-cache-vfs-publication-recover";
    defer cwd.deleteTree(io, out) catch {};
    try builder.createPack(out, &.{}, .{ .pack_version = 19 });
    var p = try Publication.init(allocator, out);
    defer p.deinit();
    defer cwd.deleteTree(io, p.transaction) catch {};
    try p.begin();
    // Inject a filesystem failure at the second rename: stage is missing.
    try std.testing.expectError(error.FileNotFound, p.publish());
    var reader = try reader_mod.PackReader.open(allocator, out);
    try std.testing.expectEqual(@as(u64, 19), reader.manifest.pack_version);
    reader.close(allocator);
    try p.cancel();

    try p.begin();
    // Simulate process interruption after old -> previous, before stage -> output.
    try cwd.renamePreserve(p.output, cwd, p.backup, io);
    try recover(out, allocator);
    reader = try reader_mod.PackReader.open(allocator, out);
    try std.testing.expectEqual(@as(u64, 19), reader.manifest.pack_version);
    reader.close(allocator);
    try std.testing.expect(!try exists(p.transaction));
}

test "publication refuses unrelated output and unowned staging directories" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    const cwd = std.Io.Dir.cwd();
    const out = "zig-cache-vfs-publication-preconditions";
    var p = try Publication.init(allocator, out);
    defer p.deinit();
    defer cwd.deleteTree(io, out) catch {};
    defer cwd.deleteTree(io, p.transaction) catch {};
    try cwd.createDir(io, out, .default_dir);
    try std.testing.expectError(error.InvalidOutputPath, p.begin());
    try cwd.deleteDir(io, out);
    try cwd.createDir(io, p.transaction, .default_dir);
    try std.testing.expectError(error.BuildRecoveryRequired, p.begin());
    const unrelated = try std.fs.path.join(allocator, &.{ p.transaction, "unrelated" });
    defer allocator.free(unrelated);
    var file = try pf.open(unrelated, .{ .mode = .create_read_write });
    pf.close(&file);
    try std.testing.expectError(error.BuildRecoveryRequired, recover(out, allocator));
    try std.testing.expect(try exists(p.transaction));
    try cwd.deleteFile(io, unrelated);
    try recover(out, allocator);
    try std.testing.expect(!try exists(p.transaction));
    try std.testing.expectError(error.InvalidArgument, Publication.init(allocator, "."));
    try std.testing.expectError(error.InvalidArgument, Publication.init(allocator, "/"));
}

test "publication recovery keeps completed generation and removes backup" {
    const builder = @import("pack_builder.zig");
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    const cwd = std.Io.Dir.cwd();
    const out = "zig-cache-vfs-publication-completed";
    defer cwd.deleteTree(io, out) catch {};
    try builder.createPack(out, &.{}, .{ .pack_version = 1 });
    var p = try Publication.init(allocator, out);
    defer p.deinit();
    defer cwd.deleteTree(io, p.transaction) catch {};
    try p.begin();
    try builder.createPack(p.stage, &.{}, .{ .pack_version = 2 });
    try cwd.renamePreserve(p.output, cwd, p.backup, io);
    try cwd.renamePreserve(p.stage, cwd, p.output, io);
    // Process stops during backup cleanup. Recovery must retain the new pack
    // even when the disposable backup is no longer a readable pack.
    const old_manifest = try std.fs.path.join(allocator, &.{ p.backup, "manifest.db" });
    defer allocator.free(old_manifest);
    try cwd.deleteFile(io, old_manifest);
    try recover(out, allocator);
    var reader = try reader_mod.PackReader.open(allocator, out);
    defer reader.close(allocator);
    try std.testing.expectEqual(@as(u64, 2), reader.manifest.pack_version);
    try std.testing.expect(!try exists(p.transaction));
}

test "first build interruption removes only its private stage" {
    const builder = @import("pack_builder.zig");
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    const cwd = std.Io.Dir.cwd();
    const out = "zig-cache-vfs-publication-first-build";
    var p = try Publication.init(allocator, out);
    defer p.deinit();
    defer cwd.deleteTree(io, out) catch {};
    defer cwd.deleteTree(io, p.transaction) catch {};
    try p.begin();
    try builder.createPack(p.stage, &.{}, .{});
    try recover(out, allocator);
    try std.testing.expect(!try exists(out));
    try std.testing.expect(!try exists(p.transaction));
}
