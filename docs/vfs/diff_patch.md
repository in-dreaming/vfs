# VFS Pack Diff & Patch 设计

本文是 VFS pack 差分（diff）与增量更新（patch）的架构设计。它建立在 `docs/vfs/vfs_arch.md`、`docs/vfs/task/setup.md` 与现有实现之上，所有约束（u64 FileEntry、u64 object key、value 强校验、禁 mock、禁 callback public API、DB/VFS 库边界）继续生效。

---

## 0. 决策记录

以下为设计前已人工决策的事项，本文其余内容均以此为前提。

| # | 议题 | 决策 |
|---|---|---|
| D1 | patch 写回位置 | pack 分 readonly / writable 两种形态。readonly（如 apk 内）不可写：为其创建 **overlay writable pack**，以更高优先级挂载，patch 写入 overlay。writable pack **in-place** 直接写回。 |
| D2 | 多 data db 并行 | 先补 DB 层多 data file 支持（KvDb 打开 manifest 中全部 `data_NNN.db`，按 `IndexInfo.data_db_id` 路由读，写可指定 shard）。patch 以 shard 为并行/批量单位。 |
| D3 | hdiff 迁移范围 | V1 仅迁移内存 suffix-array 精确匹配 diff；按 block/文件分段控制内存；patch 端完整移植。大文件流式 diff（block-digest）不在 V1。 |
| D4 | 崩溃恢复模型 | 只依赖 DB 事务原子性。不记录进度。重启后重跑全部 unit，用“目标已到位（hash/crc 命中）”幂等跳过。 |
| D5 | task graph 框架 | 新建通用 `src/vfs/task/`（索引化 DAG、按资源类分 ready 队列、关键路径优先级、typed payload、运行中动态加任务、统计/进度/取消、可插拔 executor）。`pack_builder`/`mutation_executor` 迁移，旧 `mutation/task_graph.zig`、`scheduler.zig`、`resource_budget.zig` 删除。 |
| D6 | 压缩 codec | 纯 zig 实现 lz4 block 格式（压缩 + 解压）作为前置任务。zstd/oodle 保持占位，作为“不可运行时压缩”的策略路径。 |
| D7 | diff 容器 blob 粒度 | 按目标 shard 分组 + 固定大小 chunk blob（默认 8 MiB，可配）。unit 描述符记 `(chunk_id, offset, len)`。 |
| D8 | 差分策略来源 | 按 codec 能力自动推导 + BuildCfg `diff_strategy=` 可覆盖 + diff 时试算降级。 |

设计内新增、未单独提问但对外部行为有影响的选择，集中列在 §19，可复议。

---

## 1. 定位与目标

~~~text
构建机 (Build Host)                      客户端 (Runtime / Updater)
  pack v1 ──┐                              base pack (readonly | writable)
  pack v2 ──┼─> vfs diff ──> DiffPack ──>  vfs patch ──> pack v2 / overlay v2
  pack v3 ──┘   (v1->v2, v2->v3, v1->v3)   (单 diff 或 chain 合并一次到位)
~~~

目标：

~~~text
1. diff 产物是一个独立 libdb 目录（DiffPack），payload 以大 blob 存储。
2. 支持三种差分策略并可按 block 配置：
   L  逻辑文件 diff：对解压后 block 数据 hdiff，patch 后重新分页、压缩、写回。
   P  page diff：对压缩后 page payload hdiff，patch 后直接写回 page。
   R  raw replace：不 diff，整 page 替换。
3. patch 用 task graph 执行，CPU / 多线程 / 文件 IO / 内存全部作为可调预算。
4. v1->v2->v3 多 diff 一次展开为一张图、按 unit 合并，不产生中间版本写入。
5. 进程中途被杀可以直接重跑并快速收敛（幂等）。
6. 架构必须支撑“反复实验换局部方案”：所有策略点是数据/配置，不是分支硬编码。
~~~

非目标（V1）：

~~~text
1. 跨文件/跨 pack 全局匹配（重命名文件复用）。
2. 大逻辑文件流式 diff（block-digest）。
3. patch 与运行时读并发（需 generation-scoped key，见 §18）。
4. DirectoryManifest 语义 diff（V1 按 raw object 整体替换）。
5. 网络下载/断点续传（DiffPack 是普通文件，由外部下载器负责）。
~~~

---

## 2. 现状与可挂载点

| 现状 | 位置 | 对本设计的意义 |
|---|---|---|
| pack = libdb 目录 `manifest.db / index.db / data_000.db`；所有 VFS object 是 8B LE u64 key 的 KV | `src/db/kv_db.zig:87-124`，`src/vfs/object_key.zig` | DiffPack 直接复用 KvDb；patch 本质是“对目标 KV 集合做一组 put/delete” |
| `IndexInfo.data_db_id` 与 manifest data file 表已存在，但 KvDb 只打开 `data_000.db` | `src/db/format.zig:14-24`，`src/db/manifest.zig:74-101` | 多 data file 只需补 open/路由/写分发（§12.1） |
| `Batch` 独立于 `pending`，读不会触发其提交 | `src/db/batch_snapshot.zig:18-123`，`kv_db.zig:254-257` | patch 写路径必须走 `Batch`，不能用 `put`（否则 `prepareRead` 会在读旧 page 时强制提交） |
| `Batch.commit` 在全局 `batch_lock` 内做 data append | `batch_snapshot.zig:62-80` | 跨 shard 并行写被串行化，T0 必须重排（§12.1） |
| custom `file_ops` vtable + `InMemoryFileOps.FileSystem` | `src/db/platform/file.zig:15-57`，`inmemory_file_ops.zig` | DiffPack 以 in-memory fs 只读打开；目标 pack 支持外部 SDK hook |
| 只读 store 单 syscall 借用读 `getBorrowedBytes` | `kv_db.zig:299-304` | 读旧 page 的热路径 |
| `FileManifest.BlockDesc{codec, page_size, block_hash, flags}` + explicit `PageRef{pack_id, pack_generation, page_key, ...}` | `src/vfs/format/file_manifest.zig:19-53` | overlay 模式下未变化 page 指向 base pack 的既有机制 |
| `PageValue` 104B header 含 `codec/raw_size/stored_size/raw_crc/stored_crc/content_hash` | `src/vfs/format/page_value.zig:16-29` | P/R unit 直接携带新 header |
| whole-file `PatchManifest` + `merge_planner` + `mutation_executor` | `src/vfs/format/patch_manifest.zig`，`src/vfs/mutation/` | 被 DiffPack 取代；executor 迁移到新 task 框架后删除 |
| 静态预算调度器 `ResourceTaskGraph/scheduler/ResourceBudget` | `src/vfs/mutation/{task_graph,scheduler,resource_budget}.zig` | 被 `src/vfs/task/` 取代 |
| codec 仅 `none` 真实可用 | `src/vfs/compress/registry.zig` | lz4 前置（§13） |
| `db_checkpoint/optimize/recover` 在 custom ops 下 unsupported | `src/db/root.zig:44,72,83` | DiffPack 只读，不受影响；目标 pack 用 OS ops |
| DB 无 key scan；`checkpoint.collectLiveEntries` 可枚举 live record | `src/db/index/checkpoint.zig` | diff 侧枚举 pack 全部 object 的依据（§12.3） |

---

## 3. 术语

~~~text
Base pack          diff 的旧版本 pack（客户端当前版本）。
Target pack        diff 的新版本 pack（构建机产物；客户端 patch 后应等价于它）。
Overlay pack       为 readonly base 创建的 writable pack，挂载优先级高于 base，
                   PackManifest 记录 base 链接（§8.2）。
Logical view       patch 读取“旧数据”的视图：[overlay?, base] 按优先级解析，
                   与 Volume 的 EntryResolver 语义一致，但离线运行。
DiffPack           diff 产物，一个 libdb 目录。含 DiffManifest、UnitTable、
                   FileOpTable、PathDelta、Chunk。
DiffUnit           最小可独立 apply 且幂等的单位：一个 page（P/R）、一个 block（L）
                   或一个非 page object（manifest/tombstone）。
DiffStrategy       L | P | R，见 §5。
Shard              目标 pack 的一个 data file（data_NNN.db）。写、delete、flush 以
                   shard 为并行/批量单位。
Chunk              DiffPack 中一个 blob，连续存放同一 shard 若干 unit 的 payload。
PatchChain         有序 DiffPack 序列 v_a->v_b->...->v_z，在 plan 阶段合并为一份 PatchPlan。
PatchPlan          合并后的 unit 集合 + 文件级 op + path delta + 最终 PackManifest 参数。
PatchSession       一次 patch 的运行时对象：目标、chain、plan、task graph、统计。
PatchIntent        写入目标 pack 的 reserved object，标记“patch 进行中”（§14）。
~~~

---

## 4. 总体架构

### 4.1 分层

~~~text
tools/vfs.zig                       diff-pack / patch-pack / dump-diff / verify-diff / bench-patch
include/vfs.h                       vfs_patch_* 轮询式 ABI（V1.5）

src/vfs/diff/                       构建侧
  pack_scan.zig                     枚举 pack 全部 object（live entry -> u64 key -> 分类）
  diff_planner.zig                  object 级 diff -> 每 block 策略决议 -> DiffUnit 列表
  diff_engine.zig                   对 unit 生成 payload（L/P/R），试算与降级
  diff_pack_writer.zig              分 shard 排序、chunk 打包、写 DiffPack
  strategy.zig                      策略规则表、阈值、BuildCfg 覆盖

src/vfs/hdiff/                      hdiff 算法 zig 移植（纯算法，无 IO）
  sais.zig  match.zig  cover.zig  rle.zig  varint.zig  serialize.zig  patch.zig  diff.zig

src/vfs/patch/                      客户端侧
  diff_pack_reader.zig              打开 DiffPack（in-memory 或 disk）、解码表、chunk 访问
  chain.zig                         版本链解析、可用 DiffPack 选择
  coalesce.zig                      chain 合并 -> PatchPlan
  old_view.zig                      Logical view：旧 object 读取（overlay + base）
  shard_writer.zig                  每 shard 的 Batch 管理、批量 flush
  patch_session.zig                 会话、task graph 构建、执行、提交、resume
  overlay.zig                       overlay pack 创建/校验/PageRef 重写

src/vfs/task/                       通用任务框架（§10）
  graph.zig  resource.zig  scheduler.zig  worker_pool.zig  trace.zig

src/vfs/compress/lz4.zig            真实 lz4（§13）
src/db/                             多 data file、live entry 枚举、Batch 并行化（§12）
~~~

### 4.2 数据流

~~~text
diff:
  PackScan(base) ─┐
                  ├─> DiffPlanner ──> [DiffUnit...] ──> DiffEngine (task graph 并行)
  PackScan(target)┘        │                                  │
                           └── strategy.zig                   v
                                                   DiffPackWriter ──> DiffPack/

patch:
  DiffPack[] ──load(in-memory)──> chain.resolve ──> coalesce ──> PatchPlan
                                                                   │
  target (+overlay) ──open exclusive──> OldView / ShardWriter[]    │
                                                                   v
                                                   PatchSession.buildGraph ──> task.Scheduler
                                                                   │
                                     per unit: read_old -> apply -> stage ; per shard: commit_batch
                                     per file: build_manifest ; path_index ; pack_manifest_commit
~~~

---

## 5. 差分策略

### 5.1 三种策略

~~~text
L  logical-block diff
   diff 输入 : old_raw_block = concat(decompress(old pages of block))
              new_raw_block = concat(decompress(new pages of block))
   payload   : hdiff(old_raw_block -> new_raw_block)
   patch     : 读 block 全部旧 page -> 解压 -> hpatch -> 按新 BlockDesc.page_size 切页
              -> 用新 BlockDesc.codec 压缩每页 -> 构造 PageValue -> 写回
   precondition : old FileManifest.blocks[b].block_hash == unit.old_block_hash
   目标校验  : 新 raw block hash == unit.new_block_hash；每页 raw_crc 由本地计算写入
   适用      : codec 可运行时压缩（none / lz4）
   优点      : 对 raw 变化敏感度最好；precondition 基于 raw 内容，与 codec 实现无关
   代价      : patch 时 CPU（解压 + 压缩）与内存（2 × raw block）

P  page diff
   diff 输入 : old PageValue.payload（压缩后字节）
              new PageValue.payload
   payload   : [new PageValue header 104B][hdiff(old_payload -> new_payload)]
   patch     : 读旧 page record -> 校验 stored_crc -> hpatch -> 拼接 header -> 校验 -> 写回
   precondition : old stored_crc == unit.old_stored_crc && old stored_size == unit.old_stored_size
   适用      : codec 不可运行时压缩（zstd 高级别 / oodle）
   优点      : 无解压/压缩 CPU；单 page 内存
   代价      : 压缩流对 raw 小改动放大，diff 比例通常差；precondition 依赖“stored 字节完全一致”

R  raw replace
   payload   : [new PageValue header 104B][new payload 原样]
   patch     : 校验 -> 写回
   适用      : 新增 page / diff 不划算 / block 小于阈值 / 布局变化且 codec 不可运行时压缩
~~~

非 page object（FileManifest、EntryTombstone、DirectoryManifest、PathIndex）不做字节 diff，走 §7.3 文件级 op。

### 5.2 unit 粒度

~~~text
L  : unit = (file_entry, block_index)              -> 产出该 block 全部 page
P/R: unit = (file_entry, block_index, page_index)  -> 产出 1 page
del: unit = page_key                               -> delete 1 page KV
~~~

同一 block 内不允许 L 与 P/R 混用（L 已覆盖整个 block）。同一文件的不同 block 可以不同策略。

### 5.3 策略决议（D8）

决议在 **diff 时**完成；patch 端只执行 unit 描述符声明的策略，不做决策。

~~~text
输入: old BlockDesc?（新增 block 时为 null）, new BlockDesc, cfg override?, registry caps

1. cfg override 存在 -> 取 override 作为候选（仍受第 4 步硬约束）。
2. 否则按 codec 能力:
     caps(new.codec).runtime_compress == true  -> 候选 L
     else                                       -> 候选 P
3. 新增 block（old == null）:
     codec == none -> L(空 old)   # 等价于 lz4 传输压缩
     else          -> R
4. 硬约束降级:
     候选 P 且 (old.page_size != new.page_size || old.codec != new.codec)  -> caps.runtime_compress ? L : R
     候选 P 且 old page_count != new page_count -> 共有 page 走 P，多出的 page 走 R，减少的 delete
     候选 L 且 new.raw_size > max_diff_input_bytes -> 分段 L（§6.5），仍不可行 -> P 或 R
5. 试算降级（DiffEngine 实际生成 payload 后）:
     payload_size >= new_stored_size * replace_ratio (默认 0.9) -> R
     new_stored_size < min_diff_bytes (默认 4 KiB)              -> R
6. 记录最终策略与降级原因到 unit.flags（供 dump-diff 统计）。
~~~

`CodecCaps` 由 `compress/registry.zig` 提供：

~~~zig
pub const CodecCaps = struct {
    runtime_compress: bool,    // 客户端可在 patch 时压缩
    runtime_decompress: bool,  // 客户端可解压（none/lz4 真实，zstd/oodle 返回 unsupported）
    deterministic: bool,       // 相同输入产出相同字节（P 策略的前提）
    version_hash: u64,         // 实现版本标识
};
~~~

BuildCfg 扩展：

~~~text
default_diff_strategy=auto            # auto | logical | page | replace
file=/big.bin|1002|src.bin|65536|lz4|0|page    # 第 7 段为 diff_strategy 覆盖
~~~

### 5.4 覆盖 P 到运行时 codec 的风险

若 cfg 强制对 lz4 block 用 P，且该 block 在客户端曾被 L patch 重压缩过，则客户端 stored 字节来自客户端 lz4，构建机 stored 字节来自构建机 lz4。二者只有在 `CodecCaps.deterministic && version_hash` 一致时才相同。因此：

~~~text
1. P unit 记录 codec_version_hash；patch 时与 registry 不一致 -> error.CodecMismatch，不尝试 apply。
2. 自动规则不会对 runtime codec 选 P，正是为了避开这条路径。
3. dump-diff 对被覆盖为 P 的 runtime-codec block 输出警告。
~~~

---

## 6. hdiff 算法迁移（zig）

参照 HDiffPatch 的 `create_compressed_diff` / `patch_decompress` 算法结构移植，容器格式为本项目自定义（§6.4），不追求与 HDiffPatch 文件互操作。

### 6.1 模块

~~~text
src/vfs/hdiff/
  sais.zig       SA-IS 线性时间后缀数组（i32 索引，输入 ≤ 2^31-1）
  match.zig      基于 SA 的最长匹配搜索：lower_bound + LCP 扩展；
                 优先尝试 last_old_pos 邻近位置（保持 old 侧局部性）
  cover.zig      cover 选择与扩展：
                   - kMinMatchLen、kMinSingleMatchScore 过滤
                   - 前向/后向 extend（按字节相似度收益）
                   - 相邻 cover link 合并（old 侧近似连续、间隙代价低）
  rle.zig        subDiff RLE 编解码：ctrl 流（类型 2bit + 长度 varint）+ code 流
                 类型: run_0 | run_ff | run_byte | literal
  varint.zig     7-bit 变长整数；cover.old_pos 增量带符号位
  serialize.zig  组装 4 流：covers / rle_ctrl / rle_code / new_data_diff，各自可选 lz4
  patch.zig      流式 apply：按 cover 顺序，间隙拷贝 new_data_diff，
                 cover 区间 out[i] = old[old_pos+i] + sub[i]
  diff.zig       对外: diff(allocator, old, new, opts) ![]u8 ; patch(old, diff, out) !void
~~~

### 6.2 diff 流程

~~~text
diff(old, new):
  1. sa = sais(old)                              # 4·|old| 字节
  2. covers = []
     pos = 0; last_old = 0
     while pos < |new|:
       m = match.longest(sa, old, new, pos, prefer_near = last_old)
       if m.len >= kMinMatchLen: covers.push({m.old_pos, pos, m.len}); pos += m.len; last_old = m.old_pos + m.len
       else: pos += 1
  3. cover.dispose(covers, old, new):
       过滤 score < kMinSingleMatchScore 的孤立短 cover
       extend 前后边界；link 合并相邻 cover
  4. streams:
       cover_buf     = varint(Δold_pos 带符号, Δnew_pos, len) ...
       sub           = for cover: new[new_pos+i] - old[old_pos+i]  -> rle.encode -> ctrl, code
       new_data_diff = new 中未被 cover 覆盖的字节
  5. serialize(streams, compress = lz4 | none)
~~~

初始参数取 HDiffPatch 默认值（`kMinMatchLen`、`kMinSingleMatchScore`、link 阈值），全部作为 `DiffOptions` 字段暴露给实验。

### 6.3 patch 流程

~~~text
patch(old, diff, out):
  header 校验 -> 4 流各建 reader（lz4 流式解压到环形缓冲）
  new_pos = 0
  for cover in covers:
    copy new_data_diff -> out[new_pos .. cover.new_pos)
    for i in 0..cover.len: out[cover.new_pos+i] = old[cover.old_pos+i] +% rle.next()
    new_pos = cover.new_pos + cover.len
  copy 剩余 new_data_diff
  校验 out.len == header.new_size ；crc32c(out) == header.new_crc
~~~

patch 只需 old 随机访问、out 顺序写、固定大小 scratch；与 unit 大小无关的额外内存为 O(1)。

### 6.4 容器格式 VHDF

~~~text
[0]  magic u32 'VHDF'
[4]  version u16 = 1
[6]  flags u16          bit0 covers_lz4 bit1 ctrl_lz4 bit2 code_lz4 bit3 newdata_lz4
[8]  old_size u64
[16] new_size u64
[24] new_crc u32 (crc32c of new)
[28] cover_count u32
[32] 4 × { raw_size u32, stored_size u32 }   # covers, rle_ctrl, rle_code, new_data_diff
[64] header_crc u32
[68] streams...
~~~

### 6.5 内存与分段（D3）

~~~text
单次 diff 内存 ≈ |old| + |new| + 4·|old|（SA）+ covers。
max_diff_input_bytes 默认 64 MiB（可配）。

block raw_size > max_diff_input_bytes 时的 L 分段:
  以 page 边界切成 segment_i（默认 16 MiB），old segment 取相同 raw 偏移 ± window（默认 4 MiB）；
  每段独立 VHDF；unit.flags |= SEGMENTED，
  payload = [segment_count u32][each: raw_off u64, raw_len u64, vhdf_len u32, vhdf]
  patch 时按段 apply 后拼接，再统一分页压缩。
~~~

diff 阶段多个 unit 并行由 task 框架承担；单 unit 内 SA 构建单线程。

### 6.6 测试

~~~text
1. 随机数据 roundtrip：patch(old, diff(old,new)) == new，尺寸 0..8 MiB，覆盖 old 为空、new 为空、完全相同、完全不同。
2. 结构化数据（插入/删除/移动块）diff 比例回归阈值。
3. 损坏 VHDF（每个字段位翻转）必须返回错误，不越界。
4. sais 与朴素排序在小输入上一致性对拍。
5. rle 编解码枯竭/溢出边界。
~~~

---

## 7. DiffPack 格式

### 7.1 目录与 key

DiffPack 是一个 libdb 目录，使用 KvDb 默认参数创建，只有 1 个 data file（in-memory 整体加载时不需要 shard 并行）。

~~~text
diffManifestKey()          = hash64("vfs.diff.singleton.v1", "diff-manifest")
diffFileOpTableKey()       = hash64("vfs.diff.singleton.v1", "file-op-table")
diffPathDeltaKey()         = hash64("vfs.diff.singleton.v1", "path-delta")
diffUnitTableKey(shard)    = hashIdentity1("vfs.diff.unit-table.v1", shard)
diffChunkKey(chunk_id)     = hashIdentity1("vfs.diff.chunk.v1", chunk_id)
~~~

新增 namespace 集中在 `object_key.zig`，并加入 reserved key 冲突检查。

### 7.2 DiffManifest（"VDFM"）

~~~text
[0]   magic u32 'VDFM'
[4]   version u16 = 1
[6]   header_size u16
[8]   diff_id u64                 # 随机派生，唯一标识本 DiffPack
[16]  target_pack_id u64
[24]  base_pack_version u64       # from
[32]  target_pack_version u64     # to
[40]  target_build_id u64
[48]  flags u32                   # bit0 has_path_delta bit1 has_directory_manifest
[52]  shard_hint_count u32        # diff 时使用的分组 shard 数（§7.6）
[56]  unit_count u64
[64]  chunk_count u32
[68]  chunk_nominal_bytes u32
[72]  file_op_count u64
[80]  target_file_count u64       # 写入最终 PackManifest
[88]  target_tombstone_count u64
[96]  base_content_hash [32]      # base PackManifest.content_hash
[128] target_content_hash [32]    # target PackManifest.content_hash（最终写入）
[160] payload_total_bytes u64
[168] tool_version_hash u64
[176] hdiff_options_hash u64
[184] manifest_crc u32
~~~

### 7.3 FileOpTable（"VDFO"）

文件级 op 由 base/target 的 object 级差异直接推导，不做语义猜测：

~~~text
FileOp (112B)
  op u8: put_file_manifest | delete_file_manifest | put_entry_tombstone | delete_entry_tombstone
       | put_directory_manifest
  file_entry u64
  old_file_version u64 / new_file_version u64
  old_content_hash [32] / new_content_hash [32]
  payload_ref { chunk_id u32, offset u32, len u32 }   # put_* 的完整编码 object（原样自 target）
~~~

`put_file_manifest` 的 payload 是 target pack 中 FileManifest 的原始编码。patch 端在 overlay 模式重写为 explicit PageRef（§8.2），in-place 模式原样写入。

### 7.4 UnitTable（"VDUT"，每 shard 一个 blob）

~~~text
UnitTableHeader: magic 'VDUT' | version u16 | header_size u16 | shard u32 | unit_count u32 | crc u32
UnitDesc (128B 固定):
  [0]   kind u8        : put_page_raw | put_page_pdelta | put_block_ldelta | delete_page
  [1]   strategy u8    : L | P | R | none
  [2]   codec u16      : 新 page/block codec
  [4]   flags u32      : SEGMENTED | DOWNGRADED_RATIO | DOWNGRADED_LAYOUT | CFG_OVERRIDE
  [8]   file_entry u64
  [16]  block_index u32
  [20]  page_index u32      # L 时为 0
  [24]  page_count u32      # L: 新 block 的 page 数；P/R: 1
  [28]  old_stored_size u32 # P
  [32]  old_stored_crc u32  # P precondition
  [36]  new_stored_crc u32  # P/R 幂等判定
  [40]  old_block_hash [32] # L precondition
  [72]  new_block_hash [32] # L 幂等判定与结果校验
  [104] codec_version_hash u64  # P
  [112] payload chunk_id u32
  [116] payload offset u32
  [120] payload len u32
  [124] reserved u32 = 0
~~~

unit 在表内按 apply 推荐顺序排列（§7.6）。

### 7.5 PathDelta（"VDPI"）与 Chunk（"VDCK"）

~~~text
PathDelta
  header: magic | version | add_count u32 | remove_count u32 | string_size u32 | crc
  add[]    : { file_entry u64, path_off u32, path_len u32, flags u32 }
  remove[] : { path_hash u64, path_off u32, path_len u32 }
  strings
  说明: 由 base/target PathIndex 全量对比得出。patch 时 old PathIndex + delta -> 重编码。
        chain 合并时 add/remove 按顺序 fold。

Chunk
  header 32B: magic 'VDCK' | version u16 | header_size u16 | chunk_id u32 | shard u32
             | payload_bytes u32 | payload_crc u32 | reserved
  payload   : unit payload 按 apply 顺序紧密排列，每个 unit 起点 16B 对齐
  nominal 大小 8 MiB（可配 1..64 MiB）；单个 unit payload 超过 nominal 时独占一个更大的 chunk。
~~~

### 7.6 shard 分组与排序

diff 时 base 与 target 是构建机上的 pack，其 data file 数不一定等于客户端目标 pack 的 data file 数。因此 DiffPack 中的 "shard" 是 **分组提示**：

~~~text
shard_hint(unit) = object_key.fileShard(file_entry, shard_hint_count)
                 = wyhash(file_entry) % shard_hint_count      (file_entry == 0 或单 shard 时为 0)
shard_hint_count = target pack 的 data file 数（构建时 BuildCfg 指定）
~~~

分组按 **file_entry** 而不是按 page key：PackWriter（构建）与 ShardWriter（patch）都用同一函数放置一个文件的全部对象（page、FileManifest、tombstone），于是

- 一个 apply unit（一个 page 链，或一个 block 的复合链）的所有写入落在同一 shard 的同一 Batch，要么全部提交要么全不提交——幂等续跑（§11.3）依赖这一点；
- 一个文件的 page 在 data file 中物理相邻，L 单元读旧 block 时局部性好。

KvDb 本身按 `IndexInfo.data_db_id` 路由读取，这只是放置策略而非查找规则：目标 pack 与 target pack 的 data file 数不一致时仍正确，仅失去 chunk 与写流水线的一一对应。

同一 shard 内 unit 排序：

~~~text
1. file_entry 升序（同一文件 page 连续，读旧 page 时 index 局部性好）
2. block_index、page_index 升序
3. delete_page 排最后
~~~

---

## 8. 目标形态与写入模式（D1）

### 8.1 in-place（writable pack）

~~~text
目标 = base pack 自身。
put/delete 直接落到该 KvDb；PackManifest 最后提交。
patch 完成后 pack_version = target_pack_version，pack 与构建机 target 在 object 集合上等价
（record 物理布局不同，checkpoint/optimize 后 index 亦等价）。
~~~

### 8.2 overlay（readonly pack）

~~~text
目标 = overlay pack（新建或已存在），挂载优先级 > base。
PackManifest.flags |= PACK_FLAG_OVERLAY
PackManifest 新增字段（版本 2，header_size 108 -> 132）:
  base_pack_id u64        # 必须等于自身 pack_id（同一逻辑 pack 的不同物理层）
  base_pack_version u64   # overlay 建立时 base 的版本
  base_pack_generation u64
  overlay_flags u32
~~~

overlay 语义：

~~~text
1. overlay.pack_id == base.pack_id；Volume 允许同 pack_id 多 mount，pack_generation 区分。
2. 变化的 page 写入 overlay（page_key 相同，overlay 先命中）。
3. FileManifest 写入 overlay 时，被 patch 触及的 block 的每个 page 必须能被解析：
     - 该 page 本次写入 overlay         -> implicit key 可用（同 pack_id，overlay 命中）
     - 该 page 未变化、仍在 base        -> implicit key 同样命中 base（FileHandle 用 file 的
                                          pack_id/pack_generation 定位 store；两层同 pack_id）
   因此 overlay 模式下 **不需要重写为 explicit PageRef**，前提是 EntryResolver 对同 pack_id
   多层按 generation 逐层回退查找 page。这是 §12.4 的 Volume 改动。
4. delete_page unit 在 overlay 模式下变为 **写 PagePlaceholder**（一个 40B "VPHD" 标记 value），
   使 overlay 命中并报告 NotFound，屏蔽 base 中的旧 page。
   （只在 block page_count 缩小时出现；文件删除走 EntryTombstone，不需要逐 page 屏蔽。）
5. overlay 上再 patch（v2->v3）：目标仍是同一 overlay，in-place 写；OldView 仍是 [overlay, base]。
6. overlay 可 rebase：base 被整包更新（如 apk 升级）后 overlay 失效，检测到
   base.pack_version != overlay.base_pack_version 时 Volume 拒绝挂载该 overlay。
~~~

PagePlaceholder 是新增 object 类型：

~~~text
"VPHD" 40B: magic | version | file_entry u64 | block_index u32 | page_index u32 | reason u32 | crc
读取端：解析到 PagePlaceholder 视为该 page 在本层被删除，不再回退下层。
~~~

### 8.3 OldView

~~~text
OldView.readPage(page_key, identity) ![]const u8:
  for layer in [overlay?, base]:
    bytes = layer.reader.readObjectBorrow(page_key) catch NotFound -> continue
    if isPlaceholder(bytes) return error.NotFound
    return bytes
  return error.NotFound

OldView.readFileManifest / readObject 同理。
~~~

in-place 模式 OldView 只有一层，且与写目标是同一 KvDb（读走 delta+base index，Batch 未提交内容不可见，天然是"旧视图"）。

---

## 9. Patch 流程

### 9.1 阶段

~~~text
P0 open
   打开目标 pack（KvDb read_write，exclusive lock 文件 `.vfs_patch.lock`）
   overlay 模式：打开/创建 overlay，打开 base 只读
   校验 PackManifest.pack_id、pack_version ∈ chain.from
   读 PatchIntent（若存在：上次未完成，进入 resume 语义，§14）

P1 load diffs
   每个 DiffPack 以 InMemoryFileOps(writeback=false) 只读打开（预算内），否则 disk 只读打开
   解码 DiffManifest、FileOpTable、PathDelta、每 shard UnitTable（chunk 按需）

P2 chain + coalesce  (§11)
   -> PatchPlan{ units_by_shard[], file_ops[], path_delta, final_manifest_params }

P3 build graph  (§9.2)

P4 run
   写 PatchIntent{ diff_ids, from, to, started_at }（单独 Batch 提交）
   scheduler.run(graph)

P5 finalize
   PathIndex 重编码 -> PackManifest（pack_version = to）与 PatchIntent 删除 在**同一个 Batch** 提交
   可选 optimize / verify

P6 close
   释放锁；Volume 若在线则 refresh mount generation
~~~

### 9.2 Task 图

节点类型（`TaskKind`）与资源类：

~~~text
load_chunk(shard, chunk_id)            io_read, mem=chunk_bytes     # disk 模式才有；in-memory 模式为 no-op
apply_unit(unit)                       cpu_diff | cpu_codec, mem     # 读旧、hpatch、(解压/压缩)、构造 value、校验、stage
stage -> commit_batch(shard, seq)      io_write, db_write(shard)     # 将 staged ops 以 Batch 提交到 shard
delete_batch(shard)                    db_write(shard)               # 该 shard 全部 delete/placeholder 一次提交
file_op(file_entry)                    db_write(shard_of(manifest_key))
path_index                             cpu, db_write
commit_manifest                        pack_exclusive
optimize / verify                      pack_exclusive（可选）
~~~

依赖：

~~~text
load_chunk(c) -> apply_unit(u) ∀ u.payload.chunk == c        (disk 模式)
apply_unit(u) -> commit_batch(shard(u), seq(u))              # seq 按 batch 水位切分
commit_batch(s, k) -> commit_batch(s, k+1)                    # 同 shard 串行
∀ commit_batch(s,*), delete_batch(s) -> file_op(f)  当 f 的 page 落在 s     # 保证 manifest 提交时 page 已落盘
∀ file_op -> path_index -> commit_manifest -> [optimize] -> [verify]
~~~

batch 水位：

~~~text
ShardWriter(s) 收集 staged ops；当 staged_bytes >= batch_bytes(默认 16 MiB) 或 staged_ops >= batch_ops(默认 2048)
时封装为 commit_batch(s, k) 节点并**动态加入图**（需要 task 框架支持运行中 addTask）。
最后一个 batch 在该 shard 全部 apply_unit 完成后由 drain 逻辑补发。
durability: 中间 batch .none（只写不 fsync），每 shard 每 flush_every_n_batches(默认 4) 次 .async，
finalize 前所有 shard .sync。若崩溃，未 sync 的 batch 靠 DB journal 恢复或丢弃，幂等重跑补齐。
~~~

优先级（关键路径近似）：

~~~text
priority(apply_unit) = remaining_bytes_of_shard(s) 大者优先（使各 shard 尾部对齐）
                     + L unit 加权（CPU 重）
priority(commit_batch) > apply_unit                （尽早释放 staged 内存）
priority(load_chunk)  按 chunk 内 unit 数量
~~~

### 9.3 apply_unit 细节

~~~text
R  put_page_raw:
   1. 幂等检查：OldView.readPage 成功 && stored_crc == unit.new_stored_crc -> skip（统计 skipped）
   2. decodePageValue(payload, identity) 全校验
   3. stage put(page_key, payload)

P  put_page_pdelta:
   1. 幂等检查同 R
   2. old = OldView.readPage；decode；stored_crc == unit.old_stored_crc 否则 error.PreconditionFailed
   3. codec_version_hash 校验（§5.4）
   4. new_payload = hpatch(old.payload, vhdf)；拼 header；decodePageValue 全校验（含 stored_crc）
   5. stage put

L  put_block_ldelta:
   1. old_manifest = OldView.readFileManifest(file_entry)（缓存于 session，按 file_entry 共享）
   2. 幂等检查：若 OldView 中该 block 全部 new page 存在且 block 内 page raw_crc 序列 hash == new_block_hash -> skip
      （代价：读 page_count 个 record header，不解压。raw_crc 在 PageValue header 里。）
   3. precondition：old_manifest.blocks[b].block_hash == unit.old_block_hash
   4. old_raw = concat(decompress(OldView.readPage(p)) for p in old block pages)   # mem = old.raw_size
   5. new_raw = hpatch(old_raw, vhdf)（分段时逐段）；sha256(new_raw) == new_block_hash
   6. 分页：for i in 0..page_count: raw_i = new_raw[i*ps..]; payload_i = compress(codec, raw_i)
      构造 PageValue(codec, raw_size, stored_size, raw_crc, stored_crc, content_hash)
   7. stage put × page_count
   8. old page_count > new page_count 时，多余 page 由 planner 已生成 delete_page unit

delete_page:
   in-place: stage delete(page_key)
   overlay : stage put(page_key, PagePlaceholder)
   幂等：目标已不存在 / 已是 placeholder -> skip
~~~

staged op 的内存计入 `mem` 资源；`ShardWriter.stage` 满水位时返回 `WouldBlock`，任务框架把该 apply_unit 重新排队而不是阻塞 worker（§10.4）。

### 9.4 file_op 与 finalize

~~~text
put_file_manifest:   幂等（目标已存在且 bytes 相等 -> skip）；Batch put
delete_file_manifest: Batch delete（overlay: 写 EntryTombstone 即可，不删 manifest）
put_entry_tombstone / delete_entry_tombstone: 同上
path_index:          old = OldView.readObject(pathIndexKey) -> collectEntries -> apply PathDelta
                     -> encodePathIndex -> 与 commit_manifest 同一 Batch
commit_manifest:     Batch{ put(pathIndexKey), put(packManifestKey, {pack_version=to, build_id, file_count,
                     tombstone_count, content_hash=target_content_hash, overlay 字段}), delete(patchIntentKey) }
                     .sync 提交
~~~

commit_manifest 是唯一使更新"对外可见"的点：在此之前 pack_version 仍是 from，Volume 挂载读到的是旧视图（已写入但未被 manifest 引用的 page 对读者不可见，因为 FileManifest 仍指向旧 block 布局——但 **implicit key 相同的 page 会被覆盖**，见 §18 并发读限制）。

---

## 10. 通用 Task 框架 `src/vfs/task/`（D5）

### 10.1 目标

~~~text
1. O(1) 摊销的 ready 发现（入度计数，不扫描全表）。
2. 按资源类分 ready 队列，每队列按 priority 堆排。
3. 资源预算：计数型（io_read/io_write/cpu/db_write[shard]）+ 字节型（mem）+ 互斥型（pack_exclusive/pack_shared）。
4. typed payload：任务携带 `*anyopaque` + kind，executor 按 kind 解释。
5. 运行中动态 addTask/addDependency（依赖对象必须尚未 finished，否则立即视为满足）。
6. 任务可返回 `.yield`（资源暂不可得，回队列）而不是阻塞。
7. 取消：失败任务级联 cancel 其 users；session 级 cancel 标志。
8. 统计：每 kind 计数/耗时/字节；dispatch trace 可导出（bench 与实验用）。
9. worker pool 生命周期独立于单次 run，可复用。
~~~

### 10.2 API

~~~zig
pub const TaskId = u32;
pub const ResourceClass = enum(u8) { io_read, io_write, cpu, cpu_codec, db_write, pack_exclusive, _ };

pub const Need = struct {
    io_read: u8 = 0, io_write: u8 = 0, cpu: u8 = 0, cpu_codec: u8 = 0,
    db_write_shard: ?u16 = null,          // 占用该 shard 的写令牌（每 shard 1）
    mem_bytes: u64 = 0,
    pack_exclusive: bool = false, pack_shared: bool = false,
};

pub const TaskDesc = struct {
    kind: u16,                   // 使用方定义的枚举值
    payload: ?*anyopaque = null,
    need: Need = .{},
    priority: i32 = 0,
    label_file_entry: u64 = 0, label_index: u32 = 0,   // trace 用
};

pub const RunResult = enum { done, yield };

pub const Executor = struct {
    context: *anyopaque,
    run: *const fn (ctx: *anyopaque, graph: *Graph, id: TaskId, desc: TaskDesc) anyerror!RunResult,
};

pub const Budget = struct {
    io_read: u8 = 4, io_write: u8 = 2, cpu: u8 = 0 /* 0=ncpu-1 */, cpu_codec: u8 = 0,
    db_write_per_shard: u8 = 1, mem_bytes: u64 = 256 << 20, pack_exclusive: u8 = 1,
    worker_threads: u8 = 0 /* 0=auto */,
};

pub const Graph = struct {
    pub fn init(allocator) Graph;
    pub fn addTask(self, desc: TaskDesc) !TaskId;                  // 运行中可调用（内部加锁）
    pub fn addDependency(self, before: TaskId, after: TaskId) !void;
    pub fn cancel(self) void;
    pub fn stats(self) Stats;
};

pub const Scheduler = struct {
    pub fn init(allocator, budget: Budget) !Scheduler;              // 建 worker pool
    pub fn run(self, graph: *Graph, executor: Executor, opts: RunOptions) !Report;
    pub fn deinit(self) void;
};
~~~

### 10.3 内部结构

~~~text
Task slot: { desc, state: atomic u8, remaining_deps: atomic u32, users: SegmentedList(TaskId), started_ns, finished_ns }
Ready queues: 每 ResourceClass 一个 binary heap（按 priority）；任务归入其 need 中"最稀缺"资源类队列
              （启发式：db_write_shard > cpu_codec > io_write > io_read > cpu）
Token pools:  计数信号量数组 + shard 写令牌位图 + mem 计数器 + pack 互斥状态
Dispatcher:   单线程循环：pop 最高优先级可满足的任务 -> acquire -> 投递 worker；
              worker 完成 -> release -> 递减 users.remaining_deps -> 为 0 则 push ready
              yield -> release -> 重新 push（priority -1 防止饥饿）
Worker pool:  N 线程，MPMC 队列；线程复用；worker 内不阻塞在资源上
Trace:        ring buffer of {task_id, kind, t_dispatch, t_start, t_end, thread}，可 dump 为 JSON（bench）
~~~

### 10.4 yield 语义

`ShardWriter.stage` 满水位、in-memory chunk 未加载完等情况返回 `WouldBlock`，executor 转为 `.yield`。调度器将其放回队列并优先调度能释放该资源的任务（commit_batch）。避免 worker 空转持锁。

### 10.5 迁移

~~~text
pack_builder.buildTaskGraphForPlan / mutation_executor.buildTaskGraph -> 用新 Graph API 重写
mutation_executor 整体由 patch_session 取代（whole-file PatchManifest 路径废弃，§17）
删除 src/vfs/mutation/{task_graph,scheduler,resource_budget}.zig 及其测试，
等价测试迁入 src/vfs/task/*.zig（线性依赖、预算上限、失败级联、并发执行、内存预算、动态加任务、yield）
~~~

---

## 11. PatchChain 与 Coalesce

### 11.1 chain 选择

~~~text
输入: from_version（目标 pack 当前）、to_version（期望）、可用 DiffPack 列表（本地目录扫描或外部给定路径）
构图: 版本为节点，DiffPack 为边 (base->target)，边权 = payload_total_bytes
选择: Dijkstra 最小总 payload 的路径；无路径 -> error.NoPatchPath
输出: 有序 DiffPack 列表 [d1, d2, ..., dn]，d1.base == from，dn.target == to
~~~

若存在直达 diff v1->v3，通常权重更小自然被选中；若只有 v1->v2、v2->v3，则两者合并。

### 11.2 unit 合并规则

以 `(file_entry, block_index, page_index)`（P/R/delete）或 `(file_entry, block_index)`（L）为 key，按 chain 顺序 fold：

~~~text
状态 S(key) 初始 = none

fold(S, u):
  R      : S = R(u)                                # 后者完全覆盖
  delete : S = delete(u)
  P      : S == none      -> P(u)
           S == R(v)      -> R(apply_P_at_plan_time(v, u))   # plan 阶段直接算出新 raw，代价小（单 page）
           S == P(v)      -> chain P: 记录 [v, u] 序列，apply 时顺序 hpatch（不在 plan 阶段合并 VHDF）
           S == delete    -> 非法（diff 一致性错误）
  L      : 对该 block 的全部 page key:
           S(block) == none        -> L(u)
           S(block) == L(v)        -> chain L: [v, u]，apply 时顺序 hpatch raw
           S(block) 有 P/R/delete  -> 先按 v 的 page 级结果在 apply 时构成 old_raw（需要那些 page 的最终结果）
                                      简化: 若 block 上已有任何 page 级 state，则 apply 时先按旧 chain 求出
                                      该 block 全部 page 的 raw，再做 L(u)。实现为 apply_unit 的 "composite" 输入。
  P/R 遇到 S(block) == L(v)      -> 同理 composite：先 L(v) 得 raw block，压缩得 page，再 P/R(u)
~~~

合并后每个 key 只有一个 apply_unit（可能带 chain），因此 v1->v3 只写一次，不产生中间版本 IO。

precondition 取 chain 首个 unit 的 old_*；幂等判定取最后一个 unit 的 new_*。

实现（`patch/coalesce.zig` + `patch/patch_session.zig`）把上表收敛为两种 apply_unit：

~~~text
按 (file_entry, block_index) 收集全部 step，同一 diff 内排序 L < P/R < delete（再按 page_index）。
block 链中没有 L  -> 每个 page 一个 unit，携带该 page 的 step 链；后到的 R/delete 丢弃更早的 step。
block 链中有 L    -> 一个 composite unit：apply 时在内存页集合上按序回放整条链
                     （L 读 "页 0.. 直到缺页" 组成 old_raw 并校验 old_block_hash；
                      R/P/delete 直接改页集合），最后一次性输出该 block 的 put/delete。
~~~

幂等判定不需要 hpatch：per-page unit 比较 target 层该页 stored_crc 与末 step 的 new_stored_crc；
composite unit 由 step 链推出每页的期望终态（absent / stored_crc / 属于某个 L 的输出），
再用 target 层页头（raw_crc 序列哈希 == L.new_stored_crc）逐一比对。任一不符即整单元重算。

### 11.3 file_op / path_delta 合并

~~~text
file_op: 同 file_entry 取最后一个 op；put 后 delete -> delete；delete 后 put -> put
path_delta: add/remove 按顺序 fold 到一个 map<path, ?file_entry>
final_manifest_params: 取最后一个 DiffManifest 的 target_*；
                       校验 chain 首 base_content_hash == 目标当前 PackManifest.content_hash
~~~

---

## 12. DB 与 VFS 底层前置改动

### 12.1 DB 多 data file（D2）

~~~text
格式: 无变化（manifest data file 表、IndexInfo.data_db_id、data_NNN.db 命名均已存在）。

KvDb:
  data: []DataFile（按 manifest 表顺序）；data_db_id -> 数组下标
  OpenOptions.data_file_count: u32 = 0    # create 时初始 data file 数；open 时忽略
  OpenOptions.shard_fn: ?ShardFn          # 默认 shard = mixHash128To64(key) % n
  lookupInfo/getInto/getBorrowedBytes: 用 info.data_db_id 选 DataFile
  Batch: 
    - 新增 Batch.begin(db, allocator, .{ .shard = ?u16 })：指定后所有 put 必须落在该 shard（debug 断言）
    - commit 拆为: (a) per-shard data append（各自 append_mutex，不持 batch_lock）
                    (b) 持 batch_lock：journal begin/appendMany/commit + delta publish
      跨 shard Batch 并行 commit 时 (a) 完全并行，(b) 短临界区。
  checkpoint/optimize/verify/recover: 遍历全部 data file；optimize 每 data file 独立截尾
  relocation: 同 data_db_id 内 relocate

C ABI: db_open_options_t 新增 data_file_count（struct_size 兼容）
tools/db.zig: dump_manifest 列出 data files

测试: 多 shard put/get/delete roundtrip；崩溃矩阵扩展到多 data file；并行 Batch commit 压测
~~~

### 12.2 in-memory 只读打开加速

`InMemoryFileOps.getOrLoad` 目前用单线程 `readPositionalAll` 整文件读入。补充：

~~~text
FileSystem.init(allocator, .{ .writeback, .preload_paths: []const []const u8, .parallel = true })
预加载列表内的文件按 ≥ 8 MiB 分片并行读（使用 task 框架的 io_read 预算）。
DiffPack 打开时 preload = [manifest.db, index.db, data_000.db]。
~~~

### 12.3 live entry 枚举 API

`checkpoint.collectLiveEntries(db)` 目前为内部函数。提升为 `KvDb.collectLiveKeys(allocator) ![]LiveEntry{ key: Key128, info: IndexInfo }`，并在 record 中读回 raw key bytes（8B u64）。diff 侧 `pack_scan` 以此枚举 pack 全部 object 并按 `object_key` namespace 反推类型：无法反推的 key 需 FileManifest 提供 identity —— 因此 pack_scan 的正确做法是：

~~~text
1. 读 PackManifest、PathIndex。
2. 枚举 live keys -> 集合 K。
3. 对每个 FileManifest key（通过 fileManifestKey(file_entry) 反查：从 PathIndex + tombstone 无法覆盖所有 entry）
   -> 改为：对 K 中每个 value 读 header magic 分类（VFMF/VPAG/VETS/VPTH/VDIR/VPHD），identity 在 header 内。
   读 header 只需 104B，DB 单 syscall 借用读；百万 object 级别可接受，且 diff 只在构建机运行。
~~~

### 12.4 Volume：同 pack_id 多层与 PagePlaceholder

~~~text
1. mountPack 允许同 pack_id 多个 mount，要求 flags 含 OVERLAY 且 PackManifest.base_pack_id == pack_id，
   base_pack_version 与已挂载 base 一致；priority 必须高于 base。
2. FileHandle.readAt 的 PageSource 解析：pinStoreMounted(pack_id, generation) 找不到精确 generation
   时，按 priority 从高到低在同 pack_id 层中逐层 readObjectBorrow，NotFound 继续下一层，
   PagePlaceholder 视为 NotFound 终止。
3. PageCacheKey 已含 pack_generation，overlay 提交后 generation 变化，缓存自然失效。
4. resolveVisibleFile: FileManifest 同样逐层解析。
~~~

---

## 13. lz4 codec（D6）

~~~text
src/vfs/compress/lz4.zig
  compressBound(n) usize
  compressBlock(src, dst, level) !usize          # level 0..12 影响 hash 表搜索深度；纯 zig，无 xxhash frame
  decompressBlock(src, dst, raw_size) !usize      # 严格边界检查，损坏输入返回 error.Corruption
  caps: { runtime_compress = true, runtime_decompress = true, deterministic = true, version_hash = hash("lz4-zig-1") }

registry.zig: codecIdentity/decompressPage/compressPage 接入 lz4；zstd 返回 caps.runtime_compress=false
build_plan.zig: codec=lz4 不再报 UnsupportedFeature
file_handle.zig: 移除 `block.codec != .none -> Unsupported`
PageValue: codec/raw_size/stored_size/raw_crc/stored_crc 已完备

测试: 与已知向量对拍（内嵌几组 lz4 官方 block 测试向量字节）、随机 roundtrip、损坏输入、
      compress 确定性（同输入同输出）、pack 构建 + 读回 lz4 pack
~~~

---

## 14. 崩溃恢复与幂等（D4）

~~~text
不变量:
  I1 每个 Batch 原子（DB journal 保证）。
  I2 PackManifest.pack_version == to 当且仅当全部 unit/file_op/path_index 已提交（同一 Batch）。
  I3 apply_unit 幂等：目标已到位则 skip；未到位则 precondition 必须成立。

崩溃时刻 -> 重跑行为:
  P0-P3 崩溃            : 无写入，直接重跑。
  P4 中崩溃             : 部分 Batch 已提交（pack_version 仍为 from，PatchIntent 存在）。
                         重跑 P0 读到 PatchIntent{diff_ids, from, to}：
                           - chain 必须与 intent 一致（否则 error.PatchIntentMismatch，需 --force 清除）
                           - 全部 unit 重跑；已提交的命中幂等 skip（读 header 级校验，不解压不 hpatch）
                           - 未提交的 unit：old 仍是 from 版本，precondition 成立，正常 apply
                         代价 = O(unit 数 × header 读)，无进度表。
  P5 崩溃（finalize Batch 未提交）: 同 P4。
  P5 已提交后崩溃       : pack_version == to，PatchIntent 已删除；重跑 P0 发现 from != 当前 -> 无事可做。

危险场景与防护:
  A. in-place 模式下 unit X 已提交，unit Y 未提交，且 Y 的 L precondition 依赖 X 所在 block 的旧 raw？
     不可能：L unit 以 block 为单位，X 与 Y 不会同属一个 block；P 的 precondition 是本 page 的 old stored_crc。
     同一 key 只有一个 unit（coalesce 保证）。
  B. 用户在 P4 崩溃后换了另一条 chain（如 v1->v3 直达）：PatchIntent 不一致，拒绝；--force 时仅允许
     to 相同的 chain（已提交 page 的 new_* 相同，幂等仍成立）。to 不同必须先完成或回滚原 chain；
     V1 不实现回滚，提示重新获取原 DiffPack。
  C. overlay 模式 base 被替换：§8.2 第 6 条。
  D. 电源故障导致 .none durability 的 batch 丢失：DB 恢复丢弃未 commit 的 journal batch；
     被丢弃的 unit 在重跑时 precondition 成立，正常 apply。
~~~

PatchIntent object：

~~~text
patchIntentKey() = hash64("vfs.object.singleton.v1", "patch-intent")   # 加入 reservedKeys
"VPIN" : magic | version | from_version u64 | to_version u64 | chain_len u32 | diff_id[chain_len] u64
       | started_unix_ms u64 | tool_version_hash u64 | crc
~~~

---

## 15. 资源策略与实验点

所有策略点在 `PatchOptions` 中显式可配，工具 `bench-patch` 可对一组配置矩阵跑出报告：

~~~zig
pub const PatchOptions = struct {
    budget: task.Budget = .{},
    diff_load: enum { auto, in_memory, disk } = .auto,
    in_memory_max_bytes: u64 = 512 << 20,        // DiffPack 总大小 ≤ 此值才整体加载
    batch_bytes: u32 = 16 << 20,
    batch_ops: u32 = 2048,
    flush_every_n_batches: u16 = 4,
    intermediate_durability: Durability = .none,
    idempotent_check: enum { header, full, off } = .header,   // off: 不检查直接重写（首次 patch 可关）
    optimize_after: bool = false,
    verify_after: enum { none, touched, full } = .touched,
    read_handles: u8 = 4,                         // OldView 每层 store 的并行读句柄
    target_file_ops: ?CustomFileOps = null,       // Android/iOS SDK hook
    trace: bool = false,
};
~~~

预期实验清单（各自独立可切）：

~~~text
E1 diff_load in_memory vs disk               —— 内存换 IO 的收益边界
E2 batch_bytes 4/16/64 MiB                    —— DB commit 次数 vs staged 内存
E3 intermediate_durability none/async         —— fsync 代价 vs 崩溃后重跑量
E4 cpu_codec 并发 vs io_write 并发            —— L 策略 CPU/IO 平衡
E5 shard 数 1/2/4/8                           —— 多 data file 并行写收益
E6 idempotent_check header vs off             —— 首次 patch 的额外读代价
E7 optimize_after                             —— patch 后读性能 vs patch 时长
E8 unit 排序 file_entry 顺序 vs 随机          —— OldView 读局部性
~~~

`verify_after = touched`：只校验本次写入的 page（decode + crc + identity）；`full` 在 store 关闭后再走一遍 `pack_tools.verifyPack`（PackManifest / PathIndex / 全部 object）。

实现状态（与设计的差异）：

- `PatchOptions` 实际字段：`budget / diff_load / in_memory_max_bytes / writer{batch_bytes,batch_ops,max_staged_bytes,intermediate_durability} / idempotent_check{header,off} / verify_after{none,touched,full} / optimize_after / force / overlay_shards / trace / trace_path / progress`。未实现 `idempotent_check=full`、`read_handles`、`target_file_ops`（in-memory 目标）。
- DiffPackReader 的 chunk 缓存按 pin 计数 + `chunk_cache_bytes`（默认 64 MiB）淘汰：`payload()` 借出期间 pin，`unpinPayload()` 后超预算即按插入序淘汰，`.disk` 模式常驻内存有上界。
- 写入 shard 目录时持有 `.vfs_patch.lock`（exclusive create），第二个 patcher 得到 `Busy`；崩溃遗留的锁文件需手动删除（intent 已完整描述恢复状态）。
- 幂等路径写 page 前用 `page_value.peekIdentity` 检查现有 value 的 header identity：intact 且属于别的 object -> `KeyCollision`，不覆盖；header 损坏视为待修复。
- DB `verify` 对"index 仍知道该 key（被新版本取代或已 tombstone）"的未引用 record 不再报 `orphan_record`：append-first 存储在 optimize 前本就带这类垃圾。`orphan_record` 只留给 index 完全不知道的 key（append 后未 commit）。
- 矩阵 E4（threads 1/2/8）已加入 `bench-patch` 默认矩阵；E5（shard 数）由构建时 `shards=` 决定，不在 patch 端变化。

---

## 16. 工具与 ABI

### 16.1 工具

~~~text
vfs diff-pack <base_dir> <target_dir> <out_diff_dir> [--chunk-mb 8]
              [--strategy auto|logical|page|replace] [--threads N]
vfs patch-pack <target_dir> <diff_dir>... [--overlay <overlay_dir>] [--to V] [--in-memory|--disk]
              [--batch-mb 16] [--threads N] [--verify none|touched|full] [--optimize] [--force] [--trace out.json]
vfs dump-diff <diff_dir>          # manifest、每 shard unit 统计（按 kind / 降级原因 / override / new_block）、chunk 分布
vfs verify-diff <diff_dir>        # 所有表 crc、chunk crc、unit payload 边界、VHDF header
vfs bench-patch <target_dir> <scratch_dir> <diff_dir>...   # 复制目标到 scratch，跑默认矩阵（load / batch / threads / durability / idempotent）
~~~

`--cfg` / `--shards` / `--report json`（diff-pack）与 `--matrix <cfg>`（bench-patch）未实现：diff 的 shard 分组直接取 target pack 的 data file 数；bench 矩阵目前是代码内的默认表（`tools/diff_tools.zig defaultMatrix`）。

### 16.2 C ABI（V1.5，轮询式，无 callback）

~~~c
typedef uint64_t vfs_patch_t;
/* flags: VFS_PATCH_IN_MEMORY | VFS_PATCH_DISK | VFS_PATCH_FORCE | VFS_PATCH_OPTIMIZE
 * verify: VFS_PATCH_VERIFY_NONE | TOUCHED | FULL ; to_version 0 = 最高可达版本 */
typedef struct vfs_patch_options { uint32_t struct_size; uint32_t flags; uint32_t threads; uint32_t batch_bytes;
                                   uint64_t in_memory_max_bytes; uint32_t verify; uint32_t reserved;
                                   uint64_t to_version; } vfs_patch_options_t;
/* state: VFS_PATCH_RUNNING | DONE | FAILED | CANCELLED ; from/to_version 在结束后填充 */
typedef struct vfs_patch_progress { uint32_t struct_size; uint32_t state; uint64_t units_total; uint64_t units_done;
                                    uint64_t bytes_written; uint64_t bytes_read; int32_t last_status; int32_t reserved;
                                    uint64_t from_version; uint64_t to_version; } vfs_patch_progress_t;

int vfs_patch_begin(const char* target_pack, const char* overlay_pack_or_null,
                    const char* const* diff_dirs, uint32_t diff_count,
                    const vfs_patch_options_t* options, vfs_patch_t* out);
int vfs_patch_poll(vfs_patch_t p, vfs_patch_progress_t* out);   // 非阻塞；按 struct_size 截断拷贝
int vfs_patch_wait(vfs_patch_t p, uint32_t timeout_ms);         // 超时返回 VFS_BUSY
int vfs_patch_cancel(vfs_patch_t p);                             // 置取消标志，下一 task 边界停止
int vfs_patch_end(vfs_patch_t p);                                // 释放；未完成则等价 cancel + join + end
                                                                 // 返回 VFS_OK / VFS_CANCELLED / 失败状态
~~~

实现（`src/vfs/abi.zig`）：`begin` 复制路径后在后台 `std.Thread` 上运行 `patch_session.run`，
进度经 `PatchOptions.progress: *Progress`（原子计数 + cancel 标志）回传；handle 注册为 `.patch`。
新增状态码 `VFS_CANCELLED = 12`（`error.Cancelled`）与 `VFS_PRECONDITION_FAILED = 13`
（`PreconditionFailed` / `PatchIntentMismatch` / `OverlayBaseMismatch` / `CodecMismatch`）；`NoPatchPath` 映射为 `VFS_INVALID_ARGUMENT`，
锁文件冲突为 `VFS_BUSY`。取消后的 pack 处于可续跑的中间状态（intent 仍在，已提交 unit 幂等跳过）。

线程安全：`poll` / `cancel` / `wait` 通过 `handle_registry.acquire`（持共享锁）访问 job，`end` 用 `take`
（独占锁，原子移除 handle）——并发的 `poll` 与 `end` 不会读到已释放的 job，第二次 `end` 得到 `VFS_INVALID_ARGUMENT`。

diff 端不进 C ABI（构建机工具）。

---

## 17. 对现有代码的替换与删除

~~~text
删除:
  src/vfs/format/patch_manifest.zig           -> DiffPack 取代
  src/vfs/mutation/merge_planner.zig          -> patch/coalesce.zig 取代
  src/vfs/mutation/mutation_executor.zig      -> patch/patch_session.zig 取代
  src/vfs/mutation/mutation_plan.zig          -> PatchPlan 取代
  src/vfs/mutation/task_graph.zig / scheduler.zig / resource_budget.zig -> src/vfs/task/
  README 中 PatchManifest 相关描述

保留并修改:
  src/vfs/build/pack_builder.zig              -> 迁移到 task 框架；BuildCfg 新增 shards / diff_strategy
  src/vfs/volume/volume.zig                   -> 同 pack_id 多层、PagePlaceholder
  src/vfs/io/file_handle.zig                  -> 逐层 page 解析、lz4 解压
  src/vfs/compress/*                          -> lz4 真实、CodecCaps
  src/vfs/format/pack_manifest.zig            -> version 2 overlay 字段
  src/vfs/object_key.zig                      -> diff/patch-intent/placeholder namespace 与 reserved key
  src/db/kv_db.zig, batch_snapshot.zig, manifest.zig, checkpoint.zig, recovery_verify.zig -> 多 data file
~~~

`Volume.writeFileByEntry/deleteEntry`（运行时 whole-file 写）保留不变。

---

## 18. 已知限制与 V2 方向

~~~text
1. patch 与运行时读不可并发（V1 要求 exclusive 打开目标 pack）。
   原因: implicit page key 相同，in-place 写入会在 commit_manifest 之前覆盖旧 page，读者看到新 page + 旧 manifest。
   V2: page key 引入 generation（pageKey(file_entry, block, page, gen)），FileManifest 记 gen，读写完全分离，
       旧 gen page 由 optimize 回收。
2. L 策略 patch 内存 = 2 × block raw_size（+ 分段窗口）；超大 block 应在 BuildCfg 中拆分或用 P。
3. diff 不做跨文件匹配；资源重命名（file_entry 不变、路径变）只影响 PathDelta，是零成本的；
   file_entry 变化则视为 delete + add。
4. 多 pack 同时 patch：V1 每个 pack 一个 PatchSession，各自 Scheduler；V2 共享一个 Scheduler 与预算。
5. DiffPack 自身不压缩容器层（VHDF 流已 lz4）；R unit payload 是已压缩 page，none codec 的 R 已按 L(空 old) 处理。
6. Overlay 层数固定为 2（overlay + base）；不支持 overlay 之上再建 overlay。
~~~

---

## 19. 设计内附加决策（可复议）

| # | 选择 | 备选 | 理由 |
|---|---|---|---|
| S1 | overlay 模式不重写 PageRef，依赖 Volume 同 pack_id 多层逐层解析 | 重写为 explicit PageRef 指向 base | FileManifest 原样写入，patch 端逻辑简单；explicit ref 使 manifest 增大 112B/page，且每次 L patch 都要重算 ref |
| S2 | delete_page 在 overlay 模式用 PagePlaceholder | 用 explicit PageRef 列表隐式屏蔽 | 与 S1 一致，读端只需识别一种额外 value |
| S3 | 中间 Batch durability .none，周期 .async，finalize .sync | 全程 .sync | 幂等重跑使 .none 安全；fsync 是 SSD 上 patch 的主要延迟源 |
| S4 | P chain 在 apply 时顺序 hpatch，不在 plan 阶段合并 VHDF | 合并 VHDF | 合并 VHDF 需要 old，等价于 apply；只有 R∘P 在 plan 阶段合并（单 page，代价小） |
| S5 | shard 在 DiffPack 中是提示而非约束 | 严格要求目标 data file 数一致 | 允许客户端 pack 与构建 target 的分片数不同而仍正确 |
| S6 | 幂等判定默认 header 级（读 104B header + crc 对比） | 全量 payload 对比 | 重跑代价降到 header 读；header 内 stored_crc 已足够 |
| S7 | PatchIntent 写入目标 pack 而非旁路文件 | 旁路文件 | 与 finalize 同一 Batch 原子删除；overlay/in-place 统一 |
| S8 | chain 选择按 payload 最小 | 按 diff 数最少 | 直达 diff 若体积更大（如全量替换）不应被强选 |
| S9 | VHDF 容器自定义，不兼容 HDiffPatch 文件 | 兼容 | 我们不需要互操作；自定义可去掉 HDiffPatch 的多 codec 插件头，简化解析 |
| S10 | lz4 纯 zig 实现 block 格式，不引入 C 依赖 | 链接 liblz4 | 保持仓库零外部依赖；block 格式实现量小 |

---

## 20. 实施任务拆分

依赖顺序（同一层可并行）：

~~~text
T0  DB 多 data file + Batch 并行 commit + collectLiveKeys 公开 + in-memory 并行预加载          (src/db)
T1  通用 task 框架 src/vfs/task/ + pack_builder 迁移 + 删除旧调度器
T2  lz4 codec + CodecCaps + file_handle 解压接入 + build_plan 放开
T3  hdiff zig 移植（sais/match/cover/rle/serialize/patch）+ VHDF
T4  格式：DiffManifest/FileOpTable/UnitTable/PathDelta/Chunk/PagePlaceholder/PatchIntent/PackManifest v2
    + object_key namespace
T5  diff 侧：pack_scan / strategy / diff_planner / diff_engine / diff_pack_writer / 工具 diff-pack、dump-diff、verify-diff
T6  Volume 同 pack_id 多层 + PagePlaceholder 读端 + overlay 创建/校验
T7  patch 侧：diff_pack_reader / chain / coalesce / old_view / shard_writer / patch_session / 工具 patch-pack
T8  崩溃矩阵测试（每个 task kind 后注入 kill）、幂等重跑测试、overlay 与 in-place 双模式端到端、chain 合并测试
T9  bench-patch 与实验矩阵、README/roadmap 更新、删除 PatchManifest 路径
T10 C ABI vfs_patch_*（V1.5）

依赖: T0,T1,T2,T3,T4 相互独立 -> T5 依赖 T1,T2,T3,T4 -> T6 依赖 T4 -> T7 依赖 T0,T1,T2,T3,T4,T6 -> T8 依赖 T5,T7 -> T9 -> T10
~~~

每个任务落地为 `docs/vfs/task/task_14..24_*.md`，沿用现有任务模板（任务目标 / 必读上下文 / 硬性禁止 / 实现范围 / 验证要求 / 完成标准）。

---

## 21. 验证要求汇总

~~~text
单元:
  hdiff roundtrip/损坏/对拍；lz4 向量/roundtrip/损坏；每个格式 encode/decode/尺寸 comptime assert/位翻转拒绝；
  task 框架：依赖序、预算上限、失败级联、yield 重排、动态加任务、多线程压力；
  coalesce：R/P/L/delete 全组合 fold 表；chain 选择最小权路径。
集成:
  build v1,v2,v3（none 与 lz4 混合、多 shard）-> diff v1->v2, v2->v3, v1->v3
  -> patch in-place: v1->v2->v3 与 v1->v3 结果 object 集合逐 key 等价于 target v3；verifyPack 通过
  -> patch overlay: readonly v1 + overlay -> Volume 读全部文件字节等价于 v3
  -> 崩溃矩阵：在每个 task kind 完成后 kill，重跑收敛，最终等价
  -> 幂等：对已完成目标重跑 patch，写入 0 字节
  -> PatchIntent 不一致拒绝、--force 同 to 允许
  -> P precondition 失败（篡改 base page）报错不写入
  -> codec_version_hash 不一致报 CodecMismatch
性能基线（bench-patch，纳入 CI 只记录不断言）:
  8×64 MiB 文件、10% page 变化、lz4 block：patch 时长、峰值内存、写字节、fsync 次数；矩阵 E1-E8
约束:
  no mock；no callback ABI；DB 不 import VFS；zig build test / -Doptimize=ReleaseSafe 通过
~~~

