#!/usr/bin/env bash
# Issue #24: confirmed real transcript against a real otpclient-cli 5.1.6 --
# a CONFIGURED database with Secret Service off, once stdin is closed
# rather than left open: the password prompt gets immediate EOF and gives
# up with this exact text instead of hanging. Distinct from no-database.sh
# (no configured database at all). Runs and exits almost instantly, unlike
# hang.sh (which still exists to exercise the CrashExit/timeout BACKSTOP
# path for a genuine, unrelated hang -- see Backend.qml's _handleExit()).
echo "Empty password not allowed" >&2
echo "No password provided, exiting." >&2
exit 255
