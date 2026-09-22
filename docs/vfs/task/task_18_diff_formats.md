# Task 18：DiffPack 与 patch 相关磁盘格式

## 1. 任务目标

实现 diff/patch 需要的全部编码格式与 object key namespace。

## 2. 必读上下文

- docs/vfs/diff_patch.md §7、§8.2、§14
- docs/vfs/task/setup.md §5（文件格式要求）
- src/vfs/format/*.zig、src/vfs/object_key.zig

## 3. 硬性禁止

- 不裸写 Zig struct；显式 LE encode/decode；保留字段写 0；全部 CRC 校验。

## 4. 实现范围

- `format/diff_manifest.zig`（VDFM）
- `format/diff_file_op.zig`（VDFO，FileOp 112B）
- `format/diff_unit_table.zig`（VDUT，UnitDesc 128B）
- `format/diff_path_delta.zig`（VDPI）
- `format/diff_chunk.zig`（VDCK header 32B）
- `format/page_placeholder.zig`（VPHD 40B）
- `format/patch_intent.zig`（VPIN）
- `format/pack_manifest.zig`：version 2 增加 overlay 字段（base_pack_id/base_pack_version/base_pack_generation/overlay_flags），v1 解码兼容；`PACK_FLAG_OVERLAY`。
- `object_key.zig`：diff namespace、`patchIntentKey`、reserved key 更新。

## 5. 验证要求

- 每种格式 encode/decode roundtrip、编码尺寸 comptime/测试断言、每字段位翻转拒绝、identity 不匹配拒绝。
- PackManifest v1 字节仍可解码；v2 roundtrip。

## 6. 完成标准

- `zig build test` 通过。
