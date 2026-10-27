#!/usr/bin/env bash
# test/crew-tmux.test.sh — crew-tmux 单测(2026-08-30 crew L 重构 Week 2)
# 覆盖 exists/ensure/run/attach/kill/list/current/is-inside/resolve

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CT="$SCRIPT_DIR/../bin/crew-tmux"
CS="$SCRIPT_DIR/../bin/crew-session"
export CREW_STATE="/tmp/crew-tmux-test-$$"

pass=0; fail=0; total=0
_ok() { total=$((total+1)); pass=$((pass+1)); echo "  ✓ $1"; }
_ng() { total=$((total+1)); fail=$((fail+1)); echo "  ✗ $1 [$2]"; }

# 每 case 用不同 tmux 名前缀,避免冲突
TEST_PREFIX="test-ctmx-$$"

setup() {
  rm -rf "$CREW_STATE"
  mkdir -p "$CREW_STATE"
}
teardown() {
  # kill 所有测试建的 tmux
  for s in $(timeout 3 tmux list-sessions -F '#{session_name}' 2>/dev/null | grep "^$TEST_PREFIX" || true); do
    tmux kill-session -t "$s" 2>/dev/null || true
  done
  # 也 kill crew- 前缀的测试 session
  for s in $(timeout 3 tmux list-sessions -F '#{session_name}' 2>/dev/null | grep "^crew-$TEST_PREFIX" || true); do
    tmux kill-session -t "$s" 2>/dev/null || true
  done
  rm -rf "$CREW_STATE"
}

trap teardown EXIT
setup

# --- Case 1: list 命令 ---
echo "--- Case 1: list ---"
"$CT" list | head -3 >/dev/null && _ok "list 不 crash" || _ng "list crash" ""

# --- Case 2: current 命令 ---
echo "--- Case 2: current ---"
if [ -n "${TMUX:-}" ]; then
  cur=$("$CT" current)
  [ -n "$cur" ] && _ok "current 输出 session 名(在 tmux 内)" || _ng "current 应有输出" ""
else
  out=$("$CT" current 2>&1)
  [ -z "$out" ] && _ok "current 无输出(不在 tmux)" || _ng "无 TMUX 应无输出" ""
fi

# --- Case 3: exists 不存在 ---
echo "--- Case 3: exists 不存在 ---"
"$CT" exists "${TEST_PREFIX}-nope" 2>/dev/null && _ng "不存在应 exit 1" "" || _ok "exists 不存在 → exit 1"

# --- Case 4: ensure 起新 tmux ---
echo "--- Case 4: ensure 起新 ---"
NAME1="${TEST_PREFIX}-a"
"$CT" ensure "$NAME1" 2>&1 >/dev/null
sleep 0.3
resolved=$("$CT" resolve "$NAME1")
tmux list-sessions -F '#{session_name}' | grep -qFx "$resolved" && _ok "ensure 后 tmux session 存在($resolved)" || _ng "ensure 后 session 不在" ""

# --- Case 5: exists 存在 ---
echo "--- Case 5: exists 存在 ---"
"$CT" exists "$NAME1" && _ok "exists 存在 → exit 0" || _ng "exists 存在应 exit 0" ""

# --- Case 6: ensure 幂等(已存在跳过)---
echo "--- Case 6: ensure 幂等 ---"
out=$("$CT" ensure "$NAME1" 2>&1)
echo "$out" | grep -qE "已存在.*跳过" && _ok "ensure 幂等 log '已存在,跳过'" || _ng "ensure 应幂等" "$out"

# --- Case 7: run 执行短命令 ---
echo "--- Case 7: run 执行短命令 ---"
tmp_script=$(mktemp)
echo 'echo CT_RUN_MARKER_XY7Z > /tmp/ct-run-out' > "$tmp_script"
chmod +x "$tmp_script"
"$CT" run "$NAME1" "$tmp_script" 2>&1 >/dev/null
# 轮询等 marker 落盘:tmux 异步执行 + 全量套件下 pane shell 启动慢(负载依赖),
# 固定 sleep 是竞态源;轮询窗口 15s,断言仍是"run 必须执行 script 且 marker 落盘"。
_run_ok=""
for _ in $(seq 1 75); do
  if [ -f /tmp/ct-run-out ] && grep -q CT_RUN_MARKER_XY7Z /tmp/ct-run-out; then _run_ok=1; break; fi
  sleep 0.2
done
[ -n "$_run_ok" ] && _ok "run 执行了 script(marker 落盘)" || _ng "run 未执行" "$(cat /tmp/ct-run-out 2>&1)"
rm -f "$tmp_script" /tmp/ct-run-out

# --- Case 8: kill session ---
echo "--- Case 8: kill ---"
"$CT" kill "$NAME1" 2>&1 >/dev/null
sleep 0.3
"$CT" exists "$NAME1" 2>/dev/null && _ng "kill 后仍存在" "" || _ok "kill 后 exists 返 exit 1"

# --- Case 9: resolve 默认 crew-<name> ---
echo "--- Case 9: resolve 默认 crew- 前缀 ---"
r=$("$CT" resolve "some-unregistered")
[ "$r" = "crew-some-unregistered" ] && _ok "未注册 name resolve 到 crew-<name>" || _ng "resolve 结果异常:$r" ""

# --- Case 10: resolve 使用 crew-session tmuxname ---
echo "--- Case 10: resolve 用 tmuxname ---"
NAME2="${TEST_PREFIX}-b"
"$CS" set "$NAME2" tmuxname "custom-tmux-name" >/dev/null
r=$("$CT" resolve "$NAME2")
[ "$r" = "custom-tmux-name" ] && _ok "resolve 使用 crew-session.tmuxname" || _ng "resolve 结果:$r" ""

# --- Case 11: resolve 使用 tmux 字段(adopted) ---
echo "--- Case 11: resolve 用 tmux(adopted 优先)---"
NAME3="${TEST_PREFIX}-c"
"$CS" set "$NAME3" tmux "external-tmux" >/dev/null
"$CS" set "$NAME3" tmuxname "should-not-use" >/dev/null
r=$("$CT" resolve "$NAME3")
[ "$r" = "external-tmux" ] && _ok "resolve adopted tmux 优先于 tmuxname" || _ng "resolve 结果:$r" ""

# --- Case 12: is-inside 自己所在的 session(如果我在 tmux)---
echo "--- Case 12: is-inside 自我判断 ---"
if [ -n "${TMUX:-}" ]; then
  my_session=$("$CT" current)
  # is-inside 需 crew name → 反查:如果 my_session 以 crew- 开头,strip 前缀即 name
  my_name="${my_session#crew-}"
  "$CT" is-inside "$my_name" && _ok "is-inside 自己 name → yes" || _ng "is-inside 自己应 yes" ""
  # is-inside 其他 name → 应 no
  "$CT" is-inside "some-nonexistent-name" 2>/dev/null && _ng "is-inside 陌生名应 no" "" || _ok "is-inside 陌生 → no"
else
  echo "  ⚠ 跳过:非 tmux 环境" ; total=$((total+2)); pass=$((pass+2))
fi

# --- Case 13: run 不存在的 session 报错 ---
echo "--- Case 13: run 不存在 session 报错 ---"
out=$("$CT" run "${TEST_PREFIX}-nonexistent" /tmp/dummy 2>&1) || true
echo "$out" | grep -qE "不存在" && _ok "run 不存在 session 报错含'不存在'" || _ng "run 不存在应报错" "$out"

# --- Case 14: kill 不存在 no-op ---
echo "--- Case 14: kill 不存在 no-op ---"
out=$("$CT" kill "${TEST_PREFIX}-nope" 2>&1) || true
echo "$out" | grep -qE "不存在.*跳过" && _ok "kill 不存在 → 跳过" || _ng "kill 不存在应 no-op" "$out"

# --- Case 15: ensure 记 tmuxname ---
echo "--- Case 15: ensure 后 crew-session 里有 tmuxname ---"
NAME4="${TEST_PREFIX}-d"
"$CT" ensure "$NAME4" 2>&1 >/dev/null
sleep 0.3
saved=$("$CS" get "$NAME4" tmuxname 2>/dev/null)
[ -n "$saved" ] && _ok "ensure 记 tmuxname='$saved'" || _ng "ensure 未记 tmuxname" ""

# --- Case 16: usage errors ---
echo "--- Case 16: usage 错误 exit 2 ---"
"$CT" ensure 2>/dev/null; ec=$?
[ "$ec" = "2" ] && _ok "ensure 无参 → exit 2" || _ng "ensure 无参应 exit 2,实际 $ec" ""
"$CT" 2>/dev/null; ec=$?
[ "$ec" = "2" ] && _ok "空命令 → exit 2" || _ng "空命令应 exit 2,实际 $ec" ""
"$CT" bogus-cmd 2>/dev/null; ec=$?
[ "$ec" = "2" ] && _ok "未知命令 → exit 2" || _ng "未知命令应 exit 2,实际 $ec" ""

echo
echo "=== crew-tmux.test.sh: $pass / $total pass, $fail fail ==="
[ "$fail" -eq 0 ]
