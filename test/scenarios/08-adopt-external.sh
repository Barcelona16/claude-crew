#!/usr/bin/env bash
# 08-adopt-external.sh — adopt 收编外部 tmux(不真起 tmux,测状态文件)
"$CREW_BIN" adopt adopt-test mock-tmux-name --sid deadbeef-1234-5678-abcd-000000000000 --dir /tmp 2>&1
echo "---state files---"
ls "$CREW_STATE/" 2>&1 | grep "adopt-test" | sort
echo "---sid---"
cat "$CREW_STATE/adopt-test.sid" 2>&1
echo "---tmux---"
cat "$CREW_STATE/adopt-test.tmux" 2>&1 2>&1 | head
