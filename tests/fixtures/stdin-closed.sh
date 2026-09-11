#!/usr/bin/env bash
# Issue #24 regression guard: proves Backend.qml actually closes the
# child's stdin (see Backend.qml's _spawn()/onRunningChanged) rather than
# leaving it an open, silent pipe. `read` with no -t below returns
# immediately (false, no output captured) once stdin hits EOF; if stdin
# were left open instead (the pre-#24 bug), this blocks until the
# surrounding `timeout -s KILL` wrapper forcibly kills it, and the caller
# sees `would-prompt`/`crashed` after the full timeoutMs instead of this
# fixture's own fast, deterministic exit.
if read -r line; then
  echo "STDIN_NOT_CLOSED:$line" >&2
else
  echo "STDIN_CLOSED_OK" >&2
fi
exit 1
