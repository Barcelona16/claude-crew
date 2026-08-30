#!/usr/bin/env bash
# 05-doctor.sh — crew doctor 输出(仅关注格式,不管实际 drift)
"$CREW_BIN" doctor 2>&1 | head -30
echo "---exit=$?---"
