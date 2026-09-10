#!/usr/bin/env bash
# Drives every *.qmltest.qml file under the real Quickshell runtime and
# checks each one's output for PASS/FAIL/ALL_DONE markers.
#
# Why this exists: `quickshell -p <file>.qml` runs a file as a full shell
# config rather than a script, and Qt.quit() has no effect inside it (the
# shell is meant to be long-lived), so there is no clean "exit when done"
# signal to wait on. Instead: launch it in the background, poll its log for
# the ALL_DONE marker the test file itself prints once every scenario has
# reported in, then kill the process.
#
# Nothing run here needs a live otpclient-cli database or the real Wayland
# clipboard -- see the fixtures/ directory, Cli.js's module docstring, and
# panel.qmltest.qml's own header for exactly what is and isn't verified
# this way. In particular, panel.qmltest.qml never instantiates Popup.qml
# (the actual PopupWindow) -- PanelState.qml is a plain Item, so this run
# never maps a window on screen even though it executes under a real,
# live Quickshell/Wayland connection.
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$DIR/.." && pwd)"

# Quickshell refuses to import QML modules from outside the launched file's
# own directory ("Module path ... is outside of the config folder"), and a
# same-directory sibling only resolves as a type with no import statement
# at all -- so every source file a test file needs has to sit right next to
# it. Rather than keep duplicate copies of the components under test in the
# repo, stage a throwaway copy for the run and delete it on exit.
WORKDIR="$(mktemp -d)"
cleanup() {
  [ -n "${PID:-}" ] && kill "$PID" 2>/dev/null || true
  rm -rf "$WORKDIR"
}
trap cleanup EXIT

cp "$REPO/Backend.qml" "$REPO/Cli.js" "$REPO/Shared.js" \
   "$REPO/PanelState.qml" "$REPO/PanelLogic.js" \
   "$DIR"/*.qmltest.qml \
   "$WORKDIR/"
cp -r "$DIR/fixtures" "$WORKDIR/fixtures"

# The path-lookup scenario (adversarial review item #6: fall back to PATH
# when the fixed absolute candidates aren't found) needs a real executable
# reachable by a bare name via PATH -- stage one and prepend it.
mkdir -p "$WORKDIR/pathbin"
cp "$DIR/fixtures/ok-list.sh" "$WORKDIR/pathbin/otp-fixture-pathlookup-test"
chmod +x "$WORKDIR/pathbin/otp-fixture-pathlookup-test"

OVERALL=0

# Runs one qmltest file to completion, printing its PASS/FAIL lines and
# returning non-zero if anything failed or it never reported in.
# Args: <file basename> <deadline seconds>
run_one() {
  local file="$1"
  local deadline_s="$2"
  local log
  log="$(mktemp)"

  PATH="$WORKDIR/pathbin:$PATH" quickshell -p "$WORKDIR/$file" >"$log" 2>&1 &
  PID=$!

  local deadline=$((SECONDS + deadline_s))
  while ! grep -q "ALL_DONE" "$log" 2>/dev/null; do
    if [ "$SECONDS" -ge "$deadline" ]; then
      echo "TIMED OUT waiting for ALL_DONE in $file -- log so far:" >&2
      cat "$log" >&2
      kill "$PID" 2>/dev/null || true
      PID=""
      rm -f "$log"
      return 1
    fi
    if ! kill -0 "$PID" 2>/dev/null; then
      echo "quickshell exited early running $file -- log:" >&2
      cat "$log" >&2
      PID=""
      rm -f "$log"
      return 1
    fi
    sleep 0.2
  done

  kill "$PID" 2>/dev/null || true
  PID=""

  echo "-- $file --"
  grep -E "PASS |FAIL |ALL_DONE" "$log" | sed -E 's/^.*(PASS |FAIL |ALL_DONE)/\1/'

  local rc=0
  if grep -q "^FAIL " <(grep -E "PASS |FAIL " "$log" | sed -E 's/^.*(PASS |FAIL )/\1/'); then
    rc=1
  fi
  if ! grep -q "ALL_DONE ok" "$log"; then
    rc=1
  fi
  rm -f "$log"
  return $rc
}

# backend.qmltest.qml's scenarios run sequentially (the shared gate makes
# that a correctness requirement, not just a convenience -- see its own
# header), and the slowest single one waits out a 700ms timeout; 25s covers
# the whole chain many times over on a loaded machine.
run_one "backend.qmltest.qml" 25 || OVERALL=1

# panel.qmltest.qml additionally waits out real countdown/confirm-gate
# timers (a 3s reveal countdown, a 3s HOTP confirm auto-disarm, a 1s
# clipboard-clear) on top of several sequential list/show round trips;
# 40s leaves generous headroom over its ~9s typical wall time.
run_one "panel.qmltest.qml" 40 || OVERALL=1

exit $OVERALL
