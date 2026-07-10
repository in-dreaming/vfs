# Task 11：Allocator 与 Epoch Reclaim

## 1. 任务目标

将 data db 从 append-only 演进为 append-first + hole reuse。

实现 free-list allocator、retired block、reader epoch、allocator checkpoint。

本任务不实现 relocation/truncate。

## 2. 必读上下文

执行前必须阅读：

- `docs/design/db/tasks/setup.md`
- `task_02_data_record_append.md`
- `task_07_kv_open_get_put_delete_cabi.md`
- `task_08_recovery_verify.md`
- `docs/design/db_arch.md` 的“Data DB 的空间管理”

## 3. 硬性禁止

- 禁止 mock/moke。
- 禁止 callback。
- 禁止 old record 在 reader epoch 安全前复用。
- 禁止 dirty recovery 时直接复用不确定空间。
- 禁止把 allocator 状态只放内存不 checkpoint。

## 4. 实现范围

实现：

- Reader epoch manager。
- enter/exit read epoch。
- retired block list。
- safe reclaim。
- size-class free-list。
- allocate from hole。
- split free block。
- append fallback。
- allocator checkpoint。
- dirty recovery quarantine。

## 5. Epoch 规则

get/snapshot 必须：

~~~text
enter_read_epoch()
lookup index
read data
exit_read_epoch()
~~~

retire block：

~~~text
retired_block = { offset, size, retire_epoch }
~~~

reclaim：

~~~text
if retired_block.retire_epoch < oldest_reader_epoch:
    insert into free-list
~~~

没有 active reader 时，oldest_reader_epoch 可以视为 current_epoch + 1。

## 6. Allocator 规则

分配：

~~~text
1. size = align_up(record_size, record_alignment)。
2. 从 size_class(size) 开始查找 free block。
3. 找到足够 block 则使用。
4. 如果剩余 >= min_split_size，split remainder 回 free-list。
5. 找不到则 append logical_tail。
~~~

释放：

~~~text
不直接 free。
必须 retire。
~~~

## 7. Allocator Checkpoint

checkpoint 保存 FREE blocks，不保存 RETIRED blocks。

格式：

~~~zig
pub const AllocatorCheckpointHeader = extern struct {
    magic: u32,
    version: u32,
    epoch: u64,
    logical_tail: u64,
    free_bytes: u64,
    pending_free_bytes: u64,
    class_count: u32,
    block_count: u32,
    block_array_offset: u64,
    header_crc: u32,
};

pub const FreeBlockDisk = extern struct {
    offset: u64,
    size: u32,
    size_class: u32,
};
~~~

写入协议：

~~~text
1. 写新 checkpoint region。
2. flush。
3. 更新 DataSuperBlock 指向新 checkpoint。
4. old checkpoint retire。
~~~

## 8. Dirty Recovery

dirty recovery：

~~~text
1. 从 index 收集 live offsets。
2. 扫描 data records。
3. live offset -> LIVE。
4. valid but not live -> quarantine 或 FREE，V1 选择 quarantine。
5. invalid partial tail -> 截断或忽略。
6. 不确定区域不得复用。
~~~

## 9. 验证流程

必须测试：

1. overwrite key 后 old block 进入 retired，不立即 free。
2. active reader 持有 old epoch 时 old block 不复用。
3. reader 退出后 reclaim，old block 可复用。
4. small hole 被 small record 复用。
5. large hole split 后 remainder 回 free-list。
6. allocator checkpoint 后重启 free-list 保持。
7. dirty recovery 中 orphan 进入 quarantine，不复用。
8. no active reader 时 reclaim 正常推进。
9. 不使用 callback。
10. 不使用 mock/moke。

## 10. 完成标准

- append-first + hole reuse 可用。
- old offset 复用受 epoch 保护。
- allocator checkpoint 可恢复。
- dirty 不确定空间不复用。

