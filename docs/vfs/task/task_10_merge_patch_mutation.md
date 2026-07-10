# Task 10：Merge / Patch / PackMutationPlan

## 1. 任务目标

实现 patch 描述到 PackMutationPlan 的转换，并复用 mutation executor 更新 pack。

目标是统一 build 和 merge 的执行模型：

~~~text
build_cfg -> BuildPlan -> PackMutationPlan
patch     -> MergePlan -> PackMutationPlan
~~~

---

## 2. 必读上下文

- docs/vfs/task/setup.md
- task_07_writable_out_pack.md
- task_09_build_cfg_incremental.md
- docs/design/vfs/vfs.md 中 Merge / Patch 章节

---

## 3. 硬性禁止

- 禁止 mock/moke。
- 禁止 patch 应用后绕过 verify。
- 禁止删除操作只从 PathIndex 删除而不处理 EntryTombstone。
- 禁止未校验 base version 就应用 patch。
- 禁止 callback。

---

## 4. 实现范围

建议新增：

~~~text
src/vfs/mutation/mutation_plan.zig
src/vfs/mutation/merge_planner.zig
src/vfs/mutation/mutation_executor.zig
src/vfs/format/patch_manifest.zig
~~~

### 4.1 PatchManifest

最小格式：

~~~text
version
target_pack_id
base_pack_version
patch_version
files[]
~~~

FilePatchDesc：

~~~text
file_entry
virtual_path optional
op: AddFile / ModifyFile / DeleteFile
old_file_size
new_file_size
old_content_hash
new_content_hash
source_payload_ref
~~~

V1 可以使用 whole-file payload，不要求 page-level patch。

### 4.2 PackMutationPlan

包含：

~~~text
AddFile
ModifyFile
DeleteFile
WritePage
DeletePage
WriteFileManifest
WriteEntryTombstone
UpdatePathIndex
UpdatePackManifest
CheckpointPack optional
VerifyPack
~~~

每个 mutation 必须记录：

- target pack
- file_entry
- source payload
- expected old version/hash，如果适用
- output object keys

### 4.3 MutationExecutor

执行流程：

~~~text
1. 校验 target pack/base version。
2. 展开 mutation plan。
3. 写 pages。
4. 写 manifests/tombstones。
5. 更新 PathIndex/PackManifest。
6. commit。
7. refresh resolver。
8. verify affected objects。
~~~

失败策略：

- commit 前失败不得发布 resolver。
- commit 后 verify 失败必须返回错误并标记 pack 需要 recover/repair。

### 4.4 PatchCoalescing

V1 支持简单同 file_entry 合并：

- Add 后 Delete 抵消。
- Modify 多次保留最后一次。
- Delete 后 Add 变 Replace。

复杂跨版本 page coalescing 留给后续。

---

## 5. 验证要求

必须测试：

1. AddFile patch 后 path/entry 可读。
2. ModifyFile patch 后读取新内容。
3. DeleteFile patch 后 tombstone 生效。
4. base_pack_version 不匹配拒绝应用。
5. patch payload hash 不匹配拒绝。
6. 多个 Modify 同 FileEntry coalesce 为最后结果。
7. Add 后 Delete 不产生可见文件。
8. Delete 后 Add 变 replace。
9. 应用 patch 后 verify-pack 通过。
10. 失败时 resolver 不发布半成品。

验证命令：

~~~powershell
zig build test
~~~

---

## 6. 完成标准

- PatchManifest 可解析和校验。
- PackMutationPlan 可执行。
- add/modify/delete 可见性正确。
- 无 mock/moke。

