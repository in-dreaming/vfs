# Task 09：BuildCfg 与文件级增量构建

## 1. 任务目标

实现 build_cfg、BuildPlan、BuildCache，使 VFS 可以从配置批量构建 pack，并支持文件级增量。

本任务不实现 page-level incremental。大文件小修改仍按 whole-file rewrite。

---

## 2. 必读上下文

- docs/vfs/task/setup.md
- task_03_pack_builder_minimal.md
- task_06_page_cache_and_compression.md

---

## 3. 硬性禁止

- 禁止 mock/moke。
- 禁止只按 mtime 判断增量而不支持 content hash。
- 禁止配置变化后仍复用旧输出。
- 禁止 compressor 版本变化后仍复用旧输出。
- 禁止 callback。

---

## 4. 实现范围

建议新增：

~~~text
src/vfs/build/build_cfg.zig
src/vfs/build/build_plan.zig
src/vfs/build/build_cache.zig
src/vfs/build/pack_builder.zig
~~~

### 4.1 BuildCfg

支持最小配置：

~~~text
pack:
  pack_id
  pack_name
  default_page_size

compression:
  default codec/level/page_size

files:
  virtual_path
  source_path
  file_entry
  page_size optional
  codec optional
~~~

配置解析可以先使用简单 JSON 或自定义文本，但必须文档化并测试。不要引入不可构建依赖。

### 4.2 BuildPlan

BuildPlan 应包含：

- pack_id
- file list
- source metadata
- resolved page_size/codec
- output object keys
- estimated page count

### 4.3 BuildCache

BuildCacheEntry：

~~~text
file_entry
virtual_path
source_path
source_size
source_mtime
source_hash
build_cfg_hash
compressor_version_hash
output_manifest_hash
~~~

rebuild 条件：

- source_hash 变化。
- source_size 变化。
- build_cfg_hash 变化。
- page_size 变化。
- codec/level 变化。
- compressor_version_hash 变化。
- file_entry 变化。
- virtual_path 变化需要至少更新 PathIndex。

---

## 5. 验证要求

必须测试：

1. 从配置构建多个文件。
2. 未变化二次构建跳过文件内容重写。
3. source 内容变化触发 rebuild。
4. page_size 变化触发 rebuild。
5. codec 变化触发 rebuild。
6. virtual_path 变化更新 PathIndex。
7. file_entry 变化生成新 manifest/page keys。
8. build cache 损坏时安全 fallback rebuild。
9. 构建结果 verify-pack 通过。
10. 构建结果可由 vfs_open_path/vfs_open_entry 读取。

验证命令：

~~~powershell
zig build test
.\zig-out\bin\vfs.exe build <cfg_path>
.\zig-out\bin\vfs.exe verify-pack <pack_path>
~~~

---

## 6. 完成标准

- 配置驱动批量构建可用。
- 文件级增量准确。
- 配置/codec/source 变化不会错误复用。
- 无 mock/moke。

