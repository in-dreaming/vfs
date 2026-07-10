# Task 04A：Index DB Container

## 1. 任务目标

实现 `index.db` 的文件容器层。

本任务负责 `index.db` 的外壳、双 superblock、region directory、region 分配，以及 active base / active delta 的入口解析。后续 base index、delta journal、delta hash、checkpoint 都必须落在本任务定义的 `index.db` region 体系内。

本任务不实现 base lookup、delta hash probing、journal record 语义、checkpoint merge。

## 2. 必读上下文

执行前必须阅读：

- `docs/design/db/tasks/setup.md`
- `task_00_platform_io.md`
- `task_01_format_crc_hash.md`
- `task_03_manifest.md`
- `docs/design/db_arch.md` 的 “Index DB 设计”

## 3. 硬性禁止

- 禁止 mock/moke。
- 禁止 callback。
- 禁止创建独立 `base.index`、`delta.hash`、`delta.journal` 文件作为生产格式。
- 禁止绕过 `index.db` superblock 直接猜测 region offset。
- 禁止把 VFS 路径、mount、overlay 等概念写入 index 文件格式。

## 4. 实现范围

实现：

- `IndexFileHeader`。
- `IndexSuperBlock` A/B。
- `RegionDirectory`。
- `RegionDesc`。
- 创建空 `index.db`。
- 打开 `index.db`。
- 选择有效 superblock。
- 固定容量 region directory V1。
- region allocate/building/active/retired 状态切换。
- active base region id 查询。
- active delta region id 查询。
- checkpoint delta region id 查询。
- index file verify 基础检查。

V1 region directory 可以固定容量，例如 4096 个 `RegionDesc`。V1 可以不做复杂 region coalesce，但必须能记录 retired region。

## 5. 文件布局

`index.db` V1 布局：

~~~text
index.db

+-------------------------------+
| IndexFileHeader               |
+-------------------------------+
| IndexSuperBlock A             |
+-------------------------------+
| IndexSuperBlock B             |
+-------------------------------+
| RegionDirectory               |
+-------------------------------+
| Region Area                   |
|   BaseIndex Region            |
|   DeltaGeneration Region      |
|   Old/Building/Retired Region |
+-------------------------------+
~~~

所有 region offset 必须是 `index.db` 文件内 offset。

禁止存进程指针。

## 6. Region 类型

必须支持：

~~~text
FREE
BASE_INDEX
DELTA
OLD_BASE
RESERVED
~~~

必须支持状态：

~~~text
FREE
BUILDING
ACTIVE
CHECKPOINTING
RETIRED
PENDING_RECLAIM
~~~

## 7. SuperBlock 规则

`IndexSuperBlock` 是当前 index 状态入口。

必须包含：

- epoch。
- file_size。
- active_base_region_id。
- active_delta_region_id。
- checkpoint_delta_region_id，0 表示无。
- region_directory_epoch。
- last_committed_journal_epoch。
- clean_shutdown。
- flags。
- crc。

启动选择规则：

~~~text
1. 读取 A/B。
2. magic 正确。
3. crc 正确。
4. 选择 epoch 最大的有效 superblock。
5. A/B 都无效则 open 返回 corruption。
~~~

## 8. Region 更新协议

创建新 region：

~~~text
1. 分配 region id。
2. 写 RegionDesc state = BUILDING。
3. flush region directory 或确保后续 superblock 切换前 region directory durable。
4. caller 写 region 内容。
5. caller verify region 内容。
6. 切换 RegionDesc state = ACTIVE 或 CHECKPOINTING。
7. 写另一个 IndexSuperBlock，epoch + 1。
8. flush superblock。
~~~

不能让 superblock 指向未完成的 BUILDING region。

## 9. DeltaGeneration Region 约束

Delta hash table 和 delta journal 必须在同一个 `DELTA` region 内。

V1 `DELTA` region 内部布局：

~~~text
DeltaHeader
DeltaHashTable
DeltaJournalArea
~~~

`DeltaHeader` 记录：

- slot_offset。
- slot_count。
- journal_offset。
- journal_size。
- journal_tail。
- clean flag。

后续 `task_05_delta_journal.md` 的 journal append 是对 `DeltaJournalArea` 的 offset-based append，不是写独立 journal 文件。

## 10. 验证流程

必须测试：

1. 创建空 `index.db`。
2. 打开后能选择有效 superblock。
3. 损坏 superblock A 时选择 B。
4. 损坏 epoch 更高但 crc 错误的 superblock 时选择旧有效 superblock。
5. A/B 都损坏时 open 返回 corruption。
6. 分配 base region，state 从 BUILDING 变 ACTIVE。
7. 分配 delta region，能读取 active_delta_region_id。
8. superblock 不允许指向 BUILDING region。
9. region offset/size 越界时 verify 失败。
10. 不创建独立 delta journal 文件。
11. 不使用 callback。
12. 不使用 mock/moke。

## 11. 完成标准

- `index.db` 容器可真实创建、打开、验证。
- 后续 base/delta/journal/checkpoint 均能通过 region id 定位。
- active base / active delta 入口语义明确。
- 没有独立 index 子文件作为生产格式。

