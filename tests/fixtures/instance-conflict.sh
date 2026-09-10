#!/usr/bin/env bash
# Confirmed real stderr from the losing side of otpclient-cli's GApplication
# D-Bus single-instance race (see Cli.js's CONCURRENCY note) -- observed
# when two invocations run at the same time, e.g. this widget on two
# monitors, or the OTPClient GUI already being open.
echo 'Failed to register: GDBus.Error:org.freedesktop.DBus.Error.UnknownMethod: No such interface "org.gtk.Actions" on object at path /com/github/paolostivanin/OTPClient' >&2
exit 1
