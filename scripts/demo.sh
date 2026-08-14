#!/usr/bin/env bash
# demo.sh — canned output for the README demo GIF (recorded via VHS, see demo.tape).
#
# Each invocation just PRINTS a representative result — it does NOT touch tmux, CCR,
# or any gateway, so the recording is stable, fast, and offline. VHS drives the
# typing/pacing; this script only supplies what the terminal "shows back".
#
# It parses crew-like args so the tape can type real-looking commands
# (`crew web --model GLM-5.2`) and get the right canned output directly.
set -uo pipefail

sub="${1:-}"; shift || true
case "$sub" in
  models)
    cat <<'EOF'
== models ==
  default
  Claude-Opus-4.8
  GLM-5.2
  kimi-k3
EOF
    ;;

  ls)
    cat <<'EOF'
== crew sessions ==
  NAME      STATUS     MODEL           KEY     DIR
  web       live       GLM-5.2         gw      ~/work/web
  docs      live       kimi-k3         gw2     ~/work/docs
  infra     resumable  Claude-Opus-4.8 gw      ~/work/infra
EOF
    ;;

  send)   echo "[crew] queued → inbox of 'web' (from docs); nudged 'web'";;
  inbox)
    cat <<'EOF'
── #1  from docs  at 19:40 ──
接口签名改了,同步下调用方
(consumed 1 message)
EOF
    ;;

  # `crew failover ...` — the headline: show the transparent key downgrade trace.
  failover)
    cat <<'EOF'
[crew-proxy] → GLM-5.2  via key 'gw'   (stream=True)
[crew-proxy] ← key 'gw' upstream 429; failing over
[crew-proxy] → GLM-5.2  via key 'gw2'  (stream=True)
[crew-proxy]   'gw' TRIPPED (3 fails, cooldown 60s) — 'gw2' took over, claude never noticed
EOF
    ;;

  # any named session with --model: echo a ready line
  *)
    model=""; while [ $# -gt 0 ]; do [ "$1" = "--model" ] && { model="$2"; shift; }; shift; done
    case "$sub" in
      web)  echo "[crew] session 'web'  ready (model: glm,GLM-5.2,  key: gw)";;
      docs) echo "[crew] session 'docs' ready (model: kimi,kimi-k3, key: gw2)";;
      *)    echo "[crew] session '$sub' ready (model: ${model:-default})";;
    esac
    ;;
esac
