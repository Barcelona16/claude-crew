#!/usr/bin/env bash
# make-public.sh — derive the open-source build of claude-crew from this (internal) repo.
#
# Single source of truth = this repo (internal, has JD llm-gw URLs + JD model names).
# The public build is DERIVED, never hand-maintained, so the two can't drift. This script:
#   1. exports a clean worktree of HEAD into a build dir (no .git, no local state)
#   2. swaps internal-specific files for their .public overlays (branding, CCR template, READMEs)
#   3. removes the .public source files + this script + internal-only docs from the build
#   4. boundary check: the build must contain ZERO joycode / llm-gw / JD-model references
#   5. prints a summary + how to push to the public remote (origin) — it does NOT push.
#
# Usage:  ./make-public.sh [build-dir]     (default: ../claude-crew-public)
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
BUILD="${1:-$HERE/../claude-crew-public}"
PUBLIC_REMOTE="origin"   # GitHub; internal repo stays on 'coding'

say(){ printf '\n\033[1m==> %s\033[0m\n' "$*"; }
info(){ printf '   %s\n' "$*"; }
die(){ printf '\n[make-public] ERROR: %s\n' "$*" >&2; exit 1; }

# Overlays: "<internal path> -> <.public overlay path>". The overlay's content REPLACES the
# internal file in the build; the overlay file itself is then removed from the build.
OVERLAYS=(
  "setup/branding.sh|setup/branding.public.sh"
  "setup/ccr-config.template.json|setup/ccr-config.public.template.json"
  "README.md|README.public.md"
  "README.en.md|README.public.en.md"
)

# Files that exist only for the internal repo or the build process — dropped from the public build.
DROP=(
  "make-public.sh"
  "docs/superpowers"
)

say "1) export clean worktree of HEAD -> $BUILD"
[ -d "$HERE/.git" ] || die "run from the repo root (no .git found)"
rm -rf "$BUILD"; mkdir -p "$BUILD"
git -C "$HERE" archive --format=tar HEAD | tar -x -C "$BUILD"
info "exported $(find "$BUILD" -type f | wc -l | tr -d ' ') files"

say "2) apply .public overlays"
for pair in "${OVERLAYS[@]}"; do
  target="${pair%%|*}"; overlay="${pair#*|}"
  [ -f "$BUILD/$overlay" ] || die "missing overlay $overlay (needed for $target)"
  mv "$BUILD/$overlay" "$BUILD/$target"
  info "$target  <-  $overlay"
done
# any leftover *.public.* overlays that weren't consumed (safety)
find "$BUILD" -name '*.public.*' -type f -print -delete | while read -r f; do info "removed stray $f"; done

say "3) drop internal-only files"
for d in "${DROP[@]}"; do
  if [ -e "$BUILD/$d" ]; then rm -rf "$BUILD/$d"; info "removed $d"; fi
done

say "4) boundary check (must be zero)"
# The public build must not mention joycode, the JD internal gateway, or JD-only model names.
PATTERNS='joycode|llm-gw|jd\.local|joybuilder|GLM-5\.2|kimi-k3|coding\.jd\.com'
if grep -rInE "$PATTERNS" "$BUILD" 2>/dev/null; then
  die "boundary check FAILED — internal references above must not reach the public build"
fi
info "clean: no joycode / llm-gw / JD-model references"

say "5) done — public build ready (NOT pushed)"
cat <<EOF

  Build dir: $BUILD

  Review it, then publish manually:
    cd "$BUILD"
    git init -q && git add -A && git commit -q -m "release: public snapshot"
    git remote add $PUBLIC_REMOTE git@github.com:Barcelona16/claude-crew.git   # if not set
    git push -f $PUBLIC_REMOTE HEAD:main

  (This script never pushes. You keep final control over what reaches GitHub.)
EOF
