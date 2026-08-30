#!/usr/bin/env bash
# test/crew-launcher.test.sh — crew-launcher 单测(2026-08-30 crew L 重构 Week 3)
# 覆盖 fg/tmux 两模式,policy 注入,sid resume/fresh,backend 加载

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CL="$SCRIPT_DIR/../bin/crew-launcher"
CS="$SCRIPT_DIR/../bin/crew-session"
CT="$SCRIPT_DIR/../bin/crew-tmux"

export CREW_STATE="/tmp/crew-launcher-test-$$"
export CREW_HOME="/tmp/crew-launcher-test-home-$$"
export CREW_CLAUDE_BIN="/bin/echo"

pass=0; fail=0; total=0
_ok() { total=$((total+1)); pass=$((pass+1)); echo "  ✓ $1"; }
_ng() { total=$((total+1)); fail=$((fail+1)); echo "  ✗ $1 [$2]"; }

TEST_PREFIX="test-lchr-$$"

setup() {
  rm -rf "$CREW_STATE" "$CREW_HOME"
  mkdir -p "$CREW_STATE" "$CREW_HOME/backends" "$CREW_HOME/templates"
  cat > "$CREW_HOME/backends/mock.conf" <<EOF
BASE_URL=http://localhost:9999
MODEL=mock-model
TOKEN=mocktoken
KEY_MODE=direct
EOF
  # copy policy templates
  cp /work/claude-crew/templates/*.md "$CREW_HOME/templates/" 2>/dev/null || true
}
teardown() {
  # kill tmux 测试 session
  for s in $(timeout 3 tmux list-sessions -F '#{session_name}' 2>/dev/null | grep "$TEST_PREFIX" || true); do
    tmux kill-session -t "$s" 2>/dev/null || true
  done
  rm -rf "$CREW_STATE" "$CREW_HOME"
  rm -f /tmp/crew-launch-${TEST_PREFIX}*.sh
}

trap teardown EXIT
setup

# --- Case 1: usage error ---
echo "--- Case 1: usage 错误 ---"
"$CL" 2>/dev/null; ec=$?
[ "$ec" = "2" ] && _ok "空命令 → exit 2" || _ng "空命令应 exit 2,实际 $ec" ""
"$CL" spawn 2>/dev/null; ec=$?
[ "$ec" = "2" ] && _ok "spawn 无 --name --mode → exit 2" || _ng "spawn 无参应 exit 2,实际 $ec" ""

# --- Case 2: 缺 backend 报错 ---
echo "--- Case 2: 缺 backend ---"
N="${TEST_PREFIX}-a"
out=$("$CL" spawn --name "$N" --mode fg 2>&1) || true
echo "$out" | grep -q "no backend" && _ok "缺 backend 报错" || _ng "应报 'no backend',实际:$out" ""

# --- Case 3: fg mode 起(mock claude 立退)+ sid 新建 ---
echo "--- Case 3: fg mode + sid 生成 ---"
N="${TEST_PREFIX}-b"
"$CS" set "$N" backend mock >/dev/null
out=$("$CL" spawn --name "$N" --mode fg 2>&1)
echo "$out" | grep -q "session-id" && _ok "fg mode 输出含 --session-id(新 sid)" || _ng "fg 应输出 --session-id,实际:$out" ""
sid=$("$CS" get "$N" sid 2>/dev/null)
[ -n "$sid" ] && _ok "fg mode 后 sid 存 crew-session=$sid" || _ng "fg 后 sid 未存" ""
"$CS" has "$N" fgpid && _ok "fg mode 记 fgpid" || _ng "fg 未记 fgpid" ""
[ "$("$CS" get "$N" notmux)" = "1" ] && _ok "fg mode notmux=1" || _ng "fg mode notmux 应=1" ""

# --- Case 4: fg mode + 已有 sid → resume(不换新)---
echo "--- Case 4: fg 已有 sid → resume ---"
N="${TEST_PREFIX}-c"
"$CS" set "$N" backend mock >/dev/null
"$CS" set "$N" sid "existing-sid-xyz" >/dev/null
out=$("$CL" spawn --name "$N" --mode fg 2>&1)
echo "$out" | grep -q -- "--resume existing-sid-xyz" && _ok "已有 sid → --resume 复用" || _ng "应 --resume 已有 sid,实际:$out" ""

# --- Case 5: --fresh 强制新 sid ---
echo "--- Case 5: --fresh 强制新 sid ---"
N="${TEST_PREFIX}-d"
"$CS" set "$N" backend mock >/dev/null
"$CS" set "$N" sid "should-not-resume" >/dev/null
out=$("$CL" spawn --name "$N" --mode fg --fresh 2>&1)
echo "$out" | grep -q "session-id" && _ok "--fresh 强制 --session-id 新" || _ng "--fresh 应新 sid,实际:$out" ""
echo "$out" | grep -q "should-not-resume" && _ng "--fresh 但仍 resume 老 sid" "" || _ok "--fresh 未 resume 老 sid"

# --- Case 6: policy 注入 → policy_body 文件 + launcher.sh 含 append-system-prompt ---
echo "--- Case 6: policy 注入 ---"
N="${TEST_PREFIX}-e"
"$CS" set "$N" backend mock >/dev/null
"$CS" set "$N" policy aggressive >/dev/null
"$CL" spawn --name "$N" --mode fg >/dev/null 2>&1
[ -f "$CREW_STATE/$N.policy_body" ] && _ok "policy_body 文件生成" || _ng "policy_body 未生成" ""
[ -s "$CREW_STATE/$N.policy_body" ] && _ok "policy_body 非空" || _ng "policy_body 应有内容" ""
launcher="/tmp/crew-launch-$N.sh"
grep -q "append-system-prompt" "$launcher" && _ok "launcher.sh 含 --append-system-prompt" || _ng "launcher.sh 缺 --append-system-prompt" ""
grep -qE 'cat.*'"$N"'\.policy_body' "$launcher" && _ok "launcher.sh 用 \$(cat FILE) 展开 policy" || _ng "launcher.sh 展开方式不对" ""

# --- Case 7: launcher.sh 命令行短(A1 精神,不含长 policy body 原文)---
echo "--- Case 7: launcher.sh 短(policy 走 cat)---"
N="${TEST_PREFIX}-f"
"$CS" set "$N" backend mock >/dev/null
"$CS" set "$N" policy aggressive >/dev/null
"$CL" spawn --name "$N" --mode fg >/dev/null 2>&1
launcher="/tmp/crew-launch-$N.sh"
sz=$(wc -c < "$launcher")
[ "$sz" -lt 800 ] && _ok "launcher.sh 短($sz 字节 < 800)" || _ng "launcher.sh 太长 $sz 字节" ""

# --- Case 8: unknown backend conf 报错 ---
echo "--- Case 8: 未知 backend conf ---"
N="${TEST_PREFIX}-g"
"$CS" set "$N" backend "nonexistent-backend" >/dev/null
out=$("$CL" spawn --name "$N" --mode fg 2>&1) || true
echo "$out" | grep -q "not found" && _ok "未知 backend conf 报 not found" || _ng "未知 backend 应报,实际:$out" ""

# --- Case 9: mode 参数校验 ---
echo "--- Case 9: mode 参数校验 ---"
N="${TEST_PREFIX}-h"
"$CS" set "$N" backend mock >/dev/null
out=$("$CL" spawn --name "$N" --mode bogus 2>&1) || true
echo "$out" | grep -qE "mode.*必须|fg 或 tmux" && _ok "非法 mode 报错" || _ng "非法 mode 应报错,实际:$out" ""

# --- Case 10: tmux mode(真起 tmux,claude=/bin/echo 立退)---
echo "--- Case 10: tmux mode 起 tmux ---"
N="${TEST_PREFIX}-i"
"$CS" set "$N" backend mock >/dev/null
out=$("$CL" spawn --name "$N" --mode tmux 2>&1) || true
# 期望 crew-tmux ensure 后 send-keys 灌 launcher,tmux session 存在
resolved=$("$CT" resolve "$N")
tmux list-sessions -F '#{session_name}' 2>/dev/null | grep -qFx "$resolved" && _ok "tmux mode 起 session '$resolved'" || _ng "tmux mode 未起 session,resolved=$resolved out=$out" ""
[ "$("$CS" get "$N" notmux)" = "0" ] && _ok "tmux mode notmux=0" || _ng "tmux mode notmux 应=0" ""

# --- Case 11: tmux mode + --task 灌初始任务(仅测流程不测 REPL)---
echo "--- Case 11: tmux mode --task ---"
N="${TEST_PREFIX}-j"
"$CS" set "$N" backend mock >/dev/null
out=$("$CL" spawn --name "$N" --mode tmux --task "hello world" 2>&1) || true
echo "$out" | grep -qE "ready" && _ok "tmux mode --task 完成 log 'ready'" || _ng "tmux mode --task 应 ready,实际:$out" ""

echo
echo "=== crew-launcher.test.sh: $pass / $total pass, $fail fail ==="
[ "$fail" -eq 0 ]
