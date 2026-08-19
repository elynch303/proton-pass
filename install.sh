#!/usr/bin/env bash
# Install step for the Proton Pass plugin.
# Copies qs-protonpass.sh to ~/.local/bin/ — the widget shells out to it for
# every pass-cli interaction.
#
# Usage:
#   bash install.sh          # asks before overwriting an existing install
#   bash install.sh --yes    # overwrite without prompting
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN_DIR="${HOME}/.local/bin"
SRC="$SCRIPT_DIR/qs-protonpass.sh"
DST="$BIN_DIR/qs-protonpass.sh"

assume_yes=false
for arg in "$@"; do
  case "$arg" in
    --yes) assume_yes=true ;;
  esac
done

if [[ -e "$DST" && "$assume_yes" != true ]]; then
  read -rp "$DST already exists — overwrite? [y/N] " reply
  [[ "$reply" =~ ^[Yy]$ ]] || { echo "Skipped."; exit 0; }
fi

mkdir -p "$BIN_DIR"
cp "$SRC" "$DST"
chmod +x "$DST"
echo "Installed $DST"

if ! command -v pass-cli >/dev/null 2>&1; then
  echo
  echo "pass-cli was not found on PATH. Install it first, e.g.:"
  echo "  yay -S proton-pass-cli-bin"
  echo "then run:"
  echo "  pass-cli login"
fi
