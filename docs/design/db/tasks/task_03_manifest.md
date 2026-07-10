# Task 03：Manifest DB

## 1. 任务目标

实现 store 级 manifest 文件，用于描述一个 DB store 的基本元信息、index 文件、data 文件列表、feature flags 与 schema version。

manifest 不进入高频 lookup 路径，但它是 `db_open` 的入口。

## 2. 必读上下文

执行前必须阅读：

- `docs/design/db/tasks/setup.md`
- `task_00_platform_io.md`
- `task_01_format_crc_hash.md`
- `docs/design/db_arch.md` 的“文件组成”

## 3. 硬性禁止

- 禁止 mock/moke。
- 禁止 callback。
- 禁止使用 JSON 作为生产 manifest 格式。
- 禁止依赖目录扫描猜测 data 文件列表。

## 4. 实现范围

实现：

- manifest file header。
- manifest superblock A/B。
- data db file table。
- index db path/uuid。
- store uuid。
- format version。
- feature flags。
- schema version。
- create/load/update。

## 5. 文件格式要求

manifest 应为二进制格式。

V1 可以采用固定容量 data file table，例如最多 4096 个 data db。

建议结构：

~~~zig
pub const ManifestHeader = extern struct {
    magic: u32,
    major_version: u16,
    minor_version: u16,
    endian: u32,
    header_size: u64,
    superblock_a_offset: u64,
    superblock_b_offset: u64,
    table_offset: u64,
    table_capacity: u32,
    reserved: u32,
    uuid: [16]u8,
    crc: u32,
};

pub const ManifestSuperBlock = extern struct {
    magic: u32,
    version: u32,
    epoch: u64,
    index_file_id: u32,
    data_file_count: u32,
    feature_flags: u64,
    schema_version: u64,
    clean_shutdown: u32,
    flags: u32,
    crc: u32,
};
~~~

如果路径字符串区暂缓实现，V1 可规定固定相对路径：

- `index.db`
- `data_000.db`
- `data_001.db`

但 manifest 中仍必须显式记录 data file count 和 file id。

## 6. 更新协议

manifest 更新必须使用双 superblock：

~~~text
1. 写 file table 或相关元信息。
2. flush data。
3. 写另一个 superblock，epoch + 1。
4. flush metadata。
~~~

启动选择 epoch 最大且 crc 正确的 superblock。

## 7. 验证流程

必须测试：

1. create manifest。
2. open manifest。
3. store uuid 持久化一致。
4. index 文件名/id 可读。
5. data file count 可读。
6. 增加 data file entry 后重启仍存在。
7. 损坏 superblock A 时选择 B。
8. 损坏 epoch 更大的 superblock crc 时选择旧的有效 superblock。
9. 截断 manifest 时 open 返回 corruption。
10. 不使用 JSON。
11. 不使用 callback。
12. 不使用 mock/moke。

## 8. 完成标准

- `db_open` 后续可以依赖 manifest 找到 index/data 文件。
- manifest 更新具有双 superblock 崩溃保护。
- 没有目录扫描猜测逻辑。
