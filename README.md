# vfs / db

This repository currently contains the standalone DB library used by the VFS stack. The DB is a mmap-friendly key/value store for asset/runtime data: append-first data records, mmap base + delta indexes, journaled updates, checkpoint/optimize maintenance, and a stable C ABI.

## Current DB status

- Public ABI is `db_*` only; VFS APIs are intentionally not exported from `libdb`.
- ABI v2 uses `uint64_t db_handle_t`; `0` is invalid. Handles are pointer-address handles guarded by an internal registry at the ABI boundary.
- Public keys are raw byte slices: `(const void* key, uint64_t key_size)`.
- DB maps raw keys to internal `Key128` using a default stable hash or a caller-provided `db_context_t.hash_fn`.
- Data records persist raw key bytes and verify them on read, so binary keys and hash-collision scenarios are covered.
- Base and delta indexes are mmap-backed. Data files are not whole-file mmaped.
- `db_get_info` exposes stable runtime/file statistics.

Important limitation: `db_context_t.file_ops` is declared in the ABI, but the full custom file backend is not implemented yet. Passing non-null `file_ops` currently returns `DB_UNSUPPORTED`. The default platform IO path is the supported path today.

## Build

```powershell
zig build
zig build -Doptimize=ReleaseSafe
```

Installed artifacts are written under `zig-out/`:

- `zig-out/lib/db.lib` / static library
- `zig-out/bin/db_shared.dll` / shared library on Windows
- `zig-out/bin/db.exe` / CLI
- `zig-out/include/db.h` / public C header

## Test

```powershell
zig build test
zig build -Doptimize=ReleaseSafe
```

The test suite covers:

- C ABI v2 handle lifecycle, invalid handle safety, raw/binary keys, custom hash, collision behavior, and `db_get_info`.
- mmap delta/base index paths.
- batch atomicity and snapshot reads.
- recovery/verify corruption and truncation cases.
- checkpoint/optimize and allocator free-hole metadata.
- CLI smoke paths.

## C ABI sketch

Include `include/db.h`.

```c
#include "db.h"

db_handle_t db = db_create("my.db", NULL, NULL);
if (!db) {
    fprintf(stderr, "db_create failed: %d %s\n",
            db_last_status(), db_last_error_message());
    return 1;
}

const char key[] = { 'a', 0, 'b' };
db_put(db, key, sizeof(key), "value", 5, 0);

uint64_t size = 0;
db_get_size(db, key, sizeof(key), &size);

char buf[16];
uint64_t written = 0;
db_get_into(db, key, sizeof(key), buf, sizeof(buf), &written);

db_info_t info = {0};
info.struct_size = sizeof(info);
db_get_info(db, &info);

db_close(db);
```

Custom hash:

```c
static int my_hash(void* user, const void* key, uint64_t key_size,
                   uint64_t* out_hi, uint64_t* out_lo) {
    (void)user;
    /* Fill a stable 128-bit hash for key/key_size. */
    *out_hi = 1;
    *out_lo = 2;
    return 0;
}

db_context_t ctx = {0};
ctx.struct_size = sizeof(ctx);
ctx.version = 1;
ctx.hash_fn = my_hash;

db_handle_t db = db_create("my.db", NULL, &ctx);
```

## CLI

```powershell
zig build

.\zig-out\bin\db.exe create zig-out\bin\sample-db
Set-Content -NoNewline -Encoding ascii zig-out\bin\value.txt "hello"
.\zig-out\bin\db.exe put zig-out\bin\sample-db 0 1 zig-out\bin\value.txt
.\zig-out\bin\db.exe get zig-out\bin\sample-db 0 1 zig-out\bin\out.txt
.\zig-out\bin\db.exe verify zig-out\bin\sample-db
.\zig-out\bin\db.exe checkpoint zig-out\bin\sample-db
.\zig-out\bin\db.exe optimize zig-out\bin\sample-db
.\zig-out\bin\db.exe recover zig-out\bin\sample-db
.\zig-out\bin\db.exe bench zig-out\bin\bench-db 10000
```

The CLI still accepts keys as two integer components (`hi lo`) for convenience. The library ABI accepts raw byte keys.

## Design notes

- Writes are staged in memory and committed in batches. Reads force pending writes to commit first on the current runtime/editor model.
- Durable ordering is data record first, journal commit second, mmap delta publish last.
- `verify` checks index/data consistency and allocator free-hole metadata.
- `optimize` folds deletes/overwrites into the base index, records middle free holes, and truncates only tail-contiguous free space.
- Current runtime allocation remains append-first; reuse of persisted free holes is a planned follow-up.

See:

- `docs/design/db.md`
- `docs/design/db_arch.md`
- `docs/design/db/tasks/setup.md`
- `docs/design/db/tasks/task_00_platform_io.md` through `task_13_tools.md`

