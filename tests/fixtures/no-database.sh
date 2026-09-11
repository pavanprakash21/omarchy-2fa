#!/usr/bin/env bash
# Issue #24: confirmed real transcript (by the issue's own reporter,
# against a real otpclient-cli 5.1.6 with no default database configured
# anywhere -- no -d/--database, no GSettings default) once stdin is closed
# rather than left open: the interactive "Type the absolute path to the
# database:" prompt gets immediate EOF and gives up with this exact text.
# Distinct from db-missing.sh (a *configured* path that doesn't exist).
echo "Type the absolute path to the database: Couldn't get db path from stdin" >&2
exit 255
