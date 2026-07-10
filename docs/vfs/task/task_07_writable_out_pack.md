# Task 07：Writable Out Pack 与 Whole-file Rewrite

## 1. 任务目标

实现 writable out pack，使 VFS 支持运行时/editor 写入覆盖层。

V1 写入策略是 whole-file rewrite：修改文件时完整重写该文件 pages 和 FileManifest 到 writable pack。

---

## 2. 必读上下文

- docs/vfs/task/setup.md
- task_05_volume_mount_overlay.md
- task_03_pack_builder_minimal.md
- task_00_db_file_ops_inmemory.md

---

## 3. 硬性禁止

- 禁止 mock/moke。
- 禁止写入后不更新 resolver 却声称可见。
- 禁止 commit 失败后发布半成品。
- 禁止 page-level incremental，除非 task_11 已完成且本任务明确扩展。
- 禁止跳过 key collision 检查。

---

## 4. 实现范围

建议新增或扩展：

~~~text
src/vfs/pack/pack_writer.zig
src/vfs/volume/volume.zig
src/vfs/format/tombstone.zig
~~~

### 4.1 Writable pack

Volume options 支持指定 writable pack：

~~~text
no writable pack:
  write/delete 返回 VFS_PERMISSION_DENIED 或 VFS_UNSUPPORTED_FEATURE。

writable pack:
  默认最高 priority。
  所有写入进入该 pack。
~~~

### 4.2 写文件 API

内部 Zig API 至少支持：

~~~zig
pub fn writeFileByEntry(volume: *Volume, file_entry: u64, data: []const u8, options: WriteOptions) !void;
pub fn writeFileByPath(volume: *Volume, path: []const u8, file_entry: u64, data: []const u8, options: WriteOptions) !void;
~~~

C ABI 可在本任务或后续任务暴露。如果暴露，必须使用 caller buffer，不得 callback。

### 4.3 写入流程

~~~text
1. 校验 file_entry != 0。
2. 选择 writable pack。
3. split data -> pages。
4. 对每个 page 生成 PageValue。
5. 检测 page_key collision。
6. DB batch put pages。
7. 生成 FileManifest。
8. DB batch put FileManifest。
9. 如果有 path，更新 PathIndex。
10. 更新 PackManifest。
11. batch commit。
12. commit 成功后刷新 EntryResolver/PathIndex overlay view。
~~~

### 4.4 删除

实现 EntryTombstone：

~~~text
delete_entry(file_entry):
  write EntryTombstone to writable pack
  update PackManifest
  commit
  refresh resolver
~~~

PathTombstone 可选；如果不实现，必须明确返回 unsupported。

### 4.5 InMemoryFileOps

如果 task_00 已完成，本任务应支持可选 InMemoryFileOps 写入模式：

~~~text
load writable pack DB to memory
apply writes through normal DB path
flush writeback atomically
reopen/refresh pack
~~~

如果 task_00 未完成，不得 mock；必须标记阻塞。

---

## 5. 验证要求

必须测试：

1. 没有 writable pack 时写入失败。
2. 写入新 FileEntry 后 open_entry 可读。
3. 写入 path 后 open_path 可读。
4. 覆盖已有低优先级 FileEntry 后读取新内容。
5. 删除 Entry 后 open_entry/open_path 返回 not found。
6. commit 失败模拟时 resolver 不发布半成品。
7. key collision 检测触发 VFS_KEY_COLLISION。
8. 写入后 DB verify 通过。
9. 使用 InMemoryFileOps 写入并 flush 后默认 backend 可读。

验证命令：

~~~powershell
zig build test
~~~

---

## 6. 完成标准

- writable pack 能真实写入和覆盖。
- whole-file rewrite 语义正确。
- tombstone 可隐藏低优先级文件。
- InMemoryFileOps 路径真实可用或明确因 task_00 阻塞。

