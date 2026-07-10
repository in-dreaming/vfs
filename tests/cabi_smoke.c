#include "db.h"

#include <stdint.h>
#include <stdio.h>
#include <string.h>

int main(int argc, char** argv) {
    if (argc != 2) return 2;

    db_t* db = 0;
    db_open_options_t options;
    memset(&options, 0, sizeof(options));
    options.struct_size = (uint32_t)sizeof(options);
    options.durability = DB_DURABILITY_SYNC;

    int rc = db_open(argv[1], &options, &db);
    if (rc != DB_OK) return rc;

    db_key128_t key = { 1, 2 };
    const char payload[] = "c-abi";
    rc = db_put(db, key, payload, sizeof(payload) - 1, 0);
    if (rc != DB_OK) return rc;
    rc = db_commit(db, DB_DURABILITY_SYNC);
    if (rc != DB_OK) return rc;

    uint64_t size = 0;
    rc = db_get_size(db, key, &size);
    if (rc != DB_OK || size != sizeof(payload) - 1) return 10;

    char out[16];
    uint64_t written = 0;
    rc = db_get_into(db, key, out, sizeof(out), &written);
    if (rc != DB_OK || written != sizeof(payload) - 1) return 11;
    if (memcmp(out, payload, sizeof(payload) - 1) != 0) return 12;

    rc = db_checkpoint(db, 0);
    if (rc != DB_OK) return rc;
    rc = db_verify(db, 0);
    if (rc != DB_OK) return rc;
    rc = db_optimize(db, 0);
    if (rc != DB_OK) return rc;

    rc = db_close(db);
    if (rc != DB_OK) return rc;
    return 0;
}
