# 2FA

Bar widget for [Omarchy](https://omarchy.org/) that reveals and copies a
TOTP/HOTP code from your [OTPClient](https://github.com/paolostivanin/OTPClient)
database, on demand.

## Status

v1.0 (on-demand reveal): the bar icon opens a searchable panel listing every
issuer/account in your OTPClient database. Select a row (mouse or keyboard)
to decrypt just that one token, copy its code to the clipboard, and see it
on screen for a few seconds. Nothing is decrypted until you ask for it, and
never more than one code is held in memory at a time. Follow the
[milestone](https://github.com/pavanprakash21/omarchy-2fa/milestones) for
what's still ahead (settings, richer error copy).

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
| `database` | `""` | Passed through to `--database`. **Not yet wired** — see below; the default (unset) is today's existing, unaffected behavior. |
| `icon` | a lock/shield glyph | Override the bar (and dock) icon glyph. |
| `confirmHotp` | `true` | Accepted, but **cannot be disabled** — see below. |

### `database` isn't wired yet

`otpclient-cli` is deliberately never given a `-d/--database` argument by
this plugin today (an already-reviewed decision from issue #2: it only ever
talks to your already-configured default database). Actually honoring an
override here means adding that argument to `Backend.qml`/`Cli.js`, both of
which are a separately owned, already twice-reviewed layer outside the
scope of the settings work that added this key. Leaving `database` unset —
the default, `""` — is exactly today's existing behavior, so nothing
regresses; setting it to a real path currently has no effect. Tracked as a
follow-up.

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
advance.

## If something's not working

Every failure this panel can hit renders its own actionable message inline
— no desktop notification, no stack trace, and never a password, code, or
database secret in the text:

| What you'll see | What it means | The fix |
|---|---|---|
| "otpclient isn't installed…" | `otpclient-cli` isn't at `/usr/bin` or `/usr/local/bin` (checked directly; no PATH lookup, per this plugin's own threat model — see issue #21) | `otpclient` is AUR-only: `yay -S otpclient`, which installs to `/usr/bin` |
| "Secret Service integration is off…" | otpclient-cli is blocked on a password prompt this panel can't answer — the most likely first-run state | Enable "Use Secret Service" in OTPClient's own preferences |
| "password… is stale or wrong" | The keyring entry needs refreshing | Unlock the database once in the OTPClient GUI |
| "No OTPClient database found…" | Nothing configured at the expected path | Set one up in the OTPClient GUI, or check `~/.config/otpclient/otpclient.cfg` |
| "returned output this panel could not understand" | A decrypt/parse failure | Reported as-is; no automatic repair is attempted |
| "No entries in your OTPClient database." | An empty, valid database | Not an error — add tokens in the OTPClient GUI |
| "otpclient-cli crashed" | otpclient-cli itself died to a signal | Likely a bug in otpclient-cli or a damaged database, not a config problem here |
| "another OTPClient process already has the database open" | A GLib D-Bus single-instance race — most commonly the OTPClient GUI being open | Close the other instance and try again |

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

1. Enable this plugin normally first (see Install, below) — the dock only
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

## Requirements

- Omarchy on Hyprland (Wayland).
- [`OTPClient`](https://github.com/paolostivanin/OTPClient)'s `otpclient-cli`,
  with a default database already configured (via the OTPClient GUI, or
  `otpclient-cli --import`). Nothing here creates a database for you.
- `wl-clipboard` (`wl-copy`/`wl-paste`) for the clipboard copy.

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

## License

GPL-3.0-or-later, see [LICENSE](LICENSE).
