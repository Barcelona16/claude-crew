#!/usr/bin/env bash
# martty-plugins/install.sh —— 把 claude-crew 的 Martty 插件装进 ~/.oma/plugins(幂等)
# 用法:bash acp/martty-plugins/install.sh [插件目录名…](不带参装全部)
# 主题列表:claude-code-theme(Claude Code 风格,JIMDB Agent 专用,作者 wangqiwang1)
# 注意:插件只「注册」调色板;要开机即用还需 settings.json 的 theme 键 —— 本脚本默认同步写。
set -euo pipefail
SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OMA_HOME="${MARTTY_HOME:-$HOME/.oma}"
DEST_ROOT="$OMA_HOME/plugins"
mkdir -p "$DEST_ROOT"
names=("$@"); [ $# -eq 0 ] && names=($(find "$SRC" -mindepth 1 -maxdepth 1 -type d -not -name '.*' -exec basename {} \;))
for n in "${names[@]}"; do
  src="$SRC/$n/plugin.json"; [ -f "$src" ] || { echo "✗ 缺 $src"; exit 1; }
  dest="$DEST_ROOT/$n"; mkdir -p "$dest"
  cp "$src" "$dest/plugin.json"
  echo "✓ $n → $dest/plugin.json(martty 内 /theme 或 /plugins 查看)"
  # 主题类插件:默认写 settings.json theme 键(插件 id 调色板名)→ 下次 martty 启动即默认激活
  if python3 -c "import json,sys;exit(0 if json.load(open(sys.argv[1]))['kind']=='theme' else 1)" "$src" 2>/dev/null; then
    pid=$(python3 -c "import json,sys;print(json.load(open(sys.argv[1]))['source']['pluginId'])" "$src")
    pid="${pid#tui-theme-}"
    S="$OMA_HOME/settings.json"
    python3 - "$S" "$pid" <<'PYSET'
import json, sys, os
path, theme_id = sys.argv[1], sys.argv[2]
try:
    d = json.load(open(path))
except Exception:
    d = {}
d['theme'] = theme_id
tmp = path + '.tmp'
with open(tmp, 'w', encoding='utf-8') as f:
    json.dump(d, f, indent=2, ensure_ascii=False)
os.replace(tmp, path)
print(f"✓ settings.json theme → {theme_id}(默认激活)")
PYSET
  fi
done
