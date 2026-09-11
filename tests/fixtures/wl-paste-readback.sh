#!/usr/bin/env bash
# Stands in for /usr/bin/wl-paste --no-newline for tests/panel.qmltest.qml.
# Echoes back (without a trailing newline, matching --no-newline's real
# contract) whatever wl-copy-capture.sh most recently captured, so
# PanelState.qml's clipboardClearSeconds "still ours" comparison
# (Logic.clipboardStillOurs) can be exercised without a real clipboard.
DIR="$(cd "$(dirname "$0")" && pwd)"
printf '%s' "$(cat "$DIR/clipboard-capture.txt" 2>/dev/null)"
exit 0
