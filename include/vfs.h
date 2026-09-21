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

typedef uint64_t vfs_volume_t;
typedef uint64_t vfs_file_t;
typedef uint64_t vfs_file_entry_t;

typedef struct vfs_open_options {
    uint32_t struct_size;
    uint32_t flags;
    /* Decoded page cache budget in bytes; 0 = default (8 MiB). */
    uint64_t page_cache_bytes;
    /* Maximum simultaneously open read-only pack stores; 0 = default (16). */
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
    VFS_INTERNAL_ERROR = 100,
};

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
