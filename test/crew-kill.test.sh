#!/usr/bin/env bash
# test/crew-kill.test.sh — crew kill 命令解析测试
# 2026-08-31 修 flag 顺序 bug:`crew kill --purge <name>` 曾把 --purge 当会话名
#
# 策略:不真起 tmux/claude,只往 CREW_STATE 建 state 文件,跑 crew kill,
# 断言 state 文件按预期名字被清、不该被创建的 "--purge" 假会话没落盘。

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CREW="$SCRIPT_DIR/../bin/crew"
CS="$SCRIPT_DIR/../bin/crew-session"

export CREW_STATE="/tmp/crew-kill-test-$$"
export CREW_HOME="/tmp/crew-kill-test-home-$$"
# 兜底:防 kill 自杀检查(在 tmux 里跑测试也不误伤)
export CREW_KILL_ALLOW_SELF=1

pass=0; fail=0; total=0
_ok() { total=$((total+1)); pass=$((pass+1)); echo "  ✓ $1"; }
_ng() { total=$((total+1)); fail=$((fail+1)); echo "  ✗ $1 [$2]"; }

setup() {
  rm -rf "$CREW_STATE" "$CREW_HOME"
  mkdir -p "$CREW_STATE" "$CREW_HOME/backends"
}
teardown() {
  rm -rf "$CREW_STATE" "$CREW_HOME"
}
trap teardown EXIT

# ------------------------------------------------------------------
# Case 1:kill <name> --purge(旧写法,顺序 name → flag)—— 会话应被清
# ------------------------------------------------------------------
setup
echo "--- Case 1: kill <name> --purge(name 在前)---"
"$CS" set target-a backend mock >/dev/null
"$CS" set target-a sid deadbeef-0001 >/dev/null
"$CREW" kill target-a --purge >/dev/null 2>&1
if [ ! -f "$CREW_STATE/target-a.backend" ] && [ ! -f "$CREW_STATE/target-a.sid" ]; then
  _ok "target-a state 已清"
else
  _ng "target-a state 残留" "$(ls $CREW_STATE 2>/dev/null | tr '\n' ' ')"
fi
if [ ! -f "$CREW_STATE/--purge.backend" ] && [ ! -f "$CREW_STATE/---purge.backend" ]; then
  _ok "无 --purge 假会话残留"
else
  _ng "落地了假会话 --purge" ""
fi

# ------------------------------------------------------------------
# Case 2:kill --purge <name>(flag 在前)—— 修 bug 的核心用例
# ------------------------------------------------------------------
setup
echo "--- Case 2: kill --purge <name>(flag 在前,修的核心 case)---"
"$CS" set target-b backend mock >/dev/null
"$CS" set target-b sid deadbeef-0002 >/dev/null
out=$("$CREW" kill --purge target-b 2>&1)
if [ ! -f "$CREW_STATE/target-b.backend" ] && [ ! -f "$CREW_STATE/target-b.sid" ]; then
  _ok "target-b state 已清"
else
  _ng "target-b state 残留(--purge 被误当会话名的老 bug 复发)" "$(ls $CREW_STATE 2>/dev/null | tr '\n' ' ')"
fi
# 关键断言:不能在 log 输出里看到 "deleted session '--purge'"
if echo "$out" | grep -qF "deleted session '--purge'"; then
  _ng "log 显示 deleted '--purge' —— flag 被当成会话名" "$out"
else
  _ok "log 无 deleted '--purge'"
fi
if echo "$out" | grep -qF "deleted session 'target-b'"; then
  _ok "log 正确显示 deleted 'target-b'"
else
  _ng "log 未显示 deleted 'target-b'" "$out"
fi

# ------------------------------------------------------------------
# Case 3:kill <name>(无 flag)—— state 清但 transcript 不动(purge=0)
# ------------------------------------------------------------------
setup
echo "--- Case 3: kill <name> 无 --purge ---"
"$CS" set target-c backend mock >/dev/null
"$CREW" kill target-c >/dev/null 2>&1
if [ ! -f "$CREW_STATE/target-c.backend" ]; then
  _ok "target-c state 已清"
else
  _ng "target-c state 未清" ""
fi

# ------------------------------------------------------------------
# Case 4:kill 没有 name(应报 usage)
# ------------------------------------------------------------------
echo "--- Case 4: kill 无 name ---"
out=$("$CREW" kill --purge 2>&1) ; ec=$?
if [ "$ec" != "0" ] && echo "$out" | grep -qi "usage"; then
  _ok "kill --purge 无 name → 报 usage,非 0 退出"
else
  _ng "kill --purge 无 name 应报 usage(exit=$ec)" "$out"
fi

# ------------------------------------------------------------------
# Case 5:未知 flag 拒绝(防止 typo 被吞成 name)
# ------------------------------------------------------------------
setup
echo "--- Case 5: kill --unknown 拒绝 ---"
"$CS" set target-d backend mock >/dev/null
out=$("$CREW" kill --unknown target-d 2>&1) ; ec=$?
if [ "$ec" != "0" ] && echo "$out" | grep -qi "unknown flag"; then
  _ok "未知 flag 拒绝"
else
  _ng "未知 flag 应拒绝(exit=$ec)" "$out"
fi
# 且 target-d 不应被清(拒绝路径不动 state)
[ -f "$CREW_STATE/target-d.backend" ] && _ok "target-d state 保留(拒绝路径不动)" || _ng "拒绝路径不应清 state" ""

# ------------------------------------------------------------------
# 汇总
# ------------------------------------------------------------------
echo
echo "=== $pass/$total passed, $fail failed ==="
[ "$fail" = "0" ] && exit 0 || exit 1
