# VFS improvement progress

## Stage 1: capacity and offline build publication (2026-10-08)

### Implemented

- DB commit reservation covers both the delta's 70% slot limit and journal space for the entire batch, including begin/commit records. A large explicit batch remains one atomic batch.
- When reservation needs room, checkpoint committed records into a durable base before activating a correctly sized empty delta. Prepare/map the replacement before activation; replace mappings without a fallible old-delta close. Serialize replacement with commits and protect concurrent lookups.
- Keep VFS object layout and DB format unchanged. No larger fixed default and no VFS-specific logic in the DB.
- Build into an exclusively created sibling `<output>.vfs-build/stage`, close and verify it, then publish. Remove the destructive pre-build deletion in both direct and config-driven builds.
- Existing destinations must be valid pack directories. Files, symlinks, unrelated directories, root/current-directory aliases and occupied transaction paths fail closed. A transaction directory is never silently reused.
- Config-build cache refresh is best-effort after publication; `cache_write_failed` is returned/reported separately, so an optional cache I/O failure never reports the committed pack as a failed build.
- A failed publication rename restores the previous pack. If restoration itself fails, preserve the transaction and previous pack for recovery. Cleanup failure after successful publication leaves recoverable debris rather than falsely reporting a failed build.
- `vfs recover-build <pack_dir>` recovers an interrupted offline build only after the builder has stopped. It verifies an ownership marker and valid pack candidates, restores a moved-aside previous generation when output is absent, retains a completed new generation, and refuses ambiguous states. An empty leftover transaction directory can be removed explicitly even if final cleanup already removed its marker; nonempty unowned directories remain untouched.

### Operational contract

Standalone directory replacement is an **offline** operation: stop readers/writers while replacing or recovering a pack. Portable two-rename replacement has an interval where the destination name is absent; it is not a live atomic switch. For live multi-pack changes, build immutable generation paths and use the existing `volume/staging.zig` transaction/manifest layer. That layer was intentionally not repurposed to change the standalone pack layout.

Recovery handles process interruption and normal filesystem errors. This stage does not promise power-loss durability for directory renames on every filesystem. DB fsync failure after writing a superblock remains an ambiguous I/O outcome requiring close/reopen; a full poisoned-handle policy is future work. Index region descriptors are not reclaimed by this change. The builder still holds source and encoded pages in memory.

### Verification

Toolchain: official Zig 0.16.0, Linux x86_64; `ZIG_GLOBAL_CACHE_DIR=/tmp/vfs-review-tools/global-cache`.

- Test-first full ReleaseSafe run: all 149 existing Zig tests passed; the three new fresh/replacement capacity and failure-preservation regressions failed, reproducing the defects.
- Targeted final DB suite: 44/44 passed. Includes small initial capacity, queued and 1,001-operation explicit batches, journal-only exhaustion, delete rollover, dirty recovery, reopen, and concurrent reader/writer capacity transitions.
- Publication regressions cover fresh/replacement 1,024-page packs, invalid writer configuration and injected post-close build failure retaining old output, injected second-rename failure rollback, interruption between renames, completed-publication cleanup recovery, and rejected unrelated destinations/transaction directories.
- Final full ReleaseSafe suite: 158/158 Zig tests passed (44 DB, 113 VFS, 1 roundtrip). The only failing step is the unchanged C-ABI missing-DiffPack assertion at tests/vfs_cabi_smoke.c:116. ReleaseSafe build passed all 18 steps.
- Actual CLI reproduction: tiny pack replaced by a 64 MiB / 1,024-page file, plus a fresh 64 MiB pack. Both verify-pack runs reported zero issues; extraction and full-byte `cmp` passed.

Commands:

```sh
ZIG=/tmp/vfs-review-tools/zig-x86_64-linux-0.16.0/zig
export ZIG_GLOBAL_CACHE_DIR=/tmp/vfs-review-tools/global-cache
$ZIG build -Doptimize=ReleaseSafe --summary all
$ZIG build test -Doptimize=ReleaseSafe --summary all
# Private temporary directory; tiny existing pack -> 64 MiB replacement,
# plus fresh 64 MiB build, verify-pack, extract-file, and cmp of every byte.
```

### Next stages

The pre-existing Debug CRC inline-assembly `q` constraint failure and C-ABI missing-DiffPack smoke assertion remain untouched. Address those next; do not treat the full suite as green until the C smoke passes.

### Stage 1 review follow-up: current-directory aliases

Independent review identified that absolute/normalized spellings of the current directory bypassed the literal `.` / `..` guard. Publication now rejects both normalized equality with canonical cwd and existing aliases through symlinked parents, before creating any transaction directory. Cleanup scope is unchanged.

The new alias regression failed before the fix. Focused ReleaseSafe verification passed all 14 selected tests, including both alias regressions, every publication recovery test, and representative pack-builder tests. `git diff --check` passed. The symlink test is skipped on Windows, where creating symlinks can require additional privileges.

```sh
printf 'pub const enable_abi_exports = false;\n' > /tmp/vfs-stage1-db-options.zig
ZIG_GLOBAL_CACHE_DIR=/tmp/vfs-review-tools/global-cache \
  /tmp/vfs-review-tools/zig-x86_64-linux-0.16.0/zig test \
  -O ReleaseSafe -I include --dep db_internal -Mroot=src/vfs/root.zig \
  -O ReleaseSafe --dep db_build_options -Mdb_internal=src/db/internal.zig \
  -Mdb_build_options=/tmp/vfs-stage1-db-options.zig \
  --test-filter 'pack builder' --test-filter 'publication'
```

## Stage 2: C ABI contracts and retained lifetimes (2026-10-08)

### Implemented

- Preserve existing ABI symbols, status values and struct prefixes. Stat output rejects sizes below the four-byte header, preserves `struct_size`, and copies only the advertised prefix up to the known structure size. Patch progress keeps its eight-byte minimum; caller tails are untouched. Add Zig and C canary coverage, including partial fields and newer/larger caller buffers.
- Replace pointer-derived handles with namespace-tagged monotonic opaque IDs. IDs are never reused within a library instance, including allocation failure or address reuse. Cross-kind IDs fail validation. Each acquisition owns a per-object lease; the short registry lock protects admission only, never I/O, object destruction, join or wait.
- Volume and DB close return BUSY without invalidating the handle while operations or dependent objects retain them. Files retain their volume. DB batches and snapshots retain their DB, including its hash/context used by snapshot byte-key reads. File close, batch commit/rollback, snapshot end and patch end invalidate public IDs atomically and drain only that object's admitted operations. Batch mutation is serialized per batch. Existing DB close-error behavior still consumes the handle on an I/O error.
- Fix the C smoke ABRT before missing-DiffPack processing: C hosts use libc startup, but the library had selected Zig's raw Linux thread backend, whose TLS descriptor was not initialized by C startup. Compile C-facing library roots with libc/pthread support. The ordinary missing-DiffPack and successful-patch smoke now runs against both static and shared libraries, using independent fixtures.
- Preserve u64 pack identities throughout runtime mounts, file/page source state and cache keys. Keep the on-disk PageRef's existing u32 representation unchanged. A source ID that cannot fit is not truncated: the incremental writer copies the new payload instead of reusing a foreign ref. High-ID destinations use the existing implicit-page encoding. Writes/deletes retain the actual pack ID rather than resetting it to 1. FileEntry64 identity is unchanged.
- Read-only requests pin only their current page source. An unused overlay/top store is released before base fallback or foreign-page access, so a strict `max_open_stores=1` works. Writable mounts retain their existing request-wide generation guard. Peer store contention sleeps on a separate notification mutex/epoch; releases never need the volume mutation lock and cannot lose a wake between a failed admission attempt and waiting.

### Lifetime and mutation contract

Close invalidates a file/job ID before draining existing leases; newly arriving operations fail with INVALID_ARGUMENT. Closing a file can block until an admitted read finishes. Future asynchronous jobs must release retained file/volume leases at terminal completion, not wait for a later request-end call, to avoid same-thread close-before-end deadlock. No async API or new callback API is introduced here.

Read-only concurrent reads and handle close/open coordination are covered here. This stage does **not** claim safe concurrent in-place mutation. A historical direct-writer cycle remains for stage 3 admission work: `FileHandle.readAt` retains writable mount W, then `pinStoreMounted`/`pinMounted` may need `Volume.lock` to open a parked foreign source; `writeFileByEntry` / `writeFileByPath` / `deleteEntry` can hold that lock and call `refreshWritableMount` → `drainPinsLocked(W)`. Stop reads before those direct mutation calls until shared/exclusive update admission covers them. An admission rule only for patch jobs would not resolve those direct writer paths. Offline directory replacement still requires stopped readers/writers as documented in stage 1.

The internal Zig ownership contract still requires callers to close their own FileHandle/Volume/DB values in order; retained-ID protection applies at the public C ABI boundary. Caller-provided DB hash/context storage must outlive every dependent and successful DB close. Loading multiple independent copies of the library does not make their handles interchangeable.

### Verification

Toolchain: official Zig 0.16.0, Linux x86_64, ReleaseSafe; `ZIG_GLOBAL_CACHE_DIR=/tmp/vfs-review-tools/global-cache`.

- Test-first: the new stat-prefix regression failed against the prior implementation (undersized output was accepted); the existing C-host missing-DiffPack smoke still aborted. Independent ordinary C-host thread reproduction and symbolized stack confirmed the raw-thread TLS startup mismatch; the same library compiled with libc completed normally.
- Final full suite: **167/167 Zig tests passed** (47 DB, 119 VFS, 1 roundtrip), and **both static and shared C-ABI smoke executables passed**, all 30 build/test steps. Repeated the complete suite three additional times, all passing.
- Final ReleaseSafe build: **18/18 steps passed**. `zig fmt` was applied to changed Zig files; `git diff --check` passed.
- Added deterministic retained-close tests verify immediate stale-ID rejection, address reuse without ID reuse, cross-kind rejection, unrelated-object progress while another close drains, volume BUSY during a retained file read, and DB BUSY through batch/snapshot lifetimes including custom key hashing.
- Added/expanded tests cover bounded stat/progress prefixes with canaries, u64 IDs sharing low 32 bits, high-ID reads/writes/deletes without truncation, copying instead of unencodable foreign refs, one-store overlay fallbacks and read-only explicit foreign refs, and the nested writable/foreign pin notification lock ordering.
- Independent read-only review found a notification-lock cycle during implementation; the separate notifier/epoch design and deterministic regression corrected it. Subsequent review found no further new actionable regressions in this stage.

Not verified here: Windows/macOS/other architectures, sanitizer/race-detector runs, or live in-place writer/update admission. The pre-existing default Debug CRC inline-assembly `q` constraint failure remains deferred to stage 5. No push was made.

Commands:

```sh
ZIG=/tmp/vfs-review-tools/zig-x86_64-linux-0.16.0/zig
export ZIG_GLOBAL_CACHE_DIR=/tmp/vfs-review-tools/global-cache
$ZIG build test -Doptimize=ReleaseSafe --summary all
$ZIG build -Doptimize=ReleaseSafe --summary all
# Repeated the full test command three more times against the final code.
git diff --check
```
