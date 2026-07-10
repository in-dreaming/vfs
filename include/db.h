#ifndef DB_H
#define DB_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#if defined(_WIN32) && defined(DB_SHARED)
#  if defined(DB_BUILDING_SHARED)
#    define DB_API __declspec(dllexport)
#  else
#    define DB_API __declspec(dllimport)
#  endif
#else
#  define DB_API
#endif

typedef uint64_t db_handle_t;

typedef int (*db_hash_fn)(
    void* user_data,
    const void* key,
    uint64_t key_size,
    uint64_t* out_hi,
    uint64_t* out_lo);

typedef struct db_file_ops {
    uint32_t struct_size;
    uint32_t version;
    void* user_data;
    void* open;
    void* close;
    void* read_at;
    void* write_at;
    void* get_size;
    void* set_size;
    void* sync;
    void* preallocate;
    void* mmap;
    void* msync;
    void* munmap;
} db_file_ops_t;

typedef struct db_context {
    uint32_t struct_size;
    uint32_t version;
    void* user_data;
    db_hash_fn hash_fn;
    const db_file_ops_t* file_ops;
} db_context_t;

typedef struct db_open_options {
    uint32_t struct_size;
    uint32_t flags;
    uint32_t durability;
    uint32_t reserved0;
    uint64_t max_delta_entries;
    uint64_t data_file_target_size;
} db_open_options_t;

typedef struct db_info {
    uint32_t struct_size;
    uint32_t abi_version;
    uint32_t format_version;
    uint32_t open_mode;
    uint64_t feature_flags;
    uint64_t key_count;
    uint64_t value_count;
    uint64_t data_bytes;
    uint64_t index_bytes;
    uint64_t delta_entries;
    uint64_t pending_ops;
    uint64_t free_bytes;
    uint64_t tail_free_bytes;
    uint64_t mmap_index_bytes;
} db_info_t;

enum {
    DB_OK = 0,
    DB_NOT_FOUND = 1,
    DB_INVALID_ARGUMENT = 2,
    DB_IO_ERROR = 3,
    DB_CORRUPTION = 4,
    DB_CHECKSUM_MISMATCH = 5,
    DB_UNSUPPORTED_VERSION = 6,
    DB_BUSY = 7,
    DB_NO_SPACE = 8,
    DB_PERMISSION_DENIED = 9,
    DB_UNSUPPORTED = 10,
    DB_INTERNAL_ERROR = 100,
};

enum {
    DB_DURABILITY_NONE = 0,
    DB_DURABILITY_ASYNC = 1,
    DB_DURABILITY_SYNC = 2,
};

enum {
    DB_OPEN_READ_WRITE = 0,
    DB_OPEN_READ_ONLY = 1,
    DB_OPEN_WRITE_ONLY = 2,
};

DB_API db_handle_t db_create(const char* path, const db_open_options_t* options, const db_context_t* context);
DB_API db_handle_t db_open(const char* path, const db_open_options_t* options, const db_context_t* context);
DB_API int db_close(db_handle_t db);

DB_API int db_last_status(void);
DB_API const char* db_last_error_message(void);

DB_API int db_get_info(db_handle_t db, db_info_t* out_info);
DB_API int db_get_size(db_handle_t db, const void* key, uint64_t key_size, uint64_t* out_size);
DB_API int db_get_into(db_handle_t db, const void* key, uint64_t key_size, void* dst, uint64_t dst_size, uint64_t* out_written);
DB_API int db_put(db_handle_t db, const void* key, uint64_t key_size, const void* data, uint64_t size, uint32_t flags);
DB_API int db_delete(db_handle_t db, const void* key, uint64_t key_size);
DB_API int db_commit(db_handle_t db, uint32_t durability);
DB_API int db_checkpoint(db_handle_t db, uint32_t flags);
DB_API int db_verify(db_handle_t db, uint32_t flags);
DB_API int db_recover(const char* path, uint32_t flags, const db_context_t* context);
DB_API int db_optimize(db_handle_t db, uint32_t flags);

DB_API db_handle_t db_batch_begin(db_handle_t db);
DB_API int db_batch_put(db_handle_t batch, const void* key, uint64_t key_size, const void* data, uint64_t size, uint32_t flags);
DB_API int db_batch_delete(db_handle_t batch, const void* key, uint64_t key_size);
DB_API int db_batch_commit(db_handle_t batch, uint32_t durability);
DB_API int db_batch_rollback(db_handle_t batch);

DB_API db_handle_t db_snapshot_begin(db_handle_t db);
DB_API int db_snapshot_get_size(db_handle_t snapshot, const void* key, uint64_t key_size, uint64_t* out_size);
DB_API int db_snapshot_get_into(db_handle_t snapshot, const void* key, uint64_t key_size, void* dst, uint64_t dst_size, uint64_t* out_written);
DB_API int db_snapshot_end(db_handle_t snapshot);

#ifdef __cplusplus
}
#endif

#endif
