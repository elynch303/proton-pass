#!/usr/bin/env bash
# pass-cli wrapper/dispatcher for the Proton Pass bar widget.
#
# Keeps all pass-cli invocation and JSON parsing in one place, same reason
# qs-security-scan.sh exists for the security-scan plugin. Every subcommand
# prints one JSON object to stdout and exits 0 on success; on failure it
# prints {"error": "<message>"} to stdout and exits non-zero, so the widget
# can branch on a single shape either way.
#
# pass-cli's own lock/unlock/create-lock prompt for the lock code on a real
# TTY (confirmed: piping the code via stdin fails with "No such device or
# address" reading /dev/tty) — so `lock`/`unlock` here just proxy exit
# status, and the widget drives the actual code entry through a floating
# terminal, the same way it drives `pass-cli login`.
set -uo pipefail

PASS_CLI="${QS_PROTONPASS_CLI:-pass-cli}"

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
    local has_lock
    has_lock="$(printf '%s' "$out" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("session_has_lock", False))' 2>/dev/null)"
    if [ "$has_lock" = "True" ]; then
      # session_has_lock only tells us a lock exists, not whether it's
      # currently engaged; a locked session fails ordinary calls like
      # `vault list` below, which is what actually distinguishes the two.
      if "$PASS_CLI" vault list --output json >/dev/null 2>&1; then
        printf '{"state":"unlocked"}\n'
      else
        printf '{"state":"locked"}\n'
      fi
    else
      printf '{"state":"unlocked"}\n'
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

# Lock/unlock require a real TTY (pass-cli reads the code from /dev/tty) —
# these exist for completeness/scripted callers but the widget itself drives
# lock/unlock through a floating terminal, not through these.
cmd_lock() {
  _require_cli || { _err "pass-cli not installed"; return 1; }
  "$PASS_CLI" session lock 2>&1
}

cmd_unlock() {
  _require_cli || { _err "pass-cli not installed"; return 1; }
  "$PASS_CLI" session unlock 2>&1
}

main() {
  local subcmd="${1:-}"
  shift || true
  case "$subcmd" in
    status) cmd_status "$@" ;;
    vaults) cmd_vaults "$@" ;;
    items) cmd_items "$@" ;;
    view) cmd_view "$@" ;;
    totp) cmd_totp "$@" ;;
    lock) cmd_lock "$@" ;;
    unlock) cmd_unlock "$@" ;;
    *)
      _err "unknown subcommand: $subcmd"
      return 1
      ;;
  esac
}

main "$@"
