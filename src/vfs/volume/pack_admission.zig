//! Process-local admission for canonical mounted pack paths. This does not
//! police independent processes, hard-link/bind-mount aliases or raw DB users.
const std = @import("std");
const sync = @import("db_internal").platform.sync;
const State = struct { mounts: usize = 0, updating: bool = false };
var mutex: sync.Mutex = .{};
var paths: std.StringHashMapUnmanaged(State) = .empty;
const a = std.heap.smp_allocator;

/// Returned canonical path belongs to the caller until unmount.
pub fn mount(path: []const u8) ![]u8 {
    const resolved = try std.Io.Dir.cwd().realPathFileAlloc(std.Io.Threaded.global_single_threaded.io(), path, a);
    defer a.free(resolved);
    return register(try a.dupe(u8, resolved));
}

/// Provider-scoped opaque roots are not OS paths. Aliasing provider contexts
/// must explicitly share identity/root spelling; external mutation is forbidden
/// for the lifetime of a mount. Custom mounted updates are unsupported.
pub fn mountCustom(provider: u64, root: []const u8) ![]u8 {
    if (provider == 0 or root.len == 0) return error.InvalidArgument;
    return register(try std.fmt.allocPrint(a, "custom:{x}:{s}", .{ provider, root }));
}

fn register(canonical: []u8) ![]u8 {
    errdefer a.free(canonical);
    mutex.lock();
    defer mutex.unlock();
    if (paths.getPtr(canonical)) |state| {
        if (state.updating) return error.Busy;
        state.mounts += 1;
    } else {
        const key = try a.dupe(u8, canonical);
        errdefer a.free(key);
        try paths.put(a, key, .{ .mounts = 1 });
    }
    return canonical;
}

pub fn unmount(canonical: []u8) void {
    mutex.lock();
    defer mutex.unlock();
    const state = paths.getPtr(canonical).?;
    std.debug.assert(!state.updating and state.mounts != 0);
    state.mounts -= 1;
    if (state.mounts == 0) {
        const removed = paths.fetchRemove(canonical).?;
        a.free(removed.key);
        if (paths.count() == 0) {
            paths.deinit(a);
            paths = .empty;
        }
    }
    a.free(canonical);
}

/// All-or-nothing reservation. Exactly one mount may own each target path.
pub fn begin(canonical: []const []const u8) !void {
    mutex.lock();
    defer mutex.unlock();
    for (canonical, 0..) |path, i| {
        for (canonical[0..i]) |prior| if (std.mem.eql(u8, path, prior)) return error.Busy;
        const state = paths.get(path) orelse return error.InvalidArgument;
        if (state.mounts != 1 or state.updating) return error.Busy;
    }
    for (canonical) |path| paths.getPtr(path).?.updating = true;
}

pub fn end(canonical: []const []const u8) void {
    mutex.lock();
    defer mutex.unlock();
    for (canonical) |path| {
        const state = paths.getPtr(path).?;
        std.debug.assert(state.updating);
        state.updating = false;
    }
}
