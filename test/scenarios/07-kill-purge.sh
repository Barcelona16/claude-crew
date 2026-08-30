#!/usr/bin/env bash
# 07-kill-purge.sh — kill 删除 + --purge 连 transcript
"$CREW_BIN" --no-tmux --backend mock kill-test >/dev/null 2>&1
"$CREW_BIN" kill kill-test 2>&1
echo "---after kill state files---"
ls "$CREW_STATE/" 2>&1 | grep "kill-test" || echo "gone"
