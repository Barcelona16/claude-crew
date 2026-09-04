#!/bin/bash
# pane-idle-repl-busy.test.sh — paneIdle 加 REPL 忙态检测(2026-09-04)
# 覆盖:
#   1. spinner(✻/✽/Braille)→ non-idle
#   2. "queued messages" 标记 → non-idle
#   3. "Press up to edit" 标记 → non-idle
#   4. 空 ❯ 框且无以上标记 → idle
set -eu

pass=0; fail=0
t() {
  local name="$1"
  if "$2"; then pass=$((pass+1)); echo "✓ $((pass)) $name"
  else fail=$((fail+1)); echo "✗ FAIL $name"; fi
}

TMP=$(mktemp -d /tmp/panetest-XXXX)
trap 'rm -rf "$TMP"; tmux kill-session -t panetest-idle 2>/dev/null || true; tmux kill-session -t panetest-spin 2>/dev/null || true; tmux kill-session -t panetest-queue 2>/dev/null || true' EXIT

# 用一个 tmux fake pane 塞不同内容 · 断言 paneIdle 返 false/true
mk_fake_session() {
  local name="$1" pane_content="$2"
  # 建 fake session · cat 一个 file 让 pane 显示指定内容
  # 真机 Claude REPL 状态行/spinner 在 pane 底部 · 用 5 行 tmux 高度让内容在底部
  local f="$TMP/$name.txt"
  echo -e "$pane_content" > "$f"
  tmux kill-session -t "$name" 2>/dev/null || true
  tmux new-session -d -s "$name" -x 200 -y 5 "cat '$f' && sleep 300"
  sleep 0.3
}

# ---- 1. 空 ❯ 框 · idle ----
test_case_idle_empty_prompt() {
  mk_fake_session "panetest-idle" $'some output\n❯ \n\n  session-footer'
  local r
  r=$(node -e "console.log(require('/work/claude-crew/bin/crew-wake.js').paneIdle('panetest-idle'))")
  [ "$r" = "true" ]
}
t "case-1 空 ❯ 框 · paneIdle=true" test_case_idle_empty_prompt

# ---- 2. 活 spinner(动作词+秒计数)· non-idle ----
test_case_busy_working_with_secs() {
  mk_fake_session "panetest-spin" $'✻ Working… (15s · ↓ 1.2k tokens)\n❯ \n\n  footer'
  local r
  r=$(node -e "console.log(require('/work/claude-crew/bin/crew-wake.js').paneIdle('panetest-spin'))")
  [ "$r" = "false" ]
}
t "case-2 Working…(15s) · paneIdle=false" test_case_busy_working_with_secs

# ---- 3. Frolicking + 秒计数 · non-idle ----
test_case_busy_frolicking() {
  mk_fake_session "panetest-spin" $'· Frolicking… (10s · ↓ 32 tokens)\n❯ \n\n  footer'
  local r
  r=$(node -e "console.log(require('/work/claude-crew/bin/crew-wake.js').paneIdle('panetest-spin'))")
  [ "$r" = "false" ]
}
t "case-3 Frolicking…(10s) · paneIdle=false" test_case_busy_frolicking

# ---- 3a. "Churned for X · done" 是结束标记 · idle(关键 case) ----
test_case_churned_done_is_idle() {
  mk_fake_session "panetest-done" $'✻ Churned for 7m 34s · done 5:23 PM\n❯ \n\n  footer'
  local r
  r=$(node -e "console.log(require('/work/claude-crew/bin/crew-wake.js').paneIdle('panetest-done'))")
  [ "$r" = "true" ]
}
t "case-3a Churned for X · done · paneIdle=true(★关键)" test_case_churned_done_is_idle

# ---- 4. queued messages 标记 · non-idle ----
test_case_busy_queued_msg() {
  mk_fake_session "panetest-queue" $'work done\n❯ Press up to edit queued messages\n\n  footer'
  local r
  r=$(node -e "console.log(require('/work/claude-crew/bin/crew-wake.js').paneIdle('panetest-queue'))")
  [ "$r" = "false" ]
}
t "case-4 queued messages 标记 · paneIdle=false" test_case_busy_queued_msg

# ---- 5. crew-heartbeat 版本同步(源码断言) ----
test_case_heartbeat_synced() {
  grep -q 'queued messages' /work/claude-crew/bin/crew-heartbeat.js
  grep -q 'BUSY_RE' /work/claude-crew/bin/crew-heartbeat.js
  grep -q 'Frolicking' /work/claude-crew/bin/crew-heartbeat.js
}
t "case-5 crew-heartbeat paneIdle 也含 BUSY_RE + queued 检测" test_case_heartbeat_synced

# ---- 6. crew-wake.js 版本一致(不用 require · 避免子孙耦合;两份手工同步 A5) ----
test_case_wake_syntax() {
  node -c /work/claude-crew/bin/crew-wake.js
  node -c /work/claude-crew/bin/crew-heartbeat.js
}
t "case-6 crew-wake + crew-heartbeat 语法过" test_case_wake_syntax

echo
if [ "$fail" -gt 0 ]; then echo "FAIL: $fail failed"; exit 1; fi
echo "ALL PASS $pass"
