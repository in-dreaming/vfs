#!/usr/bin/env python3
"""Golden Eval model guard — modelId 通过命令行参数传入"""
import json, os, sys

MODEL_GUARD = os.environ.get("GOLDEN_EVAL_MODEL_GUARD", "1") == "1"

# 模型参数（来自 hook command 的命令行参数，创建实例时写入）
TARGET_MODEL_ID = sys.argv[1] if len(sys.argv) > 1 else ""
TARGET_MODEL_LABEL = sys.argv[2] if len(sys.argv) > 2 else ""

# ── 模型拦截 (UserPromptSubmit) ──
def model_guard(data):
    if not MODEL_GUARD or not TARGET_MODEL_ID:
        return {"continue": True}
    req = data.get("model", "")
    if req and req != TARGET_MODEL_ID:
        return {"continue": False, "stopReason": f"请在对话窗口模型列表中切换到「{TARGET_MODEL_LABEL}」" if TARGET_MODEL_LABEL else "当前模型不匹配，请切换"}
    return {"continue": True}

# ── main ──
try:
    d = json.load(sys.stdin)
except Exception:
    print(json.dumps({"continue": True}))
    sys.exit(0)

ev = d.get("hook_event_name", "")
try:
    if ev == "UserPromptSubmit":
        print(json.dumps(model_guard(d)))
    else:
        print(json.dumps({"continue": True}))
except Exception as e:
    sys.stderr.write(f"[Golden Eval] error: {e}\n")
    print(json.dumps({"continue": True, "hookSpecificOutput": {"hookEventName": ev, "permissionDecision": "deny", "permissionDecisionReason": f"[Golden Eval] guard error: {e}"}}))
