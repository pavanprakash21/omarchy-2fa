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
// - Every invocation's stdin is explicitly closed (issue #24 -- see
//   _spawn() and each Process's onRunningChanged below) so a CLI that would
//   otherwise block reading a database-path or password prompt fails fast
//   and deterministically instead. `/usr/bin/timeout -s KILL <n>` (OS-level
//   deadline) *and* a QML Timer watchdog (deadline+2s, belt and suspenders)
//   remain as a backstop for a GENUINE hang (e.g. Secret Service present
//   but D-Bus itself wedged) -- see _handleExit()'s docstring for why
//   that's no longer the primary signal for `would-prompt`. This mirrors
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
// PRECONDITION (discovered, not otherwise documented in issue #2; UPDATED
// for issue #17, and again for issue #24): the argv this file builds
// includes -d/--database ONLY when `database` below is non-empty -- see
// that property's own doc comment and Cli.js's _withDatabase(). With
// `database` left at its default ("", unset), this is unchanged from the
// original issue #2 contract: `otpclient-cli --help` says -d "Default
// value is taken from GSettings/otpclient.cfg" -- confirmed: on a machine
// with no such default set (e.g. otpclient-cli never configured via the
// GUI), --list with no -d prompts *interactively for a database path*
// ("Type the absolute path to the database:") over stdin. A user who
// leaves `database` unset still needs OTPClient set up with a default
// database (GUI or `otpclient-cli --import`, which registers one) -- a
// perfectly reasonable assumption for this plugin's premise.
//
// ISSUE #24 UPDATE: that database-path prompt USED TO be indistinguishable
// from "Secret Service is off" -- both left the child blocked reading
// stdin, both were only ever noticed via the 4s timeout, and both got
// reported as the same guessed `would-prompt` state (a live, confirmed
// misdiagnosis: a machine with no database configured at all was told to
// go check Secret Service, which would have fixed nothing). Every spawn
// now explicitly closes the child's stdin instead (see _spawn() and each
// Process's onRunningChanged below) -- verified against a real
// otpclient-cli 5.1.6, this makes BOTH prompts fail immediately with
// distinct stderr text instead of hanging, which is what lets Cli.js's
// classify() tell them apart deterministically as `no-database` and
// `would-prompt` respectively, rather than guessing from a timeout. See
// Cli.js's STDIN CLOSURE note for the exact verified transcripts.
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

  // Paths to try for otpclient-cli, in order -- both genuine absolute
  // paths, deliberately with NO bare-name/PATH-lookup fallback (issue #21:
  // that third default candidate used to be the literal string
  // "otpclient-cli", resolved via `/usr/bin/env otpclient-cli` -- see
  // Cli.wrapViaPath()'s doc comment for how that mechanism works). Dropped
  // rather than kept as a "documented trade-off", because it did not
  // actually correspond to a documented, supported install path: this
  // project's own README describes exactly one install method (AUR,
  // `yay -S otpclient`), which lands at /usr/bin, already covered by the
  // first candidate below; there was no Flatpak/user-local install this
  // widget actually ships support for that the fallback was earning its
  // keep for. Per this project's own threat model (issue #9: "a
  // compromised or substituted otpclient-cli ... binary on a poisoned
  // PATH"), a fallback that exists for a use case nothing here documents
  // or tests against is pure attack surface with no offsetting benefit --
  // and it was already the one inconsistency between this file and
  // PanelState.qml's wlCopyPath/wlPastePath, which have never had an
  // equivalent PATH-lookup fallback. `Cli.wrapViaPath()`/
  // `Cli.isPathLookupCandidate()` are NOT deleted -- they remain a real,
  // tested (tests/backend.qmltest.qml's "path-lookup" scenario, driven by
  // explicitly overriding `binaryCandidates` on a Backend instance) opt-in
  // mechanism, so a future, actually-supported non-standard install
  // location can still be wired up deliberately (e.g. a
  // shell.json-configurable path, mirroring wlCopyPath/wlPastePath) without
  // it being silently on-by-default for every install in the meantime.
  // Overridable so tests can point this at a fixture script instead of the
  // real binary; no candidate here is ever built from database content.
  property var binaryCandidates: ["/usr/bin/otpclient-cli", "/usr/local/bin/otpclient-cli"]

  // Hard wall-clock ceiling for one invocation, in milliseconds. Argon2id
  // at the CLI's default parameters measured ~0.22s against a real
  // database on this machine; 4s leaves generous headroom on a loaded
  // machine while still failing fast into `would-prompt` when Secret
  // Service is off and the CLI is blocked reading a password from stdin.
  property int timeoutMs: 4000

  // Optional otpclient-cli database override -- shell.json's `database`
  // setting (issue #8), wired end to end here (issue #17). "" (the
  // default) means exactly what it always has: no -d/--database argument
  // at all, so otpclient-cli falls back to its own configured default --
  // see Cli.js's _withDatabase() and the PRECONDITION note above this
  // Item. Threaded into listInventory()/_requestShow() below via the
  // SAME property read at each call site, so listInventory() and both
  // requestCode()/requestHotpCode() (which share _requestShow()) can never
  // disagree about which database they're reading -- a mismatch there
  // would mean the inventory a user sees and the code a click on a row
  // actually decrypts could silently come from two different databases,
  // which is the one thing #17 explicitly calls out as unacceptable.
  // otpclient-cli's own -d/--database accepts EITHER a path or a bare name
  // as printed by --list-databases (confirmed via `otpclient-cli --help`);
  // this property (and Cli.js) makes no attempt to tell the two apart --
  // whatever a user configures is passed straight through as one argv
  // element, never interpolated into anything else.
  property string database: ""

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
  // binary-missing, would-prompt, bad-password, db-missing, no-database,
  // malformed, empty, crashed, instance-conflict. `crashed`/
  // `instance-conflict` were added after adversarial review found real
  // scenarios the original 7-state list from issue #2 didn't distinguish
  // -- see _handleExit()'s docstring and Cli.js's isInstanceConflictStderr().
  // `no-database` was added for issue #24: a live misdiagnosis found "no
  // database configured at all" and "database exists, Secret Service off"
  // were both being collapsed into `would-prompt` -- see the PRECONDITION
  // note above and Cli.js's classify().
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
  // Emitted for every non-"ok" --show outcome, same nine `state` values
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
    root._startAttempt(listProc, Cli.listArgv(root.database), 0)
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
      // Issue #22: issuer/account are untrusted (otpauth:// import) content
      // -- deliberately NOT interpolated into this message. The useful
      // fact here is that a caller misused the API, not which specific
      // entry it was about; a raw, attacker-influenced string reaching a
      // log sink is exactly what issue #9's checklist rules out elsewhere
      // ("nothing is logged that would leak ... an account list"), and
      // this is otherwise the only console.* call anywhere in this
      // plugin's otpclient-facing surface (verified: the only match for
      // `console\.` outside tests/).
      console.warn("Backend.requestCode() refused for a HOTP entry; use requestHotpCode() explicitly -- it advances and persists the counter.")
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
    root._startAttempt(showProc, Cli.showArgv(showProc._issuer, showProc._account, root.database), 0)
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

  // ISSUE #24: `stdinEnabled = true` here, THEN `false` in the Process's own
  // onRunningChanged (below) once `running` actually flips -- in that
  // order, on this exact Quickshell version. This was verified empirically
  // (see the PR description for the harness), not assumed from
  // documentation, because the documented and observed behaviors disagree:
  //   - Leaving stdinEnabled false the whole time (the old behavior here,
  //     and this property's own documented default) does NOT close the
  //     child's stdin -- it leaves an open, silent pipe, and a child
  //     reading from it (otpclient-cli's database-path or password prompt)
  //     blocks for real, confirmed against both a `cat` stand-in and the
  //     real otpclient-cli.
  //   - Toggling true -> false synchronously, in the same tick as setting
  //     `running = true`, does NOT close it either -- confirmed the same
  //     way, and the child still hangs.
  //   - Toggling true -> false from INSIDE onRunningChanged, after `running`
  //     has already become true, DOES close it: the child gets immediate
  //     EOF on stdin (confirmed: a `cat` reading it exits instantly instead
  //     of needing `-s KILL`; the real otpclient-cli against a
  //     Secret-Service-off database returned in single-digit milliseconds
  //     with "Empty password not allowed"/"No password provided, exiting."
  //     instead of waiting out the 4s timeout). This is also why the toggle
  //     is split across two places instead of being one call here: setting
  //     it back to true before every spawn matters too, since listProc/
  //     showProc are long-lived and reused for every call, and this
  //     Quickshell version does not reopen a channel by re-enabling it
  //     without a fresh `running` transition in between.
  function _spawn(proc, candidate, argvTail) {
    proc.command = Cli.isPathLookupCandidate(candidate)
      ? Cli.wrapViaPath(candidate, argvTail, root.timeoutMs)
      : Cli.wrap(candidate, argvTail, root.timeoutMs)
    proc._startedAt = Date.now()
    proc.stdinEnabled = true
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
  //
  // ISSUE #24: this CrashExit/timeout path used to be the ONLY way either
  // prompt-blocked case ever got reported, which is exactly why "no
  // database configured" and "Secret Service off" used to be
  // indistinguishable (both just "the process never came back"). Now that
  // every spawn closes stdin (see _spawn()), both of those prompts fail
  // immediately and are classified deterministically by Cli.js's
  // classify() from stderr text (`no-database` / `would-prompt`) well
  // before this timeout path would ever fire. This path remains reachable
  // -- and still reports `would-prompt` when corroborated -- only for a
  // GENUINE hang unrelated to either prompt (e.g. Secret Service present
  // but its D-Bus service itself wedged): a backstop, not the primary
  // signal it used to be.
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
      if (running) {
        listProc.stdinEnabled = false // issue #24 -- see _spawn()'s docstring for why this has to happen here, not in _spawn() itself
        listWatchdog.restart()
      } else {
        listWatchdog.stop()
      }
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
      if (running) {
        showProc.stdinEnabled = false // issue #24 -- see _spawn()'s docstring for why this has to happen here, not in _spawn() itself
        showWatchdog.restart()
      } else {
        showWatchdog.stop()
      }
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
