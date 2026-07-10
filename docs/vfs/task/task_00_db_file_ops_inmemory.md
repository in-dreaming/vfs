# Task 00：DB custom file_ops 与 InMemoryFileOps

## 1. 任务目标

实现 DB 层 db_context_t.file_ops 的真实支持，并提供 VFS 后续可使用的 InMemoryFileOps 能力。

这是 InMemory merge/staging 与 custom backend 验证的前置任务，不是 VFS Task 01-06 只读最小闭环的前置任务。当前 README 明确说明 db_context_t.file_ops 已在 ABI 声明，但完整 custom file backend 尚未实现；传入非空 file_ops 会返回 DB_UNSUPPORTED。VFS 后续 build/merge/staging 如果选择 InMemoryFileOps 路径，必须先补齐这个 DB 特性。

本任务修改 DB 层，但不得引入任何 VFS 语义。

---

## 2. 必读上下文

执行前必须阅读：

- docs/vfs/task/setup.md
- README.md
- include/db.h
- src/db/platform/file.zig
- src/db/kv_db.zig
- docs/design/db/tasks/setup.md

---

## 3. 硬性禁止

- 禁止 mock/moke。
- 禁止在 DB 层出现 vfs_* ABI 或 VFS 概念。
- 禁止用内存 map 假装 DB；DB 必须继续走真实 index/data/journal 逻辑。
- 禁止跳过 flush、truncate、mmap、file size 语义。
- 禁止 callback 风格新增 public API；本任务只实现已有 file_ops 后端接口。
- 禁止破坏默认 platform file IO 路径。

说明：db_file_ops_t 本身是 DB ABI 已存在的函数指针后端接口，不属于“新增 public callback API”。本任务不得再新增其他 callback 型 API。

---

## 4. 实现范围

本任务容易膨胀，必须按以下边界执行：

- 必须让 DB 默认 platform backend 的行为完全保持。
- 必须让 custom backend 覆盖 DB 正常 open/create/get/put/delete/commit/verify 的真实路径。
- 必须实现一个真实 InMemoryFileOps backend，不能用测试 map 绕过 DB。
- recover/optimize/checkpoint 如因当前 DB 内部路径尚未全部抽象而无法完整支持，必须返回明确 DB_UNSUPPORTED 或在结果中说明剩余 DB 抽象缺口；不得假成功。
- 不要求在本任务中改变 DB key 模型。VFS 的 u64 object key 由 VFS 编码为 8-byte raw key bytes 传入 DB。

### 4.1 完善 db_file_ops_t

当前 include/db.h 中 db_file_ops_t 字段是 void*。需要在 Zig 内部为这些字段定义明确调用签名，并在打开 DB 时验证：

- struct_size
- version
- 必需函数是否存在
- unsupported optional 函数的 fallback 策略

建议函数语义：

~~~c
open(user, path, flags, out_file)
close(file)
read_at(file, offset, dst, size, out_read)
write_at(file, offset, src, size, out_written)
get_size(file, out_size)
set_size(file, size)
sync(file, mode)
preallocate(file, offset, size)
mmap(file, offset, size, flags, out_mapping)
msync(mapping, offset, size, mode)
munmap(mapping)
~~~

因为 include/db.h 当前把函数指针字段声明为 void*，本任务必须在 DB Zig 侧集中定义 cast 后的精确 ABI 签名，并补 C header 注释或 typedef，避免调用方按错误签名传入函数。若需要调整 public header，必须保持 struct_size/version 兼容策略。

如果现有 ABI 不能表达所有参数，必须在 task 结果中说明 ABI 差距，并采用兼容扩展方案。不能静默假装支持。

### 4.2 PlatformFile 抽象接入 custom backend

DB 所有文件访问必须通过统一 file abstraction：

~~~text
default backend:
  src/db/platform/file.zig 真实 OS file IO

custom backend:
  db_context_t.file_ops
~~~

以下路径必须可使用 custom backend：

- manifest/index/data 文件 open/create。
- pread/pwrite。
- get_size/set_size。
- flush/sync。
- mmap/munmap/msync，如果 index 路径需要 mmap。

如果 custom backend 不支持 mmap，则 DB open 应返回 DB_UNSUPPORTED，除非同时实现了非 mmap index fallback。不能 silently degrade 成错误数据结构。

实现时禁止把 default backend 与 custom backend 写成两套 DB 逻辑；只能在 platform file abstraction 层分发，DB 上层 manifest/index/data 逻辑仍走同一套代码。

### 4.3 InMemoryFileOps 实现

实现一个测试和 VFS 可复用的 in-memory backend。

建议位置：

~~~text
src/db/platform/inmemory_file_ops.zig
~~~

行为：

~~~text
open:
  从 real disk mirror 读取文件到 memory buffer，或创建空文件。

read_at:
  从 memory buffer 按 offset copy。

write_at:
  自动扩容 memory buffer，copy 数据，dirty = true。

get_size:
  返回 logical_size。

set_size:
  resize logical buffer，dirty = true。

sync:
  如果配置为 writeback，则写临时文件、flush、rename 替换。
  如果配置为 pure memory test mode，则只标记 synced epoch，但必须只用于测试。

mmap:
  返回稳定 buffer range。
  mmap 后 write/resize 必须保证已有 mapping 不悬空，或明确禁止 resize while mapped 并返回 DB_BUSY。

munmap:
  释放 mapping bookkeeping，不释放底层文件内容。
~~~

VFS 使用目标是 small/medium pack merge：

~~~text
Load DB files into memory
DB operations use normal code path
Flush full output atomically
~~~

### 4.4 C ABI 行为

传入 non-null db_context_t.file_ops 不应再直接返回 DB_UNSUPPORTED。

必须：

- 验证 struct size/version。
- 对缺少必需函数返回 DB_INVALID_ARGUMENT。
- 对 DB 当前必须但 backend 不支持的能力返回 DB_UNSUPPORTED。
- 成功时所有 DB get/put/delete/batch/checkpoint/verify 路径走 custom backend。

如果 recover/optimize 因实现范围暂未完整接入 custom backend，必须有测试覆盖其明确错误返回。不能保留“传入 file_ops 但部分路径偷偷使用默认 OS 文件”的混合行为。

---

## 5. 验证要求

必须测试：

1. 默认 platform backend 的现有 DB 测试全部通过。
2. 使用 InMemoryFileOps 创建 DB、put、get、delete、commit。
3. 使用 InMemoryFileOps 关闭后 flush 到磁盘，再用默认 backend 打开并读回数据。
4. 使用默认 backend 创建 DB，再用 InMemoryFileOps 打开、修改、flush，最后默认 backend 读回修改。
5. custom backend 缺少必需函数时返回明确错误。
6. custom backend 不支持 mmap 且 DB 需要 mmap 时返回 DB_UNSUPPORTED。
7. mmap mapping 内容与 read_at 内容一致。
8. set_size/truncate 后 verify 行为正确。
9. sync 路径不是 no-op，writeback 模式必须真实落盘。
10. 不影响 db_get_info。
11. checkpoint/optimize/recover 要么真实支持 custom backend，要么返回明确 DB_UNSUPPORTED 并有测试说明。

验证命令：

~~~powershell
zig build
zig build test
zig build -Doptimize=ReleaseSafe
zig build test -Doptimize=ReleaseSafe
~~~

---

## 6. 完成标准

- db_context_t.file_ops 有真实实现。
- InMemoryFileOps 可用于真实 DB 正常读写路径。
- 默认 DB IO 路径不退化。
- 没有 VFS 语义进入 DB。
- 不改变 DB key 模型；VFS u64 object key 仍由 VFS 编码为 raw key bytes。
- README 中关于 file_ops unsupported 的限制应在后续文档更新任务中修改。
