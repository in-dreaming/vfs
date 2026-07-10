# Task 09：Checkpoint

## 1. 任务目标

实现 delta 到 base 的 checkpoint。

checkpoint 将 old base 与 frozen delta 合并为 new base，并通过 superblock 原子切换，避免 delta 无限增长。

## 2. 必读上下文

执行前必须阅读：

- `docs/design/db/tasks/setup.md`
- `task_04_index_file_container.md`
- `task_04_base_index.md`
- `task_06_delta_index.md`
- `task_08_recovery_verify.md`
- `docs/design/db_arch.md` 的“Checkpoint”

## 3. 硬性禁止

- 禁止 mock/moke。
- 禁止 callback。
- 禁止 checkpoint 时原地修改 old base。
- 禁止 checkpoint 长时间阻塞所有 get。
- 禁止切换 superblock 前暴露不完整 new base。

## 4. 实现范围

实现：

- 使用 `task_04_index_file_container.md` 已实现的 RegionDirectory。
- active delta freeze。
- 创建新 active delta。
- checkpointing delta lookup。
- old base + frozen delta merge。
- new base region builder。
- new base crc verify。
- superblock atomic switch。
- old base/delta retired。
- reader epoch 后回收 old region。

## 5. Checkpoint 流程

~~~text
1. 获取 checkpoint state lock。
2. active_delta 标记为 checkpointing_delta。
3. 创建新的 active_delta。
4. 更新 superblock，使新写入进入新 active_delta。
5. 释放 checkpoint state lock。
6. 后台或当前线程 merge old_base + checkpointing_delta。
7. 写 new_base region，state = building。
8. verify new_base。
9. flush new_base。
10. 获取 checkpoint state lock。
11. superblock 切换 active_base_region_id 到 new_base。
12. checkpoint_delta_region_id = 0。
13. old base 和 checkpointing delta 标记 retired。
14. 释放 checkpoint state lock。
15. 等 reader epoch 安全后回收 retired region。
~~~

如果不实现后台线程，本任务可以同步执行 checkpoint，但 lookup 语义必须正确。

## 6. Merge 规则

~~~text
1. 遍历 old_base entries。
2. 查 frozen delta。
3. delta tombstone：跳过。
4. delta put：输出 delta 新 info。
5. delta not_found：输出 old base entry。
6. 遍历 frozen delta entries。
7. 对 old_base 不存在的新 key，输出 delta put。
8. 忽略 tombstone。
9. 按 base index 排序规则排序。
10. build new base。
~~~

V1 merge 可使用临时内存 HashSet/BitSet 标记 consumed，因为 checkpoint 是维护路径，不是 lookup 热路径。

## 7. Lookup 期间语义

checkpoint 期间 lookup 顺序：

~~~text
active_delta
checkpointing_delta
current snapshot base
~~~

切换后：

~~~text
active_delta
new_base
~~~

旧 reader 可以继续持有 old_base，直到 reader epoch 退出。

## 8. 验证流程

必须测试：

1. base 中 key A，delta 覆盖 A，checkpoint 后 base 返回新 A。
2. base 中 key B，delta tombstone B，checkpoint 后 B 不存在。
3. delta 中新 key C，checkpoint 后 C 进入 base。
4. checkpoint 期间 put D 进入新 active delta，不丢失。
5. checkpoint 期间 lookup A/B/C/D 语义正确。
6. new base build 中途崩溃，重启后仍使用 old base + delta。
7. superblock 切换后崩溃，重启后使用 new base。
8. old base 在 reader epoch 结束前不回收。
9. 不原地修改 old base。
10. 不使用 callback。
11. 不使用 mock/moke。

## 9. 完成标准

- delta 可安全合并。
- checkpoint 崩溃恢复正确。
- lookup 语义在 checkpoint 前中后保持一致。
