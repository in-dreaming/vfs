# Task 12：Relocation 与 Truncate

## 1. 任务目标

实现后台或显式 optimize 能力：

- 将尾部 live record 搬到前部 hole。
- 形成连续 tail free range。
- 安全 truncate 缩容。

本任务依赖 allocator 与 epoch。

## 2. 必读上下文

执行前必须阅读：

- `docs/design/db/tasks/setup.md`
- `task_11_allocator_epoch.md`
- `task_09_checkpoint.md`
- `docs/design/db_arch.md` 的“Relocation”和“Truncate”

## 3. 硬性禁止

- 禁止 mock/moke。
- 禁止 callback。
- 禁止不校验 index current location 就搬移。
- 禁止直接修改 base index。
- 禁止 truncate 中间 hole。
- 禁止 reader epoch 未安全时 truncate。

## 4. 实现范围

实现：

- live record candidate scan。
- hole candidate selection。
- relocation write new record。
- index logical CAS。
- failed CAS cleanup。
- tail free range tracking。
- resize lock。
- safe truncate。
- optimize API。

## 5. Relocation 协议

~~~text
1. 从文件尾部向前选择 live record old_info。
2. 读取 old record。
3. 校验 key/crc/version。
4. 选择前部 hole。
5. 写 new record 到 hole。
6. 执行 index_compare_exchange(key, old_info, new_info)。
7. CAS 成功：old block retire。
8. CAS 失败：new block retire。
~~~

index_compare_exchange 是逻辑 CAS：

~~~text
1. key lock。
2. lookup current。
3. current 必须等于 expected。
4. append delta journal PUT desired。
5. publish delta hash desired。
6. unlock。
~~~

如果 key 已 tombstone 或 current != expected，relocation 放弃。

## 6. Truncate 协议

只允许 truncate tail free：

~~~text
[Live][Hole][Live][TailFree] 只能缩 TailFree
~~~

流程：

~~~text
1. 获取 resize lock。
2. 确认 tail range 全部 FREE/TAIL_FREE。
3. 确认无 pending writer。
4. 确认 reader epoch 安全。
5. 写 allocator checkpoint。
6. 写 DataSuperBlock，logical_tail 更新。
7. flush metadata。
8. setLen/truncate 文件。
9. 释放 resize lock。
~~~

runtime 默认关闭自动 truncate，必须通过 config 或显式 optimize 调用。

## 7. Crash Recovery

relocation 崩溃情况：

- new record 写完但 index CAS 未发布：new record 是 orphan/quarantine。
- index CAS 发布后 old record 未 retire：两个 record 都完整，但 index 指向 new，old 后续可 orphan/quarantine。
- CAS 失败但 new record 未 retire：new record orphan/quarantine。

truncate 崩溃情况：

- superblock 未切换：使用旧 tail。
- superblock 已切换但 truncate 未执行：文件更大但 tail 之后为 free，可后续 shrink。
- truncate 已执行：使用新 tail。

## 8. 验证流程

必须测试：

1. relocation 成功后 lookup 返回同一 payload。
2. relocation 后 old block retired。
3. relocation CAS 失败时 new block retired。
4. delete 与 relocation 竞争时不复活 deleted key。
5. overwrite 与 relocation 竞争时不覆盖新值。
6. tail live records 搬走后形成 tail free。
7. safe truncate 后文件长度下降。
8. 中间 hole 不触发 truncate。
9. active reader 持有 tail old record 时 truncate 被推迟。
10. relocation 崩溃模拟后 recovery 不丢可见数据。
11. truncate 崩溃模拟后 recovery 一致。
12. 不使用 callback。
13. 不使用 mock/moke。

## 9. 完成标准

- optimize 可降低碎片。
- truncate 只在安全条件下执行。
- 并发 put/delete/reader 不被破坏。
- 崩溃恢复语义完整。

