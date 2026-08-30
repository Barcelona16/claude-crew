#!/usr/bin/env bash
# switch-to-v2.sh — 切换到 crew v2(2026-08-30 crew L 重构 Week 4)
#
# 策略:最小侵入 —— 只替换 /work/claude-crew/bin/crew 主命令 + 加 3 个子工具
# 不动老目录其他文件(LICENSE/README/install.sh/backends/等)
# rollback:switch-to-v1.sh

set -euo pipefail

OLD=/work/claude-crew
V2=/work/claude-crew-v2
BACKUP=/work/claude-crew.bin-bak-$(date +%s)

echo "[switch] 备份老 bin/ 到 $BACKUP"
cp -a "$OLD/bin" "$BACKUP"

echo "[switch] 备份老 crew 主命令为 $OLD/bin/crew.v1"
cp -a "$OLD/bin/crew" "$OLD/bin/crew.v1"

echo "[switch] 复制 v2 4 个 bin 到 $OLD/bin/"
cp -a "$V2/bin/crew" "$OLD/bin/crew"
cp -a "$V2/bin/crew-session" "$OLD/bin/crew-session"
cp -a "$V2/bin/crew-tmux" "$OLD/bin/crew-tmux"
cp -a "$V2/bin/crew-launcher" "$OLD/bin/crew-launcher"

# 保留符号链接 crew-v1-reference 移除(不必要)
rm -f "$OLD/bin/crew-v1-reference"

echo "[switch] 验证 syntax"
bash -n "$OLD/bin/crew" && echo "  crew ✓"
bash -n "$OLD/bin/crew-session" && echo "  crew-session ✓"
bash -n "$OLD/bin/crew-tmux" && echo "  crew-tmux ✓"
bash -n "$OLD/bin/crew-launcher" && echo "  crew-launcher ✓"

echo "[switch] 验证 version"
/root/claude-crew/bin/crew version

echo
echo "[switch] ✓ 切换完成"
echo "  rollback: bash $(dirname "$0")/switch-to-v1.sh"
echo "  backup:   $BACKUP"
echo "  v1 crew:  $OLD/bin/crew.v1"
