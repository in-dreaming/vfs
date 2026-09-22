# Task 16：lz4 codec 与 CodecCaps

## 1. 任务目标

纯 zig 实现 lz4 block 格式压缩与解压，接入 compress registry、pack 构建与读路径，并给每个 codec 提供 `CodecCaps`。

## 2. 必读上下文

- docs/vfs/diff_patch.md §5.3、§13
- src/vfs/compress/*.zig、src/vfs/io/file_handle.zig、src/vfs/build/build_plan.zig、src/vfs/build/pack_builder.zig

## 3. 硬性禁止

- 不链接外部 lz4 库。
- 解压必须严格边界检查；损坏输入返回错误，不越界。
- 不用伪压缩（原样拷贝冒充 lz4）。

## 4. 实现范围

- `lz4.zig`：`compressBound`、`compressBlock(src, dst, level)`（hash 表匹配，level 控制搜索深度）、`decompressBlock(src, dst, raw_size)`；`caps`。
- `registry.zig`：`CodecCaps`、`caps(codec)`、`compressPage(codec, level, raw, dst)`、`decompressPage` 接入 lz4；zstd caps 为 `runtime_compress=false`。
- `build_plan.zig`：lz4 不再报 Unsupported。
- `pack_builder.createPack`：按 `BuildFileInput.codec/codec_level` 压缩 page（可存 raw：压缩无收益时 stored==raw 并置 page_flags）。
- `file_handle.zig`：移除 `codec != .none -> Unsupported`，走 `decompressPage`。

## 5. 验证要求

- lz4 随机数据 roundtrip（0..1 MiB，含高重复与不可压缩）。
- 与内嵌参考向量对拍（至少 2 组固定输入→固定输出）。
- 损坏/截断输入解压返回错误。
- 相同输入两次压缩输出字节一致。
- 构建 lz4 pack -> Volume 读回字节一致；verifyPack 通过。

## 6. 完成标准

- `zig build test` 通过；lz4 pack 端到端可读。
