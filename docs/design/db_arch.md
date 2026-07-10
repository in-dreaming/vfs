# 游戏引擎资产 KV 数据库架构设计

## 0. 目标与结论

本文定义一个面向游戏引擎 editor 与 runtime 的统一资产 KV 数据库。它不是通用数据库，而是一个可嵌入、可校验、可恢复、跨平台的资产存储格式。

设计目标：

- 存储 import/cook 后的引擎内部资产数据。
- 支持千万级 key、从小 metadata 到大 blob 的 value。
- editor 和 runtime 使用同一套文件格式。
- runtime 可按配置支持新增、删除、修改、patch、mod、cache、热更新、本地生成内容。
- 查询路径不全量构建内存 map，主要依赖 mmap-friendly 索引。
- 写入路径尽量使用底层可控接口，减少不可预测的系统调用、页缓存、隐式文件偏移、隐式 flush、隐式重分配带来的副作用。
- 跨平台支持 Windows、Linux、macOS、主机工具链以及后续 console/mobile 平台适配。
- 实现语言使用 Zig，对外暴露 C ABI。

最终推荐架构：

~~~text
asset_store/
  manifest.db
  index.db
  data_000.db
  data_001.db
  data_002.db
  ...
~~~

核心结构：

~~~text
Index DB:
  base bucket index
  + mutable delta hash index
  + delta journal
  + checkpoint merge

Data DB[N]:
  append-first record file
  + optional hole allocator
  + immutable record
  + epoch delayed reclaim
  + optional relocation/truncate
~~~

最重要的设计底线：

- data record 不原地覆盖。
- base index 不原地插入、删除、修改。
- 写入先完成 data record，再写 delta journal，最后发布 delta hash。
- journal 是恢复真相，mmap hash table 是查询加速。
- reader 可能持有旧 offset，旧 record 必须通过 epoch 延迟回收。
- data 文件不整体 mmap 读写，避免大 value、truncate、relocation 与 OS page cache 互相放大副作用。
- index 可 mmap，但 mutable mmap 必须受 journal、seqlock、显式 flush 和恢复协议约束。

---

## 1. 非目标

本项目不追求成为通用关系数据库、通用 LSM 数据库或完整事务数据库。

非目标：

- 不提供 SQL。
- 不提供任意范围查询作为核心能力。
- 不提供多表 join。
- 不在第一版提供完整 ACID 多事务隔离。
- 不保证每次写入后立即缩容。
- 不把所有 key -> info 加载为进程内 hash map。
- 不依赖平台默认缓存策略来保证性能或持久化。

本系统优先优化：

- key -> asset blob 的 point lookup。
- 大量只读资产加载。
- editor 批量导入。
- runtime 少量增删改。
- 可验证、可恢复、可离线修复的文件格式。

---

## 2. 数据模型

### 2.1 Key

内部统一使用 128-bit key。

~~~zig
pub const Key128 = extern struct {
    hi: u64,
    lo: u64,
};
~~~

推荐来源：

- hash128(namespace + virtual_path + import_settings + source_guid)
- 或 {namespace/type/group, hash64}

即使外部只提供 64-bit hash，内部也应扩展到 128-bit，避免长期资产库、mod、patch、生成内容混在一起时碰撞处理困难。

### 2.2 Value

value 是引擎格式 blob，可以是：

- asset metadata
- texture chunk
- mesh buffer
- animation data
- shader cache
- audio chunk
- asset registry
- directory tree
- import database

目录结构不进入主索引结构，而作为特殊 key 存在 data db 中，例如：

~~~text
KEY_DIRECTORY_TREE
KEY_ASSET_REGISTRY
KEY_SCHEMA_TABLE
KEY_IMPORT_DATABASE
~~~

runtime 启动时可以读取这些特殊 blob，反序列化为内存结构。

---

## 3. 文件组成

### 3.1 manifest.db

manifest.db 是 store 级元信息入口。它很小，可以独立双 superblock，也可以在 V1 先简化为固定头。

职责：

- store magic/version/uuid
- index.db 路径与版本
- data db 文件列表
- feature flags
- schema version
- 默认 config
- 平台兼容信息

manifest 不进入高频 lookup 路径。

### 3.2 index.db

index.db 保存 key -> IndexInfo。

IndexInfo 指向 data db 内的 record：

~~~zig
pub const IndexInfo = extern struct {
    data_db_id: u32,
    flags: u32,
    offset: u64,
    stored_size: u32,
    raw_size: u32,
    version: u64,
    crc: u32,
    codec: u16,
    reserved: u16,
};
~~~

index.db 内包含：

- FileHeader
- SuperBlock A/B
- RegionDirectory
- BaseIndex region
- DeltaGeneration region
- checkpoint/free/old regions

### 3.3 data_NNN.db

data db 保存 immutable record。

多个 data db 的目的：

- 降低单文件过大带来的平台风险。
- 支持按资产类型、冷热、大小分组。
- 支持并发写入分散到多个文件。
- relocation/optimize 可以按文件执行。
- 后续可对不同 data db 使用不同压缩、预取、cache 策略。

---

## 4. Index DB 设计

### 4.1 总体布局

~~~text
index.db

+-------------------------------+
| IndexFileHeader               |
+-------------------------------+
| IndexSuperBlock A             |
+-------------------------------+
| IndexSuperBlock B             |
+-------------------------------+
| RegionDirectory               |
+-------------------------------+
| BaseIndex Region              |
|   BaseIndexHeader             |
|   BucketTable                 |
|   EntryArray                  |
+-------------------------------+
| DeltaGeneration 0 Region      |
|   DeltaHeader                 |
|   DeltaHashTable              |
|   DeltaJournal                |
+-------------------------------+
| DeltaGeneration 1 Region      |
|   DeltaHeader                 |
|   DeltaHashTable              |
|   DeltaJournal                |
+-------------------------------+
| Free / Old / Checkpoint Area  |
+-------------------------------+
~~~

lookup 顺序：

~~~text
active_delta
checkpointing_delta
base
~~~

put/delete 只写 active_delta，不直接改 base。

checkpoint 时：

~~~text
old base + frozen delta -> new base
atomic superblock switch
old base / old delta delayed reclaim
~~~

### 4.2 FileHeader

所有多字节字段统一 little-endian。所有 offset 都是文件内 offset，不存进程指针。

~~~zig
pub const IndexFileHeader = extern struct {
    magic: u32,
    major_version: u16,
    minor_version: u16,
    endian: u32,
    pointer_size: u32,
    file_header_size: u64,
    superblock_a_offset: u64,
    superblock_b_offset: u64,
    region_directory_offset: u64,
    page_size: u64,
    alignment: u64,
    uuid: [16]u8,
    header_crc: u32,
};
~~~

### 4.3 SuperBlock A/B

双 superblock 用于抵抗写元数据时崩溃。

~~~zig
pub const IndexSuperBlock = extern struct {
    magic: u32,
    version: u32,
    epoch: u64,
    file_size: u64,
    active_base_region_id: u64,
    active_delta_region_id: u64,
    checkpoint_delta_region_id: u64,
    region_directory_epoch: u64,
    last_committed_journal_epoch: u64,
    clean_shutdown: u32,
    flags: u32,
    create_time: u64,
    update_time: u64,
    reserved: [128]u8,
    crc: u32,
};
~~~

启动选择规则：

- magic 正确。
- crc 正确。
- epoch 最大。

写入规则：

- 新 region 写完并 flush。
- 写另一个 superblock。
- flush superblock 所在范围。
- epoch 单调递增。

### 4.4 RegionDirectory

RegionDirectory 管理 index.db 内部区域。

~~~zig
pub const RegionType = enum(u32) {
    free = 0,
    base_index = 1,
    delta = 2,
    old_base = 3,
    reserved = 4,
};

pub const RegionState = enum(u32) {
    free = 0,
    building = 1,
    active = 2,
    checkpointing = 3,
    retired = 4,
    pending_reclaim = 5,
};

pub const RegionDesc = extern struct {
    region_id: u64,
    region_type: u32,
    state: u32,
    offset: u64,
    size: u64,
    epoch_created: u64,
    epoch_retired: u64,
    crc: u32,
    flags: u32,
};
~~~

V1 可以使用固定容量 RegionDirectory，暂不做复杂 region 合并；V2 再做 index.db 内部空间复用。

### 4.5 Base Index

Base index 是大规模稳定索引，适合 mmap 查询，不支持原地插入删除。

布局：

~~~text
BaseIndexHeader
BucketTable[2^bucket_bits]
EntryArray[entry_count]
~~~

BaseEntry 固定大小，建议 64B 对齐：

~~~zig
pub const BaseEntry = extern struct {
    h: u64,
    key_hi: u64,
    key_lo: u64,
    data_db_id: u32,
    flags: u32,
    offset: u64,
    stored_size: u32,
    raw_size: u32,
    version: u64,
    crc: u32,
    codec: u16,
    reserved: u16,
};
~~~

Bucket：

~~~zig
pub const BaseBucket = extern struct {
    begin: u64,
    count: u32,
    flags: u32,
};
~~~

查询流程：

~~~text
h = mix_hash128_to_u64(key)
bucket_id = high_bits(h, bucket_bits)
bucket = buckets[bucket_id]
entries = entry_array[bucket.begin .. bucket.begin + bucket.count]
bucket 内按 (h, key_hi, key_lo) 查找
full key 校验
~~~

bucket 内查找策略：

- count <= 16：线性扫描。
- count > 16：按 h 二分，再 full key 校验。

千万级 key 推荐 bucket_bits 为 20 或 21。

### 4.6 Delta Index

Delta index 承担所有可变更：

- put
- delete tombstone
- relocation 的逻辑 CAS 发布
- patch/mod/cache 的覆盖

Delta 使用 open addressing hash table。hash table 可 mmap，但不是恢复真相。

~~~zig
pub const DeltaSlotState = enum(u8) {
    empty = 0,
    occupied = 1,
    tombstone = 2,
};

pub const DeltaSlot = extern struct {
    seq: u64,
    h: u64,
    key_hi: u64,
    key_lo: u64,
    data_db_id: u32,
    flags: u32,
    offset: u64,
    stored_size: u32,
    raw_size: u32,
    version: u64,
    crc: u32,
    codec: u16,
    state: u8,
    reserved0: u8,
    slot_crc: u32,
    reserved1: u32,
};
~~~

并发读写：

- writer 使用 key striped lock + delta stripe lock。
- slot 更新使用 seqlock 思路。
- reader 读 seq，复制字段，再读 seq；若 seq 变化或为奇数则重试。

严格 C/C++ 内存模型下，非原子字段并发读写会有 data race。Zig 实现中也应避免依赖未定义行为。推荐 V1 做法：

- V1 先使用 striped RWLock 保护 delta probe 范围，保证正确性。
- V2 再把热路径替换为原子字段或平台约束明确的 seqlock slot。

### 4.7 Delta Journal

Delta journal 是恢复真相。

Journal record：

~~~zig
pub const DeltaJournalOp = enum(u16) {
    put = 1,
    delete = 2,
    batch_begin = 3,
    batch_commit = 4,
    batch_abort = 5,
};

pub const DeltaJournalRecordHeader = extern struct {
    magic: u32,
    version: u16,
    op: u16,
    journal_epoch: u64,
    batch_id: u64,
    record_size: u32,
    header_crc: u32,
};

pub const DeltaJournalPayload = extern struct {
    h: u64,
    key_hi: u64,
    key_lo: u64,
    info: IndexInfo,
};

pub const DeltaJournalRecordFooter = extern struct {
    magic_commit: u32,
    record_crc: u32,
};
~~~

写入顺序：

~~~text
1. data record 写完整。
2. append delta journal record header/payload/footer。
3. durability 要求为 sync 时 flush journal。
4. 更新 delta hash slot。
~~~

崩溃语义：

- data 完整但 journal 未完整：orphan record，恢复时释放或隔离。
- journal 完整但 hash table 未更新：replay journal 恢复。
- hash table 已更新但 clean flag 为 false：replay journal 重建 hash table。

### 4.8 Checkpoint

checkpoint 合并 base 与 frozen delta。

流程：

~~~text
1. freeze active_delta -> checkpointing_delta。
2. 创建新的 active_delta 接收写入。
3. 后台 merge old_base + checkpointing_delta。
4. 写 new_base region，state = building。
5. 校验 new_base crc。
6. flush new_base。
7. 写 superblock，active_base_region_id 指向 new_base。
8. old_base / checkpointing_delta 标记 retired。
9. 等 reader epoch 安全后回收。
~~~

checkpoint 期间 lookup：

~~~text
active_delta
checkpointing_delta
old_base 或 new_base，由当前 snapshot 决定
~~~

---

## 5. Data DB 设计

### 5.1 总体布局

~~~text
data_000.db

+-------------------------------+
| DataFileHeader                |
+-------------------------------+
| DataSuperBlock A              |
+-------------------------------+
| DataSuperBlock B              |
+-------------------------------+
| AllocatorCheckpoint Region    |
+-------------------------------+
| Record Area                   |
|   [Record][Record][Hole]      |
|   [Record][Free Tail]         |
+-------------------------------+
~~~

V1 可以只实现 append-only，不使用 hole。文件只增长，不缩容。

V2 实现 append-first + hole reuse。

### 5.2 DataFileHeader

~~~zig
pub const DataFileHeader = extern struct {
    magic: u32,
    major_version: u16,
    minor_version: u16,
    endian: u32,
    flags: u32,
    header_size: u64,
    superblock_a_offset: u64,
    superblock_b_offset: u64,
    record_area_offset: u64,
    alignment: u64,
    uuid: [16]u8,
    crc: u32,
};
~~~

### 5.3 DataSuperBlock

~~~zig
pub const DataSuperBlock = extern struct {
    magic: u32,
    version: u32,
    epoch: u64,
    file_size: u64,
    logical_tail: u64,
    durable_tail: u64,
    allocator_checkpoint_offset: u64,
    allocator_checkpoint_size: u64,
    allocator_checkpoint_epoch: u64,
    free_bytes: u64,
    pending_free_bytes: u64,
    tail_free_bytes: u64,
    clean_shutdown: u32,
    flags: u32,
    crc: u32,
};
~~~

### 5.4 Record 格式

record 自描述，便于扫描、恢复、verify。

~~~zig
pub const RecordHeader = extern struct {
    magic: u32,
    header_version: u16,
    flags: u16,
    key_hi: u64,
    key_lo: u64,
    version: u64,
    header_size: u32,
    stored_size: u32,
    raw_size: u32,
    header_crc: u32,
    payload_crc: u32,
    txn_id: u64,
};

pub const RecordFooter = extern struct {
    magic_commit: u32,
    record_crc: u32,
};
~~~

record 有效条件：

- header magic 正确。
- header_size、stored_size、raw_size 合法。
- key 与 index lookup 的 key 一致。
- header_crc 正确。
- payload_crc 正确。
- footer magic_commit 正确。
- record_crc 正确。

### 5.5 Data 写入原则

data record 不原地覆盖。

put 时：

~~~text
allocate offset
write header without visible index
write payload
write footer commit marker
append delta journal
publish delta index
retire old record
~~~

index 决定 record 可见性。data 文件中存在完整 record 不等于 record 对用户可见。

### 5.6 Allocator

V1 allocator：

- 全局或 per data db logical_tail。
- append 分配。
- 可选预分配文件空间。
- 不复用 hole。

V2 allocator：

- size-class free-list。
- retired list。
- free-pending epoch。
- allocator checkpoint。
- tail free tracking。

block 状态：

~~~text
LIVE      index 当前指向
RETIRED   index 不再指向，但 reader 可能仍持有
FREE      可以复用
TAIL_FREE 文件尾部连续 free，可 truncate
~~~

free-list class：

~~~text
<= 256B
<= 512B
<= 1KB
<= 2KB
...
large block
~~~

retire 不直接 free：

~~~text
retired(offset, size, retire_epoch)
oldest_reader_epoch > retire_epoch
then insert into free-list
~~~

### 5.7 Relocation

relocation 用于降低碎片、形成 tail free、最终 truncate。

协议：

~~~text
1. 选择 live record old_info。
2. 读取并校验 old record。
3. 分配 new offset，优先使用前部 hole。
4. 写 new record。
5. index_compare_exchange(key, old_info, new_info)。
6. 成功：old block retire。
7. 失败：new block retire。
~~~

因为 base 不原地修改，index CAS 是逻辑 CAS：

~~~text
lock key
lookup current
if current == expected:
  append delta journal PUT desired
  publish delta hash
else:
  fail
unlock
~~~

### 5.8 Truncate

truncate 只允许处理文件尾部连续 free range。

禁止直接缩掉中间 hole。

条件：

- 尾部 range 无 live record。
- 尾部 range 无 pending reader。
- 尾部 range 无 pending writer。
- allocator checkpoint 已提交。
- data superblock 已安全切换。
- resize lock 持有。

runtime 默认不频繁 truncate，只在退出、关卡切换或显式维护时执行。

---

## 6. 一致性与恢复

### 6.1 持久化等级

~~~zig
pub const Durability = enum(c_int) {
    none = 0,
    async = 1,
    sync = 2,
};
~~~

None：

- 最快。
- 崩溃可能丢最近修改。
- 适合临时 cache。

Async：

- 默认。
- 后台 group flush。
- 崩溃可能丢最近若干毫秒修改。
- 恢复后结构一致。

Sync：

- put/delete 返回前 data、必要文件长度 metadata、journal、journal tail/header、可见性元数据达到平台持久化要求。
- 适合重要 manifest、patch、registry、存档。

### 6.2 写入顺序

Sync 模式：

~~~text
data pwrite
if data write extended file: make file length durable
data superblock logical_tail write
data/data-superblock flush
journal append
journal tail/header flush
delta hash publish
~~~

Async 模式：

~~~text
data pwrite
data superblock logical_tail write
journal append
delta hash publish
background group flush
~~~

注意：严格 WAL 原则通常要求 journal 先于 main data 修改；本设计的 data record 是 immutable 且 index 未发布前不可见，因此 data 可以先写。真正决定可见性的 index 修改必须由 journal 恢复。

如果 journal record 已经 durable，它引用的 data record 以及必要的文件长度 metadata 必须已经 durable。否则崩溃恢复可能 replay 出 dangling index offset。

### 6.3 崩溃恢复

启动恢复流程：

~~~text
1. 读取 manifest。
2. 读取 index superblock A/B，选择有效 epoch。
3. mmap base index。
4. 检查 active/checkpoint delta clean flag。
5. dirty delta: 清空 hash table，扫描 journal replay。
6. 读取每个 data db superblock A/B。
7. clean data db: 加载 allocator checkpoint。
8. dirty data db: 根据 index live set + record scan 修复。
9. orphan record 加入 quarantine 或 free-pending。
10. verify index 指向 record 的 key/crc/version。
~~~

V1 可保守处理：

- dirty recovery 中不能确定的空间进入 quarantine。
- quarantine 不立即复用。
- full verify 后再释放。

---

## 7. 并发模型

锁与同步原语：

- key striped lock：保护同一 key 的 put/delete/relocate。
- delta stripe lock：保护 delta hash probe/insert/update。
- allocator lock：保护 free-list/logical_tail。
- resize lock：保护 truncate 与 append/allocate 竞争。
- checkpoint state lock：保护 active delta freeze/switch。
- reader epoch：保护 old offset、old base、old delta region 延迟回收。

普通 get：

~~~text
enter read epoch
lookup index
pread data record
exit read epoch
~~~

普通 put：

~~~text
key lock
allocator allocate
data write
journal append
delta publish
retire old
unlock
~~~

普通 get 不拿 key lock，避免读被写阻塞。

---

## 8. 底层 IO 与 cache 副作用控制

这是实现重点。目标不是完全绕过 OS cache，而是让行为可配置、可观测、可恢复，避免隐式副作用影响高层语义。

### 8.1 文件 IO 原则

- 不使用会修改共享文件偏移的 read/write 作为并发路径。
- 使用 offset-based IO：POSIX pread/pwrite，Windows OVERLAPPED ReadFile/WriteFile。
- 所有文件 offset 显式传入。
- 大块写入使用对齐 buffer。
- flush 明确由 durability 和 group flush 控制。
- 不依赖 close 隐式 flush 作为一致性保证。
- 避免在高频路径频繁 extend/truncate 文件。

### 8.2 mmap 使用边界

适合 mmap：

- base bucket table。
- base entry array。
- delta hash table。

不适合整体 mmap：

- data value blob。
- 高频 append data file。
- 需要 relocation/truncate 的 data file。

原因：

- 大 value 会污染 OS page cache。
- mmap 写入顺序与持久化顺序不直观。
- truncate 与仍被映射/读取的页面交互复杂。
- 随机访问大 data mmap 容易造成不可控 page fault。

### 8.3 平台 hint

POSIX/Linux 可选：

- posix_fadvise sequential/random/dontneed。
- madvise random/sequential/willneed/dontneed。
- fallocate 预分配。
- fdatasync/fsync 显式同步。
- pwritev/readv 合并小 IO。

Windows 可选：

- FILE_FLAG_OVERLAPPED。
- FILE_FLAG_RANDOM_ACCESS / FILE_FLAG_SEQUENTIAL_SCAN。
- SetFileInformationByHandle 预分配/截断。
- FlushFileBuffers。
- ReadFileScatter/WriteFileGather 或普通 OVERLAPPED IO。

Direct IO / unbuffered IO：

- 作为高级配置，不作为默认。
- 需要严格对齐 offset、size、buffer。
- 对小 record 和 metadata 不友好。
- 可用于大 blob streaming data db。

### 8.4 Cache 策略

内部 cache 应显式分层：

- index 依赖 mmap + OS page cache。
- data 小 value 可选 block cache。
- 大 value 默认 streaming，读后可 fadvise/madvise dontneed。
- 解压后 asset cache 属于引擎资源系统，不属于 DB 基础层。

避免：

- DB 层偷偷缓存所有 value。
- data 全量 mmap 导致 OS cache 被大贴图/音频扫掉。
- 每次 put 触发强制 fsync。
- 每次 delete 触发 relocation/truncate。

### 8.5 Syscall 降低策略

- batch put 合并 journal record。
- pwritev/writev 合并 header/payload/footer。
- group flush 合并 fdatasync/FlushFileBuffers。
- allocator 批量预留 tail range。
- delta journal 顺序 append，减少随机写。
- checkpoint 后台批量生成新 base。

---

## 9. Zig 实现约束

### 9.1 语言选择

实现语言使用 Zig。

原因：

- 手动内存管理清晰。
- 跨平台系统调用封装能力强。
- extern struct 与 C ABI 适配直接。
- 错误处理适合系统库。
- 可控制 allocator、对齐、packed/extern layout。

### 9.2 文件格式结构体

磁盘结构体要求：

- 使用固定宽度整数。
- 使用 extern struct 或显式序列化。
- 禁止直接写入包含指针、slice、bool、enum 默认大小不明确的结构。
- enum 明确 backing integer。
- 所有保留字段写 0。
- 所有 offset 为 u64。
- 所有 size 为 u64 或明确限制的 u32。
- 明确 little-endian 编解码。

建议：

- 磁盘读写使用 encode/decode 函数，而不是盲目把 struct 内存 dump 到文件。
- 对 hot path entry/slot 可使用 extern struct + comptime assert size/alignment。

### 9.3 错误模型

内部 Zig 使用 error union。

C ABI 对外使用整数错误码：

~~~zig
pub const DbStatus = enum(c_int) {
    ok = 0,
    not_found = 1,
    invalid_argument = 2,
    io_error = 3,
    corruption = 4,
    checksum_mismatch = 5,
    unsupported_version = 6,
    busy = 7,
    no_space = 8,
    permission_denied = 9,
    internal_error = 100,
};
~~~

### 9.4 内存分配

- DB handle 持有 allocator。
- C ABI open 时可传自定义 allocator hooks，V1 可先使用默认 allocator。
- 所有返回给 C 的内存必须有明确 free API。
- get 大 value 禁止 callback。必须使用 caller-provided buffer、两阶段 `get_size/get_into`，或显式 reader handle 且由 caller 主动读取。

---

## 10. C ABI

C ABI 必须稳定、少暴露内部结构。

### 10.1 基本原则

- 使用 opaque handle。
- 所有 ABI struct 固定 size/version。
- 所有输入 slice 使用 pointer + length。
- 不跨 ABI 抛 Zig error。
- C ABI 默认使用 caller-provided buffer，不返回内部 mmap 指针。
- 若未来增加 owned-buffer API，必须配套 `db_*_free`；当前 V1 不提供 owned-buffer get。
- DB 是独立库，建议产物为 `libdb`。
- DB 库导出符号统一使用 `db_*` 前缀。
- 未来 VFS 是另一个独立库，建议产物为 `libvfs`，其导出符号使用 `vfs_*` 前缀。
- DB 库禁止导出 `vfs_*` 或 `vfs_db_*`。
- VFS 库禁止导出 `db_*`；如需包装 DB 能力，必须暴露为 `vfs_*`。
- DB 库不能依赖未来 VFS 库；VFS 库可以链接并调用 DB 库。
- DB 文件格式不得包含 VFS 路径、mount、overlay 等上层语义。

### 10.2 示例 API

~~~c
typedef struct db db_t;

typedef struct db_key128 {
    uint64_t hi;
    uint64_t lo;
} db_key128_t;

typedef struct db_open_options {
    uint32_t struct_size;
    uint32_t flags;
    uint32_t durability;
    uint32_t reserved0;
    uint64_t max_delta_entries;
    uint64_t data_file_target_size;
} db_open_options_t;

int db_open(const char* path, const db_open_options_t* options, db_t** out_db);
int db_close(db_t* db);

int db_get_size(db_t* db, db_key128_t key, uint64_t* out_size);
int db_get_into(db_t* db, db_key128_t key, void* dst, uint64_t dst_size, uint64_t* out_written);

int db_put(db_t* db, db_key128_t key, const void* data, uint64_t size, uint32_t flags);
int db_delete(db_t* db, db_key128_t key);

int db_checkpoint(db_t* db, uint32_t flags);
int db_verify(db_t* db, uint32_t flags);
int db_optimize(db_t* db, uint32_t flags);
~~~

大 value 不使用 callback streaming。若 `get_into` 不适合，后续只能增加显式 reader handle API，例如 `db_reader_open/db_reader_read/db_reader_close`，由 caller 主动拉取数据。

Batch API：

~~~c
typedef struct db_batch db_batch_t;

int db_batch_begin(db_t* db, db_batch_t** out_batch);
int db_batch_put(db_batch_t* batch, db_key128_t key, const void* data, uint64_t size, uint32_t flags);
int db_batch_delete(db_batch_t* batch, db_key128_t key);
int db_batch_commit(db_batch_t* batch, uint32_t durability);
int db_batch_rollback(db_batch_t* batch);
~~~

---

## 11. Cross-platform Platform Layer

需要单独抽象 platform 层，不让核心 DB 直接散落平台条件编译。

建议模块：

~~~text
platform/
  file.zig
  mmap.zig
  flush.zig
  lock.zig
  time.zig
  crc.zig
~~~

File API：

~~~zig
pub const FileHandle = opaque {};

pub const OpenFlags = packed struct {
    read: bool,
    write: bool,
    create: bool,
    truncate: bool,
    random_access_hint: bool,
    sequential_hint: bool,
    overlapped_or_pwrite: bool,
    direct_io: bool,
};

pub fn pread(handle: FileHandle, offset: u64, dst: []u8) !usize;
pub fn pwrite(handle: FileHandle, offset: u64, src: []const u8) !usize;
pub fn pwritev(handle: FileHandle, offset: u64, vecs: []const IoVec) !usize;
pub fn flush_data(handle: FileHandle) !void;
pub fn flush_metadata(handle: FileHandle) !void;
pub fn set_len(handle: FileHandle, len: u64) !void;
pub fn preallocate(handle: FileHandle, offset: u64, len: u64) !void;
pub fn advise(handle: FileHandle, offset: u64, len: u64, advice: Advice) void;
~~~

mmap API：

~~~zig
pub fn mmap_readonly(handle: FileHandle, offset: u64, len: u64) !MappedRegion;
pub fn mmap_readwrite(handle: FileHandle, offset: u64, len: u64) !MappedRegion;
pub fn msync(region: MappedRegion, mode: SyncMode) !void;
pub fn munmap(region: MappedRegion) void;
~~~

核心代码只调用 platform 层。平台层负责：

- Windows HANDLE / OVERLAPPED。
- POSIX fd / pread / pwrite。
- mmap / MapViewOfFile。
- flush 语义差异。
- path encoding 差异。

---

## 12. Editor 与 Runtime 策略

格式统一，策略不同。

~~~zig
pub const DbConfig = extern struct {
    allow_write: bool,
    allow_checkpoint: bool,
    allow_relocation: bool,
    allow_truncate: bool,
    durability: c_int,
    max_delta_entries: u64,
    max_delta_bytes: u64,
    data_hole_ratio_trigger: f32,
    tail_free_trigger: u64,
};
~~~

Editor 默认：

- allow_write = true
- allow_checkpoint = true
- allow_relocation = true
- allow_truncate = true
- idle aggressive checkpoint/optimize

Runtime 默认：

- allow_write 按平台配置
- allow_checkpoint = true，但低频
- allow_relocation = false 或只在安全点执行
- allow_truncate = false 或退出/关卡切换执行
- 大 value streaming，避免污染 cache

---

## 13. 重点与难点

### 13.1 难点：崩溃一致性

难点不是写入，而是任意位置崩溃后能恢复到一致状态。

关键手段：

- 双 superblock。
- record footer commit marker。
- header/payload/record crc。
- delta journal replay。
- base/checkpoint 不原地修改。
- dirty flag。
- orphan/quarantine 策略。

### 13.2 难点：mmap mutable index

mmap 修改不是普通内存修改那么简单。

必须处理：

- reader 看到半写 slot。
- cache line tearing。
- flush 顺序。
- 崩溃后 hash table 与 journal 不一致。
- 跨平台 msync/FlushViewOfFile 行为差异。

解决：

- journal 是真相。
- hash table 可重建。
- slot 使用 lock/seqlock。
- clean flag 控制恢复。

### 13.3 难点：old offset 复用

reader 可能 lookup 到 old offset 后，writer 更新 index 并释放 old block。

如果 old block 被立即复用，reader 会读到别的 record。

解决：

- get 进入 read epoch。
- retire block 记录 retire_epoch。
- oldest_reader_epoch 安全后才能 free。

### 13.4 难点：空间回收与 truncate

中间 hole 不能直接缩容。

要缩容必须：

- relocation 把尾部 live record 搬到前部 hole。
- 尾部形成连续 free range。
- epoch 安全。
- allocator checkpoint 安全。
- superblock 安全。

### 13.5 重点：底层 IO 可控

实现必须避免：

- 隐式文件偏移。
- 隐式 flush。
- data 全量 mmap。
- 高频 fsync。
- 高频 truncate。
- 大 value 污染 index cache。

### 13.6 重点：验证工具

必须提供离线/在线 verify：

- verify index superblock。
- verify region directory。
- verify base bucket range。
- replay journal 到临时 hash。
- verify data record crc。
- verify index -> record key/version/crc。
- 找 orphan、dangling index、duplicate visible key。

---

## 14. 推荐实现阶段

### Phase 0：最小原型

- Zig platform file IO。
- data append record。
- record crc/footer。
- 简单内存 index，仅用于验证 data 格式。

### Phase 1：可用 V1

- index.db base bucket index。
- delta hash table。
- delta journal。
- get/put/delete。
- crash recovery replay。
- checkpoint base+delta。
- C ABI。
- verify 工具。

### Phase 2：空间管理

- free-list allocator。
- retired epoch。
- allocator checkpoint。
- orphan/quarantine recovery。

### Phase 3：优化整理

- relocation。
- tail shrink。
- editor idle optimize。
- runtime safe-point optimize。

### Phase 4：性能与高级功能

- pwritev/writev batching。
- async IO / IOCP / io_uring 可选。
- read cache。
- data db placement policy。
- patch/mod overlay policy。
- partial checkpoint。

---

## 15. 最终定版摘要

本 DB 是一个面向游戏资产的嵌入式 KV 存储。

它使用 mmap-friendly index 实现快速 point lookup；使用 append-first immutable data record 保证写入简单和崩溃可恢复；使用 delta journal 保证 runtime/editor 增删改；使用 checkpoint 将增量合并为稳定 base；使用 epoch 保护 reader；使用可控 platform IO 层降低系统调用和 cache 副作用。

第一版优先实现正确性和恢复能力，不急于做空间回收。等文件格式、journal、checkpoint、verify 稳定后，再加入 allocator、relocation、truncate。
