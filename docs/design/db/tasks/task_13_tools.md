# Task 13：CLI 工具与测试工具链

## 1. 任务目标

实现 DB 配套命令行工具，支持创建、导入、读取、dump、verify、recover、checkpoint、optimize、benchmark。

工具必须调用真实 DB 实现，禁止 mock/moke。

这些工具属于 DB 库工具链，命名使用 `db_*` 或 `db` 多子命令。未来 VFS 工具必须另行使用 `vfs_*` 或 `vfs` 命名，不能混在本任务中。

## 2. 必读上下文

执行前必须阅读：

- `docs/design/db/tasks/setup.md`
- 所有已完成 task 文档
- `docs/design/roadmap.md` 的“工具链”

## 3. 硬性禁止

- 禁止 mock/moke。
- 禁止 callback。
- 禁止 CLI 绕过 DB 模块直接篡改文件，除非工具名称明确是 corruption test helper。
- 禁止 benchmark 使用内存假数据路径代替真实文件路径。

## 4. 实现范围

实现工具：

~~~text
db_create
db_put
db_get
db_delete
db_dump_manifest
db_dump_index
db_verify
db_recover
db_checkpoint
db_optimize
db_bench
~~~

如果构建系统暂不支持多个 exe，可以先实现一个 `db` 多子命令工具：

~~~text
db create
db put
db get
...
~~~

## 5. 工具语义

### 5.1 create

创建空 DB store。

必须创建：

- manifest.db
- index.db
- 至少一个 data_000.db

### 5.2 put

从文件读取 payload，写入 key。

禁止 callback。

### 5.3 get

读取 key 到输出文件。

必须使用 get_size + get_into 或 reader handle 主动读取，不得使用 callback。

### 5.4 dump_manifest

打印 manifest 中结构化字段。

### 5.5 dump_index

打印 base/delta 统计：

- base entry count
- bucket count
- delta live count
- delta tombstone count
- journal tail

### 5.6 verify

运行 verify，输出 issue 列表。

有 corruption/checksum/dangling index 时 exit code 非 0。

### 5.7 recover

执行 recovery。

必须先输出将要修复的内容摘要，再执行。若需要交互确认，应提供 `--yes`。自动化测试使用 `--yes`。

### 5.8 checkpoint

触发 checkpoint。

### 5.9 optimize

触发 relocation/truncate。若对应功能未实现，必须返回 unsupported，而不是假成功。

### 5.10 bench

真实文件 benchmark：

- sequential put。
- random get。
- overwrite。
- delete。
- checkpoint。

禁止使用内存 mock。

## 6. 验证流程

必须测试：

1. CLI create 后文件存在。
2. CLI put 一个文件。
3. CLI get 输出文件与输入一致。
4. CLI delete 后 get 返回 not_found。
5. CLI verify clean DB exit 0。
6. 人工损坏 payload 后 verify exit 非 0。
7. CLI checkpoint 后 verify 仍通过。
8. dump_manifest 输出 store uuid/version。
9. dump_index 输出 entry count。
10. optimize 在未实现功能时返回 unsupported，不假成功。
11. bench 使用真实临时目录文件。
12. 不使用 callback。
13. 不使用 mock/moke。

## 7. 完成标准

- 工具可用于开发和 CI。
- 所有工具调用真实 DB 实现。
- verify/recover 对后续调试足够明确。
