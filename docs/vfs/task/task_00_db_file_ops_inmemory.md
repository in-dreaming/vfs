# Task 00：DB custom file_ops 与 InMemoryFileOps

## 1. 任务目标

实现 DB 层 db_context_t.file_ops 的真实支持，并提供 VFS 后续可使用的 InMemoryFileOps 能力。

这是 VFS 的前置任务。当前 README 明确说明 db_context_t.file_ops 已在 ABI 声明，但完整 custom file backend 尚未实现；传入非空 file_ops 会返回 DB_UNSUPPORTED。VFS build/merge 后续需要 InMemoryFileOps，因此必须先补齐这个 DB 特性。

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
read_at(file, dst, size, offset)
write_at(file, src, size, offset)
get_size(file, out_size)
set_size(file, size)
sync(file, mode)
preallocate(file, size)
mmap(file, offset, size, flags, out_mapping)
msync(mapping, offset, size, mode)
munmap(mapping)
~~~

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
10. 不影响 db_get_info、checkpoint、optimize、recover。

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
- InMemoryFileOps 可用于真实 DB 全路径。
- 默认 DB IO 路径不退化。
- 没有 VFS 语义进入 DB。
- README 中关于 file_ops unsupported 的限制应在后续文档更新任务中修改。

