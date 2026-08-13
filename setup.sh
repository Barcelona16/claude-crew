#!/usr/bin/env bash
# setup.sh — one-command onboarding for claude-crew's CCR-based multi-model switching.
#
# Cross-platform: macOS (launchd) and Linux (systemd --user). It NEVER embeds your keys —
# you supply your own gateway/API token (prompted or via $GATEWAY_TOKEN), and it stays local
# in ~/.claude-code-router/config.json + ~/.config/claude-crew/keys.conf.
#
# What it does:
#   1. put `crew` on PATH            5. keys.conf + policy + presets
#   2. check deps (node/tmux/py3)    6. merge CCR provider config
#   3. install claude-code-router    7. run CCR + crew-proxy as services
#   4. JD gateway token (local)      8. set the default model preset
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

# Branding: internal (JD) vs open-source values live in setup/branding.sh. make-public.sh
# swaps in branding.public.sh for the GitHub build so this one script serves both versions.
. "$HERE/setup/branding.sh"

say "1) install crew onto PATH"
bash "$HERE/install.sh"

say "2) check dependencies"
have tmux    || info "MISSING tmux — brew install tmux  /  apt install tmux"
have claude  || info "MISSING claude (Claude Code CLI) — https://claude.com/claude-code"
have node    || die  "node is required (for claude-code-router). Install Node.js first."
have python3 || info "MISSING python3 — needed for crew-proxy (key failover). Core still works without it."

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

say "4) $TOKEN_DESC"
TOKEN="${GATEWAY_TOKEN:-}"
if [ -z "$TOKEN" ]; then printf "   %s" "$TOKEN_PROMPT"; read -r TOKEN; fi
[ -n "$TOKEN" ] || die "no token provided"

say "5) merge CCR provider config -> $CCRCFG"
mkdir -p "$CCRDIR"
FILLED="$(mktemp)"; sed "s|__GATEWAY_TOKEN__|$TOKEN|g" "$HERE/setup/$CCR_TEMPLATE" > "$FILLED"
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

say "6) keys.conf + key-policy + model presets"
mkdir -p "$CFG/backends"
if [ -f "$CFG/keys.conf" ]; then info "keys.conf exists — leaving as is"
else { echo "# crew api keys — <alias>=<key>. Use: crew --key <alias> <session>"; echo "gw=$TOKEN"; } > "$CFG/keys.conf"; chmod 600 "$CFG/keys.conf"; info "wrote keys.conf (gw=<your token>)"; fi
if [ -f "$CFG/key-policy.conf" ]; then info "key-policy.conf exists — leaving as is"
else cat > "$CFG/key-policy.conf" <<'EOF'
# crew-proxy key failover policy — one line per model, keys high->low priority.
#   <model> = <alias1> <alias2> ...
# crew-proxy tries the highest-priority healthy key; on repeated upstream failure
# (401/403/429/5xx) it trips that key and transparently retries the next one.
# A model with NO line here just passes through to CCR unchanged (single-key default).
# Each alias must (a) exist in keys.conf and (b) have a CCR provider serving that model
# with that key. Example (after adding gw2 to keys.conf + a CCR provider):
#   GLM-5.2 = gw gw2
EOF
  info "wrote key-policy.conf (empty — single-key passthrough by default)"; fi
# BASE_URL points at crew-proxy (:8788), which routes to CCR (:3456). With no policy line
# for a model, crew-proxy is a transparent passthrough, so single-key users are unaffected.
mkpreset(){ cat > "$CFG/backends/$1.conf" <<EOF
BASE_URL=http://127.0.0.1:8788
MODEL=$2
TOKEN=test
ENV_EXTRA=MAX_THINKING_TOKENS=0
KEY_MODE=ccr
EOF
}
for _p in "${PRESETS[@]}"; do mkpreset "${_p%%|*}" "${_p#*|}"; done
info "wrote $(ls "$CFG"/backends/*.conf 2>/dev/null | wc -l | tr -d ' ') model presets"

say "7) run background services ($OS)"
PY="$(command -v python3 || echo /usr/bin/python3)"
PROXY_SCRIPT="$CFG/crew_proxy.py"
cp "$HERE/setup/crew_proxy.py" "$PROXY_SCRIPT" && info "installed crew-proxy -> $PROXY_SCRIPT"
SVCS="ccr"; have python3 && SVCS="ccr proxy"
fill(){ sed -e "s|__NODE__|$NODE_BIN|g" -e "s|__NODE_DIR__|$NODE_DIR|g" -e "s|__CCR_CLI__|$CCR_CLI|g" -e "s|__PY__|$PY|g" -e "s|__PROXY_SCRIPT__|$PROXY_SCRIPT|g" -e "s|__HOME__|$HOME|g" "$1"; }
port_up(){ (exec 3<>"/dev/tcp/127.0.0.1/$1") 2>/dev/null && { exec 3>&- 3<&-; return 0; }; return 1; }
if [ "$OS" = Darwin ] && command -v launchctl >/dev/null 2>&1; then
  LA="$HOME/Library/LaunchAgents"; mkdir -p "$LA"; uid="$(id -u)"
  for svc in $SVCS; do
    lbl="com.claudecrew.$svc"
    fill "$HERE/setup/launchd/$lbl.plist.tmpl" > "$LA/$lbl.plist" || { info "WARN: can't write $LA/$lbl.plist"; continue; }
    launchctl bootout "gui/$uid/$lbl" 2>/dev/null || true
    launchctl bootstrap "gui/$uid" "$LA/$lbl.plist" 2>/dev/null || launchctl load -w "$LA/$lbl.plist" 2>/dev/null || true
    launchctl kickstart -k "gui/$uid/$lbl" 2>/dev/null || true
  done
  info "launchd agents up ($SVCS)"
elif command -v systemctl >/dev/null 2>&1 && systemctl --user show-environment >/dev/null 2>&1; then
  UD="$HOME/.config/systemd/user"; mkdir -p "$UD"; UNITS=""
  for svc in $SVCS; do fill "$HERE/setup/systemd/claudecrew-$svc.service.tmpl" > "$UD/claudecrew-$svc.service"; UNITS="$UNITS claudecrew-$svc.service"; done
  systemctl --user daemon-reload 2>/dev/null || true
  systemctl --user enable --now $UNITS 2>/dev/null || info "systemctl enable failed — try: loginctl enable-linger $USER, then re-run"
  info "systemd --user units up ($SVCS)"
else
  # headless / container (no launchd, no systemd user bus): launch detached with nohup.
  # No auto-restart — a boot/rebuild script (e.g. your bridge start.sh) should re-launch these.
  info "no launchd/systemd user session — launching detached (nohup, container mode)"
  nsvc(){ local n="$1" p="$2"; shift 2; port_up "$p" && { info "  $n already up (:$p)"; return; }; nohup "$@" >>"$CCRDIR/$n.nohup.log" 2>&1 & disown 2>/dev/null || true; info "  started $n (:$p, pid $!)"; }
  nsvc ccr 3456 "$NODE_BIN" "$CCR_CLI" start
  have python3 && nsvc proxy 8788 "$PY" "$PROXY_SCRIPT"
fi

say "8) default model preset"
case "${SHELL:-}" in */zsh) RC="$HOME/.zshrc";; */bash) RC="$HOME/.bashrc";; *) RC="$HOME/.profile";; esac
grep -q "CREW_BACKEND" "$RC" 2>/dev/null || echo "export CREW_BACKEND=$DEFAULT_BACKEND" >> "$RC"
info "default CREW_BACKEND=$DEFAULT_BACKEND (in $RC)"

say "done ✅"
cat <<EOF

  crew models                        # list all model presets
  crew up                            # ensure CCR (:3456) + crew-proxy (:8788) are up
  crew myproj --model $DEFAULT_BACKEND   # start a session on a model (auto-attaches)

  Notes:
   • Open a new shell (or: source $RC) so CREW_BACKEND takes effect.
   • crew-proxy (:8788) sits in front of CCR and does key failover. With one key it's a
     transparent passthrough. To enable failover: add more keys to $CFG/keys.conf, add a
     matching CCR provider per key, and list them (high->low) in $CFG/key-policy.conf.
EOF
