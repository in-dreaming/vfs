# Task 24：patch C ABI（V1.5，轮询式）

## 1. 任务目标

在 `include/vfs.h` 与 `src/vfs/abi.zig` 暴露 `vfs_patch_begin/poll/wait/cancel/end`，无 callback。

## 2. 必读上下文

- docs/vfs/diff_patch.md §16.2
- Task 21 产物

## 3. 硬性禁止

- 禁止 callback；进度只能轮询。

## 4. 实现范围

- `vfs_patch_options_t`、`vfs_patch_progress_t`（含 struct_size）。
- `vfs_patch_begin` 在后台线程运行 PatchSession；`poll` 读原子进度；`wait` 带超时；`cancel` 设置取消标志；`end` 释放。
- handle 注册到 handle_registry。

## 5. 验证要求

- C smoke：begin → poll 至完成 → end；错误路径（无效 handle、不存在 diff）。

## 6. 完成标准

- `zig build test` 通过（含 C smoke）。
