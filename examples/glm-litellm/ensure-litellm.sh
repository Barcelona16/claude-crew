#!/usr/bin/env bash
# ensure-litellm.sh — idempotently ensure the LiteLLM proxy is listening on :PORT.
# Referenced by the "glm" crew backend's ENSURE_CMD, so a crew session can bring
# its backend up on demand. Safe to run repeatedly.
#
# Env:
#   LITELLM_PORT        default 4000
#   LITELLM_CONFIG      default <this dir>/config.yaml  (or ~/.config/claude-crew/glm-litellm/config.yaml)
#   GLM_GATEWAY_TOKEN   upstream gateway token (required to actually serve requests)
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PORT="${LITELLM_PORT:-4000}"
CONFIG="${LITELLM_CONFIG:-${XDG_CONFIG_HOME:-$HOME/.config}/claude-crew/glm-litellm/config.yaml}"
[ -f "$CONFIG" ] || CONFIG="$HERE/config.yaml"
LOG="${XDG_STATE_HOME:-$HOME/.local/state}/claude-crew"; mkdir -p "$LOG"

# Portable "is it up?" — bash /dev/tcp, no lsof/ss needed (works in bare containers).
listening(){ (exec 3<>"/dev/tcp/127.0.0.1/$PORT") 2>/dev/null && { exec 3>&- 3<&-; return 0; }; return 1; }

if listening; then exit 0; fi

command -v litellm >/dev/null 2>&1 || { echo "[ensure-litellm] litellm not installed; run examples/glm-litellm/setup.sh" >&2; exit 1; }
[ -f "$CONFIG" ] || { echo "[ensure-litellm] config not found: $CONFIG" >&2; exit 1; }
[ -n "${GLM_GATEWAY_TOKEN:-}" ] || echo "[ensure-litellm] WARN: GLM_GATEWAY_TOKEN unset; proxy will start but upstream calls will fail" >&2

echo "[ensure-litellm] starting litellm on :$PORT" >&2
LITELLM_LOCAL_MODEL_COST_MAP=True nohup litellm --config "$CONFIG" --host 127.0.0.1 --port "$PORT" > "$LOG/litellm.log" 2>&1 &
for _ in $(seq 1 12); do listening && break; sleep 1; done
listening && echo "[ensure-litellm] up on :$PORT" >&2 || { echo "[ensure-litellm] failed to come up; see $LOG/litellm.log" >&2; exit 1; }
