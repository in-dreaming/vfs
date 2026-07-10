下面把这三块进一步细化到“可以开工实现”的粒度：

```text id="qj4b2a"
1. index.db 二进制布局
2. delta hash table 的 seqlock / 并发 / 恢复协议
3. data db allocator 的 free-list / checkpoint / relocation 格式
```

---

# 1. `index.db` 二进制布局

## 1.1 设计目标

`index.db` 需要同时满足：

```text id="zzzhf9"
1. 不全量加载到内存。
2. mmap 后可直接 lookup。
3. base index 查询快。
4. runtime/editor 都能写 index。
5. 写入不原地修改 base。
6. delta 可恢复。
7. checkpoint 可原子切换。
```

Linux 上 `mmap()` 是在进程虚拟地址空间创建文件映射，真正的物理页由 OS 按需加载；因此 index 可以设计成 mmap-friendly 的数组结构，而不是启动时构建内存哈希表。([man7.org][1])

---

## 1.2 文件总体布局

建议 `index.db` 使用固定头 + 多个 region：

```text id="80ayrb"
index.db

+-------------------------------+
| FileHeader                    |
+-------------------------------+
| SuperBlock A                  |
+-------------------------------+
| SuperBlock B                  |
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
| Free / Old Base / Checkpoint  |
+-------------------------------+
```

这里的 `DeltaGeneration 0/1` 不是概念绕圈，而是为 checkpoint 服务：

```text id="b35xk1"
active_delta:
  当前写入

checkpointing_delta:
  已冻结，正在合并进 new base
```

lookup 顺序：

```text id="mvvfhu"
active_delta
checkpointing_delta
base
```

---

## 1.3 FileHeader

`FileHeader` 固定在文件头，只写一次，主要用于识别格式。

```cpp id="i7zvmf"
struct IndexFileHeader {
    uint32_t magic;          // 'GKVI' / Game KV Index
    uint16_t major_version;
    uint16_t minor_version;

    uint32_t endian;         // 0x01020304
    uint32_t pointer_size;   // reserved, normally 8

    uint64_t file_header_size;
    uint64_t superblock_a_offset;
    uint64_t superblock_b_offset;
    uint64_t region_directory_offset;

    uint64_t page_size;      // build-time assumed page size, e.g. 4096
    uint64_t alignment;      // e.g. 4096 or 64K

    uint8_t  uuid[16];
    uint32_t header_crc;
};
```

要求：

```text id="v8qp9f"
1. 所有 offset 都是文件内 offset，不存进程指针。
2. 结构体字段固定大小，不用平台相关类型。
3. 多字节字段统一 little-endian。
4. region 起始最好 4KB 对齐。
```

---

## 1.4 SuperBlock A/B

`SuperBlock` 是当前 index 状态的入口。

双 superblock 解决“写到一半崩溃”的问题。

```cpp id="4vm3d9"
struct IndexSuperBlock {
    uint32_t magic;              // 'ISB0'
    uint32_t version;

    uint64_t epoch;              // 单调递增
    uint64_t file_size;

    uint64_t active_base_region_id;
    uint64_t active_delta_region_id;
    uint64_t checkpoint_delta_region_id; // 0 表示无

    uint64_t region_directory_epoch;
    uint64_t last_committed_journal_epoch;

    uint32_t clean_shutdown;     // 1 clean, 0 dirty
    uint32_t flags;

    uint64_t create_time;
    uint64_t update_time;

    uint8_t  reserved[128];

    uint32_t crc;
};
```

启动时：

```text id="qkdt4y"
1. 读 SuperBlock A/B。
2. 检查 magic/crc。
3. 选择 epoch 最大且 crc 正确的 superblock。
4. 如果 clean_shutdown = 0，则执行 journal recovery。
```

superblock 写入顺序：

```text id="82iznv"
1. 写新 region / new base / new delta。
2. fsync 或 msync 对应区域。
3. 写另一个 superblock。
4. fsync superblock 所在页。
```

如果通过 mmap 修改 superblock，需要显式同步。`msync()` 用于把 mmap 区域的修改同步到底层存储，POSIX 文档说明它用于确保映射区数据完整写入永久存储。([man7.org][2])

---

## 1.5 RegionDirectory

region directory 管理 index.db 内部区域。

```cpp id="5tq7e6"
enum RegionType : uint32_t {
    REGION_FREE       = 0,
    REGION_BASE_INDEX = 1,
    REGION_DELTA      = 2,
    REGION_OLD_BASE   = 3,
    REGION_RESERVED   = 4,
};

struct RegionDesc {
    uint64_t region_id;
    uint32_t type;
    uint32_t state;

    uint64_t offset;
    uint64_t size;

    uint64_t epoch_created;
    uint64_t epoch_retired;

    uint32_t crc;
    uint32_t flags;
};

struct RegionDirectory {
    uint32_t magic;       // 'IRD0'
    uint32_t version;

    uint64_t epoch;
    uint64_t region_count;
    uint64_t region_capacity;

    RegionDesc regions[];

    // crc at end
};
```

region state：

```text id="smj9ri"
FREE
BUILDING
ACTIVE
CHECKPOINTING
RETIRED
PENDING_RECLAIM
```

实现上可以先简单化：

```text id="751irz"
V1:
  region directory 固定容量，例如 4096 个 RegionDesc
  不做复杂空间回收
  old region 等下一次 full optimize 回收

V2:
  支持 region coalesce
  支持 index.db 内部空间复用
```

---

# 2. Base Index 详细格式

## 2.1 BaseIndexHeader

```cpp id="xn7ybe"
struct BaseIndexHeader {
    uint32_t magic;           // 'BIDX'
    uint32_t version;

    uint64_t build_epoch;

    uint32_t key_bits;        // 64 or 128
    uint32_t hash_bits;       // 64
    uint32_t bucket_bits;     // e.g. 20 or 21
    uint32_t entry_size;

    uint64_t bucket_count;
    uint64_t entry_count;

    uint64_t bucket_offset;   // relative to BaseIndex region
    uint64_t entry_offset;    // relative to BaseIndex region

    uint64_t min_hash;
    uint64_t max_hash;

    uint32_t bucket_crc;
    uint32_t entry_crc;
    uint32_t header_crc;
};
```

---

## 2.2 BucketTable

```cpp id="tsrlx9"
struct BaseBucket {
    uint64_t begin;   // EntryArray index
    uint32_t count;
    uint32_t flags;
};
```

大小：

```text id="56u2la"
bucket_count = 2^20
BaseBucket = 16B
BucketTable = 16MB
```

10M key 时平均 bucket：

```text id="9fibjr"
10,000,000 / 1,048,576 ≈ 9.5 entries
```

---

## 2.3 BaseEntry

推荐固定大小，方便 mmap 后随机访问。

```cpp id="ezav81"
struct BaseEntry {
    uint64_t h;        // secondary hash64

    uint64_t key_hi;
    uint64_t key_lo;

    uint32_t data_db_id;
    uint32_t flags;

    uint64_t offset;

    uint32_t stored_size;
    uint32_t raw_size;

    uint64_t version;

    uint32_t crc;
    uint16_t codec;
    uint16_t reserved;
};
```

大小约：

```text id="tsq24x"
8 + 16 + 8 + 8 + 8 + 8 = 56B
对齐后 64B
```

10M entry：

```text id="g1mbqk"
约 640MB
```

mmap 下这是可以接受的，因为不会一次性读入物理内存。

---

## 2.4 Base lookup

```cpp id="q0lqcl"
bool base_lookup(BaseIndex* base, Key128 key, IndexInfo* out) {
    uint64_t h = mix_hash128_to_u64(key);

    uint64_t bucket_id = h >> (64 - base->bucket_bits);
    BaseBucket b = base->buckets[bucket_id];

    BaseEntry* begin = base->entries + b.begin;
    BaseEntry* end   = begin + b.count;

    // bucket 内按 (h, key_hi, key_lo) 排序
    auto range = equal_range_by_hash(begin, end, h);

    for (BaseEntry* e = range.first; e != range.second; ++e) {
        if (e->key_hi == key.hi && e->key_lo == key.lo) {
            *out = entry_to_info(*e);
            return true;
        }
    }

    return false;
}
```

bucket 内可以：

```text id="z52sxf"
count <= 16: 线性扫描通常最快
count > 16: binary search by h
```

建议实现：

```cpp id="54sb2m"
if (b.count <= 16) linear_scan();
else binary_search();
```

---

# 3. Delta Hash Table 设计

## 3.1 Delta 的职责

delta 负责所有 runtime/editor 的 index 修改：

```text id="8kdjxa"
put
delete tombstone
覆盖 base
覆盖旧 delta
```

base 不做原地插入/删除。

---

## 3.2 DeltaHeader

```cpp id="h4vko7"
struct DeltaHeader {
    uint32_t magic;       // 'DIDX'
    uint32_t version;

    uint64_t generation_id;
    uint64_t create_epoch;

    uint32_t table_bits;
    uint32_t slot_size;

    uint64_t slot_count;
    uint64_t live_count;
    uint64_t tombstone_count;

    uint64_t slot_offset;     // relative to delta region
    uint64_t journal_offset;  // relative to delta region
    uint64_t journal_size;
    uint64_t journal_tail;

    uint32_t clean;           // 1 clean, 0 dirty
    uint32_t flags;

    uint32_t header_crc;
};
```

`slot_count` 建议保持 2 的幂：

```text id="r5fybc"
slot_count = 1 << table_bits
```

load factor：

```text id="hr200q"
live_count + tombstone_count <= slot_count * 0.70
```

超过就 freeze delta，创建新 active delta，后台 checkpoint。

---

## 3.3 DeltaSlot

```cpp id="lp6zgi"
enum DeltaSlotState : uint8_t {
    SLOT_EMPTY     = 0,
    SLOT_OCCUPIED  = 1,
    SLOT_TOMBSTONE = 2,
};

struct DeltaSlot {
    std::atomic<uint64_t> seq;

    uint64_t h;

    uint64_t key_hi;
    uint64_t key_lo;

    uint32_t data_db_id;
    uint32_t flags;

    uint64_t offset;

    uint32_t stored_size;
    uint32_t raw_size;

    uint64_t version;

    uint32_t crc;
    uint16_t codec;
    uint8_t  state;
    uint8_t  reserved0;

    uint32_t slot_crc;
    uint32_t reserved1;
};
```

建议对齐到 64B 或 128B。

如果 slot 是 64B：

```text id="zxnzrq"
1M slots ≈ 64MB
```

如果 runtime delta 允许 1M 修改，64MB mmap delta hash 是可接受的。

---

## 3.4 为什么用 seqlock

delta slot 会被 writer 原地更新，reader 不能看到半写入状态。

seqlock 的思想是：

```text id="o3apyn"
writer:
  seq 变奇数
  写数据
  seq 变偶数

reader:
  读 seq
  复制数据
  再读 seq
  如果 seq 没变且为偶数，说明数据一致
```

Linux 内核文档将 sequence counter/seqlock 描述为一种 reader-writer 一致性机制，读者无需加锁，通过重试获得一致快照。([内核文档][3])

这里我们只借鉴机制，不直接依赖内核 seqlock。

---

## 3.5 Delta read slot

```cpp id="y950l6"
bool read_slot_consistent(const DeltaSlot* slot, DeltaSlotSnapshot* out) {
    for (;;) {
        uint64_t s1 = slot->seq.load(std::memory_order_acquire);

        if (s1 & 1) {
            cpu_relax();
            continue;
        }

        // copy fields
        DeltaSlotSnapshot tmp;
        tmp.h           = slot->h;
        tmp.key_hi      = slot->key_hi;
        tmp.key_lo      = slot->key_lo;
        tmp.data_db_id  = slot->data_db_id;
        tmp.flags       = slot->flags;
        tmp.offset      = slot->offset;
        tmp.stored_size = slot->stored_size;
        tmp.raw_size    = slot->raw_size;
        tmp.version     = slot->version;
        tmp.crc         = slot->crc;
        tmp.codec       = slot->codec;
        tmp.state       = slot->state;
        tmp.slot_crc    = slot->slot_crc;

        std::atomic_thread_fence(std::memory_order_acquire);

        uint64_t s2 = slot->seq.load(std::memory_order_acquire);

        if (s1 == s2 && !(s2 & 1)) {
            *out = tmp;
            return true;
        }
    }
}
```

注意：如果 slot 内含非原子字段，reader 直接读这些字段在 C++ 标准层面可能有 data race。工程上有三种处理方式：

```text id="v9mqe6"
方案 A：slot 写入用原子字段，严格 C++ 合法。
方案 B：用 memcpy + 平台约定，接受底层工程实践。
方案 C：reader 对 delta bucket 加 shared lock，放弃无锁读。
```

推荐 V1 选择：

```text id="tjb73f"
delta lookup 不加全局锁；
slot 使用 seq + 原子/对齐字段；
writer 用 per-stripe lock。
```

如果你想先稳：

```text id="acfa05"
V1 可以直接用 striped RWLock。
V2 再换 seqlock。
```

---

## 3.6 Delta write slot

writer 对同一 key 使用 striped key lock，对同一 probe 区间也可以用 stripe lock，避免多个 writer 抢同一 slot。

```cpp id="zq4q1i"
void write_slot(DeltaSlot* slot, const DeltaSlotSnapshot& v) {
    uint64_t old = slot->seq.load(std::memory_order_relaxed);

    // odd = writing
    slot->seq.store(old + 1, std::memory_order_release);

    slot->h           = v.h;
    slot->key_hi      = v.key_hi;
    slot->key_lo      = v.key_lo;
    slot->data_db_id  = v.data_db_id;
    slot->flags       = v.flags;
    slot->offset      = v.offset;
    slot->stored_size = v.stored_size;
    slot->raw_size    = v.raw_size;
    slot->version     = v.version;
    slot->crc         = v.crc;
    slot->codec       = v.codec;
    slot->state       = v.state;
    slot->slot_crc    = calc_slot_crc(v);

    std::atomic_thread_fence(std::memory_order_release);

    // even = stable
    slot->seq.store(old + 2, std::memory_order_release);
}
```

---

## 3.7 Delta hash probing

使用 open addressing。

建议 Robin Hood hash 可提升稳定性，但实现复杂。V1 先用 linear probing 或 quadratic probing。

```cpp id="1r4pls"
uint64_t pos = h & (slot_count - 1);

for (uint32_t probe = 0; probe < max_probe; ++probe) {
    DeltaSlot* slot = &slots[pos];

    snapshot = read_slot(slot);

    if (snapshot.state == EMPTY) {
        return not_found;
    }

    if ((snapshot.state == OCCUPIED || snapshot.state == TOMBSTONE) &&
        snapshot.h == h &&
        snapshot.key_hi == key.hi &&
        snapshot.key_lo == key.lo) {
        return found(snapshot);
    }

    pos = (pos + 1) & (slot_count - 1);
}
```

注意 tombstone：

```text id="jnf52p"
lookup:
  遇到 tombstone 且 key 相等，表示 deleted。
  遇到 unrelated tombstone 不能停止 probe。

insert:
  可以复用第一个 unrelated tombstone slot。
```

---

## 3.8 Delta journal 写入协议

journal 是恢复真相。delta hash table 是加速结构。

```cpp id="nkrfc6"
struct DeltaJournalRecordHeader {
    uint32_t magic;       // 'DJR0'
    uint16_t version;
    uint16_t op;          // PUT / DELETE / BATCH_BEGIN / BATCH_COMMIT

    uint64_t journal_epoch;
    uint64_t batch_id;

    uint32_t record_size;
    uint32_t header_crc;
};

struct DeltaJournalPayload {
    uint64_t h;
    uint64_t key_hi;
    uint64_t key_lo;
    IndexInfo info;
};

struct DeltaJournalRecordFooter {
    uint32_t magic_commit; // 'DEND'
    uint32_t record_crc;
};
```

写入顺序：

```text id="w9u10n"
1. data db record 写完。
2. append delta journal record。
3. journal record footer 写完。
4. 根据 durability 决定是否 fsync/msync。
5. 更新 delta hash slot。
```

为什么 journal 先于 hash table：

```text id="wx0vle"
如果 hash table 更新了但 journal 没写完整，崩溃后无法恢复该 index 修改。
如果 journal 写完整但 hash table 没更新，崩溃后可以 replay journal 重建。
```

---

## 3.9 Delta recovery

启动时：

```text id="8dh8p2"
if delta.clean == 1:
  可以直接使用 delta hash table
else:
  清空 delta hash table
  扫描 delta journal
  对每条完整 journal record replay 到 hash table
  遇到半条 record 停止
  设置 clean = 1
```

journal 扫描规则：

```text id="3j50um"
1. header magic 正确。
2. record_size 合法。
3. header_crc 正确。
4. footer magic 正确。
5. record_crc 正确。
6. op 合法。
```

遇到不完整：

```text id="0uqq0y"
截断 journal_tail 到最后一条完整 record 之后。
```

---

## 3.10 Delta clean/dirty 状态

open 时：

```text id="9vxzif"
delta.clean = 0
写 superblock/index header
```

正常 close 时：

```text id="asjhrw"
flush journal
flush hash table
delta.clean = 1
写 superblock
```

崩溃后：

```text id="05c4nk"
delta.clean = 0
强制 replay journal
```

---

# 4. Checkpoint 细化

## 4.1 为什么需要双 delta generation

checkpoint 时不能阻塞 runtime/editor 新写入。

流程：

```text id="42uf5g"
1. active_delta 变成 checkpointing_delta。
2. 新建 active_delta。
3. 新写入进入新 active_delta。
4. 后台 merge base + checkpointing_delta。
5. 生成 new base。
6. 切换 superblock。
```

---

## 4.2 merge 算法

输入：

```text id="rejmnw"
old_base entries sorted by (bucket, h, key)
checkpoint_delta hash table
```

输出：

```text id="44dj3h"
new_base entries sorted by new bucket/h/key
```

简单实现：

```text id="qxapz5"
1. 遍历 old_base entries。
2. 对每个 base key 查 checkpoint_delta：
   - delta tombstone：跳过。
   - delta put：输出 delta 新值。
   - delta 无：输出 base 原值。
3. 遍历 checkpoint_delta：
   - 对 base 不存在的新 key，输出。
4. 对输出 entries 按 h/key 排序。
5. 构建 bucket table。
```

为了避免“查 base 是否存在”太慢，可以在步骤 3 构建一个临时 bitset 或者给 delta slot 标记 `consumed`。

V1 可以允许 checkpoint 使用临时内存，因为 checkpoint 是后台维护，不是 runtime lookup 路径。

---

## 4.3 checkpoint 原子切换

```text id="v850ai"
1. new base 写到新 region，state = BUILDING。
2. 写完后校验 crc。
3. region state = ACTIVE_CANDIDATE。
4. fsync/msync new base。
5. 写 SuperBlock，把 active_base_region_id 指向 new base。
6. old base state = RETIRED。
7. checkpoint_delta state = RETIRED。
8. 等 reader epoch 后回收 old regions。
```

---

# 5. `data db allocator` 详细设计

## 5.1 Data DB 文件布局

```text id="z4g0ny"
data_000.db

+-------------------------------+
| DataFileHeader                |
+-------------------------------+
| SuperBlock A                  |
+-------------------------------+
| SuperBlock B                  |
+-------------------------------+
| AllocatorCheckpoint Region    |
+-------------------------------+
| Record Area                   |
|   [Record][Hole][Record]      |
|   [Record][Free Tail]         |
+-------------------------------+
```

---

## 5.2 DataFileHeader

```cpp id="26j91y"
struct DataFileHeader {
    uint32_t magic;          // 'GKVD'
    uint16_t major_version;
    uint16_t minor_version;

    uint32_t endian;
    uint32_t flags;

    uint64_t header_size;
    uint64_t superblock_a_offset;
    uint64_t superblock_b_offset;

    uint64_t record_area_offset;
    uint64_t alignment;

    uint8_t uuid[16];

    uint32_t crc;
};
```

---

## 5.3 DataSuperBlock

```cpp id="qaug3a"
struct DataSuperBlock {
    uint32_t magic;      // 'DSB0'
    uint32_t version;

    uint64_t epoch;

    uint64_t file_size;
    uint64_t logical_tail;      // 当前 append tail
    uint64_t durable_tail;      // 已确认持久化 tail，可选

    uint64_t allocator_checkpoint_offset;
    uint64_t allocator_checkpoint_size;
    uint64_t allocator_checkpoint_epoch;

    uint64_t free_bytes;
    uint64_t pending_free_bytes;
    uint64_t tail_free_bytes;

    uint32_t clean_shutdown;
    uint32_t flags;

    uint32_t crc;
};
```

---

## 5.4 Allocator 设计

### 5.4.1 Block 状态

```text id="fdduhs"
LIVE:
  index 指向该 record

RETIRED:
  index 已不指向，但可能有 reader 持有旧 offset

FREE:
  可以重新分配

TAIL_FREE:
  文件尾部连续 free，可 truncate
```

### 5.4.2 Free block 格式

allocator checkpoint 里保存 free list。

```cpp id="o145ch"
struct FreeBlockDisk {
    uint64_t offset;
    uint32_t size;
    uint32_t size_class;
};
```

### 5.4.3 Size class

建议按 2 的幂分桶：

```text id="60jjbc"
class 0: <= 256B
class 1: <= 512B
class 2: <= 1KB
class 3: <= 2KB
...
class N: > 64MB
```

计算：

```cpp id="mm6nns"
uint32_t size_class(uint32_t size) {
    size = align_up(size, 16);
    if (size <= 256) return 0;
    return ceil_log2(size) - 8;
}
```

### 5.4.4 分配策略

```cpp id="zzr3p2"
AllocResult allocate(uint32_t size) {
    size = align_up(size, record_alignment);

    lock allocator;

    for class c = size_class(size) to max_class:
        block = freelist[c].find_first_fit(size);
        if block:
            remove block;
            if block.size - size >= min_split_size:
                split remainder back to freelist;
            unlock;
            return block.offset;

    offset = logical_tail;
    logical_tail += size;
    ensure_file_size(logical_tail);

    unlock;
    return offset;
}
```

### 5.4.5 释放策略

不能直接放入 free list。

```cpp id="l0tkum"
void retire_block(offset, size) {
    RetiredBlock rb;
    rb.offset = offset;
    rb.size = size;
    rb.retire_epoch = current_epoch();

    retired_list.push(rb);
}
```

后台：

```cpp id="6dk86s"
void reclaim_retired() {
    uint64_t safe_epoch = oldest_reader_epoch();

    for rb in retired_list:
        if rb.retire_epoch < safe_epoch:
            freelist_insert(rb.offset, rb.size);
}
```

---

## 5.5 AllocatorCheckpoint

### 5.5.1 格式

```cpp id="nrpm5k"
struct AllocatorCheckpointHeader {
    uint32_t magic;       // 'ACKP'
    uint32_t version;

    uint64_t epoch;

    uint64_t logical_tail;
    uint64_t free_bytes;
    uint64_t pending_free_bytes;

    uint32_t class_count;
    uint32_t block_count;

    uint64_t block_array_offset;

    uint32_t header_crc;
};

struct AllocatorCheckpoint {
    AllocatorCheckpointHeader header;
    FreeBlockDisk blocks[];
    uint32_t checkpoint_crc;
};
```

这里只保存 `FREE` blocks，不保存 `RETIRED` blocks。崩溃后 `RETIRED` 可以通过 index/data 扫描重建。

### 5.5.2 checkpoint 触发

```text id="ez829n"
1. free list 变化超过 N 次。
2. free_bytes 超过阈值。
3. optimize 前后。
4. close DB。
5. 定时后台。
```

### 5.5.3 checkpoint 写入顺序

```text id="b2a4nb"
1. 在 data db 中分配新的 checkpoint region。
2. 写 AllocatorCheckpointHeader + blocks。
3. 写 crc。
4. fsync/msync。
5. 写 DataSuperBlock 指向新 checkpoint。
6. old checkpoint region retire。
```

---

## 5.6 崩溃恢复中的 allocator

启动时：

```text id="rujc6b"
1. 读取 DataSuperBlock。
2. 加载 allocator checkpoint。
3. 如果 clean，直接使用。
4. 如果 dirty，执行修复：
   a. 读取 index，收集 live offset set。
   b. 扫描 data db records。
   c. valid record 且在 live offset set 中 -> LIVE。
   d. valid record 但不在 live offset set 中 -> FREE/orphan。
   e. invalid partial record -> tail 截断或忽略。
5. 重建 free list。
```

V1 可以选择保守策略：

```text id="il4pjn"
dirty recovery 时不立即复用无法确定的区域；
先加入 quarantine；
下次 full verify 后再释放。
```

---

# 6. Data write 细节

## 6.1 IO API

data db 写 record 不建议用 mmap，而是 `pread/pwrite` 或 Windows overlapped IO。

POSIX `pwrite()` 在指定 offset 写入，并且不改变文件描述符当前偏移；这正适合多线程同一文件不同 offset 并发读写。([man7.org][4])

Windows `WriteFile` 在 `OVERLAPPED` 中通过 `Offset`/`OffsetHigh` 指定写入位置。([微软学习][5])

---

## 6.2 Record 写入顺序

```text id="2x7cyw"
1. allocator 分配 offset。
2. 写 header，其中 flags 不含 COMMITTED。
3. 写 payload。
4. 写 footer commit marker。
5. 可选 fdatasync/group flush。
6. 返回 IndexInfo 给 index 层。
```

record 是否有效由：

```text id="0gciyu"
header magic
record size 合法
header crc
payload crc
footer magic
record crc
```

共同判断。

---

## 6.3 Put 完整顺序

```text id="s02n0a"
put:
  key lock
  allocate data block
  write data record
  append delta journal
  publish delta hash table
  retire old index target
  unlock
```

如果崩溃：

```text id="m143my"
data 写完，journal 没写：
  record 是 orphan，恢复时释放。

journal 写完，delta hash 没写：
  replay journal 恢复。

delta hash 写完，superblock 未 clean：
  replay journal 仍可恢复。
```

---

# 7. Relocation 细化

## 7.1 relocation 触发

```text id="llg480"
1. data_db free_bytes / file_size > 30%
2. tail_free_bytes > 512MB
3. runtime 退出/关卡切换
4. editor idle
5. 手动 optimize
```

---

## 7.2 relocation 候选选择

为了缩容，优先搬尾部 live record：

```text id="8gsxm1"
从文件尾部向前扫描 live records
把它们搬到文件前部 holes
让 tail 变成连续 free
```

需要维护或临时构建：

```text id="fo7nr8"
live record offset -> key
```

这个信息可从 index 反查，也可以 record header 自带 key。

---

## 7.3 relocation 协议

```text id="9iut7e"
1. 读取 old record。
2. 确认 index 仍然指向 old offset。
3. 分配 new offset，优先前部 hole。
4. 写 new record。
5. CAS index old_info -> new_info。
6. CAS 成功：old block retire。
7. CAS 失败：new block retire。
```

CAS index 对 delta/base 的处理：

```text id="iwtjg2"
如果 key 当前在 active_delta:
  compare active_delta slot old_info

如果 key 当前只在 base:
  写 active_delta 覆盖 base，前提是 lookup 结果仍是 old_info

如果 key 被 tombstone/delete:
  relocation 放弃，new block retire
```

---

# 8. Index CAS 语义

因为 base 不改，CAS 不是物理地改 base entry。

逻辑 CAS：

```cpp id="tr3hb4"
bool index_compare_exchange(Key128 key, IndexInfo expected, IndexInfo desired) {
    KeyLockGuard lock(key);

    IndexInfo current;
    bool exists = lookup_current(key, &current);

    if (!exists) return false;
    if (!same_location(current, expected)) return false;

    delta_journal_append(Put, key, desired);
    delta_hash_put(key, desired);

    return true;
}
```

所以 relocation 对 base record 的“CAS 更新”实际是：

```text id="fgar3x"
确认当前 lookup 仍是 expected
然后向 delta 写 desired
```

这很重要，因为 base index 不原地修改。

---

# 9. 读写锁模型

最终需要的锁：

```text id="0nztbw"
1. key striped lock
   保护同一 key put/delete/relocate 竞争

2. delta stripe lock
   保护 delta hash probe/insert

3. allocator lock
   保护 free list 和 logical_tail

4. resize lock
   保护 truncate 与分配冲突

5. checkpoint state lock
   保护 active_delta freeze/switch

6. epoch/RCU
   保护 old offset、old base、old delta region 延迟回收
```

普通 get：

```text id="kjkm0t"
不拿 key lock
只 enter read epoch
查 delta/base
pread data
exit epoch
```

普通 put：

```text id="y3x0nr"
key lock
短 allocator lock
delta stripe lock
```

relocation：

```text id="10y02u"
key lock
allocator lock
delta stripe lock
```

truncate：

```text id="1pafls"
resize lock
要求低频
```

---

# 10. 建议 V1 取舍

为了快速做出来，建议 V1 不要一次实现所有复杂优化。

## V1 必须有

```text id="b3hj13"
1. index.db base bucket index
2. delta mmap hash table
3. delta journal replay
4. data db append write
5. data record crc/footer
6. key striped lock
7. reader epoch
8. delete tombstone
9. checkpoint base+delta
```

## V1 可以暂缓

```text id="i69k8v"
1. data hole reuse
2. relocation
3. truncate shrink
4. Robin Hood hash
5. multi-level delta
6. async io_uring / IOCP
```

## V2 再做

```text id="6ueh33"
1. free-list allocator
2. allocator checkpoint
3. relocation
4. tail shrink
5. quarantine recovery
6. load group locality optimize
```

---

# 11. 推荐代码模块划分

```text id="gouqhx"
kvdb/
  index/
    index_file.h
    superblock.h
    base_index.h
    delta_index.h
    delta_journal.h
    checkpoint.h

  data/
    data_file.h
    record.h
    allocator.h
    allocator_checkpoint.h
    relocation.h

  concurrency/
    epoch.h
    striped_lock.h
    seqlock_slot.h

  platform/
    file_io_posix.h
    file_io_windows.h
    mmap_posix.h
    mmap_windows.h

  db/
    kvdb.h
    batch.h
    recovery.h
    verify.h
```

---

# 12. 最终细化结论

这三块可以这样定版：

```text id="q8z8k2"
index.db:
  双 superblock
  region directory
  base bucket index
  双 delta generation
  delta journal
  checkpoint 原子切换

delta hash:
  mmap open addressing
  slot 使用 seq/seqlock 防半写读取
  writer 使用 striped lock
  journal 是恢复真相
  hash table 是查询加速
  dirty 时 replay journal

data allocator:
  append-first
  V1 可纯 append
  V2 增加 size-class free-list
  free 走 retire epoch
  allocator checkpoint 双写
  relocation 通过逻辑 CAS index 安全搬移
  truncate 只在 tail 全 free 且 epoch 安全时执行
```

如果现在开工，我建议先写 **Phase 1 原型**：

```text id="qvb51p"
1. data db append-only record file
2. index base bucket 构建器
3. delta hash + journal
4. lookup/put/delete
5. checkpoint 合并
6. crash recovery replay
```

跑通后再加 allocator 和 relocation，否则第一版复杂度会过高。

[1]: https://man7.org/linux/man-pages/man2/mmap.2.html?utm_source=chatgpt.com "mmap(2) - Linux manual page"
[2]: https://man7.org/linux/man-pages/man3/msync.3p.html?utm_source=chatgpt.com "msync(3p) - Linux manual page"
[3]: https://docs.kernel.org/locking/seqlock.html?utm_source=chatgpt.com "Sequence counters and sequential locks"
[4]: https://man7.org/linux/man-pages/man2/pread.2.html?utm_source=chatgpt.com "pread(2) - Linux manual page"
[5]: https://learn.microsoft.com/en-us/windows/win32/api/fileapi/nf-fileapi-writefile?utm_source=chatgpt.com "WriteFile function (fileapi.h) - Win32 apps"
