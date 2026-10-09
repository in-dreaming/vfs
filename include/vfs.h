#ifndef VFS_H
#define VFS_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#if defined(_WIN32) && defined(VFS_SHARED)
#  if defined(VFS_BUILDING_SHARED)
#    define VFS_API __declspec(dllexport)
#  else
#    define VFS_API __declspec(dllimport)
#  endif
#else
#  define VFS_API
#endif

/* Handles are process-local opaque IDs, not pointers. A closed ID is never
 * reused; using it (or an ID of another kind) returns VFS_INVALID_ARGUMENT.
 * Volume close returns VFS_BUSY, leaving the handle valid, while files or
 * admitted operations retain it. File close invalidates its ID immediately,
 * then waits for admitted operations to finish before releasing resources.
 * No process-global registry lock is held during I/O or these waits. */
typedef uint64_t vfs_volume_t;
typedef uint64_t vfs_file_t;
typedef uint64_t vfs_file_entry_t;

typedef struct vfs_open_options {
    uint32_t struct_size;
    uint32_t flags;
    /* Decoded payload budget including pinned/inflight pages; 0 = 8 MiB.
     * Oversized pages return RESOURCE_LIMIT; transient pressure retries. */
    uint64_t page_cache_bytes;
    /* Maximum simultaneously open read-only pack stores; 0 = default (16).
     * Reads pin only their active source store. Overlay fallback/foreign refs
     * work with a limit of 1; contenders wait for an idle store. */
    uint32_t max_open_stores;
    /* Extra read-only OS handles per pack data file so concurrent reads are
     * not serialized on one file object; 0 = default (4). */
    uint32_t read_handles;
    /* Fixed lazy read workers, 0 = 4; maximum 64. */
    uint32_t read_workers;
    /* Includes queued, running and completed-but-unreleased requests; 0 = 256. */
    uint32_t max_requests;
    /* Maximum ranges per submitted batch; 0 = 256. */
    uint32_t max_ranges_per_request;
    uint32_t reserved;
    /* DB record scratch limit per read worker; 0 = 16 MiB. */
    uint64_t read_scratch_bytes;
} vfs_open_options_t;

/* Flags for vfs_open_path / vfs_open_entry. */
enum {
    /* Whole implicit pages bypass cache residency. Raw pages copy directly;
     * compressed pages use bounded decoded scratch. Partial pages and explicit
     * PageRefs still use the cache. Use for one-shot whole-file loads. */
    VFS_OPEN_STREAMING = 1u << 0,
};

/* Set struct_size to the writable allocation size before each call (at least
 * 4 bytes). The library writes only min(struct_size, sizeof(vfs_stat_t)) bytes,
 * preserves struct_size and leaves any newer caller tail untouched. Prefixes
 * may end inside a field; only fully present fields are usable by the caller.
 * Too-small sizes are rejected without writing. */
typedef struct vfs_stat {
    uint32_t struct_size;
    uint32_t flags;
    uint64_t file_entry;
    uint64_t size;
    uint64_t page_size;
    uint64_t reserved0;
} vfs_stat_t;

enum {
    VFS_OK = 0,
    VFS_NOT_FOUND = 1,
    VFS_INVALID_ARGUMENT = 2,
    VFS_IO_ERROR = 3,
    VFS_CORRUPTION = 4,
    VFS_CHECKSUM_MISMATCH = 5,
    VFS_UNSUPPORTED_VERSION = 6,
    VFS_UNSUPPORTED_FEATURE = 7,
    VFS_PERMISSION_DENIED = 8,
    VFS_KEY_COLLISION = 9,
    VFS_DB_ERROR = 10,
    VFS_BUSY = 11,
    /* An asynchronous operation was cancelled by the caller. */
    VFS_CANCELLED = 12,
    /* The patch target does not match what the DiffPacks expect (content
     * hash, PatchIntent of another chain, overlay/base mismatch). */
    VFS_PRECONDITION_FAILED = 13,
    /* A page exceeds its decoded-cache limit, or a record exceeds worker scratch. */
    VFS_RESOURCE_LIMIT = 14,
    VFS_INTERNAL_ERROR = 100,
};

/* ---- Bounded asynchronous reads (polling; no callbacks) ------------------ */
typedef uint64_t vfs_request_t;
/* Fixed-layout array element; its stride is not struct_size-extensible. */
typedef struct vfs_read_range {
    uint64_t offset;
    void* dst;
    uint64_t size;
} vfs_read_range_t;
typedef struct vfs_read_options {
    uint32_t struct_size;
    uint32_t flags; /* Must be zero. */
    /* Higher queued priority first, FIFO ties. No preemption or deadline.
     * NULL options default to 0 for reads, -1 for prefetch. */
    int32_t priority;
    uint32_t reserved;
} vfs_read_options_t;
enum {
    VFS_REQUEST_QUEUED = 0,
    VFS_REQUEST_RUNNING = 1,
    VFS_REQUEST_DONE = 2,
    VFS_REQUEST_FAILED = 3,
    VFS_REQUEST_CANCELLED = 4,
};
typedef struct vfs_request_progress {
    uint32_t struct_size;
    uint32_t state;
    uint32_t ranges_total;
    uint32_t ranges_done; /* Successfully completed ranges. */
    uint64_t bytes_read; /* Logical bytes, including a valid partial prefix. */
    int32_t last_status;
    uint32_t reserved;
} vfs_request_progress_t;
typedef struct vfs_read_result {
    uint32_t struct_size;
    uint32_t state; /* QUEUED means unexecuted, including after batch failure. */
    uint64_t bytes_read;
    int32_t last_status;
    uint32_t reserved;
} vfs_read_result_t;
/* Descriptors/options are copied before return. Destination buffers must stay
 * valid and unmodified until terminal poll/wait or request_end returns.
 * Each batch is one file, runs ranges in order, and stops on first failure.
 * Overlapping destinations within that batch therefore follow range order;
 * callers synchronize buffers shared between separate requests themselves.
 * EOF is successful short IO. Submit failure sets out_request=0 and writes no
 * destination. Queue/result capacity exhaustion returns VFS_BUSY.
 * Cancellation is cooperative between pages; an active backend call/shared
 * load may finish. On failure/cancel only reported prefixes are valid.
 * Completed metadata survives file/volume close until request_end. */
VFS_API int vfs_read_async(vfs_file_t file, uint64_t offset, void* dst, uint64_t size,
                            const vfs_read_options_t* options, vfs_request_t* out_request);
VFS_API int vfs_read_batch_async(vfs_file_t file, const vfs_read_range_t* ranges, uint32_t count,
                                  const vfs_read_options_t* options, vfs_request_t* out_request);
/* Populates the shared decoded cache, including on STREAMING file handles.
 * Completion does not pin pages; normal eviction is always allowed. */
VFS_API int vfs_prefetch_async(vfs_file_t file, uint64_t offset, uint64_t size,
                                const vfs_read_options_t* options, vfs_request_t* out_request);
VFS_API int vfs_request_poll(vfs_request_t request, vfs_request_progress_t* out_progress);
VFS_API int vfs_request_result(vfs_request_t request, uint32_t index, vfs_read_result_t* out_result);
/* VFS_BUSY on timeout; VFS_OK on any terminal state. Inspect recorded status. */
VFS_API int vfs_request_wait(vfs_request_t request, uint32_t timeout_ms);
VFS_API int vfs_request_cancel(vfs_request_t request);
/* Cancels unfinished work, drains destination writes and consumes the handle.
 * Returns VFS_OK when released; inspect the IO result before calling end. */
VFS_API int vfs_request_end(vfs_request_t request);

typedef struct vfs_stats {
    uint32_t struct_size;
    uint32_t flags;
    uint64_t cache_hits, cache_misses, cache_coalesced, cache_evictions;
    uint64_t cache_resident_bytes, cache_allocated_bytes, cache_peak_bytes;
    uint64_t cache_inflight_bytes, cache_pinned_bytes, cache_evicted_pinned_bytes;
    uint64_t requests_queued, requests_running, requests_retained;
    uint64_t requests_completed, requests_failed, requests_cancelled, requests_rejected;
    uint64_t bytes_read, bytes_prefetched;
    uint64_t open_stores, cache_limit_bytes, scratch_limit_per_worker;
    uint32_t worker_limit, request_limit, ranges_limit;
    uint32_t backend; /* 0 = filesystem, 1 = custom (Zig-facing mount API). */
    /* Scratch sampled at request boundaries; active allocations may be newer. */
    uint64_t scratch_retained_bytes, scratch_peak_worker_bytes;
} vfs_stats_t;
/* Approximate concurrent sample. Request counters last for the volume;
 * cache counters also survive admitted mounted cache invalidation.
 * Bytes are logical decoded bytes, not physical disk/network throughput.
 * Pinned bytes overlap resident/evicted fields. Allocation bytes cover page
 * payloads, not cache metadata, caller buffers, OS mappings or backend storage. */
VFS_API int vfs_get_stats(vfs_volume_t volume, vfs_stats_t* out_stats);

/* ---- Patch (V1.5, polling; no callbacks) ---------------------------------- */

typedef uint64_t vfs_patch_t;

/* Flags for vfs_patch_options_t.flags. */
enum {
    /* Load every DiffPack fully into memory (default: automatic by size). */
    VFS_PATCH_IN_MEMORY = 1u << 0,
    /* Read DiffPacks from disk even when small. */
    VFS_PATCH_DISK = 1u << 1,
    /* Accept a pending PatchIntent left by a different chain to the same version. */
    VFS_PATCH_FORCE = 1u << 2,
    /* Run the store optimizer after the new version is published. */
    VFS_PATCH_OPTIMIZE = 1u << 3,
};

/* Values for vfs_patch_options_t.verify. */
enum {
    VFS_PATCH_VERIFY_NONE = 0,
    /* Re-decode every page written by this run. */
    VFS_PATCH_VERIFY_TOUCHED = 1,
    /* TOUCHED plus a whole-pack verification after the store is closed. */
    VFS_PATCH_VERIFY_FULL = 2,
};

typedef struct vfs_patch_options {
    uint32_t struct_size;
    uint32_t flags;
    /* Worker threads; 0 = default (logical CPU count). */
    uint32_t threads;
    /* Staged bytes per shard before a batch is committed; 0 = default (16 MiB). */
    uint32_t batch_bytes;
    /* Automatic in-memory loading applies to DiffPacks up to this size; 0 = default (512 MiB). */
    uint64_t in_memory_max_bytes;
    uint32_t verify;
    uint32_t reserved;
    /* Stop at this pack version; 0 = highest reachable. */
    uint64_t to_version;
} vfs_patch_options_t;

/* Values for vfs_patch_progress_t.state. */
enum {
    VFS_PATCH_RUNNING = 0,
    VFS_PATCH_DONE = 1,
    VFS_PATCH_FAILED = 2,
    VFS_PATCH_CANCELLED = 3,
};

/* Same bounded-prefix output convention as vfs_stat_t, with an 8-byte minimum.
 * Initialize struct_size before polling, including when checking invalid IDs. */
typedef struct vfs_patch_progress {
    uint32_t struct_size;
    uint32_t state;
    uint64_t units_total;
    uint64_t units_done;
    uint64_t bytes_written;
    uint64_t bytes_read;
    /* VFS_OK while running or on success; the failure status otherwise. */
    int32_t last_status;
    int32_t reserved;
    /* Filled once state != VFS_PATCH_RUNNING. */
    uint64_t from_version;
    uint64_t to_version;
} vfs_patch_progress_t;

/* Starts a patch on a background thread. `target_pack` is patched in place,
 * or, when `overlay_pack_or_null` is given, stays read-only and the changes
 * are written to the overlay (created if missing). OFFLINE API: callers must
 * stop all readers/writers, including other processes, for these paths. The
 * advisory lock excludes cooperating patchers only. */
VFS_API int vfs_patch_begin(const char* target_pack, const char* overlay_pack_or_null,
                            const char* const* diff_dirs, uint32_t diff_count,
                            const vfs_patch_options_t* options, vfs_patch_t* out_patch);
/* Admits an update of an existing mounted pack (its overlay when present).
 * Busy if this volume has open files/requests, another update, or any target
 * path is mounted more than once in this process. Canonical paths include
 * ordinary symlink aliases. Independent processes/raw DB readers must still
 * be stopped by the caller. Opens/stats in this volume are Busy during the
 * job; partial failure leaves the target Busy until a successful resume.
 * Completion releases the volume lease and refreshes reader/cache generation.
 * No caller handles are force-closed; no live snapshot migration is promised. */
VFS_API int vfs_patch_begin_in_volume(vfs_volume_t volume, uint64_t pack_id,
                                    const char* const* diff_dirs, uint32_t diff_count,
                                    const vfs_patch_options_t* options, vfs_patch_t* out_patch);
/* Non-blocking snapshot of the progress counters. */
VFS_API int vfs_patch_poll(vfs_patch_t patch, vfs_patch_progress_t* out_progress);
/* Blocks until the patch finished or `timeout_ms` elapsed; returns VFS_BUSY on timeout. */
VFS_API int vfs_patch_wait(vfs_patch_t patch, uint32_t timeout_ms);
/* Requests cancellation; the run stops at the next task boundary. */
VFS_API int vfs_patch_cancel(vfs_patch_t patch);
/* Releases the handle; a still-running patch is cancelled and joined first. */
VFS_API int vfs_patch_end(vfs_patch_t patch);

VFS_API int vfs_open_volume(const char* path, const vfs_open_options_t* options, vfs_volume_t* out_volume);
VFS_API int vfs_close_volume(vfs_volume_t volume);
VFS_API int vfs_mount_pack(vfs_volume_t volume, const char* pack_path, uint32_t priority, uint32_t flags);
VFS_API int vfs_open_path(vfs_volume_t volume, const char* path, uint32_t flags, vfs_file_t* out_file);
VFS_API int vfs_open_entry(vfs_volume_t volume, uint64_t file_entry, uint32_t flags, vfs_file_t* out_file);
VFS_API int vfs_stat_path(vfs_volume_t volume, const char* path, vfs_stat_t* out_stat);
VFS_API int vfs_stat_entry(vfs_volume_t volume, uint64_t file_entry, vfs_stat_t* out_stat);
VFS_API int vfs_read_at(vfs_file_t file, uint64_t offset, void* dst, uint64_t size, uint64_t* out_read);
VFS_API int vfs_close_file(vfs_file_t file);
VFS_API int vfs_last_status(void);
VFS_API const char* vfs_last_error_message(void);

#ifdef __cplusplus
}
#endif

#endif
