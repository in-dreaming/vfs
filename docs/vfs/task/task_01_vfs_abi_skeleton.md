# Task 01：VFS ABI 与工程骨架

## 1. 任务目标

创建独立 libvfs 工程骨架、include/vfs.h、handle registry、错误码和基础 C ABI。

本任务只建立真实库边界和可调用 ABI，不实现 pack format、page 读取、overlay 或 writable pack。

---

## 2. 必读上下文

执行前必须阅读：

- docs/vfs/task/setup.md
- docs/vfs/vfs_arch.md
- include/db.h
- build.zig
- src/db/root.zig
- src/db/kv_db.zig 中 handle registry 与 status 处理方式

---

## 3. 硬性禁止

- 禁止 mock/moke。
- 禁止把 VFS API 加进 include/db.h。
- 禁止在 DB 库导出 vfs_*。
- 禁止 VFS 导出 db_*。
- 禁止 callback public API。
- 禁止用固定成功返回伪造 open/read。

---

## 4. 实现范围

新增建议文件：

~~~text
src/vfs/root.zig
src/vfs/abi.zig
src/vfs/error.zig
src/vfs/handle_registry.zig
src/vfs/volume/volume.zig
src/vfs/io/file_handle.zig
include/vfs.h
tools/vfs.zig
~~~

修改 build.zig：

- 新增 vfs static library。
- 新增 vfs_shared shared library。
- install include/vfs.h。
- 新增 vfs CLI。
- 保留现有 DB build/test 行为。

### 4.1 ABI

实现：

~~~c
typedef uint64_t vfs_volume_t;
typedef uint64_t vfs_file_t;
typedef uint64_t vfs_file_entry_t;

int vfs_open_volume(const char* path, const vfs_open_options_t* options, vfs_volume_t* out_volume);
int vfs_close_volume(vfs_volume_t volume);
int vfs_mount_pack(vfs_volume_t volume, const char* pack_path, uint32_t priority, uint32_t flags);
int vfs_open_path(vfs_volume_t volume, const char* path, uint32_t flags, vfs_file_t* out_file);
int vfs_open_entry(vfs_volume_t volume, uint64_t file_entry, uint32_t flags, vfs_file_t* out_file);
int vfs_stat_path(vfs_volume_t volume, const char* path, vfs_stat_t* out_stat);
int vfs_stat_entry(vfs_volume_t volume, uint64_t file_entry, vfs_stat_t* out_stat);
int vfs_read_at(vfs_file_t file, uint64_t offset, void* dst, uint64_t size, uint64_t* out_read);
int vfs_close_file(vfs_file_t file);
int vfs_last_status(void);
const char* vfs_last_error_message(void);
~~~

### 4.2 当前行为

因为 pack format 未实现，本任务中：

- vfs_open_volume 可以创建真实 Volume 对象并保存 root path/options。
- vfs_close_volume 必须真实释放 handle。
- vfs_mount_pack 返回 VFS_UNSUPPORTED_FEATURE，不能伪成功。
- vfs_open_path 未 mount 时返回 VFS_NOT_FOUND 或 VFS_NO_PACK_MOUNTED。
- vfs_open_entry(volume, 0) 返回 VFS_INVALID_ARGUMENT。
- vfs_read_at 对 invalid handle 返回错误。

### 4.3 错误码

定义稳定错误码：

~~~c
enum {
    VFS_OK = 0,
    VFS_NOT_FOUND = 1,
    VFS_INVALID_ARGUMENT = 2,
    VFS_IO_ERROR = 3,
    VFS_CORRUPTION = 4,
    VFS_CHECKSUM_MISMATCH = 5,
    VFS_UNSUPPORTED_VERSION = 6,
    VFS_UNSUPPORTED_FEATURE = 7,
    VFS_PERMISSION_DENIED = 8,
    VFS_KEY_COLLISION = 9,
    VFS_DB_ERROR = 10,
    VFS_BUSY = 11,
    VFS_INTERNAL_ERROR = 100,
};
~~~

---

## 5. 验证要求

必须测试：

1. zig build 生成 db 和 vfs artifacts。
2. C smoke test include vfs.h 成功。
3. vfs_open_volume 成功返回非 0 handle。
4. invalid path/null out pointer 返回 VFS_INVALID_ARGUMENT。
5. vfs_close_volume 后再次 close 返回 invalid handle。
6. vfs_open_entry(volume, 0) 返回 invalid argument。
7. vfs_open_path 未 mount pack 不伪成功。
8. invalid file handle read 不崩溃。
9. 符号检查：vfs 库导出 vfs_*，不导出新的 db_*。
10. DB 现有测试仍通过。

验证命令：

~~~powershell
zig build
zig build test
~~~

---

## 6. 完成标准

- VFS 独立库与 header 存在。
- ABI handle 生命周期真实可测。
- 未实现功能返回明确错误，不伪成功。
- 不破坏 DB。

