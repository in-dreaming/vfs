# Task 21：patch 侧（reader / chain / coalesce / old_view / shard_writer / session / 工具）

## 1. 任务目标

给定目标 pack（in-place 或 overlay）与一个或多个 DiffPack，用 task 框架并行 apply，最终原子提交 PackManifest；支持幂等重跑。

## 2. 必读上下文

- docs/vfs/diff_patch.md §8、§9、§11、§14、§15
- Task 14–20 产物

## 3. 硬性禁止

- 写路径只用 `Batch`，不用 `KvDb.put`（避免读触发提交）。
- worker 内不阻塞等待 staged 内存，使用 yield。
- 不记录进度表（D4）；幂等靠目标校验。

## 4. 实现范围

- `patch/diff_pack_reader.zig`：in-memory（InMemoryFileOps 只读）或 disk 打开；解码全部表；`chunkSlice(chunk_id)`。
- `patch/chain.zig`：给定 DiffPack 列表 + from/to，Dijkstra 选最小 payload 路径。
- `patch/coalesce.zig`：fold 出 `PatchPlan{units_by_shard, file_ops, path_delta, final_params}`；R∘P plan 期合并；P/L chain 保序。
- `patch/old_view.zig`：多层读取。
- `patch/shard_writer.zig`：staged ops、水位、`Batch` 提交、durability 策略。
- `patch/patch_session.zig`：P0–P6 流程、graph 构建、apply_unit（R/P/L/delete 与幂等检查）、file_op、path_index、commit_manifest、PatchIntent。
- `PatchOptions`（§15）。
- `tools/vfs.zig`：`patch-pack`。

## 5. 验证要求

- in-place：v1 --(d12)--> v2 --(d23)--> v3 与 v1 --(d12,d23 合并)--> v3 与 v1 --(d13)--> v3 三者 object 集合等价于构建的 v3。
- overlay：readonly v1 + overlay → Volume 读全部文件字节 == v3 源文件。
- 幂等：完成后重跑写入 0 op。
- 崩溃矩阵：在任一 task kind 完成后中止（fault injection），重跑收敛。
- P precondition 失败、CodecMismatch、PatchIntent 不一致、chain 无路径 → 明确错误。

## 6. 完成标准

- `zig build test` 通过；工具端到端可用。
