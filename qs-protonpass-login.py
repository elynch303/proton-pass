#!/usr/bin/env python3
# Runs `pass-cli login` inside a real pty, transparently relayed to/from the
# real terminal this script is launched inside (same reason
# qs-protonpass-tty.py exists for the lock-code prompts: piping pass-cli's
# output away from a real TTY breaks its flow — confirmed for
# unlock/create-lock/remove-lock, and login is grouped with those in this
# plugin's own header comment as needing a real TTY too).
#
# On top of that transparent relay, this scans the relayed bytes for the
# login URL pass-cli prints and opens it in the default browser
# automatically, once, the moment it appears — rather than relying solely
# on pass-cli's own internal browser-open attempt (present in the pass-cli
# binary itself, but whether *that* succeeds depends on the exact spawn
# environment it inherits; this guarantees it regardless).
#
# pty.spawn is the stdlib's own script(1)-equivalent: it already handles the
# bidirectional real-terminal <-> child-pty relay (raw-moding our own stdin
# for the duration, restoring it after), so this only has to hook its
# master_read callback to look at what's flowing through — nothing here
# injects input the way qs-protonpass-tty.py does for lock codes.

import os
import pty
import re
import subprocess
import sys

PASS_CLI = os.environ.get("QS_PROTONPASS_CLI", "pass-cli")
URL_RE = re.compile(rb"https?://\S+")
MAX_BUF = 4096  # rolling window, in case a URL straddles two reads

_buf = b""
_opened = False


def open_browser(url: bytes):
    global _opened
    if _opened or not url:
        return
    _opened = True
    try:
        subprocess.Popen(
            ["xdg-open", url.decode(errors="replace")],
            stdin=subprocess.DEVNULL,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            start_new_session=True,
        )
    except FileNotFoundError:
        pass  # no xdg-open — pass-cli's own fallback message is still on screen


def _clean_url(url: bytes) -> bytes:
    # Trim trailing characters that are almost always surrounding
    # punctuation, not part of the URL itself (e.g. "...authenticate: URL.").
    # A trailing ')' is the exception: keep it if it balances an earlier '('
    # within the matched text (e.g. "https://x.com/a(2)"), only strip it
    # when unbalanced (e.g. the common "(see https://x.com/a)" — the regex
    # match itself starts at "h", so the leading '(' is outside it and this
    # trailing ')' is truly just the sentence's, not the URL's).
    # `url and` guards against looping forever: an empty bytes slice tests
    # as "in" any bytes object, so without it a URL that stripped down to
    # nothing would never make url[-1:] leave the strip set.
    while url and url[-1:] in b".,;:!?>\"'":
        url = url[:-1]
    while url and url.endswith(b")") and url.count(b"(") < url.count(b")"):
        url = url[:-1]
    return url


def master_read(fd):
    global _buf
    data = os.read(fd, 1024)
    if data:
        _buf = (_buf + data)[-MAX_BUF:]
        m = URL_RE.search(_buf)
        if m:
            open_browser(_clean_url(m.group(0)))
    return data


def main():
    status = pty.spawn([PASS_CLI, "login"], master_read)
    sys.exit(os.waitstatus_to_exitcode(status))


if __name__ == "__main__":
    main()
