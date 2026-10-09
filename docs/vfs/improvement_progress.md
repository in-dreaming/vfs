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

## Stage 3: patch recovery and mounted update admission (2026-10-08)

### Implemented

- Persistent OS advisory `.vfs_patch.lock`: no unlink race, harmless unlocked leftovers, and automatic release after process death. Acquire before overlay initialization. This coordinates cooperating patchers; old exclusive-create binaries must be stopped rather than mixed with the new protocol.
- Additive callback-free `vfs_patch_begin_in_volume(volume, pack_id, ...)` retains the Volume through worker cleanup, acquires admission synchronously, derives paths from mounts, and parks both overlay and base. Terminal state is published only after update cleanup and Volume retain release. Existing offline path API and on-disk formats are unchanged.
- Small process-local canonical-path mount/admission registry reserves paths before reader open, refuses updates of multiply mounted paths, and blocks new aliases during an update. Ordinary symlink and normalized aliases are covered. Independent processes, raw DB readers, bind-mount aliases, and separately linked library instances remain the caller's offline responsibility.
- Conservatively reject live files/retained requests or pins with Busy. No force-closing or waiting under Volume.lock. All Volume read/open/stat/mutation admission is blocked during the update; successful release reopens metadata, advances cache generation, clears cached pages, and validates target objects plus target-manifest page references against mounted sources. This is not a whole-Volume content scan.
- Failed/cancelled updates whose intent commit was attempted stay recovery-required and unreadable; admission and job retains still release. Both partial and post-finalize failures can be retried. A version-equal no-op still validates before restoring reads. Mounting a pack with an unfinished intent starts in recovery-required state. An unhealthy overlay base cannot be used to resume its overlay.
- Direct writable APIs use the same nonblocking local admission and canonical target reservation. This removes the historical cycle where a writable request held its target pin while waiting for a parked foreign source and an updater waited for that pin under Volume.lock. Direct write errors are conservatively gated after the writer is opened/attempted; abort discards pending work, not already durable writes. Direct-write failure has no PatchIntent rollback protocol and requires offline inspection/repair before remount.
- Resume reconstructs the durable intent's exact diff IDs even if a cheaper candidate is newly available. Missing, duplicate, or discontinuous saved IDs fail closed. Explicit FORCE alone selects a fresh cheapest chain to the same requested final version; precondition checks still apply.
- ShardWriter ownership is explicit: error/would_block leave values with the caller; staged transfers ownership. A later commit error is sticky and surfaces through subsequent stage/drain. Pending/local staging arrays transfer ownership once, and byte accounting releases consumed failed batches.

### Verification and limits

- Normal regressions cover advisory lock conflict/reacquisition, stale filenames, overlay lock-before-initialization, allocator/write rejection ownership, saved-chain choice, live handle/pin Busy, base+overlay parking, canonical aliases, pre-write cancellation/failure release, partial/post-finalize recovery gating, wide pack IDs, foreign PageRefs, and direct writable foreign-source reads.
- `test-heavy` creates isolated random `/tmp/vfs-patch-process-*` roots and owns every child it terminates. Its matrix is 5 boundaries × in-place/overlay × 1/4 workers. A fresh child resumes and verifies object/visible-byte equivalence, deletion visibility and zero-work rerun; overlay base files are compared byte-for-byte. At a multiworker stop, other workers may progress before termination; one-worker cases provide precise intermediate boundaries.
- Initial full ReleaseSafe aggregate after the main implementation passed 178/178 Zig tests and both static/shared C ABI smoke programs (30/30 steps). Subsequent independent review corrections and expanded regressions require the final rerun recorded below.
- Independent review of patch lock, saved-chain recovery, staging ownership, and subprocess tests found no blockers. Admission review drove fixes for pre-admission probing, eviction under exclusive pins, recovery-state bypasses, post-finalize validation, full-width implicit identities, and unhealthy overlay bases.
- This verifies process interruption and normal tested failures, not power-loss safety. Windows runtime/OS handle behavior is unverified here. Existing underlying DB close/park errors and ambiguous fsync outcomes are not a comprehensive poisoned-handle or rollback solution. General allocation/error-path completeness, common task refactor, bounded hpatch memory, and later async/performance work remain out of scope.

Commands (official Zig 0.16.0, Linux x86_64):

```sh
ZIG=/tmp/vfs-review-tools/zig-x86_64-linux-0.16.0/zig
export ZIG_GLOBAL_CACHE_DIR=/tmp/vfs-review-tools/global-cache
$ZIG build test -Doptimize=ReleaseSafe -j2 --summary all
$ZIG build test-heavy -Doptimize=ReleaseSafe -j2 --summary all
$ZIG build -Doptimize=ReleaseSafe -j2 --summary all
```

### Final Stage 3 verification

Against the final product tree after all review fixes:

- Full ReleaseSafe aggregate: **178/178 Zig tests** (47 DB, 130 VFS, 1 roundtrip), **30/30 steps**, including static and shared C smoke exercising the additive mounted API.
- Three further cached full-suite runs passed **178/178**, including admission/read concurrency and both C smoke variants.
- Real process-death matrix: **20/20 cases**, **4/4 test-heavy steps**. Rebuilt the harness against the final tree; every interrupted child was owned by the harness and every resume was a fresh process.
- ReleaseSafe build: **18/18 steps**. `git diff --check` passed.
- Final independent admission/ABI and patch-recovery/harness reviews reported no remaining blockers in their respective reviewed scopes. No push performed.

## Stage 4: bounded construction and verified path-index views (2026-10-08)

### Implemented

- Replace whole-source/all-encoded-page retention with bounded windows: read source pages in order, update SHA256, encode through the existing task scheduler, queue encoded values, write through the existing shard-routing PackWriter, commit the window, and release it. A scheduler/worker pool is reused; each window destroys its graph and report. No page-count-sized task graph, dependency list, source allocation or output array remains.
- Reserve each admitted page's full lifetime against the existing resolved `Budget.mem_bytes`, including raw source, codec output/scratch and moving-realloc capacity, VPAG bytes, the DB-owned pending copy/key, and the aligned DB append buffer copy. Scheduler completion does not release the enclosing window reservation. Reject a page that cannot fit before allocating it; never silently exceed the configured payload budget for a giant page. Check codec and DB value-width limits.
- Make repeated scheduler-run retirement safe: workers signal their completion condition before releasing the run-state mutex, so no trailing signal can mutate a retired/reused stack frame. On dispatcher allocation/submission errors, stop admission and drain all actually submitted jobs without allocating before destroying RunState. Reserve completion/report storage before submission and roll back rejected submissions, preventing phantom completions and cleanup hangs. Existing task failure/continuation behavior is preserved.
- Derive the slot limit from existing worker count (at most twice `worker_threads`), so tiny pages cannot create arbitrarily many descriptors. Flush DB pending values after every page window and individual file manifest. Keep all writes private until close/verify/publish, preserving the stage 1 offline publication/recovery protocol.
- Stream planning hashes through a fixed 64 KiB buffer. Construction compares the actual written source size/hash against its plan before publication; no-op plans recheck the source snapshot. Short reads, growth or final length changes fail closed. Stream the pack content hash using the identical previous byte sequence.
- Config incremental behavior remains **whole-generation rebuild on any change**, with a no-op for unchanged inputs; this is not selective encoded-file reuse. Validate the complete input set (including removals), match cache entries by FileEntry64 rather than source path, and bind a no-op to actual published file-manifest hashes/content metadata/path mappings and pack identity. Report actual encode-task counts rather than estimates; empty files require no encode tasks.
- Retain immutable path-index bytes plus a verified view in PackReader. Validate once at open/mount, then resolve paths without repeated CRC/full-index scans. Public byte-oriented lookup wrappers still validate untrusted input. Validation now includes checked layout arithmetic, nonempty bounded strings, heads/links, stored-hash bucket membership, cycle detection and exact reachability in O(buckets + entries), without an extra visited allocation. Full-path comparison under hash collisions, valid forward links, FileEntry64, and format bytes remain unchanged. Stage 3 metadata replacement naturally rebuilds the view; parking preserves the owned bytes.

### Memory and source-stability contract

The limit is a **payload-pipeline working-set bound**, not a total process RSS limit. For raw page size `n`, VPAG value bound `V=n+104`, codec allocation bound `C`, admission conservatively reserves:

`n + C + 3*V + 95 + 8 + 4096` bytes.

The 95 covers DB record header/key/footer/alignment; the additional 8 covers the pending DB key. The 4096 is extra admission slack, not a proof that every descriptor allocation fits that amount. None codec has `C=n`. LZ4 has `C=2*(n+n/255+16)`, plus 262144 bytes of matcher heads for n>=13, plus 2*n chain bytes at positive compression levels. The double compressed capacity covers moving shrink realloc. For 64 KiB pages, reservations are 332191 bytes (none), 660417 bytes (LZ4 level 0), and 791489 bytes (LZ4 level 4). Raw fallback remains bounded by the source page size. Actual last-page length determines admission.

Scheduler/queue/report/DB descriptor capacities are separately bounded O(worker_threads), including capacities retained from the largest window. Fixed worker stacks, allocator overhead, mmap/address space and OS page cache are outside this payload accounting. The recorded window high water is reserved payload capacity, not aggregate allocator/RSS measurement; the codec regression separately measures actual peak requested allocations, including forced moving realloc.

Metadata is intentionally not constant-sized: file/path/cache metadata is O(files + path bytes), PackWriter collision identities and DB checkpoint/verification indexes are O(objects/pages). The path-index object is exactly `48 + 4*bucketCount(F) + 40*F + S` bytes (bucketCount is the power of two at least 2*F, or 1 for no files). Encoding/writing that singleton temporarily retains multiple metadata copies. Final verification also uses metadata-sized indexes and one record-sized payload. No external-memory index redesign, bounded whole-verifier RSS, parallel DB commit redesign, new I/O runtime, public callback, or format change is claimed.

Sources must remain stable during planning/build. Hash comparisons reject observed differences, including same-size changes between passes; they are not a filesystem snapshot or lock against arbitrary concurrent mutation. Direct createPack describes the bytes it actually read. Config builds bind cache facts to the matching planned/written bytes, and an observed mismatch leaves the prior published pack intact.

### Verification

Test-first regressions reproduced removed-input no-op invalidation, whole-file planning allocation under a 16 KiB metadata allocator, and CRC-valid invalid path links. Added coverage includes bounded source reads, size changes, page-count arithmetic, window/graph/report/pending high waters across growing inputs, none/LZ4 and multiple shards, complete decoded page comparisons, admission failure and failure after committed private windows, source/encoder allocation failures, published-manifest/cache binding, stale no-op plans, actual codec peak allocations, mount-time malformed-index rejection, and repeated verified lookups across park/reopen.

The existing semantic path-hash corruption fixture now flips a non-bucket hash bit: changing bucket membership is correctly rejected earlier as structural path-index corruption, while this fixture continues testing the separate path_hash_mismatch diagnostic.

A deliberately injected scheduler-allocation regression first observed an active worker after run returned, then crashed; it passes after nonallocating error drain was added. Repeated-run stress covers 1000 windows each with 1/4 workers, including task-error windows. One earlier overlapping aggregate invocation had an allocator fault in the capacity regression; its owned transaction was recovered through recover-build. Three clean serial suites subsequently passed before the additional scheduler fixes. The original allocator fault's precise cause is not proven; it is not dismissed as fixture interference. Final commands and results are recorded below after final-tree verification. Platform coverage remains Linux x86_64 ReleaseSafe; Debug CRC portability remains for stage 5.

### Final Stage 4 verification

Against the final product and stabilized test tree, strictly serial execution:

- Full ReleaseSafe aggregate passed **198/198 Zig tests** (47 DB, 150 VFS, 1 roundtrip), **30/30 steps**, including static and shared C smoke. Repeated three consecutive times after the final test-only change; all passed.
- Final `test-heavy`: **20/20 real process-death recovery cases**, **4/4 steps**. Final ReleaseSafe build: **18/18 steps**.
- Final CLI binaries: a tiny pack replaced by a 64 MiB / 1024-page source, and a fresh pack from that source. Both verify-pack runs reported **zero issues**; extraction plus full-byte `cmp` passed. Combined maximum RSS of the two builder children was **27428 KiB** on this host, an observation rather than a process-memory guarantee.
- Window regressions compare 8, 80 and 800 full pages plus a tail under a two-slot budget; actual graph/report/pending operation counts stay at two for none/LZ4. Payload-allocation failures cover partially encoded and previously committed private windows. Codec peak-allocation tests force moving realloc. Scheduler tests use a bounded failure-index sweep that tolerates worker-timing-dependent allocation counts while rejecting swallowed OOM, leaks and early return with active executors; this is not exhaustive allocation-path coverage.
- Independent read-only reviews of the bounded builder, verified index/lifetimes and final scheduler drain reported no remaining blockers. All changed Zig files were formatted; `git diff --check` passed. No push.

```sh
ZIG=/tmp/vfs-review-tools/zig-x86_64-linux-0.16.0/zig
export ZIG_GLOBAL_CACHE_DIR=/tmp/vfs-review-tools/global-cache
# Run sequentially; fixed historical test fixtures are not concurrency-safe.
$ZIG build test -Doptimize=ReleaseSafe -j2 --summary all  # three final runs
$ZIG build test-heavy -Doptimize=ReleaseSafe -j2 --summary all
$ZIG build -Doptimize=ReleaseSafe -j2 --summary all
# Isolated mktemp root: put-file tiny -> 64 MiB, fresh 64 MiB,
# verify-pack both, extract-file both, cmp all bytes.
git diff --check
```

Residual limits are the payload/metadata/source-stability/offline contracts above, non-exhaustive failure injection, no race-detector or cross-platform runtime validation, and the pre-existing Debug CRC portability issue deferred to stage 5. The earlier allocator fault's exact cause remains unproven; the independently demonstrated scheduler lifetime and allocation-unwind defects were fixed and the final serial gates passed.
