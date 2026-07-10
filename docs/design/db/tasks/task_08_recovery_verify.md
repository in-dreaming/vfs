# Task 08：Recovery 与 Verify

## 1. 任务目标

实现崩溃恢复与 verify 工具/模块。

恢复负责让 DB 在 dirty shutdown、journal 截断、data orphan 等情况下回到一致状态。

Verify 负责检测格式损坏、引用错误、checksum mismatch。

## 2. 必读上下文

执行前必须阅读：

- `docs/design/db/tasks/setup.md`
- `task_04_index_file_container.md`
- `task_05_delta_journal.md`
- `task_06_delta_index.md`
- `task_07_kv_open_get_put_delete_cabi.md`
- `docs/design/db_arch.md` 的“一致性与恢复”和“重点与难点”

## 3. 硬性禁止

- 禁止 mock/moke。
- 禁止 callback。
- 禁止遇到 corruption 静默忽略。
- 禁止恢复时把无法确定安全性的空间直接加入 free-list。
- 禁止用“重建全部 DB”代替精确恢复，除非 verify 工具显式提供离线 rebuild 模式。

## 4. 实现范围

实现：

- open 时 dirty flag 检查。
- delta journal replay。
- journal tail 修正。
- data record scan。
- orphan record 识别。
- quarantine 记录。
- index -> data 校验。
- verify report。
- recover 命令或 API。

## 5. Recovery 流程

~~~text
1. 读取 manifest。
2. 读取 index superblock A/B，选择有效 epoch。
3. mmap/open base index。
4. 检查 delta clean flag。
5. 如果 delta dirty：
   a. 清空 delta hash table。
   b. 扫描 journal 到 last_good_tail。
   c. replay 完整 record。
   d. 截断 journal tail。
   e. 设置 clean。
6. 读取 data superblock A/B。
7. 如果 data dirty：
   a. 从 index 收集 live offset set。
   b. 扫描 data records。
   c. valid 且 live -> live。
   d. valid 但不 live -> orphan/quarantine。
   e. invalid partial tail -> 忽略或截断到安全 tail。
8. verify live index 指向 record。
~~~

## 6. Verify 检查项

必须检查：

- manifest magic/version/crc。
- index superblock A/B。
- region directory。
- base bucket range。
- base entry sort order。
- delta header。
- delta slot crc。
- journal scan。
- data superblock A/B。
- data record header/footer/payload crc。
- index entry 指向 data record 时 key 必须一致。
- index entry 指向 data record 时 version 必须符合预期。
- tombstone 不应要求 data record。
- duplicate visible key。
- dangling index offset。
- orphan record。

## 7. Verify Report

报告必须结构化，不能只打印字符串。

建议：

~~~zig
pub const VerifyIssueKind = enum {
    corruption,
    checksum_mismatch,
    dangling_index,
    orphan_record,
    duplicate_key,
    invalid_superblock,
    invalid_region,
    invalid_record,
};

pub const VerifyIssue = struct {
    kind: VerifyIssueKind,
    file_id: u32,
    offset: u64,
    key: ?Key128,
    message_code: u32,
};
~~~

CLI 可以把结构化 report 打印为文本。

## 8. 验证流程

必须测试：

1. clean DB verify 通过。
2. journal 最后一条截断，recovery 后只恢复完整 record。
3. data record 完整但 journal 没写，recovery 标为 orphan/quarantine。
4. delta hash table 清空但 journal 完整，recovery 后 lookup 正常。
5. payload 损坏，verify 报 checksum_mismatch。
6. index offset 指向不存在位置，verify 报 dangling_index。
7. base index bucket 损坏，verify 报 invalid_region 或 corruption。
8. superblock A 损坏时选择 B。
9. A/B 都损坏时 open 返回 corruption。
10. verify CLI 返回非 0 exit code，当存在 corruption。
11. 不使用 callback。
12. 不使用 mock/moke。

## 9. 完成标准

- dirty DB 可恢复。
- verify 能明确报告问题。
- 不确定空间进入 quarantine，不直接复用。
- recovery 过程不依赖 mock/moke。
