# Task 06：Delta Hash Index

## 1. 任务目标

实现 mutable delta hash index。

Delta index 承担 runtime/editor 所有 index 修改，包括 put、delete tombstone，以及后续 relocation 的逻辑 CAS 发布。

本任务集成 delta journal：写 delta 前必须先 append journal。

## 2. 必读上下文

执行前必须阅读：

- `docs/design/db/tasks/setup.md`
- `task_04_index_file_container.md`
- `task_05_delta_journal.md`
- `task_04_base_index.md`
- `docs/design/db_arch.md` 的“Delta Index”

## 3. 硬性禁止

- 禁止 mock/moke。
- 禁止 callback。
- 禁止用 Zig HashMap 代替生产 delta hash table。
- 禁止先更新 hash table 再写 journal。
- 禁止忽略 tombstone。

## 4. 实现范围

实现：

- DeltaHeader。
- DeltaSlot。
- open addressing hash table。
- put。
- delete tombstone。
- lookup。
- load factor 统计。
- dirty/clean flag。
- journal replay 重建 hash table。
- striped lock。

V1 可使用 striped lock 保护 probe/update 范围。seqlock 可以后续优化，不是本任务必须。

Delta hash table 必须位于 `index.db` 的 active `DELTA` region 内，和 DeltaJournalArea 共享同一个 DeltaGeneration region。生产格式禁止独立 delta hash 文件。

## 5. Hash Table 规则

- slot_count 必须是 2 的幂。
- load factor 触发条件：`live_count + tombstone_count <= slot_count * 0.70`。
- probing V1 使用 linear probing。
- insert 可复用第一个 unrelated tombstone slot。
- lookup 遇到 unrelated tombstone 不能停止。
- lookup 遇到 same-key tombstone 必须返回 deleted。

## 6. 写入顺序

PUT：

~~~text
1. key striped lock。
2. delta stripe lock。
3. append journal PUT。
4. publish/update delta slot。
5. 更新 live/tombstone count。
6. unlock。
~~~

DELETE：

~~~text
1. key striped lock。
2. delta stripe lock。
3. append journal DELETE。
4. publish tombstone slot。
5. 更新 live/tombstone count。
6. unlock。
~~~

journal append 失败时，不允许修改 hash table。

## 6.1 Clean / Dirty 持久化协议

open writable 时：

~~~text
1. 设置 DeltaHeader.clean = 0。
2. flush DeltaHeader 所在范围。
3. 后续所有 put/delete 才允许执行。
~~~

normal close 时：

~~~text
1. flush delta journal 写入范围。
2. flush delta hash table 写入范围。
3. 设置 DeltaHeader.clean = 1。
4. flush DeltaHeader 所在范围。
5. 更新并 flush IndexSuperBlock clean_shutdown。
~~~

如果 hash table 或 journal 没有完成 flush，禁止把 clean 设置为 1。

如果 open 时发现 clean = 0，必须 replay journal 重建 hash table，不能信任现有 hash table。

## 7. Recovery

dirty delta 恢复：

~~~text
1. 清空 delta hash table。
2. 使用 JournalScanner 主动 next() 扫描。
3. 对完整 PUT record 执行 slot put，但不再次写 journal。
4. 对完整 DELETE record 执行 tombstone put，但不再次写 journal。
5. 将 DeltaHeader.journal_tail 回退到 last_good_tail。
6. flush replay 后的 hash table。
7. 设置 clean = 1。
8. flush DeltaHeader。
~~~

禁止用 callback replay。

## 8. 验证流程

必须测试：

1. 空 delta lookup 返回 not_found。
2. put 后 lookup 返回 IndexInfo。
3. put 同 key 第二次覆盖第一次。
4. delete 后 lookup 返回 deleted/tombstone。
5. unrelated tombstone 不终止 probe。
6. hash collision 下 full key 校验正确。
7. journal append 失败时 hash table 不变。
8. dirty recovery replay 后 lookup 结果一致。
9. 截断 journal 后 recovery 只恢复完整 record。
10. load factor 超过阈值返回 need_checkpoint 或明确错误。
11. open writable 会先持久化 clean = 0。
12. normal close 只有 journal/hash/header 都 flush 后才设置 clean = 1。
13. clean = 0 时 open 必须 replay journal。
14. 不使用生产 HashMap。
15. 不使用 callback。
16. 不使用 mock/moke。

## 9. 完成标准

- delta hash table 是真实文件/mmap region 或真实文件映射结构。
- journal 是恢复真相。
- recovery 可重建 hash table。
- tombstone 语义完整。
