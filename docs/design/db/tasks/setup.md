# DB 任务公共上下文

本文是所有 DB 实现任务的公共上下文。任何 agent 在执行 `docs/design/db/tasks/` 下的任务前，必须先阅读本文，再阅读对应 task 文件。只阅读 `setup.md` 与具体 task 文件，应足以准确完成该任务。

## 1. 项目目标

本项目要实现一个面向游戏引擎 editor/runtime 的资产 KV 数据库。

它不是通用数据库，而是一个可嵌入、可校验、可恢复、跨平台的资产存储格式。

核心目标：

- 存储 import/cook 后的引擎内部资产数据。
- 支持千万级 key。
- value 覆盖小 metadata 到大 blob，例如 texture、mesh、audio、shader cache。
- editor 与 runtime 使用同一套文件格式。
- runtime 可按配置支持新增、删除、修改、patch、mod、cache、热更新、本地生成内容。
- 查询路径不能全量构建 `map<key, info>` 或 `unordered_map<key, info>`。
- 索引主要使用 mmap-friendly 的文件内数组结构。
- 数据 blob 使用 offset-based file IO，不整体 mmap。
- 实现语言使用 Zig。
- 对外提供稳定 C ABI，所有 DB 层导出符号统一使用 `db_*` 前缀。

## 1.1 DB 库与未来 VFS 库边界

DB 和 VFS 必须是两个独立库。

推荐库边界：

~~~text
libdb:
  source root: src/db/
  C ABI prefix: db_*
  responsibility: asset KV database

libvfs:
  source root: src/vfs/
  C ABI prefix: vfs_*
  responsibility: virtual file system / mount / path / overlay
~~~

当前任务只实现 `libdb`。实现代码必须放在 DB 空间下。推荐源码根为 `src/db/`，内部再拆分 `data/`、`index/`、`platform/`、`concurrency` 等子模块。

未来会有独立 `libvfs`。`libvfs` 可以链接并调用 `libdb`，但 `libdb` 不能链接、import、include 或反向依赖 `libvfs`。

边界规则：

- DB 库只负责资产 KV store、文件格式、索引、journal、recovery、checkpoint、allocator。
- VFS 库负责虚拟路径、mount、overlay、目录语义、权限策略、路径解析等更高层能力。
- DB 库 public C ABI 只使用 `db_*` 前缀。
- VFS 库 public C ABI 只使用 `vfs_*` 前缀。
- `db_*` 和 `vfs_*` 是两个独立 ABI 命名空间，不能混用。
- 禁止在 DB 库导出 `vfs_*` 或 `vfs_db_*` 符号。
- 禁止在 VFS 库导出 `db_*` 符号；VFS 如需暴露能力，应包装成 `vfs_*`。
- 禁止 DB 库 include/import 未来 VFS 库模块。
- 禁止把 VFS 的路径、mount、overlay 概念写入 DB 文件格式。
- 如需为 VFS 预留能力，应通过 DB 层通用 API 暴露，例如 key/value、batch、snapshot、verify，而不是写入 VFS 语义。

完整设计参考：

- `docs/design/db_arch.md`
- `docs/design/roadmap.md`
- `docs/design/db.md`
- `docs/design/db2.md`

这些设计文档是背景资料；具体实现必须以当前 task 文件和本文为准。

## 2. 全局硬性约束

所有任务必须遵守以下约束。

### 2.1 禁止 mock / moke

禁止为了通过测试而写 mock/moke 实现。

这里的 mock/moke 包括但不限于：

- 用内存 map 假装文件数据库。
- 用临时数组假装 mmap index。
- 用固定返回值假装 IO 成功。
- 用伪 crc、伪 hash、伪 flush。
- 在实现代码里根据测试文件名、测试 key、测试环境特殊处理。
- 声称“后续替换为真实实现”，但当前任务交付物中核心路径不是可运行真实实现。

允许写测试 helper，但测试 helper 不能进入生产路径，不能替代真实实现。

### 2.2 禁止 callback

禁止在当前任务实现中引入 callback 风格 API。

这里的 callback 包括：

- 函数指针回调。
- Zig `fn` 回调参数。
- 用户传入 closure/context 后由 DB 反向调用。
- streaming read callback。
- async completion callback。

如果需要读取大 value，应使用以下方案之一：

- caller 提供 buffer，DB 填充。
- 两阶段 API：先查询 size，再由 caller 分配 buffer 后读取。
- 显式 reader handle API，由 caller 主动 `read_next`。

禁止新增 callback API。

### 2.3 跨平台

目标平台：

- Windows
- Linux
- macOS
- 后续 console/mobile 平台

任何平台相关逻辑必须隔离在 platform 层。核心 DB 逻辑不能散落系统调用。

路径、文件句柄、mmap、flush、truncate、preallocate、advice 都必须经 platform 抽象。

### 2.4 IO 可控

高频路径禁止使用隐式文件偏移。

必须使用 offset-based IO：

- POSIX：`pread` / `pwrite` 或等价封装。
- Windows：`ReadFile` / `WriteFile` + explicit offset / OVERLAPPED 或等价封装。

禁止在并发读写路径使用共享文件偏移的 read/write。

所有 flush 必须显式由 durability 策略控制。

禁止依赖 `close()` 隐式 flush 作为一致性保证。

### 2.5 文件格式

磁盘格式要求：

- 固定宽度整数。
- little-endian。
- 文件内 offset 使用 `u64`。
- 不写入进程指针。
- 不写入 slice。
- enum 必须明确 backing integer。
- 保留字段写 0。
- 结构体 size/alignment 必须有 comptime assert 或单元测试。
- 跨平台读写必须通过 encode/decode 或经过严格验证的 extern struct。

### 2.6 可恢复性

所有写入路径必须考虑进程崩溃、断电、文件截断、部分写。

默认原则：

- data record 不原地覆盖。
- base index 不原地插入、删除、修改。
- journal 是恢复真相。
- mmap hash table 是查询加速。
- index 决定 record 可见性。
- old offset 不能在 reader 安全退出前复用。

### 2.7 不扩大任务边界

每个 task 文件定义了该任务的范围。

执行时：

- 不实现未要求的高级功能。
- 不改动无关模块。
- 不修改公共格式，除非 task 明确要求。
- 如果发现 task 与已存在实现冲突，先记录问题，不要静默换设计。

## 3. 目标文件布局

建议代码布局：

~~~text
src/
  db/
    key.zig
    status.zig
    options.zig
    kv_db.zig
    batch.zig
    snapshot.zig
    c_api.zig
    data/
      data_file.zig
      record.zig
      allocator.zig
      allocator_checkpoint.zig
      relocation.zig
    index/
      index_file.zig
      superblock.zig
      region_directory.zig
      base_index.zig
      delta_index.zig
      delta_journal.zig
      checkpoint.zig
    platform/
      file.zig
      mmap.zig
      flush.zig
      path.zig
      advice.zig
    concurrency/
      striped_lock.zig
      epoch.zig
tools/
tests/
~~~

如果现有仓库结构不同，可以适配，但必须保持模块职责清晰。

未来 VFS 库应使用单独目录，例如：

~~~text
src/
  vfs/
    ...
~~~

当前 DB 任务不得创建或依赖 `src/vfs/`。

## 4. 核心数据结构

### 4.1 Key128

内部 key 固定为 128-bit。

~~~zig
pub const Key128 = extern struct {
    hi: u64,
    lo: u64,
};
~~~

即使外部传入 64-bit key，也必须扩展为 128-bit。

### 4.2 IndexInfo

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

`IndexInfo` 指向 data db 内的 record。

### 4.3 Durability

~~~zig
pub const Durability = enum(c_int) {
    none = 0,
    async = 1,
    sync = 2,
};
~~~

语义：

- `none`：最快，允许丢最近修改，但不能产生不可恢复结构损坏。
- `async`：默认，后台 group flush。
- `sync`：返回前 data、必要文件长度 metadata、journal、可见性元数据达到平台持久化要求。

Sync 的全局规则：

- 如果写入扩展了文件，必须保证新文件长度也 durable。
- `flushData` 只有在平台能保证“数据 + 已扩展文件长度”时才足够；否则必须使用 `flushMetadata` 或更强 flush。
- journal commit 不能先于其引用的 data record durable。
- clean flag 不能先于 journal/hash/header durable。
- V1 允许 `async/none` 丢失最近修改，但恢复后结构必须一致。

## 5. 任务依赖关系

推荐执行顺序：

~~~text
task_00_platform_io.md
task_01_format_crc_hash.md
task_02_data_record_append.md
task_03_manifest.md
task_04_index_file_container.md
task_04_base_index.md
task_05_delta_journal.md
task_06_delta_index.md
task_07_kv_open_get_put_delete_cabi.md
task_08_recovery_verify.md
task_09_checkpoint.md
task_10_batch_snapshot.md
task_11_allocator_epoch.md
task_12_relocation_truncate.md
task_13_tools.md
~~~

后续任务可以读取前序任务产物，但不能用 mock/moke 替代前序任务。

如果前序任务未完成，应停止并报告缺失依赖。

## 6. 通用验证要求

每个任务至少需要：

- 单元测试。
- 文件级集成测试。
- 错误路径测试。
- 跨平台条件编译检查。
- 不使用 mock/moke 的说明。
- 不使用 callback 的说明。

如果任务涉及磁盘格式，还必须提供：

- magic/version 检查。
- crc/checksum 检查。
- 截断文件测试。
- 损坏字段测试。

如果任务涉及 C ABI，还必须提供：

- C header 或等价导出声明。
- ABI struct size/version。
- 调用成功路径测试。
- 调用错误路径测试。
- 内存释放规则测试。

## 7. 完成定义

一个 task 完成必须满足：

- 生产代码是真实实现，不是 mock/moke。
- 没有 callback API。
- 所有 task 明确要求的 public API 已实现。
- 验证流程中的命令或测试全部通过。
- 文档中列出的边界行为都有测试覆盖。
- 未实现项明确不在本 task 范围内。
- 不破坏已有测试。
