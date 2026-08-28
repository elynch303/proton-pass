#!/usr/bin/env python3
# Fixed-argv clipboard-copy helper for the Proton Pass widget.
#
# The widget needs to get a secret (password/TOTP code) onto the Wayland
# clipboard without ever putting it in any process's argv or a shell
# command string — both are visible to any other local process via `ps` or
# /proc/*/cmdline for as long as that process runs. This script's own argv
# never carries user/secret data; the secret arrives on stdin instead, as
# one JSON object on one line: {"value": "<secret>"}.
#
# JSON-on-one-line rather than a raw byte stream: JSON.stringify on the QML
# side escapes embedded newlines/control characters, so the whole secret
# round-trips as a single line no matter what characters it contains,
# without either side having to compute a separate UTF-8 byte-length header.
#
# The QML Process that spawns this script has no way to close/EOF its own
# stdin pipe (see ProtonPassWidget.qml's header comment on execDetached),
# so this helper can't just read-until-EOF either — the line framing above
# is what lets it know the payload is complete without EOF.
#
# wl-copy itself *does* need a real EOF on its stdin to claim the selection.
# That's satisfied by a pipe this helper opens and closes itself (a fresh
# subprocess.Popen stdin pipe) — a completely different fd than the
# never-closing one this script's own stdin is.
#
# wl-copy runs with --foreground so it never forks away: the pid printed
# back is the actual process serving the clipboard, so the widget can later
# terminate exactly that process — and only if it's still alive and still
# wl-copy — instead of blindly clearing whatever's on the clipboard now
# (which could by then be something unrelated the user copied themselves).

import json
import subprocess
import sys

MAX_LINE_BYTES = 131072  # generous ceiling well above any real secret/TOTP code


def fail(msg):
    print(json.dumps({"ok": False, "error": msg}))
    sys.exit(1)


def main():
    line = sys.stdin.buffer.readline(MAX_LINE_BYTES)
    try:
        payload = json.loads(line)
        secret = payload["value"]
        if not isinstance(secret, str) or not secret:
            raise ValueError("empty or non-string value")
    except Exception:
        fail("bad payload")
        return

    try:
        proc = subprocess.Popen(
            ["wl-copy", "--foreground", "--sensitive"],
            stdin=subprocess.PIPE,
            start_new_session=True,
        )
    except FileNotFoundError:
        fail("wl-copy not found")
        return

    try:
        proc.stdin.write(secret.encode())
        proc.stdin.close()
    except BrokenPipeError:
        fail("wl-copy exited before accepting input")
        return

    print(json.dumps({"ok": True, "pid": proc.pid}))


if __name__ == "__main__":
    main()
