#!/usr/bin/env bash
# martty-plugins/install.sh —— 把 claude-crew 的 Martty 插件装进 ~/.oma/plugins(幂等)
# 用法:bash acp/martty-plugins/install.sh [插件目录名…](不带参装全部)
# 主题列表:claude-code-theme(Claude Code 风格,JIMDB Agent 专用,作者 wangqiwang1)
set -euo pipefail
SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEST_ROOT="${MARTTY_HOME:-$HOME/.oma}/plugins"
mkdir -p "$DEST_ROOT"
names=("$@"); [ $# -eq 0 ] && names=($(find "$SRC" -mindepth 1 -maxdepth 1 -type d -not -name '.*' -exec basename {} \;))
for n in "${names[@]}"; do
  src="$SRC/$n/plugin.json"; [ -f "$src" ] || { echo "✗ 缺 $src"; exit 1; }
  dest="$DEST_ROOT/$n"; mkdir -p "$dest"
  cp "$src" "$dest/plugin.json"
  echo "✓ $n → $dest/plugin.json(martty 内 /theme 或 /plugins 查看)"
done
