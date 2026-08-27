#!/usr/bin/env bash
# pass-cli wrapper/dispatcher for the Proton Pass bar widget.
#
# Keeps all pass-cli invocation and JSON parsing in one place, same reason
# qs-security-scan.sh exists for the security-scan plugin. Every subcommand
# prints one JSON object to stdout and exits 0 on success; on failure it
# prints {"error": "<message>"} to stdout and exits non-zero, so the widget
# can branch on a single shape either way.
#
# pass-cli's own lock/unlock/create-lock/remove-lock prompt for the lock
# code on a real TTY (confirmed: piping the code via stdin fails with "No
# such device or address" reading /dev/tty). qs-protonpass-tty.py wraps
# those three in a pty so the code can come from this script's own stdin
# instead — see its header for the full explanation. `lock` needs no code
# and no TTY, so it's a direct proxy.
set -uo pipefail

PASS_CLI="${QS_PROTONPASS_CLI:-pass-cli}"
TTY_HELPER="${QS_PROTONPASS_TTY_HELPER:-$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/qs-protonpass-tty.py}"
[ -x "$TTY_HELPER" ] || TTY_HELPER="$HOME/.local/bin/qs-protonpass-tty.py"

_err() {
  python3 -c 'import json,sys; print(json.dumps({"error": sys.argv[1]}))' "$1"
}

_require_cli() {
  command -v "$PASS_CLI" >/dev/null 2>&1
}

cmd_status() {
  if ! _require_cli; then
    printf '{"state":"missing"}\n'
    return 0
  fi
  local out
  if out="$("$PASS_CLI" info --output json 2>&1)"; then
    local has_lock idle_timeout
    has_lock="$(printf '%s' "$out" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("session_has_lock", False))' 2>/dev/null)"
    if [ "$has_lock" = "True" ]; then
      idle_timeout="$(printf '%s' "$out" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("session_lock_after_seconds", ""))' 2>/dev/null)"
      # session_has_lock only tells us a lock exists, not whether it's
      # currently engaged; a locked session fails ordinary calls like
      # `vault list` below, which is what actually distinguishes the two.
      if "$PASS_CLI" vault list --output json >/dev/null 2>&1; then
        printf '{"state":"unlocked","hasLock":true,"idleTimeout":%s}\n' "${idle_timeout:-null}"
      else
        printf '{"state":"locked"}\n'
      fi
    else
      printf '{"state":"unlocked","hasLock":false}\n'
    fi
    return 0
  fi
  if printf '%s' "$out" | grep -qi "authenticated client\|no session"; then
    printf '{"state":"logged-out"}\n'
    return 0
  fi
  printf '{"state":"locked"}\n'
}

cmd_vaults() {
  _require_cli || { _err "pass-cli not installed"; return 1; }
  "$PASS_CLI" vault list --output json 2>/dev/null || { _err "failed to list vaults"; return 1; }
}

# Item metadata only (title, type, vault, timestamps) — never secrets.
# pass-cli has no all-vaults item list, so with no --vault we fan out across
# every vault from `vault list` and merge.
cmd_items() {
  _require_cli || { _err "pass-cli not installed"; return 1; }
  local vault_share_id=""
  if [ "${1:-}" = "--vault" ]; then
    vault_share_id="${2:-}"
  fi

  if [ -n "$vault_share_id" ]; then
    "$PASS_CLI" item list --share-id "$vault_share_id" --output json 2>/dev/null || { _err "failed to list items"; return 1; }
    return 0
  fi

  local vaults_json
  vaults_json="$("$PASS_CLI" vault list --output json 2>/dev/null)" || { _err "failed to list vaults"; return 1; }

  python3 -c '
import json, sys, subprocess

vaults = json.loads(sys.argv[1]).get("vaults", [])
pass_cli = sys.argv[2]
all_items = []
for v in vaults:
    share_id = v.get("share_id")
    try:
        out = subprocess.run(
            [pass_cli, "item", "list", "--share-id", share_id, "--output", "json"],
            capture_output=True, text=True, timeout=15,
        )
        if out.returncode != 0:
            continue
        items = json.loads(out.stdout).get("items", [])
        for it in items:
            it["vault_name"] = v.get("name")
        all_items.extend(items)
    except Exception:
        continue
print(json.dumps({"items": all_items}))
' "$vaults_json" "$PASS_CLI" || { _err "failed to merge items"; return 1; }
}

# Single secret field, for a one-shot clipboard copy. Never persisted.
cmd_view() {
  _require_cli || { _err "pass-cli not installed"; return 1; }
  local share_id="${1:-}" item_id="${2:-}" field="${3:-}"
  if [ -z "$share_id" ] || [ -z "$item_id" ] || [ -z "$field" ]; then
    _err "usage: view SHARE_ID ITEM_ID FIELD"
    return 1
  fi

  local out
  out="$("$PASS_CLI" item view --share-id "$share_id" --item-id "$item_id" --output json 2>/dev/null)" || { _err "failed to view item"; return 1; }

  python3 -c '
import json, sys
d = json.loads(sys.argv[1])
field = sys.argv[2]
login = d.get("item", {}).get("content", {}).get("content", {}).get("Login", {})
val = login.get(field)
if val is None:
    print(json.dumps({"error": f"field not found: {field}"}))
    sys.exit(1)
print(json.dumps({"value": val}))
' "$out" "$field"
}

# Non-secret detail-view fields in one call (username, urls, timestamps) —
# replaces a separate per-field `view` call for each; username is not
# treated as secret elsewhere in this script either.
cmd_detail() {
  _require_cli || { _err "pass-cli not installed"; return 1; }
  local share_id="${1:-}" item_id="${2:-}"
  if [ -z "$share_id" ] || [ -z "$item_id" ]; then
    _err "usage: detail SHARE_ID ITEM_ID"
    return 1
  fi

  local out
  out="$("$PASS_CLI" item view --share-id "$share_id" --item-id "$item_id" --output json 2>/dev/null)" || { _err "failed to view item"; return 1; }

  python3 -c '
import json, sys
d = json.loads(sys.argv[1])
item = d.get("item", {})
login = item.get("content", {}).get("content", {}).get("Login", {})
print(json.dumps({
    "username": login.get("username", ""),
    "urls": login.get("urls", []) or [],
    "modify_time": item.get("modify_time"),
}))
' "$out"
}

cmd_totp() {
  _require_cli || { _err "pass-cli not installed"; return 1; }
  local share_id="${1:-}" item_id="${2:-}"
  if [ -z "$share_id" ] || [ -z "$item_id" ]; then
    _err "usage: totp SHARE_ID ITEM_ID"
    return 1
  fi

  local out uri
  out="$("$PASS_CLI" item view --share-id "$share_id" --item-id "$item_id" --output json 2>/dev/null)" || { _err "failed to view item"; return 1; }
  uri="$(printf '%s' "$out" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("item",{}).get("content",{}).get("content",{}).get("Login",{}).get("totp_uri",""))')"
  if [ -z "$uri" ]; then
    _err "no TOTP configured for this item"
    return 1
  fi

  "$PASS_CLI" totp generate "$uri" --output json 2>/dev/null || { _err "failed to generate TOTP"; return 1; }
}

cmd_logout() {
  _require_cli || { _err "pass-cli not installed"; return 1; }
  "$PASS_CLI" logout >/dev/null 2>&1
  printf '{"ok":true}\n'
}

cmd_lock() {
  _require_cli || { _err "pass-cli not installed"; return 1; }
  "$PASS_CLI" session lock >/dev/null 2>&1
  printf '{"ok":true}\n'
}

# Code arrives on our own stdin (one line) and is relayed to the tty helper's
# stdin unchanged — never touches argv, a file, or a log at any hop.
cmd_unlock() {
  _require_cli || { _err "pass-cli not installed"; return 1; }
  [ -x "$TTY_HELPER" ] || { _err "tty helper not installed"; return 1; }
  python3 "$TTY_HELPER" unlock
}

cmd_create_lock() {
  _require_cli || { _err "pass-cli not installed"; return 1; }
  [ -x "$TTY_HELPER" ] || { _err "tty helper not installed"; return 1; }
  local idle_timeout="${1:-300}"
  python3 "$TTY_HELPER" create-lock "$idle_timeout"
}

cmd_remove_lock() {
  _require_cli || { _err "pass-cli not installed"; return 1; }
  [ -x "$TTY_HELPER" ] || { _err "tty helper not installed"; return 1; }
  python3 "$TTY_HELPER" remove-lock
}

main() {
  local subcmd="${1:-}"
  shift || true
  case "$subcmd" in
    status) cmd_status "$@" ;;
    vaults) cmd_vaults "$@" ;;
    items) cmd_items "$@" ;;
    view) cmd_view "$@" ;;
    detail) cmd_detail "$@" ;;
    totp) cmd_totp "$@" ;;
    logout) cmd_logout "$@" ;;
    lock) cmd_lock "$@" ;;
    unlock) cmd_unlock "$@" ;;
    create-lock) cmd_create_lock "$@" ;;
    remove-lock) cmd_remove_lock "$@" ;;
    *)
      _err "unknown subcommand: $subcmd"
      return 1
      ;;
  esac
}

main "$@"
