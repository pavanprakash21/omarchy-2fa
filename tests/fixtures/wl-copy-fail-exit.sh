#!/usr/bin/env bash
# Stands in for a wl-copy that STARTS but fails (as opposed to a
# nonexistent binary path, which never starts at all -- both are exercised
# separately in tests/panel.qmltest.qml's clipboard-failure regression
# tests, since Quickshell's Process surfaces them differently: this one
# fires a real `exited` signal with a nonzero code; a missing binary fires
# neither `started` nor `exited` at all -- see PanelState.qml's copyProc
# docstring). Drains stdin first so the writer (PanelState.qml's
# `write()` + `stdinEnabled = false`) never blocks on a full pipe.
cat >/dev/null
exit 1
