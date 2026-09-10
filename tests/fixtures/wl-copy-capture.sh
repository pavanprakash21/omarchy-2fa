#!/usr/bin/env bash
# Stands in for /usr/bin/wl-copy for tests/panel.qmltest.qml. Captures
# whatever PanelState.qml wrote to STDIN (never argv -- issue #5 requires
# the code go over stdin only) to a file next to this script, so the test
# can assert on it without ever touching the real Wayland clipboard.
#
# `--clear` (PanelState.qml's clearCopyProc) removes the captured file
# instead of reading stdin: a real wl-copy --clear takes no stdin at all,
# and Quickshell's Process gives a child an OPEN pipe with no writer by
# default when stdinEnabled is false (see Backend.qml/Cli.js's own note on
# this) -- `cat` would block forever waiting for an EOF nothing will ever
# send.
DIR="$(cd "$(dirname "$0")" && pwd)"
if [[ "$1" == "--clear" ]]; then
  rm -f "$DIR/clipboard-capture.txt"
  exit 0
fi
cat > "$DIR/clipboard-capture.txt"
exit 0
