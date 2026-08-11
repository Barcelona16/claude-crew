#!/usr/bin/env bash
# setup.sh — one-command onboarding for claude-crew's CCR-based multi-model switching.
#
# Cross-platform: macOS (launchd) and Linux (systemd --user). It NEVER embeds your keys —
# you supply your own JD llm-gw token (prompted or via $GATEWAY_TOKEN), and it stays local
# in ~/.claude-code-router/config.json + ~/.config/claude-crew/keys.conf.
#
# What it does:
#   1. put `crew` on PATH            5. write keys.conf + model presets
#   2. check deps (node/tmux/py3)    6. install joycode proxy
#   3. install claude-code-router    7. run CCR + joycode as launchd/systemd services
#   4. merge CCR provider config     8. set the default model preset
#
# Re-runnable (idempotent-ish): merges providers, backs up existing CCR config, skips keys.conf if present.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
CFG="${XDG_CONFIG_HOME:-$HOME/.config}/claude-crew"
CCRDIR="$HOME/.claude-code-router"
CCRCFG="$CCRDIR/config.json"
OS="$(uname -s)"

say(){ printf '\n\033[1m==> %s\033[0m\n' "$*"; }
info(){ printf '   %s\n' "$*"; }
die(){ printf '\n[setup] ERROR: %s\n' "$*" >&2; exit 1; }
have(){ command -v "$1" >/dev/null 2>&1; }

say "1) install crew onto PATH"
bash "$HERE/install.sh"

say "2) check dependencies"
have tmux    || info "MISSING tmux — brew install tmux  /  apt install tmux"
have claude  || info "MISSING claude (Claude Code CLI) — https://claude.com/claude-code"
have node    || die  "node is required (for claude-code-router). Install Node.js first."
have python3 || info "MISSING python3 — needed only for the joycode proxy"

say "3) claude-code-router (CCR)"
if ! have ccr; then
  info "installing @musistudio/claude-code-router globally (npm i -g)..."
  npm i -g @musistudio/claude-code-router || die "npm install failed — install CCR manually, then re-run."
fi
NODE_BIN="$(command -v node)"; NODE_DIR="$(dirname "$NODE_BIN")"
CCR_CLI="$(npm root -g 2>/dev/null)/@musistudio/claude-code-router/dist/cli.js"
[ -f "$CCR_CLI" ] || CCR_CLI="$(readlink -f "$(command -v ccr)" 2>/dev/null || true)"
[ -f "$CCR_CLI" ] || die "can't locate claude-code-router cli.js (looked in npm global root)"
info "node=$NODE_BIN"; info "ccr cli=$CCR_CLI"

say "4) JD gateway token (your own; stays local)"
TOKEN="${GATEWAY_TOKEN:-}"
if [ -z "$TOKEN" ]; then printf "   Enter your JD llm-gw token: "; read -r TOKEN; fi
[ -n "$TOKEN" ] || die "no token provided"

say "5) merge CCR provider config -> $CCRCFG"
mkdir -p "$CCRDIR"
FILLED="$(mktemp)"; sed "s|__GATEWAY_TOKEN__|$TOKEN|g" "$HERE/setup/ccr-config.template.json" > "$FILLED"
[ -f "$CCRCFG" ] && { cp "$CCRCFG" "$CCRCFG.bak.$$"; info "backed up existing config -> $CCRCFG.bak.$$"; }
CCR_CFG="$CCRCFG" CCR_ADD="$FILLED" node - <<'NODE'
const fs=require("fs");
const add=JSON.parse(fs.readFileSync(process.env.CCR_ADD,"utf8"));
let cfg=null; try{ cfg=JSON.parse(fs.readFileSync(process.env.CCR_CFG,"utf8")); }catch(e){}
if(!cfg){ fs.writeFileSync(process.env.CCR_CFG, JSON.stringify(add,null,2)); console.log("   created fresh CCR config"); process.exit(0); }
cfg.Providers=cfg.Providers||[];
const have=new Set(cfg.Providers.map(p=>p.name)); let n=0;
for(const p of add.Providers){ if(!have.has(p.name)){ cfg.Providers.push(p); n++; } }
if(!cfg.Router||!cfg.Router.default) cfg.Router=add.Router;
cfg.HOST=cfg.HOST||add.HOST; cfg.PORT=cfg.PORT||add.PORT; if(cfg.APIKEY==null)cfg.APIKEY=add.APIKEY;
fs.writeFileSync(process.env.CCR_CFG, JSON.stringify(cfg,null,2));
console.log("   merged "+n+" new provider(s); existing providers left untouched");
NODE
rm -f "$FILLED"

say "6) keys.conf + model presets + joycode proxy"
mkdir -p "$CFG/backends"
if [ -f "$CFG/keys.conf" ]; then info "keys.conf exists — leaving as is"
else { echo "# crew api keys — <alias>=<key>. Use: crew --key <alias> <session>"; echo "gw=$TOKEN"; } > "$CFG/keys.conf"; chmod 600 "$CFG/keys.conf"; info "wrote keys.conf (gw=<your token>)"; fi
[ -f "$HERE/setup/joycode_proxy.py" ] && cp "$HERE/setup/joycode_proxy.py" "$CFG/joycode_proxy.py"
mkpreset(){ cat > "$CFG/backends/$1.conf" <<EOF
BASE_URL=http://127.0.0.1:3456
MODEL=$2
TOKEN=test
ENV_EXTRA=MAX_THINKING_TOKENS=0
KEY_MODE=ccr
EOF
}
mkpreset "Claude-Opus-4.8-joybuilder" "opus,Claude-Opus-4.8-joybuilder"
mkpreset "GLM-5.2"                    "glm,GLM-5.2"
mkpreset "kimi-k3-joybuilder"         "kimi,kimi-k3-joybuilder"
for m in Claude-Opus-4.8-hq Claude-Opus-4.7-hq Claude-Sonnet-4.6-hq Claude-Opus-4.6-hq; do mkpreset "joycode_$m" "joycode,$m"; done
for m in JoyAI-Code-1.5 Kimi-K2.6 GLM-5.2 GLM-5.2-jcloud GLM-5.1 GLM-5 GLM-5-jcloud MiniMax-M3 MiniMax-M2.7 DeepSeek-V4-Pro Doubao-Seed-2.0-pro; do mkpreset "joycode_$m" "joycode-oai,$m"; done
info "wrote $(ls "$CFG"/backends/*.conf 2>/dev/null | wc -l | tr -d ' ') model presets"

say "7) run CCR + joycode as background services ($OS)"
PY="$(command -v python3 || echo /usr/bin/python3)"; PROXY="$CFG/joycode_proxy.py"
fill(){ sed -e "s|__NODE__|$NODE_BIN|g" -e "s|__NODE_DIR__|$NODE_DIR|g" -e "s|__CCR_CLI__|$CCR_CLI|g" -e "s|__PY__|$PY|g" -e "s|__PROXY__|$PROXY|g" -e "s|__HOME__|$HOME|g" "$1"; }
if [ "$OS" = Darwin ]; then
  LA="$HOME/Library/LaunchAgents"; mkdir -p "$LA"; uid="$(id -u)"
  for svc in ccr joycode; do
    lbl="com.claudecrew.$svc"
    fill "$HERE/setup/launchd/$lbl.plist.tmpl" > "$LA/$lbl.plist" || { info "WARN: can't write $LA/$lbl.plist (permission?)"; continue; }
    launchctl bootout "gui/$uid/$lbl" 2>/dev/null || true
    launchctl bootstrap "gui/$uid" "$LA/$lbl.plist" 2>/dev/null || launchctl load -w "$LA/$lbl.plist" 2>/dev/null || true
    launchctl kickstart -k "gui/$uid/$lbl" 2>/dev/null || true
  done
  info "launchd agents: com.claudecrew.ccr / com.claudecrew.joycode"
else
  UD="$HOME/.config/systemd/user"; mkdir -p "$UD"
  fill "$HERE/setup/systemd/claudecrew-ccr.service.tmpl"     > "$UD/claudecrew-ccr.service"
  fill "$HERE/setup/systemd/claudecrew-joycode.service.tmpl" > "$UD/claudecrew-joycode.service"
  systemctl --user daemon-reload 2>/dev/null || true
  systemctl --user enable --now claudecrew-ccr.service claudecrew-joycode.service 2>/dev/null \
    || info "systemctl --user enable failed — run: loginctl enable-linger $USER, then re-run this step."
  info "systemd --user units: claudecrew-ccr / claudecrew-joycode"
fi

say "8) default model preset"
case "${SHELL:-}" in */zsh) RC="$HOME/.zshrc";; */bash) RC="$HOME/.bashrc";; *) RC="$HOME/.profile";; esac
grep -q "CREW_BACKEND" "$RC" 2>/dev/null || echo 'export CREW_BACKEND=Claude-Opus-4.8-joybuilder' >> "$RC"
info "default CREW_BACKEND=Claude-Opus-4.8-joybuilder (in $RC)"

say "done ✅"
cat <<EOF

  crew models                        # list all model presets
  crew up                            # ensure CCR (:3456) + joycode (:8765) are up
  crew myproj --model GLM-5.2        # start a session on a model (auto-attaches)
  crew myproj --model joycode_Kimi-K2.6

  Notes:
   • joycode_* models need you logged in to JoyCode inside VS Code (the proxy reads that session).
   • Open a new shell (or: source $RC) so CREW_BACKEND takes effect.
   • Only ONE gateway token is wired by default; add more keys in $CFG/keys.conf and
     extra CCR providers if you want per-model key switching (crew --key ...).
EOF
