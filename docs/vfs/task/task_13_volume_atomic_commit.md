# Task 13：Volume 级 Staging 与原子提交

## 1. 任务目标

实现跨多个 pack 的 volume 级一致更新。单个 pack 的 DB batch/commit 不能保证多个 pack 的原子可见性，因此 VFS 必须引入 staging generation 与 meta/volume manifest。

---

## 2. 必读上下文

- docs/vfs/task/setup.md
- task_10_merge_patch_mutation.md
- task_12_task_graph_scheduler.md
- docs/vfs/vfs_arch.md 中 volume/mount/overlay 部分

---

## 3. 硬性禁止

- 禁止 mock/moke。
- 禁止部分 pack 成功后立即对 volume 可见。
- 禁止 meta commit 前切换 resolver 到新版本。
- 禁止崩溃恢复时出现半新半旧可见状态。
- 禁止 callback。

---

## 4. 实现范围

建议新增：

~~~text
src/vfs/format/volume_manifest.zig
src/vfs/format/volume_transaction.zig
src/vfs/volume/transaction.zig
src/vfs/volume/staging.zig
~~~

### 4.1 VolumeManifest

记录：

- volume_id
- current_version
- mounted packs
- pack_id -> pack_generation
- priority
- writable pack
- manifest_crc

### 4.2 Staging

更新流程：

~~~text
1. 为每个目标 pack 创建 staging generation。
2. 所有 page/manifest/path 更新写入 staging。
3. verify staging pack。
4. 标记 pack staging ready。
5. 所有 pack ready 后写 VolumeTransaction。
6. 更新 VolumeManifest current_version。
7. commit meta pack。
8. 刷新 resolver 到新 version。
~~~

### 4.3 崩溃恢复

open volume 时：

~~~text
if transaction absent:
  use current manifest

if transaction present but not committed:
  keep old current version
  staging 可继续或清理

if transaction committed but manifest not fully switched:
  complete switch or recover to last valid superblock
~~~

必须能通过 manifest CRC 和 generation 状态判断。

### 4.4 InMemory merge

如果 task_00 完成，本任务应支持 staging pack 使用 InMemoryFileOps：

~~~text
load staging pack to memory
apply mutation graph
verify
flush staging atomically
then meta commit
~~~

---

## 5. 验证要求

必须测试：

1. 单 pack staging commit 成功后可见新版本。
2. 多 pack staging 全部 ready 后才切换 volume。
3. pack A 成功、pack B 失败时 volume 仍为旧版本。
4. meta commit 前崩溃，重开后仍为旧版本。
5. meta commit 后崩溃，重开后为新版本或可完成恢复。
6. staging orphan 可被 recover 清理或继续。
7. verify-volume 检查 pack_generation 与 VolumeManifest 一致。
8. resolver 切换是原子视图，不出现半新半旧。
9. InMemoryFileOps staging 路径真实落盘可读。

验证命令：

~~~powershell
zig build test
~~~

---

## 6. 完成标准

- Volume 级跨 pack 原子可见。
- 崩溃恢复语义明确且有测试。
- Staging 与 meta manifest 格式可 verify。
- 无 mock/moke。

