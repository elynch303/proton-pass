#!/usr/bin/env python3
# Drives pass-cli's lock-code prompts (create-lock / unlock / remove-lock),
# which read the code from a real TTY via rpassword — piping stdin directly
# to pass-cli fails with "No such device or address" reading /dev/tty
# (confirmed by hand). A pty makes pass-cli see a real terminal while the
# code itself comes from *this* script's own stdin, one line, so it never
# touches argv/ps.
#
# Usage: qs-protonpass-tty.py <create-lock IDLE_TIMEOUT|unlock|remove-lock>
# Code read from stdin (one line, no trailing newline needed).
# Prints one JSON object: {"ok": true} or {"ok": false, "error": "..."}.

import json
import os
import pty
import select
import sys
import time

PASS_CLI = os.environ.get("QS_PROTONPASS_CLI", "pass-cli")


def run_with_pty(argv, responses, timeout=10):
    pid, fd = pty.fork()
    if pid == 0:
        os.execvp(argv[0], argv)
    out = b""
    start = time.time()
    idx = 0
    while time.time() - start < timeout:
        r, _, _ = select.select([fd], [], [], 0.3)
        if fd in r:
            try:
                chunk = os.read(fd, 1024)
            except OSError:
                break
            if not chunk:
                break
            out += chunk
            while idx < len(responses) and responses[idx][0].encode() in out:
                os.write(fd, responses[idx][1].encode())
                idx += 1
        if not os.path.exists(f"/proc/{pid}"):
            time.sleep(0.2)
            break
    try:
        os.waitpid(pid, os.WNOHANG)
    except OSError:
        pass
    return out.decode(errors="replace")


def result(ok, error=None):
    obj = {"ok": ok}
    if error is not None:
        obj["error"] = error
    print(json.dumps(obj))


def main():
    if len(sys.argv) < 2:
        result(False, "usage: qs-protonpass-tty.py <create-lock IDLE_TIMEOUT|unlock|remove-lock>")
        return
    action = sys.argv[1]
    code = sys.stdin.readline().rstrip("\n")
    if not code:
        result(False, "no code provided")
        return

    if action == "create-lock":
        idle_timeout = sys.argv[2] if len(sys.argv) > 2 else "300"
        argv = [PASS_CLI, "session", "create-lock", "--idle-timeout", idle_timeout]
        responses = [("Enter lock code", code + "\n"), ("Re-enter lock code", code + "\n")]
    elif action == "unlock":
        argv = [PASS_CLI, "session", "unlock"]
        responses = [("Enter lock code", code + "\n")]
    elif action == "remove-lock":
        argv = [PASS_CLI, "session", "remove-lock"]
        responses = [("Enter lock code", code + "\n")]
    else:
        result(False, f"unknown action: {action}")
        return

    out = run_with_pty(argv, responses)

    if "SessionLocked" in out or "session_locked" in out.lower():
        result(False, "wrong code")
        return
    if "successfully" in out.lower():
        result(True)
        return
    result(False, out.strip().splitlines()[-1] if out.strip() else "no response from pass-cli")


if __name__ == "__main__":
    main()
