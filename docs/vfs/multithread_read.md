> Implementation update (2026-10-08, stage 2): the historical analysis below
> predates retained opaque IDs. ABI lookups now acquire object-local leases;
> registry locks are never held across I/O or drain/join. Read-only stores pin
> only the current page source, so overlay/foreign reads work with a strict
> one-store budget. Writable mounts retain a request-wide generation pin.
> Store contention uses a condition variable instead of the old bounded spin.
> See `improvement_progress.md` for the current verified contracts.

# VFS 只读多线程并发读调研与实施

本文调研 `vfs_read_at` → `Volume/FileHandle` → `PageCache` → `PackReader` → `KvDb` → `DataFile` → 平台 IO 的完整读路径，量化每一层在多线程只读场景下的串行化点与冗余开销，并给出让"多线程读取整体速度随线程数扩展"的实现方案与分阶段路线。

调研基于实施前的仓库代码（Zig 0.16.0，Windows x64，32 逻辑核），数据来自 `zig build bench-read -Doptimize=ReleaseFast` 与一个 CRC 微基准。**§1–§10 保留为实施前的调研记录（其中的行号、锁结构描述均指旧代码）；§11 记录实际实施内容、验证与前后性能对比。**

---

## 0. 结论摘要

1. **物理文件读本身没有用户态锁**。`pf.pread` 直接走 `NtReadFile(offset)` / `pread(2)`，不共享文件游标，`Io.Threaded.global_single_threaded` 只是 syscall 适配器，不引入调度锁。
2. **但在 Windows 上同一 handle 的并发 pread 会被内核串行化**。Zig std 以 `FILE_SYNCHRONOUS_IO_NONALERT` 打开普通文件（`std/Io/Threaded.zig:5033`），同步 file object 的所有 I/O 在 I/O manager 内按 file object 加锁排队。要在 Windows 上真正并发，必须改为 overlapped/asynchronous 打开、每线程独立 handle，或对只读 pack 的 data 文件 mmap。
3. **冷读路径是 CPU-bound，不是 IO-bound**：单线程 64 KiB 页 miss 约 2.0 ms，其中约 2.3 ms 可由 7 次逐位 CRC32C（每次 326 µs）解释。目前"多线程有加速"只是把冗余 CRC 摊到多个核上。
4. **热读路径被 page cache 全局自旋锁完全串行化**：`copyFromEntry` 的 64 KiB memcpy（explicit-ref 页还包括 CRC + SHA-256）都在锁内执行，4 线程比 1 线程还慢（0.72x / 0.97x）。
5. **每页读要拿 8 次全局锁、发 10 次 pread、做 3 次 64 KiB 堆分配、拷贝 4 遍数据**；如果 pack 经过 `optimize()`（生产路径），每次 DB lookup 还会额外 mmap 整个 index 文件、O(N) 校验 base index 再 munmap。
6. 建议按 **A（去冗余/去全局锁，低风险）→ B（分片引用计数 cache + 原子 pin）→ C（单次 pread 直读 dst + 硬件 CRC + Windows overlapped/多 handle）→ D（miss 去重、预取、异步 API）** 分四阶段实施，A+B 即可让热路径接近线性扩展、冷路径提升一个数量级。

---

## 1. 调研范围与方法

- 范围：只读 volume（无 writable pack）下 `vfs_open_*` / `vfs_stat_*` / `vfs_read_at` 的多线程行为；写路径仅在影响读路径锁设计时提及。
- 方法：
  - 逐层阅读 `src/vfs/abi.zig`、`src/vfs/volume/volume.zig`、`src/vfs/io/file_handle.zig`、`src/vfs/io/page_cache.zig`、`src/vfs/pack/pack_reader.zig`、`src/db/kv_db.zig`、`src/db/index/{base_index,delta_index,index_file}.zig`、`src/db/data/data_file.zig`、`src/db/platform/file.zig`、`src/vfs/format/page_value.zig`、`src/vfs/compress/{registry,none}.zig`。
  - 阅读 Zig 0.16 std 中 `Io/Threaded.zig` 的 `fileReadPositional` / `dirOpenFileWtf16` / `fileMemoryMapCreate`，确认平台层真实行为。
  - 运行仓库现有基准 `tests/vfs_concurrent_read_bench.zig`。
  - 单独测量 `fmt.crc32c` 与 `std.hash.crc.Crc32Iscsi` 的吞吐。

---

## 2. 当前读流程全景

### 2.1 调用链

~~~text
vfs_read_at(file, offset, dst, size)                   src/vfs/abi.zig:146
  registry.validate(FileHandle)                        src/vfs/handle_registry.zig:24   [全局自旋锁]
  FileHandle.readAt                                    src/vfs/io/file_handle.zig:32
    for block in manifest.blocks:
      for page overlapping [offset, offset+size):
        volume.pinStore(pack_id, gen)                  src/vfs/volume/volume.zig:347    [Volume.lock 自旋锁, 线性查 mounts]
        page_cache.copyRange(...)                      src/vfs/io/page_cache.zig:46
          copyHit -> lock; findLocked(线性扫); copyFromEntry(memcpy [+crc+sha256]); unlock
          miss:
            noteMiss -> lock; unlock
            reader.readObjectAlloc(page_key)           src/vfs/pack/pack_reader.zig:89
              db.getSizeBytes(key)                     src/db/kv_db.zig:218
                commitPending -> pending_lock           src/db/kv_db.zig:384
                lookupInfoNoLock                       src/db/kv_db.zig:480
                  delta.lookup (只读: 无锁 mmap 读)      src/db/index/delta_index.zig:48
                  miss -> base_mod.open(index)          src/db/index/base_index.zig:171  [mmap 全文件 + verifyBytes O(N)]
                          base.lookup; base.close()     [munmap]
                readPayloadRawKey(整个 value 读入 tmp)   src/db/data/data_file.zig:495
              db.getIntoBytes(key, buf)                src/db/kv_db.zig:231
                (再次 commitPending / lookup / readPayloadRawKey)
            decodePageValue                            src/vfs/format/page_value.zig:61
            registry.decompressPage(.none) -> dupe     src/vfs/compress/none.zig:15
            lock; insertOwnedLocked(可能 evictOne 线性扫); copyFromEntry; unlock
        volume.unpinStore                              src/vfs/volume/volume.zig:355    [Volume.lock]
~~~

### 2.2 ABI 层（`src/vfs/abi.zig`, `src/vfs/handle_registry.zig`）

- 每次 `vfs_read_at` 都调用 `registry.validate`，它在一个进程级 `std.atomic.Mutex` 自旋锁下查 `AutoHashMapUnmanaged`（`handle_registry.zig:5-31`）。这是所有 volume、所有 file 共享的单点。
- `last_status` / `last_error` 是 `threadlocal`，无问题。

### 2.3 Volume / FileHandle（`volume.zig`, `file_handle.zig`）

- `Volume.lock` 是一个自旋锁（`volume.zig:540-542`），保护 `mounts`、`page_cache` 生命周期、pin 计数、store LRU。
- `FileHandle.readAt` 对**每一页**调用 `pinStore`/`unpinStore`（`file_handle.zig:75-76`），各拿一次 `Volume.lock`，并在锁内线性扫描 `mounts`（`findMountedPackContainingGeneration` → `findMountedPackById`）。
- `pinMountedLocked` 在 store 已 ready 时是 O(1)+计数；未 ready 时触发 LRU park/ensureReady（`volume.zig:375-386`）。
- `MountedPack` 是 `ArrayList(MountedPack)` 的值元素；`mountPackWithPriorityLocked` 会 `append` + `std.mem.sort`（`volume.zig:89-96`），元素地址不稳定，因此 `FileHandle` 目前只能持 `pack_id`，无法缓存 `*MountedPack`。
- `open_file_count` 是原子的，`vfs_close_volume` 用它拒绝关闭仍有打开文件的 volume。

### 2.4 Page cache（`page_cache.zig`）

- 单个 `std.atomic.Mutex` 自旋锁 + `ArrayList(Entry)` 线性表 + 全局 `clock` 做 LRU（`page_cache.zig:30-36`）。
- **命中路径**：`copyHit` 在锁内 `findLocked` 线性扫描所有 entry，再 `copyFromEntry` 把最多一页（64 KiB）memcpy 到用户 buffer；若是 explicit page ref（writable pack 写出的文件），还会在锁内对整页做 `crc32c` 和 `contentHash`(SHA-256)（`page_cache.zig:153-162`）。
- **未命中路径**：DB 读 + 解码 + 解压在锁外（好），但随后 `insertOwnedLocked` 可能在锁内做 O(N) `evictOne`，然后再次在锁内 memcpy 到用户 buffer。
- 没有 in-flight 去重：多个线程同时 miss 同一页会各自读盘、各自解码，最后只保留一份（`page_cache.zig:71-78` 的二次查找只是丢弃重复结果）。
- `stats` 非原子。

### 2.5 PackReader → KvDb（`pack_reader.zig`, `kv_db.zig`）

- `readObjectFromDb` 分两步：`getSizeBytes` 再 `getIntoBytes`（`pack_reader.zig:95-102`）。
- `getSizeBytes` 为了核对 raw key，把**整个 value 读入临时 buffer 并完整校验**（`kv_db.zig:223-227`），随后 `getIntoBytes` 再读一次。即每页 payload 从 OS 读两遍、DB 层 CRC 四遍。
- 每个 `get*` 先调 `commitPending`，它无条件拿 `pending_lock`（`kv_db.zig:384-390`）。只读模式下 `pending` 永远为空，这把锁纯属浪费，但它是所有读线程共享的一个 cache line。
- `requireRead` 读非原子 `parked`（`kv_db.zig:507-510`），`park()` 在 `park_lock` 下写它；正确性依赖 Volume 的 pin 计数保证 park 时无 reader（`lruIdleReadonlyLocked` 只选 `pin_count == 0`）。
- `lookupInfoNoLock`（`kv_db.zig:480-493`）：
  - 只读模式下 `delta.lookup` 走 `lookupNoLock`，直接读只读 mmap slot，**无锁**（`delta_index.zig:48-51, 297-303`）。
  - delta 未命中则 `base_mod.open(self.index)`：`pf.mmapReadonly` 映射**整个 index 文件**，`readHeader`，然后 `verifyBytes` 遍历**全部 bucket 和 entry**（每个 bucket 校 CRC）（`base_index.zig:171-185, 211-236`），做一次二分查找，再 `munmap`。每次 DB get 都会重复这一整套。
- 哪条索引路径会被命中取决于 pack 是否 `optimize()` 过：
  - `pack_builder.createPack` 只 `commitPending`，所有对象留在 delta；delta 默认 1024 slot、70% 上限（`delta_index.zig:85-87`, `kv_db.zig:92`），按代码推断超过约 716 个对象的 pack 会在 `close()` 时报 `NeedCheckpoint`。
  - `mutation_executor.optimizePack`（build cfg / merge / patch 路径）会 `optimize()`，把全部对象搬进 base index，delta 清空。**生产 pack 每次 get 都会走 `base_mod.open` 的 mmap+O(N) verify+munmap 路径**。现有基准只覆盖了 delta 常驻的情况，低估了生产成本。

### 2.6 DataFile 记录读取（`data_file.zig`）

`dataReadPayloadRawKeyMaybe`（`data_file.zig:495-509`）对一条记录：

~~~text
pread header (64 B)                       readAndValidateHeaderHandle   crc32c(64 B)
pread stored key (key_size, VFS=8 B)      堆分配 stored_key
pread payload (stored_size)               直接进 dst
verifyPayloadAndFooter:
  crc32c(payload)                         [64 KiB pass]
  pread key 再次 (堆分配 key_bytes)
  pread footer (8 B)
  crcRecord(header + key + payload + magic)  [64 KiB pass]
~~~

即每条记录 5 次 pread、2 次小堆分配、2 次整页 CRC。记录在文件中是连续的 `[header][key][payload][footer][pad]`，而 `IndexInfo.stored_size` 与调用方 `key_bytes.len` 在读之前都已知，完全可以一次 pread 读完。

### 2.7 平台 IO（`platform/file.zig`, Zig std）

- `pf.pread`/`preadAll` → `File.readPositional(io, ..., offset)` → `Threaded.fileReadPositional`（`std/Io/Threaded.zig:9881`）。Windows 走 `NtReadFile(handle, ..., &offset)`，POSIX 走 `preadv`。**用户态无锁、无共享游标**，注释所述正确。
- `pf.openIn` 忽略 `random_access_hint` / `sequential_hint` / `direct_io`（`file.zig:183-185`），`pf.advise` 是空实现（`file.zig:333-340`）。
- Windows 打开方式：`dirOpenFileWtf16` 使用 `.IO = .SYNCHRONOUS_NONALERT`（`follow_symlinks` 默认 true，`std/Io/Threaded.zig:5033`），返回的 `File.flags.nonblocking = false`。**同步 file object 上，Windows I/O manager 会在 NtReadFile 期间持有 file object 锁**（它需要维护 CurrentByteOffset），因此同一 handle 上的并发 pread 在内核中排队。POSIX 上 `pread` 对同一 fd 完全并发。
- `mmapReadonly` 在 Windows 上是 `NtCreateSection + NtMapViewOfSection`，`munmap` 是 `NtUnmapViewOfSection + CloseHandle`（`Threaded.zig:18007-18046, 18206-18231`）；这些是进程地址空间级操作，多线程同时做会在内核 VM 锁上竞争。
- DB 在只读模式下仍以 `.read_write` 打开 `data_000.db` 与 `index.db`（`data_file.zig:203`, `index_file.zig:175`），`loadAndMaybeRepair` 甚至可能写 superblock。这与"只读"语义不符，也阻止在只读介质上打开 pack；属于顺带发现。

---

## 3. 单页读取成本剖析（64 KiB 页、codec none、非 explicit-ref）

### 3.1 Miss 路径

| 步骤 | 位置 | 共享锁 | syscall | 堆分配 | 整页 CRC |
| --- | --- | --- | --- | --- | --- |
| registry.validate | abi.zig:150 | registry 全局自旋 | | | |
| pinStore | volume.zig:347 | Volume.lock | | | |
| copyHit | page_cache.zig:96 | PageCache.lock | | | |
| noteMiss | page_cache.zig:109 | PageCache.lock | | | |
| getSizeBytes | kv_db.zig:218 | pending_lock | 5 pread (+base: mmap/munmap ≈4) | tmp 64K, 8, 8 | 2 |
| getIntoBytes | kv_db.zig:231 | pending_lock | 5 pread (+base ≈4) | page_bytes 64K, 8, 8 | 2 |
| decodePageValue | page_value.zig:61 | | | | 2 (stored_crc, raw_crc) |
| decompressPage(none) | none.zig:15 | | | raw 64K (dupe) | 1 |
| insert + copy | page_cache.zig:69-81 | PageCache.lock | | | |
| unpinStore | volume.zig:355 | Volume.lock | | | |
| **合计** | | **8 次 / 5 把全局锁** | **10 pread (+8 VM)** | **3×64K + 4 小** | **7 次 ≈ 2.3 ms** |

数据搬运：kernel→tmp、kernel→page_bytes、page_bytes→raw、raw→dst，一页拷 4 遍。

### 3.2 Hit 路径

registry(1) + pinStore(1) + copyHit(1, 锁内线性扫 + 64 KiB memcpy) + unpinStore(1) = **4 次全局锁**，其中一次锁内持有大拷贝。explicit-ref 页额外在锁内做 1 次 CRC32C（326 µs）+ 1 次 SHA-256（约 150-300 µs），即**每次 cache 命中都重算摘要**。

---

## 4. 基准数据与解读

### 4.1 `zig build bench-read -Doptimize=ReleaseFast`（4 × 8 MiB 文件，64 KiB 页，pack 未 optimize，delta 常驻）

~~~text
== disjoint cold (WS 32 MiB, cache 8 MiB, eviction pressure) ==
  1 thread(s): 1069.9 ms   59.8 MiB/s  1.00x  hits=512  misses=512  evict=384
  2 thread(s): 1071.6 ms   59.7 MiB/s  1.00x  hits=0    misses=1024 evict=896
  4 thread(s):  544.5 ms  117.5 MiB/s  1.96x  hits=0    misses=1024 evict=896

== disjoint cold (WS 32 MiB, cache 64 MiB, no eviction) ==
  1 thread(s): 1046.9 ms   30.6 MiB/s  1.00x  misses=512
  2 thread(s):  540.7 ms   59.2 MiB/s  1.94x  misses=512
  4 thread(s):  287.5 ms  111.3 MiB/s  3.64x  misses=512

== disjoint warm (WS 32 MiB, cache 64 MiB, memcpy/lock) ==
  1 thread(s): 5.4 ms  23885.9 MiB/s  1.00x  hits=2048
  2 thread(s): 5.2 ms  24575.7 MiB/s  1.03x  hits=2048
  4 thread(s): 7.5 ms  17136.1 MiB/s  0.72x  hits=2048

== same file random warm (cache hits, lock contention) ==
  1 thread(s): 24.5 ms  670069 pages/s  1.00x
  2 thread(s): 22.2 ms  738690 pages/s  1.10x
  4 thread(s): 25.2 ms  649970 pages/s  0.97x
~~~

### 4.2 CRC 微基准（64 KiB，ReleaseFast）

~~~text
fmt.crc32c (逐位)            : 326.1 us/page   0.20 GB/s
std.hash.crc.Crc32Iscsi (查表): 98.0 us/page   0.67 GB/s   (结果一致)
~~~

### 4.3 解读

1. **冷读单线程 30.6 MiB/s ≈ 2.04 ms/页**。7 次逐位 CRC ≈ 2.28 ms，与观测值吻合；10 次 pread（OS cache 命中，约 10-20 µs/次）与 3 次 64 KiB 分配是次要项。**冷路径是 CPU-bound**。
2. 冷读 4 线程 3.64x，看起来扩展良好，但那只是 CRC 被分摊到多个核；一旦 CRC 修好，Windows 同步 handle 的内核串行化和 5 把全局锁会成为新的天花板。
3. "eviction pressure" 场景 2 线程 1.00x 是基准口径问题：1 线程时 8 MiB cache 恰好装下一个文件，第二遍全部命中（hits=512）；2 线程互相驱逐，misses 翻倍。按 miss 数算实际是 2x。建议基准按实际 miss 字节数报吞吐。
4. **热读 4 线程反而变慢（0.72x、0.97x）**。热路径没有 IO、没有 CRC，只剩锁：Volume.lock ×2 + PageCache.lock ×1（锁内 memcpy + 线性扫描）。这是"多线程读整体速度"目前最直接的失败点。
5. 基准直接调 `Volume.openEntry` / `FileHandle.readAt`，**未经过 C ABI 的 `registry.validate`**，真实 C 调用方还多一把全局锁。
6. 基准 pack 未 `optimize()`，**未覆盖 base index 的 per-lookup mmap+verify 路径**；对生产 pack，该路径每 get 增加约 4 次 VM syscall 和 O(对象数) 的校验循环，且多线程在 VM 锁上竞争。

---

## 5. 并发瓶颈清单（按严重度）

| # | 层 | 问题 | 影响 | 位置 |
| --- | --- | --- | --- | --- |
| B1 | Page cache | 全局自旋锁内做 memcpy / CRC / SHA-256，线性表查找与驱逐 | 热路径完全串行，多线程负扩展 | page_cache.zig:96-107, 115-120, 137-162 |
| B2 | DB / 校验 | 逐位 CRC32C，每页 7 遍 | 冷路径 CPU-bound，~2 ms/页 | format.zig:140-151; data_file.zig:596-606; page_value.zig:83,89; none.zig:17 |
| B3 | 平台 | Windows 以同步 file object 打开，内核按 handle 串行化 pread | Windows 上单 pack 数据读无法真正并发 | std Threaded.zig:5033; file.zig:180-202 |
| B4 | DB | 每次 lookup 未命中 delta 就 mmap 整个 index + O(N) verify + munmap | 生产 pack 每 get 数十 µs～ms 级额外成本，VM 锁竞争 | kv_db.zig:486-492; base_index.zig:171-185 |
| B5 | DB | `getSizeBytes` 读并校验整个 value；VFS 先 size 后 into 读两遍 | pread、分配、CRC 各翻倍 | kv_db.zig:218-229; pack_reader.zig:95-102 |
| B6 | Volume | 每页 `pinStore`/`unpinStore` 各拿一次 Volume.lock 并线性扫 mounts | 每页 2 次全局锁 | file_handle.zig:75-76; volume.zig:347-360 |
| B7 | ABI | `registry.validate` 全局自旋锁 | 每次 read_at 1 次全局锁 | handle_registry.zig:24-31 |
| B8 | DB | 只读模式仍在每次 get 拿 `pending_lock` | 每页 2 次全局锁 | kv_db.zig:384-390 |
| B9 | DataFile | 每条记录 5 次 pread、2 次小分配，记录连续却分片读 | syscall 数 5x | data_file.zig:495-509, 596-606 |
| B10 | 全局 | 所有锁都是 `tryLock + spinLoopHint` 纯自旋 | 高核数下 CPU 空转、尾延迟放大 | volume.zig:540; page_cache.zig:173; kv_db.zig:645; handle_registry.zig:8 |
| B11 | Page cache | 无 in-flight 去重 | 同页并发 miss 重复读盘/解码 | page_cache.zig:62-79 |
| B12 | Page cache / codec | none codec 仍 `dupe` 一份；每页 3 次 64 KiB 堆分配 | 分配器压力与额外拷贝 | none.zig:18; kv_db.zig:224; pack_reader.zig:98 |
| B13 | DB | `parked` 非原子读写 | 数据竞争（依赖上层 pin 保证不出错） | kv_db.zig:67, 145-147, 507 |

---

## 6. 目标：什么算"真实的并发读"

以只读 volume 为前提，定义三条路径的目标形态：

~~~text
热路径 (cache hit)
  - 0 次全局锁；仅 1 次分片锁，且锁内不做 memcpy/CRC
  - O(1) 查找
  - 扩展性 ≈ 内存带宽；8 线程 ≥ 6x

冷路径 (OS page cache 命中)
  - 1 次索引查找（无 syscall、无锁）
  - 1~2 次 pread（header+key 与 payload；或整条记录一次）
  - 1 次硬件/查表 CRC
  - 0 次 64 KiB 堆分配（直读 dst 或线程本地 scratch）
  - 扩展性 ≈ OS page cache 拷贝带宽；Windows 需 overlapped/多 handle 才能成立

冷路径 (磁盘)
  - 与上同，扩展性 ≈ 设备队列深度；N 线程 = N 个 outstanding IO
~~~

只读 store 的关键性质：文件内容与索引在 open 期间不变。因此 base index 可以映射一次终身复用，delta 为空或只读，`pending` 永远为空，所有写向锁在读路径上都可以短路。

---

## 7. 方案设计

### 7.1 DB 层（`kv_db.zig` / `base_index.zig` / `data_file.zig` / `platform/file.zig`）

**D1. 只读快路径短路 `commitPending`。**
`mode == .read_only` 时 `getSize*/getInto*` 不调 `commitPending`（`put/delete` 已被 `requireWrite` 拒绝，`pending` 必空）。读写模式保持原逻辑。去掉 B8。

**D2. 缓存 `BaseIndex` 于 `KvDb`。**
新增字段 `base: ?base_mod.BaseIndex`，在 `openIn` 打开并**只 verify 一次**，`closeFiles` 时关闭。`lookupInfoNoLock` 直接用 `self.base.?.lookup(key)`，变成纯内存读、无 syscall、无锁。读写模式下 `checkpoint/optimize` 重建 base 后需在 `maintenance_lock` 内替换并处理正在读的线程（可先用 RwLock；长期用 epoch 延迟 munmap）。去掉 B4。

**D3. 单次 pread 读整条记录。**
新增 `readRecordInto(info: IndexInfo, key, key_bytes, dst) !usize`：记录总长 = `64 + key_bytes.len + info.stored_size + 8`，从 `info.offset` 一次 pread 到线程本地 scratch（或 `dst` 前预留 header 空间），在内存中校验 header、key、footer 并拷出 payload。5 次 pread → 1 次，小分配 → 0。若要零拷贝进 `dst`，可拆成 2 次 pread（header+key 到栈，payload 直入 dst，footer 到栈）。去掉 B9、大部分 B12。

**D4. `getSizeBytes` 不读 payload。**
只读 `header + key_bytes.len` 字节校对 key，返回 `raw_size`。同时给 VFS 提供 `lookupBytes(key_bytes) !IndexInfo`，让 VFS 一次 lookup 后直接按 `raw_size` 分配/直读，彻底去掉 size+into 双读。去掉 B5。

**D5. CRC32C 提速与去冗余。**
- 立即：`fmt.crc32c` 改为 `std.hash.crc.Crc32Iscsi`（结果一致，3.3x）。
- 进一步：x86-64 SSE4.2 `crc32q` / AArch64 `crc32cx` 硬件指令（~10-20 GB/s），运行时按 `std.Target` 特性选择。
- 校验契约收敛为**每层各一遍**：DB 层用 `record_crc` 覆盖 header+key+payload（去掉单独的 `payload_crc` 整页 pass，或反之）；VFS `decodePageValue` 对 codec none 只校 `raw_crc`（`stored_crc == raw_crc`）；`none.decompressPage` 不再重复校验也不再 `dupe`。7 遍 → 2 遍；配合硬件 CRC，每页 CRC 成本从 ~2.3 ms 降到 ~10 µs 级。
- 提供 `OpenOptions.verify_payload` 让离线 `verify-pack` 已校验过的只读 pack 可选择跳过 DB 层 payload CRC（保留 header/footer 校验以防错位）。

**D6. `parked` 原子化。**
`parked: std.atomic.Value(bool)`，`isParked` 用 acquire 读；配合 V1 的两阶段 pin 协议保证 park 与 reader 互斥。去掉 B13。

**D7. Windows 并发 IO（去掉 B3）。**三选一，可组合：
- W1（首选）：`pf.openIn` 在 Windows 上直接 `NtCreateFile(.IO = .ASYNCHRONOUS)` 并返回 `File{ .flags = .{ .nonblocking = true } }`，`readPositional` 会走 std 现有的 APC 等待路径（`Threaded.zig:9901-9930`）。同一 handle 并发 `NtReadFile(offset)` 不再被 file object 锁串行。
- W2（兜底、跨平台）：只读 store 持一个小 handle 池（如 4-8 个），reader 按线程 id 取用。实现最简单，代价是 handle 数 × `max_open_stores`。
- W3（实验）：只读 pack 的 `data_*.db` 整体 `mmapReadonly`，`readRecordInto` 变 memcpy。规避 syscall 与 handle 锁；`db_arch.md` 对 data 文件不 mmap 的顾虑（truncate/relocation/写序）在只读不可变 pack 上不成立，但需评估大 pack 的 page fault 与地址空间成本，作为 opt-in。
- POSIX 上补 `posix_fadvise(RANDOM)`、base index 映射 `MADV_RANDOM`。

### 7.2 Volume / Store pin（`volume.zig`, `file_handle.zig`）

**V1. 原子 pin 计数 + 两阶段 park。**
`MountedPack.pin_count: std.atomic.Value(u32)`，`ready: std.atomic.Value(bool)`。快路径：`pin_count.fetchAdd(1, .acquire)`，检查 `ready`，成立即返回，不碰 `Volume.lock`。慢路径（未 ready）：拿 `Volume.lock` 做 ensureReady / LRU park。park 时先在锁内 `cmpxchg(pin_count, 0 → PARKING_SENTINEL)` 阻止新 pin，成功后再 `reader.park()`。去掉 B6 的锁。

**V2. `MountedPack` 改为堆节点，地址稳定。**
`mounts: ArrayList(*MountedPack)`，节点只在 `Volume.close` 释放。`FileHandle` 在 `openEntry` 时解析并持有自己 pack 的 `*MountedPack`，`readAt` 不再按 `pack_id` 线性查找；只有 explicit page ref 指向其它 pack 时才查 mount 表。

**V3. mount 表读多写少 → RwLock 或不可变快照。**
第一步用 `std.Thread.RwLock`，读侧共享。第二步 `mounts` 变为原子交换的不可变切片（mount/unmount 时 copy-on-write），reader `load(.acquire)` 即可，旧切片延迟释放（mount 极少，可到 `Volume.close` 再释放）。

**V4. 每次 `readAt` 对自己的 pack 只 pin 一次**，而不是每页一次；foreign ref 才按页 pin。

**V5. 只读 volume 标志。**
`Volume.read_only = (writable_path.len == 0)`；`refreshWritableMount`/写路径保持粗锁不变，读路径以此标志启用上述快路径，避免影响写语义。

### 7.3 Page cache（`page_cache.zig`）

**C1. 分片。** `shards: [64]Shard`，`Shard = { lock: std.Thread.Mutex, map: AutoHashMap(PageCacheKey, *Entry), lru: 双向链表或 CLOCK }`，按 `hash(PageCacheKey) % 64` 选片。查找 O(1)，锁竞争降 64 倍。

**C2. 引用计数出锁。** `Entry.refs: std.atomic.Value(u32)`。命中：分片锁内查到 → `refs += 1` → 解锁 → 在锁外 memcpy/校验 → `refs -= 1`。驱逐只选 `refs == 0` 的 entry；若被驱逐时仍有引用，标记 `evicted`，最后一个 unref 负责 free。锁内不再有大拷贝，去掉 B1。

**C3. explicit-ref 校验只做一次。** `Entry.verified_crc/verified_hash` 标记；加载时校验，命中时不再算 SHA-256/CRC。

**C4. 预算与 LRU 分片化。** 每片 `budget/64`，或全局 `used_bytes` 原子 + 各片独立驱逐；`clock` 改为每片或用 CLOCK 位近似 LRU；`stats` 改原子。

**C5. miss 去重。** 分片内插入 `loading` 占位 entry（含 `std.Thread.ResetEvent`），后来的同页 miss 等待而不重复读盘。去掉 B11。可放到 Phase D。

**C6. 大读绕过 cache 直读 dst。** 当读请求覆盖整页、或调用方以 flag 指明 streaming（复用现有被忽略的 `vfs_open_*` `flags` 参数，如 `VFS_OPEN_NO_CACHE`），走 D3 的 `readRecordInto` 把 payload 直接写进用户 buffer，跳过 cache 插入。整文件加载这种引擎最常见模式将变成 0 分配、1~2 次 pread、1 次 CRC。

**C7. 线程本地 scratch。** 页解码用 `threadlocal` 可增长 buffer 替代 3 次 `smp_allocator` 分配。

### 7.4 ABI / handle registry（`abi.zig`, `handle_registry.zig`）

**A1.** `handle_registry` 的锁改 `std.Thread.RwLock`，`validate` 走共享读；或分片（按 handle 低位）。
**A2.** 长期：`FileHandle`/`Volume` 首字段放 magic + generation，`vfs_read_at` 以指针标记快速校验，registry 只在 open/close 维护（防 use-after-free 仍靠 registry 的 close 路径）。去掉 B7。

### 7.5 锁原语（B10）

所有 `lockMutex` 纯自旋替换为 `std.Thread.Mutex`（Windows SRW / futex，竞争时挂起）；读多写少处用 `std.Thread.RwLock`。真正短临界区（原子计数）直接用原子操作。高核数机器上纯自旋在慢路径（含 syscall 的 ensureReady、evictOne）会灾难性放大。

### 7.6 与写路径的边界

- 写路径（`writeFile*`、`deleteEntry`、`refreshWritableMount`）继续在 `Volume.lock` 独占下执行，并把 `read_only` 快路径关掉（或以 RwLock 写侧独占）。
- `refreshWritableMount` 目前在不检查 `pin_count` 的情况下 `close()` 并重开 writable reader（`volume.zig:416-424`），与仍持 pin 的 reader 存在竞争；引入 V1 后应在 `pin_count == 0` 或等待 drain 后再切换。属于写路径修正，本文只标注。

---

## 8. 实施路线

| 阶段 | 内容 | 预期效果 | 风险 |
| --- | --- | --- | --- |
| **A 去冗余、去全局锁**（低风险） | D1、D2、D4、D5（查表 CRC + 7→2 遍）、A1、7.5 锁替换、基准修正（§9） | 冷读单线程 30 MiB/s → 数百 MiB/s 至 GB/s 级（转为 IO/拷贝 bound）；生产 pack 消除 per-get mmap；热读仍受 cache 锁限制 | 校验契约变更需更新 `verify-pack` 与损坏注入测试 |
| **B 分片 cache + 原子 pin**（中） | C1-C4、V1-V5 | 热读随线程近线性扩展（目标 8 线程 ≥ 6x），每页全局锁 8 → 0 | pin/park 协议、entry 生命周期需并发测试 |
| **C 直读 + 硬件 CRC + Windows 并发 IO**（中） | D3、C6、C7、硬件 CRC、D7(W1 或 W2) | 冷读每页 ≈ 1-2 pread + 1 硬件 CRC + 0 分配；Windows 单 pack 并发读成立 | Windows overlapped 路径依赖 std 内部行为，需 fallback 到 W2 |
| **D 去重、预取、异步** | C5、`pf.advise` 落地、可选 batch/async read API | 同页并发 miss 不重复；大文件顺序读吞吐提升 | 属增强 |

A 和 B 合起来即可满足"只读情况下多线程读取整体速度随线程数提升"的核心目标。

---

## 9. 验证方法

### 9.1 基准扩展（`tests/vfs_concurrent_read_bench.zig`）

1. 线程数扩到 1/2/4/8/16/32；按实际 miss 字节数报吞吐，修正 eviction 场景口径。
2. 增加 "optimized pack" 场景：`createPack` 后调 `KvDb.optimize()`，覆盖 base index 路径。
3. 增加 explicit-ref 场景（writable pack 写出后只读挂载），暴露命中时 SHA-256。
4. 增加 C ABI 路径（`vfs_open_path/vfs_read_at`），包含 `registry.validate`。
5. 增加 "streaming 整文件读" 场景，用于 C6。
6. 输出每页 syscall 数（可用 `strace -c` / Windows ETW 抽样）与分配次数作为回归指标。

### 9.2 正确性

- 现有并发测试：`vfs abi concurrent read_at on one volume`、`volume concurrent readers share one pack store`、`platform concurrent pread shares one file handle`、`volume parks idle readonly stores under max_open_stores`。
- 新增：`max_open_stores = 1`、M 个 pack、N 线程随机读，验证 park/pin 两阶段协议；cache entry 在驱逐与并发读交叠时无 use-after-free；mount 表快照在并发 mount + read 下无悬垂。
- Linux 下以 `-fsanitize-thread` 构建跑并发测试；Windows 下用 Application Verifier 检查 handle 使用。
- 损坏注入测试（`vfs rejects corrupted manifest page identity and checksums`）在 D5 收敛校验层次后必须仍全部通过。

### 9.3 目标指标（建议）

~~~text
热读  disjoint warm     8 线程 ≥ 6x（相对 1 线程），1 线程 ≥ 10 GiB/s
热读  same-file random  4 线程 ≥ 3x
冷读  OS cache 命中     1 线程 ≥ 1 GiB/s；Windows 4 线程 ≥ 3x（需 D7）
冷读  每页 syscall ≤ 2，64 KiB 堆分配 = 0，整页 CRC ≤ 1
~~~

---

## 10. 附录：关键代码位置索引

~~~text
ABI 入口 / 注册表         src/vfs/abi.zig:146-156, src/vfs/handle_registry.zig:5-31
FileHandle.readAt         src/vfs/io/file_handle.zig:32-104
Volume pin / park / LRU   src/vfs/volume/volume.zig:347-414, 520-533
Page cache                src/vfs/io/page_cache.zig:30-175
PackReader 读对象         src/vfs/pack/pack_reader.zig:89-102
KvDb get / lookup         src/db/kv_db.zig:204-237, 384-390, 480-510
Base index open/lookup    src/db/index/base_index.zig:51-94, 171-185, 211-236
Delta index lookup        src/db/index/delta_index.zig:48-51, 234-256, 297-307
DataFile 记录读取         src/db/data/data_file.zig:495-509, 547-606, 631-634
平台 IO / mmap            src/db/platform/file.zig:164-253, 342-395
CRC32C                    src/db/format.zig:140-151, src/vfs/format/common.zig
PageValue 解码            src/vfs/format/page_value.zig:61-107
none codec                src/vfs/compress/none.zig:15-19
Zig std Windows 打开/读   std/Io/Threaded.zig:4999-5036, 9881-9930, 18007-18046
现有并发基准              tests/vfs_concurrent_read_bench.zig, build.zig:110-122 (bench-read)
~~~

---

## 11. 实施记录与性能对比

§7 方案已按 A → B → C（含 D 的 miss 去重）一次性落地。本节记录实际改动、验证方式和前后对比。所有数字来自同一台机器（Windows x64，32 逻辑核，SSE4.2）、`ReleaseFast`、OS page cache 已热，因此衡量的是 VFS 自身开销与扩展性，而非磁盘。

### 11.1 实际改动清单

| 方案项 | 实现 | 文件 |
| --- | --- | --- |
| D5 CRC | 新增共享 CRC32C 实现：x86-64 `crc32q/crc32b`、AArch64 `crc32cx/crc32cb`、便携 slicing-by-8 回退；提供 `update/finish/hashContinue` 增量接口；bitwise 参考实现保留用于测试 | `src/db/crc32c.zig`, `src/db/format.zig`, `src/vfs/format/common.zig` |
| D5 去冗余 | `decodePageValue` 对 payload 只算一遍（同时校 `stored_crc` 与 `raw_crc`）；`none.decompressPage` 不再重复校验；DB 单次读路径只校 `record_crc`（已覆盖 header+key+payload+footer） | `page_value.zig`, `compress/none.zig`, `data_file.zig` |
| D3 单次 pread | `DataFile.readRecordBorrow`：按索引已知长度一次 `pread` 整条记录进线程本地 scratch，内存中校验 header/key/footer/record_crc，返回借用切片；`readMetaCheckKey` 只读 header+key | `data_file.zig` |
| D4 | `KvDb.lookupBytes` / `getBorrowedBytes`；`getSizeBytes` 不再读 payload；`getIntoBytes` 走 borrow + memcpy | `kv_db.zig` |
| D1 | `prepareRead`：只读模式跳过 `commitPending` 与 `pending_lock` | `kv_db.zig` |
| D2 | `KvDb.base` 在 open 时映射并校验一次，`lookupInfo` 直接查内存；`checkpoint/optimize` 后 `refreshBase`；只读模式无锁，读写模式 `base_lock` RwLock | `kv_db.zig` |
| D6 | `parked: atomic.Value(bool)`；`park` 先发布 parked 再关文件 | `kv_db.zig` |
| D7 (W2) | `DataFile.read_handles` 句柄池（默认 4，`MAX_READ_HANDLES=16`），按线程 slot 选择；只读模式以 `.read_only` 打开且不再回写 superblock | `data_file.zig`, `kv_db.zig`, `pack_reader.zig` |
| C1–C5 | PageCache 重写：64 分片 + `HashMap` + 每片双向 LRU；entry 引用计数，memcpy/校验在锁外；`loading` 占位 + Condition 实现 miss 去重（`coalesced` 统计）；explicit-ref crc/hash 只在加载时校验一次；全局原子 `total_bytes` + 低水位（budget−1/8）批量回收 | `io/page_cache.zig` |
| C6 | `VFS_OPEN_STREAMING` 打开标志：整页读取绕过 cache 直接解码进用户 buffer（`readThrough`），常驻页仍从 cache 命中 | `file_handle.zig`, `page_cache.zig`, `abi.zig`, `include/vfs.h` |
| C7 | DB 层线程本地 record scratch 替代每页 3 次 64 KiB 堆分配 | `data_file.zig` |
| V1 | `MountedPack.pin_count` 原子；`pinFast` 无锁；`PIN_PARKING` 哨兵实现两阶段 park；`refreshWritableMount` 先 `drainPinsLocked` 再换 reader | `volume.zig` |
| V2 | `MountedPack` 改为堆节点（`ArrayList(*MountedPack)`），`FileHandle.mounted` 缓存指针 | `volume.zig`, `file_handle.zig` |
| V3 | mount 表以不可变 `MountList` 原子发布（`published`），读侧完全无锁；旧列表 retire 到 `close` 释放 | `volume.zig` |
| V4 | `readAt` 对自身 pack 每次调用只 pin 一次；foreign ref 才按页 pin | `file_handle.zig` |
| A1 | VFS/DB 两个 handle registry 改 RwLock，`validate` 共享读 | `handle_registry.zig`, `kv_db.zig` |
| 7.5 锁原语 | 新增 `platform/sync.zig`：基于 `std.Io.Mutex/RwLock/Condition` 的阻塞锁（短自旋后 futex 挂起）；替换 Volume/KvDb/PageCache/DataFile 的纯自旋锁 | `src/db/platform/sync.zig` 及各处 |
| ABI | `vfs_open_options_t` 的两个 reserved 字段启用为 `page_cache_bytes`、`read_handles`；`vfs_open_*` 校验未知 flag | `abi.zig`, `include/vfs.h` |

该次实施时未做：Windows overlapped 打开（W1）、data 文件 mmap（W3）、`pf.advise` 落地、异步 API。后续阶段 6 已补充 polling 异步/批量读取、显式预取、优先级/取消与运行时预算；当前契约见 [runtime_reads.md](runtime_reads.md)。W2 句柄池已达到 W1 的目标（见 11.3），W1 依赖 std 内部行为，留作后续。

### 11.2 验证

- 单元/集成测试：`zig build test` 共 105 个（DB 39、VFS 65、roundtrip 1），Debug 连续 5 轮、ReleaseSafe、ReleaseFast 全部通过。
- 新增测试：
  - `crc32c.zig`：硬件 / slicing-by-8 / bitwise 三实现在 0..1024 所有长度与 9 种对齐下逐一相等；增量与一次性结果一致。
  - `data_file.zig`：`readRecordBorrow` 对错误 key（hi/lo、长度、内容）、错误 `stored_size`、payload 位翻转、footer magic 破坏分别返回 NotFound / Corruption / ChecksumMismatch；句柄池共享同一内容。
  - `page_cache.zig`：预算驱逐与代际隔离；真实 pack 上 miss→hit、部分范围、越界、加载失败不留毒化 entry；**8 线程 × 2000 次随机页/随机范围 + 16 页预算的持续驱逐**下数据逐字节正确、`hits+misses+coalesced` 精确守恒。
  - `volume.zig`：**`max_open_stores=1`、6 个 pack、8 线程随机读**，逐轮触发 park/unpark，验证两阶段 pin 协议、无悬垂、结束时所有 `pin_count == 0`。
  - `abi.zig`：`VFS_OPEN_STREAMING` 整文件读常驻 0 页、非对齐读经 cache 且精确；未知 flag 返回 `VFS_INVALID_ARGUMENT`。
  - `sync.zig`：Mutex/RwLock 跨线程互斥。
- 既有损坏注入测试（manifest/page identity/checksum、page_ref 篡改）在校验层次收敛后全部仍通过。
- `zig fmt --check` 对所有改动文件通过。

### 11.3 性能对比（`zig build bench-read -Doptimize=ReleaseFast`）

基准口径变更：文件 8 MiB → 4 MiB × 8（总 WS 仍 32 MiB / 512 页；旧口径下 8 个 8 MiB 文件会超过未 `optimize()` 的 pack 的 delta 容量并报 `NeedCheckpoint`——即 §2.5 预测的问题）；线程数扩到 1/2/4/8；按实际 miss 数报 miss 路径吞吐；新增 optimized pack、explicit refs、C ABI、streaming、句柄池敏感度场景。

**冷读（miss 路径，delta pack，cache 128 MiB 无驱逐）**

| 线程 | 之前 | 之后 | 单页 miss 成本 |
| --- | --- | --- | --- |
| 1 | 30.6 MiB/s（2.04 ms/页） | 1525 MiB/s | 41 µs/页（**~50x**） |
| 2 | 59.2 MiB/s | 2592 MiB/s | 24 µs |
| 4 | 111.3 MiB/s | 3918 MiB/s | 16 µs |
| 8 | – | 4736 MiB/s（3.1x） | 13 µs |

**冷读 + `VFS_OPEN_STREAMING`（整文件加载，cache 1 MiB）**

| 线程 | 之后 | 单页 |
| --- | --- | --- |
| 1 | 2686 MiB/s | 23 µs |
| 8 | 10524 MiB/s（3.9x） | 5.9 µs |

同场景不带 streaming（每页仍插入 cache 并驱逐）为 1336 → 4130 MiB/s，可见整文件加载时 cache 插入/驱逐本身占了约一半成本。

**Windows 句柄池敏感度（streaming，cold）**——直接验证 §0 第 2 点的内核串行化结论：

| read_handles | 1 线程 | 4 线程 | 8 线程 |
| --- | --- | --- | --- |
| 0（单 handle） | 2600 MiB/s | 4100 MiB/s（1.58x） | 3856 MiB/s（1.48x） |
| 1 | 2451 | 3956（1.61x） | 3457（1.41x） |
| 4（默认） | 2533 | 7096（2.80x） | 9509（3.75x） |
| 8 | 2693 | 7342（2.73x） | 9368（3.48x） |

单 handle 时 2 线程后完全停止扩展；4 个 handle 即可解除，8 个无进一步收益。

**热读（cache 命中）**

| 场景 | 之前 | 之后 |
| --- | --- | --- |
| disjoint warm 1 线程 | 23.9 GiB/s | 38.5 GiB/s |
| disjoint warm 4 线程 | 16.7 GiB/s（**0.72x**） | 116 GiB/s（3.0x） |
| disjoint warm 8 线程 | – | 172 GiB/s（4.5x） |
| same-file random 1 线程 | 670 K 页/s | 805 K 页/s |
| same-file random 4 线程 | 650 K 页/s（**0.97x**） | 2.77 M 页/s（3.4x） |
| same-file random 8 线程 | – | 4.55 M 页/s（5.7x） |
| explicit refs warm 8 线程 | （每次命中重算 CRC+SHA-256） | 113 GiB/s（3.0x，仅加载时校验） |
| C ABI `vfs_read_at` warm 8 线程 | – | 150 GiB/s（3.9x） |

**生产布局（optimized pack，base index）**

冷读 1 线程 1556 MiB/s、4 线程 3895 MiB/s，与 delta pack 持平——per-get 的 mmap+O(N) verify+munmap 已消除（之前基准未覆盖此路径，无直接旧数据；按 §2.5 分析，旧路径每 get 额外 4 次 VM syscall + 全索引校验）。

### 11.4 对照 §9.3 目标

| 目标 | 结果 |
| --- | --- |
| 热读 disjoint warm 8 线程 ≥ 6x，1 线程 ≥ 10 GiB/s | 4.5x（已达内存带宽区间：172 GiB/s 聚合）；1 线程 38 GiB/s ✅ |
| 热读 same-file random 4 线程 ≥ 3x | 3.4x ✅ |
| 冷读 OS cache 命中 1 线程 ≥ 1 GiB/s | 1.5 GiB/s（cache 路径）/ 2.6 GiB/s（streaming）✅ |
| Windows 4 线程 ≥ 3x | streaming 3.9x（8 线程）/ 2.8x（4 线程）；cache 路径 2.6x |
| 每页 syscall ≤ 2、64 KiB 堆分配 = 0、整页 CRC ≤ 1 | streaming 路径：1 pread、0 分配、DB 层 1 次 record_crc + VFS 层 1 次 payload crc（两层各一遍，硬件指令下合计约 6 µs）✅ |

热读 8 线程未到 6x 的原因是 4 MiB 文件 × 16 遍在 8 线程下只有约 3 ms 的运行时间，线程创建/join 与 memcpy 带宽饱和占主导；cache 路径的冷读 8 线程 3.1x 则受 cache 插入（`allocator.dupe` + 分片插入 + 回收）限制，对整文件加载应使用 `VFS_OPEN_STREAMING`。

### 11.5 后续可选项

- W1：Windows 以 `FILE_FLAG_OVERLAPPED` 打开单 handle 替代句柄池，减少句柄数 × store 数。
- `readThrough` 对 explicit-ref 页也支持直读（当前 explicit ref 走 cache 以复用校验结果）。
- 顺序读预取（沿 manifest 顺序预读下一页到 cache）。
- 写路径 `refreshWritableMount` 期间的读者目前通过 drain 等待，可改为双 reader 切换实现零等待。
