#!/usr/bin/env bash
# Same shape as ok-list.sh, but with an artificial delay -- used to open a
# window during which a second Backend instance's call can be observed
# being refused by the process-wide shared gate (Shared.js), then
# succeeding once this one finishes. 300ms is comfortably inside every
# scenario's timeoutMs elsewhere in this suite (3000ms) while still being
# long enough for the test to reliably observe the refusal.
sleep 0.3
cat <<'JSON'
[
  {"issuer": "GitHub", "account": "pavan@smaply.com", "group": "Work", "type": "TOTP"}
]
JSON
exit 0
