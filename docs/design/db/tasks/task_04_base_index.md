# Task 04：Base Index

## 1. 任务目标

实现 mmap-friendly 的只读 base bucket index。

Base index 是大规模稳定索引，负责从 key 查找 `IndexInfo`。它不支持原地插入、删除、修改。所有变更由 delta index 覆盖。

## 2. 必读上下文

执行前必须阅读：

- `docs/design/db/tasks/setup.md`
- `task_00_platform_io.md`
- `task_01_format_crc_hash.md`
- `task_04_index_file_container.md`
- `docs/design/db_arch.md` 的“Index DB 设计”

## 3. 硬性禁止

- 禁止 mock/moke。
- 禁止 callback。
- 禁止构建生产路径 `HashMap<Key128, IndexInfo>` 代替 base index。
- 禁止 base index 原地插入/删除。
- 禁止通过测试数据特殊分支通过测试。

## 4. 实现范围

实现：

- BaseIndexHeader。
- BaseBucket。
- BaseEntry。
- base index builder。
- base mmap/open。
- base lookup。
- base verify。

本任务不实现 delta、journal、checkpoint。

## 5. 文件布局

Base index region 内部：

~~~text
BaseIndexHeader
BucketTable[1 << bucket_bits]
EntryArray[entry_count]
~~~

`BaseEntry` 必须固定大小，建议 64B。

## 6. Builder 输入

Builder 输入是一组 entries：

~~~zig
pub const BuildEntry = struct {
    key: Key128,
    info: IndexInfo,
};
~~~

Builder 输出必须写入 `index.db` 的 `BASE_INDEX` region。测试可以使用临时 index.db，但生产格式禁止独立 base index 文件。

Builder 可以使用临时内存排序，这是离线构建/后台 checkpoint 路径，不是 runtime lookup 路径。

## 7. 排序规则

entry 必须按以下顺序排序：

~~~text
bucket_id = high_bits(mixHash128To64(key), bucket_bits)
h
key_hi
key_lo
~~~

Bucket 记录该 bucket 在 EntryArray 中的 `[begin, begin + count)`。

## 8. Lookup 规则

~~~text
1. h = mixHash128To64(key)。
2. bucket_id = high_bits(h, bucket_bits)。
3. 读取 bucket。
4. 若 count == 0，返回 not_found。
5. count <= 16，线性扫描。
6. count > 16，按 h 二分找到 equal range，再 full key 校验。
7. key 完全一致时返回 IndexInfo。
~~~

只比较 h 不够，必须比较 full key。

## 9. Verify 规则

verify 必须检查：

- header magic/version。
- bucket_count 是否等于 `1 << bucket_bits`。
- bucket range 不越界。
- bucket begin/count 单调且覆盖合法。
- entries 在 bucket 内排序正确。
- header/bucket/entry crc 正确。
- duplicate key 行为明确。V1 推荐 builder 拒绝重复 key。

## 10. 验证流程

必须测试：

1. 构建空 base index。
2. 构建 1 个 entry，lookup 成功。
3. 构建 1000 个 entry，全部 lookup 成功。
4. lookup 不存在 key 返回 not_found。
5. 构造 hash bucket 碰撞，full key 校验正确。
6. duplicate key build 返回错误。
7. 损坏 bucket count 后 verify 失败。
8. 损坏 entry key 顺序后 verify 失败。
9. mmap readonly lookup 成功。
10. 不使用生产 HashMap 代替 lookup。
11. 不使用 callback。
12. 不使用 mock/moke。

## 11. 完成标准

- base index 可从真实文件 mmap 查询。
- builder 生成的文件跨平台 deterministic。
- lookup 不需要全量加载 map。
- verify 能发现结构损坏。
