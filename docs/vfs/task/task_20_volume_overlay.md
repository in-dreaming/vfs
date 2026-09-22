# Task 20：Volume 同 pack_id 多层与 PagePlaceholder

## 1. 任务目标

Volume 支持 overlay pack（同 pack_id、更高 priority、PackManifest 带 base 链接）与 base pack 同时挂载；page/FileManifest 逐层解析；PagePlaceholder 屏蔽下层 page。

## 2. 必读上下文

- docs/vfs/diff_patch.md §8、§12.4
- src/vfs/volume/volume.zig、src/vfs/io/file_handle.zig

## 3. 硬性禁止

- 不改变非 overlay pack 的既有读语义与并发读性能路径。

## 4. 实现范围

- `mountPackWithPriority`：允许同 pack_id 多 mount 当且仅当新 mount 的 PackManifest 有 `PACK_FLAG_OVERLAY` 且 `base_pack_id == pack_id`，并校验已挂载 base 的 pack_version == overlay.base_pack_version。
- `resolveVisibleFile` / `FileHandle.readAt`：同 pack_id 层按 priority 降序逐层查 object，NotFound 继续，PagePlaceholder 终止为 NotFound。
- `patch/overlay.zig`：`createOverlay(base_path, overlay_path)`、`openOrCreateOverlay`、`validateOverlay`。

## 5. 验证要求

- base + overlay 挂载：overlay 中的 page 覆盖 base；未覆盖 page 读自 base；placeholder 使 page 读 NotFound。
- base 版本不匹配的 overlay 拒绝挂载。
- 非 overlay 同 pack_id 重复挂载仍拒绝。

## 6. 完成标准

- `zig build test` 通过。
