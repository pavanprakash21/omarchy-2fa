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
