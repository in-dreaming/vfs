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
    /* Decoded page cache budget in bytes; 0 = default (8 MiB). */
    uint64_t page_cache_bytes;
    /* Maximum simultaneously open read-only pack stores; 0 = default (16).
     * Reads pin only their active source store. Overlay fallback/foreign refs
     * work with a limit of 1; contenders wait for an idle store. */
    uint32_t max_open_stores;
    /* Extra read-only OS handles per pack data file so concurrent reads are
     * not serialized on one file object; 0 = default (4). */
    uint32_t read_handles;
} vfs_open_options_t;

/* Flags for vfs_open_path / vfs_open_entry. */
enum {
    /* Reads covering a whole page bypass the page cache and decode straight
     * into the caller's buffer. Use for one-shot whole-file loads. */
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
    /* A patch was cancelled by the caller. */
    VFS_CANCELLED = 12,
    /* The patch target does not match what the DiffPacks expect (content
     * hash, PatchIntent of another chain, overlay/base mismatch). */
    VFS_PRECONDITION_FAILED = 13,
    VFS_INTERNAL_ERROR = 100,
};

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
