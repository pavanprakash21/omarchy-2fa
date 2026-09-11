#!/usr/bin/env bash
# --list fixture for the adversarial-review deny-list regression test
# (tests/panel.qmltest.qml, "unknown type requires confirmation"): a single
# entry whose type is neither "TOTP" nor "HOTP". Not reachable through
# today's real otpclient-cli (it only ever emits those two literal
# strings), but PanelState.qml's confirm gate must not silently allow an
# unrecognized type through unconfirmed -- see PanelLogic.js's
# isDefinitivelyTotp()/requiresConfirmation().
set -e
for arg in "$@"; do
  if [[ "$arg" == "--list" ]]; then
    echo '[{"issuer": "Mystery", "account": "acct", "group": "", "type": ""}]'
    exit 0
  fi
done
# --show: always "succeeds" so a wrongly-unconfirmed activation would be
# observable as an immediate reveal rather than a busy/error no-op.
echo '[{"type": "", "account": "acct", "issuer": "Mystery", "current": "000000", "validity_seconds": 30}]'
exit 0
