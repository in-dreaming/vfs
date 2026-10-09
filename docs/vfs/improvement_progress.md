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
