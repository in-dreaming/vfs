# Task 06：Page Cache 与 Compression Registry

## 1. 任务目标

实现 VFS 读取路径的 page cache，并引入 compression registry。V1 至少支持 none codec；可选实现 lz4/zstd，但如果引入依赖必须真实可构建、可测试。

本任务不得改变 vfs_read_at 的语义，只优化 page 获取与解码路径。

---

## 2. 必读上下文

- docs/vfs/task/setup.md
- task_04_pack_reader_open_read.md
- src/vfs/format/page_value.zig

---

## 3. 硬性禁止

- 禁止 mock/moke。
- 禁止伪压缩、伪 CRC。
- 禁止 cache key 只用 page_key。
- 禁止 pack generation 变化后读到旧 cache。
- 禁止返回 cache 内部可变指针给 C 调用方。
- 禁止 callback。

---

## 4. 实现范围

建议新增：

~~~text
src/vfs/io/page_cache.zig
src/vfs/compress/compressor.zig
src/vfs/compress/registry.zig
src/vfs/compress/none.zig
src/vfs/compress/lz4.zig
src/vfs/compress/zstd.zig
~~~

### 4.1 PageCache

Page cache key：

~~~text
pack_id
pack_generation
file_entry
block_index
page_index
codec_identity
~~~

必须支持：

- memory budget。
- LRU 或 clock 淘汰。
- cache miss 读取 DB PageValue。
- cache hit 直接 copy caller 请求范围。
- volume close 时释放。
- pack remount/generation 变化后不命中旧 cache。

### 4.2 CompressionRegistry

接口方向：

~~~zig
pub const Compressor = struct {
    codec: u16,
    version_hash: u64,
    compressBound: fn(...) ...,
    compressPage: fn(...) ...,
    decompressPage: fn(...) ...,
};
~~~

如果 Zig 代码中需要函数指针，只能作为内部 registry，不得暴露为 public C callback。

### 4.3 None codec

none codec 必须真实校验：

- stored_size == raw_size。
- stored payload copy 后 raw_crc 正确。

### 4.4 LZ4/Zstd

如果实现：

- 必须接入真实库或 Zig package。
- 失败时返回 VFS_UNSUPPORTED_FEATURE。
- 不能用 memcpy 假装压缩。

如果不实现：

- registry 中明确没有该 codec。
- 读取对应 codec 返回 VFS_UNSUPPORTED_FEATURE。

---

## 5. 验证要求

必须测试：

1. none codec roundtrip。
2. cache miss 后第二次读取同 page 命中 cache。
3. cache memory budget 超限会淘汰。
4. pack_generation 不同不会复用旧 cache。
5. corrupted stored_crc 不进入 cache。
6. corrupted raw_crc 不进入 cache。
7. unsupported codec 返回 VFS_UNSUPPORTED_FEATURE。
8. 跨 page read 中部分 page hit、部分 miss 正确。
9. 大量随机读无越界和泄漏。

验证命令：

~~~powershell
zig build test
zig build test -Doptimize=ReleaseSafe
~~~

---

## 6. 完成标准

- vfs_read_at 使用真实 PageCache。
- none codec 真实可用。
- unsupported codec 错误明确。
- 无 mock/moke。

