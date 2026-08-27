#!/usr/bin/env bash
# install.sh — put `crew` on your PATH + wire up the session statusLine.
#   bash install.sh                 # symlink into ~/.local/bin (default) + statusLine
#   PREFIX=/usr/local bash install.sh   # system-wide (may need sudo)
#   bash install.sh --no-statusline # skip touching ~/.claude/settings.json
#   bash install.sh --clean-stale   # 装完后清残留会话状态(tmux 死了但 crew 还标 live)
#   bash install.sh --clean-stale --dry-run   # 只打印会清什么,不动
set -euo pipefail
NO_STATUSLINE=0
CLEAN_STALE=0
DRY_RUN=0
for a in "$@"; do case "$a" in
  --no-statusline) NO_STATUSLINE=1;;
  --clean-stale)   CLEAN_STALE=1;;
  --dry-run)       DRY_RUN=1;;
esac; done
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PREFIX="${PREFIX:-$HOME/.local}"
BINDIR="$PREFIX/bin"
mkdir -p "$BINDIR"
ln -sf "$HERE/bin/crew" "$BINDIR/crew"
chmod +x "$HERE/bin/crew"
echo "[install] linked $BINDIR/crew -> $HERE/bin/crew"
case ":$PATH:" in
  *":$BINDIR:"*) echo "[install] $BINDIR is on PATH — run: crew --help" ;;
  *) echo "[install] NOTE: $BINDIR is not on PATH. Add:  export PATH=\"$BINDIR:\$PATH\"" ;;
esac
echo "[install] Backends live in ${XDG_CONFIG_HOME:-\$HOME/.config}/claude-crew/backends/*.conf"
echo "[install] Try a GLM-via-LiteLLM backend: bash examples/glm-litellm/setup.sh"

# --- session statusLine (bottom-of-terminal 'session · model · 🔑key' line) ----
# Point Claude Code's statusLine at crew's script so every session shows its name,
# backend model, and key alias. Idempotent + non-destructive: only the statusLine
# key is touched, and only when it's empty or already points at a crew-statusline.sh
# (so an older jimdb-chaos path auto-migrates to this repo's copy). A third-party
# statusLine is left alone with a hint. Opt out entirely with --no-statusline.
STATUSLINE_SH="$HERE/bin/crew-statusline.sh"
chmod +x "$STATUSLINE_SH" 2>/dev/null || true
if [ "$NO_STATUSLINE" = 1 ]; then
  echo "[install] --no-statusline: leaving ~/.claude/settings.json untouched"
elif command -v node >/dev/null 2>&1; then
  CREW_STATUSLINE_SH="$STATUSLINE_SH" SETTINGS_FILE="$HOME/.claude/settings.json" node -e '
    var fs=require("fs"), path=require("path");
    var sh=process.env.CREW_STATUSLINE_SH, sf=process.env.SETTINGS_FILE, cmd="bash "+sh;
    var s={}; try{ s=JSON.parse(fs.readFileSync(sf,"utf8")); }catch(e){}
    var cur=(s.statusLine&&s.statusLine.command)||"";
    if(cur===cmd){ console.log("[install] statusLine already -> crew script"); process.exit(0); }
    var owns = !cur || /crew-statusline\.sh/.test(cur);  // empty or any crew statusline (incl old path)
    if(!owns){
      console.log("[install] NOTE: settings.json has a third-party statusLine, left as-is:");
      console.log("             "+cur);
      console.log("           to show crew session names, set statusLine.command = "+cmd);
      process.exit(0);
    }
    s.statusLine={type:"command",command:cmd};
    try{ fs.mkdirSync(path.dirname(sf),{recursive:true}); }catch(e){}
    fs.writeFileSync(sf, JSON.stringify(s,null,2)+"\n");
    console.log("[install] statusLine.command -> "+cmd+(cur?"  (migrated from: "+cur+")":"  (new)"));
  ' || echo "[install] WARN: statusLine wiring failed; set statusLine.command = bash $STATUSLINE_SH manually"
else
  echo "[install] node not found; skipping statusLine. Set statusLine.command = bash $STATUSLINE_SH manually"
fi

# --- 清残留会话状态(--clean-stale)-------------------------------------------
# crew ls 判 live 看两处:(1) tmux has-session (2) fgpid 存活。任一命中就 live。
# 残留场景:tmux 已被 kill / 电脑重启后 tmux server 全空,但 crew_state/<name>.sid
# 还在;下次 crew ls 显示 resumable,并没错——问题是 fg_live 分支:.notmux=1 +
# .fgpid 指向早死的 pid → crew 会误报 live(fgpid 复用到别的 pid 就更乱)。
# 这段清:.notmux=1 但 .fgpid 里的 pid 已经不是 claude 进程 → 删 fgpid 让状态如实。
if [ "$CLEAN_STALE" = 1 ]; then
  STATE="${CREW_STATE:-$HOME/.local/share/claude-crew}"
  if [ -d "$STATE" ]; then
    echo "[install] 扫 $STATE 找残留 fgpid…"
    cleaned=0
    for fgf in "$STATE"/*.fgpid; do
      [ -f "$fgf" ] || continue
      nm=$(basename "$fgf" .fgpid)
      pid=$(cat "$fgf" 2>/dev/null | tr -d '[:space:]')
      case "$pid" in ''|*[!0-9]*)
        echo "  [stale] $nm fgpid 内容非数字($pid) → rm"
        [ "$DRY_RUN" = 0 ] && rm -f "$fgf"; cleaned=$((cleaned+1)); continue;;
      esac
      if ! kill -0 "$pid" 2>/dev/null; then
        echo "  [stale] $nm fgpid=$pid 已死 → rm"
        [ "$DRY_RUN" = 0 ] && rm -f "$fgf"; cleaned=$((cleaned+1)); continue
      fi
      # pid 存活但不是 claude(pid 复用到别的进程) → 也算残留
      cmd=$(ps -p "$pid" -o command= 2>/dev/null || true)
      case "$cmd" in
        *claude*) : ;;  # 真是 claude,保留
        *)
          echo "  [stale] $nm fgpid=$pid 存活但非 claude($cmd) → rm"
          [ "$DRY_RUN" = 0 ] && rm -f "$fgf"; cleaned=$((cleaned+1)) ;;
      esac
    done
    if [ "$cleaned" = 0 ]; then
      echo "[install] 无残留 fgpid"
    else
      echo "[install] 清了 $cleaned 条残留 fgpid$([ "$DRY_RUN" = 1 ] && echo ' [dry-run 未真删]')"
    fi
    echo "[install] 建议再跑 'crew prune --dry-run' 看长期闲置(>7d)会话"
  fi
fi
