#!/bin/bash

set -euo pipefail

BIN_DIR=${1:-$HOME/.local/bin}
BINDINGS=$HOME/.config/hypr/bindings.lua

install -Dm755 "$(dirname "$0")/omarchy-capture-image-search" \
  "$BIN_DIR/omarchy-capture-image-search"
echo "Installed $BIN_DIR/omarchy-capture-image-search"

if grep -q omarchy-capture-image-search "$BINDINGS" 2>/dev/null; then
  echo "Keybindings already present in $BINDINGS"
  exit 0
fi

cat <<'BINDINGS_HELP'

Add these to ~/.config/hypr/bindings.lua, then run: hyprctl reload

o.bind("SUPER + ALT + PRINT", "Search screen with Google Lens", "omarchy-capture-image-search")
o.bind("SUPER + SHIFT + ALT + PRINT", "Search screen with Google Lens (private)", "omarchy-capture-image-search --private")
BINDINGS_HELP
