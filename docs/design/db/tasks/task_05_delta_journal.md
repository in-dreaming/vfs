# Task 05：Delta Journal

## 1. 任务目标

实现 delta journal。journal 是 index 修改的恢复真相。

本任务只实现 journal append、scan、replay record 解码，不实现 delta hash table。

## 2. 必读上下文

执行前必须阅读：

- `docs/design/db/tasks/setup.md`
- `task_00_platform_io.md`
- `task_01_format_crc_hash.md`
- `task_04_index_file_container.md`
- `docs/design/db_arch.md` 的“Delta Journal”

## 3. 硬性禁止

- 禁止 mock/moke。
- 禁止 callback。
- 禁止写伪 journal。
- 禁止用内存 list 代替真实 journal。
- 禁止创建独立 `delta.journal` 文件作为生产格式。
- 禁止 scan 时跳过损坏 record 后继续使用后续 record。遇到不完整或损坏 record 必须停止在最后完整 record。

## 4. 实现范围

实现：

- DeltaJournalRecordHeader。
- DeltaJournalPayload。
- DeltaJournalRecordFooter。
- journal append PUT。
- journal append DELETE。
- batch begin/commit record 的编码，batch 语义可后续任务实现。
- journal scan。
- journal truncate tail 到最后完整 record。
- journal crc 校验。

Journal 必须位于 `index.db` 的 active `DELTA` region 内，具体范围由 `DeltaHeader.journal_offset / journal_size / journal_tail` 描述。所有 journal offset 都是相对于 `DELTA` region 的 offset，不能解释为独立文件 offset。

## 5. Record 格式

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

DELETE record 的 `info` flags 必须标记 tombstone，offset 可以为 0。

## 6. Append 协议

~~~text
1. 持有 journal append lock。
2. offset = delta_region.offset + journal_offset + journal_tail。
3. 编码 header/payload/footer。
4. pwritevAll 到 offset。
5. journal_tail += record_size。
6. 更新 DeltaHeader.journal_tail。
7. durability == sync 时 flush journal 写入范围与 DeltaHeader。
~~~

append 必须是 offset-based。

Sync 前置条件：

- 调用方必须先保证 journal record 引用的 data record 已 durable。
- 如果 data record 所在文件发生扩展，调用方必须先保证新文件长度 durable。
- 本任务不允许在 data durable 之前写入可恢复的 committed journal record。

## 7. Scan 协议

~~~text
1. 从 delta_region.offset + journal_offset 开始。
2. 读取 header。
3. 校验 magic/version/record_size/header_crc。
4. 读取 payload/footer。
5. 校验 footer magic 和 record_crc。
6. 产出 decoded record。
7. 遇到 EOF 或半条 record，停止。
8. 遇到 crc 错误，停止并返回 corruption 与 last_good_tail。
~~~

本任务禁止 callback，因此 scan 不能使用 visitor callback。

推荐 API：

~~~zig
pub const JournalScanner = struct {
    pub fn next(self: *JournalScanner) !?JournalRecord;
    pub fn lastGoodTail(self: *JournalScanner) u64;
};
~~~

caller 主动 `next()`，不是 callback。

## 8. 验证流程

必须测试：

1. append PUT 后 scan 得到同一 key/info。
2. append DELETE 后 scan 得到 tombstone。
3. append 多条 record 后顺序一致。
4. sync durability 调用 flush。
5. 截断最后一条 footer 后 scan 停止在上一条完整 record。
6. 修改 header_crc 后 scan 报 corruption。
7. 修改 record_crc 后 scan 报 corruption。
8. 将 DeltaHeader.journal_tail 回退到 last_good_tail 后再次 scan 正常。
9. scanner 使用 pull 模式 `next()`，没有 callback。
10. 不创建独立 delta journal 文件。
11. 构造 data 未 durable 的场景时，journal append API 必须允许调用方在写 journal 前失败/中止，不能先写 committed journal。
12. 不使用 mock/moke。

## 9. 完成标准

- journal 是 `index.db` 内 DeltaJournalArea 的真实 offset-based append。
- scan 能可靠识别最后完整 record。
- 后续 delta recovery 可以直接使用 scanner replay。
