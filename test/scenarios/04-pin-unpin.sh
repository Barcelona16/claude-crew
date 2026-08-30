#!/usr/bin/env bash
# 04-pin-unpin.sh — pin/unpin 状态文件切换
"$CREW_BIN" pin test-pin 2>&1
ls "$CREW_STATE/test-pin.pintmux" 2>&1
"$CREW_BIN" unpin test-pin 2>&1
ls "$CREW_STATE/test-pin.pintmux" 2>&1 || echo "pintmux gone (expected)"
