# Task 19：diff 侧（pack_scan / strategy / planner / engine / writer / 工具）

## 1. 任务目标

给定 base pack 与 target pack 目录，产出 DiffPack 目录；策略按 §5.3 自动决议并可被 BuildCfg 覆盖；diff 计算并行。

## 2. 必读上下文

- docs/vfs/diff_patch.md §4、§5、§7
- Task 14/15/16/17/18 产物

## 3. 硬性禁止

- 不做跨文件全局匹配（V1 非目标）。
- DiffPack 写入只用 PackWriter/KvDb 公开接口。

## 4. 实现范围

- `diff/pack_scan.zig`：枚举 pack live object，按 value magic 分类，构造 `PackImage{manifest, path_index, files: map<file_entry, FileImage>, tombstones, others}`。
- `diff/strategy.zig`：`decide(old_block?, new_block, override?, caps) -> Strategy`；阈值 `StrategyOptions`。
- `diff/diff_planner.zig`：对比两个 PackImage → `[]PlannedUnit` + `[]FileOp` + `PathDelta`。
- `diff/diff_engine.zig`：按 unit 生成 payload（L/P/R），试算降级；task 框架并行。
- `diff/diff_pack_writer.zig`：按 shard_hint 分组排序、chunk 打包、写 DiffManifest/UnitTable/FileOpTable/PathDelta/Chunk。
- `build_cfg.zig`：`shards=`、`default_diff_strategy=`、file 第 7 段 `diff_strategy`。
- `tools/vfs.zig`：`diff-pack`、`dump-diff`、`verify-diff`。

## 5. 验证要求

- none/lz4 混合 pack v1→v2：新增/修改/删除文件、page 数变化、codec 变化、空文件。
- 自动策略：lz4 block → L；zstd(占位) block → P/R；小 block → R。
- 覆盖策略生效；试算降级标记 flags。
- dump-diff / verify-diff 对产物无错误。

## 6. 完成标准

- `zig build test` 通过；工具可用。
