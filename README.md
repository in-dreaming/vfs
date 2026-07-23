# VFS and DB

This repository ships two independently usable layers for engine and runtime data:

- `libdb` is a standalone, durable key/value database. Applications can link it directly when they need raw binary-key storage, batch and snapshot reads, recovery, verification, checkpointing, or optimization.
- `libvfs` is a pack-based virtual file system built on `libdb`. It turns DB-backed pack objects into files addressed by normalized virtual paths or stable `uint64_t` file entries, then composes packs into priority-ordered volumes.

`libvfs` depends on `libdb`; `libdb` does not depend on or expose VFS concepts. Use `libdb` for application-owned records and `libvfs` for packaged asset delivery, overlays, and file-oriented runtime access.

## What VFS provides today

- Pack creation from source files, with a pack manifest, path index, file manifests, and page values stored in a DB-backed pack directory.
- Access by either virtual path or `vfs_file_entry_t`; path lookup and entry lookup are intentionally separate paths.
- Mounted volumes with explicit priority. Higher-priority packs overlay lower-priority packs, and entry tombstones hide lower-priority files.
- Offset-based file reads with page identity and checksum validation.
- A writable out pack for whole-file updates, entry deletion, and page-reference reuse for unchanged pages.
- Build configuration and incremental planning, patch/merge mutation planning, resource-aware task-graph scheduling, and atomic volume-manifest staging/recovery.
- Pack and volume tools for inspection, verification, extraction, and recovery.
- A stable C ABI with handle validation and caller-owned read buffers; it does not use callbacks.

### Current limitations

- Runtime compression support is **`none` only**. `lz4` and `zstd` appear in format/config enums as reserved future choices, but pack creation and reading reject them with `UnsupportedFeature`.
- The public C ABI is currently read/mount oriented. Writable-pack and mutation workflows are available through the Zig library APIs and tools, not as C write calls.
- `db_context_t.file_ops` is declared by `libdb`, but custom file backends are not implemented. The supported pack storage path uses platform IO.

## Architecture

```text
Engine / Runtime / Editor
  open(path | FileEntry) · stat · read_at
                 |
VFS Volume
  mount table · overlay resolver · path/entry resolvers · file handles · page cache
                 |
VFS Pack
  pack/path/file manifests · page values · tombstones · build and mutation metadata
                 |
libdb
  key/value · batch · snapshot · journal · mmap indexes · checkpoint · verify · recover
```

A `FileEntry` is the stable logical identity of a file; paths are a lookup mechanism rather than the identity itself. VFS derives compact object keys for manifests and pages, then verifies file/page identity again from the stored value headers so collisions or corrupt data cannot silently return the wrong content.

Pack directories contain DB files such as `index.db` and `data_*.db`. A volume is a set of mounted packs ordered by priority; equal priorities are rejected to keep resolution deterministic.

## Build and test

```powershell
zig build
zig build test
zig build -Doptimize=ReleaseSafe
zig build test -Doptimize=ReleaseSafe
```

Installed artifacts are placed in `zig-out/`:

- `zig-out/lib/vfs.lib` and `zig-out/bin/vfs_shared.dll`
- `zig-out/include/vfs.h`
- `zig-out/lib/db.lib` and `zig-out/bin/db_shared.dll`
- `zig-out/include/db.h`
- `zig-out/bin/vfs.exe` and `zig-out/bin/db.exe`

## VFS command-line tools

```powershell
# Create an empty pack.
.\zig-out\bin\vfs.exe create-pack zig-out\sample-pack

# Build a one-file pack: <pack> <virtual-path> <file-entry> <source-file>.
.\zig-out\bin\vfs.exe put-file zig-out\sample-pack /textures/a.bin 1001 .\assets\a.bin

# Inspect and validate a pack.
.\zig-out\bin\vfs.exe dump-pack zig-out\sample-pack
.\zig-out\bin\vfs.exe dump-path-index zig-out\sample-pack
.\zig-out\bin\vfs.exe dump-file zig-out\sample-pack 1001
.\zig-out\bin\vfs.exe verify-pack zig-out\sample-pack

# Extract, repair, or validate a staged volume.
.\zig-out\bin\vfs.exe extract-file zig-out\sample-pack 1001 .\out\a.bin
.\zig-out\bin\vfs.exe recover-pack zig-out\sample-pack
.\zig-out\bin\vfs.exe verify-volume .\volume-root

# Build from a VFS build configuration.
.\zig-out\bin\vfs.exe build .\vfs-build.cfg
```

`put-file` and `build-simple` are aliases with the same arguments. `verify-pack` validates manifests, paths, pages, checksums, and referenced page identities; a failed validation returns a non-zero exit code.

## VFS C ABI

Include `include/vfs.h`. The ABI uses 64-bit opaque handles; `0` is invalid. `vfs_stat_t` and `vfs_open_options_t` start with `struct_size` for forward-compatible struct extension.

```c
#include "vfs.h"
#include <string.h>

vfs_volume_t volume = 0;
vfs_file_t file = 0;

if (vfs_open_volume("runtime", NULL, &volume) != VFS_OK ||
    vfs_mount_pack(volume, "packs/base", 10, 0) != VFS_OK ||
    vfs_open_path(volume, "/textures/a.bin", 0, &file) != VFS_OK) {
    /* Inspect vfs_last_status() and vfs_last_error_message(). */
}

vfs_stat_t stat = {0};
stat.struct_size = sizeof(stat);
if (vfs_stat_path(volume, "/textures/a.bin", &stat) == VFS_OK) {
    unsigned char bytes[4096];
    uint64_t read = 0;
    vfs_read_at(file, 0, bytes, sizeof(bytes), &read);
}

if (file) vfs_close_file(file);
if (volume) vfs_close_volume(volume);
```

Use `vfs_open_entry(volume, file_entry, ...)` and `vfs_stat_entry(...)` when the caller already owns the stable `FileEntry`. This bypasses path lookup. A volume cannot be closed while it still has open file handles (`VFS_BUSY`).

## Standalone DB storage layer

`libdb` is not an internal-only VFS implementation detail. It is a standalone mmap-friendly key/value store with a `db_*` C ABI and no dependency on pack, path, volume, or file-entry types.

### What DB provides today

- Raw binary keys and values. The public ABI accepts `(const void* key, uint64_t key_size)`; keys are stored and rechecked on read, including hash-collision cases.
- Durable append-first data records, mmap-backed base/delta indexes, journaled updates, checkpointing, optimization, recovery, and verification.
- Batched writes and snapshot reads, plus `db_get_info` for runtime and file statistics.
- 64-bit opaque `db_handle_t` handles. `0` is invalid; APIs report status through return values, `db_last_status()`, and `db_last_error_message()`.
- A default stable 128-bit key hash, with an optional caller-supplied `db_context_t.hash_fn`.

`db_context_t.file_ops` reserves a custom file-backend seam, but it is not implemented today: passing non-null `file_ops` returns `DB_UNSUPPORTED`. The supported storage backend is platform IO.

### DB C ABI

Include `include/db.h` when using DB directly:

```c
#include "db.h"

const char key[] = { 'a', 0, 'b' };
db_handle_t db = db_create("runtime-db", NULL, NULL);
if (!db) {
    /* Inspect db_last_status() and db_last_error_message(). */
    return 1;
}

if (db_put(db, key, sizeof(key), "value", 5, 0) == DB_OK) {
    uint64_t value_size = 0;
    if (db_get_size(db, key, sizeof(key), &value_size) == DB_OK) {
        char value[16];
        uint64_t written = 0;
        db_get_into(db, key, sizeof(key), value, sizeof(value), &written);
    }
}

db_close(db);
```

### DB command-line tools

```powershell
.\zig-out\bin\db.exe create zig-out\sample-db
Set-Content -NoNewline -Encoding ascii zig-out\value.txt "hello"
.\zig-out\bin\db.exe put zig-out\sample-db 0 1 zig-out\value.txt
.\zig-out\bin\db.exe get zig-out\sample-db 0 1 zig-out\out.txt
.\zig-out\bin\db.exe verify zig-out\sample-db
.\zig-out\bin\db.exe checkpoint zig-out\sample-db
.\zig-out\bin\db.exe optimize zig-out\sample-db
.\zig-out\bin\db.exe recover zig-out\sample-db
```

The CLI accepts keys as `hi lo` integer components for convenience; the library ABI accepts arbitrary raw byte keys. See `include/db.h` for the full API and `docs/design/db.md` for the storage design.

## Design and task references

- `docs/vfs/vfs_arch.md` — VFS data model and runtime architecture.
- `docs/vfs/vfs_roadmap.md` — implementation roadmap.
- `docs/vfs/task/setup.md` — VFS contracts and validation requirements.
- `docs/design/db_arch.md` — DB storage design.
