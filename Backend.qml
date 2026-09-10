import QtQuick
import Quickshell.Io
import "Cli.js" as Cli
import "Shared.js" as Shared

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
// commands run -- and then independently adversarially reviewed, which
// found and fixed six further issues (a genuine cached-code retention bug,
// a crash/timeout conflation, an overstated concurrency claim, a stale
// .lock narrative, a wrong test fixture, and narrow binary discovery). Both
// rounds are reflected below; several details differ from the original
// issue text and from upstream source because the real binary disagreed
// with both, and each such spot is called out where it matters.
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
// - A decrypted code (or anything else a process printed) is never retained
//   longer than the single signal emission that hands it to the caller.
//   stdout/stderr are collected by StdioCollector instances created fresh
//   for each invocation and explicitly destroyed immediately after the
//   corresponding signal fires -- see _armCollectors()/_disarmCollectors().
//   A password is never read, logged, or handled by this file at all: it
//   never appears in an argv element, an env var, or anywhere else here.
//   `entries` (the --list cache) only ever holds issuer/account/group/type
//   -- the --list payload has no code in it to begin with.
// - Only one otpclient-cli invocation runs at a time within this Backend
//   instance, full stop -- not just "one list at a time" and separately
//   "one show at a time" -- AND that gate is shared across every Backend
//   instance in this quickshell process (the bar renders one per monitor)
//   via Shared.js. See Shared.js and Cli.js's CONCURRENCY note for exactly
//   what this does and doesn't protect against.
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
// THE DATABASE LOCK FILE (corrected after adversarial review -- the
// original comment here was wrong): otpclient-cli creates a `<name>.lock`
// file next to the database on EVERY invocation, success or failure, and
// removes it afterward -- it is not a sign of anything unusual, and it is
// not specific to the HOTP/mutating case. Adversarial testing hammered
// this: dozens of `timeout -s KILL` shots timed around the ~0.22s
// read/write boundary produced no torn write, and a stale lock planted
// ahead of time did not block a subsequent call either. There is no known
// residual risk here to mitigate, and Backend does not (and per the issue,
// must not) touch the lock file or the database directly regardless.
Item {
  id: root

  // ---- Configuration --------------------------------------------------

  // Paths/names to try for otpclient-cli, in order. An entry starting with
  // "/" is invoked directly at that absolute path. A bare entry (no
  // leading "/") is resolved via `/usr/bin/env <name>`, which does its own
  // PATH lookup inside the child at exec time -- see Cli.wrapViaPath()'s
  // doc comment for why that's still safe. Nothing here is ever resolved
  // through a shell, and no candidate is ever built from database content.
  // Overridable so tests can point this at a fixture script instead of the
  // real binary.
  property var binaryCandidates: ["/usr/bin/otpclient-cli", "/usr/local/bin/otpclient-cli", "otpclient-cli"]

  // Hard wall-clock ceiling for one invocation, in milliseconds. Argon2id
  // at the CLI's default parameters measured ~0.22s against a real
  // database on this machine; 4s leaves generous headroom on a loaded
  // machine while still failing fast into `would-prompt` when Secret
  // Service is off and the CLI is blocked reading a password from stdin.
  property int timeoutMs: 4000

  // ---- Read-only state --------------------------------------------------

  // "" until a call has actually been attempted (Backend never spawns
  // anything on its own -- there is no Component.onCompleted here). Once an
  // attempt has run, this is either the path that actually exec'd, or "" if
  // every candidate came back "not found"/"not executable". NOTE: if
  // resolution fell back to a bare PATH-lookup candidate (see
  // binaryCandidates above), this reads as that literal bare name (e.g.
  // "otpclient-cli"), not a true absolute path -- the actual path `env`
  // found is resolved inside the child and never reported back to us.
  readonly property bool binaryResolved: root._binaryResolved
  readonly property string binaryPath: root._binaryPath

  // Reflects only THIS Backend instance's own activity -- true while a
  // call this instance itself started is in flight. A sibling instance
  // (another monitor's Backend, or a call this instance refused because
  // the shared gate -- see Shared.js -- was already held elsewhere) does
  // NOT flip these to true; check the return value of listInventory()/
  // requestCode()/requestHotpCode() (false means refused) if that
  // distinction matters to a caller.
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
  // Emitted for every non-"ok" --list outcome. `state` is one of:
  // binary-missing, would-prompt, bad-password, db-missing, malformed,
  // empty, crashed, instance-conflict. The last two were added after
  // adversarial review found real scenarios the original 7-state list from
  // issue #2 didn't distinguish -- see _handleExit()'s docstring and
  // Cli.js's isInstanceConflictStderr().
  signal listFailed(string state, string message)

  // Emitted after a successful --show (TOTP via requestCode(), or HOTP via
  // the explicit requestHotpCode()). `entry` is
  // {issuer, account, type, current, secondsRemaining, counter}.
  // secondsRemaining is time left in the CURRENT period, not the period
  // length -- otpclient-cli does not expose the period itself anywhere.
  // counter is only meaningful for HOTP and reflects the value *after* this
  // call already advanced and persisted it. `entry` is handed to this
  // signal and then never retained anywhere in this file.
  signal showSucceeded(string issuer, string account, var entry)
  // Emitted for every non-"ok" --show outcome, same eight `state` values
  // documented on listFailed above.
  signal showFailed(string issuer, string account, string state, string message)

  // ---- Public functions ---------------------------------------------------

  // Triggers a fresh inventory read. Returns false (no-op) if any call --
  // list or show, on THIS Backend instance or any other one in this
  // process -- is already in flight; see the shared-gate note above for
  // why this can't be relaxed to "just check listBusy".
  function listInventory() {
    if (!root._begin("list")) return false
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
  // is already in flight anywhere in this process.
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

  // Acquires the process-wide shared gate (Shared.js) and, only if that
  // succeeds, this instance's own local flags (kept separately so
  // listBusy/showBusy/busy stay accurately bound to THIS instance -- see
  // their doc comments). Acquiring both together, in this order, means a
  // caller never observes a local "busy" state without also having
  // actually taken the shared gate.
  function _begin(kind) {
    if (!Shared.tryAcquire(kind)) return false
    root._inFlight = true
    root._activeKind = kind
    return true
  }

  function _end() {
    Shared.release()
    root._inFlight = false
    root._activeKind = ""
  }

  function _requestShow(issuer, account) {
    if (!account) return false // -a/--account is mandatory for --show
    if (!root._begin("show")) return false
    showProc._issuer = String(issuer || "")
    showProc._account = String(account)
    root._startAttempt(showProc, Cli.showArgv(showProc._issuer, showProc._account), 0)
    return true
  }

  function _startAttempt(proc, argvTail, candidateIndex) {
    proc._finished = false
    proc._argvTail = argvTail
    root._armCollectors(proc)

    if (root._binaryResolved) {
      if (!root._binaryPath) {
        root._finish(proc, "binary-missing", root._missingMessage())
        return
      }
      proc._candidateIndex = -1
      proc._triedPath = root._binaryPath
      root._spawn(proc, root._binaryPath, argvTail)
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
    root._spawn(proc, candidate, argvTail)
  }

  function _spawn(proc, candidate, argvTail) {
    proc.command = Cli.isPathLookupCandidate(candidate)
      ? Cli.wrapViaPath(candidate, argvTail, root.timeoutMs)
      : Cli.wrap(candidate, argvTail, root.timeoutMs)
    proc._startedAt = Date.now()
    proc.running = true
  }

  function _missingMessage() {
    return "otpclient-cli not found (checked: " + root.binaryCandidates.join(", ") + ")"
  }

  // Creates a fresh pair of StdioCollectors for `proc` and destroys
  // whatever it previously had (see _disarmCollectors()). Called at the
  // start of every single spawn attempt, including each retry while
  // walking binaryCandidates, so no attempt's output can ever be read as
  // if it were a different attempt's.
  function _armCollectors(proc) {
    root._disarmCollectors(proc)
    proc._stdout = collectorComponent.createObject(proc)
    proc._stderr = collectorComponent.createObject(proc)
    proc.stdout = proc._stdout
    proc.stderr = proc._stderr
  }

  // Detaches and destroys `proc`'s current StdioCollectors, if any. This
  // is what actually clears a decrypted code (or anything else printed)
  // out of memory once it's no longer needed -- StdioCollector.text is
  // read-only, so there is no way to blank it in place; recreating the
  // object is the only option. Called when arming a new attempt (disarming
  // the previous one, by reading proc's current live collectors).
  function _disarmCollectors(proc) {
    root._destroyCollectors(proc, proc._stdout, proc._stderr)
  }

  // Destroys SPECIFIC collector objects (outCollector/errCollector),
  // captured by the caller at the point it read their .text, rather than
  // re-reading proc._stdout/proc._stderr. This distinction matters: a
  // caller of listInventory()/requestCode()/requestHotpCode() is free to
  // call right back in from inside a listSucceeded/showSucceeded/
  // listFailed/showFailed handler (a "load again" pattern is completely
  // normal), and _startAttempt() will have already armed a FRESH pair of
  // collectors for that reentrant call by the time the original handler
  // that emitted the signal gets back control and runs its own
  // post-emission cleanup. Reading proc._stdout/proc._stderr again at that
  // point would destroy the *reentrant* call's brand-new, about-to-be-used
  // collectors instead of the ones this call actually finished with. Using
  // captured references avoids that: each finished call only ever destroys
  // its own collectors, and only detaches proc.stdout/proc.stderr /
  // proc._stdout/proc._stderr if nothing has replaced them since.
  function _destroyCollectors(proc, outCollector, errCollector) {
    if (proc.stdout === outCollector) proc.stdout = null
    if (proc.stderr === errCollector) proc.stderr = null
    if (proc._stdout === outCollector) proc._stdout = null
    if (proc._stderr === errCollector) proc._stderr = null
    if (outCollector) outCollector.destroy()
    if (errCollector) errCollector.destroy()
  }

  // QProcess::ExitStatus -- no named QML enum is exposed for this by
  // Quickshell's Process type, so the raw value is used directly (0 =
  // NormalExit, 1 = CrashExit).
  readonly property int _crashExit: 1

  // Raw signal number Quickshell/Qt was observed to report as `exitCode`
  // when `exitStatus` is CrashExit and the process died to our own
  // `-s KILL` (SIGKILL=9 on Linux) -- confirmed against the real binary;
  // see the isTimeoutExit()/CrashExit note in Cli.js. Used below only to
  // *corroborate* a timeout, alongside elapsed time; it is not sufficient
  // on its own (an external `kill -9` or an OOM kill would report the same
  // number) -- see _handleExit()'s docstring.
  readonly property int _sigkillExitCode: 9

  // Shared by both Process items' onExited. `proc._candidateIndex >= 0`
  // means we're still walking binaryCandidates for the very first call this
  // session; once one candidate actually execs (any outcome other than
  // "not found"/"not executable"), that path is locked in for every future
  // call, list or show alike.
  //
  // CrashExit handling (would-prompt vs. crashed): adversarial review
  // found that treating every CrashExit as "our own -s KILL timeout fired"
  // was wrong -- a kernel OOM kill, an external `kill -9`, or a genuine
  // otpclient-cli crash (SIGSEGV/SIGABRT, plausible on a malformed or
  // adversarial database) all produce CrashExit too, and reporting any of
  // those as `would-prompt` ("Secret Service is off") would mask a real
  // crash as a benign config problem -- the worst failure mode here. A
  // CrashExit is now only accepted as `would-prompt` when TWO things
  // corroborate it: the reported exitCode matches what our own SIGKILL is
  // known to produce (or the documented-but-unconfirmed 124/137), AND at
  // least roughly our own timeoutMs actually elapsed first. A CrashExit
  // that fails either check is reported as the distinct `crashed` state
  // instead -- not would-prompt, and not silently folded into `malformed`
  // either, since "the process died to a signal" is meaningfully different
  // information from "we couldn't parse its output".
  function _handleExit(proc, exitCode, exitStatus, kind) {
    if (proc._finished) return // watchdog already resolved this attempt

    // Captured NOW, before any signal is emitted -- see _destroyCollectors()
    // for exactly why this matters (a reentrant call from inside the signal
    // handler this exit eventually triggers must not have its own fresh
    // collectors torn down by this call's own post-emission cleanup).
    var outCollector = proc._stdout
    var errCollector = proc._stderr
    var outText = outCollector ? outCollector.text : ""
    var errText = errCollector ? errCollector.text : ""

    if (exitStatus === root._crashExit) {
      var elapsed = Date.now() - proc._startedAt
      var minExpected = root.timeoutMs - 500 // small tolerance for scheduling jitter
      var matchesOurSignal = exitCode === root._sigkillExitCode || Cli.isTimeoutExit(exitCode)
      if (matchesOurSignal && elapsed >= minExpected) {
        if (!root._binaryResolved) {
          root._binaryResolved = true
          root._binaryPath = proc._triedPath
        }
        root._finish(proc, "would-prompt",
          "otpclient-cli did not respond within " + root.timeoutMs + "ms and was killed " +
          "(likely blocked on a password prompt because Secret Service is unavailable).",
          outCollector, errCollector)
        return
      }
      if (!root._binaryResolved) {
        root._binaryResolved = true
        root._binaryPath = proc._triedPath
      }
      root._finish(proc, "crashed",
        "otpclient-cli exited abnormally (signal death, exitCode=" + exitCode + ", after " + elapsed + "ms" +
        (matchesOurSignal ? ", before our own timeout could plausibly have fired" : ", not matching our own timeout signal") +
        "). This may be a real crash or something external killing it -- not a Secret Service/password-prompt issue.",
        outCollector, errCollector)
      return
    }

    if (Cli.isMissingExit(exitCode)) {
      if (proc._candidateIndex >= 0 && proc._candidateIndex < root.binaryCandidates.length - 1) {
        root._startAttempt(proc, proc._argvTail, proc._candidateIndex + 1)
        return
      }
      root._binaryResolved = true
      root._binaryPath = ""
      root._finish(proc, "binary-missing", root._missingMessage(), outCollector, errCollector)
      return
    }

    // This candidate actually executed. Lock it in before anything else --
    // any exit reaching this point is a real answer from a real binary,
    // not evidence the path is wrong.
    if (!root._binaryResolved) {
      root._binaryResolved = true
      root._binaryPath = proc._triedPath
    }

    // Defensive fallback for a platform that reports a timeout as a clean
    // NormalExit with the documented 124/137 rather than the CrashExit
    // this component has only ever actually observed -- still corroborated
    // by elapsed time for the same reason as the CrashExit branch above.
    if (Cli.isTimeoutExit(exitCode) && (Date.now() - proc._startedAt) >= (root.timeoutMs - 500)) {
      root._finish(proc, "would-prompt",
        "otpclient-cli did not respond within " + root.timeoutMs + "ms " +
        "(likely blocked on a password prompt because Secret Service is unavailable).",
        outCollector, errCollector)
      return
    }

    var result = Cli.classify(exitCode, outText, errText, kind)
    if (result.state === "ok") {
      if (kind === "list") root._finishListOk(proc, result.entries, outCollector, errCollector)
      else root._finishShowOk(proc, result.entry, outCollector, errCollector)
      return
    }
    root._finish(proc, result.state, result.message, outCollector, errCollector)
  }

  function _finishListOk(proc, entries, outCollector, errCollector) {
    if (proc._finished) return
    proc._finished = true
    root.entries = entries
    root._end()
    root.listSucceeded(entries)
    root._destroyCollectors(proc, outCollector, errCollector)
  }

  function _finishShowOk(proc, entry, outCollector, errCollector) {
    if (proc._finished) return
    proc._finished = true
    root._end()
    root.showSucceeded(proc._issuer, proc._account, entry)
    root._destroyCollectors(proc, outCollector, errCollector)
  }

  // Single exit point for every non-ok outcome, for both list and show.
  // Idempotent: the watchdog and the normal exit path both funnel through
  // here and only the first caller wins. outCollector/errCollector default
  // to proc's current live collectors when omitted (the watchdog path,
  // which isn't reentered the way a signal handler can be -- see
  // _destroyCollectors()'s docstring for why the distinction matters at all).
  function _finish(proc, state, message, outCollector, errCollector) {
    if (proc._finished) return
    proc._finished = true
    if (outCollector === undefined) outCollector = proc._stdout
    if (errCollector === undefined) errCollector = proc._stderr
    root._end()
    if (proc === listProc) {
      root.entries = []
      root.listFailed(state, message)
    } else {
      root.showFailed(proc._issuer, proc._account, state, message)
    }
    root._destroyCollectors(proc, outCollector, errCollector)
  }

  // Test-only diagnostics -- NOT part of the public API, may change or
  // disappear without notice. These exist solely so tests/backend.qmltest
  // .qml can assert that a decrypted code never outlives the single signal
  // emission that hands it to the caller (see _disarmCollectors() above),
  // by checking that the currently-armed collector (if any) is empty
  // immediately after that emission returns.
  function __debugListStdoutText() { return listProc._stdout ? listProc._stdout.text : "" }
  function __debugShowStdoutText() { return showProc._stdout ? showProc._stdout.text : "" }

  Component {
    id: collectorComponent
    StdioCollector { waitForEnd: true }
  }

  Process {
    id: listProc
    property int _candidateIndex: -1
    property string _triedPath: ""
    property var _argvTail: []
    property bool _finished: true
    property double _startedAt: 0
    property string _issuer: ""
    property string _account: ""
    property var _stdout: null
    property var _stderr: null

    onRunningChanged: {
      if (running) listWatchdog.restart()
      else listWatchdog.stop()
    }
    onExited: function (exitCode, exitStatus) {
      root._handleExit(listProc, exitCode, exitStatus, "list")
    }
  }

  Process {
    id: showProc
    property int _candidateIndex: -1
    property string _triedPath: ""
    property var _argvTail: []
    property bool _finished: true
    property double _startedAt: 0
    property string _issuer: ""
    property string _account: ""
    property var _stdout: null
    property var _stderr: null

    onRunningChanged: {
      if (running) showWatchdog.restart()
      else showWatchdog.stop()
    }
    onExited: function (exitCode, exitStatus) {
      root._handleExit(showProc, exitCode, exitStatus, "show")
    }
  }

  // Backstop behind `timeout -s KILL`, exactly as scanWatchdog/killWatchdog
  // back up zeru.portwatch's own inner timeouts: if the wrapped `timeout`
  // process somehow never reports back at all (no exited signal, e.g. if
  // /usr/bin/timeout itself were missing -- unreachable in practice on any
  // Arch/Omarchy install, but not provable from here), this guarantees
  // the shared gate and _inFlight still clear and the call still resolves
  // to a typed state instead of wedging the widget for the rest of the
  // session. Margin is generous (timeoutMs + 2s) since the OS-level
  // timeout should always win first -- confirmed: a real killed invocation
  // reported back in ~1.00s against a 1s deadline, i.e. no observable
  // slack was needed.
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
