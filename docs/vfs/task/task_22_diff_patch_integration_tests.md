# Task 22：diff/patch 集成与崩溃矩阵测试

## 1. 任务目标

在 `tests/vfs_diff_patch.zig` 建立端到端测试：多版本构建 → diff → patch（in-place / overlay / chain）→ 等价性 → 崩溃重跑 → 幂等。

## 2. 必读上下文

- docs/vfs/diff_patch.md §21
- Task 19–21 产物

## 3. 硬性禁止

- 不用 mock；崩溃用 fault injection 在真实流程中提前返回错误。

## 4. 实现范围

- 生成 v1/v2/v3 源数据集（none + lz4、多 shard、含新增/修改/删除/缩小/扩大 page 数）。
- 三条 patch 路径的等价性检查（逐 key 比较 decode 后的 object；PackManifest pack_version/content_hash）。
- overlay 路径用 Volume 读回字节与源比较。
- 崩溃矩阵：对每种 task kind，在完成 k 个后注入失败，然后无注入重跑，检查等价。
- 幂等重跑统计写入 0。
- build.zig 注册为 test step。

## 5. 验证要求

- 全部通过；无泄漏（testing.allocator）。

## 6. 完成标准

- `zig build test` 通过。
