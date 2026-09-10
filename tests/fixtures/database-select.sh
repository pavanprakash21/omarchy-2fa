#!/usr/bin/env bash
# Stands in for otpclient-cli's response to `-d/--database <value>` being
# PRESENT vs. ABSENT in argv -- this is what proves Backend.qml/Cli.js
# actually thread PanelState's `database` setting into EVERY invocation
# (listInventory()/requestCode()/requestHotpCode() alike), not just build an
# argv helper that nothing ends up calling.
#
# Issue #17's own acceptance bar: "a test covers both, and fails if the flag
# is dropped." A fixture that returns the same canned JSON regardless of
# argv would pass whether or not --database is actually wired up -- worthless
# by that bar. This one instead returns DELIBERATELY DIFFERENT, easily
# distinguished output depending on whether "--database $EXPECTED_DB" is
# present: if Backend.qml/Cli.js stop passing it (or pass the wrong value),
# the response silently but visibly switches from the "FixtureDB"/"matched"
# shape to the "DefaultDB"/"unmatched" one, and tests/backend.qmltest.qml's
# "database wiring" scenario below goes red.
EXPECTED_DB="/fixture/expected.db"

database=""
prev=""
is_list=0
for arg in "$@"; do
  if [[ "$prev" == "--database" ]]; then database="$arg"; fi
  if [[ "$arg" == "--list" ]]; then is_list=1; fi
  prev="$arg"
done

if [[ "$is_list" == "1" ]]; then
  if [[ "$database" == "$EXPECTED_DB" ]]; then
    echo '[{"issuer": "FixtureDB", "account": "matched", "group": "", "type": "TOTP"}]'
  else
    echo '[{"issuer": "DefaultDB", "account": "unmatched", "group": "", "type": "TOTP"}]'
  fi
  exit 0
fi

# --show: same distinguishing logic, deliberately independent of -a/-i so
# this fixture only ever tells the caller ONE thing -- whether --database
# reached this invocation with the expected value -- and can't be
# accidentally satisfied by matching on the account instead.
if [[ "$database" == "$EXPECTED_DB" ]]; then
  echo '[{"type": "TOTP", "account": "matched", "issuer": "FixtureDB", "current": "555000", "validity_seconds": 30}]'
else
  echo '[{"type": "TOTP", "account": "unmatched", "issuer": "DefaultDB", "current": "000111", "validity_seconds": 30}]'
fi
exit 0
