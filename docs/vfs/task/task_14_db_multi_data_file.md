# Task 14：DB 多 data file 与并行 Batch

## 1. 任务目标

让 libdb 一个 store 真实打开并读写 manifest 中登记的全部 `data_NNN.db`，写入可按 shard 分发，跨 shard 的 Batch 提交在 data append 阶段并行。这是 patch "每个数据 db 一条流水线" 的前置。

## 2. 必读上下文

- docs/vfs/diff_patch.md §2、§12.1
- src/db/kv_db.zig、src/db/batch_snapshot.zig、src/db/manifest.zig、src/db/data/data_file.zig、src/db/recovery_verify.zig、src/db/data/relocation.zig
- include/db.h

## 3. 硬性禁止

- 不改变 data record / index / journal 磁盘格式。
- 不破坏单 data file store 的兼容：旧 store 打开行为不变。
- 不 mock 文件；不在 DB 引入 VFS 概念。

## 4. 实现范围

- `OpenOptions.data_file_count`（仅 create 时生效，>=1）。
- `KvDb.data` 保持为 shard 0；新增 `extra_data: []DataFile` 存放 shard 1..n-1；`dataFile(id)`、`shardCount()`、`defaultShard(key)`。
- open/close/park/reopen 处理全部 data file。
- 所有读路径按 `IndexInfo.data_db_id` 路由。
- `PutOptions.shard`、`Batch.begin(..., .{ .shard })`；未指定时用 `defaultShard`。
- `commitPending` 与 `Batch.commit` 按 shard 分组 append；`Batch.commit` 的 data append 移出 `batch_lock`。
- `flushDataForCommit` 对触及的 shard 逐个 publishSuper。
- `optimize` 与 `verify` 遍历全部 shard；`relocateKey` 在记录所属 shard 内迁移。
- `DataFile.readKeyBytes(offset, dst)`：读回 record 中的 raw key bytes。
- `KvDb.collectLiveKeys(allocator)`：公开枚举 live entries（含 IndexInfo）。
- C ABI：`db_open_options_t.data_file_count`（struct_size 兼容）。
- `tools/db.zig dump_manifest` 输出 data file 列表。

## 5. 验证要求

- 多 shard put/get/delete/overwrite roundtrip，key 分布到 >1 个 data file。
- 指定 shard 的 Batch 写入落到对应 data file。
- 两个不同 shard 的 Batch 并发 commit 正确。
- 多 shard optimize 后 verify ok，数据可读。
- 旧单 data file store 打开与全部现有测试通过。
- `readKeyBytes` 回读等于写入的 raw key。

## 6. 完成标准

- `zig build test` 通过。
- 新增测试覆盖上述项。
