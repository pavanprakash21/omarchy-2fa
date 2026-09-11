# 2FA

Bar widget for [Omarchy](https://omarchy.org/) that reveals and copies a
TOTP/HOTP code from your [OTPClient](https://github.com/paolostivanin/OTPClient)
database, on demand.

![The 2FA panel: a search box filtered to "twit", one matching row showing
Twitter, "TOTP code copied · 19s remaining", and the code itself masked
behind bullets](preview.png)

## What it does

The bar icon opens a searchable panel listing every issuer/account in your
OTPClient database. Select a row (mouse or keyboard) to decrypt just that
one token, copy its code to the clipboard, and see it on screen for a few
seconds. Nothing is decrypted until you ask for it, and never more than one
code is held in memory at a time.

### Why revealing a code takes a moment

Decrypting **any** code from your OTPClient database means running its
Argon2id key derivation (t=4, m=128 MiB, p=4) — that's deliberately slow,
because it's the same thing standing between an attacker and your secrets
if the database file leaks. Measured on real hardware, one derivation
takes **~0.22s**. That's the pause you see between activating a row and the
code landing on your clipboard; it's the KDF doing its job, not a bug or a
slow widget.

This is also why the panel does not show a live grid of every code at
once: keeping a grid current means re-deriving the key for every single
token roughly every 30 seconds, forever, just so a code is on screen in
case you look at it. Instead, opening the panel costs exactly **one**
Argon2id decrypt to list issuers/accounts (no codes, just names — the
`--list` inventory call), and revealing a code costs exactly one more,
scoped to the single row you clicked. One decrypt per code you actually
ask for, never a background refresh loop.

Follow the [milestone](https://github.com/pavanprakash21/omarchy-2fa/milestones)
for what's still ahead.

## Requirements

- Omarchy on Hyprland (Wayland).
- [`OTPClient`](https://github.com/paolostivanin/OTPClient), **from the AUR**
  — it is not in `extra`:
  ```
  yay -S otpclient
  ```
  with a default database already configured (via the OTPClient GUI, or
  `otpclient-cli --import`). Nothing here creates a database for you.
- **Secret Service enabled in OTPClient.** Open OTPClient's own preferences
  and turn on "Use Secret Service integration", then unlock your database
  once so the password is stored in your keyring. Without this,
  `otpclient-cli` cannot obtain a password non-interactively, and every
  reveal ends up in the `would-prompt` state instead of a code — **this is
  the single most common first-run problem**; see
  [If something's not working](#if-somethings-not-working) below. (This is
  now a distinct state from having no database configured at all, which
  gets its own message pointing at creating one — the two used to be
  indistinguishable here.)
- `wl-clipboard` (`wl-copy`/`wl-paste`) for the clipboard copy.

> **2026-09-11:** the AUR `otpclient` package is currently pinned to 5.1.6
> and itself flagged out-of-date. On 5.1.6, `otpclient-cli` cannot run at
> all while the OTPClient GUI is open — a real upstream bug (the CLI
> registers the GUI's own D-Bus application id), fixed in commit
> `7a9671e1` but not yet in a tagged release. Closing the GUI works around
> it today; `otpclient-git` builds from `master` and already has the fix.

## Install

```
omarchy plugin add https://github.com/pavanprakash21/omarchy-2fa.git --enable
```

Or by hand:

```
git clone https://github.com/pavanprakash21/omarchy-2fa.git ~/.config/omarchy/plugins/pavanprakash21.twofa
omarchy-shell shell rescanPlugins
omarchy plugin enable pavanprakash21.twofa
```

### Updating

```
omarchy plugin update pavanprakash21.twofa
omarchy restart shell
```

**The restart is required, not optional.** `omarchy plugin update` pulls the new
files, but the running shell has already compiled and cached the old QML, so a
plain update leaves you running the previous version with no indication that
anything is stale. `omarchy-shell shell rescanPlugins` re-reads manifests and is
not enough on its own either. Use `omarchy restart shell` (it handles restarting
safely while a lock client is live, which a raw `kill` does not).

## Use

- Click the shield icon in the bar to open the panel.
- Type to filter by issuer or account.
- Up/Down to move the selection, Enter to reveal + copy the selected row,
  Escape to close (or to cancel an armed HOTP confirmation — see below).
- HOTP rows need a second, deliberate Enter to actually reveal: `--show`
  advances and persists the HOTP counter on the real device too, so an
  accidental first press only arms a "press again to confirm" prompt rather
  than immediately desynchronizing the token.
- Clicking away, or opening any other bar panel, closes this one.

### Keyboard toggle

Keyboard shortcuts belong to Hyprland, so the plugin never edits your Omarchy
bindings automatically. To summon or dismiss the panel with a shortcut
(e.g. `SUPER + SHIFT + T`), add this to `~/.config/hypr/bindings.lua`:

```lua
o.bind("SUPER + SHIFT + T", "2FA", "omarchy-shell pavanprakash21.twofa toggle")
```

`open` and `close` are also exposed over the same IPC target
(`pavanprakash21.twofa`), if you'd rather bind those individually than
toggle.

## Settings

Every setting below has a working default — the plugin is fully usable with
none of them set. Add an inline entry for this widget's `moduleName`
(`pavanprakash21.twofa`) under `shell.json`, the same place every other
widget's own tunables live:

```json
{
  "pavanprakash21.twofa": {
    "maskCodes": true,
    "revealSeconds": 5,
    "clipboardClearSeconds": 0,
    "database": "",
    "icon": "󰦝",
    "confirmHotp": true
  }
}
```

| Key | Default | Meaning |
|---|---|---|
| `maskCodes` | `true` | Mask a revealed code on screen until you click it to reveal. The clipboard copy always happens regardless of this — masking only ever affects what's painted on screen. |
| `revealSeconds` | `5` | How long a code auto-clears from the panel when otpclient-cli itself gives no expiry to count down (always true for HOTP). A TOTP code's own real, CLI-reported countdown is never shortened or lengthened by this — only the panel's own fallback window is. |
| `clipboardClearSeconds` | `0` | Clear the clipboard this many seconds after a copy, but only if it still holds the exact code this panel put there — a copy you made yourself in the meantime is left alone. `0` disables this entirely. |
| `database` | `""` | Which OTPClient database to read, passed through to `--database`. Accepts either a path or a database *name* as printed by `otpclient-cli --list-databases`. Unset (the default) means no `--database` argument at all, i.e. your configured default database. |
| `icon` | a lock/shield glyph | Override the bar (and dock) icon glyph. |
| `confirmHotp` | `true` | Accepted, but **cannot be disabled** — see below. |

### Pointing at a non-default database

If you keep more than one OTPClient database, set `database` to the one this
panel should read:

```json
"database": "/home/you/.config/otpclient/work.db"
```

The value is handed to `otpclient-cli -d/--database` verbatim as a single
argument, so both forms that flag accepts work — an absolute path, or a
database name as listed by `otpclient-cli --list-databases`. It applies to
the token list and to every reveal alike, so the panel can never end up
listing one database and decrypting from another.

Leaving it unset passes no `--database` argument at all, which is the
default-database behavior described everywhere else in this file. A value
pointing at a database that doesn't exist surfaces as the same "database
not found" state as any other missing database, not as a parse error.

### `confirmHotp` cannot be disabled

`otpclient-cli --show` on an HOTP entry **advances and persists a real
counter on your device** on every single call — it is not idempotent and
not safe to retry. The "press again to confirm" gate this panel requires
before that can happen is a safety invariant, not a preference, and it
covers more than entries affirmatively typed `HOTP`: any entry whose type
isn't affirmatively `TOTP` requires it too, since an unrecognized type is
exactly the case you can least afford to guess wrong about. `confirmHotp`
is accepted in `shell.json` — so the key doesn't just silently vanish — but
setting it to `false` has no effect: the panel still requires a deliberate
second activation before any HOTP-shaped counter is ever allowed to
advance. This is deliberate: a setting must never be able to fail-open the
one gate standing between a click and an irreversible counter advance.

## Syncing from Ente Auth

OTPClient has no sync of its own. If you keep your tokens in [Ente
Auth](https://ente.io/auth/) — end-to-end encrypted, and the practical way to
have the same vault on a phone and a desktop — `contrib/ente-sync.sh` refreshes
the OTPClient database from it, and therefore this widget:

```
yay -S ente-cli-bin
ente account add          # choose "auth" as the app
./contrib/ente-sync.sh
```

Run it after adding or removing a token in Ente. It is deliberately a command
you run, not a daemon — a background job holding your whole 2FA vault open on a
timer is a worse trade than typing one command occasionally. Re-running it is
safe: `otpclient-cli` detects and skips duplicates.

One thing the script exists to handle: **Ente's export writes every secret in
plaintext.** The script points Ente's export directory at `/dev/shm` (RAM),
mode 0700, and shreds it on the way out — including on Ctrl-C — so nothing
unencrypted is ever written to your SSD. If you export from the Ente GUI
instead, it lands plaintext in `~/Downloads`; shred it promptly, or prefer the
GUI's encrypted export.

## Security

- **In memory:** never more than one decrypted code at a time, and only for
  as long as it's on screen — it's overwritten the next time you reveal a
  different row, and cleared outright when the panel closes. Nothing is
  cached, and nothing is ever written to disk by this plugin.
- **Clipboard:** the revealed code is piped to `wl-copy` over **stdin**,
  never passed as a command-line argument — argv is world-readable via
  `/proc/<pid>/cmdline` on Linux, stdin is not.
- **Optional clipboard clear:** set `clipboardClearSeconds` (see
  [Settings](#settings)) to have the plugin clear the clipboard N seconds
  after a copy. It only clears if the clipboard still holds the exact code
  it put there — reading it back first via `wl-paste` — so it never wipes
  out something you copied yourself in the meantime.
- **HOTP caveat:** `otpclient-cli --show` on an HOTP entry **advances and
  persists that token's counter on disk** as a side effect of simply
  reading the code — it is not a safe, idempotent "peek". Doing this by
  accident desynchronizes the token from whatever server checks it. That's
  why HOTP (and any non-`TOTP`-typed) row requires a deliberate second
  activation to actually reveal — see [Use](#use) and
  [`confirmHotp` cannot be disabled](#confirmhotp-cannot-be-disabled).

## If something's not working

Every failure this panel can hit renders its own actionable message inline
— no desktop notification, no stack trace, and never a password, code, or
database secret in the text:

| What you'll see | What it means | The fix |
|---|---|---|
| "otpclient isn't installed…" | `otpclient-cli` isn't at `/usr/bin` or `/usr/local/bin` (checked directly; no PATH lookup, per this plugin's own threat model — see issue #21) | `otpclient` is AUR-only: `yay -S otpclient`, which installs to `/usr/bin` |
| "Secret Service integration is off…" | otpclient-cli couldn't obtain a database password non-interactively — the most likely first-run state, given a database is configured | Enable "Use Secret Service" in OTPClient's own preferences |
| "No OTPClient database is configured yet…" | Nothing configured at all — no `-d`/`--database`, no default in GSettings | Create a database in the OTPClient GUI (or `otpclient-cli --import`) |
| "password… is stale or wrong" | The keyring entry needs refreshing | Unlock the database once in the OTPClient GUI |
| "No OTPClient database found…" | A database *is* configured, but nothing exists at that path | Set one up in the OTPClient GUI, or check `~/.config/otpclient/otpclient.cfg` |
| "returned output this panel could not understand" | A decrypt/parse failure | Reported as-is; no automatic repair is attempted |
| "No entries in your OTPClient database." | An empty, valid database | Not an error — add tokens in the OTPClient GUI |
| "otpclient-cli crashed" | otpclient-cli itself died to a signal | Likely a bug in otpclient-cli or a damaged database, not a config problem here |
| "otpclient-cli can't run because the OTPClient GUI is open" | A GLib D-Bus single-instance bug in otpclient-cli <= 5.1.6 (see the dated note under [Requirements](#requirements)) — this does not clear on its own | Close the OTPClient GUI, or switch to `otpclient-git` |

The widget installs and enables cleanly even with `otpclient` not installed
at all — every case above is a degraded, in-panel state, never a crash or a
blocked shell startup.

## Dock hosting (rosakodu.dock)

This widget also works inside the third-party
[`rosakodu.dock`](https://github.com/rosakodu/omarchy-dock) plugin, using the
exact same entry point as the bar — no separate build or code path. The
dock resolves any installed plugin's `barWidget` entry point on its own
(`DockPanel.qml`'s `getWidgetSource()`), so nothing needs to be registered
for that part.

**The dock's own widget picker will not offer this plugin.** Its "Add
widget" UI (`components/WidgetPickerPopup.qml`) enumerates a hardcoded list
of `omarchy.*` ids and has no notion of third-party plugins, even though the
dock is fully capable of hosting one. Until that's fixed upstream, add this
plugin to the dock by hand:

1. Enable this plugin normally first (see Install, above) — the dock only
   resolves ids for plugins that are actually installed.
2. Edit `~/.config/omarchy/dock-settings.json` and add
   `"pavanprakash21.twofa"` to the `dockWidgets` array, e.g.:
   ```json
   {
     "dockWidgets": ["omarchy.apps", "pavanprakash21.twofa"]
   }
   ```
3. Restart the dock (or your shell) to pick up the change.

An upstream issue asking for third-party plugin ids in the picker is open at
[rosakodu/omarchy-dock#29](https://github.com/rosakodu/omarchy-dock/issues/29)
— this step can go away once that lands.

Everything else — the panel opening in the right place, the icon glyph, the
open/close/toggle lifecycle — works the same whether the icon lives in the
bar or the dock, on any screen edge the dock is docked to.

**`shell.json` settings only take effect in the bar, not the dock.** When
the dock hosts a widget it injects `bar`, `shell`, `widgetId`, and
`moduleName` into it (`DockPanel.qml`'s `configureHostedWidget()`), but it
never sets the widget's `settings` property the way the real bar host does
(`Bar.qml` reads each widget's `shell.json` entry and assigns it there) —
so `setting(name, fallback)` always returns its fallback while hosted in
the dock, regardless of what you've configured. This is a dock limitation,
not something this plugin can work around from its side; every entry in
the [Settings](#settings) table above behaves as its documented default
when this widget lives in the dock.

## License

GPL-3.0-or-later, see [LICENSE](LICENSE). This plugin is built entirely
against, and only makes sense alongside,
[OTPClient](https://github.com/paolostivanin/OTPClient), which is itself
GPL-3.0. It ships no code from OTPClient and only ever talks to it through
`otpclient-cli`'s command-line/JSON interface — but it exists to be a front
end for that tool, shares its lineage, and inherits its license rather than
picking a different one.
