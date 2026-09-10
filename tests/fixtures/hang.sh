#!/usr/bin/env bash
# Simulates otpclient-cli blocked reading a password from stdin because
# Secret Service is unavailable and no --password-file was given: it just
# sits there. Sleeps far longer than any timeoutMs used in the test suite,
# so it is only ever ended by the `timeout -s KILL` wrapper (or, if that
# somehow failed, Backend.qml's own watchdog Timer).
sleep 30
