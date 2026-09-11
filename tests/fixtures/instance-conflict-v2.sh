#!/usr/bin/env bash
# Issue #25: the OTHER confirmed real-world stderr shape for the exact same
# GApplication D-Bus single-instance race that instance-conflict.sh
# simulates (see Cli.js's ISSUE #25 note) -- observed on a live run with
# the OTPClient GUI open, and NOT recognized by the original
# isInstanceConflictStderr(), which only matched the org.gtk.Actions/
# UnknownMethod signature. That gap is exactly what made issue #25 a
# misdiagnosis: this fell through to "malformed" instead.
echo 'GDBus.Error:org.freedesktop.DBus.Error.NotSupported: Application does not handle command line arguments' >&2
exit 1
