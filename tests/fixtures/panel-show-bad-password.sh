#!/usr/bin/env bash
# Combined fixture: --list succeeds with the same 3-row inventory as
# panel-combo.sh, but EVERY --show call fails with the confirmed real
# stderr shape for a wrong/stale password (see Cli.js's module docstring:
# "Incorrect password.", exit 255). Used by tests/panel.qmltest.qml's
# reveal-time-error group to reach a --show-time failure (revealState/
# revealErrorState/revealFailedKey) on real inventory, distinct from the
# --list-time failure fixtures (malformed.sh, db-missing.sh, etc.) every
# other group already exercises against loadState.
set -e

is_list=0
for arg in "$@"; do
  if [[ "$arg" == "--list" ]]; then is_list=1; fi
done

if [[ "$is_list" == "1" ]]; then
  cat <<'JSON'
[
  {"issuer": "GitHub", "account": "pavan@smaply.com", "group": "", "type": "TOTP"},
  {"issuer": "Example", "account": "alice@example.com", "group": "", "type": "TOTP"},
  {"issuer": "Bank", "account": "acct1", "group": "", "type": "HOTP"}
]
JSON
  exit 0
fi

echo "Incorrect password." >&2
exit 255
