#!/usr/bin/env bash
# Install step for the Proton Pass plugin.
# Copies qs-protonpass.sh and qs-protonpass-tty.py to ~/.local/bin/ — the
# widget shells out to the former for every pass-cli interaction, which in
# turn calls the latter for the three lock-code prompts (unlock/create-lock/
# remove-lock) that need a real TTY.
#
# Usage:
#   bash install.sh          # asks before overwriting an existing install
#   bash install.sh --yes    # overwrite without prompting
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN_DIR="${HOME}/.local/bin"

assume_yes=false
for arg in "$@"; do
  case "$arg" in
    --yes) assume_yes=true ;;
  esac
done

mkdir -p "$BIN_DIR"
for name in qs-protonpass.sh qs-protonpass-tty.py; do
  src="$SCRIPT_DIR/$name"
  dst="$BIN_DIR/$name"
  if [[ -e "$dst" && "$assume_yes" != true ]]; then
    read -rp "$dst already exists — overwrite? [y/N] " reply
    [[ "$reply" =~ ^[Yy]$ ]] || { echo "Skipped $name."; continue; }
  fi
  cp "$src" "$dst"
  chmod +x "$dst"
  echo "Installed $dst"
done

if ! command -v pass-cli >/dev/null 2>&1; then
  echo
  echo "pass-cli was not found on PATH. Install it first, e.g.:"
  echo "  yay -S proton-pass-cli-bin"
  echo "then run:"
  echo "  pass-cli login"
fi
