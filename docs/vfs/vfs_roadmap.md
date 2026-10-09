# VFS 实现路线图

本文是不带时间的实施路线。每个阶段都应该形成可测试、可验证、可回滚的边界。

---

## 原则

- VFS public 层只暴露 u64 FileEntry。
- vfs_open 必须同时支持 path 与 FileEntry。
- path open 通过 PathIndex 解析 FileEntry。
- entry open 直接用 FileEntry，不能依赖路径。
- DB key 使用 u64 object key。
- 任何 PageValue / FileManifest 读取都必须反向校验 identity，避免 u64 key 碰撞导致静默错读。
- 先实现只读单 pack，再实现 volume overlay。
- 先实现 whole-file rewrite，再实现 page-level copy-on-write。
- 先实现同步读写 API，再在内部加入 cache、prefetch、task graph。
- verify/recover 工具要早做，不要最后补。
- C ABI 从 V1 开始保持向后兼容，后续只扩展不破坏。

---

## Phase 0：基础结构与 ABI 骨架

目标：建立 VFS 库的工程边界，确保它和 DB 库独立。

交付：

- src/vfs/root.zig
- src/vfs/abi.zig
- src/vfs/error.zig
- src/vfs/handle_registry.zig
- include/vfs.h
- tools/vfs.zig
- build.zig 中新增 vfs static/shared library 和 vfs CLI。

API 骨架：

~~~c
vfs_open_volume
vfs_close_volume
vfs_mount_pack
vfs_open_path
vfs_open_entry
vfs_stat_path
vfs_stat_entry
vfs_read_at
vfs_close_file
vfs_last_status
vfs_last_error_message
~~~

验收：

- 能构建 libvfs。
- C smoke test 能创建/关闭 volume handle。
- invalid handle 不崩溃。
- vfs_open_path 与 vfs_open_entry 在未 mount pack 时返回明确错误。

暂不做：

- 真正 pack format。
- page 读取。
- overlay。
- writable pack。

---

## Phase 1：u64 object key 与基础格式

目标：确定 VFS 写入 DB 的 object key 规则和二进制 value 格式。

交付：

- object_key.zig
- format/page_value.zig
- format/file_manifest.zig
- format/pack_manifest.zig
- format/path_index.zig
- CRC/hash 工具封装。
- little-endian encode/decode。
- comptime size/alignment assert。

需要实现的 key：

~~~text
PACK_MANIFEST_KEY
PATH_INDEX_KEY
DIRECTORY_MANIFEST_KEY
file_manifest_key(file_entry)
page_key(file_entry, block_index, page_index)
~~~

需要实现的 value：

~~~text
PackManifest
PathIndex
FileManifest
PageValue
~~~

验收：

- 所有格式可以 encode -> decode -> equal。
- checksum/header_crc 能检测损坏。
- PageValue header identity 校验覆盖 file_entry/block/page。
- 构建时能检测 object key 重复。

暂不做：

- 压缩算法。
- 目录树完整合并。
- 多 pack overlay。

---

## Phase 2：PackBuilder 最小闭环

目标：把普通文件写入一个 pack DB。

交付：

- pack/pack_writer.zig
- build/pack_builder.zig
- none codec。
- file split 为 block/page。
- 写 PageValue。
- 写 FileManifest。
- 写 PathIndex。
- 写 PackManifest。
- CLI：
  - vfs create-pack
  - vfs put-file
  - vfs dump-pack

流程：

~~~text
input file
  -> choose FileEntry
  -> split block/page
  -> build PageValue
  -> db_put(page_key)
  -> build FileManifest
  -> db_put(file_manifest_key)
  -> update PathIndex
  -> update PackManifest
  -> db_commit
~~~

验收：

- 能创建包含单个文件的 pack。
- 能创建包含多个文件的 pack。
- 构建工具能检测 page_key/file_manifest_key 冲突。
- dump 工具能列出 FileEntry、path、file size、page count。

暂不做：

- Volume。
- MountTable。
- overlay。
- 压缩。

---

## Phase 3：单 pack 只读访问

目标：实现从单个 pack 读取文件。

交付：

- pack/pack_reader.zig
- volume/volume.zig 的最小单 pack 模式。
- volume/path_resolver.zig
- volume/entry_resolver.zig
- io/file_handle.zig
- io/read_plan.zig

关键流程：

~~~text
vfs_open_path
  -> normalize path
  -> PathIndex lookup
  -> FileEntry
  -> open_entry_common
  -> read FileManifest
  -> create file handle

vfs_open_entry
  -> FileEntry
  -> read FileManifest
  -> create file handle

vfs_read_at
  -> map range to pages
  -> db_get PageValue
  -> verify header/crc
  -> copy bytes
~~~

验收：

- vfs_open_path 能读回构建输入文件。
- vfs_open_entry 能读回同一个文件。
- vfs_read_at 支持任意 offset/size。
- 读超过 EOF 正确返回短读。
- 损坏 PageValue header/payload 时返回 checksum/corruption 错误。

暂不做：

- page cache。
- 多 pack。
- writable pack。

---

## Phase 4：Volume、MountTable 与 Overlay

目标：支持多个 pack 挂载与覆盖。

交付：

- volume/mount_table.zig
- volume/overlay_resolver.zig
- 多 pack EntryResolver。
- PathIndex overlay view。
- EntryTombstone。
- CLI：
  - vfs mount-test
  - vfs list-visible

解析规则：

~~~text
higher priority pack shadows lower priority pack
writable pack has highest priority by default
tombstone hides lower priority file
same priority order must be deterministic
~~~

验收：

- base pack + patch pack 中同 FileEntry 时，读取高优先级版本。
- 高优先级 tombstone 能隐藏低优先级文件。
- path open 与 entry open 对同一 FileEntry 的 overlay 结果一致。
- 同 priority 冲突要么稳定解析，要么返回配置错误。

暂不做：

- PathTombstone。
- redirect。
- explicit PageRef。

---

## Phase 5：Page Cache 与读性能基础

目标：减少重复 page 读取、解压和校验成本。

交付：

- io/page_cache.zig
- LRU 或 clock cache。
- cache memory budget。
- per-file sequential read hint。
- 简单 read-ahead。

Page cache key：

~~~text
pack_id
pack_generation
file_entry
block_index
page_index
~~~

验收：

- 重复读取同一 page 命中 cache。
- pack remount 或 generation 变化后不会读到旧 cache。
- cache 超预算会淘汰。
- 随机读与顺序读都保持正确。

暂不做：

- 异步 IO。
- 全局 task graph。
- 自适应预取。

---

## Phase 6：压缩框架

目标：让 PageValue 支持 codec。

交付：

- compress/compressor.zig
- compress/registry.zig
- none codec。
- lz4 codec。
- zstd codec。
- raw fallback。
- codec version/hash 记录。

流程：

~~~text
write page:
  raw page
  -> compressor
  -> if compressed larger and StoreRawIfLarger, store raw
  -> PageValueHeader records codec/flags/raw_size/stored_size

read page:
  PageValueHeader
  -> verify stored_crc
  -> decompress or raw copy
  -> verify raw_crc
~~~

验收：

- none/lz4/zstd roundtrip。
- 压缩后更大时 raw fallback 正确。
- codec 不支持时返回 VFS_UNSUPPORTED_FEATURE。
- codec 版本变化能触发 build cache 失效。

---

## Phase 7：Writable Out Pack

目标：支持运行时或 editor 写入覆盖层。

交付：

- writable pack open/create。
- pack/pack_writer.zig 增量更新。
- whole-file rewrite。
- EntryTombstone 写入。
- PathIndex / PackManifest 更新。
- volume commit。

写文件流程：

~~~text
resolve FileEntry
  -> split new file
  -> write pages to writable pack
  -> write new FileManifest
  -> update PackManifest
  -> update PathIndex if path changed/new
  -> commit
  -> refresh resolver
~~~

验收：

- 写入新 path 后可通过 path open。
- 写入已有 FileEntry 后覆盖低优先级版本。
- 删除 FileEntry 后低优先级版本不可见。
- commit 失败时 resolver 不发布半成品。

暂不做：

- page-level copy-on-write。
- 跨 pack 原子事务。

---

## Phase 8：Verify / Recover / Tooling

目标：把格式和索引一致性检查工具补齐。

交付：

- vfs verify-pack
- vfs verify-volume
- vfs dump-path-index
- vfs dump-file
- vfs extract-file
- vfs recover-pack

verify 内容：

~~~text
PackManifest checksum
PathIndex checksum
PathIndex path_hash + path bytes 一致
FileManifest checksum
FileManifest file_entry 与 key identity 一致
PageValue header identity 一致
PageValue stored_crc/raw_crc 一致
PackManifest file list 与实际 manifest 一致
Tombstone 记录合法
object key 无冲突
~~~

验收：

- 能检测 path index 损坏。
- 能检测 manifest 指向缺失 page。
- 能检测 page payload 损坏。
- 能检测 u64 object key collision。
- dump/extract 可用于人工排错。

---

## Phase 9：BuildCfg 与文件级增量

目标：支持从配置批量构建 pack。

交付：

- build/build_cfg.zig
- build/build_plan.zig
- build/build_cache.zig
- build/pack_builder.zig 批量模式。
- CLI：
  - vfs build
  - vfs rebuild-changed

BuildCacheEntry：

~~~text
file_entry
source_path
source_size
source_mtime
source_hash
build_cfg_hash
compressor_version_hash
output_manifest_hash
~~~

验收：

- source 未变化时跳过文件。
- compression/page_size/cfg 变化时重建文件。
- file_entry 变化时重建并更新 path index。
- 构建结果可被 runtime VFS 读取。

暂不做：

- page-level incremental。
- task graph。

---

## Phase 10：Merge / Patch（已被 Phase 15 取代）

> 本阶段的 whole-file PatchManifest 与 `mutation/*` 路径已在 Phase 15 中删除；
> 版本间更新统一走 DiffPack + patch（见 docs/vfs/diff_patch.md）。以下内容仅作历史记录。

目标：支持把 patch 描述转换成 pack mutation。

交付：

- mutation/mutation_plan.zig
- mutation/merge_planner.zig
- mutation/mutation_executor.zig
- PatchManifest 格式。
- 简单 PatchCoalescing。

统一模型：

~~~text
build_cfg -> BuildPlan -> PackMutationPlan
patch     -> MergePlan -> PackMutationPlan
~~~

PackMutationPlan 包含：

~~~text
AddFile
ModifyFile
DeleteFile
AddPage
ModifyPage
DeletePage
WriteManifest
UpdatePathIndex
UpdatePackManifest
~~~

验收：

- patch add/modify/delete 文件正确。
- 多个 patch 连续应用后最终可见结果正确。
- modify 后旧版本被 overlay 隐藏。
- 删除后低优先级版本不可见。

暂不做：

- 跨版本复杂 coalescing。
- page 复用。
- task graph scheduler。

---

## Phase 11：Page-level Incremental 与 Explicit PageRef

目标：减少大文件小修改的写入成本。

交付：

- explicit PageRef manifest 格式。
- page raw hash cache。
- page-level build cache。
- sparse overlay file manifest。
- copy-on-write page 写入。

流程：

~~~text
old manifest + new source
  -> compare page hashes
  -> changed page 写入 writable pack
  -> unchanged page 使用 PageRef 指向旧 page
  -> 写新 FileManifest
~~~

验收：

- 大文件修改少量 page 时只写变化 page。
- 读取 sparse manifest 能跨 pack 取 page。
- 旧 pack 不存在时，引用旧 page 的文件返回明确错误。
- verify 能检查 PageRef 指向合法。

---

## Phase 12：Task Graph 调度

目标：让 build/merge 在 IO、CPU、DB 写入、内存预算下高效执行。

交付：

- mutation/task_graph.zig
- resource budget。
- IO executor。
- CPU executor。
- DB executor。
- manifest/meta executor。
- 静态优先级调度。

资源：

~~~text
disk read tasks
disk write tasks
compress tasks
hash tasks
db write tasks
inflight memory bytes
pack exclusive lock
meta exclusive lock
~~~

验收：

- 构建大量文件时内存不会无限增长。
- DB 写入并发受控。
- 压缩任务能吃满配置的 CPU 预算。
- pack manifest 更新串行且正确。

暂不做：

- 自适应调度。
- critical path 全局优化。

---

## Phase 13：Volume 级原子提交

目标：支持跨多个 pack 的一致更新。

交付：

- staging pack generation。
- meta pack / volume manifest。
- volume transaction record。
- commit/rollback/recover。

流程：

~~~text
write pack staging
  -> verify staging
  -> mark pack staging ready
  -> update meta pack volume version
  -> commit volume
~~~

崩溃恢复：

~~~text
meta 未 commit:
  volume 仍指向旧版本。
  staging pack 可继续或清理。

meta 已 commit:
  volume 指向新版本。
  下次 open 必须能完整加载。
~~~

验收：

- 任意阶段模拟崩溃后 volume 不出现半新半旧可见状态。
- recover 能清理孤儿 staging。
- verify-volume 能检查 meta 与 pack generation 一致。

---

## Phase 14：高级优化

目标：提升大型项目、热更新和运行时场景性能。

候选项：

- PathIndex 分片加载。
- DirectoryManifest 分片加载。
- EntryResolver mmap-friendly 表。
- async read API。
- read-ahead 自适应。
- page cache 热度统计。
- content-addressed page 复用。
- collision bucket。
- in-memory merge file ops。
- hybrid pack writer。
- adaptive task scheduler。
- critical path priority。
- pack priority / scene priority。

这些功能不应该阻塞 V1。只有在基础格式、只读路径、overlay、writable pack、verify 都稳定后再进入。

---

## Phase 15：DiffPack 与 Patch（已完成）

目标：pack 版本 A → B 的差量分发与就地/overlay 应用，取代 Phase 10 的 whole-file patch。

设计：docs/vfs/diff_patch.md。

交付：

- DB：多 data shard（`data_NNN.db`）、按 shard pin 的 Batch、`InMemoryFileOps`。
- 压缩：per-page `lz4`；codec registry 带 `version_hash`。
- `hdiff/`：纯 Zig 的 HDiffPatch 子集（VHDF 格式），`diffAlloc` / `patchAlloc`。
- `task/`：通用任务图调度器（`cpu` / `cpu_codec` / `mem_bytes` / `db_write_shard` 资源，yield，trace）。
- `format/`：`DiffManifest`、`UnitTable`、`FileOpTable`、`PathDelta`、`Chunk`、`PagePlaceholder`、`PatchIntent`。
- `diff/`：`PackImage` 扫描、strategy ladder（logical / page / replace + ratio downgrade）、planner、engine、DiffPack writer。
- `patch/`：`DiffPackReader`（in-memory 或 disk）、chain 选择（Dijkstra by payload）、coalesce（per-page / composite block unit）、`OldView` 分层读、`ShardWriter`（per-shard batch，unit 原子 staging）、`patch_session`（intent → graph → drain → finalize → optimize）。
- Volume：overlay pack 挂载，页解析 overlay → base，placeholder 隐藏 base 页。
- 工具：`diff-pack` / `dump-diff` / `verify-diff` / `patch-pack` / `bench-patch`；`verify-pack` 识别 placeholder / intent / overlay。
- C ABI：`vfs_patch_begin / poll / wait / cancel / end`（后台线程 + 轮询，无 callback），新增状态 `VFS_CANCELLED` / `VFS_PRECONDITION_FAILED`。

验收（已由 `zig build test` 覆盖）：

- in-place：v1 →(d12)→ v2 →(d23)→ v3、v1 →(d12,d23)→ v3、v1 →(d13)→ v3 三条路径与直接构建的 v3 逐对象等价。
- overlay：只读 base v1 + overlay 读出 v2 / v3 内容；删除文件不可见；缩短文件末页被 placeholder 隐藏。
- 崩溃矩阵：intent 之后、任意 unit / file op 之后、finalize 之前中断，再次运行均收敛；不同链到同版本无 `--force` 拒绝。
- 前置校验：base content hash 不符 → `PreconditionFailed`；无可达链 → `NoPatchPath`。

暂不做：

- `zstd` codec。
- diff 构建的 C ABI（构建机工具，不进运行时 ABI）。
- 跨 pack_id 的 diff。

---

## Phase 16：恢复与运行时准入（部分完成）

迭代依据：`diff_patch_iteration.md`；实际交付与验证：`improvement_progress.md`。

- 已实现：OS advisory patch lock、真实 owned-child kill/restart 20-case matrix、保守 Volume update lease、canonical mounted-path 冲突检测、刷新 reader/cache generation、失败后 recovery-required、saved-chain resume、staging error ownership。
- additive `vfs_patch_begin_in_volume` 保持 callback-free ABI；已有 path API 明确 offline 约束；磁盘格式未改。
- direct writable APIs 遇 live handle/pin/source recovery conflict 返回 Busy，不在 Volume.lock 内等待 reader。
- 未完成：Windows runtime 验证、通用 DB I/O error poisoned-handle、后续 task/common 重构、bounded hpatch memory 与性能实验。不得将本阶段描述成关闭全部 P0/P1。

---

## 推荐最小发布边界

第一个可用版本建议包含：

~~~text
1. vfs.h 基础 ABI。
2. u64 FileEntry。
3. u64 DB object key。
4. PackManifest。
5. PathIndex。
6. FileManifest。
7. PageValue。
8. none codec。
9. 单 pack build。
10. 单 pack mount。
11. vfs_open_path。
12. vfs_open_entry。
13. vfs_read_at。
14. verify-pack。
~~~

这个边界足够小，但已经验证了 VFS 最核心的两条 open 路径和 page 读取闭环。


## 2026-10-08 runtime read extension

Polling asynchronous reads, ordered batches, explicit prefetch, queued priorities,
cooperative cancellation, bounded decoded payload/worker scratch, diagnostics and
readonly custom-provider propagation are implemented. See
[runtime read contracts](runtime_reads.md) for ownership, permanent configured
limits and supported provider scope. Adaptive readahead, native overlapped IO,
remote-provider SDKs and callback completion are not included.
