.pragma library

// Cli.js -- pure helpers for talking to otpclient-cli.
//
// Nothing in this file touches a QML/Quickshell type, so it can be loaded
// and exercised with a plain `node` outside the shell runtime (see
// tests/cli.test.js). Backend.qml owns all process spawning, timers,
// exitStatus interpretation and signal emission; this file only builds
// argv arrays and interprets text that already came back from a finished
// process.
//
// Everything below was checked against a real `otpclient-cli` (OTPClient
// 5.1.6) and a scratch database created for this purpose -- see the PR
// description for exactly which commands were run. Several details in the
// original issue text and in upstream source did NOT hold up and are
// called out inline; this file reflects what was actually observed.
//
// DATABASE OVERRIDE (issue #17): listArgv()/showArgv() both take an
// optional `database` argument and thread it into `-d/--database <value>`
// via the shared _withDatabase() helper below. This was previously a
// documented-but-inert shell.json setting (issue #8) that Backend.qml never
// read; #17 is what actually wires it end to end. See _withDatabase()'s own
// doc comment for the empty-means-unchanged invariant and for why this file
// deliberately does not try to distinguish a path from a
// --list-databases-printed name -- otpclient-cli's own -d/--database
// accepts either, unchanged.
//
// Field names, confirmed against the real binary's --output=json:
//   --list  -> array of {issuer, account, group, type}
//   --show  -> array (always observed array-wrapped, even for one result)
//              of {issuer, account, type, current, validity_seconds,
//                  counter (HOTP only)}. "next"/-n was not exercised.
//   IMPORTANT: validity_seconds is the seconds *remaining* in the current
//   period (observed: 7, then 25, on repeated calls to a 30s TOTP), not the
//   period length. The period itself is not exposed anywhere in the JSON.
// Confirmed stderr strings (English, untranslated; matched case-insensitively,
// and matching degrades to "malformed" rather than hanging if a locale
// translates them):
//   wrong password   -> "Incorrect password."
//   missing database -> "Error while loading the database: Missing database
//                        file" (NOT "...does not exist." as upstream source
//                        for a different code path suggested -- both
//                        patterns are matched defensively)
//   no such account  -> NO stderr at all: exit 255, stdout is "[]". This is
//                        the `empty` state, detected from the parsed JSON
//                        shape, not from stderr.
// Every field is read defensively: wrong type or missing key is treated as
// absent, never thrown.
//
// STDOUT POLLUTION (confirmed): a --show call that *mutates* the database
// (observed on every HOTP call, which persists an advanced counter) prints
// diagnostic lines -- e.g. two lines of "Backup copy successfully created."
// -- on stdout *before* the JSON payload, despite the man page's claim that
// diagnostics go to stderr. extractJson() below scans for the first JSON
// value in the text rather than assuming stdout is pure JSON, and this is
// applied to every call (list and show, mutating or not), not just HOTP,
// since the cost of doing so is zero and the upstream behavior isn't
// documented well enough to trust "only HOTP does this".
//
// HOTP SAFETY (confirmed): --show on an HOTP entry advances and persists
// the counter (verified 7 -> 8 -> 9 across three successive calls) and
// rewrites the database's .bak file every time. This is not idempotent and
// not safe to retry or re-fetch by accident -- see requestHotpCode() in
// Backend.qml, which is a deliberately separate, explicitly-named entry
// point from the ordinary (idempotent, TOTP) requestCode().
//
// CONCURRENCY (corrected after adversarial review -- the original claim
// here was wrong): running two otpclient-cli invocations at the same time
// does NOT corrupt the database -- up to 12-way parallel invocations were
// run repeatedly under adversarial testing with clean md5/content checks
// every time. What actually happens is a GLib GApplication D-Bus
// single-instance race: one process wins and behaves normally, and the
// loser(s) exit 1 having touched no files, with
// "Failed to register: GDBus.Error:org.freedesktop.DBus.Error.UnknownMethod:
// No such interface \"org.gtk.Actions\" on object at path
// /com/github/paolostivanin/OTPClient" on stderr. isInstanceConflictExit()
// below matches that signature so it gets its own typed state
// ("instance-conflict") instead of falling through to "malformed". Backend
// serializes its own invocations anyway (not to prevent corruption, but so
// a losing, wasted invocation doesn't routinely happen just from this
// widget's own list+show calls overlapping), and shares that gate across
// every Backend instance in the process (see Shared.js) since the widget
// renders per-monitor -- but that can't do anything about a fully separate
// process, e.g. the OTPClient GUI, also being open, which is exactly why
// the D-Bus signature is matched and surfaced rather than assumed away.
//
// -m/--match-exact is not optional on --show. Without it, otpclient-cli's
// matching is g_ascii_strcasecmp (case-insensitive *equality*, not
// "contains" despite the man page) -- so a click on one row could silently
// decrypt and return a different account's code. There is no argv builder
// anywhere in this file for the export flag: it writes plaintext secrets to
// disk and must never be invoked.

var TIMEOUT_BIN = "/usr/bin/timeout"

// GNU coreutils `timeout` exit-code contract per `man timeout` (coreutils
// 9.11): 124/137 timed out, 125 wrapper itself failed, 126 found-but-not-
// executable, 127 not found, otherwise the wrapped command's own status.
// CONFIRMED DIFFERENTLY IN PRACTICE for the -s KILL timeout path: Qt's
// QProcess (which Quickshell's Process wraps) does not surface a clean
// exit code of 137 for a KILL-terminated `timeout` -- it reports
// exitStatus=QProcess.CrashExit with a platform-specific exitCode (observed:
// the raw signal number, 9, not 137). Backend.qml treats ANY CrashExit as
// a timeout (see its docstring) since -s KILL is the only signal this
// component ever sends anywhere in the process tree; the numeric checks
// below are kept as a secondary/defensive path for a NormalExit 124/137
// should some platform actually deliver one.
// 127/126 (not found / not executable) WERE confirmed to arrive as a plain
// NormalExit with that exact exitCode, since no signal is involved.
var TIMEOUT_CODE_TERM = 124
var TIMEOUT_CODE_KILL = 137
var WRAPPER_FAILED_CODE = 125
var NOT_EXECUTABLE_CODE = 126
var NOT_FOUND_CODE = 127

function timeoutSeconds(timeoutMs) {
  return Math.max(1, Math.ceil(timeoutMs / 1000))
}

// Wraps ANY argv array in `timeout -s KILL <n>` -- the one, shared
// implementation of the OS-level deadline every subprocess this plugin
// spawns is held to. -s KILL (SIGKILL) is required rather than the default
// SIGTERM: otpclient-cli blocked reading a password from stdin (confirmed:
// it blocks rather than failing fast, when stdin is an open pipe with no
// writer and no data -- exactly what Quickshell's Process gives a child by
// default) may not react to TERM, and SIGKILL cannot be caught or ignored.
// wrap()/wrapViaPath() below are otpclient-cli-specific callers of this;
// GuardedProcess.qml (issue #20 -- PanelState.qml's wl-copy/wl-paste
// processes) is the other, calling this directly rather than duplicating
// the wrapping logic a second time.
function wrapTimeout(argv, timeoutMs) {
  return [TIMEOUT_BIN, "-s", "KILL", String(timeoutSeconds(timeoutMs))].concat(argv)
}

// Wrap the real invocation in `timeout -s KILL <n>`. This is a second,
// OS-enforced deadline on top of the QML-side watchdog timer in Backend.qml
// -- belt and suspenders, mirroring zeru.portwatch's Widget.qml.
function wrap(binaryPath, argvTail, timeoutMs) {
  return wrapTimeout([binaryPath].concat(argvTail), timeoutMs)
}

// Absolute-path fallback: `env` resolves its first argument through PATH
// itself, inside the child, at exec time. This is a cheap way to find an
// otpclient-cli installed somewhere other than /usr/bin or /usr/local/bin
// (a user-local ~/.local/bin install, a Flatpak export shim, etc.) without
// Backend.qml doing its own directory scanning or ever invoking a shell.
// `name` is always one of Backend.qml's own fixed binaryCandidates entries
// (in production, the fixed literal "otpclient-cli"; tests use a different
// fixed name to point this at a fixture script placed on PATH) -- never
// data from the database -- so this doesn't reopen the shell-injection
// concern; it's exactly as safe as any other fixed argv element here.
// The real absolute path `env` finds is not reported back to us; see
// Backend.qml's binaryPath doc comment for what that means for callers.
var PATH_LOOKUP_BIN = "/usr/bin/env"

function wrapViaPath(name, argvTail, timeoutMs) {
  return wrapTimeout([PATH_LOOKUP_BIN, name].concat(argvTail), timeoutMs)
}

// A `binaryCandidates` entry is a request to resolve via PATH (rather than
// a literal absolute path to invoke directly) when it doesn't start with
// "/". Bare command names have no other meaning in this list.
function isPathLookupCandidate(candidate) {
  return typeof candidate === "string" && candidate.length > 0 && candidate.charAt(0) !== "/"
}

// Prepends `-d/--database <value>` (issue #17: threading PanelState's
// `database` setting -- issue #8 -- down into the argv Cli.js builds), but
// ONLY when a value is actually present. `database` falsy (undefined, null,
// or "" -- the shell.json default) returns `argv` completely untouched: this
// is what makes the common, unconfigured path byte-identical to the argv
// this file built before this feature existed, which is the one invariant
// every caller (listArgv()/showArgv() below) most needs to hold exactly.
//
// `otpclient-cli --help` documents -d/--database as accepting EITHER "a
// path to the database" OR "a name from --list-databases" -- confirmed
// against a real otpclient-cli 5.1.6 (see the PR description). This
// function does not, and must not, try to tell those two apart (e.g. by
// sniffing for a leading "/"): the flag itself doesn't care, so guessing
// here would only be one more way to get it wrong for a name that happens
// to look path-shaped (or vice versa). Whatever PanelState's `database`
// setting holds is passed straight through, verbatim, as ITS OWN discrete
// argv element -- never interpolated into `-d<value>` or any other single
// string -- same invariant every other argv element in this file already
// holds (see showArgv()'s own note on shell metacharacters).
function _withDatabase(argv, database) {
  if (!database) return argv
  return ["--database", String(database)].concat(argv)
}

function listArgv(database) {
  return _withDatabase(["--list", "--output=json"], database)
}

// --account is documented by `otpclient-cli --help` as mandatory for
// --show; --issuer is documented optional and only narrows a match. (In
// practice -i alone without -a also worked in the version tested here --
// an upstream inconsistency between --help text and actual behavior, in
// the same spirit as the --match-exact / man-page discrepancy the issue
// already calls out. This builder follows the documented contract: account
// is always required by Backend.qml's requestCode()/requestHotpCode()
// before this is even called, and issuer is included only when present,
// since every entry Backend has on hand -- from a prior --list -- carries
// both fields already.)
//
// `database` (issue #17) is threaded through identically to listArgv()
// above, via the same _withDatabase() helper -- Backend.qml passes the
// SAME `database` value to both builders from the SAME property on every
// call, so --list and --show can never read two different databases just
// because one call site forgot to pass it along.
function showArgv(issuer, account, database) {
  var argv = ["--show", "-a", String(account)]
  if (issuer) argv.push("-i", String(issuer))
  argv.push("-m", "--output=json")
  return _withDatabase(argv, database)
}

function isMissingExit(exitCode) {
  return exitCode === NOT_FOUND_CODE || exitCode === NOT_EXECUTABLE_CODE
}

function isTimeoutExit(exitCode) {
  return exitCode === TIMEOUT_CODE_KILL || exitCode === TIMEOUT_CODE_TERM
}

function isWrapperFailedExit(exitCode) {
  return exitCode === WRAPPER_FAILED_CODE
}

// Confirmed signature of the GApplication D-Bus single-instance race (see
// the CONCURRENCY note above): the losing process's stderr. Matched
// specifically enough (both "failed to register" AND the GDBus.Error
// prefix) that it shouldn't false-positive on an unrelated stderr line.
function isInstanceConflictStderr(stderrText) {
  var err = stderrText || ""
  return /failed to register/i.test(err) && /gdbus\.error/i.test(err)
}

function isPlainObject(v) {
  return v !== null && typeof v === "object" && !Array.isArray(v)
}

// Scans `text` for the first JSON value (array or object) and parses just
// that, ignoring any diagnostic lines before or after it. Required because
// otpclient-cli can print plain-text diagnostics on stdout ahead of the
// actual JSON payload (see module docstring) -- a plain JSON.parse(text)
// would throw on that and misreport a perfectly good result as malformed.
// Returns the parsed value, or null if no balanced JSON value is found.
function extractJson(text) {
  var s = text || ""
  var start = -1
  for (var i = 0; i < s.length; i++) {
    if (s[i] === "[" || s[i] === "{") {
      start = i
      break
    }
  }
  if (start === -1) return null

  var depth = 0
  var inStr = false
  var esc = false
  for (var j = start; j < s.length; j++) {
    var ch = s[j]
    if (inStr) {
      if (esc) esc = false
      else if (ch === "\\") esc = true
      else if (ch === '"') inStr = false
      continue
    }
    if (ch === '"') {
      inStr = true
      continue
    }
    if (ch === "[" || ch === "{") {
      depth++
    } else if (ch === "]" || ch === "}") {
      depth--
      if (depth === 0) {
        var candidate = s.slice(start, j + 1)
        try {
          return JSON.parse(candidate)
        } catch (e) {
          return null
        }
      }
    }
  }
  return null // unbalanced -- truncated output, not a parse we can trust
}

function normalizeEntry(raw) {
  if (!isPlainObject(raw)) return null
  var issuer = typeof raw.issuer === "string" ? raw.issuer : ""
  var account = typeof raw.account === "string" ? raw.account : ""
  if (!issuer && !account) return null // nothing usable to key or match on
  return {
    issuer: issuer,
    account: account,
    group: typeof raw.group === "string" ? raw.group : "",
    type: typeof raw.type === "string" ? raw.type : ""
  }
}

// Parses `--list --output=json`. Never returns a code -- the list payload
// has no "current" field, only inventory data.
function parseList(text) {
  var data = extractJson(text)
  if (data === null) return { ok: false }
  var arr = Array.isArray(data) ? data : [data]
  var entries = []
  for (var i = 0; i < arr.length; i++) {
    var e = normalizeEntry(arr[i])
    if (e) entries.push(e)
  }
  return { ok: true, entries: entries }
}

function normalizeShow(raw) {
  if (!isPlainObject(raw)) return null
  var current = typeof raw.current === "string" ? raw.current : ""
  if (!current) return null // a "show" result with no code is not usable
  return {
    issuer: typeof raw.issuer === "string" ? raw.issuer : "",
    account: typeof raw.account === "string" ? raw.account : "",
    type: typeof raw.type === "string" ? raw.type : "",
    current: current,
    // Seconds *remaining* in the current period -- see module docstring.
    // -1 means "not present in this payload", never a real duration.
    secondsRemaining: typeof raw.validity_seconds === "number" ? raw.validity_seconds : -1,
    counter: typeof raw.counter === "number" ? raw.counter : -1
  }
}

// Parses `--show ... --output=json`. otpclient-cli was observed to always
// array-wrap --show's result (even for a single match), so that shape is
// the primary one; a bare object is tolerated too, defensively.
// Returns { ok, entry } normally, or { ok: false, empty: true } for the
// confirmed "no matching account" shape: exit 255, empty stderr, "[]".
function parseShow(text) {
  var data = extractJson(text)
  if (data === null) return { ok: false, empty: false }
  if (Array.isArray(data)) {
    if (data.length === 0) return { ok: false, empty: true }
    data = data[0]
  }
  var entry = normalizeShow(data)
  if (!entry) return { ok: false, empty: false }
  return { ok: true, entry: entry }
}

// Classifies a run that Backend.qml has already determined did not time
// out and did not fail to exec (both handled upstream of this using
// exitStatus/exitCode -- see Backend.qml). `kind` is "list" or "show".
// Returns { state, message, entries? , entry? }. `state` is one of: ok,
// bad-password, db-missing, malformed, empty, instance-conflict. (Backend
// additionally reports would-prompt and crashed, from exitStatus alone --
// see its docstring -- so this function never returns those two itself.)
function classify(exitCode, stdoutText, stderrText, kind) {
  var err = stderrText || ""

  if (isWrapperFailedExit(exitCode)) {
    return { state: "malformed", message: "The timeout wrapper itself failed to run otpclient-cli (exit 125)." }
  }
  if (isInstanceConflictStderr(err)) {
    return {
      state: "instance-conflict",
      message: "otpclient-cli couldn't start because another instance (the OTPClient GUI, or this widget on another monitor) is already using it. Try again in a moment."
    }
  }
  if (/incorrect password/i.test(err)) {
    return { state: "bad-password", message: "Incorrect database password." }
  }
  if (/missing database file/i.test(err) || /does not exist/i.test(err)) {
    return { state: "db-missing", message: "OTPClient database not found." }
  }
  // Defensive secondary path to would-prompt: only reachable if stdin was
  // closed/EOF rather than the open-but-silent pipe Quickshell's Process
  // gives the child by default (the default case hangs and is caught by
  // Backend.qml's CrashExit check instead -- this is for e.g. a future
  // change to stdinEnabled, or a different Quickshell version's defaults).
  if (/empty password not allowed/i.test(err) || /no password provided/i.test(err)) {
    return { state: "would-prompt", message: "otpclient-cli could not obtain a database password non-interactively." }
  }

  if (kind === "list") {
    var listResult = parseList(stdoutText)
    if (listResult.ok) {
      return listResult.entries.length === 0
        ? { state: "empty", message: "No entries in the database.", entries: [] }
        : { state: "ok", entries: listResult.entries }
    }
  } else {
    var showResult = parseShow(stdoutText)
    if (showResult.empty) {
      return { state: "empty", message: "No matching entry for that issuer/account." }
    }
    if (showResult.ok) {
      return { state: "ok", entry: showResult.entry }
    }
  }

  // Unrecognized outcome -- deliberately not thrown, and stdout is never
  // echoed back into the message for a "show" call, since a mangled JSON
  // payload could still contain a fragment of a code.
  var detail = err.trim() ? " stderr: " + err.trim() : ""
  return { state: "malformed", message: "Could not parse otpclient-cli output." + detail }
}
