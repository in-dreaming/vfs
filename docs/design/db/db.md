# 游戏引擎 KV 数据库设计调研文档

## 0. 结论摘要

本数据库用于游戏引擎 editor 和 runtime 的统一资产存储，目标是存储 import 后的引擎格式数据，并支持运行时文件增删改。最终推荐方案是：

```text
Index DB:
  mmap base bucket index
  + mmap mutable delta hash index
  + delta journal
  + checkpoint merge

Data DB[N]:
  append-first 数据文件
  + hole/free-list allocator
  + immutable record
  + background relocation
  + optional truncate shrink

Lookup:
  先查 delta index
  再查 base index

Write:
  先写 data db record
  再写 delta index
  旧 record 延迟回收

Delete:
  delta tombstone 覆盖 base/delta 旧值

Optimize:
  后台搬移 live record 到 hole
  释放尾部空间
  条件满足时 truncate 缩容
```

核心原则：

```text
1. data db 文件内 record 不原地覆盖。
2. 修改采用 append 或 hole reuse 写新 record。
3. index 决定 record 可见性。
4. old record 通过 epoch/RCU 延迟复用。
5. runtime/editor 使用同一套格式，但策略可配置。
6. index 不构建 map<key, info> 内存表，而是 mmap 文件内索引结构。
```

---

## 1. 需求定义

### 1.1 使用场景

数据库用于两类场景：

```text
Editor:
  存储 import 后的引擎格式资产
  支持增删改
  支持大规模资产导入
  支持后台整理、压缩、缩容

Runtime:
  读取引擎格式资产
  支持运行时新增、删除、修改文件
  支持 patch、mod、cache、热更新、本地生成内容
  与 editor 使用同一套 DB 格式
```

### 1.2 数据规模

目标支持：

```text
key 数量：千万级
value：从小 metadata 到大贴图、mesh、shader cache、音频等
data db：N 个数据文件
index db：一个或少数几个索引文件
```

### 1.3 key 形式

key 是：

```text
uint64 hash
或
uint128 hash
```

推荐内部统一按 `uint128` 设计。即使外部传入 `uint64`，也可以扩展成 `uint128`：

```text
key128 = { namespace/type/group, hash64 }
```

或者：

```text
key128 = hash128(namespace + virtual_path + import_settings + source_guid)
```

原因：

```text
1. 千万级数据下 uint64 碰撞概率不高，但不是零。
2. 引擎资产数据库更适合长期稳定、可校验的 key。
3. uint128 可以容纳 namespace/type/version 等扩展信息。
```

### 1.4 目录结构

目录结构不放在 index 主表里。

建议作为特殊 key 存储到 data db：

```text
KEY_DIRECTORY_TREE
KEY_ASSET_REGISTRY
KEY_SCHEMA_TABLE
KEY_IMPORT_DATABASE
```

runtime 启动时读取这些 blob，反序列化并构建内存目录树。

---

## 2. 总体架构

### 2.1 文件组成

```text
asset_store/
  index.db

  data_000.db
  data_001.db
  data_002.db
  ...
```

不再引入 segment 概念。

每个 `data_xxx.db` 就是一个独立数据文件，也是空间分配、搬移、缩容的基本单位。

### 2.2 逻辑结构

```text
Index DB:
  key -> IndexInfo

Data DB:
  offset -> Record
```

`IndexInfo` 指向 data db 中的数据位置：

```cpp
struct IndexInfo {
    uint32_t data_db_id;
    uint64_t offset;
    uint32_t stored_size;
    uint32_t raw_size;
    uint64_t version;
    uint32_t crc;
    uint16_t flags;
    uint16_t codec;
};
```

---

## 3. Data DB 设计

### 3.1 Data DB 文件布局

```text
data_000.db

+------------------------------+
| SuperBlock A                 |
+------------------------------+
| SuperBlock B                 |
+------------------------------+
| Allocator Checkpoint         |
+------------------------------+
| Records / Holes              |
|                              |
| [rec][rec][hole][rec][hole]  |
| [rec][free tail...]          |
+------------------------------+
```

### 3.2 SuperBlock

使用双 superblock，避免崩溃时损坏唯一元数据。

```cpp
struct DataSuperBlock {
    uint32_t magic;
    uint32_t version;
    uint64_t epoch;

    uint64_t logical_file_size;
    uint64_t physical_file_size;

    uint64_t allocator_checkpoint_offset;
    uint64_t allocator_checkpoint_size;

    uint64_t free_bytes;
    uint64_t pending_free_bytes;

    uint32_t crc;
};
```

启动时选择：

```text
epoch 最大
且 crc 正确
的 superblock
```

### 3.3 Record 格式

```cpp
struct RecordHeader {
    uint32_t magic;
    uint16_t header_version;
    uint16_t flags;

    uint64_t key_hi;
    uint64_t key_lo;

    uint64_t version;

    uint32_t header_size;
    uint32_t stored_size;
    uint32_t raw_size;

    uint32_t header_crc;
    uint32_t payload_crc;

    uint64_t txn_id;
};

[payload bytes]

struct RecordFooter {
    uint32_t magic_commit;
    uint32_t record_crc;
};
```

`RecordFooter` 可选，但强烈建议保留。它可以帮助崩溃恢复识别“写到一半的 record”。

### 3.4 写入原则

data db 内 record 不原地覆盖。

修改一个 key 时：

```text
1. 写一个新的 record。
2. index 指向新 record。
3. 旧 record 进入 retire/free-pending。
```

这避免：

```text
读写同一 byte range
变长 value 原地扩容
部分写损坏
复杂 page rollback
```

---

## 4. Data DB 的空间管理

### 4.1 append-first，不是 append-only

推荐不是纯 append-only，而是：

```text
优先找合适 hole
找不到再 append 到文件尾
```

也就是：

```text
append-first + hole reuse
```

### 4.2 Free-list allocator

data db 内部维护 size class freelist：

```text
free_list[0] : 0 ~ 256B
free_list[1] : 257B ~ 512B
free_list[2] : 513B ~ 1KB
free_list[3] : 1KB ~ 2KB
...
free_list[N] : large block
```

free block：

```cpp
struct FreeBlock {
    uint64_t offset;
    uint32_t size;
};
```

写入流程：

```text
1. 根据 record_size 找 size class。
2. 找到足够大的 hole。
3. 如果 hole 明显大于 record，则 split。
4. 没找到 hole，则 append 到 tail。
5. pwrite record。
6. 更新 index。
```

### 4.3 为什么不要每次写完立即整理

不建议：

```text
put 完立刻搬移数据填洞
```

因为这会把一次普通写入变成：

```text
写新 record
更新 index
搬移其他 record
再次更新 index
产生新 hole
等待 reader epoch
可能 truncate
```

会显著放大写延迟。

更合适的是：

```text
前台写只记录 hole。
后台根据条件 optimize。
```

### 4.4 后台 relocation

后台整理目标：

```text
1. 复用空洞
2. 把尾部 live record 搬到前部 hole
3. 让文件尾部形成连续 free range
4. truncate 缩容
```

relocation 流程：

```text
1. 选择一个 live record old_offset。
2. 找到一个合适 hole new_offset。
3. 从 old_offset 读取 record。
4. 写完整副本到 new_offset。
5. 校验 new record。
6. CAS 更新 index：
   只有 index 仍指向 old_offset/version，才改成 new_offset。
7. CAS 成功：old_offset retire。
8. CAS 失败：new_offset 作废，加入 retire/free。
```

伪代码：

```cpp
bool relocate(Key128 key, IndexInfo old_info, FreeBlock hole) {
    Record rec = read_record(old_info.offset);

    write_record_at(hole.offset, rec);

    IndexInfo new_info = old_info;
    new_info.offset = hole.offset;

    if (index_compare_exchange(key, old_info, new_info)) {
        retire_block(old_info.offset, old_info.stored_size);
        return true;
    } else {
        retire_block(hole.offset, old_info.stored_size);
        return false;
    }
}
```

### 4.5 truncate 缩容

只有文件尾部是连续 free range，才可以缩容。

```text
[Live][Hole][Live][HoleTail]
只能缩 HoleTail
不能直接缩中间 Hole
```

truncate 流程：

```text
1. 后台 relocation 把尾部 live record 搬到前部 hole。
2. 尾部 old block 进入 free-pending。
3. 等待 reader epoch 安全。
4. 确认 tail range 无 reader、无 writer、无 live record。
5. 获取 resize lock。
6. 更新 allocator metadata。
7. 写 superblock。
8. truncate 文件。
```

runtime 默认不建议频繁 truncate。可以配置为：

```text
Editor:
  idle 时 aggressive optimize/truncate

Runtime:
  默认关闭 truncate
  只在存档点、关卡切换、退出时低频执行
```

---

## 5. Index DB 设计

### 5.1 设计约束

index db 不全量加载为：

```cpp
map<Key, IndexInfo>
unordered_map<Key, IndexInfo>
```

而是通过 mmap 映射索引文件。

mmap 的意义是把文件映射到进程虚拟地址空间，实际物理内存由 OS 按页加载。Linux `mmap` 文档说明它会在调用进程虚拟地址空间创建新的映射；共享映射写回磁盘时通常需要配合同步机制，例如 `msync` 用于把 mmap 后的内存修改刷新回文件。

### 5.2 Index DB 总体布局

```text
index.db

+------------------------------+
| SuperBlock A                 |
+------------------------------+
| SuperBlock B                 |
+------------------------------+
| BaseIndexHeader              |
+------------------------------+
| BaseBucketTable              |
+------------------------------+
| BaseEntryArray               |
+------------------------------+
| DeltaGeneration 0            |
|   DeltaHashTable             |
|   DeltaJournal               |
+------------------------------+
| DeltaGeneration 1            |
|   DeltaHashTable             |
|   DeltaJournal               |
+------------------------------+
| Free / Checkpoint Area       |
+------------------------------+
```

### 5.3 为什么需要 base + delta

因为 runtime 也支持增删改，所以 index 不能是纯只读。

但也不应该直接原地修改 base index。

推荐结构：

```text
Base Index:
  大规模稳定索引
  mmap bucket table + sorted entries
  查询快
  不原地插入/删除

Delta Index:
  最近增删改
  mmap hash table
  支持运行时/editor 写入
  tombstone 覆盖 base
  定期 checkpoint 合并进 base
```

lookup：

```text
1. 查 active delta
2. 查 checkpointing delta
3. 查 base
```

put/delete：

```text
只写 active delta
```

checkpoint：

```text
base + frozen delta -> new base
原子切换 superblock
清理旧 base/delta
```

### 5.4 Base Index：bucket + sorted entries

Base index 文件结构：

```cpp
struct BaseIndexHeader {
    uint32_t format;
    uint32_t bucket_bits;

    uint64_t bucket_count;
    uint64_t entry_count;

    uint64_t bucket_offset;
    uint64_t entry_offset;

    uint32_t crc;
};

struct Bucket {
    uint64_t begin;
    uint32_t count;
    uint32_t flags;
};

struct BaseEntry {
    uint64_t h;

    uint64_t key_hi;
    uint64_t key_lo;

    IndexInfo info;
};
```

查找流程：

```text
1. h = mix_hash128_to_u64(key)
2. bucket_id = h >> (64 - bucket_bits)
3. 读取 Bucket{begin,count}
4. 在 entries[begin, begin+count) 中按 h/key 查找
5. full key 校验
```

伪代码：

```cpp
bool base_lookup(Key128 key, IndexInfo* out) {
    uint64_t h = mix_hash128_to_u64(key);

    uint32_t bucket_id = h >> (64 - bucket_bits);
    Bucket b = buckets[bucket_id];

    BaseEntry* begin = entries + b.begin;
    BaseEntry* end   = begin + b.count;

    auto range = equal_range_by_h(begin, end, h);

    for (BaseEntry* e = range.first; e != range.second; ++e) {
        if (e->key_hi == key.hi && e->key_lo == key.lo) {
            *out = e->info;
            return true;
        }
    }

    return false;
}
```

### 5.5 为什么 bucket 优于 tree

用户提出的方案：

```text
key -> hash32/hash64 -> tree -> collision verify
```

该方案可行，但不推荐作为主方案。

原因：

```text
1. key 本身已经是 hash，再 hash 后主要用途是打散和快速定位。
2. 对 point lookup 来说，bucket 是固定深度的浅层索引。
3. tree lookup 需要 root/internal/leaf 多次随机页访问。
4. mmap 下随机 page fault 成本高。
5. tree 的优势是 range scan 和动态插入，而本场景主要是 key -> info。
6. 动态写入已经由 delta hash index 承担。
```

推荐吸收 hash-of-hash 思路：

```text
使用 secondary hash64
不用 hash32
不用在 hash64 上建 tree
而是用 hash64 高位定位 bucket
bucket 内存 full key 解决碰撞
```

千万级数据不建议用 hash32。hash32 在 1000 万 key 下会产生大量碰撞，虽然可以用 full key 解决，但没有必要。

### 5.6 Bucket 参数建议

假设：

```text
entry_count = 10,000,000
```

推荐：

```text
bucket_count = 2^20 = 1,048,576
平均每 bucket ≈ 9.5 entries
BucketTable ≈ 16MB
```

或者：

```text
bucket_count = 2^21
平均每 bucket ≈ 4.8 entries
BucketTable ≈ 32MB
```

mmap 下 bucket table 通常会被 OS page cache 缓存住，entry array 按需分页。

### 5.7 Delta Index：mmap hash table + journal

Delta hash slot：

```cpp
struct DeltaSlot {
    std::atomic<uint64_t> seq;

    uint64_t h;

    uint64_t key_hi;
    uint64_t key_lo;

    IndexInfo info;

    uint8_t state; // empty / occupied / tombstone
    uint8_t op;    // put / delete
    uint16_t flags;

    uint32_t crc;
};
```

Delta journal entry：

```cpp
struct DeltaJournalEntry {
    uint32_t magic;
    uint16_t version;
    uint16_t op; // put/delete

    uint64_t epoch;

    uint64_t h;
    uint64_t key_hi;
    uint64_t key_lo;

    IndexInfo info;

    uint32_t crc;
};
```

Delta journal 是恢复真相，delta hash table 是查询加速结构。

启动时：

```text
1. 检查 delta hash table 是否 clean。
2. clean 则直接使用。
3. dirty 则根据 delta journal 重建 delta hash table。
```

---

## 6. Lookup 流程

完整 lookup：

```cpp
bool lookup(Key128 key, IndexInfo* out) {
    ReadGuard guard = enter_read_epoch();

    uint64_t h = mix_hash128_to_u64(key);

    if (delta_lookup(active_delta, h, key, out)) {
        return !out->is_tombstone();
    }

    if (checkpoint_delta &&
        delta_lookup(checkpoint_delta, h, key, out)) {
        return !out->is_tombstone();
    }

    return base_lookup(key, out);
}
```

查找顺序：

```text
active_delta
checkpointing_delta
base
```

原因：

```text
1. 最新修改一定在 active_delta。
2. checkpointing_delta 是被冻结、正在合并的旧 delta。
3. base 是稳定大索引。
```

---

## 7. 写入流程

### 7.1 put

```text
put(key, value):
  1. 获取 key-level lock。
  2. data db 分配空间。
  3. 写 record。
  4. 校验 record。
  5. append delta journal。
  6. 更新 delta hash table。
  7. retire old record。
  8. 返回。
```

伪代码：

```cpp
bool put(Key128 key, Span value) {
    KeyLockGuard lock(key);

    IndexInfo old_info;
    bool had_old = lookup_without_epoch_escape(key, &old_info);

    IndexInfo new_info = data_db_write_record(key, value);

    delta_journal_append(Put, key, new_info);
    delta_hash_put(key, new_info);

    if (had_old) {
        retire_record(old_info);
    }

    return true;
}
```

### 7.2 delete

```text
delete(key):
  1. 获取 key-level lock。
  2. append delta journal: tombstone。
  3. delta hash 写 tombstone。
  4. retire old record。
```

### 7.3 同一个 key 并发写

同一个 key 必须串行化。

推荐 striped key lock：

```cpp
Lock locks[65536];

Lock& lock_for(Key128 key) {
    return locks[mix64(key) & 65535];
}
```

RocksDB 的 TransactionDB/OptimisticTransactionDB 也体现了类似思想：写入事务需要处理冲突，悲观事务通过锁隔离，乐观事务在提交时检测冲突。这个项目不需要完整通用事务，但需要 key-level conflict control。

---

## 8. 并发 IO 模型

### 8.1 同一文件支持并发读写吗？

支持，但要使用指定 offset 的 IO。

POSIX 下使用：

```cpp
pread(fd, buf, size, offset);
pwrite(fd, buf, size, offset);
```

`pread/pwrite` 会在指定 offset 读写，并且不改变文件描述符的当前文件偏移，适合多线程并发访问同一文件的不同位置。

Windows 下使用：

```cpp
ReadFile / WriteFile + OVERLAPPED.Offset / OffsetHigh
```

Windows 文档说明，支持 byte offset 的文件可以通过 `OVERLAPPED` 的 `Offset` 和 `OffsetHigh` 指定写入起始偏移。

### 8.2 不要使用共享 file pointer

不要这样：

```cpp
lseek(fd, offset);
write(fd, data, size);
```

多个线程共享 file offset，会互相干扰。

### 8.3 应用层仍需保证一致性

OS 支持同一文件不同 offset 并发 IO，但不会替 DB 保证：

```text
record 是否完整
index 是否已经发布
旧 record 是否仍被 reader 使用
truncate 是否安全
```

这些必须由 DB 层处理。

---

## 9. 并发读写安全

### 9.1 record 不可变

读线程读取的是已提交 record。

写线程写新 record。

两者不写同一个 byte range。

```text
reader -> old offset
writer -> new offset
```

### 9.2 index 是可见性边界

写入顺序：

```text
1. 写 data record。
2. record 完整可校验。
3. 写 delta journal。
4. 发布 delta index。
```

只有 index 指向某个 record 后，reader 才可能读到它。

### 9.3 reader epoch

问题：

```text
reader 已经从 index 读到 old offset
writer/delete/relocate 使 old offset 失效
```

解决：

```text
old offset 不能立即复用
必须等待所有可能持有 old offset 的 reader 退出
```

使用 epoch/RCU：

```cpp
ReadGuard guard = enter_read_epoch();

lookup index;
pread data record;

guard.exit();
```

retire block：

```text
free_pending(epoch)
  -> oldest_reader_epoch > retire_epoch
  -> free_reusable
```

### 9.4 truncate 必须等 epoch 安全

truncate 前必须保证：

```text
1. 尾部区域无 live record。
2. 尾部区域无 pending reader。
3. 尾部区域无 pending writer。
4. allocator checkpoint 已提交。
5. superblock 已安全切换。
```

---

## 10. Delta checkpoint

### 10.1 为什么需要 checkpoint

delta 会随着 runtime/editor 修改不断增长。

当 delta 太大：

```text
lookup 变慢
journal 变大
tombstone 增多
启动恢复变慢
```

需要合并：

```text
base + delta -> new base
```

### 10.2 checkpoint 流程

```text
1. 冻结 active_delta，成为 checkpointing_delta。
2. 创建新的 active_delta，继续接收写入。
3. 后台 merge old base + checkpointing_delta。
4. 生成 new base bucket table + entry array。
5. fsync new base。
6. 原子切换 index superblock。
7. 等旧 reader epoch 结束。
8. 回收 old base 和 checkpointing_delta。
```

### 10.3 checkpoint 期间 lookup

```text
lookup 顺序：
  active_delta
  checkpointing_delta
  old_base 或 new_base
```

checkpoint 完成并切换后：

```text
新 reader 使用 new_base
旧 reader 可以继续使用 old_base
old_base 延迟回收
```

---

## 11. 崩溃恢复

### 11.1 可能崩溃点

```text
data record 写了一半
data record 写完但 index 未更新
delta journal 写了一半
delta journal 写完但 delta hash table 未更新
checkpoint 生成一半
superblock 切换一半
relocation 搬移一半
truncate 前崩溃
```

### 11.2 基本策略

```text
1. record 自描述，带 magic/crc/footer。
2. delta journal 是 index 修改恢复真相。
3. delta hash table 可重建。
4. base index 不原地修改。
5. superblock A/B 双写。
6. checkpoint 生成新区域，完成后原子切换。
7. relocation 通过 CAS index 决定新副本是否可见。
```

### 11.3 启动恢复流程

```text
1. 读取 index superblock A/B，选择有效 epoch。
2. mmap base index。
3. 检查 delta hash clean 标志。
4. 若 dirty，根据 delta journal 重建 delta hash table。
5. 读取 data db superblock A/B。
6. 检查 allocator checkpoint。
7. 必要时扫描 data db record，重建 free list。
8. 校验 index 指向的 record。
9. 孤儿 record 进入 free-pending/free。
```

---

## 12. Editor / Runtime 统一策略

统一的是：

```text
1. 文件格式
2. index 查找逻辑
3. data record 格式
4. delta 修改逻辑
5. checkpoint 机制
6. crash recovery 机制
```

不同的是配置：

```cpp
struct DbConfig {
    bool allow_write;
    bool allow_checkpoint;
    bool allow_relocation;
    bool allow_truncate;

    uint64_t max_delta_size;
    uint64_t max_delta_entries;

    float data_hole_ratio_trigger;
    uint64_t tail_free_trigger;

    Durability durability;
};
```

Editor 默认：

```text
allow_write = true
allow_checkpoint = true
allow_relocation = true
allow_truncate = true
checkpoint aggressive when idle
optimize aggressive when idle
```

Runtime 默认：

```text
allow_write = true 或按平台配置
allow_checkpoint = true 但低频
allow_relocation = false 或低频
allow_truncate = false 或仅退出/关卡切换
```

这仍然是一套 DB，只是 runtime 的后台维护策略更保守。

---

## 13. 数据一致性与持久化等级

提供三种 durability：

```cpp
enum Durability {
    None,
    Async,
    Sync,
};
```

### 13.1 None

```text
最快
崩溃可能丢最近修改
适合临时 cache
```

### 13.2 Async

```text
默认模式
后台 group flush
崩溃可能丢最近几毫秒/几十毫秒
恢复时保持结构一致
```

### 13.3 Sync

```text
put/delete 返回前确保 data + journal 持久化
适合重要存档、patch manifest、资产 registry
```

写入顺序建议：

```text
Sync:
  data pwrite
  data fdatasync
  delta journal append
  index fdatasync
  delta hash update

Async:
  data pwrite
  delta journal append
  delta hash update
  后台 group flush
```

---

## 14. mmap 使用建议

### 14.1 index 可以 mmap

index lookup 适合 mmap：

```text
BaseBucketTable
BaseEntryArray
DeltaHashTable
```

因为它们是结构化数组，查找时访问少量页面。

### 14.2 data db 不建议全部 mmap 写

data db 的 value 可能很大，而且有 append、hole reuse、relocation、truncate。

推荐：

```text
data db:
  pread/pwrite 为主

index db:
  mmap 为主
```

### 14.3 mutable mmap 需谨慎

如果通过 mmap 修改 index，需要注意：

```text
1. 写入顺序
2. cache line tearing
3. atomic/seqlock
4. msync 或平台同步
5. 崩溃恢复
```

Linux `msync` 的作用是把 mmap 后内存中的修改刷新回文件；没有同步调用时，不能简单假设修改已经按预期持久化。

因此 delta journal 比 mmap hash table 更重要：

```text
journal = 恢复真相
hash table = 查询加速
```

---

## 15. 推荐 API

```cpp
class KvDb {
public:
    bool open(const char* path, const DbConfig& config);
    void close();

    bool get(Key128 key, Blob* out);
    bool put(Key128 key, Span value, PutOptions options = {});
    bool remove(Key128 key, DeleteOptions options = {});

    Batch begin_batch();

    Snapshot begin_snapshot();
    void end_snapshot(Snapshot);

    void checkpoint();
    void optimize_data_db(uint32_t data_db_id);
    void verify();
};
```

Batch：

```cpp
class Batch {
public:
    void put(Key128 key, Span value);
    void remove(Key128 key);
    bool commit(Durability durability);
    void rollback();
};
```

---

## 16. 批量事务

editor import 常需要：

```text
一组资产全部成功，或者全部不可见
```

可以支持轻量 batch：

```text
1. data db 写所有 record。
2. delta journal 写 batch begin。
3. delta journal 写多条 put/delete。
4. delta journal 写 batch commit。
5. delta hash table 批量发布。
```

恢复时：

```text
只有看到 batch commit，才重放该 batch。
```

不建议第一版实现完整通用 ACID transaction。当前需求只需要：

```text
单 key 原子
batch 原子发布
snapshot read
```

---

## 17. 关键参数建议

### 17.1 Index

```text
key: uint128
secondary hash: uint64
base bucket count:
  10M entries -> 2^20 或 2^21

BaseEntry:
  48B ~ 64B

Bucket:
  16B

10M entries:
  entries ≈ 480MB ~ 640MB
  bucket table ≈ 16MB ~ 32MB
```

### 17.2 Delta

```text
delta hash load factor: <= 0.7
delta checkpoint trigger:
  editor: 512MB 或 base_count * 10%
  runtime: 64MB~256MB 或退出/关卡切换
```

### 17.3 Data DB

```text
data_db_count:
  16 / 32 / 64 起步，根据资产类型和并发写入调节

small value: < 64KB
medium value: 64KB ~ 4MB
large value: > 4MB

hole ratio trigger:
  free_bytes / file_size > 25% ~ 35%

tail shrink trigger:
  tail_free > 256MB / 512MB / 1GB
```

---

## 18. 与现成数据库方案对比

### 18.1 SQLite / LMDB

适合 metadata、配置、工具侧查询，但不适合作为本方案的核心 data blob store。

主要原因：

```text
1. 通用事务语义较重。
2. 并发写入模型不一定满足同一 DB 多 key 高并发写。
3. 大 blob + 运行时 pack + hole relocation 需求更适合自定义存储。
```

### 18.2 RocksDB

RocksDB 的事务机制成熟，TransactionDB/OptimisticTransactionDB 可以处理并发冲突。

但本项目不直接采用 RocksDB 作为最终格式，原因：

```text
1. runtime 引擎格式需要可控、简单、跨平台。
2. key 是 hash，主要 point lookup，不需要完整 LSM 能力。
3. data blob 需要自定义布局、压缩、relocation、runtime 策略。
4. console/mobile 平台引入 RocksDB 复杂度较高。
```

RocksDB 可作为 V0/V1 editor index 原型，但最终推荐自研格式。

---

## 19. 最终推荐实现路线

### Phase 0：验证原型

```text
data db:
  append write
  record header/footer/crc
  不做 relocation

index:
  mmap base bucket index
  mmap delta hash index
  delta journal

功能:
  get/put/delete
  runtime/editor 统一
```

### Phase 1：可用版本

```text
加入:
  hole allocator
  free-pending epoch
  batch commit
  checkpoint base+delta
  crash recovery
```

### Phase 2：空间优化

```text
加入:
  background relocation
  tail shrink
  allocator checkpoint
  data db optimize
```

### Phase 3：性能优化

```text
加入:
  async IO / io_uring / Windows IOCP
  read cache
  decompressed cache
  asset type aware placement
  load group locality optimize
```

### Phase 4：高级功能

```text
加入:
  multi-generation delta
  partial checkpoint
  online verify
  pack export/import
  patch/mod overlay policy
```

---

## 20. 最终方案一句话

最终方案是：

```text
一个统一 editor/runtime 的 mmap-friendly KV 数据库。

index.db 使用 base bucket index + mutable delta hash index；
data.db 使用 append-first + hole reuse + immutable record；
修改只发布到 delta，后台 checkpoint 合并；
数据搬移通过 CAS index 保证安全；
旧 record 通过 epoch 延迟复用；
runtime 也可以增删改，但默认低频 checkpoint/optimize。
```

最重要的设计底线：

```text
不要原地覆盖 record。
不要原地插入 base index。
不要依赖全量内存 map。
不要频繁 truncate。
不要让 reader 读到未提交 record。
不要让 old offset 在 reader 退出前被复用。
```
