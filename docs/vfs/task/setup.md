# VFS 任务公共上下文

本文是所有 VFS 实现任务的公共上下文。任何 agent 在执行 docs/vfs/task/ 下的任务前，必须先阅读本文，再阅读对应 task 文件。只阅读本文与具体 task 文件，应足以准确完成该任务。

---

## 1. 项目状态

当前仓库已经实现 DB 层，VFS 尚未实现。

DB 当前能力：

- 对外 ABI 是 db_*。
- handle 类型是 uint64_t db_handle_t，0 为 invalid。
- public key 是 raw byte slice：(const void* key, uint64_t key_size)。
- DB 内部会把 raw key bytes 映射到内部 key。
- data record 持久化 raw key bytes，并在读取时校验。
- 支持 db_create、db_open、db_get_size、db_get_into、db_put、db_delete、db_commit、db_batch_*、db_snapshot_*、db_checkpoint、db_verify、db_optimize、db_recover。
- base/delta index mmap，data file 不整体 mmap。
- 写入顺序是 data record first、journal commit second、delta publish last。

重要限制：

- db_context_t.file_ops 当前在 ABI 中存在，但完整 custom file backend 尚未实现。
- 传入非空 file_ops 当前会返回 DB_UNSUPPORTED。
- VFS 需要 InMemoryFileOps，因此必须先实现 DB file_ops 支持，见 task_00_db_file_ops_inmemory.md。

---

## 2. VFS 总体目标

VFS 是 DB 之上的资源虚拟文件系统库。

~~~text
Engine / Runtime / Editor
  open(path)
  open(FileEntry)
  read_at / stat / list_dir / write / delete

VFS Runtime Layer
  volume / mount table / overlay resolver / path index
  file entry resolver / file handle / page cache

VFS Pack Format Layer
  pack manifest / path index / directory manifest
  file manifest / page value / tombstone / compression

VFS Build + Mutation Layer
  build cfg / pack builder / mutation plan / merge / patch
  task graph / verify / repair tools

DB Layer
  key-value / batch / snapshot / checkpoint / verify / optimize
~~~

VFS 不重新实现 DB 的 record、journal、index、checkpoint、allocator。VFS 只定义资源文件如何拆分为 DB object、如何挂载 pack、如何解析 overlay、如何打开和读取文件、如何构建和更新 pack。

完整背景文档：

- docs/vfs/vfs_arch.md
- docs/vfs/vfs_roadmap.md
- docs/design/vfs/vfs.md
- README.md

具体实现必须以本文和当前 task 文件为准。背景文档用于理解，不得用旧草案覆盖 task 中的明确约束。

---

## 3. 核心语义约束

### 3.1 VFS public 层只支持 u64 FileEntry

VFS 对外暴露的逻辑文件入口是：

~~~c
typedef uint64_t vfs_file_entry_t;
~~~

规则：

- 0 是 invalid FileEntry。
- 非 0 是稳定逻辑文件 ID。
- FileEntry 可以来自路径 hash、资源 GUID、导入 ID、资产 ID。
- VFS public API 不暴露 128-bit file id。
- path 只是找到 FileEntry 的一种方式。

### 3.2 vfs_open 必须支持两种入口

必须实现两条打开路径：

~~~text
vfs_open_path:
  path -> normalize -> PathIndex -> FileEntry -> common open

vfs_open_entry:
  FileEntry -> EntryResolver -> FileManifest -> file handle
~~~

entry open 不能依赖 path，也不能要求 PathIndex 里存在对应 path。

### 3.3 DB object key 使用 u64

VFS 面向 DB 时使用 u64 object key。

必须集中实现 object key 派生：

~~~text
PACK_MANIFEST_KEY
PATH_INDEX_KEY
DIRECTORY_MANIFEST_KEY
file_manifest_key(file_entry)
page_key(file_entry, block_index, page_index)
build_cache_key(...)
patch_manifest_key(...)
~~~

VFS 不把复杂结构体 key 暴露给上层。page/file/manifest 的 identity 必须写在 value header 中，并在读取时反向校验。

### 3.4 u64 碰撞处理

V1 不实现 collision bucket。必须使用强校验避免静默错读。

写入规则：

- 构建 pack 时必须检测所有生成 object key 唯一。
- 写 writable pack 时，如果目标 object key 已存在，必须读取旧 value header 并校验 identity。
- key 相同但 identity 不同时返回 VFS_KEY_COLLISION。
- 禁止静默覆盖 identity 不同的 value。

读取规则：

- 读取 FileManifest 后必须校验 header.file_entry。
- 读取 PageValue 后必须校验 header.file_entry、block_index、page_index。
- header/checksum/identity 任一不匹配都不能返回数据。

---

## 4. 硬性禁止

### 4.1 禁止 mock / moke

禁止为了通过测试而写 mock/moke 实现。

包括但不限于：

- 用内存 map 假装 pack DB。
- 用固定数组假装 PathIndex。
- 用固定返回值假装 DB IO 成功。
- 用伪 CRC、伪 hash、伪 flush、伪 compression。
- 在实现中根据测试文件名、测试 key、测试路径特殊分支。
- 写“后续替换为真实实现”的核心路径。

允许测试 helper，但测试 helper 只能在 test 代码中使用，不能进入生产路径。

### 4.2 禁止 callback public API

VFS public C ABI 禁止 callback 风格 API。

禁止：

- streaming read callback。
- async completion callback。
- 用户传入函数指针由 VFS 反调。
- Zig public API 中以 callback/closure 作为核心读取方式。

允许：

- caller 提供 buffer，VFS 填充。
- 两阶段 API：先 stat/get_size，再读入 caller buffer。
- future explicit reader handle，由 caller 主动 read_next。

### 4.3 禁止破坏 DB/VFS 库边界

DB 和 VFS 是两个独立库：

~~~text
libdb:
  src/db/
  include/db.h
  db_* ABI

libvfs:
  src/vfs/
  include/vfs.h
  vfs_* ABI
~~~

禁止：

- 在 DB 中导出 vfs_*。
- 在 VFS 中导出 db_*。
- DB import/include VFS。
- 把路径、mount、overlay 写进 DB 文件格式。

VFS 可以 import/link DB。

---

## 5. 文件格式要求

所有 VFS 磁盘格式必须：

- 使用固定宽度整数。
- little-endian encode/decode。
- 不写进程指针。
- 不写 slice。
- enum 明确 backing integer。
- 保留字段写 0。
- header 带 magic/version/header_size。
- value 带 checksum 或 CRC。
- 读取时校验 magic/version/size/crc/identity。
- 有 comptime assert 或单元测试覆盖结构尺寸/编码尺寸。

禁止直接把普通 Zig struct 裸写为磁盘格式，除非该 struct 是严格审查过的 extern/packed layout，并有跨平台 size/alignment 测试。推荐使用显式 encode/decode。

---

## 6. 关键对象

### 6.1 Pack

一个 pack 底层对应一个 DB store：

~~~text
pack_xxx/
  index.db
  data_000.db
  data_001.db
  ...
~~~

pack 中保存：

- PackManifest
- PathIndex
- DirectoryManifest
- FileManifest
- PageValue
- Tombstone
- Build cache

### 6.2 PathIndex

PathIndex 是 path -> FileEntry 的索引。DB 不负责 path prefix/range scan。

PathIndex 必须保存 normalized path bytes，用于处理 path_hash 碰撞。

查找流程：

~~~text
normalize path
  -> hash64(normalized_path)
  -> bucket lookup
  -> compare full normalized path bytes
  -> FileEntry
~~~

### 6.3 EntryResolver

EntryResolver 是 FileEntry -> visible FileLocation 的 overlay 解析器。

规则：

- priority 高的 pack 覆盖 priority 低的 pack。
- writable out pack 默认最高优先级。
- tombstone 隐藏低优先级版本。
- 同 priority 的处理必须稳定；推荐 V1 直接返回配置错误，避免不同机器解析不同。

### 6.4 FileManifest

FileManifest 描述一个逻辑文件如何由 block/page 组成。

V1 使用 implicit page key：

~~~text
page_key(file_entry, block_index, page_index)
~~~

V2 可实现 explicit PageRef，用于 page-level incremental 和跨 pack page 复用。

### 6.5 PageValue

PageValue 格式：

~~~text
[PageValueHeader][payload]
~~~

PageValueHeader 至少包含：

- magic/version/header_size
- file_entry
- block_index/page_index
- codec/codec_flags
- raw_size/stored_size
- raw_crc/stored_crc
- content_hash
- page_flags
- header_crc

---

## 7. 推荐源码布局

~~~text
src/vfs/
  root.zig
  abi.zig
  error.zig
  handle_registry.zig
  object_key.zig
  hash.zig

  format/
    pack_manifest.zig
    path_index.zig
    directory_manifest.zig
    file_manifest.zig
    page_value.zig
    tombstone.zig

  pack/
    pack.zig
    pack_reader.zig
    pack_writer.zig
    manifest_cache.zig

  volume/
    volume.zig
    mount_table.zig
    overlay_resolver.zig
    entry_resolver.zig
    path_resolver.zig

  io/
    file_handle.zig
    read_plan.zig
    page_cache.zig

  compress/
    compressor.zig
    registry.zig
    none.zig
    lz4.zig
    zstd.zig

  build/
    build_cfg.zig
    build_plan.zig
    build_cache.zig
    pack_builder.zig

  mutation/
    mutation_plan.zig
    mutation_executor.zig
    merge_planner.zig
    task_graph.zig

tools/
  vfs.zig

include/
  vfs.h
~~~

可以根据现有仓库结构适配，但职责边界必须清晰。

---

## 8. 公共 C ABI 方向

基础 ABI：

~~~c
typedef uint64_t vfs_volume_t;
typedef uint64_t vfs_file_t;
typedef uint64_t vfs_file_entry_t;

int vfs_open_volume(const char* path, const vfs_open_options_t* options, vfs_volume_t* out_volume);
int vfs_close_volume(vfs_volume_t volume);
int vfs_mount_pack(vfs_volume_t volume, const char* pack_path, uint32_t priority, uint32_t flags);

int vfs_open_path(vfs_volume_t volume, const char* path, uint32_t flags, vfs_file_t* out_file);
int vfs_open_entry(vfs_volume_t volume, uint64_t file_entry, uint32_t flags, vfs_file_t* out_file);

int vfs_stat_path(vfs_volume_t volume, const char* path, vfs_stat_t* out_stat);
int vfs_stat_entry(vfs_volume_t volume, uint64_t file_entry, vfs_stat_t* out_stat);

int vfs_read_at(vfs_file_t file, uint64_t offset, void* dst, uint64_t size, uint64_t* out_read);
int vfs_close_file(vfs_file_t file);
~~~

ABI struct 必须包含 struct_size，并支持向后兼容读取。

---

## 9. 通用验证要求

每个 task 至少需要：

- Zig 单元测试。
- 文件级集成测试。
- C ABI smoke test，如果 task 涉及 public ABI。
- 错误路径测试。
- 损坏文件/损坏 value 测试，如果 task 涉及磁盘格式。
- no mock/moke 说明。
- no callback 说明。
- 不破坏已有 zig build test。

推荐验证命令：

~~~powershell
zig build
zig build test
zig build -Doptimize=ReleaseSafe
zig build test -Doptimize=ReleaseSafe
~~~

如果某 task 因依赖未实现不能跑完整命令，必须在最终说明中写清楚缺失依赖和已完成的可运行验证。

---

## 10. 任务依赖顺序

推荐顺序：

~~~text
task_00_db_file_ops_inmemory.md
task_01_vfs_abi_skeleton.md
task_02_object_keys_and_formats.md
task_03_pack_builder_minimal.md
task_04_pack_reader_open_read.md
task_05_volume_mount_overlay.md
task_06_page_cache_and_compression.md
task_07_writable_out_pack.md
task_08_verify_recover_tools.md
task_09_build_cfg_incremental.md
task_10_merge_patch_mutation.md
task_11_page_level_incremental.md
task_12_task_graph_scheduler.md
task_13_volume_atomic_commit.md
~~~

如果前序任务未完成，当前任务必须停止并报告阻塞，不得用 mock 代替。

---

## 11. 完成定义

一个 task 完成必须满足：

- 生产路径是真实实现。
- 没有 mock/moke。
- 没有新增 callback public API。
- 不破坏 DB/VFS 边界。
- 磁盘格式有 encode/decode 与校验。
- 错误路径可预测，不 panic、不越界、不泄漏 handle。
- 验证流程全部通过，或明确说明被真实依赖阻塞。
- 未实现项清楚标明“不在本 task 范围内”。

