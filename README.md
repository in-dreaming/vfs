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
- Multi-shard packs: a pack's `data_000.db … data_NNN.db` files are written and committed in parallel; every object of a file lives in that file's shard.
- Per-page `lz4` compression (`none` and `lz4` at runtime; `zstd` is still a reserved enum value).
- Build configuration and incremental planning, a resource-aware task-graph scheduler (`cpu`, `cpu_codec`, `mem_bytes`, per-shard `db_write_shard` tokens), and atomic volume-manifest staging/recovery.
- Version-to-version **DiffPacks**: page-level (`hdiff` over stored pages), logical-block (`hdiff` over decompressed blocks, recompressed on apply) or replace units, chosen per file by a strategy ladder with size-ratio downgrade.
- **Patch** of a pack in place or into an overlay pack, with chain selection across several DiffPacks, per-unit idempotent re-run, a `PatchIntent` marker for crash recovery, and an optional post-patch `optimize`.
- Pack, diff and volume tools for inspection, verification, extraction, recovery and benchmarking.
- A stable C ABI with handle validation and caller-owned read buffers; it does not use callbacks.

### Current limitations

- `zstd` is not implemented; pack creation and reading reject it with `UnsupportedFeature`.
- The public C ABI covers synchronous/asynchronous reads, ordered batches, prefetch, diagnostics, mount and polling-style patch application. Pack building and diffing are available through the Zig library APIs and tools, not as C calls.
- `db_context_t.file_ops` is implemented. VFS Zig options support readonly custom mounts; the public VFS C API keeps filesystem paths and no new callback vtable. Custom mounted writes/patches are unsupported. See [runtime read contracts](docs/vfs/runtime_reads.md).

## Architecture

```text
Engine / Runtime / Editor
  open(path | FileEntry) · stat · read_at
                 |
VFS Volume
  mount table · overlay resolver · path/entry resolvers · file handles · page cache
                 |
VFS Pack
  pack/path/file manifests · page values · tombstones · placeholders · patch intent
                 |
VFS Diff / Patch
  pack scan · strategy · hdiff units · DiffPack · chain · coalesce · shard writers
                 |
libdb
  key/value · batch · snapshot · journal · mmap indexes · data shards · checkpoint · verify · recover
```

A `FileEntry` is the stable logical identity of a file; paths are a lookup mechanism rather than the identity itself. VFS derives compact object keys for manifests and pages, then verifies file/page identity again from the stored value headers so collisions or corrupt data cannot silently return the wrong content.

Pack directories contain `manifest.db`, `index.db` and one or more `data_NNN.db` shards. A volume is a set of mounted packs ordered by priority; equal priorities are rejected to keep resolution deterministic. An overlay pack (produced by `patch-pack --overlay`) is mounted above its base and only holds the objects that changed; page placeholders in the overlay hide base pages that no longer exist.

## Build and test

Use **official Zig 0.16.0**, pinned in `.zigversion`, on PATH. No external
libraries or package manager are required. Other Zig releases/nightlies are not
part of the supported toolchain. Keep the pin and both CI workflows in sync.

```sh
zig version                         # must print 0.16.0
zig build                           # native Debug, static/shared DB + VFS + tools
zig build test                      # full regressions, including all eight ABI consumers
zig build test -Doptimize=ReleaseSafe
zig build test-abi                   # C11/C++17 × DB/VFS × static/shared only
zig build check-abi                  # compile/link consumers only; useful for cross targets
zig fmt --check build.zig src tests tools
```

Run fixture-mutating commands **sequentially** in a checkout. Historical test
paths are fixed; independent concurrent `zig build test` processes can collide.
`-j2` bounds compilation parallelism on smaller machines; it does not make
concurrent aggregate invocations safe. Zig's own build driver handles the
independent fixtures within one invocation.

Installed headers are `zig-out/include/db.h` and `vfs.h`. Artifacts vary by target:

- Linux: `zig-out/lib/libdb.a`, `libvfs.a`, `libdb_shared.so`, `libvfs_shared.so`
- macOS: static `.a` and shared `.dylib` libraries under `zig-out/lib/`
- Windows: static/import libraries under `zig-out/lib/`, shared `.dll` files under `zig-out/bin/`
- Tools: `zig-out/bin/db` and `vfs` (`.exe` on Windows)

C-facing library roots link libc, including the platform thread runtime. C and
C++ consumers must link the corresponding library and arrange normal shared
library lookup when using DLLs/dylibs/shared objects. Define `DB_SHARED` or
`VFS_SHARED` for Windows shared-library imports. `test-abi` exercises actual
C/C++ process startup, DB persistence and VFS background patch threads, not just
header parsing. See [validation and platform coverage](docs/validation.md) for
commands, reliability/performance entry points, and current verification limits.

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

# Diff two versions of a pack, inspect and validate the DiffPack.
.\zig-out\bin\vfs.exe diff-pack .\pack-v1 .\pack-v2 .\diff-1-2 --threads 8
.\zig-out\bin\vfs.exe dump-diff .\diff-1-2
.\zig-out\bin\vfs.exe verify-diff .\diff-1-2

# Patch in place (interrupted runs resume idempotently), or into an overlay next to a read-only base.
.\zig-out\bin\vfs.exe patch-pack .\pack-v1 .\diff-1-2 .\diff-2-3 --threads 8 --optimize --verify full --trace .\patch-trace.json
.\zig-out\bin\vfs.exe patch-pack .\pack-v1 .\diff-1-2 --overlay .\pack-v1-overlay

# Run the patch experiment matrix (in-memory/disk DiffPack, batch sizes, threads, durability) on a scratch copy.
.\zig-out\bin\vfs.exe bench-patch .\pack-v1 .\scratch .\diff-1-2
```

`put-file` and `build-simple` are aliases with the same arguments. `verify-pack` validates manifests, paths, pages, checksums, and referenced page identities; a failed validation returns a non-zero exit code.

A build configuration is a plain `key=value` file:

```text
pack_path=zig-out\pack-v2
pack_id=3
pack_version=2
shards=4
default_page_size=65536
default_codec=lz4
default_codec_level=4
default_diff_strategy=auto
file=/textures/a.bin|1001|assets\a.bin
file=/audio/b.bin|1002|assets\b.bin|4096|none|0|page
```

The optional per-file fields are page size, codec, codec level and diff strategy (`auto | logical | page | replace`). `pack_id` must stay the same across versions of a pack; `pack_version` must increase, and `diff-pack` refuses two packs with the same version.

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

### Applying DiffPacks from C

`vfs_patch_*` runs a patch on a background thread and exposes progress by polling; there are no callbacks.

```c
vfs_patch_options_t opts = {0};
opts.struct_size = sizeof(opts);
opts.flags = VFS_PATCH_IN_MEMORY | VFS_PATCH_OPTIMIZE;
opts.threads = 4;
opts.verify = VFS_PATCH_VERIFY_TOUCHED;

const char* diffs[] = { "diffs/1-2", "diffs/2-3" };
vfs_patch_t patch = 0;
if (vfs_patch_begin("packs/base", NULL /* or an overlay dir */, diffs, 2, &opts, &patch) == VFS_OK) {
    vfs_patch_progress_t p = {0};
    p.struct_size = sizeof(p);
    while (vfs_patch_poll(patch, &p) == VFS_OK && p.state == VFS_PATCH_RUNNING) {
        vfs_patch_wait(patch, 100);   /* returns VFS_BUSY on timeout */
    }
    int rc = vfs_patch_end(patch);    /* VFS_OK, VFS_CANCELLED, or the failure status */
}
```

The target must not be mounted while it is patched in place. An interrupted patch (crash or `vfs_patch_cancel`) leaves a `PatchIntent` in the pack; running the same DiffPack chain again resumes idempotently, a different chain to the same version is refused with `VFS_PRECONDITION_FAILED` unless `VFS_PATCH_FORCE` is set.

## Standalone DB storage layer

`libdb` is not an internal-only VFS implementation detail. It is a standalone mmap-friendly key/value store with a `db_*` C ABI and no dependency on pack, path, volume, or file-entry types.

### What DB provides today

- Raw binary keys and values. The public ABI accepts `(const void* key, uint64_t key_size)`; keys are stored and rechecked on read, including hash-collision cases.
- Durable append-first data records, mmap-backed base/delta indexes, journaled updates, checkpointing, optimization, recovery, and verification.
- Batched writes and snapshot reads, plus `db_get_info` for runtime and file statistics.
- 64-bit opaque `db_handle_t` handles. `0` is invalid; APIs report status through return values, `db_last_status()`, and `db_last_error_message()`.
- A default stable 128-bit key hash, with an optional caller-supplied `db_context_t.hash_fn`.

`db_context_t.file_ops` supplies the existing versioned custom file backend, including positional IO and mapping capabilities. Readonly VFS Zig mounts propagate it through park/reopen; see [provider and runtime contracts](docs/vfs/runtime_reads.md). Missing capabilities return an explicit unsupported status.

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
