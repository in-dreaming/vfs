# Task 15：通用 Task 框架 `src/vfs/task/`

## 1. 任务目标

用一个通用、索引化、支持优先级/资源预算/动态加任务/yield 的 DAG 调度框架替换 `src/vfs/mutation/{task_graph,scheduler,resource_budget}.zig`，并迁移 `pack_builder`。

## 2. 必读上下文

- docs/vfs/diff_patch.md §10
- src/vfs/mutation/task_graph.zig、scheduler.zig、resource_budget.zig（被替换对象）
- src/vfs/build/pack_builder.zig（使用方）

## 3. 硬性禁止

- 不引入 callback 风格 public C ABI。
- 调度器不得在 worker 线程内阻塞等待资源（用 yield）。
- 不保留旧调度器副本。

## 4. 实现范围

- `graph.zig`：`Graph{addTask, addDependency, cancel, stats}`，入度计数、users 列表、运行中可加任务。
- `resource.zig`：`ResourceClass`、`Need`、`Budget`、token 池（计数 + mem 字节 + 每 shard 写令牌 + pack 互斥）。
- `scheduler.zig`：按资源类分的优先级堆 ready 队列；dispatch 循环；yield 重排；失败级联取消；`Report/Stats`。
- `worker_pool.zig`：可复用线程池，MPMC 队列。
- `trace.zig`：可选 dispatch trace ring buffer 与 JSON dump。
- `pack_builder` 迁移到新 API；删除 `mutation/task_graph.zig`、`scheduler.zig`、`resource_budget.zig`；`mutation_executor` 暂用新 API（Task 24 删除）。

## 5. 验证要求

- 线性依赖按序执行。
- 预算上限（cpu/io/mem/shard/pack_exclusive）不被突破。
- 失败级联取消 users。
- 多 worker 并发执行 ready 任务。
- 运行中动态 addTask 并被执行。
- yield 任务被重新调度且最终完成。
- pack_builder 现有测试通过。

## 6. 完成标准

- 旧模块删除，`zig build test` 通过。
