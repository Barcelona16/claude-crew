#!/usr/bin/env bash
# crew-sendmsg-hook.test.sh — PostToolUse hook 脚本单元测试
# 覆盖:
#   ① 正常 SendMessage JSON → 写对 inbox(from=self, note=message)+ feedback 镜像
#   ② toolName/toolInput 驼峰变体 → 同样成功
#   ③ 缺 CREW_SESSION → 不写,退 0
#   ④ tool_name 是别的工具(Read)→ 不写,退 0(二次校验兜底)
#   ⑤ 坏 JSON → 退 0 不崩
#   ⑥ 空 stdin → 退 0 不写
#   ⑦ 缺 to / 缺 message → 不写,退 0
#   ⑧ message 含换行/引号/特殊字符 → 逐字节保真
#   ⑨ CREW_SENDMSG_TOOL 覆盖工具名 → 按覆盖值匹配

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="$SCRIPT_DIR/../bin/crew-sendmsg-hook.sh"

pass=0; fail=0; total=0
_ok() { total=$((total+1)); pass=$((pass+1)); echo "  ✓ $1"; }
_ng() { total=$((total+1)); fail=$((fail+1)); echo "  ✗ $1"; }

# 测试隔离:清掉可能从父 shell 继承的 CREW_* env,避免污染 Case 3 等
unset CREW_SESSION CREW_SENDMSG_TOOL CREW_STATE FEEDBACK_JSONL 2>/dev/null || true

# 每个 case 一个干净 state 目录。用法:run_hook <json> [env KEY=VAL ...] 通过前置变量传 env。
# 返回:全局 RC(退出码)、STATE(该次 state 目录,供断言 inbox)。
# 用 env -i 起一个干净环境(只保留 PATH/HOME + 显式传入的),杜绝继承污染。
run_hook() {
  local json="$1"; shift
  STATE="$(mktemp -d /tmp/crew-hook-test.XXXXXX)"
  printf '%s' "$json" | env -i PATH="$PATH" HOME="$HOME" \
    CREW_STATE="$STATE/state" FEEDBACK_JSONL="$STATE/fb.jsonl" "$@" bash "$HOOK"
  RC=$?
}
inbox_count() { ls "$STATE/state/inbox/$1"/*.json 2>/dev/null | wc -l | tr -d ' '; }
cleanup() { rm -rf "$STATE"; }

# ---- Case 1: 正常 ----
echo "--- Case 1: 正常 SendMessage ---"
run_hook '{"tool_name":"SendMessage","tool_input":{"to":"bob","message":"hi bob"}}' CREW_SESSION=alice
[ "$RC" = 0 ] && _ok "退 0" || _ng "退码=$RC"
[ "$(inbox_count bob)" = 1 ] && _ok "bob inbox 写 1 条" || _ng "inbox 数=$(inbox_count bob)"
f=$(ls "$STATE/state/inbox/bob"/*.json 2>/dev/null | head -1)
node -e "const e=JSON.parse(require('fs').readFileSync('$f'));process.exit(e.from.kind==='session'&&e.from.id==='alice'&&e.note==='hi bob'?0:1)" \
  && _ok "信封 from=session:alice note=hi bob" || _ng "信封字段不对"
[ -f "$STATE/fb.jsonl" ] && _ok "feedback.jsonl 镜像存在" || _ng "无镜像"
cleanup

# ---- Case 2: 驼峰变体 ----
echo "--- Case 2: toolName/toolInput 驼峰 ---"
run_hook '{"toolName":"SendMessage","toolInput":{"to":"bob","message":"camel"}}' CREW_SESSION=alice
[ "$RC" = 0 ] && [ "$(inbox_count bob)" = 1 ] && _ok "驼峰变体也写 1 条" || _ng "驼峰失败 rc=$RC cnt=$(inbox_count bob)"
cleanup

# ---- Case 3: 缺 CREW_SESSION ----
echo "--- Case 3: 缺 CREW_SESSION ---"
run_hook '{"tool_name":"SendMessage","tool_input":{"to":"bob","message":"m"}}'
[ "$RC" = 0 ] && [ "$(inbox_count bob)" = 0 ] && _ok "无 self 不写 + 退 0" || _ng "rc=$RC cnt=$(inbox_count bob)"
cleanup

# ---- Case 4: 别的工具 ----
echo "--- Case 4: tool_name=Read 不记 ---"
run_hook '{"tool_name":"Read","tool_input":{"to":"bob","message":"m"}}' CREW_SESSION=alice
[ "$RC" = 0 ] && [ "$(inbox_count bob)" = 0 ] && _ok "非 SendMessage 不写 + 退 0" || _ng "rc=$RC cnt=$(inbox_count bob)"
cleanup

# ---- Case 5: 坏 JSON ----
echo "--- Case 5: 坏 JSON ---"
run_hook 'not json {{{' CREW_SESSION=alice
[ "$RC" = 0 ] && [ "$(inbox_count bob)" = 0 ] && _ok "坏 JSON 退 0 不崩不写" || _ng "rc=$RC cnt=$(inbox_count bob)"
cleanup

# ---- Case 6: 空 stdin ----
echo "--- Case 6: 空 stdin ---"
run_hook '' CREW_SESSION=alice
[ "$RC" = 0 ] && [ "$(inbox_count bob)" = 0 ] && _ok "空 stdin 退 0 不写" || _ng "rc=$RC cnt=$(inbox_count bob)"
cleanup

# ---- Case 7: 缺 to / 缺 message ----
echo "--- Case 7: 缺 to / 缺 message ---"
run_hook '{"tool_name":"SendMessage","tool_input":{"message":"m"}}' CREW_SESSION=alice
miss_to_ok=0
[ "$RC" = 0 ] && [ "$(ls "$STATE/state/inbox" 2>/dev/null | wc -l | tr -d ' ')" = 0 ] && miss_to_ok=1
cleanup
run_hook '{"tool_name":"SendMessage","tool_input":{"to":"bob"}}' CREW_SESSION=alice
miss_msg_ok=0
[ "$RC" = 0 ] && [ "$(inbox_count bob)" = 0 ] && miss_msg_ok=1
cleanup
[ "$miss_to_ok" = 1 ] && [ "$miss_msg_ok" = 1 ] && _ok "缺 to 或缺 message 均不写 + 退 0" || _ng "缺字段处理不对 miss_to=$miss_to_ok miss_msg=$miss_msg_ok"

# ---- Case 8: 特殊字符逐字节保真 ----
echo "--- Case 8: message 含换行/引号/特殊字符 ---"
# 用 node 生成含换行、引号、& 的合法 JSON,喂给 hook,再核对 note 与原文逐字节相等
MSG=$'line1\nline2 "quoted" & <special> \t tab'
JSON=$(MSG="$MSG" node -e 'process.stdout.write(JSON.stringify({tool_name:"SendMessage",tool_input:{to:"bob",message:process.env.MSG}}))')
run_hook "$JSON" CREW_SESSION=alice
f=$(ls "$STATE/state/inbox/bob"/*.json 2>/dev/null | head -1)
if [ -n "$f" ]; then
  MSG="$MSG" node -e "const e=JSON.parse(require('fs').readFileSync('$f'));process.exit(e.note===process.env.MSG?0:1)" \
    && _ok "特殊字符 note 逐字节保真" || _ng "note 不匹配原文"
else _ng "特殊字符消息未写 inbox"; fi
cleanup

# ---- Case 9: CREW_SENDMSG_TOOL 覆盖 ----
echo "--- Case 9: CREW_SENDMSG_TOOL 覆盖工具名 ---"
# 覆盖成 "XSend",则 tool_name=SendMessage 应被视为不匹配(不写),tool_name=XSend 才写
run_hook '{"tool_name":"SendMessage","tool_input":{"to":"bob","message":"m"}}' CREW_SESSION=alice CREW_SENDMSG_TOOL=XSend
c_no=$(inbox_count bob); cleanup
run_hook '{"tool_name":"XSend","tool_input":{"to":"bob","message":"m"}}' CREW_SESSION=alice CREW_SENDMSG_TOOL=XSend
[ "$c_no" = 0 ] && [ "$(inbox_count bob)" = 1 ] && _ok "覆盖后按新名匹配(旧名不写/新名写)" || _ng "覆盖不生效 c_no=$c_no cnt=$(inbox_count bob)"
cleanup

echo
echo "=== crew-sendmsg-hook.test.sh: $pass / $total pass, $fail fail ==="
[ "$fail" -eq 0 ]
