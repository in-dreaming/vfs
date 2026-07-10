# Task 11：Page-level Incremental 与 Explicit PageRef

## 1. 任务目标

实现 page-level incremental 和 explicit PageRef，使大文件小修改只写变化 page，未变化 page 可引用旧 pack/page。

---

## 2. 必读上下文

- docs/vfs/task/setup.md
- task_10_merge_patch_mutation.md
- task_06_page_cache_and_compression.md
- docs/vfs/vfs_arch.md 中 FileManifest/PageRef 章节

---

## 3. 硬性禁止

- 禁止 mock/moke。
- 禁止 explicit PageRef 指向不存在 page。
- 禁止旧 pack 缺失时静默返回空数据。
- 禁止 page hash 相同就跳过校验所有 identity。
- 禁止 callback。

---

## 4. 实现范围

### 4.1 FileManifest explicit PageRef

扩展 FileManifest：

~~~text
BlockDesc flags 支持 explicit_page_refs
PageRef array:
  pack_id
  pack_generation
  file_entry
  block_index
  page_index
  page_key
  raw_hash/content_hash
~~~

读取逻辑：

~~~text
if block implicit:
  page_key(current file_entry, block, page)
  read from current pack

if block explicit:
  PageRef 指定 pack/page
  read referenced page
  verify referenced PageValue identity
  verify content_hash/raw_crc
~~~

### 4.2 Page-level build cache

PageBuildCacheEntry：

~~~text
file_entry
block_index
page_index
raw_page_hash
compress_info_hash
stored_page_hash
raw_size
stored_size
source range
~~~

### 4.3 Copy-on-write 写入

流程：

~~~text
old manifest + new source
  -> split new source pages
  -> hash pages
  -> unchanged page create PageRef to old page
  -> changed page write to writable/current pack
  -> write new FileManifest describing full file
~~~

### 4.4 Verify

verify-pack 必须扩展：

- 检查 PageRef 目标 pack 是否 mounted/available。
- 检查 PageRef 目标 PageValue 存在。
- 检查目标 identity 与 PageRef 一致。
- 检查 hash/crc 一致。

---

## 5. 验证要求

必须测试：

1. 大文件只修改一个 page，仅写一个新 PageValue。
2. 读取 sparse manifest 得到完整新文件。
3. 未变化 page 从旧 pack 读取。
4. 旧 pack 缺失时读取失败且错误明确。
5. PageRef 指向错误 file_entry 时 verify/read 失败。
6. PageRef 指向错误 block/page 时 verify/read 失败。
7. referenced page payload 损坏时读取失败。
8. page hash cache 损坏时 fallback rebuild。
9. whole-file rewrite 与 page-level incremental 结果一致。

验证命令：

~~~powershell
zig build test
~~~

---

## 6. 完成标准

- explicit PageRef 格式可用。
- page-level incremental 真实减少写入。
- sparse manifest 读取和 verify 正确。
- 无 mock/moke。

