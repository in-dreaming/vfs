# Bounded runtime reads

The synchronous `vfs_read_at` remains available. Additive C functions submit
single reads, ordered one-file batches, and explicit prefetch to a lazy fixed
worker pool per volume. Completion is handle-based polling; no application
callback is introduced. See `include/vfs.h` for exact layouts and signatures.

## Ownership and results

- Submission copies options and range descriptors. The caller owns destination
  storage and must keep it valid, unmodified and properly synchronized until
  terminal poll/wait or `vfs_request_end` returns.
- Queued and running requests retain their file, which retains the volume.
  Closing a file invalidates its ID immediately and drains those requests.
  A volume with file dependencies still returns `VFS_BUSY` on close.
- Requests release their file dependency **before publishing terminal state**.
  An unreleased completed result does not keep its file open, block a mounted
  update, or prevent volume close. Results own a detached reference-counted
  admission ledger until `vfs_request_end`; there is no pointer-cast handle ABI.
- Batch ranges run in order, including overlapping destinations, and stop on
  first failure. Across separate requests the caller synchronizes shared
  destinations. A result left QUEUED after a terminal batch was unexecuted.
  An active range is RUNNING; its byte count is published when that range stops.
- EOF is a successful short read. Failure/cancellation preserves the reported
  valid prefix, but no guarantee is made about bytes outside that prefix.
- Poll returns the status of obtaining the snapshot; inspect `last_status` for
  the IO outcome. Wait returns `VFS_BUSY` on timeout and `VFS_OK` for any terminal
  outcome. End cancels unfinished work, drains writes, consumes the ID and
  returns `VFS_OK` for successful release. Inspect results before ending.
- Cancellation of a queued job removes it immediately. Running cancellation is
  cooperative between pages and admission retries. Backend calls, shared page
  loads and store availability waits may complete first; a last-page completion
  may win a late cancellation. No hard cancellation-latency promise is made.

## Scheduling and admission

`vfs_open_options_t` retains its old prefix and appends these zero-defaulted
settings: 4 workers (maximum 64), 256 retained requests, 256 ranges per request,
and 16 MiB DB record scratch per worker. Smaller old option structs retain the
same defaults. Queue capacity counts queued, running and completed-but-unended
results; release results promptly. Rejected admission returns `VFS_BUSY` and
creates no request or destination writes. A malformed descriptor fails the
whole submission before any work is queued.

Higher queued priority dispatches first; ties use FIFO submission order. The
scheduler does not preempt a running request, alter OS thread priorities,
guarantee deadlines, or prevent starvation under sustained higher priorities.
Default priority is zero for reads and minus one for prefetch.

Prefetch resolves the same overlay/foreign references and verifies the same
page identity, checksums and requested span as normal reads. It warms the same
coalescing decoded cache, even on a `VFS_OPEN_STREAMING` file, without a second
payload destination. Completion does not pin pages against subsequent eviction.
Batching amortizes submission overhead; it does not promise merged physical IO.

## Memory limits and pressure

The cache budget now charges decoded payload reservations **before allocation**,
including in-flight decoding, resident pages, invalidated pages still pinned,
and temporary decoded compressed pages on the streaming path. Peak charged
payload bytes cannot exceed the configured budget. Eviction skips pinned pages;
there is no memory-admission wait while holding a store pin.

Transient pin/in-flight contention is internal admission pressure, not a public
read failure. Both synchronous and asynchronous file reads release every store
and cache pin, retain their completed prefix, back off for 100 microseconds and
retry. Async cancellation is checked between these retries. This permits a
one-store budget with overlay fallbacks and foreign PageRefs without a
memory/store lock cycle.

A decoded page larger than the entire configured cache budget is a permanent
configured-limit failure (`VFS_RESOURCE_LIMIT`, value 14), including tiny cache
budgets. Increase the budget or choose an appropriate page size. Whole-page raw implicit-page
STREAMING reads bypass decoded allocations and can succeed without room for a
cached page; compressed streaming reads still need one decoded-page reservation.
Partial streaming reads, explicit PageRefs and explicit prefetch use the cache
normally. A DB
record larger than an async worker's scratch bound also reports
`VFS_RESOURCE_LIMIT`; the bound includes record header/key/payload/footer.
Scratch grows without a temporary old-plus-new allocation peak and is freed at
worker shutdown. Readonly DB reopen no longer scans/rebuilds the writable tail.

These are explicit payload/scratch bounds, **not a process RSS guarantee**.
Cache metadata, hash capacity, file manifests, DB indexes/mappings, backend-owned
storage, OS page cache and caller buffers are separate. Request descriptors and
results are bounded by the configured retained-count and per-request range
limits, and worker stacks/count are fixed. Ordinary caller-thread synchronous
DB scratch retains its historical behavior; the new per-worker scratch cap
applies to asynchronous read workers only.

## Diagnostics

`vfs_get_stats` returns a size-versioned, approximate concurrent sample of cache
hits/misses/coalescing/evictions, resident/charged/in-flight/pinned/retired payload
bytes, high water, request states/outcomes/capacity rejections, logical read/prefetch
bytes, open readonly stores and configured limits. Pinned bytes overlap other
cache categories; samples taken during mutation need not algebraically sum.
Worker scratch retention/high water is sampled at request boundaries, so active
allocations may be newer. Request and cache counters last for the volume, including admitted cache
invalidation after a mounted update. Logical decoded bytes
are not physical disk/network throughput. No trace callback or unbounded event
log is introduced.

## Readonly custom providers

The DB's existing `CustomFileOps`/`db_context_t.file_ops` backend is implemented.
VFS Zig `Volume.OpenOptions.file_ops` now propagates it through PackReader and
park/reopen. The public VFS C ABI does not add another callback vtable.

A custom volume also requires a nonzero, process-unique `provider_identity`.
Roots are opaque provider keys, not OS paths; no fake realpath canonicalization
is performed. Contexts aliasing the same provider namespace must share the same
identity token and exact root spelling. Aliases across distinct tokens, root
spellings, custom and native storage, other processes or direct DB access remain
the caller's responsibility. Provider storage must remain immutable while
mounted. Its callback context must outlive the volume, including parked stores
and queued requests. Callbacks must support concurrent readonly calls and keep
returned mappings valid until unmap. Native filesystem mounts retain their existing canonical
process-wide update admission.

Custom direct writes are rejected with PermissionDenied because no writable
mount exists; mounted update leases and writable-pack setup return Unsupported.
Legacy path-only patch APIs remain native-filesystem-only and cannot recognize
provider roots: do not pass opaque provider roots to them. This is a read-provider
seam, not a remote writer or patch SDK. The filesystem and existing in-memory backend are conformance targets.
Required existing callback fields remain present; readonly providers can return
Unsupported for write/set-size/sync. Readonly open uses open/read/get-size/mmap/
munmap and does not request writable mappings or sync. Short reads/writes are
looped with zero-progress/count checks. Missing mapping capability is explicit;
reopen never silently switches to filesystem IO. Dirty readonly delta journals
return Busy and require explicit writable recovery rather than mutating storage
as a side effect of reading. Native overlay patch resume performs that recovery
only for its writable overlay target while holding the patch advisory lock; it
does not recover or write its readonly base.

PackReader retains its owned path-index bytes and stage4 `VerifiedView` together;
backend propagation does not undo verify-once immutable path lookup.
