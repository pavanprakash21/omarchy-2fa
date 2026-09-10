#!/usr/bin/env bash
# Drives backend.qmltest.qml under the real Quickshell runtime and checks
# its output for PASS/FAIL/ALL_DONE markers.
#
# Why this exists: `quickshell -p <file>.qml` runs a file as a full shell
# config rather than a script, and Qt.quit() has no effect inside it (the
# shell is meant to be long-lived), so there is no clean "exit when done"
# signal to wait on. Instead: launch it in the background, poll its log
# for the ALL_DONE marker the test file itself prints once every scenario
# has reported in, then kill the process. Nothing here needs a live
# otpclient-cli database -- see the fixtures/ directory and Cli.js's
# module docstring for exactly what is and isn't verified this way.
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$DIR/.." && pwd)"

# Quickshell refuses to import QML modules from outside the launched file's
# own directory ("Module path ... is outside of the config folder"), and a
# same-directory sibling only resolves as a type with no import statement
# at all -- so Backend.qml/Cli.js have to sit right next to the test file
# for `import "../"` to be unnecessary. Rather than keep a duplicate copy
# of the component under test in the repo, stage a throwaway copy for the
# run and delete it on exit.
WORKDIR="$(mktemp -d)"
LOG="$(mktemp)"
cleanup() {
  [ -n "${PID:-}" ] && kill "$PID" 2>/dev/null || true
  rm -rf "$WORKDIR" "$LOG"
}
trap cleanup EXIT

cp "$REPO/Backend.qml" "$REPO/Cli.js" "$DIR/backend.qmltest.qml" "$WORKDIR/"
cp -r "$DIR/fixtures" "$WORKDIR/fixtures"

quickshell -p "$WORKDIR/backend.qmltest.qml" >"$LOG" 2>&1 &
PID=$!

# Generous ceiling: the slowest scenario (would-prompt) waits out a 700ms
# timeout; 15s covers that many times over on a loaded machine.
DEADLINE=$((SECONDS + 15))
while ! grep -q "ALL_DONE" "$LOG" 2>/dev/null; do
  if [ "$SECONDS" -ge "$DEADLINE" ]; then
    echo "TIMED OUT waiting for ALL_DONE -- log so far:" >&2
    cat "$LOG" >&2
    exit 1
  fi
  if ! kill -0 "$PID" 2>/dev/null; then
    echo "quickshell exited early -- log:" >&2
    cat "$LOG" >&2
    exit 1
  fi
  sleep 0.2
done

kill "$PID" 2>/dev/null || true

grep -E "PASS |FAIL |ALL_DONE" "$LOG" | sed -E 's/^.*(PASS |FAIL |ALL_DONE)/\1/'

if grep -q "^FAIL " <(grep -E "PASS |FAIL " "$LOG" | sed -E 's/^.*(PASS |FAIL )/\1/'); then
  exit 1
fi
if ! grep -q "ALL_DONE ok" "$LOG"; then
  exit 1
fi
exit 0
