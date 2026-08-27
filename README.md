# Proton Pass

An [Omarchy](https://omarchy.com) bar-widget plugin that brings Proton Pass
into your bar: vault selection, item search, and session auto-lock — backed
by the official [`pass-cli`](https://proton.me/pass), not a reimplementation.

![Proton Pass popup showing vault selection and item search](preview.png)

## Features

- Bar badge reflects session state: not installed / logged out / locked / unlocked,
  with a lock glyph badge in the corner when locked
- Vault selector, with an "All vaults" view
- Live item search across titles
- Click an item to reveal and copy username, password, or a TOTP code —
  copies go through the clipboard and **auto-clear after ~30s**
- Inline PIN-based auto-lock: set a PIN and your own idle timeout (30–900s)
  from the popup, then unlock with a 6-box PIN entry — no floating terminal
  needed for day-to-day lock/unlock
- Login still opens a floating terminal, since it's a one-time interactive
  web-login/2FA flow
- No secret values are ever written to disk by this plugin — everything is
  fetched from `pass-cli` on demand

## Requirements

- [Omarchy](https://omarchy.com) with Quickshell
- [`pass-cli`](https://proton.me/pass) — the official Proton Pass CLI
  (AUR: `proton-pass-cli-bin` or `proton-pass-cli`)
- You must have run `pass-cli login` at least once before the widget will
  show anything beyond a "log in" prompt
- `wl-copy` / `wl-clipboard` for the clipboard-copy actions

## Installation

```
omarchy plugin add https://github.com/elynch303/proton-pass.git
```

Then run the install step to place the helper script:

```
bash ~/.config/omarchy/plugins/io.github.elynch303.proton-pass/install.sh
```

Add it to your bar layout in `~/.config/omarchy/shell.json`:

```json
{ "id": "io.github.elynch303.proton-pass" }
```

## How it works

`qs-protonpass.sh` (installed to `~/.local/bin`) wraps `pass-cli` and
normalizes its output to JSON for the widget: session status, vault list,
item metadata (no secrets), single-field secret reveal for copy actions, and
TOTP generation. The widget polls `qs-protonpass.sh status` on a light
interval to keep the bar badge accurate, and only fetches vault/item data
when the popup is open.

Locking follows `pass-cli`'s own session lock — this plugin doesn't
reimplement idle detection, it just surfaces `pass-cli session create-lock` /
`lock` / `unlock` / `remove-lock` in the UI. Since those commands only accept
the lock code through a real TTY prompt, `qs-protonpass-tty.py` (also
installed to `~/.local/bin`) drives that prompt over a pseudo-terminal so the
PIN can be typed inline in the popup. The PIN is read once from the script's
own stdin and written straight into the pty — it never appears in any
process's argv and is never written to disk. The idle timeout you choose at
setup is `pass-cli`'s own — nothing here is hardcoded or read from any
browser extension.

## Security notes

- Clipboard-copy model, not autofill — nothing is typed into other windows
- Clipboard is cleared automatically after the copy times out, and
  immediately if the popup is closed early
- Item search/list only ever fetches metadata (title, type, vault); actual
  secret values are fetched one field at a time, only when you click copy
- Nothing from a vault is cached to `~/.cache` or anywhere else on disk
- Your PIN never appears in process argv and is never written to disk —
  see "How it works" above

## Uninstalling

```
omarchy plugin remove io.github.elynch303.proton-pass
rm -f ~/.local/bin/qs-protonpass.sh ~/.local/bin/qs-protonpass-tty.py
```

Then remove its entry from `~/.config/omarchy/shell.json` if you added one.
This plugin never wrote anything to `~/.cache` or elsewhere on disk, so
there's no other state to clean up.

## License

MIT
