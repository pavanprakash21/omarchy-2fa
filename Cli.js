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
// CONCURRENCY (confirmed, not mentioned anywhere in the issue): running two
// otpclient-cli invocations against the same database at the same time
// corrupts *both* -- observed exit code 1 with empty stdout on one and a
// GDBus/org.gtk.Actions D-Bus registration error on stderr of the other,
// with no indication in either output that anything was wrong. The same
// two invocations run one after the other were both clean. Backend.qml
// therefore serializes ALL invocations (list and show alike) through one
// shared in-flight gate, never just a per-call-kind one.
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

// Wrap the real invocation in `timeout -s KILL <n>`. This is a second,
// OS-enforced deadline on top of the QML-side watchdog timer in Backend.qml
// -- belt and suspenders, mirroring zeru.portwatch's Widget.qml. -s KILL
// (SIGKILL) is required rather than the default SIGTERM: otpclient-cli
// blocked reading a password from stdin (confirmed: it blocks rather than
// failing fast, when stdin is an open pipe with no writer and no data --
// exactly what Quickshell's Process gives a child by default) may not
// react to TERM, and SIGKILL cannot be caught or ignored.
function wrap(binaryPath, argvTail, timeoutMs) {
  return [TIMEOUT_BIN, "-s", "KILL", String(timeoutSeconds(timeoutMs)), binaryPath].concat(argvTail)
}

function listArgv() {
  return ["--list", "--output=json"]
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
function showArgv(issuer, account) {
  var argv = ["--show", "-a", String(account)]
  if (issuer) argv.push("-i", String(issuer))
  argv.push("-m", "--output=json")
  return argv
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
// Returns { state, message, entries? , entry? }. `state` is always one of:
// ok, bad-password, db-missing, would-prompt, malformed, empty.
function classify(exitCode, stdoutText, stderrText, kind) {
  var err = stderrText || ""

  if (isWrapperFailedExit(exitCode)) {
    return { state: "malformed", message: "The timeout wrapper itself failed to run otpclient-cli (exit 125)." }
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
