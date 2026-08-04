#!/usr/bin/env bash
# install.sh — put `crew` on your PATH.
#   bash install.sh                 # symlink into ~/.local/bin (default)
#   PREFIX=/usr/local bash install.sh   # system-wide (may need sudo)
set -euo pipefail
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
