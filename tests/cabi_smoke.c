#include "db.h"

#include <stdint.h>
#include <stdio.h>
#include <string.h>

#define CHECK(expr) do { if (!(expr)) { \
    fprintf(stderr, "DB ABI check failed at line %d: %s (status=%d, %s)\n", \
            __LINE__, #expr, db_last_status(), db_last_error_message()); \
    return 1; \
} } while (0)

/* The build gives each language/linkage variant its own owned directory. */
int main(int argc, char** argv) {
    CHECK(argc == 2);
    const unsigned char key[] = { 'a', 0, 'b', 255 };
    const unsigned char batch_key[] = { 'a', 0, 'c', 254 };
    const char payload[] = "c-abi";
    db_open_options_t options;
    memset(&options, 0, sizeof(options));
    options.struct_size = (uint32_t)sizeof(options);
    options.durability = DB_DURABILITY_SYNC;

    db_handle_t db = db_create(argv[1], &options, NULL);
    CHECK(db != 0);
    CHECK(db_put(db, key, sizeof(key), payload, sizeof(payload) - 1, 0) == DB_OK);
    CHECK(db_commit(db, DB_DURABILITY_SYNC) == DB_OK);
    uint64_t size = 0;
    CHECK(db_get_size(db, key, sizeof(key), &size) == DB_OK);
    CHECK(size == sizeof(payload) - 1);
    char out[16];
    uint64_t written = 0;
    CHECK(db_get_into(db, key, sizeof(key), out, sizeof(out), &written) == DB_OK);
    CHECK(written == sizeof(payload) - 1 && memcmp(out, payload, written) == 0);

    db_handle_t batch = db_batch_begin(db);
    CHECK(batch != 0);
    CHECK(db_close(db) == DB_BUSY);
    CHECK(db_batch_put(batch, batch_key, sizeof(batch_key), payload, sizeof(payload) - 1, 0) == DB_OK);
    CHECK(db_batch_commit(batch, DB_DURABILITY_SYNC) == DB_OK);
    CHECK(db_batch_rollback(batch) == DB_INVALID_ARGUMENT);
    db_handle_t snapshot = db_snapshot_begin(db);
    CHECK(snapshot != 0);
    CHECK(db_close(db) == DB_BUSY);
    CHECK(db_snapshot_get_into(snapshot, batch_key, sizeof(batch_key), out, sizeof(out), &written) == DB_OK);
    CHECK(written == sizeof(payload) - 1 && memcmp(out, payload, written) == 0);
    CHECK(db_snapshot_end(snapshot) == DB_OK);
    CHECK(db_snapshot_end(snapshot) == DB_INVALID_ARGUMENT);

    db_info_t info;
    memset(&info, 0, sizeof(info));
    info.struct_size = (uint32_t)sizeof(info);
    CHECK(db_get_info(db, &info) == DB_OK);
    CHECK(db_checkpoint(db, 0) == DB_OK);
    CHECK(db_verify(db, 0) == DB_OK);
    CHECK(db_optimize(db, 0) == DB_OK);
    CHECK(db_close(db) == DB_OK);
    CHECK(db_close(db) == DB_INVALID_ARGUMENT);
    CHECK(db_get_size(db, key, sizeof(key), &size) == DB_INVALID_ARGUMENT);

    db = db_open(argv[1], &options, NULL);
    CHECK(db != 0);
    CHECK(db_get_into(db, key, sizeof(key), out, sizeof(out), &written) == DB_OK);
    CHECK(written == sizeof(payload) - 1 && memcmp(out, payload, written) == 0);
    CHECK(db_delete(db, batch_key, sizeof(batch_key)) == DB_OK);
    CHECK(db_commit(db, DB_DURABILITY_SYNC) == DB_OK);
    CHECK(db_close(db) == DB_OK);
    return 0;
}
