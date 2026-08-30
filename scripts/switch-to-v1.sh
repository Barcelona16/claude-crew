#!/usr/bin/env bash
# switch-to-v1.sh — rollback 到老 crew(2026-08-30 crew L 重构 Week 4)
#
# 从 crew.v1 备份恢复,删除 v2 3 子工具
# 老 backup 目录留着(--clean-backup 才清)

set -euo pipefail

OLD=/work/claude-crew

if [ ! -f "$OLD/bin/crew.v1" ]; then
  echo "[rollback] 无 crew.v1 备份,不能 rollback" >&2
  exit 1
fi

echo "[rollback] 从 crew.v1 恢复 crew"
mv "$OLD/bin/crew.v1" "$OLD/bin/crew"

echo "[rollback] 删除 v2 3 子工具"
rm -f "$OLD/bin/crew-session"
rm -f "$OLD/bin/crew-tmux"
rm -f "$OLD/bin/crew-launcher"

echo "[rollback] 验证"
/root/claude-crew/bin/crew --help 2>&1 | head -3

echo
echo "[rollback] ✓ 已回到 v1(老 crew)"
echo "  bin/ backups 保留在 /work/claude-crew.bin-bak-* 目录,如需清理:rm -rf /work/claude-crew.bin-bak-*"
