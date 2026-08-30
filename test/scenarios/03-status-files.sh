#!/usr/bin/env bash
# 03-status-files.sh — 起会话后 state 文件形态
"$CREW_BIN" --no-tmux --backend mock mock-test2 >/dev/null 2>&1
echo "---state files---"
ls -1 "$CREW_STATE/" 2>&1 | sort
echo "---.backend---"
cat "$CREW_STATE/mock-test2.backend" 2>&1 | head
echo "---.notmux---"
cat "$CREW_STATE/mock-test2.notmux" 2>&1 | head
