#!/usr/bin/env bash
# Simulates a broken/partial JSON payload (truncated pipe, wrong --output
# value handled unexpectedly, a future otpclient-cli version changing its
# format, etc.) that must not crash the widget or be silently misread.
echo "not actually json {"
exit 0
