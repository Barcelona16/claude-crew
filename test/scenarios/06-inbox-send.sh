#!/usr/bin/env bash
# 06-inbox-send.sh — inbox 队列
# 起会话 → send message → inbox 查
"$CREW_BIN" --no-tmux --backend mock inbox-test >/dev/null 2>&1
"$CREW_BIN" send inbox-test "hello world" 2>&1
echo "---peek---"
"$CREW_BIN" inbox inbox-test --peek 2>&1 | head -10
echo "---consume---"
"$CREW_BIN" inbox inbox-test 2>&1 | head -10
echo "---after consume peek---"
"$CREW_BIN" inbox inbox-test --peek 2>&1 | head -10
