#!/bin/bash
# crew-deploy.sh — sync claude-crew python runtime files from repo to ~/.config/claude-crew
# and restart the affected launchd services, idempotently.
#
# Usage:
#   bin/crew-deploy.sh            # apply mode: sync changed files, restart affected services, verify
#   bin/crew-deploy.sh --check   # read-only: print planned diffs + restarts, do nothing
#
# Syncs (from $REPO/setup/ -> ~/.config/claude-crew/, install -m 644, md5-gated):
#   crew_proxy.py, _crew_*.py              -> restart com.claudecrew.proxy  (:8788)
#   joycode_proxy.py, _responses_compat.py -> restart com.claudecrew.joycode (:8765)
#   ccr_v3.py                              -> restart com.claudecrew.ccr   (:3456/:3458)
#
# Guarantees:
#   - py_compile every repo file before touching the target; abort on any failure.
#   - Skip files whose md5 matches (no churn, no unnecessary restarts).
#   - Clear __pycache__ entries for modules that were replaced.
#   - Restart only the services whose files actually changed.
#   - Post-restart: PID present, port LISTEN, new err-log tail has no traceback.
#
# Tested on macOS system bash 3.2 (no associative arrays).

set -eu

CHECK=0
[ "${1:-}" = "--check" ] && CHECK=1

# --- paths -------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
SRC_DIR="$REPO_DIR/setup"
DST_DIR="$HOME/.config/claude-crew"
PYTHON="${CREW_DEPLOY_PYTHON:-/opt/homebrew/bin/python3}"
PLIST_DIR="$HOME/Library/LaunchAgents"

CREW_FILES="crew_proxy.py _crew_config.py _crew_windows.py _crew_breaker.py _crew_stats.py _crew_server.py _crew_handler.py"
JOYCODE_FILES="joycode_proxy.py _responses_compat.py"
CCR_FILES="ccr_v3.py"

# group -> "service_label:portlist"
group_spec() {
  case "$1" in
    crew)    echo "com.claudecrew.proxy:8788" ;;
    joycode) echo "com.claudecrew.joycode:8765" ;;
    ccr)     echo "com.claudecrew.ccr:3456,3458" ;;
  esac
}

# --- preflight ---------------------------------------------------------------
[ -d "$SRC_DIR" ] || { echo "ERROR: src dir missing: $SRC_DIR" >&2; exit 1; }
mkdir -p "$DST_DIR"

changed_crew=0
changed_joycode=0
changed_ccr=0
changed_list=""   # space-separated filenames that were replaced (for pycache purge)

echo "== crew-deploy: repo=$REPO_DIR  dst=$DST_DIR  mode=$([ $CHECK = 1 ] && echo CHECK || echo APPLY)"

# --- 1+2: compile gate, md5-gated install -----------------------------------
sync_group() {
  # $1 = group name, $2 = flag var name, rest = files
  local group="$1"; local flagvar="$2"; shift 2
  local f src dst sh dh
  for f in "$@"; do
    src="$SRC_DIR/$f"
    dst="$DST_DIR/$f"
    [ -f "$src" ] || { echo "ERROR: source missing: $src" >&2; exit 1; }

    # compile gate — never deploy a broken file
    if ! "$PYTHON" -m py_compile "$src" 2>/tmp/crew-deploy-pyc.err; then
      echo "ERROR: py_compile failed for $src — aborting." >&2
      cat /tmp/crew-deploy-pyc.err >&2
      exit 1
    fi

    sh=$(md5 -q "$src")
    if [ -f "$dst" ]; then dh=$(md5 -q "$dst"); else dh=""; fi

    if [ "$sh" = "$dh" ]; then
      echo "  skip  $f (md5 identical)"
      continue
    fi

    if [ $CHECK = 1 ]; then
      echo "  would-install $f  (src=$sh ${dh:+(dst=$dh)}${dh:-+dst=MISSING})"
    else
      echo "  install $f  (src=$sh ${dh:+(old=$dh)}${dh:-+MISSING})"
      install -m 644 "$src" "$dst"
    fi
    eval "$flagvar=1"
    changed_list="$changed_list $f"
  done
}

echo "-- syncing crew group (proxy)"
sync_group crew changed_crew $CREW_FILES
echo "-- syncing joycode group"
sync_group joycode changed_joycode $JOYCODE_FILES
echo "-- syncing ccr group"
sync_group ccr changed_ccr $CCR_FILES

# --- 3: pycache purge for replaced modules -----------------------------------
if [ -n "$changed_list" ] && [ $CHECK = 0 ]; then
  pc="$DST_DIR/__pycache__"
  if [ -d "$pc" ]; then
    for f in $changed_list; do
      mod="${f%.py}"
      find "$pc" -maxdepth 1 -name "${mod}.*.pyc" -delete 2>/dev/null || true
    done
  fi
fi

# --- 4: decide restarts ------------------------------------------------------
to_restart=""
[ $changed_crew    = 1 ] && to_restart="$to_restart crew"
[ $changed_joycode  = 1 ] && to_restart="$to_restart joycode"
[ $changed_ccr     = 1 ] && to_restart="$to_restart ccr"

if [ -z "$to_restart" ]; then
  if [ $CHECK = 1 ]; then
    echo "-- check: nothing to sync, no restarts planned."
  else
    echo "== already up to date — no files changed, no restarts."
  fi
  exit 0
fi

echo "-- planned restarts:$to_restart"

# --- 5: restart + verify -----------------------------------------------------
verify_service() {
  # $1 = label, $2 = portlist (comma-separated)
  local label="$1"; local ports="$2"
  local plist="$PLIST_DIR/$label.plist"
  local errlog before_size now_size pid p new_tail

  # log path from plist (never hardcoded)
  errlog=$(plutil -extract StandardErrorPath raw "$plist" 2>/dev/null || echo "")
  before_size=0
  [ -n "$errlog" ] && [ -f "$errlog" ] && before_size=$(stat -f %z "$errlog")

  if [ $CHECK = 1 ]; then
    echo "  [check] would kickstart $label  (ports: $ports, errlog: $errlog)"
    return 0
  fi

  echo "  kickstart $label"
  launchctl kickstart -k "gui/$(id -u)/$label"
  sleep 4

  # global `launchctl list` still emits "PID  Status  Label" short columns;
  # `launchctl list <label>` on modern macOS dumps the whole plist — avoid it.
  pid=$(launchctl list 2>/dev/null | awk -v L="$label" '$3==L {print $1; exit}')
  if [ -z "$pid" ] || [ "$pid" = "-" ]; then
    echo "  FAIL: $label has no PID after restart" >&2
    return 1
  fi
  echo "  pid=$pid"

  old_ifs="$IFS"; IFS=','
  for p in $ports; do
    if lsof -nP -iTCP:"$p" -sTCP:LISTEN >/dev/null 2>&1; then
      echo "  :$p LISTEN ok"
    else
      echo "  FAIL: :$p not listening" >&2
      IFS="$old_ifs"
      return 1
    fi
  done
  IFS="$old_ifs"

  # new err-log tail (bytes appended since restart) must not contain traceback
  if [ -n "$errlog" ] && [ -f "$errlog" ]; then
    now_size=$(stat -f %z "$errlog")
    if [ "$now_size" -gt "$before_size" ]; then
      new_tail=$(tail -c $((now_size - before_size)) "$errlog")
      if echo "$new_tail" | grep -Eiq 'traceback|^[a-zA-Z_.]*Error:|Exception:' ; then
        echo "  FAIL: new err-log tail contains error:" >&2
        echo "$new_tail" | tail -20 >&2
        return 1
      fi
    fi
    echo "  errlog clean (delta=$((now_size - before_size))B)"
  fi
}

ok=1
for g in $to_restart; do
  spec=$(group_spec "$g")
  label="${spec%%:*}"
  ports="${spec#*:}"
  verify_service "$label" "$ports" || ok=0
done

if [ $ok = 1 ]; then
  echo "== deploy OK (${to_restart# })"
else
  echo "== deploy FAILED" >&2
  exit 1
fi
