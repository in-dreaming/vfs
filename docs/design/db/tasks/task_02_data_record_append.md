# Task 02：Data DB Append-only Record

## 1. 任务目标

实现 V1 data db：append-only record file。

本任务负责真实写入 `data_NNN.db` 文件，生成可校验 record，并能按 offset 读取和验证 record。

本任务不实现 index、journal、delete、free-list、relocation、truncate。

## 2. 必读上下文

执行前必须阅读：

- `docs/design/db/tasks/setup.md`
- `task_00_platform_io.md`
- `task_01_format_crc_hash.md`
- `docs/design/db_arch.md` 的“Data DB 设计”

## 3. 硬性禁止

- 禁止 mock/moke。
- 禁止 callback。
- 禁止用内存数组假装 data file。
- 禁止原地覆盖已提交 record。
- 禁止 data 文件整体 mmap 写入。
- 禁止依赖共享文件偏移 append。

## 4. 实现范围

实现：

- DataFileHeader。
- DataSuperBlock A/B。
- RecordHeader。
- RecordFooter。
- 创建 data db。
- 打开 data db。
- append record。
- 按 offset 读取 record metadata。
- 按 offset 读取 payload 到 caller-provided buffer。
- record 校验。
- close 时按 durability flush。

## 5. 文件布局

~~~text
data_000.db

+-------------------------------+
| DataFileHeader                |
+-------------------------------+
| DataSuperBlock A              |
+-------------------------------+
| DataSuperBlock B              |
+-------------------------------+
| Reserved checkpoint area      |
+-------------------------------+
| Record Area                   |
+-------------------------------+
~~~

V1 可以保留 checkpoint area，但不写 allocator checkpoint。

## 6. Record 写入协议

append record 时：

~~~text
1. 获取 append lock。
2. offset = current logical_tail。
3. 计算 header。
4. 计算 payload_crc。
5. 计算 record_crc。
6. 使用 pwritevAll 或等价 offset-based 写入 header/payload/footer。
7. logical_tail += aligned_record_size。
8. 更新 DataSuperBlock 的 logical_tail。
9. 根据 durability 执行 flush。
10. 返回 IndexInfo 所需 offset/stored_size/raw_size/crc/codec/version。
~~~

注意：

- V1 中 record 一旦写入，不修改 payload。
- V1 必须每次 append 后写 DataSuperBlock logical_tail，不允许把 superblock 更新推迟到未定义的后台 group。
- record alignment 必须固定，例如 16 或 64。具体值必须写入常量。

Durability 规则：

~~~text
Sync:
  1. pwritevAll record header/payload/footer。
  2. 如果 record 扩展了文件，确保新文件长度 durable。
  3. 写 DataSuperBlock logical_tail。
  4. flush data record 与 DataSuperBlock；如果平台 data-only flush 不保证文件长度，则必须 flush metadata。
  5. append 返回前 record 和 logical_tail 都 durable。

Async:
  1. pwritevAll record。
  2. 写 DataSuperBlock logical_tail。
  3. 可以由后台 group flush。
  4. 崩溃恢复必须能扫描 record area 修复 logical_tail。

None:
  1. 允许丢失最近 record。
  2. 不允许生成恢复后无法处理的结构损坏。
~~~

## 7. 读取协议

读取 record 时：

~~~text
1. pread header。
2. 校验 magic/header_size/stored_size/raw_size。
3. 校验 header_crc。
4. 检查 caller key 是否与 header key 一致。
5. caller 查询 size 时返回 raw_size/stored_size。
6. caller 提供 buffer 时读取 payload。
7. 校验 payload_crc。
8. pread footer。
9. 校验 footer magic 和 record_crc。
~~~

禁止返回内部 mmap 指针。

禁止 callback streaming。

## 8. Public API 建议

~~~zig
pub const DataFile = struct { ... };

pub const AppendOptions = struct {
    durability: Durability,
    codec: u16 = 0,
    flags: u16 = 0,
    version: u64,
    txn_id: u64 = 0,
};

pub const AppendResult = struct {
    offset: u64,
    stored_size: u32,
    raw_size: u32,
    crc: u32,
};

pub fn create(path: []const u8, options: CreateOptions) !DataFile;
pub fn open(path: []const u8, options: OpenOptions) !DataFile;
pub fn close(file: *DataFile) !void;
pub fn append(file: *DataFile, key: Key128, payload: []const u8, options: AppendOptions) !AppendResult;
pub fn readMeta(file: *DataFile, offset: u64) !RecordMeta;
pub fn readPayload(file: *DataFile, offset: u64, key: Key128, dst: []u8) !usize;
pub fn verifyRecord(file: *DataFile, offset: u64) !RecordMeta;
~~~

## 9. 验证流程

必须测试：

1. 创建 data db 后 header/superblock magic 正确。
2. append 一个小 record，按 offset 读回 payload 一致。
3. append 多个 record，offset 单调递增且按 alignment 对齐。
4. 大 payload，例如 8MB，读回一致。
5. caller-provided buffer 太小时必须返回明确错误或 required size，不能越界。
6. 修改 header magic 后 verify 失败。
7. 修改 payload 一个字节后 payload_crc 失败。
8. 删除 footer 或截断 footer 后 verify 失败。
9. 重启打开后 logical_tail 正确。
10. Sync append 扩展文件后，关闭并重新打开，文件长度、record、DataSuperBlock logical_tail 都必须持久化。
11. Async/None 崩溃模拟中 superblock tail 滞后时，open/recovery 能通过扫描 record area 修复或安全忽略未提交 tail。
12. 不使用 callback。
13. 不使用 mock/moke。

## 10. 完成标准

- 真实 data 文件可创建、写入、读取、校验。
- 所有读写通过 platform offset-based IO。
- record 不原地覆盖。
- 没有 free-list、relocation、truncate 的半成品逻辑。
- 测试覆盖损坏和截断。
