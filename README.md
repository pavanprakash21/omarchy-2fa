# 2FA

Bar widget for [Omarchy](https://omarchy.org/) that reveals and copies a
TOTP/HOTP code from your [OTPClient](https://github.com/paolostivanin/OTPClient)
database, on demand.

## Status

Scaffolding only right now — the widget renders a placeholder glyph and does
not yet read codes. Follow the [milestone](https://github.com/pavanprakash21/omarchy-2fa/milestones)
for the plan; a full README lands with the first working release.

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
