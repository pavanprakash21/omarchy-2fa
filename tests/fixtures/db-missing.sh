#!/usr/bin/env bash
# Verbatim string confirmed against a real otpclient-cli 5.1.6 pointed at a
# nonexistent database path (NOT the "...does not exist." wording upstream
# source suggested for a different code path -- see Cli.js's module
# docstring).
echo "Error while loading the database: Missing database file" >&2
exit 255
