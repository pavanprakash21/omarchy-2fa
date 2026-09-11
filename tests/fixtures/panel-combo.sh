#!/usr/bin/env bash
# Combined --list/--show fixture for tests/panel.qmltest.qml.
#
# PanelState.qml wires ONE Backend instance to serve both the --list call
# (on open()/refresh()) and the --show call (on activateSelected()), same
# as production use -- unlike backend.qmltest.qml's scenarios, which each
# exercise only one kind of call against a static fixture, a PanelState
# test needs a single fixture that answers correctly for both, and for
# --show, for whichever row was actually activated. Branches on argv
# (Cli.js's listArgv()/showArgv() shapes) to do that.
#
# Inventory: two TOTP rows and one HOTP row, matching the shapes
# tests/fixtures/ok-list.sh and friends already established.
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

# --show: find the -a value to answer for the right row.
account=""
prev=""
for arg in "$@"; do
  if [[ "$prev" == "-a" ]]; then account="$arg"; fi
  prev="$arg"
done

case "$account" in
  "pavan@smaply.com")
    # A short validity_seconds keeps tests/panel.qmltest.qml's countdown/
    # auto-clear scenario fast.
    echo '[{"type": "TOTP", "account": "pavan@smaply.com", "issuer": "GitHub", "current": "482913", "validity_seconds": 3}]'
    exit 0
    ;;
  "alice@example.com")
    echo '[{"type": "TOTP", "account": "alice@example.com", "issuer": "Example", "current": "111222", "validity_seconds": 25}]'
    exit 0
    ;;
  "acct1")
    # Real HOTP --show never reports validity_seconds (verified against a
    # real database -- see Cli.js), which is exactly what this fixture
    # omits, so PanelState.qml's hotpRevealFallbackSeconds path is
    # exercised for real rather than assumed.
    echo '[{"type": "HOTP", "account": "acct1", "issuer": "Bank", "current": "999111", "counter": 11}]'
    exit 0
    ;;
  *)
    echo "[]"
    exit 255
    ;;
esac
