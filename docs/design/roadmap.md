# DB 实现路线图

本文是不带时间的实施路线。每个阶段都应该以可测试、可验证、可回滚为边界。

## 原则

- 先保证格式正确、恢复可靠，再追求空间回收和性能优化。
- 先实现 append-only，再实现 hole reuse。
- 先使用简单锁保证正确性，再替换为更细粒度或无锁结构。
- journal/recovery/verify 必须早做，不能最后补。
- C ABI 从可用 V1 开始保持兼容，后续只扩展不破坏。
- 所有跨平台 IO 都通过 platform 层，不在核心逻辑散落系统调用。

---

## Phase 0：基础设施与格式试验

目标：验证 Zig、文件 IO、record 格式、crc、基础工具链。

交付：

- Zig 工程结构。
- platform file IO 抽象。
- offset-based pread/pwrite 封装。
- Windows/POSIX 路径处理。
- 基础 crc/hash 工具。
- data record encode/decode。
- append-only data file。
- 简单命令行工具：create、put、get、dump-record。

验收：

- 能创建 data db。
- 能 append record。
- 能通过 key/offset 读取 record。
- 能检测 header/footer/crc 损坏。
- 跨平台结构体 size/alignment 有 comptime assert。

暂不做：

- mmap index。
- delta journal。
- checkpoint。
- free-list。

---

## Phase 1：Index V1 与基础 KV

目标：形成真正的 key -> value 数据库闭环。

交付：

- manifest.db 基础格式。
- index.db FileHeader。
- index superblock A/B。
- index RegionDirectory。
- index BaseIndex / DeltaGeneration region 容器。
- base bucket index builder。
- base lookup。
- delta hash table。
- delta journal append。
- get/put/delete。
- tombstone。
- key striped lock。
- 基础 C ABI。

验收：

- 创建空 DB。
- 批量导入数据生成 base index。
- runtime put/delete 进入 delta。
- lookup 顺序为 active_delta -> base。
- delete tombstone 能覆盖 base。
- C 调用 open/get/put/delete/close 可用。

暂不做：

- checkpoint merge。
- crash recovery replay 完整策略。
- allocator hole reuse。

---

## Phase 2：Journal Recovery 与 Verify

目标：崩溃后可恢复，损坏可检测。

交付：

- delta dirty/clean flag。
- journal replay。
- 半条 journal record 截断或忽略。
- record orphan 检测。
- index -> data record 校验。
- verify CLI。
- corruption/error code 体系。

验收：

- 人工截断 journal 后能恢复到最后完整 record。
- data 写完但 journal 未写的 record 不可见。
- journal 写完但 delta hash 未更新时，重启后可见。
- 修改 payload 后 verify 能报 checksum mismatch。
- 修改 index offset 后 verify 能报 dangling/corrupt reference。

暂不做：

- 自动修复所有 corruption。
- relocation。

---

## Phase 3：Checkpoint

目标：delta 可合并回 base，避免无限增长。

交付：

- RegionDirectory。
- 双 delta generation。
- freeze active delta。
- 创建新 active delta。
- base + frozen delta merge。
- new base region 写入。
- superblock 原子切换。
- old base/delta retired。
- reader epoch 保护旧 region。

验收：

- delta 达到阈值后可 checkpoint。
- checkpoint 期间新 put/delete 不阻塞或仅短暂停顿。
- checkpoint 后 lookup 结果不变。
- checkpoint 中途崩溃可回到 old base + delta。
- checkpoint 完成后 old delta 可回收。

暂不做：

- index.db region 空间复杂复用。
- partial checkpoint。

---

## Phase 4：Batch 与 Snapshot

目标：支持 editor 批量导入与 runtime 一致快照读取。

交付：

- batch begin/put/delete/commit/rollback。
- journal batch begin/commit。
- batch 原子发布到 delta hash。
- read snapshot / read epoch API。
- C ABI batch API。

验收：

- batch commit 前所有 key 不可见。
- batch commit 后所有 key 同时可见。
- batch 中途崩溃未 commit 不 replay。
- snapshot 期间 checkpoint 不破坏读取。

暂不做：

- 通用多事务隔离。
- 跨 DB 事务。

---

## Phase 5：Allocator V2

目标：从 append-only 演进为 append-first + hole reuse。

交付：

- size-class free-list。
- retired block list。
- oldest_reader_epoch。
- delayed reclaim。
- allocator checkpoint。
- dirty recovery 下的 quarantine。

验收：

- delete/overwrite 后 old block 不立即复用。
- reader epoch 结束后 old block 可进入 free-list。
- 新写入可以复用合适 hole。
- allocator checkpoint 后重启 free-list 正确。
- dirty recovery 不会误复用不确定空间。

暂不做：

- relocation。
- truncate。

---

## Phase 6：Relocation 与 Shrink

目标：降低碎片并支持安全缩容。

交付：

- live record 反查。
- relocation candidate selector。
- index logical CAS。
- relocation journal/恢复策略。
- tail free range tracking。
- resize lock。
- safe truncate。

验收：

- live record 可搬到 hole。
- relocation 与 put/delete 竞争时 CAS 失败可安全回收 new block。
- 尾部形成连续 free 后可 truncate。
- truncate 前崩溃和 truncate 后崩溃均可恢复。
- runtime 可配置关闭 relocation/truncate。

---

## Phase 7：底层 IO 与性能优化

目标：降低系统调用、cache 污染和写放大。

交付：

- pwritev/writev 合并写。
- journal group commit。
- data tail range 批量预分配。
- platform advise/fadvise/madvise。
- 大 value streaming get。
- 可选 direct/unbuffered IO。
- read cache 与 decompressed cache 接口边界。

验收：

- 小 value 批量写 syscall 数明显下降。
- Sync/Async/None durability 行为可测。
- 大 value 顺序读取不明显污染 index lookup。
- direct IO 配置不影响默认兼容性。

---

## Phase 8：工具链

目标：让格式可观测、可修复、可接入 editor pipeline。

交付：

- db_create。
- db_import。
- db_dump_index。
- db_dump_manifest。
- db_verify。
- db_recover。
- db_checkpoint。
- db_optimize。
- benchmark 工具。
- fuzz/corruption test。

验收：

- 可以离线构建 base index。
- 可以导出 key 列表与统计信息。
- 可以定位坏 record。
- 可以重放 journal。
- 可以模拟崩溃点并验证恢复。

---

## Phase 9：Runtime/Editor 集成

目标：接入引擎资产系统。

交付：

- editor import 写入接口。
- runtime mount/open 接口。
- asset registry 特殊 key。
- directory tree 特殊 key。
- patch/mod overlay 策略。
- runtime config presets。
- editor config presets。

验收：

- editor 可批量 import。
- runtime 可只读 mount。
- runtime 可按配置写 cache/patch。
- patch/mod 覆盖顺序清晰。
- asset registry 可快速加载。

---

## Phase 10：高级能力

目标：提升大规模资产库和复杂发布场景能力。

候选能力：

- multi-generation delta。
- partial checkpoint。
- 按 asset type 分 data db。
- load group locality optimize。
- 压缩策略按类型配置。
- 加密/签名。
- 多进程只读 mount。
- 在线 verify。
- 热更新 manifest 原子切换。
- console/mobile 特定 IO backend。

这些能力应在核心格式稳定后逐个引入。

---

## 永久测试矩阵

每个阶段都需要维护以下测试：

- 正常 get/put/delete。
- 重复 overwrite。
- delete tombstone 覆盖 base。
- 大小 value 混合。
- journal 截断。
- data record 截断。
- footer 损坏。
- crc 损坏。
- checkpoint 中途崩溃。
- recovery 后 verify。
- 并发 get/put/delete。
- snapshot 与 checkpoint 并发。
- Windows/POSIX 文件路径。
- 大文件 offset 超过 4GB。
- C ABI 调用与内存释放。
