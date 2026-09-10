#!/usr/bin/env bash
# --list fixture for the "stale reveal survives a manual refresh()"
# regression (tests/panel.qmltest.qml): returns
# [GitHub, Example, Bank] on the FIRST --list call, and the REORDERED
# [Bank, Example, GitHub] on every call after -- as if the user edited
# their token order in the OTPClient GUI while this panel happened to stay
# open. Backend's own onListSucceeded re-clamps selectedIndex the same way
# open() does, so a refresh() that lands the clamped index on the SAME
# NUMBER while the entry underneath it changed must still drop a stale
# reveal attached to the OLD entry -- see PanelState.qml's
# onListSucceeded/_syncRevealToSelection.
#
# Call count is tracked in a state file next to this script so repeated
# invocations within one test run answer differently; tests/run-qml-tests.sh
# stages a fresh copy of fixtures/ per run, so this never leaks state
# between runs.
DIR="$(cd "$(dirname "$0")" && pwd)"
STATE="$DIR/panel-reorder-state.count"

is_list=0
for arg in "$@"; do
  if [[ "$arg" == "--list" ]]; then is_list=1; fi
done

if [[ "$is_list" == "1" ]]; then
  count=0
  [[ -f "$STATE" ]] && count="$(cat "$STATE")"
  count=$((count + 1))
  echo "$count" > "$STATE"
  if [[ "$count" -le 1 ]]; then
    cat <<'JSON'
[
  {"issuer": "GitHub", "account": "pavan@smaply.com", "group": "", "type": "TOTP"},
  {"issuer": "Example", "account": "alice@example.com", "group": "", "type": "TOTP"},
  {"issuer": "Bank", "account": "acct1", "group": "", "type": "HOTP"}
]
JSON
  else
    cat <<'JSON'
[
  {"issuer": "Bank", "account": "acct1", "group": "", "type": "HOTP"},
  {"issuer": "Example", "account": "alice@example.com", "group": "", "type": "TOTP"},
  {"issuer": "GitHub", "account": "pavan@smaply.com", "group": "", "type": "TOTP"}
]
JSON
  fi
  exit 0
fi

# --show: only GitHub is ever actually revealed by the test, but answer
# every account for robustness.
account=""
prev=""
for arg in "$@"; do
  if [[ "$prev" == "-a" ]]; then account="$arg"; fi
  prev="$arg"
done
case "$account" in
  "pavan@smaply.com")
    echo '[{"type": "TOTP", "account": "pavan@smaply.com", "issuer": "GitHub", "current": "482913", "validity_seconds": 30}]'
    exit 0
    ;;
  *)
    echo "[]"
    exit 255
    ;;
esac
