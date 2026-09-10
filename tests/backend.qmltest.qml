import QtQuick
import Quickshell.Io
// Backend.qml/Cli.js resolve as same-directory sibling types with no
// explicit import -- see tests/run-qml-tests.sh for why this file is run
// from a staged copy that sits next to them rather than from tests/ as-is.

// Integration test for Backend.qml: exercises the real Process/timeout/
// watchdog wiring, which tests/cli.test.js (plain JS, no QML runtime)
// cannot touch. Each scenario gets its own Backend instance pointed at a
// fixture script standing in for otpclient-cli, EXCEPT "binary-missing",
// which points at a path that genuinely does not exist -- that path is
// exercised for real, not simulated, since otpclient-cli is absent from
// every candidate path used there.
//
// Run with tests/run-qml-tests.sh (drives `quickshell -p` and greps the log
// for the ALL_DONE marker this file prints at the end).
Item {
  id: root

  property string fixtureDir: Qt.resolvedUrl("fixtures").toString().replace("file://", "")
  property int remaining: 0
  property int failed: 0

  function fx(name) { return root.fixtureDir + "/" + name }

  function check(name, cond) {
    if (cond) {
      console.log("PASS " + name)
    } else {
      console.log("FAIL " + name)
      root.failed++
    }
  }

  function done(name) {
    root.remaining--
    if (root.remaining === 0) {
      console.log(root.failed === 0 ? "ALL_DONE ok" : ("ALL_DONE failed=" + root.failed))
    }
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
      root.done("binary-missing")
    }
    onListSucceeded: function (entries) { root.check("binary-missing: must not succeed", false); root.done("binary-missing") }
  }

  // ---- Scenario: would-prompt (fixture hangs; -s KILL must end it) -------
  // CrashExit-based detection was verified separately against the real
  // otpclient-cli binary blocked on a real stdin password prompt (see PR
  // description); this fixture keeps that scenario deterministic and fast
  // for routine test runs without needing a live database.
  Backend {
    id: hangBackend
    binaryCandidates: [root.fx("hang.sh")]
    timeoutMs: 700
    onListFailed: function (state, message) {
      root.check("would-prompt: state", state === "would-prompt")
      root.done("would-prompt")
    }
    onListSucceeded: function (entries) { root.check("would-prompt: must not succeed", false); root.done("would-prompt") }
  }

  // ---- Scenario: ok list --------------------------------------------------
  Backend {
    id: okListBackend
    binaryCandidates: [root.fx("ok-list.sh")]
    timeoutMs: 3000
    onListSucceeded: function (entries) {
      root.check("ok-list: state via entries property", okListBackend.entries.length === 3)
      root.check("ok-list: three entries parsed", entries.length === 3)
      root.check("ok-list: fields normalized", entries[0].issuer === "GitHub" && entries[0].account === "pavan@smaply.com")
      root.check("ok-list: no code field leaks into inventory", entries[0].current === undefined)
      root.done("ok-list")
    }
    onListFailed: function (state, message) { root.check("ok-list: must not fail (" + state + ": " + message + ")", false); root.done("ok-list") }
  }

  // ---- Scenario: ok show (TOTP) -------------------------------------------
  Backend {
    id: okShowBackend
    binaryCandidates: [root.fx("ok-show.sh")]
    timeoutMs: 3000
    onShowSucceeded: function (issuer, account, entry) {
      root.check("ok-show: issuer/account echoed back", issuer === "GitHub" && account === "pavan@smaply.com")
      root.check("ok-show: current code parsed", entry.current === "482913")
      root.check("ok-show: secondsRemaining parsed as number", entry.secondsRemaining === 21)
      root.done("ok-show")
    }
    onShowFailed: function (issuer, account, state, message) { root.check("ok-show: must not fail (" + state + ")", false); root.done("ok-show") }
  }

  // ---- Scenario: ok show (HOTP, polluted stdout) --------------------------
  // Exercises extractJson end to end through the real Process/StdioCollector
  // pipeline (not just pure JS), against the exact stdout-pollution shape
  // confirmed on a real mutating HOTP call.
  Backend {
    id: hotpBackend
    binaryCandidates: [root.fx("ok-show-hotp-polluted.sh")]
    timeoutMs: 3000
    onShowSucceeded: function (issuer, account, entry) {
      root.check("hotp-polluted: current code parsed despite leading diagnostic lines", entry.current === "453172")
      root.check("hotp-polluted: counter parsed", entry.counter === 8)
      root.done("hotp-polluted")
    }
    onShowFailed: function (issuer, account, state, message) { root.check("hotp-polluted: must not fail (" + state + ")", false); root.done("hotp-polluted") }
  }

  // ---- Scenario: HOTP safety guard -- requestCode() must refuse it --------
  Backend {
    id: hotpGuardBackend
    binaryCandidates: [root.fx("ok-show-hotp-polluted.sh")]
    timeoutMs: 3000
    // These must never fire at all -- requestCode() refuses synchronously
    // for a declared-HOTP entry without spawning anything (verified below
    // in Component.onCompleted). No done() call here on purpose: the count
    // is settled by the synchronous check in onCompleted instead.
    onShowSucceeded: function () { root.check("hotp-guard: requestCode() must never actually run for type HOTP", false) }
    onShowFailed: function () { root.check("hotp-guard: requestCode() must never actually run for type HOTP", false) }
  }

  // ---- Scenario: bad-password ---------------------------------------------
  Backend {
    id: badPwBackend
    binaryCandidates: [root.fx("bad-password.sh")]
    timeoutMs: 3000
    onShowFailed: function (issuer, account, state, message) {
      root.check("bad-password: state", state === "bad-password")
      root.done("bad-password")
    }
    onShowSucceeded: function () { root.check("bad-password: must not succeed", false); root.done("bad-password") }
  }

  // ---- Scenario: db-missing ------------------------------------------------
  Backend {
    id: dbMissingBackend
    binaryCandidates: [root.fx("db-missing.sh")]
    timeoutMs: 3000
    onListFailed: function (state, message) {
      root.check("db-missing: state", state === "db-missing")
      root.done("db-missing")
    }
    onListSucceeded: function () { root.check("db-missing: must not succeed", false); root.done("db-missing") }
  }

  // ---- Scenario: empty show (confirmed shape: exit 255, "[]", no stderr) --
  Backend {
    id: emptyShowBackend
    binaryCandidates: [root.fx("empty-show.sh")]
    timeoutMs: 3000
    onShowFailed: function (issuer, account, state, message) {
      root.check("empty-show: state", state === "empty")
      root.done("empty-show")
    }
    onShowSucceeded: function () { root.check("empty-show: must not succeed", false); root.done("empty-show") }
  }

  // ---- Scenario: empty list (decrypts fine, zero entries) -----------------
  Backend {
    id: emptyListBackend
    binaryCandidates: [root.fx("empty-list.sh")]
    timeoutMs: 3000
    onListFailed: function (state, message) {
      root.check("empty-list: state", state === "empty")
      root.check("empty-list: entries property cleared", emptyListBackend.entries.length === 0)
      root.done("empty-list")
    }
    onListSucceeded: function () { root.check("empty-list: must not report ok for zero rows", false); root.done("empty-list") }
  }

  // ---- Scenario: malformed --------------------------------------------------
  Backend {
    id: malformedBackend
    binaryCandidates: [root.fx("malformed.sh")]
    timeoutMs: 3000
    onListFailed: function (state, message) {
      root.check("malformed: state", state === "malformed")
      root.done("malformed")
    }
    onListSucceeded: function () { root.check("malformed: must not succeed", false); root.done("malformed") }
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
        root.done("cache-reuse")
      }
    }
    onListFailed: function (state, message) { root.check("cache: must not fail (" + state + ")", false); root.done("cache-reuse") }
  }

  // ---- Scenario: busy guard -- overlapping calls of the SAME kind ---------
  Backend {
    id: busyBackend
    binaryCandidates: [root.fx("ok-list.sh")]
    timeoutMs: 3000
    onListSucceeded: function () { root.done("busy-guard") }
    onListFailed: function () { root.done("busy-guard") }
  }

  // ---- Scenario: cross-kind guard -- list and show on ONE Backend never
  // overlap. CONFIRMED against the real binary: two otpclient-cli
  // invocations against the same database running at once corrupt BOTH
  // (garbage exit code + empty output on one, a stray D-Bus registration
  // error on the other's stderr) -- so this has to be a single shared gate,
  // not "one list at a time" and separately "one show at a time".
  Backend {
    id: crossKindBackend
    binaryCandidates: [root.fx("ok-list.sh")]
    timeoutMs: 3000
    onListSucceeded: function () { root.done("cross-kind-guard") }
    onListFailed: function () { root.done("cross-kind-guard") }
  }

  Component.onCompleted: {
    // One done() per scenario below: binary-missing, would-prompt, ok-list,
    // ok-show, hotp-polluted, bad-password, db-missing, empty-show,
    // empty-list, malformed, cache-reuse, busy-guard, cross-kind-guard,
    // hotp-guard.
    root.remaining = 14

    missingBackend.listInventory()
    hangBackend.listInventory()
    okListBackend.listInventory()
    okShowBackend.requestCode("GitHub", "pavan@smaply.com", "TOTP")
    hotpBackend.requestHotpCode("Bank", "acct1")
    badPwBackend.requestCode("GitHub", "pavan@smaply.com", "TOTP")
    dbMissingBackend.listInventory()
    emptyShowBackend.requestCode("Nobody", "nobody", "TOTP")
    emptyListBackend.listInventory()
    malformedBackend.listInventory()

    var started = busyBackend.listInventory()
    var startedAgain = busyBackend.listInventory() // must be refused: still busy
    root.check("busy-guard: first call starts", started === true)
    root.check("busy-guard: overlapping call is refused", startedAgain === false)

    var listStarted = crossKindBackend.listInventory()
    var showWhileListing = crossKindBackend.requestCode("x", "y", "TOTP") // must be refused
    root.check("cross-kind-guard: list starts", listStarted === true)
    root.check("cross-kind-guard: show refused while list is in flight", showWhileListing === false)
    root.check("cross-kind-guard: showBusy false, listBusy true while in flight", crossKindBackend.listBusy === true && crossKindBackend.showBusy === false)

    var hotpGuardRefused = hotpGuardBackend.requestCode("Bank", "acct1", "HOTP") // must be refused, no process spawned
    root.check("hotp-guard: requestCode() refuses a declared-HOTP entry", hotpGuardRefused === false)
    root.check("hotp-guard: nothing was spawned (not even busy)", hotpGuardBackend.busy === false)
    root.done("hotp-guard") // no process ever starts, so no exit callback will fire for this one

    cacheBackend.listInventory()
  }
}
