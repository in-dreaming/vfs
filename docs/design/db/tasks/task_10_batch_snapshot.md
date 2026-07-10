# Task 10：Batch 与 Snapshot

## 1. 任务目标

实现轻量 batch 原子发布与 snapshot read。

Batch 用于 editor import：一组 put/delete 要么全部可见，要么全部不可见。

Snapshot 用于读操作在 checkpoint、delta 切换期间保持一致视图。

## 2. 必读上下文

执行前必须阅读：

- `docs/design/db/tasks/setup.md`
- `task_07_kv_open_get_put_delete_cabi.md`
- `task_09_checkpoint.md`
- `docs/design/db_arch.md` 的“批量事务”和“并发模型”

## 3. 硬性禁止

- 禁止 mock/moke。
- 禁止 callback。
- 禁止实现通用 ACID 事务后改变既有 API 语义。
- 禁止 batch commit 前部分 key 可见。
- 禁止 snapshot 暴露内部 mmap 指针给 C。

## 4. 实现范围

实现：

- Batch handle。
- batch put。
- batch delete。
- batch commit。
- batch rollback。
- journal batch_begin/batch_commit replay。
- batch 原子发布到 delta。
- Snapshot handle。
- begin/end snapshot。
- snapshot get_size/get_into。
- C ABI batch/snapshot API。

## 5. Batch 语义

Batch commit：

~~~text
1. 写所有 data record，但不发布 delta。
2. 如果 durability == sync，flush 所有 touched data files，且必须保证扩展后的文件长度和 DataSuperBlock logical_tail durable。
3. append journal BATCH_BEGIN。
4. append journal PUT/DELETE records，带同一 batch_id。
5. append journal BATCH_COMMIT。
6. durability == sync 时 flush journal 与 DeltaHeader.journal_tail。
7. 持有相关 key locks。
8. 批量 publish delta slots。
9. 释放 locks。
~~~

禁止在 batch data record durable 之前写入 durable BATCH_COMMIT。否则 recovery 可能 replay 到不存在或损坏的 data record。

Recovery：

~~~text
只有看到 BATCH_COMMIT 的 batch 才 replay。
没有 commit 的 batch 全部忽略。
~~~

## 6. Snapshot 语义

Snapshot 捕获：

- active_delta generation。
- checkpointing_delta generation，如果存在。
- base region id。
- reader epoch。

Snapshot get：

~~~text
使用 snapshot 捕获的 index generations 查找。
读取 data record。
校验 key/crc/version。
~~~

Snapshot close/end 后释放 reader epoch。

## 7. C ABI 要求

禁止 callback。

建议 API：

~~~c
typedef struct db_batch db_batch_t;
typedef struct db_snapshot db_snapshot_t;

int db_batch_begin(db_t* db, db_batch_t** out_batch);
int db_batch_put(db_batch_t* batch, db_key128_t key, const void* data, uint64_t size, uint32_t flags);
int db_batch_delete(db_batch_t* batch, db_key128_t key);
int db_batch_commit(db_batch_t* batch, uint32_t durability);
int db_batch_rollback(db_batch_t* batch);

int db_snapshot_begin(db_t* db, db_snapshot_t** out_snapshot);
int db_snapshot_get_size(db_snapshot_t* snapshot, db_key128_t key, uint64_t* out_size);
int db_snapshot_get_into(db_snapshot_t* snapshot, db_key128_t key, void* dst, uint64_t dst_size, uint64_t* out_written);
int db_snapshot_end(db_snapshot_t* snapshot);
~~~

## 8. 验证流程

必须测试：

1. batch commit 前 key 不可见。
2. batch commit 后所有 key 可见。
3. batch rollback 后所有 key 不可见。
4. batch journal 有 begin 但无 commit，recovery 后不可见。
5. batch journal 完整 commit，recovery 后全部可见。
6. Sync batch 在 data flush 失败时不得写 BATCH_COMMIT。
7. Sync batch 在 BATCH_COMMIT durable 后 recovery 不能出现 dangling data offset。
8. snapshot 开始后 overwrite key，snapshot 仍读旧值。
9. snapshot 开始后 delete key，snapshot 仍按旧视图读取。
10. snapshot 与 checkpoint 并发，snapshot 读不损坏。
11. snapshot end 后 old regions 可回收。
12. C ABI 不返回内部指针。
13. 不使用 callback。
14. 不使用 mock/moke。

## 9. 完成标准

- batch 原子发布。
- snapshot 视图稳定。
- recovery 正确处理 committed/uncommitted batch。
