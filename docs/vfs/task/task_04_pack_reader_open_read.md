# Task 04：单 Pack Reader、vfs_open_path、vfs_open_entry、vfs_read_at

## 1. 任务目标

实现单 pack 只读访问闭环。

必须支持：

- vfs_mount_pack 挂载一个 readonly pack。
- vfs_open_path 通过 PathIndex 找到 FileEntry。
- vfs_open_entry 直接使用 u64 FileEntry。
- vfs_read_at 随机读取文件内容。

---

## 2. 必读上下文

- docs/vfs/task/setup.md
- task_01_vfs_abi_skeleton.md
- task_02_object_keys_and_formats.md
- task_03_pack_builder_minimal.md
- include/vfs.h
- include/db.h

---

## 3. 硬性禁止

- 禁止 mock/moke。
- 禁止 vfs_open_entry 依赖 path。
- 禁止 read_at 返回内部 DB buffer 指针。
- 禁止跳过 PageValue/FileManifest 校验。
- 禁止 callback read API。

---

## 4. 实现范围

建议新增：

~~~text
src/vfs/pack/pack_reader.zig
src/vfs/volume/path_resolver.zig
src/vfs/volume/entry_resolver.zig
src/vfs/io/file_handle.zig
src/vfs/io/read_plan.zig
~~~

### 4.1 Mount single pack

vfs_mount_pack：

~~~text
1. 打开 pack DB。
2. 读取 PackManifest。
3. 读取 PathIndex。
4. 构建单 pack EntryResolver。
5. 将 pack 加入 Volume。
~~~

本任务只要求一个 pack。多个 pack 和 overlay 在后续任务。

### 4.2 vfs_open_path

流程：

~~~text
1. 校验 volume handle。
2. normalize path。
3. PathIndex lookup，必须 full path bytes 比较。
4. 得到 FileEntry。
5. 调用 common open。
~~~

### 4.3 vfs_open_entry

流程：

~~~text
1. file_entry == 0 返回 VFS_INVALID_ARGUMENT。
2. EntryResolver 查 FileLocation。
3. DB get FileManifest。
4. decode + verify FileManifest。
5. header.file_entry 必须等于输入。
6. 创建 file handle，保存 manifest snapshot。
~~~

### 4.4 vfs_read_at

流程：

~~~text
1. offset >= file_size 返回 0 bytes。
2. clamp 到 file_size。
3. 根据 FileManifest 计算 block/page。
4. 对每个 page：
   a. DB get PageValue。
   b. decode + verify PageValueHeader。
   c. codec none 直接校验 raw_crc。
   d. copy requested slice 到 caller buffer。
5. 返回 out_read。
~~~

本任务不要求 page cache，但必须预留后续接入点。

---

## 5. 验证要求

必须测试：

1. 使用 Task 03 builder 构建 pack，再挂载读取。
2. vfs_open_path 读回完整文件。
3. vfs_open_entry 使用同一 FileEntry 读回完整文件。
4. vfs_open_entry 不依赖 PathIndex 中 path 是否存在。
5. read_at offset 0、小范围、中间跨 page、尾部短读。
6. offset == file_size 返回 0。
7. offset > file_size 返回 0。
8. caller buffer 小于请求 size 时只写 buffer 范围并返回实际读取。
9. FileManifest file_entry 损坏时 open_entry 失败。
10. PageValue stored_crc/raw_crc 损坏时 read 失败。
11. PageValue identity 不匹配时 read 失败。
12. invalid handles 不崩溃。

验证命令：

~~~powershell
zig build
zig build test
zig build -Doptimize=ReleaseSafe
zig build test -Doptimize=ReleaseSafe
~~~

---

## 6. 完成标准

- 单 pack path open 与 entry open 均可真实读取。
- read_at 支持随机读和跨 page。
- 所有读取都校验格式。
- 没有 mock/moke。

