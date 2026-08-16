#!/usr/bin/env bash
# install.sh — put `crew` on your PATH + wire up the session statusLine.
#   bash install.sh                 # symlink into ~/.local/bin (default) + statusLine
#   PREFIX=/usr/local bash install.sh   # system-wide (may need sudo)
#   bash install.sh --no-statusline # skip touching ~/.claude/settings.json
set -euo pipefail
NO_STATUSLINE=0
for a in "$@"; do case "$a" in --no-statusline) NO_STATUSLINE=1;; esac; done
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
