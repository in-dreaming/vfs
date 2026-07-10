# Task 00：Platform IO 层

## 1. 任务目标

实现 DB 的跨平台底层 IO 抽象。后续所有文件读写、flush、truncate、preallocate、mmap 都必须通过该层，不允许核心 DB 模块直接调用系统 API。

本任务只做 platform IO，不实现 DB 文件格式。

## 2. 必读上下文

执行前必须阅读：

- `docs/design/db/tasks/setup.md`
- `docs/design/db_arch.md` 的“底层 IO 与 cache 副作用控制”和“Cross-platform Platform Layer”

## 3. 硬性禁止

- 禁止 mock/moke。
- 禁止 callback。
- 禁止在生产路径使用内存数组假装文件。
- 禁止使用共享文件偏移的 read/write 作为并发路径。
- 禁止核心 DB 模块绕过 platform 层直接调用系统 IO。

## 4. 实现范围

实现以下能力：

- 打开文件。
- 关闭文件。
- offset-based read。
- offset-based write。
- vectored write；如果平台不支持，可在 platform 层内部顺序写，但调用语义必须保持 offset-based。
- 获取文件长度。
- 设置文件长度。
- 预分配文件空间。
- flush data。
- flush metadata。
- mmap readonly。
- mmap readwrite。
- msync/flush mapped range。
- munmap。
- 文件访问 advice/hint。

## 5. 建议 API

~~~zig
pub const FileHandle = struct {
    native: NativeHandle,
};

pub const OpenMode = enum {
    read_only,
    read_write,
    create_read_write,
};

pub const OpenOptions = struct {
    mode: OpenMode,
    random_access_hint: bool = true,
    sequential_hint: bool = false,
    direct_io: bool = false,
    create_parent_dirs: bool = false,
};

pub const IoVec = struct {
    data: []const u8,
};

pub const Advice = enum {
    normal,
    random,
    sequential,
    will_need,
    dont_need,
};

pub fn open(path: []const u8, options: OpenOptions) !FileHandle;
pub fn close(file: *FileHandle) void;

pub fn pread(file: FileHandle, offset: u64, dst: []u8) !usize;
pub fn pwrite(file: FileHandle, offset: u64, src: []const u8) !usize;
pub fn pwriteAll(file: FileHandle, offset: u64, src: []const u8) !void;
pub fn pwritevAll(file: FileHandle, offset: u64, vecs: []const IoVec) !void;

pub fn len(file: FileHandle) !u64;
pub fn setLen(file: FileHandle, new_len: u64) !void;
pub fn preallocate(file: FileHandle, offset: u64, size: u64) !void;
pub fn flushData(file: FileHandle) !void;
pub fn flushMetadata(file: FileHandle) !void;
pub fn advise(file: FileHandle, offset: u64, size: u64, advice: Advice) void;

pub const MappedRegion = struct {
    ptr: [*]u8,
    len: usize,
};

pub fn mmapReadonly(file: FileHandle, offset: u64, size: u64) !MappedRegion;
pub fn mmapReadWrite(file: FileHandle, offset: u64, size: u64) !MappedRegion;
pub fn msync(region: MappedRegion) !void;
pub fn munmap(region: MappedRegion) void;
~~~

实际命名可以调整，但语义不能减少。

## 6. 平台语义要求

### 6.1 Windows

要求：

- 使用 explicit offset。
- 路径处理支持 UTF-8 输入到 Windows native path。
- `flushData`/`flushMetadata` 必须映射到明确 flush 行为。
- 如果 write/setLen 扩展了文件，`flushData` 必须明确是否保证新文件长度 durable；若不能保证，DB Sync 路径必须调用 `flushMetadata`。
- mmap 使用 Windows file mapping。
- truncate 使用明确文件长度设置。

### 6.2 POSIX/Linux/macOS

要求：

- 使用 `pread`/`pwrite` 或等价 Zig 封装。
- `flushData` 优先 data-only flush，无法支持时使用更强 flush。
- `flushMetadata` 使用包含 metadata 的 flush。
- 如果 pwrite 扩展了文件，platform 层必须提供一种使新文件长度 durable 的路径；可以是 `flushMetadata`，也可以是文档明确证明等价的更强 flush。
- mmap 使用 POSIX mmap。
- advice 使用可用平台 hint，不支持时 no-op。

## 7. 错误处理

platform 层返回 Zig error。

必须区分至少以下错误类别：

- not_found
- permission_denied
- invalid_argument
- io_error
- no_space
- busy

如果底层错误无法精确映射，可以映射为 io_error，但不能吞掉错误。

## 8. 验证流程

必须增加测试：

1. 创建临时文件。
2. 在 offset 0 写入 `abc`。
3. 在 offset 4096 写入 `xyz`。
4. 读取 offset 0，结果必须是 `abc`。
5. 读取 offset 4096，结果必须是 `xyz`。
6. 检查文件长度至少为 4099。
7. `pwritevAll` 写入 header/payload/footer 三段，读取后必须连续一致。
8. `setLen` 截断后，读取截断后范围必须失败或返回 0，不能返回旧数据。
9. mmap readonly 后读取内容一致。
10. mmap readwrite 修改内容，msync 后重新 pread 必须读到新内容。
11. advice 调用不应失败影响主流程。
12. 写入超过原文件长度后执行 Sync 所需 flush，关闭并重新打开后，新长度与新数据必须仍然存在。

## 9. 完成标准

- 所有测试通过。
- 没有 callback。
- 没有 mock/moke。
- 生产路径不使用共享文件偏移。
- platform API 被单独模块化。
- 其他 DB 模块可以只依赖该 platform API 完成文件读写。
