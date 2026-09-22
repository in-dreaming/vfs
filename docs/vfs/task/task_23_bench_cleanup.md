# Task 23：bench-patch、旧路径删除与文档收敛

## 1. 任务目标

提供实验矩阵工具；删除被取代的 whole-file PatchManifest 路径；更新 README 与 roadmap。

## 2. 必读上下文

- docs/vfs/diff_patch.md §15、§17

## 3. 硬性禁止

- 不保留死代码分支。

## 4. 实现范围

- `tools/vfs.zig bench-patch`：复制目标到临时目录，对配置矩阵（in_memory/disk、batch_bytes、threads、durability）逐项 patch 并输出耗时/写字节/峰值 staged 内存。
- 删除 `format/patch_manifest.zig`、`mutation/merge_planner.zig`、`mutation/mutation_plan.zig`、`mutation/mutation_executor.zig`、`mutation/root.zig`，更新 `root.zig`。
- README：pack 多 shard、lz4、diff/patch 用法；roadmap 增加 Phase 15。

## 5. 验证要求

- bench-patch 可运行并输出。
- `zig build test` 通过。

## 6. 完成标准

- 文档、代码一致。
