# Task 05：Volume MountTable 与 Overlay Resolver

## 1. 任务目标

实现多 pack 挂载、MountTable、Path overlay、Entry overlay 和 EntryTombstone。

本任务在 Task 04 单 pack 读取基础上扩展到多 pack 可见性解析。

---

## 2. 必读上下文

- docs/vfs/task/setup.md
- task_04_pack_reader_open_read.md
- docs/vfs/vfs_arch.md 的 Overlay 章节

---

## 3. 硬性禁止

- 禁止 mock/moke。
- 禁止同 priority 冲突产生非确定结果。
- 禁止 path overlay 与 entry overlay 混为一个概念。
- 禁止 open_entry 依赖 path。
- 禁止 tombstone 后继续落到低优先级文件。

---

## 4. 实现范围

建议新增：

~~~text
src/vfs/volume/mount_table.zig
src/vfs/volume/overlay_resolver.zig
src/vfs/volume/entry_resolver.zig
src/vfs/volume/path_resolver.zig
~~~

### 4.1 MountTable

MountEntry：

~~~zig
pub const MountEntry = struct {
    pack_id: u32,
    priority: u32,
    mount_order: u64,
    pack_version: u64,
    flags: u32,
};
~~~

规则：

- priority 高者优先。
- writable pack 默认最高优先级，但本任务可只支持 readonly。
- 同 priority 冲突 V1 推荐返回 VFS_INVALID_ARGUMENT 或 VFS_UNSUPPORTED_FEATURE，除非实现稳定 mount_order 规则并完整测试。

### 4.2 Entry overlay

构建：

~~~text
for each mounted pack:
  read PackManifest file entries
  read tombstone entries
  append FileLocation to entry map
sort locations by priority
~~~

解析：

~~~text
resolve_entry(file_entry):
  if top record is EntryTombstone -> NotFound
  else return top normal FileLocation
~~~

### 4.3 Path overlay

Path overlay 独立于 Entry overlay：

~~~text
resolve_path(path):
  for packs by priority:
    lookup PathIndex
    if PathTombstone -> NotFound
    if normal path -> FileEntry
  then resolve_entry(FileEntry)
~~~

V1 如不实现 PathTombstone，必须文档明确并测试 EntryTombstone。

---

## 5. 验证要求

必须测试：

1. base pack + patch pack 同 path 同 FileEntry，高优先级覆盖。
2. base pack + patch pack 同 FileEntry 不同 path，open_entry 返回高优先级。
3. path open 先解析 path，再解析 entry overlay。
4. EntryTombstone 隐藏低优先级 FileEntry。
5. tombstone 后 open_path 和 open_entry 均返回 not found。
6. 同 priority 冲突行为稳定且有测试。
7. unmount 或 close volume 后 handles 行为明确。
8. 多 pack 中 PageValue 读取来自正确 pack。

验证命令：

~~~powershell
zig build test
~~~

---

## 6. 完成标准

- 多 pack overlay 语义正确。
- path overlay 与 entry overlay 分离。
- tombstone 可隐藏低优先级版本。
- 没有 mock/moke。

