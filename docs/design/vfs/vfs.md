# VFS Pack Processing Layer 方案文档

## 0. 定位

本方案位于 VFS 与底层 KV DB 之间。

```text
VFS Layer
  volume / pack / inner-out overlay / handle cache / meta pack

Pack Processing Layer
  file -> block -> page
  compression abstraction
  build / merge / patch
  incremental
  inmemory file ops
  resource task graph

KV DB Layer
  index.db
  data_*.db
  mmap index
  append / hole / relocate
  checkpoint
```

本层不负责 DB 内部索引、data db 分配、mmap、delta/base index 等底层逻辑；也不负责 volume/pack 的 mount/overlay 语义。它负责把“逻辑文件更新”转化为一批高效的 KV 写入、删除、修改任务。

---

# 1. 核心修正

## 1.1 Key 不是 hash，而是结构体

Page key 不应被描述为：

```text
(file_hash, block_index, page_index) -> hash128
```

而应该是一个明确的、可序列化、可比较、可作为 KV key 的结构体。

```cpp
struct VfsPageKey {
    uint16_t pack_id;
    uint16_t key_type;       // PAGE / FILE_MANIFEST / META / ...
    uint32_t key_version;

    uint64_t file_id_hi;
    uint64_t file_id_lo;

    uint32_t block_index;
    uint32_t page_index;
    uint32_t reserved;
};
```

其中：

```text
pack_id:
  直接定位 pack。

key_type:
  区分 page、file manifest、meta record 等。

file_id_hi/file_id_lo:
  逻辑文件 ID，可以来自资源 GUID、导入 ID、路径 hash、资产 ID。
  它不是 page key 的全部，只是 page key 的组成字段。

block_index:
  文件内 block 序号。

page_index:
  block 内 page 序号。
```

该结构体可以作为 DB 的 key 类型。底层 DB 可以对 key bytes 再做内部 hash/bucket/index lookup，但从上层语义看，key 就是结构体。

推荐统一抽象：

```cpp
struct VfsKey {
    uint16_t pack_id;
    uint16_t key_type;
    uint32_t key_version;
    uint8_t  payload[24]; // page/file/meta 各自解释
};
```

然后不同 key type 有不同解释：

```cpp
struct VfsFileManifestKey {
    uint16_t pack_id;
    uint16_t key_type; // FILE_MANIFEST
    uint32_t key_version;
    uint64_t file_id_hi;
    uint64_t file_id_lo;
    uint64_t reserved;
};

struct VfsPageKey {
    uint16_t pack_id;
    uint16_t key_type; // PAGE
    uint32_t key_version;
    uint64_t file_id_hi;
    uint64_t file_id_lo;
    uint32_t block_index;
    uint32_t page_index;
    uint32_t reserved;
};
```

这样可以避免把上层 key 过早压缩成 hash，便于调试、碰撞处理、版本兼容和工具链分析。

---

## 1.2 Page value 必须包含 PageHeader

Page value 不能只是裸压缩 buffer。否则读取时无法独立知道：

```text
1. 用什么 codec 解压。
2. raw_size 是多少。
3. compressed_size 是多少。
4. page 属于哪个 block/page。
5. 是否加密、是否有字典、是否是 raw 存储。
6. 如何校验。
```

因此每个 page value 必须自带 header。

```cpp
struct PageValueHeader {
    uint32_t magic;          // 'PGV0'
    uint16_t version;
    uint16_t header_size;

    uint16_t codec;          // None / LZ4 / Zstd / Oodle / ...
    uint16_t codec_flags;

    uint32_t block_index;
    uint32_t page_index;

    uint32_t raw_size;
    uint32_t stored_size;

    uint32_t raw_crc;
    uint32_t stored_crc;

    uint32_t page_flags;     // compressed / encrypted / dictionary / raw_fallback
    uint32_t dict_id;

    uint64_t content_hash_hi;
    uint64_t content_hash_lo;

    uint32_t header_crc;
};
```

value 格式：

```text
[PageValueHeader][payload bytes]
```

payload 可能是：

```text
1. raw page bytes
2. compressed page bytes
3. encrypted + compressed page bytes
4. future custom encoded bytes
```

读取 page 时：

```text
1. DB get(page_key) -> page_value
2. 读取 PageValueHeader
3. 校验 header_crc / stored_crc
4. 根据 codec 解压
5. 校验 raw_crc
6. 返回 raw page buffer
```

---

# 2. 文件、Block、Page 模型

## 2.1 层级

```text
Logical File
  ├── FileManifest
  ├── Block 0
  │     ├── Page 0
  │     ├── Page 1
  │     └── Page N
  ├── Block 1
  │     ├── Page 0
  │     └── Page N
  └── Block M
```

含义：

```text
File:
  用户或引擎看到的逻辑资源文件。

Block:
  压缩策略单位。
  每个 block 可以配置不同 CompressInfo 和 page_size。

Page:
  KV 存储单位。
  每个 page 是一个 key-value。
```

## 2.2 为什么不是 file 直接存一个 value

大文件直接一个 value 有以下问题：

```text
1. 随机读取差。
2. 小范围修改要重写整个文件。
3. patch 粒度粗。
4. 压缩策略无法按区域变化。
5. 大文件解压延迟高。
6. merge/build 增量能力差。
```

## 2.3 为什么需要 block + page 两层

```text
block:
  用来控制压缩算法、压缩等级、字典、page_size、读取策略。

page:
  用来做 KV 存储、随机读取、增量更新、patch、并行压缩。
```

block 是策略层，page 是存储层。

---

# 3. FileManifest 设计

逻辑文件本身通过 `VfsFileManifestKey` 查询到 `FileManifest`。

```cpp
struct FileManifestHeader {
    uint32_t magic;          // 'FMF0'
    uint16_t version;
    uint16_t header_size;

    uint64_t file_size;

    uint64_t file_id_hi;
    uint64_t file_id_lo;

    uint64_t content_hash_hi;
    uint64_t content_hash_lo;

    uint32_t block_count;
    uint32_t flags;

    uint32_t manifest_crc;
};

struct BlockDesc {
    uint64_t raw_offset;
    uint64_t raw_size;

    uint32_t page_size;
    uint32_t page_count;

    uint16_t codec;
    uint16_t codec_level;
    uint32_t codec_flags;

    uint32_t dict_id;
    uint32_t block_flags;

    uint64_t block_hash_hi;
    uint64_t block_hash_lo;
};

struct FileManifest {
    FileManifestHeader header;
    BlockDesc blocks[];
};
```

读取文件：

```text
1. 构造 VfsFileManifestKey。
2. DB get(file_manifest_key)。
3. 解析 FileManifest。
4. 根据 offset/size 找 block/page。
5. 构造 VfsPageKey。
6. 读取 page value。
7. 根据 PageValueHeader 解压。
8. 拼接返回数据。
```

---

# 4. CompressInfo 抽象

## 4.1 CompressInfo

```cpp
enum class CompressCodec : uint16_t {
    None,
    LZ4,
    Zstd,
    Oodle,
    Brotli,
    Custom,
};

enum class CompressLevel : uint16_t {
    Fastest,
    Fast,
    Balanced,
    High,
    Max,
};

struct CompressInfo {
    CompressCodec codec;
    CompressLevel level;

    uint32_t flags;

    uint32_t page_size;
    uint32_t dict_id;

    uint32_t raw_block_size;
    uint32_t max_compressed_page_size;

    uint64_t param0;
    uint64_t param1;
};
```

flags：

```text
IndependentPages:
  每个 page 可独立解压。

SharedBlockDictionary:
  block 内 page 共享字典。

StoreRawIfLarger:
  压缩后比 raw 大，则存 raw。

GpuDecompressible:
  未来支持 GPU 解压。

StreamingPreferred:
  优先快速解压，而非极致压缩率。
```

## 4.2 CompressorRegistry

```cpp
struct ICompressor {
    CompressCodec codec;

    bool compress_bound(
        const CompressInfo& info,
        size_t raw_size,
        size_t* out_bound
    );

    bool compress_page(
        const CompressInfo& info,
        const void* raw,
        size_t raw_size,
        void* compressed,
        size_t* inout_compressed_size
    );

    bool decompress_page(
        const CompressInfo& info,
        const void* compressed,
        size_t compressed_size,
        void* raw,
        size_t raw_size
    );

    bool estimate_ratio(
        const CompressInfo& info,
        const void* sample,
        size_t sample_size,
        float* out_ratio
    );
};
```

注册：

```cpp
compress_registry_register(&lz4_codec);
compress_registry_register(&zstd_codec);
compress_registry_register(&oodle_codec);
```

---

# 5. build_cfg 设计

## 5.1 基本结构

```yaml
pack:
  name: map_001
  pack_id: 1001
  max_data_db_size: 536870912
  default_page_size: 65536

compression:
  default:
    codec: zstd
    level: balanced
    page_size: 65536

  by_type:
    texture:
      codec: none

    mesh:
      codec: lz4
      level: fast
      page_size: 65536

    json:
      codec: zstd
      level: high
      page_size: 32768

files:
  - file_id: "terrain_main"
    source_path: "Content/Map001/terrain.bin"
    content_hash: "..."
    blocks:
      - offset: 0
        size: 104857600
        page_size: 65536
        compress:
          codec: lz4
          level: fast

  - file_id: "dialogue"
    source_path: "Content/Map001/dialogue.json"
    content_hash: "..."
    compress:
      codec: zstd
      level: high
      page_size: 32768
```

## 5.2 字段语义

```text
file_id:
  逻辑文件 ID，参与构造 VfsFileManifestKey / VfsPageKey。

source_path:
  构建输入文件路径。

content_hash:
  文件内容校验 hash，不等于 VFS key。

blocks:
  文件内部 block 划分。

compress:
  block 或文件级压缩策略。
```

不要把 `file_id`、`content_hash`、`page_key` 混成一个概念。

---

# 6. Build Pipeline

## 6.1 总流程

```text
Parse build_cfg
  ↓
Scan source files
  ↓
Generate BuildPlan
  ↓
Incremental check
  ↓
Split file -> block -> page
  ↓
Read pages
  ↓
Hash pages
  ↓
Compress pages
  ↓
Write page KV
  ↓
Write FileManifest
  ↓
Update PackManifest
  ↓
Update VolumeMetaPack
```

## 6.2 BuildPlan

```cpp
struct PackBuildPlan {
    uint16_t pack_id;
    std::string pack_name;

    std::vector<FileBuildTask> files;

    uint64_t estimated_raw_size;
    uint64_t estimated_stored_size;
};

struct FileBuildTask {
    VfsFileManifestKey manifest_key;

    std::string source_path;

    uint64_t source_size;
    Hash128 source_hash;
    Hash128 build_cfg_hash;

    std::vector<BlockBuildTask> blocks;
};

struct BlockBuildTask {
    uint32_t block_index;

    uint64_t raw_offset;
    uint64_t raw_size;

    uint32_t page_size;

    CompressInfo compress;
};
```

## 6.3 增量判断

增量缓存：

```cpp
struct BuildCacheEntry {
    VfsFileManifestKey file_key;

    Hash128 source_hash;
    Hash128 build_cfg_hash;
    Hash128 compressor_version_hash;

    uint64_t source_size;
    uint64_t source_mtime;

    Hash128 output_manifest_hash;
};
```

文件需要 rebuild 的条件：

```text
1. source_hash 变化。
2. build_cfg_hash 变化。
3. CompressInfo 变化。
4. page_size 变化。
5. compressor version 变化。
6. file_id/key 变化。
7. pack_id 变化。
```

V1 可以做文件级增量。

V2 支持 block/page 级增量：

```cpp
struct PageBuildCacheEntry {
    VfsPageKey page_key;

    Hash128 raw_page_hash;
    Hash128 compress_info_hash;
    Hash128 stored_page_hash;

    uint32_t raw_size;
    uint32_t stored_size;
};
```

---

# 7. Merge / Patch 设计

## 7.1 Merge 输入

merge 输入是 `PatchManifest` 或 `DiffDesc`。

```cpp
struct PatchManifest {
    uint32_t version;

    uint16_t target_pack_id;
    uint16_t flags;

    uint64_t base_pack_version;
    uint64_t patch_version;

    std::vector<FilePatchDesc> files;
};

struct FilePatchDesc {
    VfsFileManifestKey file_key;
    PatchOp op; // AddFile / DeleteFile / ModifyFile

    uint64_t old_file_size;
    uint64_t new_file_size;

    Hash128 old_content_hash;
    Hash128 new_content_hash;

    std::vector<PagePatchDesc> pages;
};

struct PagePatchDesc {
    VfsPageKey page_key;
    PagePatchOp op; // AddPage / DeletePage / ModifyPage / ReusePage

    uint64_t source_offset;
    uint64_t source_size;

    CompressInfo compress;
};
```

## 7.2 Merge 输出

merge 最终转成：

```cpp
struct PackMutationPlan {
    uint16_t pack_id;
    std::vector<FileMutation> files;
};

struct FileMutation {
    VfsFileManifestKey file_key;
    MutationOp op; // Add / Modify / Delete

    std::vector<PageMutation> pages;
};

struct PageMutation {
    VfsPageKey page_key;
    MutationOp op; // Add / Modify / Delete / Reuse

    CompressInfo compress;
    DiffPayloadRef payload;
};
```

build 和 merge 后续都走 `PackMutationPlan`。

```text
build_cfg -> BuildPlanner -> PackMutationPlan
diff_desc -> MergePlanner -> PackMutationPlan
```

统一执行：

```text
PackMutationExecutor
  read source/diff
  split page
  compress
  write page KV
  delete old page KV
  write file manifest
  commit pack manifest
```

---

# 8. InMemory FileOps

## 8.1 目标

merge 经常有大量小块 IO：

```text
1. 读旧 index。
2. 查旧 page。
3. 写新 page。
4. 删除旧 page。
5. 更新 manifest。
6. 更新 delta index。
```

如果每一步都落到磁盘随机 IO，整体会很慢。

因此支持 `InMemoryFileOps`：

```text
open 时将 index/data 文件读入内存；
所有 pread/pwrite/resize 在内存 buffer 上完成；
merge 完成后整体写出。
```

## 8.2 FileOps 接口

```cpp
struct DbFileOps {
    void* user;

    DbResult (*open)(
        void* user,
        const char* path,
        DbOpenFlags flags,
        DbFileHandle* out
    );

    DbResult (*close)(DbFileHandle file);

    DbResult (*pread)(
        DbFileHandle file,
        void* buf,
        uint64_t size,
        uint64_t offset
    );

    DbResult (*pwrite)(
        DbFileHandle file,
        const void* buf,
        uint64_t size,
        uint64_t offset
    );

    DbResult (*resize)(
        DbFileHandle file,
        uint64_t new_size
    );

    DbResult (*size)(
        DbFileHandle file,
        uint64_t* out_size
    );

    DbResult (*flush)(
        DbFileHandle file,
        DbFlushMode mode
    );

    DbResult (*mmap)(
        DbFileHandle file,
        DbMmapDesc* desc,
        DbMmapHandle* out
    );

    DbResult (*munmap)(
        DbMmapHandle mapping
    );
};
```

## 8.3 InMemoryFile

```cpp
struct MemoryFile {
    std::string path;
    std::vector<uint8_t> buffer;

    bool dirty;
    bool readonly;

    uint64_t logical_size;
};
```

行为：

```text
open:
  文件存在则完整读入 buffer。
  文件不存在且允许 create，则创建空 buffer。

pread:
  从 buffer memcpy。

pwrite:
  自动扩容 buffer。
  memcpy。
  dirty = true。

resize:
  buffer.resize(new_size)。
  dirty = true。

flush:
  写到临时文件。
  fsync。
  rename 替换原文件。
```

## 8.4 使用策略

```text
小到中等 pack:
  使用 full inmemory merge。

超大 pack:
  使用 disk file ops 或 hybrid file ops。

meta pack:
  可以使用 inmemory merge，但需要更严格事务。
```

配置：

```cpp
struct MergeFileOpsOptions {
    bool enable_inmemory;
    uint64_t max_inmemory_pack_size;
    uint64_t max_inmemory_total_bytes;
    bool use_shadow_output;
};
```

---

# 9. Resource Task Graph

## 9.1 为什么需要 Resource Task Graph

merge/build 不是简单线程池能解决的问题。

原因：

```text
1. IO 任务太多会互相阻塞。
2. CPU 压缩任务太少吃不满 CPU。
3. DB 写任务太多会抢 allocator/index lock。
4. 不同 pack 大小差异极大。
5. 有些任务跨版本、跨 pack、跨 meta 依赖。
6. meta pack 必须最后原子提交。
7. 目标不是“尽快启动任务”，而是“整个图最短时间完成”。
```

因此需要构建一张全局 `Resource Task Graph`，一次更新涉及的所有 pack、page、manifest、meta 更新都在一张图里调度。

---

## 9.2 Resource Task Graph 的目标

```text
目标:
  在资源约束下，让整张更新图的 makespan 最小。

资源包括:
  1. 磁盘读带宽
  2. 磁盘写带宽
  3. 随机 IO 并发数
  4. CPU 压缩线程
  5. CPU 解压线程
  6. DB 写并发
  7. 内存 inflight buffer
  8. pack lock
  9. meta transaction lock
```

换句话说：

```text
不是所有 ready task 都应该立即运行。
调度器必须控制每类任务的并发度和资源占用。
```

---

# 10. Task 类型

## 10.1 基础任务类型

```cpp
enum class TaskType {
    ReadSource,
    ReadOldPage,
    ReadDiffPayload,

    HashPage,
    CompressPage,
    DecompressPage,

    AddPage,
    ModifyPage,
    DeletePage,

    WritePageKV,
    WriteFileManifest,
    DeleteFileManifest,

    UpdatePackManifest,
    CheckpointPack,

    UpdateMetaPack,
    CommitMetaTransaction,

    FlushPack,
    VerifyPack,
};
```

## 10.2 任务资源类型

```cpp
enum class ResourceClass {
    DiskRead,
    DiskWrite,
    RandomIO,
    SequentialIO,

    CpuCompress,
    CpuHash,
    CpuGeneric,

    DbRead,
    DbWrite,
    DbCheckpoint,

    MemoryBuffer,

    PackExclusive,
    MetaExclusive,
};
```

每个 task 声明资源需求：

```cpp
struct TaskResourceNeed {
    ResourceClass resource;
    uint32_t units;
    uint64_t bytes;
};
```

例如：

```text
ReadDiffPayload:
  DiskRead 1
  MemoryBuffer payload_size

CompressPage:
  CpuCompress 1
  MemoryBuffer raw_size + compressed_bound

WritePageKV:
  DiskWrite 1
  DbWrite 1

CommitMetaTransaction:
  MetaExclusive 1
  DiskWrite 1
```

---

# 11. Task Graph 数据结构

```cpp
using TaskId = uint64_t;

struct ResourceTask {
    TaskId id;
    TaskType type;

    uint16_t pack_id;
    VfsFileManifestKey file_key;
    VfsPageKey page_key;

    std::vector<TaskId> deps;
    std::vector<TaskId> users;

    std::vector<TaskResourceNeed> resources;

    uint64_t estimated_cost_ns;
    uint64_t estimated_input_bytes;
    uint64_t estimated_output_bytes;

    TaskPriority priority;

    TaskState state;

    void* payload;
};
```

TaskState：

```cpp
enum class TaskState {
    Pending,
    Ready,
    Running,
    Finished,
    Failed,
    Cancelled,
};
```

Graph：

```cpp
struct ResourceTaskGraph {
    std::vector<ResourceTask> tasks;

    std::vector<TaskId> ready_queue;

    uint64_t total_estimated_work;
    uint64_t critical_path_cost;
};
```

---

# 12. 一个文件修改的任务拆分

对于一个 modified file：

```text
ModifyFile
  ├── ReadOldManifest
  ├── For each changed page:
  │     ├── ReadDiffPayload
  │     ├── CompressPage
  │     └── WritePageKV
  ├── For each deleted page:
  │     └── DeletePageKV
  ├── BuildNewFileManifest
  └── WriteFileManifest
```

依赖：

```text
ReadDiffPayload -> CompressPage -> WritePageKV
DeletePageKV --------------------\
                                  -> WriteFileManifest
WritePageKV ---------------------/
```

对于 pack：

```text
All FileManifest tasks
  -> UpdatePackManifest
  -> CheckpointPack
```

对于 volume：

```text
All PackManifest tasks
  -> UpdateMetaPack
  -> CommitMetaTransaction
```

---

# 13. 跨版本更新

跨版本更新可能是：

```text
v1 -> v2 -> v3
```

也可能是：

```text
当前版本 v1，直接应用 v3 全量 diff
```

Resource Task Graph 应该一次性展开所有更新步骤。

## 13.1 PatchChain

```cpp
struct PatchChain {
    uint64_t from_version;
    uint64_t to_version;

    std::vector<PatchManifest> patches;
};
```

图构建：

```text
1. 读取当前 volume/pack version。
2. 选择 patch chain。
3. 展开所有 patch 的 FilePatchDesc。
4. 对同一个 file/page 做合并。
5. 生成最终 PackMutationPlan。
6. 再生成 Resource Task Graph。
```

## 13.2 多版本合并优化

如果 v1->v2 修改 page A，v2->v3 又修改 page A：

```text
不需要执行两次 ModifyPage。
只需要最终 v3 的 page。
```

如果 v1->v2 add page，v2->v3 delete page：

```text
两个任务可以抵消。
```

如果 v1->v2 delete file，v2->v3 add same file：

```text
变成 replace file。
```

因此图构建前需要做 `PatchCoalescing`。

```cpp
struct CoalescedMutation {
    VfsPageKey page_key;
    MutationOp final_op;
    DiffPayloadRef final_payload;
};
```

---

# 14. 调度器设计

## 14.1 基础目标

调度器不是简单：

```text
while ready:
  start all ready tasks
```

而是：

```text
在资源预算允许的前提下，选择最有价值的 ready task 运行。
```

## 14.2 ResourceBudget

```cpp
struct ResourceBudget {
    uint32_t max_disk_read_tasks;
    uint32_t max_disk_write_tasks;
    uint32_t max_random_io_tasks;

    uint32_t max_compress_tasks;
    uint32_t max_hash_tasks;
    uint32_t max_db_write_tasks;

    uint64_t max_inflight_read_bytes;
    uint64_t max_inflight_write_bytes;
    uint64_t max_inflight_memory_bytes;

    uint32_t max_pack_exclusive_tasks;
    uint32_t max_meta_exclusive_tasks;
};
```

示例：

```text
SSD:
  max_disk_read_tasks = 4~8
  max_disk_write_tasks = 2~4
  max_random_io_tasks = 4

HDD:
  max_disk_read_tasks = 1~2
  max_disk_write_tasks = 1
  max_random_io_tasks = 1

CPU:
  max_compress_tasks = physical_core_count - 2

DB:
  max_db_write_tasks = 1~4
```

## 14.3 资源令牌

每类资源用 token 控制。

```cpp
struct ResourceTokenPool {
    ResourceClass resource;
    uint32_t total_units;
    uint32_t used_units;

    uint64_t total_bytes;
    uint64_t used_bytes;
};
```

task 只有在所有资源都可获得时才可运行。

---

# 15. 调度策略

## 15.1 基础 ready queue

ready task 分多队列：

```text
IO read queue
CPU compress queue
DB write queue
Manifest queue
Meta queue
```

不要一个全局 FIFO。

## 15.2 优先级计算

每个 task 的优先级可以由：

```text
1. critical path length
2. task 类型
3. pack 优先级
4. page 是否阻塞 manifest
5. estimated cost
6. 当前资源空闲情况
```

计算：

```cpp
priority =
    critical_path_score * 4
  + pack_priority * 2
  + unblock_score * 3
  - resource_pressure_penalty
```

## 15.3 关键路径优先

先计算每个 task 到图终点的最长路径：

```text
critical_path_cost(task)
```

调度时优先跑关键路径上的 task，减少整体 makespan。

## 15.4 IO/CPU 平衡

如果 CPU 压缩队列空了，但 IO read 队列过少，说明 CPU 饥饿，应增加 read 并发。

如果大量 read task running，但 compress 队列堆积，说明 CPU 已满，应限制 read，避免内存膨胀。

可以做动态调节：

```cpp
if (compress_queue_empty && disk_read_idle) {
    increase_read_window();
}

if (compress_queue_size > high_watermark) {
    decrease_read_window();
}

if (inflight_memory > memory_high_watermark) {
    stop_scheduling_read_tasks();
}
```

---

# 16. Task Graph Scheduler 执行循环

```cpp
while (!graph.finished()) {
    collect_finished_tasks();

    for each finished task:
        release resources;
        mark dependent tasks ready if deps complete;

    update_resource_pressure();

    while (true) {
        task = pick_best_ready_task();

        if (!task) break;

        if (!resources_available(task)) {
            mark_temporarily_blocked(task);
            continue;
        }

        acquire_resources(task);
        dispatch(task);
    }

    wait_for_event();
}
```

dispatch 根据 task 类型进入不同 executor：

```text
IOExecutor
CPUExecutor
DBExecutor
MetaExecutor
```

---

# 17. Executor 设计

## 17.1 IOExecutor

负责：

```text
ReadSource
ReadOldPage
ReadDiffPayload
Disk writeback
```

控制：

```text
max_disk_read_tasks
max_disk_write_tasks
max_random_io_tasks
```

## 17.2 CPUExecutor

负责：

```text
HashPage
CompressPage
DecompressPage
BuildManifest
```

控制：

```text
max_compress_tasks
max_hash_tasks
max_cpu_generic_tasks
```

## 17.3 DBExecutor

负责：

```text
WritePageKV
DeletePageKV
WriteFileManifest
CheckpointPack
```

控制：

```text
max_db_write_tasks
pack-level write serialization
```

## 17.4 MetaExecutor

负责：

```text
UpdateMetaPack
CommitMetaTransaction
```

必须强串行：

```text
max_meta_exclusive_tasks = 1
```

---

# 18. Pack 级并发限制

同一个 pack 的 DB 写入可以并发，但某些阶段必须串行：

```text
可并发:
  WritePageKV
  DeletePageKV
  ReadOldPage

需要 pack exclusive:
  UpdatePackManifest
  CheckpointPack
  FinalizePack
```

因此 task 需要声明：

```text
PackShared(pack_id)
PackExclusive(pack_id)
```

规则：

```text
多个 PackShared 可以并行。
PackExclusive 需要等待该 pack 所有 shared 结束。
PackExclusive 期间不能启动新的 shared。
```

---

# 19. Meta 级并发限制

meta pack 是 volume 控制面，必须更严格：

```text
UpdateMetaPack
CommitMetaTransaction
```

需要：

```text
MetaExclusive
```

所有 pack 更新完成后才进入 meta commit。

---

# 20. InMemory merge 与 Task Graph 结合

如果某 pack 使用 InMemoryFileOps：

```text
1. LoadPackToMemory task
2. 所有该 pack 的 DB tasks 都在内存 file ops 上执行
3. FlushPackToDisk task
4. VerifyPack task
5. CommitPackVersion task
```

图结构：

```text
LoadPackToMemory
  -> page tasks
  -> manifest tasks
  -> FlushPackToDisk
  -> VerifyPack
  -> CommitPackVersion
```

Load/Flush 是 IO 大任务，需要资源控制：

```text
LoadPackToMemory:
  DiskRead
  MemoryBuffer pack_size

FlushPackToDisk:
  DiskWrite
  MemoryBuffer pack_size
```

所以不能同时对太多大 pack 做 inmemory merge。

---

# 21. 大小包混合调度

大型游戏可能有：

```text
大量几 MB 小 pack
少量上 GB 大 pack
```

调度策略：

```text
小 pack:
  可使用 inmemory merge。
  多 pack 并行。

大 pack:
  使用 streaming merge。
  限制并发。
  优先 page 级任务流水线。
```

避免：

```text
1. 一个大 pack 占满所有 IO。
2. 大量小 pack 同时 flush 造成写入抖动。
3. CPU 压缩线程等 IO。
4. IO 线程读太多导致内存爆。
```

---

# 22. 任务代价估算

每个 task 要有成本估算：

```cpp
struct TaskCostEstimate {
    uint64_t io_read_bytes;
    uint64_t io_write_bytes;
    uint64_t cpu_cycles;
    uint64_t memory_bytes;
    uint64_t estimated_ns;
};
```

估算来源：

```text
1. 历史统计。
2. 文件大小。
3. codec 类型。
4. 压缩等级。
5. 设备类型。
6. pack 大小。
```

压缩任务估算：

```text
estimated_ns = raw_size / codec_estimated_throughput
```

IO 任务估算：

```text
estimated_ns = bytes / current_io_bandwidth + random_io_penalty
```

---

# 23. 自适应调度

运行时统计：

```cpp
struct RuntimeStats {
    double disk_read_mb_s;
    double disk_write_mb_s;
    double compress_mb_s;
    double db_write_ops_s;

    uint32_t avg_io_latency_us;
    uint32_t avg_db_write_latency_us;

    uint64_t inflight_memory_bytes;
};
```

根据统计动态调整：

```text
如果 IO latency 升高:
  降低 max_random_io_tasks。

如果 CPU compress idle:
  增加 read window。

如果 memory pressure 高:
  暂停 read tasks，优先 drain compress/write。

如果 DB write latency 高:
  降低 db_write_tasks。
```

---

# 24. 失败与恢复

## 24.1 Task 失败

task 失败后：

```text
1. 标记 task failed。
2. 取消依赖它的后续 task。
3. 对已经写入但未 commit 的 page 保持 orphan。
4. pack manifest 不提交。
5. meta transaction 不提交。
6. 下次恢复时 GC orphan page。
```

## 24.2 pack 原子性

一个 pack 更新成功的标志不是所有 page 写完，而是：

```text
PackManifest committed
```

流程：

```text
WritePageKV tasks
  -> WriteFileManifest tasks
  -> UpdatePackManifest
  -> CheckpointPack
  -> CommitPackVersion
```

没有 commit pack version，更新不应对外可见。

## 24.3 volume 原子性

跨 pack 更新时，最终由 meta pack 提交 volume version。

```text
All packs committed to staging version
  -> UpdateMetaPack
  -> CommitMetaTransaction
```

如果 meta commit 失败：

```text
volume 仍指向旧版本。
已写 out pack staging 数据可在下次恢复中继续或清理。
```

---

# 25. 版本与 Staging

为了支持跨版本更新和失败恢复，建议 out pack 支持 staging version：

```text
out_pack/
  current/
  staging_102/
```

或者 DB 内部有 version epoch：

```text
pack_version_current
pack_version_staging
```

更新流程：

```text
1. 所有 page 写入 staging。
2. manifest 写入 staging。
3. pack commit 后 current 指向 staging。
4. meta commit 后 volume version 更新。
```

V1 可以简化：

```text
直接写 out pack delta。
失败后通过 journal 恢复。
```

但如果跨多个 pack 一次性更新，建议引入 staging，避免部分 pack 可见、meta 不一致。

---

# 26. Merge/build 统一接口

```cpp
class PackMutationExecutor {
public:
    Result execute(
        VfsVolumeHandle volume,
        const PackMutationPlan& plan,
        const PackMutationOptions& options
    );
};

struct PackMutationOptions {
    bool incremental;
    bool page_level_incremental;

    bool use_inmemory_file_ops;
    uint64_t max_inmemory_pack_bytes;
    uint64_t max_inmemory_total_bytes;

    ResourceBudget resource_budget;

    bool use_staging;
    bool atomic_volume_commit;
};
```

Build：

```cpp
PackMutationPlan plan = BuildPlanner::create(build_cfg);
executor.execute(volume, plan, options);
```

Merge：

```cpp
PatchChain chain = PatchPlanner::select(current_version, target_version);
PackMutationPlan plan = MergePlanner::create(chain);
executor.execute(volume, plan, options);
```

---

# 27. 推荐模块划分

```text
vfs/
  volume.h
  pack.h
  mount_table.h
  meta_pack.h
  handle_cache.h

pack_processing/
  key.h
  file_manifest.h
  page_value.h

  compress/
    compressor.h
    compressor_registry.h
    lz4_codec.h
    zstd_codec.h
    oodle_codec.h

  build/
    build_cfg.h
    build_planner.h
    build_cache.h

  merge/
    patch_manifest.h
    patch_chain.h
    merge_planner.h
    patch_coalescer.h

  mutation/
    mutation_plan.h
    mutation_executor.h

  task_graph/
    resource_task.h
    resource_task_graph.h
    resource_budget.h
    scheduler.h
    executors.h

  file_ops/
    db_file_ops.h
    disk_file_ops.h
    inmemory_file_ops.h
    hybrid_file_ops.h
```

---

# 28. 第一版实现建议

## V1 必须实现

```text
1. VfsPageKey / VfsFileManifestKey 结构体 key。
2. PageValueHeader。
3. FileManifest。
4. CompressorRegistry。
5. file -> block -> page 构建。
6. page KV 写入。
7. file manifest 写入。
8. 文件级增量 build。
9. merge 转 PackMutationPlan。
10. Resource Task Graph 基础调度。
11. IO/CPU/DB 三类资源限流。
12. InMemoryFileOps。
```

## V1 可简化

```text
1. page 级增量可暂缓。
2. 跨 inner/out 复用 page 可暂缓。
3. 复杂自适应调度可先用静态预算。
4. staging version 可先做 pack 级，不做 volume 级。
5. task cost 可先粗略按 bytes 估算。
```

## V2 再做

```text
1. page 级增量。
2. patch coalescing 跨多版本优化。
3. adaptive scheduler。
4. hybrid inmemory file ops。
5. staging + atomic volume commit。
6. task critical path scheduling。
7. IO 设备类型自学习。
8. pack priority / scene priority。
```

---

# 29. 最终方案总结

最终中间层设计为：

```text
Pack Processing Layer
```

它提供：

```text
1. 结构体 key，而不是三元组 hash key。
2. FileManifest 管理逻辑文件。
3. PageValueHeader 让 page value 可独立解压、校验、恢复。
4. block 作为压缩策略单位。
5. page 作为 KV 存储单位。
6. CompressorRegistry 抽象多种压缩算法。
7. build/merge 统一转换成 PackMutationPlan。
8. merge/build 使用 Resource Task Graph 做全局调度。
9. Resource Task Graph 控制 IO、CPU、DB、内存、pack/meta exclusive 资源。
10. InMemoryFileOps 用于小/中 pack 的高效 merge。
11. 增量构建优先文件级，后续扩展到 page 级。
12. 跨版本 patch 先 coalesce，再生成任务图，避免重复无效更新。
```

最核心的原则：

```text
VFS 管 pack 该从哪里读。
Pack Processing 管文件如何拆、压缩、更新。
KV DB 管 key-value 如何存。
Resource Task Graph 管所有任务如何最快完成。
```
