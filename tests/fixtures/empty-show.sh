#!/usr/bin/env bash
# Confirmed real behavior for "--show" with no matching account: exit 255,
# EMPTY stderr, and stdout is the JSON literal "[]". There is no
# "No matching token found." message at runtime in otpclient-cli 5.1.6
# despite that string existing in upstream source for a different path.
echo "[]"
exit 255
