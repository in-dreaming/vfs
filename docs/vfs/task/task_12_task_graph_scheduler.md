# Task 12：Build/Merge Resource Task Graph 调度器

## 1. 任务目标

实现 build/merge 的 Resource Task Graph 基础调度器，用于控制 IO、CPU、DB 写入、内存和 pack exclusive 资源。

本任务先实现静态预算调度，不要求自适应调度和 critical path 全局最优。

---

## 2. 必读上下文

- docs/vfs/task/setup.md
- task_09_build_cfg_incremental.md
- task_10_merge_patch_mutation.md
- docs/design/vfs/vfs.md 中 Resource Task Graph 章节

---

## 3. 硬性禁止

- 禁止 mock/moke。
- 禁止 ready task 全部无控制启动。
- 禁止忽略内存预算。
- 禁止多个 pack exclusive task 同时操作同一 pack。
- 禁止 DB 写入并发绕过 DB 安全边界。
- 禁止 callback public API。

---

## 4. 实现范围

建议新增：

~~~text
src/vfs/mutation/task_graph.zig
src/vfs/mutation/resource_budget.zig
src/vfs/mutation/scheduler.zig
src/vfs/mutation/executors.zig
~~~

### 4.1 Task 类型

至少支持：

~~~text
ReadSource
HashPage
CompressPage
WritePageKV
WriteFileManifest
WriteEntryTombstone
UpdatePathIndex
UpdatePackManifest
VerifyPack
FlushPack
~~~

### 4.2 ResourceBudget

~~~text
max_disk_read_tasks
max_disk_write_tasks
max_hash_tasks
max_compress_tasks
max_db_write_tasks
max_inflight_memory_bytes
max_pack_exclusive_tasks
~~~

### 4.3 调度循环

~~~text
while graph not finished:
  collect finished tasks
  release resources
  mark dependents ready
  pick ready tasks respecting budgets
  dispatch tasks
  wait for event
~~~

### 4.4 Pack locks

同一 pack：

- WritePageKV 可以受 max_db_write_tasks 控制。
- UpdatePackManifest、VerifyPack、FlushPack 需要 PackExclusive。
- PackExclusive 运行期间不得启动同 pack 新 shared task。

### 4.5 错误传播

task 失败：

- 标记该 task failed。
- 取消依赖它的后续 task。
- 不提交 PackManifest。
- 不发布 resolver。
- 返回包含 task type、file_entry、pack_id 的错误。

---

## 5. 验证要求

必须测试：

1. 简单线性图执行顺序正确。
2. 多 page 并行 hash/compress 受预算控制。
3. max_inflight_memory_bytes 生效。
4. max_db_write_tasks 生效。
5. PackExclusive 与 shared task 不冲突。
6. task 失败取消后续依赖。
7. build 大量文件不出现无界内存增长。
8. 调度执行结果与同步 PackBuilder 结果一致。

验证命令：

~~~powershell
zig build test
~~~

---

## 6. 完成标准

- Build/Merge 可通过 task graph 执行。
- 资源预算真实生效。
- 失败不会发布半成品。
- 无 mock/moke。

