import QtQuick
import Quickshell.Io
// Backend.qml/Cli.js/Shared.js resolve as same-directory sibling types with
// no explicit import -- see tests/run-qml-tests.sh for why this file is run
// from a staged copy that sits next to them rather than from tests/ as-is.

// Integration test for Backend.qml: exercises the real Process/timeout/
// watchdog wiring and the process-wide shared gate (Shared.js), none of
// which tests/cli.test.js (plain JS, no QML runtime) can touch. Each
// scenario gets its own Backend instance pointed at a fixture script
// standing in for otpclient-cli, EXCEPT "binary-missing", which points at
// paths that genuinely do not exist.
//
// Scenarios run SEQUENTIALLY, one at a time via runNext() below, because
// Shared.js's gate is process-wide: with every Backend instance in this one
// file sharing a single gate (by design -- that's the fix for adversarial
// review item #3b), firing them all at once from Component.onCompleted
// would mean only the first actually runs and everything else is
// (correctly!) refused. The shared-gate scenario near the end exploits
// exactly that refusal on purpose, with two distinct Backend instances.
//
// Run with tests/run-qml-tests.sh (drives `quickshell -p` with a staged
// PATH for the path-lookup scenario, and greps the log for the ALL_DONE
// marker this file prints at the end).
Item {
  id: root

  property string fixtureDir: Qt.resolvedUrl("fixtures").toString().replace("file://", "")
  property int failed: 0
  property int stepIndex: 0
  property var steps: []

  function fx(name) { return root.fixtureDir + "/" + name }

  function check(name, cond) {
    if (cond) {
      console.log("PASS " + name)
    } else {
      console.log("FAIL " + name)
      root.failed++
    }
  }

  function runNext() {
    if (root.stepIndex >= root.steps.length) {
      console.log(root.failed === 0 ? "ALL_DONE ok" : ("ALL_DONE failed=" + root.failed))
      return
    }
    var step = root.steps[root.stepIndex++]
    step()
  }

  // ---- Scenario: binary genuinely absent (real, not simulated) -----------
  Backend {
    id: missingBackend
    binaryCandidates: ["/definitely/not/a/real/path/otpclient-cli", "/also/not/real/otpclient-cli"]
    timeoutMs: 800
    onListFailed: function (state, message) {
      root.check("binary-missing: state", state === "binary-missing")
      root.check("binary-missing: resolved() reflects failure", missingBackend.binaryResolved && missingBackend.binaryPath === "")
      root.check("binary-missing: message mentions both candidates", message.indexOf("not/a/real/path") !== -1 && message.indexOf("also/not/real") !== -1)
      root.runNext()
    }
    onListSucceeded: function (entries) { root.check("binary-missing: must not succeed", false); root.runNext() }
  }

  // ---- Scenario: would-prompt (fixture hangs; -s KILL must end it, and the
  // CrashExit it produces must be CORROBORATED -- exitCode + elapsed time --
  // as our own timeout, not just assumed). CrashExit-based detection was
  // additionally verified separately against the real otpclient-cli binary
  // blocked on a real stdin password prompt (see PR description); this
  // fixture keeps that scenario deterministic and fast for routine runs.
  Backend {
    id: hangBackend
    binaryCandidates: [root.fx("hang.sh")]
    timeoutMs: 700
    onListFailed: function (state, message) {
      root.check("would-prompt: state", state === "would-prompt")
      root.runNext()
    }
    onListSucceeded: function (entries) { root.check("would-prompt: must not succeed", false); root.runNext() }
  }

  // ---- Scenario: crashed (adversarial review item #2) -- a CrashExit that
  // happens almost instantly, with a signal number that isn't our own
  // SIGKILL, must NOT be reported as would-prompt.
  Backend {
    id: crashBackend
    binaryCandidates: [root.fx("crash.sh")]
    timeoutMs: 3000
    onListFailed: function (state, message) {
      root.check("crashed: state is crashed, not would-prompt", state === "crashed")
      root.check("crashed: message identifies the real signal (SIGSEGV=11)", message.indexOf("exitCode=11") !== -1)
      root.runNext()
    }
    onListSucceeded: function () { root.check("crashed: must not succeed", false); root.runNext() }
  }

  // ---- Scenario: instance-conflict (adversarial review item #3b) ---------
  Backend {
    id: conflictBackend
    binaryCandidates: [root.fx("instance-conflict.sh")]
    timeoutMs: 3000
    onListFailed: function (state, message) {
      root.check("instance-conflict: state", state === "instance-conflict")
      root.runNext()
    }
    onListSucceeded: function () { root.check("instance-conflict: must not succeed", false); root.runNext() }
  }

  // ---- Scenario: ok list, and that its output is cleared after emission --
  Backend {
    id: okListBackend
    binaryCandidates: [root.fx("ok-list.sh")]
    timeoutMs: 3000
    onListSucceeded: function (entries) {
      root.check("ok-list: state via entries property", okListBackend.entries.length === 3)
      root.check("ok-list: three entries parsed", entries.length === 3)
      root.check("ok-list: fields normalized", entries[0].issuer === "GitHub" && entries[0].account === "pavan@smaply.com")
      root.check("ok-list: no code field leaks into inventory", entries[0].current === undefined)
      Qt.callLater(function () {
        root.check("ok-list: stdout collector cleared immediately after emission", okListBackend.__debugListStdoutText() === "")
        root.runNext()
      })
    }
    onListFailed: function (state, message) { root.check("ok-list: must not fail (" + state + ": " + message + ")", false); root.runNext() }
  }

  // ---- Scenario: ok show (TOTP), and that the CODE is cleared after --
  // adversarial review item #1 (the most important fix in this round).
  Backend {
    id: okShowBackend
    binaryCandidates: [root.fx("ok-show.sh")]
    timeoutMs: 3000
    onShowSucceeded: function (issuer, account, entry) {
      root.check("ok-show: issuer/account echoed back", issuer === "GitHub" && account === "pavan@smaply.com")
      root.check("ok-show: current code parsed", entry.current === "482913")
      root.check("ok-show: secondsRemaining parsed as number", entry.secondsRemaining === 21)
      // Qt.callLater defers this check to the next event-loop turn, which
      // is safely after Backend.qml's _finishShowOk() has run its
      // post-emission _disarmCollectors() call (that call is synchronous
      // code still executing when this handler returns control to it) --
      // see Backend.qml's _finishShowOk()/_disarmCollectors().
      Qt.callLater(function () {
        root.check("ok-show: CODE NOT RETAINED -- stdout collector empty immediately after emission", okShowBackend.__debugShowStdoutText() === "")
        root.runNext()
      })
    }
    onShowFailed: function (issuer, account, state, message) { root.check("ok-show: must not fail (" + state + ")", false); root.runNext() }
  }

  // ---- Scenario: ok show (HOTP, polluted stdout) --------------------------
  // Exercises extractJson end to end through the real Process/StdioCollector
  // pipeline (not just pure JS), against the exact stdout-pollution shape
  // confirmed on a real mutating HOTP call, and again checks the code does
  // not outlive the signal that carries it.
  Backend {
    id: hotpBackend
    binaryCandidates: [root.fx("ok-show-hotp-polluted.sh")]
    timeoutMs: 3000
    onShowSucceeded: function (issuer, account, entry) {
      root.check("hotp-polluted: current code parsed despite leading diagnostic lines", entry.current === "453172")
      root.check("hotp-polluted: counter parsed", entry.counter === 8)
      Qt.callLater(function () {
        root.check("hotp-polluted: code not retained after emission", hotpBackend.__debugShowStdoutText() === "")
        root.runNext()
      })
    }
    onShowFailed: function (issuer, account, state, message) { root.check("hotp-polluted: must not fail (" + state + ")", false); root.runNext() }
  }

  // ---- Scenario: HOTP safety guard -- requestCode() must refuse it, fully
  // synchronously, without spawning anything.
  Backend {
    id: hotpGuardBackend
    binaryCandidates: [root.fx("ok-show-hotp-polluted.sh")]
    timeoutMs: 3000
    // These must never fire at all.
    onShowSucceeded: function () { root.check("hotp-guard: requestCode() must never actually run for type HOTP", false) }
    onShowFailed: function () { root.check("hotp-guard: requestCode() must never actually run for type HOTP", false) }
  }

  // ---- Scenario: bad-password (real exit code confirmed: 255, not 1) -----
  Backend {
    id: badPwBackend
    binaryCandidates: [root.fx("bad-password.sh")]
    timeoutMs: 3000
    onShowFailed: function (issuer, account, state, message) {
      root.check("bad-password: state", state === "bad-password")
      root.runNext()
    }
    onShowSucceeded: function () { root.check("bad-password: must not succeed", false); root.runNext() }
  }

  // ---- Scenario: db-missing ------------------------------------------------
  Backend {
    id: dbMissingBackend
    binaryCandidates: [root.fx("db-missing.sh")]
    timeoutMs: 3000
    onListFailed: function (state, message) {
      root.check("db-missing: state", state === "db-missing")
      root.runNext()
    }
    onListSucceeded: function () { root.check("db-missing: must not succeed", false); root.runNext() }
  }

  // ---- Scenario: empty show (confirmed shape: exit 255, "[]", no stderr) --
  Backend {
    id: emptyShowBackend
    binaryCandidates: [root.fx("empty-show.sh")]
    timeoutMs: 3000
    onShowFailed: function (issuer, account, state, message) {
      root.check("empty-show: state", state === "empty")
      root.runNext()
    }
    onShowSucceeded: function () { root.check("empty-show: must not succeed", false); root.runNext() }
  }

  // ---- Scenario: empty list (decrypts fine, zero entries) -----------------
  Backend {
    id: emptyListBackend
    binaryCandidates: [root.fx("empty-list.sh")]
    timeoutMs: 3000
    onListFailed: function (state, message) {
      root.check("empty-list: state", state === "empty")
      root.check("empty-list: entries property cleared", emptyListBackend.entries.length === 0)
      root.runNext()
    }
    onListSucceeded: function () { root.check("empty-list: must not report ok for zero rows", false); root.runNext() }
  }

  // ---- Scenario: malformed --------------------------------------------------
  Backend {
    id: malformedBackend
    binaryCandidates: [root.fx("malformed.sh")]
    timeoutMs: 3000
    onListFailed: function (state, message) {
      root.check("malformed: state", state === "malformed")
      root.runNext()
    }
    onListSucceeded: function () { root.check("malformed: must not succeed", false); root.runNext() }
  }

  // ---- Scenario: database setting reaches EVERY call site consistently
  // (issue #17) -- listInventory(), requestCode(), and requestHotpCode()
  // must all pass the SAME `database` value into the SAME -d/--database
  // argv element. tests/fixtures/database-select.sh returns visibly
  // DIFFERENT output ("FixtureDB"/"matched" vs. "DefaultDB"/"unmatched")
  // depending on whether "--database /fixture/expected.db" is actually
  // present in argv -- a fixture that answered identically either way
  // would pass whether or not this feature was ever wired up, which is
  // exactly the "test that passes around the bug" issue #17 warns against.
  // See tests/cli.test.js for the pure-argv-shape half of this same
  // guarantee (byte-identical argv when unset; a single discrete argv
  // element, path or name, when set).
  Backend {
    id: databaseAppliedBackend
    binaryCandidates: [root.fx("database-select.sh")]
    timeoutMs: 3000
    database: "/fixture/expected.db"
    property int phase: 0
    onListSucceeded: function (entries) {
      root.check("database-applied: --list carries --database, entry matches the fixture db",
        entries.length === 1 && entries[0].issuer === "FixtureDB" && entries[0].account === "matched")
      databaseAppliedBackend.phase = 1
      databaseAppliedBackend.requestCode("FixtureDB", "matched", "TOTP")
    }
    onListFailed: function (state, message) { root.check("database-applied: list must not fail (" + state + ")", false); root.runNext() }
    onShowSucceeded: function (issuer, account, entry) {
      if (databaseAppliedBackend.phase === 1) {
        root.check("database-applied: requestCode() (TOTP path) also carries --database", entry.current === "555000")
        databaseAppliedBackend.phase = 2
        databaseAppliedBackend.requestHotpCode("FixtureDB", "matched")
      } else {
        root.check("database-applied: requestHotpCode() also carries --database -- inventory and reveal never disagree on which database they read", entry.current === "555000")
        root.runNext()
      }
    }
    onShowFailed: function (issuer, account, state, message) { root.check("database-applied: show must not fail (" + state + ")", false); root.runNext() }
  }

  // ---- Scenario: unset `database` (the default, "") must keep producing
  // today's exact argv -- no --database flag at all -- across the SAME
  // three call sites. Reuses the SAME fixture: it answers "DefaultDB"/
  // "unmatched" whenever --database is absent, which is exactly what must
  // happen here. This is the regression guard for the common,
  // unconfigured path: if a future change started always passing
  // --database (even an empty string, or some other unconditional value),
  // this scenario -- not just tests/cli.test.js's pure argv check -- would
  // catch it at the real Process/fixture level too.
  Backend {
    id: databaseUnsetBackend
    binaryCandidates: [root.fx("database-select.sh")]
    timeoutMs: 3000
    property int phase: 0
    onListSucceeded: function (entries) {
      root.check("database-unset: --list carries no --database flag by default",
        entries.length === 1 && entries[0].issuer === "DefaultDB" && entries[0].account === "unmatched")
      databaseUnsetBackend.phase = 1
      databaseUnsetBackend.requestCode("DefaultDB", "unmatched", "TOTP")
    }
    onListFailed: function (state, message) { root.check("database-unset: list must not fail (" + state + ")", false); root.runNext() }
    onShowSucceeded: function (issuer, account, entry) {
      if (databaseUnsetBackend.phase === 1) {
        root.check("database-unset: requestCode() also carries no --database flag by default", entry.current === "000111")
        databaseUnsetBackend.phase = 2
        databaseUnsetBackend.requestHotpCode("DefaultDB", "unmatched")
      } else {
        root.check("database-unset: requestHotpCode() also carries no --database flag by default", entry.current === "000111")
        root.runNext()
      }
    }
    onShowFailed: function (issuer, account, state, message) { root.check("database-unset: show must not fail (" + state + ")", false); root.runNext() }
  }

  // ---- Scenario: repeat call reuses the cached binary path, no re-probe ---
  Backend {
    id: cacheBackend
    binaryCandidates: [root.fx("ok-list.sh")]
    timeoutMs: 3000
    property int calls: 0
    onListSucceeded: function (entries) {
      cacheBackend.calls++
      if (cacheBackend.calls === 1) {
        root.check("cache: resolved after first call", cacheBackend.binaryResolved && cacheBackend.binaryPath === root.fx("ok-list.sh"))
        cacheBackend.listInventory()
      } else {
        root.check("cache: second call still resolves the same path", cacheBackend.binaryPath === root.fx("ok-list.sh"))
        root.runNext()
      }
    }
    onListFailed: function (state, message) { root.check("cache: must not fail (" + state + ")", false); root.runNext() }
  }

  // ---- Scenario: PATH-lookup fallback (adversarial review item #6) -------
  // tests/run-qml-tests.sh stages a fixture script on PATH under this exact
  // bare name before launching quickshell.
  Backend {
    id: pathLookupBackend
    binaryCandidates: ["/definitely/not/a/real/path/otpclient-cli", "otp-fixture-pathlookup-test"]
    timeoutMs: 3000
    onListSucceeded: function (entries) {
      root.check("path-lookup: falls back to a bare PATH-resolved name after absolute candidates fail", pathLookupBackend.binaryPath === "otp-fixture-pathlookup-test")
      root.check("path-lookup: entries parsed through the PATH-resolved binary", entries.length === 3)
      root.runNext()
    }
    onListFailed: function (state, message) { root.check("path-lookup: must not fail (" + state + ": " + message + ")", false); root.runNext() }
  }

  // ---- Scenario: busy guard -- overlapping calls of the SAME kind on ONE
  // Backend instance.
  Backend {
    id: busyBackend
    binaryCandidates: [root.fx("ok-list.sh")]
    timeoutMs: 3000
    onListSucceeded: function () { root.runNext() }
    onListFailed: function () { root.runNext() }
  }

  // ---- Scenario: cross-kind guard -- list and show on ONE Backend never
  // overlap either.
  Backend {
    id: crossKindBackend
    binaryCandidates: [root.fx("ok-list.sh")]
    timeoutMs: 3000
    onListSucceeded: function () { root.runNext() }
    onListFailed: function () { root.runNext() }
  }

  // ---- Scenario: shared gate across TWO DIFFERENT Backend instances
  // (adversarial review item #3b -- this is the actual fix for "the widget
  // renders per-monitor and Backend.qml is not a singleton"). Instance A
  // runs a slightly slow call; instance B, a wholly separate Backend, must
  // be refused while A is in flight, then succeed once A releases the
  // shared gate (Shared.js).
  Backend {
    id: gateBackendA
    binaryCandidates: [root.fx("slow-ok-list.sh")]
    timeoutMs: 3000
    onListSucceeded: function (entries) {
      root.check("shared-gate: instance A completes", entries.length === 1)
      var retried = gateBackendB.listInventory()
      root.check("shared-gate: instance B can start once A releases the shared gate", retried === true)
    }
    onListFailed: function (state, message) { root.check("shared-gate: instance A must not fail (" + state + ")", false); root.runNext() }
  }
  Backend {
    id: gateBackendB
    binaryCandidates: [root.fx("ok-list.sh")]
    timeoutMs: 3000
    onListSucceeded: function () { root.runNext() }
    onListFailed: function (state, message) { root.check("shared-gate: instance B must not fail on retry (" + state + ")", false); root.runNext() }
  }

  Component.onCompleted: {
    root.steps = [
      function () { missingBackend.listInventory() },
      function () { hangBackend.listInventory() },
      function () { crashBackend.listInventory() },
      function () { conflictBackend.listInventory() },
      function () { okListBackend.listInventory() },
      function () { okShowBackend.requestCode("GitHub", "pavan@smaply.com", "TOTP") },
      function () { hotpBackend.requestHotpCode("Bank", "acct1") },
      function () {
        var refused = hotpGuardBackend.requestCode("Bank", "acct1", "HOTP") // must be refused, no process spawned
        root.check("hotp-guard: requestCode() refuses a declared-HOTP entry", refused === false)
        root.check("hotp-guard: nothing was spawned (not even busy)", hotpGuardBackend.busy === false)
        root.runNext() // synchronous scenario: no signal will ever fire for it
      },
      function () { badPwBackend.requestCode("GitHub", "pavan@smaply.com", "TOTP") },
      function () { dbMissingBackend.listInventory() },
      function () { emptyShowBackend.requestCode("Nobody", "nobody", "TOTP") },
      function () { emptyListBackend.listInventory() },
      function () { malformedBackend.listInventory() },
      function () { databaseAppliedBackend.listInventory() },
      function () { databaseUnsetBackend.listInventory() },
      function () { cacheBackend.listInventory() },
      function () { pathLookupBackend.listInventory() },
      function () {
        var started = busyBackend.listInventory()
        var startedAgain = busyBackend.listInventory() // must be refused: still busy
        root.check("busy-guard: first call starts", started === true)
        root.check("busy-guard: overlapping call is refused", startedAgain === false)
      },
      function () {
        var listStarted = crossKindBackend.listInventory()
        var showWhileListing = crossKindBackend.requestCode("x", "y", "TOTP") // must be refused
        root.check("cross-kind-guard: list starts", listStarted === true)
        root.check("cross-kind-guard: show refused while list is in flight", showWhileListing === false)
        root.check("cross-kind-guard: showBusy false, listBusy true while in flight", crossKindBackend.listBusy === true && crossKindBackend.showBusy === false)
      },
      function () {
        var startedA = gateBackendA.listInventory()
        var startedB = gateBackendB.listInventory() // different Backend instance, must still be refused
        root.check("shared-gate: instance A starts", startedA === true)
        root.check("shared-gate: instance B refused while A is in flight (process-wide gate, not per-instance)", startedB === false)
        root.check("shared-gate: busy reflects only each instance's own activity", gateBackendA.busy === true && gateBackendB.busy === false)
      }
    ]
    root.runNext()
  }
}
