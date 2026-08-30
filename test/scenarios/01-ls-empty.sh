#!/usr/bin/env bash
# 01-ls-empty.sh — crew ls 空状态输出格式
# 期望:crew ls 输出 header,列 registry 里的会话(此测无会话)
"$CREW_BIN" ls 2>&1
echo "---exit=$?---"
