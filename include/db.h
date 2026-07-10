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

typedef struct db db_t;
typedef struct db_batch db_batch_t;
typedef struct db_snapshot db_snapshot_t;

typedef struct db_key128 {
    uint64_t hi;
    uint64_t lo;
} db_key128_t;

typedef struct db_open_options {
    uint32_t struct_size;
    uint32_t flags;
    uint32_t durability;
    uint32_t reserved0;
    uint64_t max_delta_entries;
    uint64_t data_file_target_size;
} db_open_options_t;

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
    DB_INTERNAL_ERROR = 100,
};

enum {
    DB_DURABILITY_NONE = 0,
    DB_DURABILITY_ASYNC = 1,
    DB_DURABILITY_SYNC = 2,
};

enum {
    DB_OPEN_READ_ONLY = 1,
    DB_OPEN_WRITE_ONLY = 2,
    DB_OPEN_READ_WRITE = 0,
};

DB_API int db_open(const char* path, const db_open_options_t* options, db_t** out_db);
DB_API int db_close(db_t* db);
DB_API int db_get_size(db_t* db, db_key128_t key, uint64_t* out_size);
DB_API int db_get_into(db_t* db, db_key128_t key, void* dst, uint64_t dst_size, uint64_t* out_written);
DB_API int db_put(db_t* db, db_key128_t key, const void* data, uint64_t size, uint32_t flags);
DB_API int db_delete(db_t* db, db_key128_t key);
DB_API int db_commit(db_t* db, uint32_t durability);
DB_API int db_checkpoint(db_t* db, uint32_t flags);
DB_API int db_verify(db_t* db, uint32_t flags);
DB_API int db_recover(const char* path, uint32_t flags);
DB_API int db_optimize(db_t* db, uint32_t flags);

DB_API int db_batch_begin(db_t* db, db_batch_t** out_batch);
DB_API int db_batch_put(db_batch_t* batch, db_key128_t key, const void* data, uint64_t size, uint32_t flags);
DB_API int db_batch_delete(db_batch_t* batch, db_key128_t key);
DB_API int db_batch_commit(db_batch_t* batch, uint32_t durability);
DB_API int db_batch_rollback(db_batch_t* batch);

DB_API int db_snapshot_begin(db_t* db, db_snapshot_t** out_snapshot);
DB_API int db_snapshot_get_size(db_snapshot_t* snapshot, db_key128_t key, uint64_t* out_size);
DB_API int db_snapshot_get_into(db_snapshot_t* snapshot, db_key128_t key, void* dst, uint64_t dst_size, uint64_t* out_written);
DB_API int db_snapshot_end(db_snapshot_t* snapshot);

#ifdef __cplusplus
}
#endif

#endif
