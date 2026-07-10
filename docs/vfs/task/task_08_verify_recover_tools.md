# Task 08：VFS Verify、Recover、Dump、Extract 工具

## 1. 任务目标

实现 VFS 格式一致性检查与诊断工具。verify 必须能发现 pack 内 manifest/path/page/tombstone 的常见损坏和不一致。

本任务不修复 DB 内部损坏；DB 内部损坏继续交给 db_verify/db_recover。VFS verify 在 DB get 成功基础上验证 VFS object 语义。

---

## 2. 必读上下文

- docs/vfs/task/setup.md
- task_02_object_keys_and_formats.md
- task_03_pack_builder_minimal.md
- task_04_pack_reader_open_read.md
- tools/db.zig

---

## 3. 硬性禁止

- 禁止 mock/moke。
- 禁止 verify 只返回 OK 而不实际检查。
- 禁止遇到首个错误就丢失上下文；至少要报告 object key 和错误类型。
- 禁止 extract 跳过校验直接输出损坏数据。
- 禁止 callback。

---

## 4. 实现范围

CLI：

~~~powershell
vfs verify-pack <pack_path>
vfs verify-volume <volume_path>
vfs dump-pack <pack_path>
vfs dump-path-index <pack_path>
vfs dump-file <pack_path> <file_entry>
vfs extract-file <pack_path> <file_entry> <out_path>
vfs recover-pack <pack_path>
~~~

### 4.1 verify-pack

检查：

- DB verify 通过。
- PackManifest magic/version/crc。
- PathIndex magic/version/crc。
- PathIndex path_hash 与 normalized path bytes 一致。
- PathIndex file_entry 非 0。
- PackManifest file list 与 FileManifest 可读取性一致。
- FileManifest magic/version/crc。
- FileManifest file_entry 与 expected identity 一致。
- block/page 数量与 file_size 一致。
- PageValue key identity 与 header identity 一致。
- PageValue stored_crc/raw_crc 正确。
- Tombstone 格式合法。
- object key 无冲突。

### 4.2 verify-volume

检查：

- 所有 mounted pack verify-pack。
- MountTable priority 冲突策略合法。
- overlay resolver 可构建。
- tombstone 不产生不一致可见性。

### 4.3 dump/extract

dump 必须输出可用于排错的信息：

- pack_id
- pack_version
- FileEntry
- paths
- file size
- page count
- codec
- flags

extract 必须走正常 reader 路径，不能直接拼 DB payload 跳过校验。

### 4.4 recover-pack

recover-pack 可先调用 db_recover，然后重新 verify VFS object。

如果 VFS 层发现 orphan page，本任务可以只报告，不要求 GC。

---

## 5. 验证要求

必须构造测试损坏：

1. PackManifest CRC 损坏。
2. PathIndex path_hash 损坏。
3. PathIndex 指向不存在 FileManifest。
4. FileManifest file_entry 不匹配。
5. FileManifest block/page count 不合法。
6. PageValue header_crc 损坏。
7. PageValue stored_crc 损坏。
8. PageValue raw_crc 损坏。
9. PageValue identity 不匹配。
10. Tombstone 格式损坏。
11. extract 正常文件输出与源文件一致。
12. extract 损坏文件失败且不输出伪成功。

验证命令：

~~~powershell
zig build
zig build test
.\zig-out\bin\vfs.exe verify-pack <pack_path>
.\zig-out\bin\vfs.exe extract-file <pack_path> <file_entry> <out_path>
~~~

---

## 6. 完成标准

- verify-pack 能发现 VFS 层主要损坏。
- dump/extract 可辅助人工排错。
- recover-pack 不伪修复。
- 无 mock/moke。

