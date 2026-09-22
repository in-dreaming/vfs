# Golden Eval 众测任务

- 任务：vfs_diffpatch
- 模型：测试模型 B
- 工作目录：`G:\work\tech\infra\vfs_tasks\diffpatch\ge-3eb82a0e3b2c`

## 任务 Prompt

调研下vfs层是否实现了包的diff&patch。如果没有则调研用hdiff实现（考虑参考其算法实现活迁移为zig版本，或直接用其cabi?），输出设计文档到docs/vfs/diff_patch.md。 需要决策的先人工决策。  一个简单直接想法是，diff也用db存储(一个包产生一个diff indexdb+data db，考虑用blob存储，而不是一条一个kv，避免大量零散小数据造成读写性能问题)

## 操作

1. 窗口打开后会自动开始本路评测，并把上面的 Prompt 填入输入框。
2. 确认模型和目录后按回车发送；若输入框为空，Prompt 已在剪贴板。
3. 做完后点击左下角“结束众测 · B”。
4. 若没有自动开始，按提示处理后点状态栏“测试模型 B · 待开始”。
