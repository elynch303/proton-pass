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
import signal
import sys
import time

PASS_CLI = os.environ.get("QS_PROTONPASS_CLI", "pass-cli")

# Ceiling on the transcript we accumulate from the pty. This is terminal
# output (prompts, echoed control sequences), not the code itself — rpassword
# on the pass-cli side disables local echo for the actual secret entry — but
# it's still unbounded attacker/hang-controlled data otherwise, and a hung
# pass-cli could be made to emit forever.
MAX_TRANSCRIPT_BYTES = 8192


def _reap(pid):
    """Kill the child (and anything it spawned into the same pty session)
    and block until it's actually gone — never leaves a hung/zombie pass-cli
    behind on timeout."""
    try:
        pgid = os.getpgid(pid)
    except ProcessLookupError:
        return
    for sig in (signal.SIGTERM, signal.SIGKILL):
        try:
            os.killpg(pgid, sig)
        except ProcessLookupError:
            return
        try:
            deadline = time.time() + 2
            while time.time() < deadline:
                wpid, _ = os.waitpid(pid, os.WNOHANG)
                if wpid == pid:
                    return
                time.sleep(0.05)
        except ChildProcessError:
            return


def run_with_pty(argv, responses, timeout=10):
    pid, fd = pty.fork()
    if pid == 0:
        os.execvp(argv[0], argv)
    out = b""
    start = time.time()
    idx = 0
    timed_out = False
    while time.time() - start < timeout:
        r, _, _ = select.select([fd], [], [], 0.3)
        if fd in r:
            try:
                chunk = os.read(fd, 1024)
            except OSError:
                break
            if not chunk:
                break
            if len(out) < MAX_TRANSCRIPT_BYTES:
                out += chunk[: MAX_TRANSCRIPT_BYTES - len(out)]
            while idx < len(responses) and responses[idx][0].encode() in out:
                os.write(fd, responses[idx][1].encode())
                idx += 1
        if not os.path.exists(f"/proc/{pid}"):
            time.sleep(0.2)
            break
    else:
        timed_out = True

    _reap(pid)
    return out.decode(errors="replace"), timed_out


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

    out, timed_out = run_with_pty(argv, responses)

    if timed_out:
        # Fixed message, not the raw transcript — on timeout we can't be
        # sure what's in `out` (a prompt pass-cli was mid-writing, a partial
        # echo, ...), so nothing pty-derived leaves this process here.
        result(False, "timed out waiting for pass-cli")
        return
    if "SessionLocked" in out or "session_locked" in out.lower():
        result(False, "wrong code")
        return
    if "successfully" in out.lower():
        result(True)
        return
    result(False, out.strip().splitlines()[-1] if out.strip() else "no response from pass-cli")


if __name__ == "__main__":
    main()
