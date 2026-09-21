//! Blocking synchronization primitives for the DB and VFS runtime.
//!
//! The codebase previously used `std.atomic.Mutex` with a `tryLock` spin loop
//! everywhere. Pure spinning is fine for a few-instruction critical section but
//! burns CPU and inflates tail latency badly when the holder does a syscall
//! (store park/ensureReady, cache eviction, DB commit). These wrappers use
//! `std.Io.Mutex` / `std.Io.RwLock`, which spin briefly and then park the
//! thread on the OS futex (WaitOnAddress on Windows). The default `Io` is the
//! same global single-threaded adapter used for file IO; futex wait/wake do not
//! depend on its scheduler.
const std = @import("std");

fn io() std.Io {
    return std.Io.Threaded.global_single_threaded.io();
}

pub const Mutex = struct {
    inner: std.Io.Mutex = .init,

    pub fn lock(self: *Mutex) void {
        self.inner.lockUncancelable(io());
    }

    pub fn tryLock(self: *Mutex) bool {
        return self.inner.tryLock();
    }

    pub fn unlock(self: *Mutex) void {
        self.inner.unlock(io());
    }
};

pub const Condition = struct {
    inner: std.Io.Condition = .init,

    /// Atomically releases `mutex`, blocks until signaled, then re-acquires it.
    pub fn wait(self: *Condition, mutex: *Mutex) void {
        self.inner.waitUncancelable(io(), &mutex.inner);
    }

    pub fn signal(self: *Condition) void {
        self.inner.signal(io());
    }

    pub fn broadcast(self: *Condition) void {
        self.inner.broadcast(io());
    }
};

pub const RwLock = struct {
    inner: std.Io.RwLock = .init,

    pub fn lock(self: *RwLock) void {
        self.inner.lockUncancelable(io());
    }

    pub fn unlock(self: *RwLock) void {
        self.inner.unlock(io());
    }

    pub fn lockShared(self: *RwLock) void {
        self.inner.lockSharedUncancelable(io());
    }

    pub fn unlockShared(self: *RwLock) void {
        self.inner.unlockShared(io());
    }
};

/// Process-wide monotonically increasing small integer per thread. Used to
/// spread threads over striped resources (read handle pools) without hashing
/// thread ids.
pub fn threadSlot() u32 {
    if (thread_slot == std.math.maxInt(u32)) {
        thread_slot = next_thread_slot.fetchAdd(1, .monotonic);
    }
    return thread_slot;
}

threadlocal var thread_slot: u32 = std.math.maxInt(u32);
var next_thread_slot: std.atomic.Value(u32) = .init(0);

test "mutex and rwlock basic exclusion across threads" {
    const Ctx = struct {
        m: Mutex = .{},
        rw: RwLock = .{},
        counter: u64 = 0,
        rw_counter: u64 = 0,

        fn worker(ctx: *@This()) void {
            var i: usize = 0;
            while (i < 10_000) : (i += 1) {
                ctx.m.lock();
                ctx.counter += 1;
                ctx.m.unlock();
                if (i % 4 == 0) {
                    ctx.rw.lock();
                    ctx.rw_counter += 1;
                    ctx.rw.unlock();
                } else {
                    ctx.rw.lockShared();
                    _ = ctx.rw_counter;
                    ctx.rw.unlockShared();
                }
            }
        }
    };
    var ctx = Ctx{};
    var threads: [4]std.Thread = undefined;
    for (&threads) |*t| t.* = try std.Thread.spawn(.{}, Ctx.worker, .{&ctx});
    for (&threads) |*t| t.join();
    try std.testing.expectEqual(@as(u64, 40_000), ctx.counter);
    try std.testing.expectEqual(@as(u64, 10_000), ctx.rw_counter);
    try std.testing.expect(threadSlot() == threadSlot());
}
