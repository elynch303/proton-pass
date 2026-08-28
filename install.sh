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
for name in qs-protonpass.sh qs-protonpass-tty.py qs-protonpass-copy.py qs-protonpass-login.py; do
  src="$SCRIPT_DIR/$name"
  dst="$BIN_DIR/$name"
  if [[ -e "$dst" && "$assume_yes" != true ]]; then
    read -rp "$dst already exists — overwrite? [y/N] " reply
    [[ "$reply" =~ ^[Yy]$ ]] || { echo "Skipped $name."; continue; }
  fi
  # A plain `cp` + `chmod` overwrites through whatever's already at $dst,
  # including a pre-existing symlink planted there ahead of time — the
  # chmod would then land on the symlink's target, not a file we control.
  # mktemp creates the temp file exclusively (O_EXCL) in the same
  # directory, so it can't itself be a pre-planted symlink; chmod happens
  # on that private file before it's ever reachable by its final name; and
  # `mv` (rename(2)) replaces whatever's at $dst — symlink or not — as a
  # single atomic directory-entry swap, never opening/following it.
  tmp="$(mktemp "$BIN_DIR/.$name.XXXXXX")"
  cp "$src" "$tmp"
  chmod +x "$tmp"
  mv -f "$tmp" "$dst"
  echo "Installed $dst"
done

if ! command -v pass-cli >/dev/null 2>&1; then
  echo
  echo "pass-cli was not found on PATH. Install it first, e.g.:"
  echo "  yay -S proton-pass-cli-bin"
  echo "then run:"
  echo "  pass-cli login"
fi
