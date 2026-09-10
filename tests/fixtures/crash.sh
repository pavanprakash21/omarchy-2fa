#!/usr/bin/env bash
# Simulates otpclient-cli crashing on its own (e.g. SIGSEGV/SIGABRT on a
# malformed or adversarial database) almost immediately, well before any
# timeout could plausibly have fired. Used to prove Backend.qml's
# CrashExit corroboration check (exitCode + elapsed time) tells this apart
# from its own -s KILL timeout instead of mislabelling it `would-prompt`.
kill -SEGV $$
