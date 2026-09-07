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

# Producer-side ceilings: every pass-cli call below is wrapped in `timeout`
# and every captured response is capped with `head -c` before it reaches a
# shell var (and from there Python/QML). A hung pass-cli or a pathological
# response otherwise blocks the widget indefinitely or gets handed to QML's
# Repeaters uncapped.
CLI_TIMEOUT="${QS_PROTONPASS_CLI_TIMEOUT:-10}"
# `item list` fetches the whole vault from Proton's API in sequential
# 100-item pages (no local-cache read path in pass-cli itself) — a large
# vault (observed: 2672 items) takes 7-17s across ~27 round-trips, well
# past CLI_TIMEOUT's 10s. Item-list calls get their own, longer ceiling.
ITEM_LIST_TIMEOUT="${QS_PROTONPASS_ITEM_LIST_TIMEOUT:-45}"
# Raised from the upstream default of 1MB: a large vault's item-metadata
# JSON can legitimately exceed that (observed: 2600+ items -> ~1.45MB),
# which silently dropped every item from this widget.
MAX_OUT_BYTES=16777216

# Cache for `item list` results: the paginated fetch above is the slow
# part of every popup open, so short-TTL caching is what actually makes
# "load faster" mean anything here — pass-cli has nothing to tune (no
# page-size flag, no local-cache read mode). Explicit refresh (--force)
# bypasses it.
ITEMS_CACHE_DIR="${QS_PROTONPASS_CACHE_DIR:-$HOME/.cache/proton-pass/items}"
ITEMS_CACHE_TTL="${QS_PROTONPASS_ITEMS_CACHE_TTL:-30}"
mkdir -p "$ITEMS_CACHE_DIR" 2>/dev/null

_cache_fresh() {
  local f="$1" mtime now
  [ -f "$f" ] || return 1
  mtime="$(stat -c %Y "$f" 2>/dev/null)" || return 1
  now="$(date +%s)"
  [ $(( now - mtime )) -lt "$ITEMS_CACHE_TTL" ]
}

_cache_write() {
  local f="$1" tmp
  tmp="$(mktemp "$ITEMS_CACHE_DIR/.tmp.XXXXXX")" || return 1
  cat > "$tmp"
  mv -f "$tmp" "$f"
}

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
  if out="$(timeout "$CLI_TIMEOUT" "$PASS_CLI" info --output json 2>&1 | head -c "$MAX_OUT_BYTES")"; then
    local has_lock idle_timeout locked
    has_lock="$(printf '%s' "$out" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("session_has_lock", False))' 2>/dev/null)"
    idle_timeout=""
    [ "$has_lock" = "True" ] && idle_timeout="$(printf '%s' "$out" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("session_lock_after_seconds", ""))' 2>/dev/null)"
    # `info`'s session_has_lock only reflects whether a lock is configured,
    # and has been observed out of sync with the session's real lock state
    # (reporting false while the session was actually SessionLocked) — so
    # the real state always comes from attempting an authenticated call,
    # never from trusting that field alone.
    if timeout "$CLI_TIMEOUT" "$PASS_CLI" vault list --output json >/dev/null 2>&1; then
      if [ "$has_lock" = "True" ]; then
        printf '{"state":"unlocked","hasLock":true,"idleTimeout":%s}\n' "${idle_timeout:-null}"
      else
        printf '{"state":"unlocked","hasLock":false}\n'
      fi
    else
      printf '{"state":"locked"}\n'
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
  timeout "$CLI_TIMEOUT" "$PASS_CLI" vault list --output json 2>/dev/null | head -c "$MAX_OUT_BYTES" || { _err "failed to list vaults"; return 1; }
}

# Item metadata only (title, type, vault, timestamps) — never secrets.
# pass-cli has no all-vaults item list, so with no --vault we fan out across
# every vault from `vault list` and merge.
cmd_items() {
  _require_cli || { _err "pass-cli not installed"; return 1; }
  local vault_share_id="" force=false
  while [ $# -gt 0 ]; do
    case "$1" in
      --vault) vault_share_id="${2:-}"; shift 2 ;;
      --force) force=true; shift ;;
      *) shift ;;
    esac
  done

  if [ -n "$vault_share_id" ]; then
    local cache_file="$ITEMS_CACHE_DIR/vault-$(printf '%s' "$vault_share_id" | tr -c 'A-Za-z0-9_-' '_').json"
    if [ "$force" != true ] && _cache_fresh "$cache_file"; then
      cat "$cache_file"
      return 0
    fi
    local out
    out="$(timeout "$ITEM_LIST_TIMEOUT" "$PASS_CLI" item list --share-id "$vault_share_id" --output json 2>/dev/null | head -c "$MAX_OUT_BYTES")" || { _err "failed to list items"; return 1; }
    printf '%s' "$out" | _cache_write "$cache_file"
    printf '%s' "$out"
    return 0
  fi

  local all_cache_file="$ITEMS_CACHE_DIR/all.json"
  if [ "$force" != true ] && _cache_fresh "$all_cache_file"; then
    cat "$all_cache_file"
    return 0
  fi

  local vaults_json
  vaults_json="$(timeout "$CLI_TIMEOUT" "$PASS_CLI" vault list --output json 2>/dev/null | head -c "$MAX_OUT_BYTES")" || { _err "failed to list vaults"; return 1; }

  # vaults_json arrives on stdin, not argv (same reasoning as cmd_view/
  # cmd_detail) — vault names could in principle be long/adversarial too.
  # Per-vault fetch is capped (byte + count) so one oversized or malicious
  # vault can't blow up memory or the list handed to QML's Repeater; a
  # rejected vault is skipped exactly like an error from pass-cli itself.
  local merged
  merged="$(printf '%s' "$vaults_json" | python3 -c '
import json, sys, subprocess

MAX_BYTES = 16 * 1024 * 1024
MAX_ITEMS_PER_VAULT = 5000
MAX_TOTAL_ITEMS = 20000

vaults = json.loads(sys.stdin.read()).get("vaults", [])
pass_cli = sys.argv[1]
item_list_timeout = float(sys.argv[2])
all_items = []
for v in vaults:
    if len(all_items) >= MAX_TOTAL_ITEMS:
        break
    share_id = v.get("share_id")
    try:
        out = subprocess.run(
            [pass_cli, "item", "list", "--share-id", share_id, "--output", "json"],
            capture_output=True, text=True, timeout=item_list_timeout,
        )
        if out.returncode != 0 or len(out.stdout.encode()) > MAX_BYTES:
            continue
        items = json.loads(out.stdout).get("items", [])[:MAX_ITEMS_PER_VAULT]
        for it in items:
            it["vault_name"] = v.get("name")
        all_items.extend(items)
    except Exception:
        continue
print(json.dumps({"items": all_items[:MAX_TOTAL_ITEMS]}))
' "$PASS_CLI" "$ITEM_LIST_TIMEOUT")" || { _err "failed to merge items"; return 1; }

  printf '%s' "$merged" | _cache_write "$all_cache_file"
  printf '%s' "$merged"
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
  out="$(timeout "$CLI_TIMEOUT" "$PASS_CLI" item view --share-id "$share_id" --item-id "$item_id" --output json 2>/dev/null | head -c "$MAX_OUT_BYTES")" || { _err "failed to view item"; return 1; }

  # The full item JSON (password, TOTP URI, notes, ...) goes in on stdin,
  # never argv — argv is visible to any local process via /proc/*/cmdline
  # or `ps`, and this object carries secrets even though only one field
  # is ever selected back out.
  printf '%s' "$out" | python3 -c '
import json, sys
d = json.loads(sys.stdin.read())
field = sys.argv[1]
login = d.get("item", {}).get("content", {}).get("content", {}).get("Login", {})
val = login.get(field)
if val is None:
    print(json.dumps({"error": f"field not found: {field}"}))
    sys.exit(1)
print(json.dumps({"value": val}))
' "$field"
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
  out="$(timeout "$CLI_TIMEOUT" "$PASS_CLI" item view --share-id "$share_id" --item-id "$item_id" --output json 2>/dev/null | head -c "$MAX_OUT_BYTES")" || { _err "failed to view item"; return 1; }

  # Same stdin-not-argv reasoning as cmd_view: this JSON still carries the
  # password/TOTP even though only non-secret fields are read back out.
  printf '%s' "$out" | python3 -c '
import json, sys
d = json.loads(sys.stdin.read())
item = d.get("item", {})
login = item.get("content", {}).get("content", {}).get("Login", {})
print(json.dumps({
    "username": login.get("username", ""),
    "email": login.get("email", ""),
    "urls": (login.get("urls", []) or [])[:20],
    "modify_time": item.get("modify_time"),
}))
'
}

cmd_totp() {
  _require_cli || { _err "pass-cli not installed"; return 1; }
  local share_id="${1:-}" item_id="${2:-}"
  if [ -z "$share_id" ] || [ -z "$item_id" ]; then
    _err "usage: totp SHARE_ID ITEM_ID"
    return 1
  fi

  local out uri
  out="$(timeout "$CLI_TIMEOUT" "$PASS_CLI" item view --share-id "$share_id" --item-id "$item_id" --output json 2>/dev/null | head -c "$MAX_OUT_BYTES")" || { _err "failed to view item"; return 1; }
  uri="$(printf '%s' "$out" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("item",{}).get("content",{}).get("content",{}).get("Login",{}).get("totp_uri",""))')"
  if [ -z "$uri" ]; then
    _err "no TOTP configured for this item"
    return 1
  fi

  # `pass-cli totp generate` only accepts the secret/URI (TOTP seed
  # included) as a positional argument — no stdin mode — and /proc/<pid>/
  # cmdline is world-readable for the life of that call, so any local
  # account could read a long-lived credential off it. TOTP is just HMAC
  # over a time counter (RFC 6238), so instead of shelling out we derive
  # the code ourselves, right here, with the URI fed on stdin — it never
  # touches argv at all. One fewer pass-cli invocation too.
  printf '%s' "$uri" | python3 -c '
import base64, hashlib, hmac, json, struct, sys, time
from urllib.parse import urlparse, parse_qs

uri = sys.stdin.read().strip()
try:
    parsed = urlparse(uri)
    if parsed.scheme != "otpauth" or parsed.netloc.lower() != "totp":
        raise ValueError("not a totp:// URI")
    q = parse_qs(parsed.query)
    secret_raw = q.get("secret", [None])[0]
    if not secret_raw:
        raise ValueError("no secret in URI")
    algo_name = (q.get("algorithm", ["SHA1"])[0] or "SHA1").upper()
    digits = int(q.get("digits", ["6"])[0] or 6)
    period = int(q.get("period", ["30"])[0] or 30)
    if digits < 6 or digits > 10 or period <= 0:
        raise ValueError("unsupported digits/period")
    digestmod = {"SHA1": hashlib.sha1, "SHA256": hashlib.sha256, "SHA512": hashlib.sha512}.get(algo_name)
    if digestmod is None:
        raise ValueError("unsupported algorithm")

    s = secret_raw.strip().upper().replace(" ", "")
    key = base64.b32decode(s + "=" * ((-len(s)) % 8))
    counter = int(time.time() // period)
    mac = hmac.new(key, struct.pack(">Q", counter), digestmod).digest()
    offset = mac[-1] & 0x0F
    code = (struct.unpack(">I", mac[offset:offset + 4])[0] & 0x7fffffff) % (10 ** digits)
    print(json.dumps({"token": str(code).zfill(digits)}))
except Exception as e:
    print(json.dumps({"error": f"failed to generate TOTP: {e}"}))
    sys.exit(1)
' || { _err "failed to generate TOTP"; return 1; }
}

# Direct-fetch favicon for an item's guessed domain (never a third-party
# proxy - this is the only network call in the plugin that isn't pass-cli
# itself, so it stays limited to https://DOMAIN/favicon.ico). Favicons
# aren't secret, so unlike everything else here they're cached to disk
# (~/.cache/proton-pass/favicons), including a `.miss` sentinel for domains
# with no favicon so a dead site isn't re-fetched on every popup open.
cmd_favicon() {
  local domain="${1:-}"
  if [ -z "$domain" ]; then
    _err "usage: favicon DOMAIN"
    return 1
  fi
  case "$domain" in
    */*|*'..'*|'') _err "invalid domain"; return 1 ;;
  esac

  local cache_dir="$HOME/.cache/proton-pass/favicons"
  mkdir -p "$cache_dir"
  local safe existing tmp mime ext dest
  safe="$(printf '%s' "$domain" | tr -c 'a-zA-Z0-9.-' '_')"

  if [ -e "$cache_dir/$safe.miss" ]; then
    _err "no favicon for $domain (cached miss)"
    return 1
  fi
  existing="$(command ls "$cache_dir/$safe".* 2>/dev/null | head -n1)"
  if [ -n "$existing" ] && [ -s "$existing" ]; then
    python3 -c 'import json,sys; print(json.dumps({"ok": True, "path": sys.argv[1]}))' "$existing"
    return 0
  fi

  # SSRF guard: `domain` is guessed from a vault item's title, and in a
  # shared vault that title is data another Proton Pass user chose — not
  # fully trusted input. The domain-shape regex upstream in the widget lets
  # through IP-literal and internal-hostname titles too (confirmed:
  # "169.254.169.254", "192.168.1.1", "router.local" all match), which
  # would otherwise trigger an automatic, no-click curl to an internal or
  # cloud-metadata address on every popup open. Resolve first and reject
  # anything that isn't a public address, then pin curl to exactly the
  # address just validated (`--resolve`) so a second, later DNS resolution
  # — which could differ (DNS rebinding) — can't slip past the check.
  local safe_ip
  safe_ip="$(python3 -c '
import ipaddress, socket, sys
domain = sys.argv[1]
try:
    infos = socket.getaddrinfo(domain, 443, proto=socket.IPPROTO_TCP)
except OSError:
    sys.exit(1)
for info in infos:
    addr = ipaddress.ip_address(info[4][0])
    if addr.is_global and not addr.is_multicast:
        print(addr)
        sys.exit(0)
sys.exit(1)
' "$domain" 2>/dev/null)" || {
    touch "$cache_dir/$safe.miss"
    _err "no favicon for $domain (unresolvable or non-public address)"
    return 1
  }

  tmp="$cache_dir/$safe.tmp"
  if ! curl -fsSL --max-time 3 --resolve "$domain:443:$safe_ip" -A "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36" "https://$domain/favicon.ico" -o "$tmp" 2>/dev/null || [ ! -s "$tmp" ]; then
    rm -f "$tmp"
    touch "$cache_dir/$safe.miss"
    _err "no favicon for $domain"
    return 1
  fi

  mime="$(file -b --mime-type "$tmp" 2>/dev/null)"
  case "$mime" in
    image/x-icon|image/vnd.microsoft.icon) ext="ico" ;;
    image/png) ext="png" ;;
    image/gif) ext="gif" ;;
    image/jpeg) ext="jpg" ;;
    image/svg+xml) ext="svg" ;;
    image/webp) ext="webp" ;;
    image/bmp) ext="bmp" ;;
    *) rm -f "$tmp"; touch "$cache_dir/$safe.miss"; _err "unsupported favicon type: $mime"; return 1 ;;
  esac

  dest="$cache_dir/$safe.$ext"
  mv "$tmp" "$dest"
  python3 -c 'import json,sys; print(json.dumps({"ok": True, "path": sys.argv[1]}))' "$dest"
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
    favicon) cmd_favicon "$@" ;;
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
