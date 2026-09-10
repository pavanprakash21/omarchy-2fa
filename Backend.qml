import QtQuick
import Quickshell.Io
import "Cli.js" as Cli

// Backend.qml -- the only thing in this plugin that talks to otpclient-cli.
//
// Two calls, and only two:
//   otpclient-cli --list --output=json                        (listInventory)
//   otpclient-cli --show -a <account> [-i <issuer>] -m --output=json
//                                              (requestCode / requestHotpCode)
// `-m/--match-exact` is always included on --show -- see Cli.js. There is no
// argv builder for the export flag anywhere in this file or Cli.js: it
// writes plaintext secrets to disk and must never be invoked.
//
// This was written and verified against a real otpclient-cli (OTPClient
// 5.1.6) and a scratch database -- see the PR description for the exact
// commands run. Several details below differ from the original issue text
// and from upstream source because the real binary disagreed with both;
// each such spot is called out where it matters.
//
// Security invariants (see issue #2):
// - `command` is always an argv array, never a shell string, so an
//   issuer/account read out of the database can't be interpreted by a shell.
// - The binary path is resolved from a fixed candidate list and cached; the
//   resolved path is what's used in every subsequent `command` array, never
//   an issuer/account.
// - Every invocation is wrapped in `/usr/bin/timeout -s KILL <n>` (OS-level
//   deadline) *and* guarded by a QML Timer watchdog (deadline+2s, belt and
//   suspenders) so a CLI blocked on a stdin password prompt surfaces as the
//   typed `would-prompt` state instead of hanging the shell. This mirrors
//   the discipline in ~/.config/omarchy/plugins/zeru.portwatch/Widget.qml.
// - A code or password is never logged, cached beyond the single signal
//   emission that hands it to the caller, or written anywhere. `entries`
//   (the --list cache) only ever holds issuer/account/group/type -- the
//   --list payload has no code in it to begin with.
// - Only one otpclient-cli invocation runs at a time, full stop -- not just
//   "one list at a time" and separately "one show at a time". CONFIRMED:
//   running two invocations against the same database concurrently
//   corrupts both (observed exit 1 with empty output on one, a stray
//   GDBus/org.gtk.Actions D-Bus registration error on the other's stderr,
//   neither of which looks like an error at a glance). Sequential calls
//   were clean every time. _inFlight below is the single gate for this,
//   shared by listInventory()/requestCode()/requestHotpCode().
//
// PRECONDITION (discovered, not otherwise documented in issue #2): neither
// argv this file builds includes -d/--database, matching the issue's exact
// contract. `otpclient-cli --help` says -d "Default value is taken from
// GSettings/otpclient.cfg" -- confirmed: on a machine with no such default
// set (e.g. otpclient-cli never configured via the GUI, as on the machine
// this was developed on), --list with no -d prompts *interactively for a
// database path* ("Type the absolute path to the database:") over stdin,
// which hangs exactly like the password prompt under the same conditions
// and is caught the same way, landing in `would-prompt`. In other words:
// this widget assumes the user already has OTPClient set up with a default
// database (GUI or `otpclient-cli --import`, which registers one) -- a
// perfectly reasonable assumption for this plugin's premise, but worth
// confirming with whoever owns settings/onboarding for this plugin, since
// "no default database configured yet" is indistinguishable here from
// "Secret Service is off", both being would-prompt.
//
// KNOWN RESIDUAL RISK (documented, not mitigated here -- out of Backend's
// scope per issue #2, which excludes reading/writing the database
// directly): the database directory also holds a `<name>.lock` file and a
// `<name>.bak` backup that otpclient-cli itself manages. If the hard
// timeout ever fires while a write is genuinely in progress (only possible
// for an HOTP show, since that's the only mutating call) rather than while
// the CLI is blocked on the password prompt before any DB access, SIGKILL
// could in theory leave a stale lock or a torn backup behind. The default
// timeoutMs (4000) is ~18x the ~0.22s Argon2id cost measured against the
// real binary, which should keep this from ever firing on a genuine
// in-progress write, but Backend does not (and per the issue, must not)
// attempt to detect or clean up a leftover lock file itself.
Item {
  id: root

  // ---- Configuration --------------------------------------------------

  // Absolute paths to probe for otpclient-cli, in order. Never resolved
  // through PATH/a shell, and never invoked directly -- always through
  // Cli.wrap() below. Overridable so tests can point this at a fixture
  // script instead of the real binary.
  property var binaryCandidates: ["/usr/bin/otpclient-cli", "/usr/local/bin/otpclient-cli"]

  // Hard wall-clock ceiling for one invocation, in milliseconds. Argon2id
  // at the CLI's default parameters measured ~0.22s against a real
  // database on this machine; 4s leaves generous headroom on a loaded
  // machine while still failing fast into `would-prompt` when Secret
  // Service is off and the CLI is blocked reading a password from stdin.
  property int timeoutMs: 4000

  // ---- Read-only state --------------------------------------------------

  // "" until a call has actually been attempted (Backend never spawns
  // anything on its own -- there is no Component.onCompleted here). Once an
  // attempt has run, this is either the absolute path that actually exec'd,
  // or "" if every candidate came back "not found"/"not executable".
  readonly property bool binaryResolved: root._binaryResolved
  readonly property string binaryPath: root._binaryPath

  readonly property bool listBusy: root._inFlight && root._activeKind === "list"
  readonly property bool showBusy: root._inFlight && root._activeKind === "show"
  readonly property bool busy: root._inFlight

  // Last successful --list result: array of {issuer, account, group, type}.
  // Never contains a code. Cleared to [] on any non-ok list outcome so
  // stale rows can't be mistaken for a fresh read. The UI is expected to
  // pass an entry's own `type` back into requestCode()'s third argument --
  // see requestCode()/requestHotpCode() below.
  property var entries: []

  // ---- Signals (this is the API the UI/#6 consumes) ---------------------

  // Emitted after a successful --list with at least one entry.
  signal listSucceeded(var entries)
  // Emitted for every non-"ok" --list outcome, `state` is one of:
  // binary-missing, would-prompt, bad-password, db-missing, malformed, empty.
  signal listFailed(string state, string message)

  // Emitted after a successful --show (TOTP via requestCode(), or HOTP via
  // the explicit requestHotpCode()). `entry` is
  // {issuer, account, type, current, secondsRemaining, counter}.
  // secondsRemaining is time left in the CURRENT period, not the period
  // length -- otpclient-cli does not expose the period itself anywhere.
  // counter is only meaningful for HOTP and reflects the value *after* this
  // call already advanced and persisted it.
  signal showSucceeded(string issuer, string account, var entry)
  // Emitted for every non-"ok" --show outcome, same six `state` values.
  signal showFailed(string issuer, string account, string state, string message)

  // ---- Public functions ---------------------------------------------------

  // Triggers a fresh inventory read. Returns false (no-op) if any call --
  // list or show -- is already in flight; see the concurrency note above
  // for why this can't be relaxed to "just check listBusy".
  function listInventory() {
    if (root._inFlight) return false
    root._begin("list")
    listProc._issuer = ""
    listProc._account = ""
    root._startAttempt(listProc, Cli.listArgv(), 0)
    return true
  }

  // Requests exactly one code for (issuer, account). This is the path for
  // TOTP entries (and any entry whose type isn't known to be HOTP): it is
  // read-only against the database and safe to call repeatedly.
  //
  // `type` should be the `type` field from the --list entry this call
  // corresponds to (e.g. entry.type). When it is "HOTP" (case-insensitive)
  // this function refuses and does nothing -- otpclient-cli's --show
  // CONFIRMS ADVANCES AND PERSISTS the HOTP counter on every call (verified
  // 7 -> 8 -> 9 across three successive calls against a real database), so
  // an HOTP code must only ever be requested through the explicitly-named
  // requestHotpCode() below, never through this one. If `type` is omitted
  // this guard cannot run -- callers should always pass it when known; it
  // only exists to catch an accidental call, not to replace a UI-level
  // confirmation gate for HOTP (see issue #5).
  //
  // Returns false without spawning anything if account is empty (--account
  // is documented mandatory for --show), if type is "HOTP", or if any call
  // is already in flight.
  function requestCode(issuer, account, type) {
    if (String(type || "").toUpperCase() === "HOTP") {
      console.warn("Backend.requestCode() refused for a HOTP entry (" + issuer + "/" + account + "); use requestHotpCode() explicitly -- it advances and persists the counter.")
      return false
    }
    return root._requestShow(issuer, account)
  }

  // Explicit, separate entry point for HOTP entries. Functionally the same
  // otpclient-cli invocation as requestCode(), but named and documented
  // distinctly on purpose: calling this ADVANCES AND PERSISTS the token's
  // counter in the database, is not idempotent, and is not safe to retry
  // automatically on failure (a failed/timed-out call may or may not have
  // already advanced the counter server-side -- otpclient-cli gives no way
  // to tell from here). The UI (#5) is expected to gate this behind an
  // explicit user confirmation, not call it from anything automatic.
  function requestHotpCode(issuer, account) {
    return root._requestShow(issuer, account)
  }

  // ---- Internals ------------------------------------------------------

  property bool _binaryResolved: false
  property string _binaryPath: ""
  property bool _inFlight: false
  property string _activeKind: ""

  function _begin(kind) {
    root._inFlight = true
    root._activeKind = kind
  }

  function _requestShow(issuer, account) {
    if (!account) return false // -a/--account is mandatory for --show
    if (root._inFlight) return false
    root._begin("show")
    showProc._issuer = String(issuer || "")
    showProc._account = String(account)
    root._startAttempt(showProc, Cli.showArgv(showProc._issuer, showProc._account), 0)
    return true
  }

  function _startAttempt(proc, argvTail, candidateIndex) {
    proc._finished = false
    proc._argvTail = argvTail

    if (root._binaryResolved) {
      if (!root._binaryPath) {
        root._finish(proc, "binary-missing", root._missingMessage())
        return
      }
      proc._candidateIndex = -1
      proc._triedPath = root._binaryPath
      proc.command = Cli.wrap(root._binaryPath, argvTail, root.timeoutMs)
      proc.running = true
      return
    }

    if (candidateIndex >= root.binaryCandidates.length) {
      root._binaryResolved = true
      root._binaryPath = ""
      root._finish(proc, "binary-missing", root._missingMessage())
      return
    }

    var candidate = root.binaryCandidates[candidateIndex]
    proc._candidateIndex = candidateIndex
    proc._triedPath = candidate
    proc.command = Cli.wrap(candidate, argvTail, root.timeoutMs)
    proc.running = true
  }

  function _missingMessage() {
    return "otpclient-cli not found (checked: " + root.binaryCandidates.join(", ") + ")"
  }

  // QProcess::ExitStatus -- no named QML enum is exposed for this by
  // Quickshell's Process type, so the raw value is used directly (0 =
  // NormalExit, 1 = CrashExit).
  readonly property int _crashExit: 1

  // Shared by both Process items' onExited. `proc._candidateIndex >= 0`
  // means we're still walking binaryCandidates for the very first call this
  // session; once one candidate actually execs (any outcome other than
  // "not found"/"not executable"), that path is locked in for every future
  // call, list or show alike.
  function _handleExit(proc, exitCode, exitStatus, kind) {
    if (proc._finished) return // watchdog already resolved this attempt

    // CONFIRMED against the real binary: when `timeout -s KILL` actually
    // has to kill something, Qt/Quickshell does NOT surface the clean
    // exitCode=137 that `man timeout` documents. It surfaces
    // exitStatus=CrashExit with a platform-specific exitCode (observed:
    // the raw signal number, 9). Since -s KILL is the only signal this
    // component ever sends anywhere in the process tree, ANY CrashExit
    // here is treated as our own timeout firing -- there is nothing else
    // it could be. The exitCode-based 124/137 check further down is kept
    // only as a defensive fallback for a platform that does report a clean
    // NormalExit for a timeout.
    if (exitStatus === root._crashExit) {
      if (!root._binaryResolved) {
        root._binaryResolved = true
        root._binaryPath = proc._triedPath
      }
      root._finish(proc, "would-prompt",
        "otpclient-cli did not respond within " + root.timeoutMs + "ms and was killed " +
        "(likely blocked on a password prompt because Secret Service is unavailable).")
      return
    }

    if (Cli.isMissingExit(exitCode)) {
      if (proc._candidateIndex >= 0 && proc._candidateIndex < root.binaryCandidates.length - 1) {
        root._startAttempt(proc, proc._argvTail, proc._candidateIndex + 1)
        return
      }
      root._binaryResolved = true
      root._binaryPath = ""
      root._finish(proc, "binary-missing", root._missingMessage())
      return
    }

    // This candidate actually executed. Lock it in before anything else --
    // any exit reaching this point is a real answer from a real binary,
    // not evidence the path is wrong.
    if (!root._binaryResolved) {
      root._binaryResolved = true
      root._binaryPath = proc._triedPath
    }

    if (Cli.isTimeoutExit(exitCode)) {
      root._finish(proc, "would-prompt",
        "otpclient-cli did not respond within " + root.timeoutMs + "ms " +
        "(likely blocked on a password prompt because Secret Service is unavailable).")
      return
    }

    var result = Cli.classify(exitCode, proc._stdout ? proc._stdout.text : "", proc._stderr ? proc._stderr.text : "", kind)
    if (result.state === "ok") {
      if (kind === "list") root._finishListOk(proc, result.entries)
      else root._finishShowOk(proc, result.entry)
      return
    }
    root._finish(proc, result.state, result.message)
  }

  function _finishListOk(proc, entries) {
    if (proc._finished) return
    proc._finished = true
    root.entries = entries
    root._end()
    root.listSucceeded(entries)
  }

  function _finishShowOk(proc, entry) {
    if (proc._finished) return
    proc._finished = true
    root._end()
    root.showSucceeded(proc._issuer, proc._account, entry)
  }

  // Single exit point for every non-ok outcome, for both list and show.
  // Idempotent: the watchdog and the normal exit path both funnel through
  // here and only the first caller wins.
  function _finish(proc, state, message) {
    if (proc._finished) return
    proc._finished = true
    root._end()
    if (proc === listProc) {
      root.entries = []
      root.listFailed(state, message)
    } else {
      root.showFailed(proc._issuer, proc._account, state, message)
    }
  }

  function _end() {
    root._inFlight = false
    root._activeKind = ""
  }

  Process {
    id: listProc
    property int _candidateIndex: -1
    property string _triedPath: ""
    property var _argvTail: []
    property bool _finished: true
    property string _issuer: ""
    property string _account: ""
    property alias _stdout: listStdout
    property alias _stderr: listStderr

    onRunningChanged: {
      if (running) listWatchdog.restart()
      else listWatchdog.stop()
    }
    onExited: function (exitCode, exitStatus) {
      root._handleExit(listProc, exitCode, exitStatus, "list")
    }

    stdout: StdioCollector { id: listStdout; waitForEnd: true }
    stderr: StdioCollector { id: listStderr; waitForEnd: true }
  }

  Process {
    id: showProc
    property int _candidateIndex: -1
    property string _triedPath: ""
    property var _argvTail: []
    property bool _finished: true
    property string _issuer: ""
    property string _account: ""
    property alias _stdout: showStdout
    property alias _stderr: showStderr

    onRunningChanged: {
      if (running) showWatchdog.restart()
      else showWatchdog.stop()
    }
    onExited: function (exitCode, exitStatus) {
      root._handleExit(showProc, exitCode, exitStatus, "show")
    }

    stdout: StdioCollector { id: showStdout; waitForEnd: true }
    stderr: StdioCollector { id: showStderr; waitForEnd: true }
  }

  // Backstop behind `timeout -s KILL`, exactly as scanWatchdog/killWatchdog
  // back up zeru.portwatch's own inner timeouts: if the wrapped `timeout`
  // process somehow never reports back at all (no exited signal, e.g. if
  // /usr/bin/timeout itself were missing -- unreachable in practice on any
  // Arch/Omarchy install, but not provable from here), this guarantees
  // _inFlight still clears and the call still resolves to a typed state
  // instead of wedging the widget for the rest of the session. Margin is
  // generous (timeoutMs + 2s) since the OS-level timeout should always win
  // first -- confirmed: a real killed invocation reported back in ~1.00s
  // against a 1s deadline, i.e. no observable slack was needed.
  Timer {
    id: listWatchdog
    interval: root.timeoutMs + 2000
    onTriggered: {
      if (listProc.running) {
        listProc.running = false
        root._finish(listProc, "would-prompt", "otpclient-cli invocation did not complete within the timeout window and was force-stopped.")
      }
    }
  }

  Timer {
    id: showWatchdog
    interval: root.timeoutMs + 2000
    onTriggered: {
      if (showProc.running) {
        showProc.running = false
        root._finish(showProc, "would-prompt", "otpclient-cli invocation did not complete within the timeout window and was force-stopped.")
      }
    }
  }
}
