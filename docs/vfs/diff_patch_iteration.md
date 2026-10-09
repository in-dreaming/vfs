# VFS Diff & Patch 后续迭代指导

本文是 `docs/vfs/diff_patch.md`（设计）与 roadmap Phase 15（已完成交付）之后的迭代计划。它基于对当前实现的逐文件审查，列出必须修的缺陷、与任务书的偏差、性能实验缺口，并给出迭代顺序与验收标准。所有条目都引用具体文件位置，便于直接开工。

约束继承：`docs/vfs/task/setup.md` 的全部规则（u64 FileEntry / object key、禁 mock、禁 callback public API、DB 不 import VFS）继续生效；`diff_patch.md` §0 的 D1–D8 人工决策不在本文范围内推翻。

---

## 2026-10-08 更新

Stage 3 已实现 P0-1 的 advisory lock、P0-2 的保守 Volume 更新准入、P0-4 的真实子进程终止矩阵，并修复 staging 错误 ownership 和 saved-chain resume。下列“现象”保留为历史问题记录；当前边界/限制见 `diff_patch.md` §15 实现状态与 `improvement_progress.md`。P0-2 不提供 live snapshot migration：有 live handle/request 或 pin 即 Busy，跨 Volume canonical alias 也拒绝。Windows 运行验证、通用 DB I/O poisoned-handle 策略及后续架构/性能项仍未完成。

## 0. 现状结论

~~~text
已跑通：diff（三策略 + ratio 降级）→ DiffPack（shard 分组 chunk 聚合）→ patch（task graph 并行、
        ShardWriter 按 shard 批提交、in-place / overlay 双模式、chain coalesce、PatchIntent 幂等重跑）
        → CLI / C ABI。zig build test 149/149。

主要缺口（按严重度）：
  1. 崩溃后 .vfs_patch.lock 残留导致永久 Busy —— 与"崩溃后可 resume"目标直接冲突。
  2. patch 与 Volume 零交互：没有"pack 不可读且无文件打开"的准入，patch 后也不刷新 mount。
  3. task 框架在 src/vfs/task/ 而非任务书要求的 src/common/，且含 db/pack 领域字段。
  4. hpatch 不是 O(1) scratch，与 diff_patch.md §6.3 的声明矛盾。
  5. DB 层同 key 跨 Batch 的 version 分配在 batch_lock 之外。
  6. patch_session.zig 承担过多职责（877 行，runSession 单函数 ~230 行）。
  7. 崩溃测试是 error 注入而非进程 kill，且全部单线程。
~~~

---

## 1. 迭代原则

~~~text
R1  格式先冻结再改。DiffPack 五种对象（VDFM/VDUT/VDFO/VDPI/VDCK）、VHDF、PatchIntent、
    PagePlaceholder、PackManifest v2 都带 version 字段：改格式必须 bump version 并保留旧版解码，
    verify-diff / dump-diff 必须能读旧版。首轮迭代（I1–I3）不改任何磁盘格式。

R2  行为不变的重构必须先有"行为锁"测试。拆 patch_session、迁 task 框架之前，先把
    patch_test.zig / diff_test.zig 的等价性断言补到"写入 0 op"级别（见 §2 P0-5），
    再动代码；重构后测试零修改通过。

R3  一次只改一个变量。性能项（§4）每个实验单独 PR，附 bench-patch 前后数据；
    没有数据支撑的默认值变更不合入。

R4  每个 P0/P1 条目关闭时同步更新 diff_patch.md 的"实现状态（与设计的差异）"段
    （§15 末尾）与 roadmap Phase 16。文档与代码不一致视为未完成。

R5  不做的事：不引入 progress/watermark 表（D4 维持幂等重跑）；不改 overlay 的
    "同 pack_id 多层 + PagePlaceholder"模型（S1/S2，已有测试）；不做 MVCC 边读边更新（§18.1）。
~~~

---

## 2. P0：正确性与恢复（阻断发布）

### P0-1 崩溃后锁文件残留 → 永久 Busy

~~~text
现象  patch_session.zig:621-623 注释说"Stale locks (crash) are removed on the next run"，
      但 PatchLock.acquire（:628-639）用 createFile(.exclusive=true)，PathAlreadyExists 直接
      return error.Busy；release 只在正常路径的 defer 里 deleteFile。
      patch_test.zig:336-342 甚至把"残留锁 → Busy"断言成了预期行为。
后果  进程被 kill 后，同一目标的所有 patch 都失败，必须人工删文件。
方案  改为 OS 建议锁：createFile(.truncate=false) 后 tryLock(.exclusive)；进程退出内核自动释放。
      文件本身可长期存在，不再依赖"谁来删"。Windows 与 POSIX 语义都满足。
      注意：DB 目录内已有 .vfs_patch.lock 的路径不变，避免旧版本/新版本互相看不见。
验收  1. 手工在目录里放一个无持有者的 .vfs_patch.lock，run 成功。
      2. 两个进程（或同进程两个 PatchLock）并发 → 第二个 Busy；第一个 release 后第二个成功。
      3. 修正 patch_test.zig:336-342 的断言语义；注释与实现一致。
~~~

### P0-2 更新准入：pack 不可读且无文件被打开

~~~text
现象  patch_session.zig 中 grep volume/Volume/refresh 为 0 命中。当前只靠目录锁排他，
      对"Volume 里正有 FileHandle 在读这个 pack"完全不设防；patch 完成后 Volume 也不知道
      版本变了（page cache 按 generation 失效依赖调用方重新 mount）。
      diff_patch.md §9.1 P6 写的"Volume 若在线则 refresh mount generation"未实现。
方案  新增 src/vfs/volume/update_lease.zig（可直接参考 vfs_tasks/diffpatch/ge-b6b6db46ebeb
      docs/vfs/diff_patch.md §5 的 UpdateLease 设计）：
        acquireUpdateLease(v, pack_id)
          1. v.open_file_count != 0 → error.Busy          （volume.zig:89 已有该计数器）
          2. 目标 mount（overlay 模式含 base + overlay）state 置 leased，publish
          3. openEntry / openPath / statEntry / pinStoreMounted 遇 leased → error.Busy
          4. drain in-flight pin，reader.park() 交出 OS handle（否则 Windows 上 read_write 打不开）
        releaseUpdateLease(v, lease, .updated | .unchanged)
          updated：page_cache 整体丢弃，重开 reader，刷新 pack_version / generation
      patch_session.run 新增可选参数 `lease: ?UpdateLease`；abi 新增 volume-handle 版入口
      vfs_patch_begin_in_volume(volume, pack_id, ...)，内部 acquire → run → release，
      句柄销毁时兜底 release。现有 path 版入口保留给离线工具（无 Volume 场景）。
      失败即 Busy，不排队、不强制关别人的 handle（业务决策，不是 VFS 的）。
验收  E32 有 open handle 时 begin → Busy 且 pack 仍完全可读
      E33 持租约期间 open/stat → Busy；release 后恢复且读到新版本
      E34 overlay 模式只锁其一（base 或 overlay）必须被测试抓出
      E35 未 end 就丢弃 job → 兜底释放，pack 不永久锁死
      E36 租约期间 reader 已 park → patch 能 read_write 打开（Windows 上必测）
      E37 release(unchanged)（dry-run / 提前失败）后读到旧版本
~~~

### P0-3 DB：同 key 跨 Batch 的 version 竞争

~~~text
现象  batch_snapshot.zig:98 在 appendSharded 阶段调用 db.nextVersion(p.key)，此时只持
      per-key 锁，beginBatchCommit（:106）的 batch_lock 还没拿。两个并发 Batch 写同一 key
      时可能都算出 v+1，各自 append 相同 version 的 record，最终由 journal 顺序决定可见性；
      recovery_verify / relocation 若按 version 判新旧会歧义。
      kv_db.zig:578 vs :593（commitPending）有同类交错。
现状  patch 场景每个 key 固定归属一个 file shard（object_key.fileShard），不会触发；
      但这是 KvDb 的通用 API，不能靠调用方约定保证。
方案  A. version 分配移入 batch_lock 临界区：appendSharded 先用占位 version 追加 record，
         beginBatchCommit 内统一分配并回填（data record 的 version 字段位置固定，可 pwrite 修补），
         或 record 不存 version、以 journal 序为准（需评估 relocation 依赖）。
      B. 若 A 改动过大：Batch.begin 时按 shard pin，并在 debug 断言"同 key 不得出现在两个
         同时 open 的 Batch"，文档明确该限制。
      优先 A；B 只作为过渡。
验收  N 线程并发 Batch 写同一组 key（不同 shard pin），全部 commit 后 verify 通过、
      每 key 最终值等于 journal 序最后一次写入；relocation/optimize 后仍一致。
~~~

### P0-4 进程级崩溃测试

~~~text
现象  FaultPoint（patch_session.zig:39-46）是 return error.InjectedFailure，会走完全部 defer：
      DB 正常 close、锁正常释放、ShardWriter 正常 deinit。真实 kill 留下的"data 已 append、
      journal 未 commit""intent 已写、锁文件残留"等状态没有被 patch 层测试覆盖
      （DB 层只有 batch_snapshot.zig:356 单测）。
      且 patch_test.zig:196/:228 崩溃矩阵全部 worker_threads = 1。
方案  1. tools/vfs.zig patch-pack 增加隐藏参数 --test-stop-at=<point>：到点后写信号文件并
         阻塞（while(true) sleep），由父进程 kill。参考 vfs_tasks/diffpatch/ge-ccceb7d8a633
         tests/test_patch_process.py 的做法，但用 Zig 写驱动（tests/vfs_patch_process.zig），
         不依赖 python。
      2. 停点：after_intent / after_units(n) / after_file_ops(n) / before_finalize /
         after_finalize_before_optimize，再乘 in-place / overlay。
      3. 矩阵同时在 worker_threads = 1 和 = 4 下跑。
      4. 挂到 zig build test-heavy（新 step），不进默认 test；CI 夜间跑。
验收  每个停点 kill 后，新进程 resume：结果 expectEquivalent 通过；重跑一次写入 0 op；
      kill 后残留的锁不阻塞（依赖 P0-1）。
~~~

### P0-5 幂等与等价性断言补齐

~~~text
现象  task_22 §4 要求"幂等重跑写入 0"，patch_test.zig:119-121 / :179-181 只断言 no_op 短路，
      没有断言 Report.units_applied == 0 && batches == 0 && bytes_written == 0。
      idempotent_check = .off 与 diff_load = .disk 两条路径没有等价性测试
      （disk 只在 diff_tools.zig:164 bench 里走过一次）。
方案  Report 增加 units_skipped / units_applied / bytes_written（若缺）；
      所有端到端测试结束追加一次"重跑 → 三项为 0"；
      矩阵扩到 {header, off} × {in_memory, disk}。
验收  上述断言全部通过；这是 §1 R2 的"行为锁"，必须先于 P1-1 / P1-2 落地。
~~~

---

## 3. P1：任务书对齐与架构

### P1-1 task 框架迁到 `src/common/task/` 并去掉领域耦合

~~~text
现象  任务书要求 task graph 放 src/common 下，当前在 src/vfs/task/。
      领域概念泄漏：resource.zig:5-14 ResourceClass 有 db_write / pack_exclusive；
      :17-29 Need 有 db_write_shard / pack_exclusive / pack_shared / pack_id；
      :50 Budget.db_write_per_shard；graph.zig:28 TaskDesc.label_file_entry。
      依赖泄漏：graph.zig:7 / scheduler.zig:12 / worker_pool.zig:4 都 import
      @import("db_internal").platform.sync —— common 不能依赖 db。
      其他：Budget.validate 是空函数（resource.zig:86-88）；completions.orderedRemove(0)
      是 O(n)（scheduler.zig:278）；trace 没有独立 trace.zig（task_15 计划有）。
目标  common 只依赖 std；VFS 侧用 Adapter 把 shard / pack 语义映射成通用资源键。
方案  1. 通用资源模型：
           ResourceVector { lanes: [N]u16, memory_bytes: u64, exclusive_lock: u32, shared_lock: u32 }
           lane 由使用方 comptime 命名（io_read / io_write / cpu / cpu_codec / db_write ...）；
           命名锁表取代 pack_exclusive/pack_shared bool 与 db_write_shard：
             VFS 约定 1..=shard_count 为 shard 写锁，0x1000 为 pack meta 锁。
         label_file_entry → 通用 label: u64（profile 分类用）。
      2. common/sync.zig 自带 Mutex/Condition（或直接 std.Thread.*），db 与 vfs 都可用。
      3. build.zig：common_mod（无 imports）注入 vfs_mod / vfs_shared_mod / db_internal_mod；
         新 step test-common；新增 tools/check_layering.zig 在 zig build test 里 grep
         src/common/** 不得 import db / db_internal / vfs（可参考 ge-b6b6db46ebeb 的同名工具）。
      4. Budget.validate 实装：构图期检查单 task need ≤ budget，报出 task label 与超限维度；
         运行期不再可能出现 NeedExceedsBudget。
      5. completions 改环形队列或 swapRemove（顺序无关）。
      6. yield 语义、动态 addTask、按 primaryClass 分队列、trace 全部保留 —— 这些是 B 的优点。
      7. patch_builder / diff_engine / patch_session 改用新 API；旧 src/vfs/task/ 删除，
         空目录 src/vfs/mutation/ 一并删除。
验收  1. zig build test-common 不链接 db / vfs 即可运行；check_layering 通过。
      2. 现有 diff / patch / build 测试零修改通过（R2）。
      3. 100k 任务链式图构图 + 调度 Debug < 4 s、Release < 200 ms（防止退化）。
      4. 构图期能检出"单 task 资源 > budget"并给出具体 task。
顺序  在 P1-2 之后做：session 拆小后，替换 task API 的 blast radius 更小。
~~~

### P1-2 拆分 `patch_session.zig`

~~~text
现象  877 行；Session 同时负责 R/P/L 语义、幂等判定、KeyCollision 检查、staging 生命周期、
      统计、故障注入、进度；runSession 一个函数跨 P0–P6 约 230 行，20+ 局部变量，多层
      defer close。applyPage（:277-296）与 applyComposite（:412-426）的 P/R 处理重复。
方案  patch/
        patch_session.zig   只留 PatchOptions / Report / run：P0 open → P1 load → P2 plan
                            → P3 graph → P4 run → P5 finalize → P6 close 的编排，每阶段一个函数
        apply_unit.zig      Session 执行器：applyPage / applyComposite / BlockState / 幂等判定
                            （blockAlreadyAt）/ KeyCollision；P 与 R 的共用逻辑抽成 applyPageStep
        intent.zig          PatchIntent 读写 + PatchLock（P0-1 改造后的 OS 锁）
        finalize.zig        PathIndex 重编码 + PackManifest + intent 删除的单 Batch 提交
        graph_builder.zig   plan → task.Graph（含 P2-3 的优先级计算）
      公共类型（FaultPoint / Progress）留在 patch_session.zig 或 types.zig。
验收  行为不变：patch_test / diff_test / abi 测试零修改通过；单文件 ≤ 400 行；
      applyPage 与 applyComposite 不再有重复的 P/R 分支。
~~~

### P1-3 hpatch 内存有界

~~~text
现象  diff_patch.md §6.3 声明"patch 只需 old 随机访问、out 顺序写、固定大小 scratch；
      与 unit 大小无关的额外内存为 O(1)"。实现（hdiff/diff.zig）：
        :185-204 Streams.load 把 4 个 lz4 流各解压到堆（O(stream_size)）
        :229      list = alloc(Cover, cover_count)（O(cover_count)）
      task_17 §3 也明确要求 O(1) 额外 scratch。注释 :227-228 承认此差异。
      当前 patch 峰值 ≈ old + new + 全部流解压 + covers，L 策略下一个 64 MiB block
      的 patch 可能多吃数十 MiB。
方案  两步走，第一步不改格式：
      1. cover 流式解码：不预建 list，按需从 covers 流读一个 cover 处理一个
         （RLE Decoder 已是流式，rle.zig:58-111）；lz4 流改为分块解压到固定环形缓冲
         （lz4 block 格式无跨块状态，可按 chunk 切）。
      2. 若 1 之后仍需更强上界（老 new_data_diff 流很大时），VHDF v2 引入 step 分段
         （参考 ge-b6b6db46ebeb hdiff/decode.zig 的 step_mem 模型，patch 端峰值 = step_mem），
         按 R1 bump version。
      若短期都不做，必须先把 §6.3 改成与实现一致，并在 PatchOptions 文档里给出峰值公式。
验收  断言测试：patch 一个 64 MiB L block 时，除 old/out 外的分配总量 ≤ 常量（如 1 MiB）；
      随机 roundtrip / 位翻转 / 截断测试保持通过。
~~~

### P1-4 策略选择补全：auto 试算 L vs P

~~~text
现象  diff_planner.zig:247-256 layout 且 block_hash 完全相同时逐页比较，只对 stored 不同
      的页发 R（重压缩场景），这是正确的。
      但 strategy.decide（strategy.zig:30-51）只按 codec caps 选 L 或 P，再由
      deltaWorthIt（:54-57）降级到 R；从未在 L 与 P 之间按体积/CPU 代价比较。
      对 lz4 block 一律 L：patch 时要解压 + 重压缩整 block，小改动时 P 可能更划算；
      对不可 runtime 压缩的 codec 一律 P：无选择余地，正确。
方案  构建机允许慢：DiffEngine 对 runtime-compressible 的候选 block 同时生成 L 与 P
      payload，按 size(L) < size(P) * logical_vs_page_gain_margin（默认 0.9，L 有重压缩
      CPU 成本所以要求更明显的体积优势）选择；结果与降级原因写入 unit.flags
      （已有 UNIT_FLAG_DOWNGRADED_* 机制）。BuildCfg 的 diff_strategy 覆盖与 --strategy
      强制保留为约束。
      注意 §5.4 风险：L patch 后的 stored 字节来自客户端 lz4；后续版本对该 block 选 P 时
      precondition 依赖 codec_version_hash 一致（已实现校验），试算时不得对上一版是 L 的
      block 选 P，除非 caps.deterministic。
验收  dump-diff 输出策略直方图与降级原因统计；
      构造"lz4 block 改 1 页"用例断言选 P，"lz4 block 改 60% 页"断言选 L；
      与手工 --strategy 强制的最小体积一致。
~~~

### P1-5 文档 / 任务书对齐项

~~~text
1. diff_patch.md §16.1 列出的 --cfg / --shards / --report json / --matrix 未实现：
   要么实现，要么从文档删除并在"实现状态"段注明。
2. task_17 要求的 match.zig / serialize.zig / patch.zig 与 task_18 的 5 个 format 文件被合并：
   接受现状，但在 task 文档末尾追加"实际落点"一节，避免后来者找不到文件。
3. §6.3 与 P1-3 实现同步；§9.2 优先级描述与 P2-3 同步。
4. vfs_arch.md:881-884 仍列出已删除的 mutation/*.zig，更新。
5. roadmap 新增 Phase 16 指向本文。
~~~

---

## 4. P2：性能与实验

这一组全部遵循 §1 R3：先有 bench 数据，再改默认值。

### P2-1 bench-patch 矩阵与指标补全

~~~text
现状  diff_tools.zig defaultMatrix 是代码内固定表（E1/E2/E3/E4 部分）；trace JSON 已有。
      缺：fsync 次数、峰值 RSS / owned memory、实际读写字节、每阶段耗时（P0–P6）。
方案  1. ShardWriter.Stats 增加 fsync_count（按 durability 计）、Report 增加 phase_ns[7]、
         bytes_read（OldView 与 DiffPackReader 计数）。
      2. --matrix <cfg> 实装：每行一个 PatchOptions 覆盖，输出 CSV/JSON。
      3. 数据集：8×64 MiB / 10% page 变化 / lz4（§21 基线）之外，补"10 万小文件 1% 变化"
         与"单 1 GiB 文件 1 页变化"两组极端。
      4. 需要回答的问题（对齐 ge-b6b6db46ebeb §16.3 Q1–Q10，取与 B 相关的）：
           Q1 L vs P 分界点（按 block 大小 / 修改比例 / codec）→ 反馈 P1-4 的 margin 默认值
           Q2 chunk_nominal_bytes 最优值（in_memory 与 disk 分别扫 1/4/8/16/64 MiB）
           Q3 batch_bytes 与 fsync 成本关系；flush_every_n_batches 的收益
           Q4 io_read 并发在 HDD / NVMe / 移动闪存上的最优值
           Q5 in_memory 加载 DiffPack 的收益是否覆盖其加载时间（冷 / 热 OS cache 分开测）
           Q6 chain (d12,d23) vs 两次串行的实测倍数
           Q7 shard 数 1/2/4/8 的并行写收益（E5）
验收  每个 Q 有数据写回 diff_patch.md §15 的默认值说明；CI 记录基线不断言。
~~~

### P2-2 DiffPack 加载路径

~~~text
1. diff_pack_reader.zig:230-244 storeBytes 只统计 data_000.db，与 diff_tools.zig:94-102
   copyTree 遍历 256 个不一致。DiffPack 目前固定单 shard 无实际影响，但 auto 阈值判断
   应遍历 manifest 的 data file 表。
2. §12.2 设计的 preload_paths 并行分片读（≥ 8 MiB 分片、用 io_read 预算）未实现；
   InMemoryFileOps.getOrLoad 仍是单线程整文件读。Q5 测出 in_memory 有收益后再做。
3. disk 模式 chunk cache 单一按插入序淘汰；若 Q2 显示 disk 模式常用，改按 unit 顺序预取。
~~~

### P2-3 调度优先级

~~~text
现象  patch_session.zig:790 apply_unit 优先级只有 composite 20 / 其他 10；
      §9.2 设计是"remaining_bytes_of_shard 大者优先 + L 加权"，使各 shard 尾部对齐。
方案  graph_builder（P1-2 拆出）在 plan 阶段按 shard 汇总 est_bytes，
      priority = f(shard_remaining_rank, composite, est_bytes)；commit_batch > apply_unit
      （尽早释放 staged 内存）。trace 里看 shard 完成时间的方差作为指标。
验收  多 shard 数据集上 trace 显示各 shard 结束时间差 < 10%；总时长不劣化。
~~~

### P2-4 多 shard 的 optimize 空间回收

~~~text
现象  relocation.zig:53-61 safeTruncate 只处理 shard 0；多 data file 下其他 shard 的尾部
      空闲不会截断。功能缺失而非破坏，但 optimize_after=true 的收益在多 shard 下打折。
方案  遍历 db.data 全部 shard 各自截尾；测试 4 shard optimize 后每个文件 logical_tail 收缩。
~~~

### P2-5 hdiff 压缩率

~~~text
现象  cover.zig:88 只探测插入点附近 8 个 SA 邻居（非完整 LCP 区间）；:206 过滤阈值
      min_single_match_score + 6 是 magic；extend 用固定 5/8 相似率。
      对高重复数据可能漏掉更长匹配。
方案  1. 先测：固定语料（贴图 / mesh / json / 可执行）上与官方 hdiffz -s-0 的 delta 体积比，
         记录为回归门槛（建议 ≤ 1.15x）。进 zig build bench-diff，不进 test。
      2. 超门槛时再调：probes 数、near_window、extend 阈值全部提升为 DiffOptions 字段，
         允许 --score/--probes 不重编译扫描。
~~~

---

## 5. P3：卫生

~~~text
注释与实现矛盾
  patch_session.zig:621-623（随 P0-1 修正）
  strategy.zig:12-22 注释写 replace_ratio / max_diff_input_bytes，字段实为
    max_delta_permille / max_logical_block_bytes

Magic number → 命名常量或 Options 字段
  cover.zig:88 探针数 8；:206 `+ 6`
  scheduler.zig:168 yield 惩罚上限 1000；:336 skipped[16]
  shard_writer.zig:82 每 op 记账开销 64
  coalesce.zig:125 / :157 est_bytes 的 *3 / *2 估算系数
  patch_session.zig:680 max_delta_entries = 1 << 16；:682 read_handles = 4；:790 优先级 20/10
  diff_engine.zig:147-151 优先级常量
  resource.zig:80 worker 推导的 `+ 2`

无用代码 / 签名
  diff_planner.zig:65-69 shardHint 忽略两个参数
  src/vfs/mutation/ 空目录

测试基础设施
  patch_test.zig:20-29 固定相对路径 zig-cache-vfs-pt-*，多个 test binary 并行会冲突 → tmpDir
  task_22 要求测试在 tests/vfs_diff_patch.zig 注册 build step：接受现状（root.zig 引入），
    在 task 文档注明

文档
  vfs_arch.md:881-884 过期的 mutation/*.zig 列表
  diff_patch.md §16.1 未实现的 CLI 参数
~~~

---

## 6. 迭代顺序

~~~text
I1  正确性收口（不改格式、不改架构）
    P0-5 行为锁测试 → P0-1 锁 → P0-3 DB version → P3 注释矛盾
    出口：崩溃矩阵在 worker_threads = 4 下通过；重跑写入 0 op 有断言。

I2  结构整理（行为不变）
    P1-2 拆 patch_session → P1-1 迁 common/task + check_layering → P3 magic number / 空目录
    出口：test-common 独立运行；check_layering 进 zig build test；所有 I1 测试零修改通过。

I3  Volume 集成与真实崩溃
    P0-2 UpdateLease + abi 新入口 → P0-4 进程级 kill 矩阵（test-heavy）
    出口：E32–E37 通过；kill 矩阵 in-place / overlay × 单/多线程 收敛。

I4  算法与策略
    P1-3 hpatch 有界 → P1-4 auto 试算 → P2-5 压缩率基线
    出口：peak scratch 断言；策略直方图；与 hdiffz 体积比 ≤ 1.15x。

I5  性能实验
    P2-1 矩阵与指标 → Q1–Q7 逐个出数据 → P2-2 / P2-3 / P2-4 按数据决定做不做
    出口：每个 Q 有结论写回默认值；profile 上无单点串行占比 > 30%。

依赖：I2 依赖 I1 的行为锁；I3 的 abi 入口依赖 I2 拆分后的 run 签名；I4/I5 与 I3 可并行。
~~~

---

## 7. 明确不做（本轮）

~~~text
1. progress / watermark 表。D4 的"重跑 + 幂等跳过"在 header 级检查下代价是 O(unit × 104B 读)，
   10 万 unit 量级可接受。若 P2-1 实测 resume 耗时成为问题，再评估每 shard 一个 u32 watermark
   （需要 shard 内顺序 commit，会牺牲部分并行度）。
2. overlay 改为独立 pack_id + explicit PageRef。当前同 pack_id 多层模型有 Volume 读路径与测试
   支撑；换模型收益（manifest 自描述、跨 pack 引用可校验）不足以抵消重写成本。
3. 多层 overlay（overlay 之上再 overlay）。§18.6 维持固定两层。
4. 边读边 patch（MVCC / generation-scoped page key）。§18.1 维持 V2 方向。
5. hdiff 流式 digest matcher（大文件 diff 不受 64 MiB 限制）。分段 L（§6.5）已能覆盖，
   构建机内存充足。
6. DiffPack 单文件归档 / CDN 形态。由外部下载器负责，与 §1 非目标 5 一致。
~~~

---

## 8. 可直接借鉴的外部设计

以下来自同一任务的另两份方案，已审查过、与 B 的模型兼容，可按需搬运而不必重新设计：

| 条目 | 来源 | 搬什么 | 用在哪 |
| --- | --- | --- | --- |
| UpdateLease 状态机 | `vfs_tasks/diffpatch/ge-b6b6db46ebeb/docs/vfs/diff_patch.md` §5 | acquire/release 流程、leased 检查点、park reader、失败即 Busy | P0-2 |
| 通用资源模型 | 同上 `src/common/task/resources.zig`（ResourceVector + LockTable）、`graph.zig`（CSR 后继 + critical path） | lane 数组 + 命名锁 + 构图期 budget 校验 | P1-1 |
| 分层检查工具 | 同上 `tools/check_layering.zig` | 规则表驱动的 import 白名单 | P1-1 |
| hdiff step 模式解码 | 同上 `src/vfs/diff/hdiff/decode.zig` / `delta.zig` | step_mem 上界、零分配 patchInto | P1-3 第二步 |
| 进程级 kill 测试 | `vfs_tasks/diffpatch/ge-ccceb7d8a633/tests/test_patch_process.py` + `src/vfs/patch/session.zig` 的 test_stop_at | 停点 → 信号文件 → kill → 新进程 resume 的编排 | P0-4（改用 Zig 驱动） |
| DB CommitOutcome | 同上 `src/db/kv_db.zig`（`CommitOutcome{committed,unknown}` + `freezeForRecovery`） | 提交结果未知时冻结而非继续写 | P0-3 若走方案 A 时一并考虑 |

搬运时保留原设计的理由说明（它们都在各自文件头注释里），并按 B 的命名与目录规范改写；不要整文件复制。
