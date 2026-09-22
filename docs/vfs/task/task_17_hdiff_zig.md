# Task 17：hdiff 算法 zig 移植

## 1. 任务目标

在 `src/vfs/hdiff/` 实现与 HDiffPatch `create_compressed_diff` 同构的字节级差分（suffix array + cover 匹配 + subDiff RLE）与线性流式 patch，容器为自定义 VHDF。

## 2. 必读上下文

- docs/vfs/diff_patch.md §6
- HDiffPatch 算法结构（公开资料）：suffix string 匹配、cover extend/link、RLE subDiff、new_data_diff 四流

## 3. 硬性禁止

- 不引入 C 依赖。
- patch 端不得对 old 做整体拷贝之外的隐式大内存分配（O(1) 额外 scratch）。
- 任何损坏输入不得越界/panic。

## 4. 实现范围

- `sais.zig`：SA-IS 后缀数组（i32）。
- `match.zig`：SA 二分 + LCP 扩展的最长匹配；near-position 优先。
- `cover.zig`：过滤/extend/link。
- `rle.zig`、`varint.zig`、`serialize.zig`（VHDF 编解码，四流可选 lz4）。
- `patch.zig`：`patch(old, diff, out)`。
- `diff.zig`：`diff(allocator, old, new, DiffOptions) ![]u8`、`DiffOptions{min_match_len, min_single_match_score, compress_streams}`、`optionsHash`。

## 5. 验证要求

- roundtrip：随机、全同、全异、空 old、空 new、插入/删除/移动块。
- diff 比例回归：对 1 MiB 随机数据修改 1% 字节，VHDF 大小 < 10% new。
- sais 与朴素排序对拍（n ≤ 2000）。
- VHDF 各 header 字段位翻转 → 错误。
- rle/varint 边界。

## 6. 完成标准

- `zig build test` 通过。
