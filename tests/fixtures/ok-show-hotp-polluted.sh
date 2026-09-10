#!/usr/bin/env bash
# Confirmed real behavior for an HOTP --show call: it mutates the database
# (advances and persists the counter) and, as a side effect, prints
# diagnostic lines on STDOUT ahead of the JSON payload -- despite the man
# page's claim that diagnostics go to stderr. This fixture reproduces that
# exact pollution so Backend.qml's extractJson-based parsing is exercised
# end-to-end through the real Process/StdioCollector pipeline, not just in
# the pure-JS tests.
cat <<'OUT'
Backup copy successfully created.
Backup copy successfully created.
[
  {"type": "HOTP", "account": "acct1", "issuer": "Bank", "current": "453172", "counter": 8}
]
OUT
exit 0
