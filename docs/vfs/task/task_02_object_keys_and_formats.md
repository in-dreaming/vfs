# Task 02：u64 Object Key 与 Pack 基础格式

## 1. 任务目标

实现 VFS object key 派生、PackManifest、PathIndex、FileManifest、PageValue、Tombstone 的二进制 encode/decode 和校验逻辑。

本任务不实现 pack builder、pack reader、volume mount。它只提供后续任务可依赖的真实格式层。

---

## 2. 必读上下文

- docs/vfs/task/setup.md
- docs/vfs/vfs_arch.md
- docs/vfs/vfs_roadmap.md
- include/db.h
- src/db/format.zig 中现有 CRC/hash 工具

---

## 3. 硬性禁止

- 禁止 mock/moke。
- 禁止裸写普通 Zig struct 到磁盘。
- 禁止省略 header identity 校验。
- 禁止把 FileEntry 扩展成 public 128-bit。
- 禁止 page/file key 碰撞时静默覆盖。
- 禁止 callback。

---

## 4. 实现范围

建议新增：

~~~text
src/vfs/object_key.zig
src/vfs/hash.zig
src/vfs/format/pack_manifest.zig
src/vfs/format/path_index.zig
src/vfs/format/directory_manifest.zig
src/vfs/format/file_manifest.zig
src/vfs/format/page_value.zig
src/vfs/format/tombstone.zig
~~~

### 4.1 ObjectKey

实现稳定 u64 key 派生：

~~~zig
pub const ObjectKey = u64;

pub fn packManifestKey() u64;
pub fn pathIndexKey() u64;
pub fn directoryManifestKey() u64;
pub fn fileManifestKey(file_entry: u64) u64;
pub fn pageKey(file_entry: u64, block_index: u32, page_index: u32) u64;
pub fn encodeDbKey(key: u64) [8]u8;
~~~

要求：

- key 派生必须稳定，不依赖进程随机种子。
- reserved key 与派生 key 必须有冲突检测 helper。
- hash 输入必须带 domain separator，例如 vfs.page.v1。
- file_entry 为 0 时返回 error.InvalidFileEntry。
- 调用 DB 时只能使用 encodeDbKey 输出的 8-byte little-endian raw key bytes。
- 禁止把 FileManifest/PageValue 的多字段 identity struct 直接作为 DB key。
- 禁止在本任务中修改 DB 内部 Key128/index/journal 格式来“适配 VFS”；如需 DB 原生 u64 ABI，必须另建 DB feature task。

### 4.2 PackManifest

实现 header 与 file index 摘要。

至少包含：

- magic VPKM
- version
- header_size
- pack_id
- flags
- pack_version
- build_id
- file_count
- tombstone_count
- path_index_key
- directory_manifest_key
- content_hash
- manifest_crc

必须提供：

~~~zig
encodePackManifest
decodePackManifest
verifyPackManifest
~~~

### 4.3 PathIndex

实现 path -> FileEntry 的索引格式。

格式必须保存：

- bucket table
- path_hash
- FileEntry
- normalized path bytes offset/size
- flags
- string table
- CRC

PathIndex lookup 必须比较 full normalized path bytes，不能只比较 hash。

### 4.4 FileManifest

实现 FileManifestHeader、BlockDesc、可选 PageRef 解码保留。

V1 必须支持 implicit page key。

Header 至少包含：

- magic VFMF
- version
- header_size
- file_entry
- file_version
- file_size
- content_hash
- block_count
- flags
- manifest_crc

BlockDesc 至少包含：

- raw_offset
- raw_size
- page_size
- page_count
- codec
- codec_level
- codec_flags
- block_hash
- flags
- page_ref_offset

### 4.5 PageValue

实现 PageValueHeader 与完整 value encode/decode。

读取时必须验证：

- magic/version/header_size。
- header_crc。
- file_entry、block_index、page_index 与 expected identity 一致。
- stored_size 与 payload 长度一致。
- stored_crc。
- raw_crc 在解压后由后续 codec 层校验；none codec 可在本任务中直接校验。

### 4.6 Tombstone

实现 EntryTombstone 基础格式：

- file_entry
- tombstone_version
- reason flags
- crc

PathTombstone 可以只定义格式，不要求 overlay 使用。

---

## 5. 验证要求

必须测试：

1. object key 派生稳定，同输入多次一致。
2. reserved key 不与常见 file/page key 冲突。
3. file_entry 0 返回错误。
4. encodeDbKey 对固定 u64 输出固定 little-endian 字节。
5. PackManifest encode/decode roundtrip。
6. FileManifest encode/decode roundtrip，多 block、多 page。
7. PathIndex 支持 path_hash 碰撞下 full path 匹配。
8. PageValue header identity 不匹配时拒绝。
9. PageValue stored_crc 损坏时拒绝。
10. 截断 value 时拒绝。
11. 保留字段非 0 时按格式策略拒绝或清晰忽略，并有测试。
12. 所有格式 little-endian 编码稳定。

验证命令：

~~~powershell
zig build test
zig build test -Doptimize=ReleaseSafe
~~~

---

## 6. 完成标准

- 格式层可被后续 pack builder/reader 直接使用。
- 所有读取路径都有校验。
- 没有 mock/moke。
- 没有 public callback。
