# VFS 架构设计

## 0. 定位

VFS 位于游戏或引擎的资源访问层与底层 KV DB 之间。它对上提供“文件系统式”的访问语义，对下只依赖 DB 的 key-value 原语。

~~~text
Engine / Runtime / Editor
  open(path)
  open(FileEntry)
  read_at / stat / list_dir / write / delete

VFS Runtime Layer
  volume
  mount table
  overlay resolver
  path index
  file entry resolver
  file handle cache
  page cache

VFS Pack Format Layer
  pack manifest
  directory manifest
  file manifest
  page value
  compression
  tombstone

VFS Build / Mutation Layer
  build cfg
  build plan
  mutation plan
  merge / patch
  pack writer
  verify / repair tools

KV DB Layer
  u64 key -> value
  batch
  snapshot
  checkpoint
  verify
  optimize
~~~

VFS 不重新实现 DB 的索引、journal、record、checkpoint、allocator 等能力。VFS 的职责是定义资源文件如何映射为 DB object、如何挂载多个 pack、如何解析 overlay、如何读取 page、如何更新 out pack。

---

## 1. 核心约束

### 1.1 VFS 层只支持 u64 FileEntry

VFS 对外暴露的逻辑文件入口是：

~~~c
typedef uint64_t vfs_file_entry_t;
~~~

约定：

~~~text
0:
  invalid entry。

非 0:
  稳定逻辑文件入口 ID。
  可以来自路径 hash、资源 GUID hash、导入系统生成 ID、资产注册表 ID。
~~~

VFS 不在 public API 中暴露 128-bit file id，也不要求调用方传入结构体 key。

### 1.2 vfs_open 支持两种入口

VFS 文件打开支持两条路径：

~~~text
1. path open
   传入虚拟路径。
   VFS 通过 PathIndex 找到 FileEntry。

2. entry open
   直接传入 FileEntry，也就是 u64。
   VFS 跳过 PathIndex，直接解析该 FileEntry 当前可见的文件版本。
~~~

C ABI 可以提供两个清晰函数：

~~~c
int vfs_open_path(
    vfs_volume_t volume,
    const char* path,
    uint32_t flags,
    vfs_file_t* out_file
);

int vfs_open_entry(
    vfs_volume_t volume,
    uint64_t file_entry,
    uint32_t flags,
    vfs_file_t* out_file
);
~~~

内部统一收敛为：

~~~text
OpenRequest
  kind = Path | FileEntry
  path | file_entry
  flags
~~~

### 1.3 DB key 使用 u64 object key

VFS 面向 DB 时也使用 u64 key。VFS 内部不会把多字段结构体 key 直接交给 DB，而是把 VFS object 派生为稳定的 u64 object key。

~~~text
FileManifestKey  = hash64("vfs.file_manifest.v1", file_entry)
PageKey          = hash64("vfs.page.v1", file_entry, block_index, page_index)
PackManifestKey  = reserved constant
PathIndexKey     = reserved constant
DirectoryKey     = reserved constant or hash64(namespace, chunk_id)
~~~

其中 reserved key 必须集中定义，所有构建工具在输出 pack 前都要检查生成 key 是否与 reserved key 冲突。

### 1.4 u64 碰撞策略

因为 VFS 与 DB 都使用 u64 key，必须显式定义碰撞策略。

V1 策略：

~~~text
1. 构建 pack 时，对所有生成的 object key 做唯一性检查。
2. 写入 runtime out pack 时，如果目标 DB key 已存在，必须读取旧 value header 校验 identity。
3. 如果 key 相同但 identity 不同，返回 VFS_KEY_COLLISION。
4. 读取 PageValue / FileManifest 时，必须校验 header 中的 file_entry、block_index、page_index。
5. 碰撞不做自动 bucket 化，不静默覆盖。
~~~

V2 可以增加 collision bucket：

~~~text
DB key -> CollisionBucket value
CollisionBucket 内存多个 object record
每个 record 带完整 identity
~~~

但 V1 不建议一开始引入 bucket，否则所有 hot path 都会复杂化。先让构建和写入阶段做强检测，读取阶段做强校验，是比较稳的落点。

---

## 2. 主要对象

### 2.1 Volume

Volume 是 VFS 的运行时入口。

~~~text
Volume
  allocator
  root path
  mounted packs
  mount table
  overlay resolver
  path index
  entry resolver
  page cache
  handle registry
  writable pack
~~~

Volume 负责：

~~~text
1. 打开/关闭整个 VFS。
2. 加载 meta pack 或 volume manifest。
3. 挂载 readonly pack、patch pack、mod pack、writable out pack。
4. 维护 PathIndex 与 EntryResolver。
5. 提供 open/stat/list/read/write/delete API。
6. 控制 overlay 优先级。
7. 处理 pack verify、checkpoint、recover、optimize。
~~~

### 2.2 Pack

Pack 是一个可挂载资源包。每个 pack 底层对应一个 DB store。

~~~text
pack_xxx/
  index.db
  data_000.db
  data_001.db
  ...
~~~

Pack 内保存：

~~~text
PackManifest
PathIndex chunk / DirectoryManifest chunk
FileManifest
PageValue
Tombstone records
Build cache records
~~~

Pack 有两种主要模式：

~~~text
readonly:
  base、dlc、patch、mod。
  默认只读，不允许运行时写入。

writable:
  editor import 输出、runtime cache、out pack、热更新 staging。
  支持 put/delete/commit/checkpoint。
~~~

### 2.3 FileEntry

FileEntry 是 VFS 的逻辑文件身份。

~~~text
FileEntry = u64
~~~

它不是文件路径，也不是 DB record offset。路径只是查找 FileEntry 的一种方式。

~~~text
path -> PathIndex -> FileEntry
FileEntry -> EntryResolver -> visible FileLocation
FileLocation -> pack + FileManifest
~~~

这样可以支持：

~~~text
1. 直接通过资源系统的 asset id 打开文件。
2. 路径重命名但 FileEntry 不变。
3. 多个路径别名指向同一个 FileEntry。
4. overlay 只更新 FileEntry 对应内容，不一定改变 path index。
~~~

### 2.4 FileLocation

FileLocation 描述某个 FileEntry 在某个 pack 中的具体版本。

~~~c
struct VfsFileLocation {
    uint32_t pack_id;
    uint32_t mount_index;
    uint64_t file_entry;
    uint64_t file_version;
    uint64_t manifest_key;
    uint32_t flags;
};
~~~

flags 可以包含：

~~~text
normal
deleted
tombstone
redirect
sparse_overlay
external_ref
~~~

### 2.5 PathIndex

PathIndex 是路径到 FileEntry 的索引。由于 DB key 是 u64，不能依赖 DB 做 path prefix/range scan。因此 PathIndex 必须是一个或多个普通 DB value。

推荐格式：

~~~text
PathIndexHeader
PathBucket[]
PathRecord[]
StringTable
~~~

PathRecord：

~~~c
struct PathRecord {
    uint64_t path_hash;
    uint64_t file_entry;
    uint32_t normalized_path_offset;
    uint32_t normalized_path_size;
    uint32_t flags;
    uint32_t reserved;
};
~~~

查找路径时：

~~~text
1. normalize path。
2. hash64(normalized_path)。
3. 在 PathIndex bucket 中查 path_hash。
4. 对同 hash 候选项比较 normalized path bytes。
5. 得到 FileEntry。
6. 调用 open_entry 流程。
~~~

PathIndex 必须保留 normalized path bytes，用来解决 path_hash 碰撞。VFS public 层只支持 u64 FileEntry，不代表路径查找可以不做字符串校验。

### 2.6 EntryResolver

EntryResolver 负责从 FileEntry 找到当前可见的 FileLocation。

~~~text
Input:
  FileEntry

Output:
  visible FileLocation or NotFound
~~~

解析顺序由 MountTable 控制：

~~~text
1. writable out pack
2. hotfix / patch pack
3. mod pack
4. dlc pack
5. base pack
~~~

如果高优先级 pack 对该 FileEntry 写了 tombstone，则低优先级版本被隐藏。

EntryResolver 可以在 volume open 时由所有 pack manifest 构建成内存表：

~~~text
file_entry -> sorted FileLocation list
~~~

如果文件数量很大，V1 可先全量加载；V2 再做分片加载或 mmap-friendly entry table。

---

## 3. Pack 内部格式

### 3.1 PackManifest

PackManifest 是 pack 的控制面入口。

~~~c
struct PackManifestHeader {
    uint32_t magic;          // 'VPKM'
    uint16_t version;
    uint16_t header_size;

    uint32_t pack_id;
    uint32_t flags;

    uint64_t pack_version;
    uint64_t build_id;

    uint64_t file_count;
    uint64_t tombstone_count;

    uint64_t path_index_key;
    uint64_t directory_manifest_key;

    uint64_t content_hash;
    uint32_t manifest_crc;
};
~~~

PackManifest 需要回答：

~~~text
1. 这个 pack 是谁。
2. 它包含哪些 FileEntry。
3. 哪些 FileEntry 被 tombstone。
4. PathIndex / DirectoryManifest 在哪里。
5. pack 的构建版本、schema、feature flags。
~~~

### 3.2 FileManifest

FileManifest 描述一个逻辑文件如何由 block/page 组成。

~~~c
struct FileManifestHeader {
    uint32_t magic;          // 'VFMF'
    uint16_t version;
    uint16_t header_size;

    uint64_t file_entry;
    uint64_t file_version;
    uint64_t file_size;

    uint64_t content_hash;

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

    uint64_t block_hash;
    uint32_t flags;
    uint32_t page_ref_offset;
};
~~~

V1 默认使用 implicit page key：

~~~text
PageKey = hash64("vfs.page.v1", file_entry, block_index, page_index)
~~~

V2 可以支持 explicit page ref：

~~~c
struct PageRef {
    uint32_t pack_id;
    uint32_t block_index;
    uint32_t page_index;
    uint64_t file_entry;
    uint64_t page_key;
    uint64_t content_hash;
};
~~~

implicit page key 简单、manifest 小。explicit page ref 支持跨 pack page 复用、page-level patch、copy-on-write sparse overlay。

### 3.3 PageValue

PageValue 是 DB 中实际保存文件数据的 value。

~~~text
[PageValueHeader][payload bytes]
~~~

~~~c
struct PageValueHeader {
    uint32_t magic;          // 'VPGV'
    uint16_t version;
    uint16_t header_size;

    uint64_t file_entry;

    uint32_t block_index;
    uint32_t page_index;

    uint16_t codec;
    uint16_t codec_flags;

    uint32_t raw_size;
    uint32_t stored_size;

    uint32_t raw_crc;
    uint32_t stored_crc;

    uint64_t content_hash;

    uint32_t page_flags;
    uint32_t header_crc;
};
~~~

读取 PageValue 时必须校验：

~~~text
1. DB key 派生身份与 header 中 file_entry/block/page 匹配。
2. header_crc 正确。
3. stored_size 与实际 payload size 匹配。
4. stored_crc 正确。
5. 解压后 raw_size 正确。
6. raw_crc 正确。
~~~

这样即使 u64 DB key 出现碰撞或调用方传错 FileEntry，也不会静默返回错误 page。

### 3.4 Tombstone

Tombstone 用于 overlay 删除。

建议区分两类：

~~~text
EntryTombstone:
  隐藏某个 FileEntry 的低优先级版本。
  open_entry(file_entry) 返回 NotFound。

PathTombstone:
  隐藏某个 path。
  open_path(path) 返回 NotFound。
  但如果同一个 FileEntry 还有其他路径别名，open_entry 是否可见取决于 EntryTombstone。
~~~

V1 可以先实现 EntryTombstone。PathTombstone 可在 PathIndex 中表示。

---

## 4. 关键流程

### 4.1 vfs_open_path

~~~text
vfs_open_path(volume, path):
  1. 校验 volume handle。
  2. normalize path。
  3. 在 PathIndex 中查找 normalized path。
  4. 若 path 不存在，返回 VFS_NOT_FOUND。
  5. 若 path 命中 PathTombstone，返回 VFS_NOT_FOUND。
  6. 得到 FileEntry。
  7. 进入 vfs_open_entry_common(volume, file_entry)。
~~~

Path normalize 规则必须稳定：

~~~text
1. 使用 / 作为分隔符。
2. 合并重复分隔符。
3. 去掉 .。
4. 禁止越过根目录的 ...
5. 是否大小写敏感由 volume option 固定。
6. 不允许不同平台产生不同 normalized path。
~~~

### 4.2 vfs_open_entry

~~~text
vfs_open_entry(volume, file_entry):
  1. file_entry == 0 则返回 VFS_INVALID_ARGUMENT。
  2. EntryResolver 按 mount 优先级查找 visible FileLocation。
  3. 若最高优先级记录是 EntryTombstone，返回 VFS_NOT_FOUND。
  4. 根据 FileLocation 打开对应 pack。
  5. 使用 FileManifestKey 读取 FileManifest。
  6. 校验 FileManifest.header.file_entry == file_entry。
  7. 校验 manifest_crc / schema / feature flags。
  8. 创建 VfsFile handle。
  9. 记录 manifest snapshot、pack generation、file size、flags。
  10. 返回 handle。
~~~

这条路径不访问 PathIndex，因此适合资源系统已经持有 FileEntry 的热路径。

### 4.3 vfs_read_at

~~~text
vfs_read_at(file, offset, size, dst):
  1. 校验 file handle。
  2. 如果 offset >= file_size，返回 0 bytes。
  3. clamp read range 到 file_size。
  4. 根据 FileManifest 找到涉及的 block/page。
  5. 对每个 page：
     a. 查询 page cache。
     b. miss 时构造 PageKey。
     c. 从对应 pack DB 读取 PageValue。
     d. 校验 PageValueHeader。
     e. 解压 payload。
     f. 校验 raw_crc。
     g. 放入 page cache。
  6. 从 raw page 拷贝用户请求范围。
  7. 返回实际读取字节数。
~~~

Page cache key：

~~~text
pack_id + pack_generation + file_entry + block_index + page_index
~~~

不能只用 PageKey，因为 pack 更新后相同 PageKey 可能指向新内容。

### 4.4 vfs_stat

~~~text
vfs_stat(path or entry):
  1. path 输入先走 PathIndex。
  2. entry 输入直接走 EntryResolver。
  3. 读取或命中 FileManifest cache。
  4. 返回 file_size、flags、version、content_hash、pack_id。
~~~

### 4.5 list_dir

目录列表不从 DB key scan 得到，而从 DirectoryManifest / PathIndex 得到。

~~~text
vfs_list_dir(path):
  1. normalize directory path。
  2. 查 DirectoryManifest。
  3. 合并 mounted packs 的目录记录。
  4. 应用 overlay priority 与 tombstone。
  5. 返回子目录和文件名。
~~~

V1 可以在 volume open 时构建内存目录树。V2 再做分片 DirectoryManifest。

### 4.6 写入文件

V1 写入采用 whole-file rewrite 到 writable pack。

~~~text
vfs_write_file(path or entry, data):
  1. 解析 FileEntry。
  2. 选择 writable pack。
  3. split file -> block -> page。
  4. 对每个 page 计算 PageKey。
  5. 压缩并构造 PageValue。
  6. batch put 所有 PageValue。
  7. 构造 FileManifest。
  8. batch put FileManifest。
  9. 更新 PackManifest / PathIndex / DirectoryManifest。
  10. batch commit。
  11. 刷新 EntryResolver / PathIndex 增量视图。
~~~

V2 再实现 page-level copy-on-write：

~~~text
只写 changed pages；
未变化 page 用 explicit PageRef 指向旧 pack；
新 FileManifest 描述完整文件视图。
~~~

### 4.7 删除文件

~~~text
vfs_delete(path):
  1. path -> FileEntry。
  2. 写 PathTombstone 或 EntryTombstone 到 writable pack。
  3. 更新 PackManifest / PathIndex / DirectoryManifest。
  4. commit。
~~~

如果删除语义是“这个路径不可见”，使用 PathTombstone。如果删除语义是“这个逻辑文件不可见”，使用 EntryTombstone。

### 4.8 pack mount

~~~text
vfs_mount_pack(volume, pack_path, options):
  1. 打开 pack DB。
  2. 读取 PackManifest。
  3. 校验 pack_id、schema、feature flags。
  4. 读取 PathIndex / DirectoryManifest 摘要。
  5. 插入 MountTable。
  6. 重建或增量更新 EntryResolver。
  7. 重建或增量更新 PathIndex overlay view。
~~~

mount priority 必须显式：

~~~text
higher priority shadows lower priority
~~~

同 priority 的 pack 顺序必须稳定，否则不同机器可能解析出不同文件。

### 4.9 checkpoint / optimize

VFS 不实现 DB 内部 checkpoint。它只决定何时调用。

~~~text
vfs_commit:
  对 writable pack 执行 db_commit。

vfs_checkpoint:
  对指定 pack 或所有 writable pack 执行 db_checkpoint。

vfs_optimize:
  对指定 pack 或所有 writable pack 执行 db_optimize。
~~~

Volume 级操作必须按 pack 状态控制，不要在 pack 正在写入时强行 optimize。

---

## 5. Overlay 语义

### 5.1 MountTable

~~~c
struct MountEntry {
    uint32_t pack_id;
    uint32_t priority;
    uint64_t pack_version;
    uint32_t flags;
};
~~~

解析规则：

~~~text
1. priority 高的 pack 优先。
2. priority 相同则 mount_order 后挂载的优先，或由 options 固定为错误。
3. tombstone 覆盖低优先级 normal file。
4. redirect 先解析 redirect，再按目标 FileEntry 查找。
5. writable pack 默认最高优先级。
~~~

### 5.2 Path overlay 与 Entry overlay

Path overlay：

~~~text
path -> FileEntry
~~~

Entry overlay：

~~~text
FileEntry -> FileLocation
~~~

两者必须分开。原因：

~~~text
1. 直接 open_entry 不应该依赖 path。
2. rename 可以只改变 PathIndex，不改变 FileEntry。
3. 同一 FileEntry 可以有多个 path alias。
4. 删除 path 与删除 entry 是不同语义。
~~~

---

## 6. 压缩与 block/page 模型

### 6.1 层级

~~~text
Logical File
  FileManifest
    Block 0
      Page 0
      Page 1
    Block 1
      Page 0
~~~

block 是压缩策略单位，page 是 DB 存储单位。

### 6.2 为什么不直接整个文件一个 value

~~~text
1. 随机读取需要解压整个文件。
2. 小修改需要重写整个文件。
3. patch 粒度太粗。
4. 大文件 value 放大 DB 写入、恢复和校验成本。
5. 无法对不同区间使用不同压缩策略。
~~~

### 6.3 V1 推荐参数

~~~text
default page size:
  64 KiB

small file:
  小于 page size 时单 page。

large streaming file:
  64 KiB 或 256 KiB page，按平台 IO/解压性能调节。

metadata/json:
  16 KiB 或 32 KiB page。
~~~

---

## 7. 错误模型

建议 VFS 自己定义错误码，不直接泄漏 DB 错误码。

~~~text
VFS_OK
VFS_NOT_FOUND
VFS_INVALID_ARGUMENT
VFS_IO_ERROR
VFS_CORRUPTION
VFS_CHECKSUM_MISMATCH
VFS_UNSUPPORTED_VERSION
VFS_UNSUPPORTED_FEATURE
VFS_PERMISSION_DENIED
VFS_KEY_COLLISION
VFS_DB_ERROR
VFS_INTERNAL_ERROR
~~~

DB 错误映射：

~~~text
DB_NOT_FOUND -> VFS_NOT_FOUND
DB_CORRUPTION -> VFS_CORRUPTION
DB_CHECKSUM_MISMATCH -> VFS_CHECKSUM_MISMATCH
DB_UNSUPPORTED_VERSION -> VFS_UNSUPPORTED_VERSION
其他 DB 错误 -> VFS_DB_ERROR 或更具体错误
~~~

---

## 8. 模块划分建议

~~~text
src/vfs/
  root.zig
  abi.zig
  error.zig
  handle_registry.zig

  hash.zig
  object_key.zig

  format/
    pack_manifest.zig
    directory_manifest.zig
    path_index.zig
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

tools/
  vfs.zig

include/
  vfs.h
~~~

---

## 9. Public ABI 草案

~~~c
typedef uint64_t vfs_volume_t;
typedef uint64_t vfs_file_t;
typedef uint64_t vfs_file_entry_t;

typedef struct vfs_open_options {
    uint32_t struct_size;
    uint32_t flags;
    uint32_t case_sensitive;
    uint32_t reserved0;
    uint64_t page_cache_bytes;
} vfs_open_options_t;

typedef struct vfs_stat {
    uint32_t struct_size;
    uint32_t flags;
    uint64_t file_entry;
    uint64_t file_size;
    uint64_t file_version;
    uint64_t content_hash;
    uint32_t pack_id;
    uint32_t reserved0;
} vfs_stat_t;

int vfs_open_volume(
    const char* path,
    const vfs_open_options_t* options,
    vfs_volume_t* out_volume
);

int vfs_close_volume(vfs_volume_t volume);

int vfs_mount_pack(
    vfs_volume_t volume,
    const char* pack_path,
    uint32_t priority,
    uint32_t flags
);

int vfs_open_path(
    vfs_volume_t volume,
    const char* path,
    uint32_t flags,
    vfs_file_t* out_file
);

int vfs_open_entry(
    vfs_volume_t volume,
    uint64_t file_entry,
    uint32_t flags,
    vfs_file_t* out_file
);

int vfs_stat_path(
    vfs_volume_t volume,
    const char* path,
    vfs_stat_t* out_stat
);

int vfs_stat_entry(
    vfs_volume_t volume,
    uint64_t file_entry,
    vfs_stat_t* out_stat
);

int vfs_read_at(
    vfs_file_t file,
    uint64_t offset,
    void* dst,
    uint64_t size,
    uint64_t* out_read
);

int vfs_close_file(vfs_file_t file);
~~~

V1 不建议先暴露复杂异步 API。先把同步 read path 做正确，再在内部引入预取和任务调度。

---

## 10. 最小可用闭环

VFS 第一版最小闭环应该是：

~~~text
1. 创建 pack。
2. 写入 path -> FileEntry。
3. 写入 FileManifest。
4. 写入 PageValue。
5. 打开 volume。
6. mount pack。
7. vfs_open_path 读文件。
8. vfs_open_entry 读同一个文件。
9. vfs_read_at 随机读取。
10. verify pack 检查 manifest/page/path index 一致性。
~~~

一旦这个闭环稳定，再向 writable pack、overlay、patch、merge、task graph 扩展。

