#!/usr/bin/env bash
# setup.sh — one-command onboarding for claude-crew's CCR 3-based multi-model switching.
#
# Cross-platform: macOS (launchd) and Linux (systemd --user). It NEVER embeds your keys —
# you supply your own gateway/API token (prompted or via $GATEWAY_TOKEN), and it stays local
# in ~/.config/claude-crew/ccr-providers.json + ~/.config/claude-crew/keys.conf.
#
# What it does:
#   1. put `crew` on PATH            5. keys.conf + policy + presets
#   2. check deps (Node 22/tmux/py3) 6. write crew provider map
#   3. install claude-code-router    7. run CCR + crew-proxy as services
#   4. JD gateway token (local)      8. set the default model preset
#
# Re-runnable (idempotent-ish): merges providers, backs up the provider map, skips keys.conf if present.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
CFG="${XDG_CONFIG_HOME:-$HOME/.config}/claude-crew"
CCRDIR="$HOME/.claude-code-router"
CCRCFG="$CFG/ccr-providers.json"
CCR_WEB_PORT="${CREW_CCR_WEB_PORT:-3458}"
CCR_GATEWAY_PORT="${CREW_CCR_PORT:-3456}"
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
have node    || die  "node is required (for claude-code-router). Install Node.js 22 or newer first."
have python3 || die "python3 is required by the CCR 3 provider-map adapter."
NODE_BIN="$(command -v node)"
NODE_MAJOR="$($NODE_BIN -p 'process.versions.node.split(".")[0]' 2>/dev/null || echo 0)"
case "$NODE_MAJOR" in ''|*[!0-9]*) die "cannot determine Node.js version";; esac
[ "$NODE_MAJOR" -ge 22 ] || die "CCR 3 requires Node.js >=22 (found $(node --version))"

say "3) claude-code-router (CCR)"
info "installing/updating @musistudio/claude-code-router@^3 globally (npm i -g)..."
npm i -g '@musistudio/claude-code-router@^3' || die "npm install failed — install CCR 3 manually, then re-run."
have ccr || die "CCR 3 installation completed but ccr is not on PATH"
NODE_DIR="$(dirname "$NODE_BIN")"
CCR_CLI="$(npm root -g 2>/dev/null)/@musistudio/claude-code-router/dist/main/cli.js"
[ -f "$CCR_CLI" ] || CCR_CLI="$(readlink -f "$(command -v ccr)" 2>/dev/null || true)"
[ -f "$CCR_CLI" ] || die "can't locate claude-code-router cli.js (looked in npm global root)"
info "node=$NODE_BIN"; info "ccr cli=$CCR_CLI"

say "4) $TOKEN_DESC"
TOKEN="${GATEWAY_TOKEN:-}"
if [ -z "$TOKEN" ]; then printf "   %s" "$TOKEN_PROMPT"; read -r TOKEN; fi
[ -n "$TOKEN" ] || die "no token provided"

say "5) merge CCR 3 provider map -> $CCRCFG"
mkdir -p "$CFG" "$CCRDIR"
umask 077
CCR_WEB_TOKEN_FILE="$CFG/ccr-web-token"
if [ -s "$CCR_WEB_TOKEN_FILE" ]; then
  CCR_WEB_TOKEN="$(cat "$CCR_WEB_TOKEN_FILE")"
else
  CCR_WEB_TOKEN="$(python3 -c 'import secrets; print(secrets.token_urlsafe(32))')"
  printf '%s\n' "$CCR_WEB_TOKEN" > "$CCR_WEB_TOKEN_FILE"
  chmod 600 "$CCR_WEB_TOKEN_FILE"
fi
[ -n "$CCR_WEB_TOKEN" ] || die "CCR web token is empty: $CCR_WEB_TOKEN_FILE"
[ -f "$CCRCFG" ] && { cp "$CCRCFG" "$CCRCFG.bak.$$"; info "backed up existing provider map -> $CCRCFG.bak.$$"; }
CCR_PROVIDER_MAP="$CCRCFG" CCR_TEMPLATE_FILE="$HERE/setup/$CCR_TEMPLATE" GATEWAY_TOKEN="$TOKEN" python3 - <<'PY'
import copy, json, os, secrets
from pathlib import Path

dst = Path(os.environ["CCR_PROVIDER_MAP"])
template = json.loads(Path(os.environ["CCR_TEMPLATE_FILE"]).read_text())
token = os.environ["GATEWAY_TOKEN"]

def fill(value):
    if isinstance(value, str):
        return value.replace("__GATEWAY_TOKEN__", token)
    if isinstance(value, list):
        return [fill(item) for item in value]
    if isinstance(value, dict):
        return {key: fill(item) for key, item in value.items()}
    return value

template = fill(template)
try:
    existing = json.loads(dst.read_text())
except (OSError, json.JSONDecodeError):
    existing = {}
if not isinstance(existing, dict):
    existing = {}
gateway = existing.get("gateway") if isinstance(existing.get("gateway"), dict) else {}
gateway = copy.deepcopy(gateway)
gateway.setdefault("api_key", "crew-" + secrets.token_urlsafe(32))
template["gateway"] = gateway
old = existing.get("Providers") or existing.get("providers") or []
by_name = {p.get("name"): p for p in old if isinstance(p, dict) and p.get("name")}
for provider in template.get("Providers", []):
    if isinstance(provider, dict) and provider.get("name"):
        by_name.setdefault(provider["name"], provider)
template["Providers"] = list(by_name.values())
if isinstance(existing.get("Router"), dict):
    template["Router"] = existing["Router"]
dst.write_text(json.dumps(template, indent=2) + "\n")
os.chmod(dst, 0o600)
print("   wrote %d provider(s) to crew-owned CCR 3 map" % len(template["Providers"]))
PY

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
#   default = gw gw2
EOF
  info "wrote key-policy.conf (empty — single-key passthrough by default)"; fi
# BASE_URL points at crew-proxy (:8788), which routes to CCR (:3456). With no policy line
# for a model, crew-proxy is a transparent passthrough, so single-key users are unaffected.
mkpreset(){
  [ -e "$CFG/backends/$1.conf" ] && { info "preset $1 exists — leaving as is"; return; }
  cat > "$CFG/backends/$1.conf" <<EOF
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
CCR_ADAPTER="$CFG/ccr_v3.py"
cp "$HERE/setup/crew_proxy.py" "$PROXY_SCRIPT" && info "installed crew-proxy -> $PROXY_SCRIPT"
cp "$HERE/setup/ccr_v3.py" "$CCR_ADAPTER" && info "installed CCR 3 adapter -> $CCR_ADAPTER"
# Never import/execute an installed proxy to discover its signing secret.
JOYCODE_SCRIPT="$CFG/joycode_proxy.py"
JOYCODE_SECRET_FILE="${JOYCODE_HMAC_SECRET_FILE:-$CFG/joycode-hmac-secret}"
JOYCODE_TIMEOUT="${JOYCODE_UPSTREAM_TIMEOUT:-300}"
JOYCODE_PORT="${JOYCODE_PORT:-8765}"
JOYCODE_READY=0
if JOYCODE_INSTALL_DIR="$CFG" JOYCODE_SOURCE_DIR="$HERE/setup" \
   JOYCODE_UPSTREAM_TIMEOUT="$JOYCODE_TIMEOUT" JOYCODE_PORT="$JOYCODE_PORT" \
   JOYCODE_HMAC_SECRET_FILE="$JOYCODE_SECRET_FILE" python3 - <<'PY'
import ast, os, stat, tempfile
from pathlib import Path

cfg = Path(os.environ['JOYCODE_INSTALL_DIR'])
src = Path(os.environ['JOYCODE_SOURCE_DIR'])
dst = cfg / 'joycode_proxy.py'
keyfile = Path(os.environ['JOYCODE_HMAC_SECRET_FILE'])

def stop(message):
    print('   JoyCode: ' + message)
    raise SystemExit(1)

def literal_secret(path):
    tree = ast.parse(path.read_text())
    writes = [n for n in ast.walk(tree) if isinstance(n, ast.Name)
              and n.id == 'HMAC_SECRET' and isinstance(n.ctx, ast.Store)]
    assignments = [n for n in tree.body if isinstance(n, (ast.Assign, ast.AnnAssign))
                   and any(isinstance(t, ast.Name) and t.id == 'HMAC_SECRET'
                           for t in (n.targets if isinstance(n, ast.Assign) else [n.target]))]
    if len(writes) != 1 or len(assignments) != 1:
        raise ValueError()
    value = assignments[0].value
    if isinstance(value, ast.Constant) and isinstance(value.value, str) and value.value.strip():
        return value.value
    # Known environment/file-based installs need no source-secret migration.
    strings = {n.value for n in ast.walk(value) if isinstance(n, ast.Constant)
               and isinstance(n.value, str)}
    if path.read_bytes() == (src / 'joycode_proxy.py').read_bytes():
        return None
    # Recognize our file-loader format across future source upgrades without executing it.
    if (isinstance(value, ast.Call) and isinstance(value.func, ast.Name)
            and value.func.id == '_load_hmac_secret' and not value.args and not value.keywords
            and any(isinstance(n, ast.FunctionDef) and n.name == '_load_hmac_secret'
                    for n in tree.body)):
        return None
    if (isinstance(value, ast.Call) and isinstance(value.func, ast.Attribute)
            and value.func.attr == 'get' and isinstance(value.func.value, ast.Attribute)
            and value.func.value.attr == 'environ'
            and isinstance(value.func.value.value, ast.Name)
            and value.func.value.value.id == 'os'
            and not value.keywords and 1 <= len(value.args) <= 2
            and isinstance(value.args[0], ast.Constant)
            and value.args[0].value == 'JOYCODE_HMAC_SECRET'):
        if len(value.args) == 1:
            return None
        default = value.args[1]
        if isinstance(default, ast.Constant) and isinstance(default.value, str):
            return default.value or None
    raise ValueError()

try:
    timeout = int(os.environ['JOYCODE_UPSTREAM_TIMEOUT'])
    port = int(os.environ['JOYCODE_PORT'])
    if timeout <= 0 or not 1 <= port <= 65535:
        stop('invalid timeout/port; kept installed proxy/service unchanged.')
    old_secret = literal_secret(dst) if dst.exists() else None
    supplied = os.environ.get('JOYCODE_HMAC_SECRET') or None
    stored = None
    if keyfile.exists() or keyfile.is_symlink():
        st = keyfile.lstat()
        if not stat.S_ISREG(st.st_mode) or st.st_uid != os.getuid():
            raise ValueError()
        stored = keyfile.read_text().strip() or None
        os.chmod(keyfile, 0o600)
    if old_secret and any(v and v != old_secret for v in (supplied, stored)):
        raise ValueError()
    secret = supplied or stored or old_secret
    if secret and (not secret.strip() or secret != secret.strip()):
        raise ValueError()
    if secret and (supplied or not stored):
        # Persist environment-only credentials so service managers need no secret in templates.
        fd, tmp = tempfile.mkstemp(prefix='.joycode-secret-', dir=keyfile.parent)
        with os.fdopen(fd, 'w') as f:
            os.fchmod(f.fileno(), 0o600)
            f.write(secret + '\n')
            f.flush()
            os.fsync(f.fileno())
        os.replace(tmp, keyfile)
    if dst.exists() and not secret:
        stop('no usable secret; kept installed proxy and service unchanged. Configure JOYCODE_HMAC_SECRET_FILE and rerun.')
    tree = ast.parse((src / 'joycode_proxy.py').read_text())
    strings = {n.value for n in ast.walk(tree) if isinstance(n, ast.Constant)
               and isinstance(n.value, str)}
    if secret and not {'JOYCODE_HMAC_SECRET_FILE', 'JOYCODE_UPSTREAM_TIMEOUT'} <= strings:
        stop('repository proxy lacks secret-file/timeout support; kept installed proxy/service. Upgrade the repository proxy, then rerun.')
    # Copy only after migration checks; keep the existing helper on any failed check.
    for name in ('_responses_compat.py', 'joycode_proxy.py'):
        content = (src / name).read_bytes()
        fd, tmp = tempfile.mkstemp(prefix='.joycode-install-', dir=cfg)
        with os.fdopen(fd, 'wb') as f:
            f.write(content)
        os.replace(tmp, cfg / name)
    if not secret:
        stop('proxy installed but service skipped: provide JOYCODE_HMAC_SECRET or a nonempty 0600 JOYCODE_HMAC_SECRET_FILE, then rerun.')
    print('   JoyCode: proxy/helper installed; signing secret stored separately (0600).')
except (OSError, ValueError, SyntaxError):
    stop('migration unsafe or failed; kept existing proxy/service. Manually move the existing signing secret to a user-owned 0600 file, set JOYCODE_HMAC_SECRET_FILE, and rerun; do not overwrite the installed proxy first.')
PY
then
  JOYCODE_READY=1
fi
SVCS="ccr proxy"
[ "$JOYCODE_READY" = 1 ] && SVCS="$SVCS joycode"
fill(){
  case "$1" in *joycode*)
    JOYCODE_TEMPLATE="$1" JOYCODE_PY="$PY" JOYCODE_SCRIPT="$JOYCODE_SCRIPT" \
    CREW_HOME="$CFG" JOYCODE_HMAC_SECRET_FILE="$JOYCODE_SECRET_FILE" \
    JOYCODE_UPSTREAM_TIMEOUT="$JOYCODE_TIMEOUT" JOYCODE_PORT="$JOYCODE_PORT" python3 - <<'PY'
import os, plistlib
from pathlib import Path
p = Path(os.environ['JOYCODE_TEMPLATE'])
values = {'__PY__': os.environ['JOYCODE_PY'], '__HOME__': os.environ['HOME'],
          '__JOYCODE_SCRIPT__': os.environ['JOYCODE_SCRIPT'],
          '__CREW_CONFIG_DIR__': os.environ['CREW_HOME'],
          '__JOYCODE_SECRET_FILE__': os.environ['JOYCODE_HMAC_SECRET_FILE'],
          '__JOYCODE_TIMEOUT__': os.environ['JOYCODE_UPSTREAM_TIMEOUT'],
          '__JOYCODE_PORT__': os.environ['JOYCODE_PORT']}
if '.plist.' in p.name:
    def fill(v):
        if isinstance(v, str):
            for key, value in values.items():
                v = v.replace(key, value)
        elif isinstance(v, list):
            v = [fill(x) for x in v]
        elif isinstance(v, dict):
            v = {k: fill(x) for k, x in v.items()}
        return v
    print(plistlib.dumps(fill(plistlib.loads(p.read_bytes()))).decode(), end='')
else:
    text = p.read_text()
    for key, value in values.items():
        # systemd quotes do not suppress specifiers; escape percent and control chars too.
        value = value.replace('%', '%%').replace('\\', '\\\\').replace('"', '\\"')
        value = value.replace('\n', '\\n').replace('\r', '\\r').replace('\t', '\\t')
        text = text.replace(key, value)
    print(text, end='')
PY
    return $?;;
  esac
  sed -e "s|__NODE__|$NODE_BIN|g" -e "s|__NODE_DIR__|$NODE_DIR|g" -e "s|__CCR_CLI__|$CCR_CLI|g" -e "s|__PY__|$PY|g" -e "s|__PROXY_SCRIPT__|$PROXY_SCRIPT|g" -e "s|__HOME__|$HOME|g" -e "s|__CREW_CONFIG_DIR__|$CFG|g" -e "s|__CCR_PROVIDER_MAP__|$CCRCFG|g" -e "s|__CCR_ADAPTER__|$CCR_ADAPTER|g" -e "s|__CCR_WEB_TOKEN__|$CCR_WEB_TOKEN|g" -e "s|__CCR_WEB_PORT__|$CCR_WEB_PORT|g" -e "s|__CCR_GATEWAY_PORT__|$CCR_GATEWAY_PORT|g" "$1"; }
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
  for svc in $SVCS; do
    fill "$HERE/setup/systemd/claudecrew-$svc.service.tmpl" > "$UD/claudecrew-$svc.service" || { info "WARN: can't render $svc unit"; continue; }
    UNITS="$UNITS claudecrew-$svc.service"
  done
  systemctl --user daemon-reload 2>/dev/null || true
  systemctl --user enable --now $UNITS 2>/dev/null || info "systemctl enable failed — try: loginctl enable-linger $USER, then re-run"
  info "systemd --user units up ($SVCS)"
else
  # headless / container (no launchd, no systemd user bus): launch detached with nohup.
  # No auto-restart — a boot/rebuild script (e.g. your bridge start.sh) should re-launch these.
  info "no launchd/systemd user session — launching detached (nohup, container mode)"
  nsvc(){ local n="$1" p="$2"; shift 2; port_up "$p" && { info "  $n already up (:$p)"; return; }; nohup "$@" >>"$CCRDIR/$n.nohup.log" 2>&1 & disown 2>/dev/null || true; info "  started $n (:$p, pid $!)"; }
  nsvc ccr "$CCR_WEB_PORT" env "CCR_WEB_AUTH_TOKEN=$CCR_WEB_TOKEN" "$NODE_BIN" "$CCR_CLI" start --no-open --port "$CCR_WEB_PORT"
  have python3 && nsvc proxy 8788 "$PY" "$PROXY_SCRIPT"
  if [ "$JOYCODE_READY" = 1 ]; then
    nsvc joycode "$JOYCODE_PORT" env -u JOYCODE_HMAC_SECRET \
      "CREW_HOME=$CFG" "CREW_CONFIG_DIR=$CFG" \
      "JOYCODE_HMAC_SECRET_FILE=$JOYCODE_SECRET_FILE" \
      "JOYCODE_UPSTREAM_TIMEOUT=$JOYCODE_TIMEOUT" "JOYCODE_PORT=$JOYCODE_PORT" \
      "$PY" "$JOYCODE_SCRIPT"
  fi
fi

say "8) apply provider map through CCR 3 RPC"
for _ in $(seq 1 30); do port_up "$CCR_WEB_PORT" && break; sleep 1; done
port_up "$CCR_WEB_PORT" || die "CCR 3 management service did not start on :$CCR_WEB_PORT"
CREW_CCR_WEB_URL="http://127.0.0.1:$CCR_WEB_PORT" CREW_CCR_WEB_TOKEN="$CCR_WEB_TOKEN" CREW_CCR_PORT="$CCR_GATEWAY_PORT" \
  python3 "$CCR_ADAPTER" apply --provider-map "$CCRCFG" || die "CCR 3 provider-map apply failed"

say "9) default model preset"
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
   • crew-proxy (:8788) sits in front of CCR 3 (:3456) and does key failover. With one key
     it is a transparent passthrough. To enable failover: add more keys to $CFG/keys.conf,
     add matching providers to $CCRCFG, then list them (high->low) in $CFG/key-policy.conf.
EOF
