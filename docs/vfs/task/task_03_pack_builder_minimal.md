# Task 03：PackBuilder 最小闭环

## 1. 任务目标

实现从真实输入文件构建单个 pack DB 的最小闭环。

输出 pack 必须能包含：

- PackManifest
- PathIndex
- FileManifest
- PageValue

本任务只实现 none codec。压缩、overlay、volume 多 pack、writable out pack 不在本任务范围。

---

## 2. 必读上下文

- docs/vfs/task/setup.md
- task_02_object_keys_and_formats.md
- include/db.h
- src/db/kv_db.zig
- tools/db.zig

---

## 3. 硬性禁止

- 禁止 mock/moke。
- 禁止用内存 map 假装 pack。
- 禁止只写 manifest 不写真实 pages。
- 禁止只按 path_hash 查找，不保存 full normalized path。
- 禁止 callback。

---

## 4. 实现范围

建议新增：

~~~text
src/vfs/pack/pack_writer.zig
src/vfs/build/pack_builder.zig
src/vfs/compress/none.zig
tools/vfs.zig
~~~

### 4.1 Build input

实现 Zig 内部 API：

~~~zig
pub const BuildFileInput = struct {
    source_path: []const u8,
    virtual_path: []const u8,
    file_entry: u64,
    page_size: u32,
};

pub fn createPack(output_path: []const u8, files: []const BuildFileInput, options: PackBuildOptions) !void;
~~~

V1 FileEntry 规则：

- file_entry 必须由调用方显式传入，且必须非 0。
- 本任务不自动从 virtual_path 生成 FileEntry，除非 CLI 明确提供一个单独选项并完整检测冲突。
- 同一个 pack 内默认禁止两个 BuildFileInput 使用同一个 file_entry，即使 virtual_path 不同也拒绝。
- 多 path alias / rename 语义留给后续显式任务，不在最小 PackBuilder 中隐式实现。

### 4.2 文件处理

每个输入文件：

~~~text
1. 读取真实 source file。
2. normalize virtual path。
3. 校验 file_entry != 0。
4. 按 page_size 切分。
5. 生成 PageValue，codec = none。
6. 写入 DB page_key(file_entry, block_index, page_index)。
7. 生成 FileManifest。
8. 写入 DB file_manifest_key(file_entry)。
9. 加入 PathIndex。
10. 加入 PackManifest file list 摘要。
~~~

所有写入 DB 的 key 必须来自 Task 02 的 ObjectKey helper，并编码为 8-byte little-endian raw key bytes。

### 4.3 key collision 检测

构建期间必须维护 object key set：

- FileManifestKey 不得重复。
- PageKey 不得重复。
- file_entry 不得重复。
- reserved key 不得被派生 key 覆盖。
- 如果重复且 identity 不同，构建失败并返回 VFS_KEY_COLLISION。

### 4.4 CLI

实现最小 CLI：

~~~powershell
vfs create-pack <pack_path>
vfs put-file <pack_path> <virtual_path> <file_entry_u64> <source_path>
vfs dump-pack <pack_path>
~~~

如果 CLI 设计更适合一次性 build，也可以提供：

~~~powershell
vfs build-simple <pack_path> <virtual_path> <file_entry_u64> <source_path>
~~~

CLI 必须调用真实 PackBuilder，不得重复实现假逻辑。

---

## 5. 验证要求

必须测试：

1. 构建包含单文件的 pack。
2. 构建包含多个文件的 pack。
3. 空文件构建为合法 FileManifest，读取 size 为 0。
4. 小于 page_size 的文件生成一个 page。
5. 大于 page_size 的文件生成多个 page。
6. PathIndex 能通过 virtual_path 找到 FileEntry。
7. file_entry 重复但 path 不同必须拒绝，错误明确。
8. object key collision 被检测。
9. PageValue payload 与源文件对应 range 一致。
10. DB verify 通过。

验证命令：

~~~powershell
zig build
zig build test
.\zig-out\bin\vfs.exe build-simple zig-out\bin\vfs-pack /hello.txt 1 README.md
.\zig-out\bin\vfs.exe dump-pack zig-out\bin\vfs-pack
.\zig-out\bin\db.exe verify zig-out\bin\vfs-pack
~~~

---

## 6. 完成标准

- 真实文件能写入 pack DB。
- pack 中 manifest/path/page 全部真实存在。
- 生成结果可被后续 reader 读取。
- 没有 mock/moke。
