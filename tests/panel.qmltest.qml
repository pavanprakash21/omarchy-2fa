import QtQuick
import Quickshell.Io
// Backend.qml/Cli.js/Shared.js/PanelState.qml/PanelLogic.js resolve as
// same-directory sibling types with no explicit import -- see
// tests/run-qml-tests.sh for why this file is run from a staged copy that
// sits next to them rather than from tests/ as-is.
import "PanelLogic.js" as Logic

// Integration test for PanelState.qml (issues #4/#5): exercises the real
// Timer/Process wiring -- inventory load, search filtering, keyboard
// selection, the HOTP confirm gate, reveal + clipboard copy, and the
// countdown auto-clear -- none of which tests/panel-logic.test.js (plain
// JS, no QML runtime) can touch. Never instantiates Popup.qml: PanelState
// is a plain Item, not a Window, so none of this maps anything on screen
// or touches this machine's real Wayland clipboard -- every external
// process (otpclient-cli, wl-copy, wl-paste) is pointed at a fixture
// script instead of the real thing.
//
// Scenarios are grouped and run SEQUENTIALLY via runNext() below, same
// discipline as backend.qmltest.qml and for the same reason: Backend's
// process-wide shared gate (Shared.js) means two PanelState instances
// calling in at once would just make the second one lose the race.
//
// Run with tests/run-qml-tests.sh.
Item {
  id: root

  property string fixtureDir: Qt.resolvedUrl("fixtures").toString().replace("file://", "")
  property int failed: 0
  property var steps: []
  property int stepIndex: 0

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

  // Polls `predicate` every 25ms until it's true or `timeoutMs` elapses,
  // then calls `onSettled(true|false)`. PanelState's list/show calls run a
  // real (fixture) child process, so their outcomes land asynchronously,
  // same as Backend.qml's own onListSucceeded/onListFailed timing.
  property var _pending: null
  Timer {
    id: pollTimer
    interval: 25
    onTriggered: {
      var p = root._pending
      if (!p) return
      if (p.predicate()) {
        root._pending = null
        p.onSettled(true)
        return
      }
      if (Date.now() - p.start >= p.timeoutMs) {
        root._pending = null
        p.onSettled(false)
        return
      }
      pollTimer.restart()
    }
  }
  function waitUntil(predicate, timeoutMs, onSettled) {
    root._pending = { predicate: predicate, timeoutMs: timeoutMs, start: Date.now(), onSettled: onSettled }
    pollTimer.restart()
  }

  // Plain "wait N ms then call back" -- distinct from waitUntil() on
  // purpose: waitUntil() resolves the moment its predicate is true, so a
  // predicate that's already true (or trivially `function(){return true}`)
  // would fire almost immediately rather than actually waiting out a real
  // Timer (e.g. clipboardClearTimer) on the object under test.
  Timer {
    id: sleepTimer
    property var _cb: null
    onTriggered: {
      var cb = sleepTimer._cb
      sleepTimer._cb = null
      if (cb) cb()
    }
  }
  function sleep(ms, cb) {
    sleepTimer.interval = ms
    sleepTimer._cb = cb
    sleepTimer.restart()
  }

  function bankKey() { return Logic.entryKey({ issuer: "Bank", account: "acct1" }) }

  // ==== Group A: list load, search filter, keyboard selection ===========
  PanelState {
    id: listState
    binaryCandidates: [root.fx("panel-combo.sh")]
    timeoutMs: 3000
  }

  function groupA() {
    listState.open()
    root.waitUntil(function () { return listState.loadState !== "loading" }, 3000, function (ok) {
      root.check("A: open() loads inventory", ok && listState.loadState === "ok")
      root.check("A: three entries parsed", listState.entries.length === 3)
      root.check("A: selection defaults to the first row", listState.selectedIndex === 0)
      root.check("A: filterText reset by open()", listState.filterText === "")

      listState.setFilterText("git")
      root.check("A: filter matches issuer, case-insensitively", listState.filteredEntries.length === 1)
      root.check("A: filter keeps a valid selection", listState.selectedIndex === 0)

      listState.setFilterText("nobody-matches-this")
      root.check("A: filter with no match empties the list", listState.filteredEntries.length === 0)
      root.check("A: selection clears to -1 when nothing is visible", listState.selectedIndex === -1)

      listState.setFilterText("")
      root.check("A: clearing the filter restores every entry", listState.filteredEntries.length === 3)
      root.check("A: selection re-clamps back onto the list", listState.selectedIndex === 0)

      listState.moveSelection(1)
      listState.moveSelection(1)
      root.check("A: moveSelection walks down", listState.selectedIndex === 2)
      listState.moveSelection(1)
      root.check("A: moveSelection clamps at the last row (no wrap)", listState.selectedIndex === 2)
      listState.moveSelection(-10)
      root.check("A: moveSelection clamps at the first row (no wrap)", listState.selectedIndex === 0)

      // Re-opening (close then open) must reset filter/selection and issue
      // a genuinely fresh --list, not reuse the cached one -- issue #4.
      listState.setFilterText("git")
      listState.moveSelection(1) // no-op (only one row matches "git"), state just needs disturbing
      listState.close()
      listState.open()
      root.waitUntil(function () { return listState.loadState !== "loading" }, 3000, function (ok2) {
        root.check("A: reopen resets the filter", ok2 && listState.filterText === "")
        root.check("A: reopen resets selection to the first row", listState.selectedIndex === 0)
        root.runNext()
      })
    })
  }

  // ==== Group B: TOTP reveal, clipboard copy (stdin-only), countdown =====
  PanelState {
    id: totpState
    binaryCandidates: [root.fx("panel-combo.sh")]
    timeoutMs: 3000
    wlCopyPath: root.fx("wl-copy-capture.sh")
    wlPastePath: root.fx("wl-paste-readback.sh")
  }

  // Reads back what wl-copy-capture.sh actually captured over stdin, so
  // Group B can assert the real code landed there intact -- not just that
  // the Process argv looked right.
  Process {
    id: checkCopied
    command: [root.fx("wl-paste-readback.sh")]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        root.check("B: the code that reached wl-copy's STDIN is exactly the revealed code", text === "482913")
      }
    }
  }

  function groupB() {
    totpState.open()
    root.waitUntil(function () { return totpState.loadState !== "loading" }, 3000, function () {
      root.check("B: selection starts on the TOTP (GitHub) row", totpState.selectedEntry && totpState.selectedEntry.issuer === "GitHub")

      var activated = totpState.activateSelected()
      root.check("B: activateSelected() on a TOTP row starts a reveal", activated === true)
      root.check("B: revealState flips to loading synchronously", totpState.revealState === "loading")

      root.waitUntil(function () { return totpState.revealState !== "loading" }, 3000, function (ok) {
        root.check("B: reveal succeeds", ok && totpState.revealState === "revealed")
        root.check("B: revealed code matches the fixture", totpState.revealedEntry && totpState.revealedEntry.current === "482913")
        root.check("B: revealedEntry carries the CLI's seconds-remaining, not a period", totpState.revealedEntry.secondsRemaining === 3)
        root.check("B: a real CLI expiry is NOT flagged as the fabricated fallback countdown", totpState.revealCountdownIsFallback === false)
        root.check("B: clipboard copy argv is the binary path ONLY -- never the code as an argv element", totpState.__debugCopyArgvIsPathOnly())

        // Give the fixture's async stdin-capture a moment to land, then
        // check what actually reached "the clipboard" -- confirms the code
        // travelled over stdin (the only channel wl-copy-capture.sh reads)
        // and landed intact, not just that argv looked right.
        root.sleep(150, function () {
          checkCopied.running = true
          root.check("B: a successful copy is reflected as clipboardCopyState 'copied'", totpState.clipboardCopyState === "copied")
        })

        // The countdown ticks the CLI's own seconds-remaining down and
        // clears the reveal at zero (issue #5) -- no proportional ring,
        // see PanelState.qml's countdownTimer docstring.
        root.waitUntil(function () { return totpState.revealState === "idle" }, 5000, function (cleared) {
          root.check("B: code clears from the UI once the countdown reaches zero", cleared)
          root.check("B: revealedEntry is dropped, not just hidden", totpState.revealedEntry === null)

          // issue #5's OTHER clearing trigger: an explicit panel close,
          // independent of the countdown.
          var activated2 = totpState.activateSelected()
          root.check("B: can reveal again after a previous reveal cleared", activated2 === true)
          root.waitUntil(function () { return totpState.revealState === "revealed" }, 3000, function (ok2) {
            root.check("B: second reveal succeeds", ok2)
            totpState.close()
            root.check("B: close() clears the reveal synchronously, no wait needed", totpState.revealState === "idle" && totpState.revealedEntry === null)
            root.runNext()
          })
        })
      })
    })
  }

  // ==== Group C: HOTP confirm gate ========================================
  PanelState {
    id: hotpState
    binaryCandidates: [root.fx("panel-combo.sh")]
    timeoutMs: 3000
  }

  function groupC() {
    hotpState.open()
    root.waitUntil(function () { return hotpState.loadState !== "loading" }, 3000, function () {
      hotpState.moveSelection(2) // GitHub(0) -> Example(1) -> Bank/HOTP(2)
      root.check("C: selection lands on the HOTP (Bank) row", hotpState.selectedEntry && hotpState.selectedEntry.issuer === "Bank")

      var firstActivate = hotpState.activateSelected()
      root.check("C: first activation on an HOTP row is accepted (arms the gate)", firstActivate === true)
      root.check("C: first activation does NOT call --show -- revealState stays idle", hotpState.revealState === "idle")
      root.check("C: hotpConfirmKey is armed for exactly this row", hotpState.hotpConfirmKey === root.bankKey())

      // Auto-disarm: an armed-but-unconfirmed HOTP row must not stay live
      // forever (mirrors zeru.portwatch's own armTimer for its confirm gate).
      root.waitUntil(function () { return hotpState.hotpConfirmKey === "" }, 4000, function (disarmed) {
        root.check("C: the confirm gate auto-disarms after its timeout", disarmed)

        // Re-arm, then navigate away: the gate must cancel immediately,
        // not survive onto a different row.
        hotpState.activateSelected()
        root.check("C: re-armed before navigating away", hotpState.hotpConfirmKey === root.bankKey())
        hotpState.moveSelection(-1)
        root.check("C: moving to a different row cancels the armed confirm immediately", hotpState.hotpConfirmKey === "")

        // Now the real deliberate two-step confirm: arm, then confirm on
        // the SAME row -- only then may the HOTP counter actually advance.
        hotpState.moveSelection(1) // back onto Bank
        hotpState.activateSelected() // arm
        var confirmed = hotpState.activateSelected() // confirm
        root.check("C: second activation of the SAME armed row is accepted", confirmed === true)
        root.check("C: confirming clears the armed gate", hotpState.hotpConfirmKey === "")
        root.check("C: revealState is now loading -- requestHotpCode() was actually called", hotpState.revealState === "loading")

        root.waitUntil(function () { return hotpState.revealState !== "loading" }, 3000, function (ok) {
          root.check("C: HOTP reveal succeeds after confirmation", ok && hotpState.revealState === "revealed")
          root.check("C: HOTP code matches the fixture", hotpState.revealedEntry && hotpState.revealedEntry.current === "999111")
          root.check("C: HOTP counter is surfaced", hotpState.revealedEntry.counter === 11)
          root.check("C: HOTP has no CLI-reported expiry -- the fixed fallback window is used, not a fabricated period",
            hotpState.revealedEntry.secondsRemaining === hotpState.hotpRevealFallbackSeconds)
          root.check("C: the fallback countdown is flagged as such, distinct from a real expiry", hotpState.revealCountdownIsFallback === true)
          hotpState.close()
          root.runNext()
        })
      })
    })
  }

  // ==== Group D: list-level error and empty states ========================
  PanelState {
    id: errorListState
    binaryCandidates: [root.fx("malformed.sh")]
    timeoutMs: 3000
  }
  PanelState {
    id: emptyListState
    binaryCandidates: [root.fx("empty-list.sh")]
    timeoutMs: 3000
  }

  function groupD() {
    errorListState.open()
    root.waitUntil(function () { return errorListState.loadState !== "loading" }, 3000, function (ok) {
      root.check("D: a malformed --list surfaces as an inline error state, not a crash", ok && errorListState.loadState === "error")
      root.check("D: the underlying typed state is preserved for the error copy", errorListState.loadErrorState === "malformed")

      emptyListState.open()
      root.waitUntil(function () { return emptyListState.loadState !== "loading" }, 3000, function (ok2) {
        root.check("D: a database with zero entries is the distinct 'empty' state, not 'error'", ok2 && emptyListState.loadState === "empty")
        root.check("D: entries is empty, not stale", emptyListState.entries.length === 0)
        root.runNext()
      })
    })
  }

  // ==== Group E: busy guard -- a reveal is refused while a refresh is =====
  // in flight on the SAME PanelState, rather than racing it.
  PanelState {
    id: busyState
    binaryCandidates: [root.fx("panel-combo.sh")]
    timeoutMs: 3000
  }

  function groupE() {
    busyState.open()
    root.waitUntil(function () { return busyState.loadState !== "loading" }, 3000, function () {
      root.check("E: initial load ok, selection valid", busyState.selectedEntry !== null)

      busyState.refresh() // starts a second --list; busy is true synchronously
      var duringRefresh = busyState.activateSelected()
      root.check("E: activateSelected() is refused while a refresh is in flight", duringRefresh === false)
      root.check("E: refusal did not touch revealState", busyState.revealState === "idle")

      root.waitUntil(function () { return busyState.loadState !== "loading" }, 3000, function () {
        root.runNext() // let the in-flight refresh settle before the next group starts a call of its own
      })
    })
  }

  // ==== Group F: clipboardClearSeconds -- clears only if still ours =======
  PanelState {
    id: clearState
    binaryCandidates: [root.fx("panel-combo.sh")]
    timeoutMs: 3000
    wlCopyPath: root.fx("wl-copy-capture.sh")
    wlPastePath: root.fx("wl-paste-readback.sh")
    clipboardClearSeconds: 1
  }

  function groupF() {
    clearState.open()
    root.waitUntil(function () { return clearState.loadState !== "loading" }, 3000, function () {
      clearState.moveSelection(1) // Example/alice -- validity_seconds: 25, long enough to outlive the clear check
      clearState.activateSelected()
      root.waitUntil(function () { return clearState.revealState === "revealed" }, 3000, function () {
        root.check("F: revealed the long-lived TOTP row", clearState.revealedEntry && clearState.revealedEntry.current === "111222")

        // Wait past clipboardClearSeconds (1s) plus the wl-paste round trip.
        root.sleep(1800, function () {
          checkCleared.running = true
        })
      })
    })
  }

  Process {
    id: checkCleared
    command: [root.fx("wl-paste-readback.sh")]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        root.check("F: clipboard is cleared once clipboardClearSeconds elapses (still held our code)", text === "")
        root.runNext()
      }
    }
  }

  // ==== Group G: the OTHER half of "only clear if still ours" -- a copy =====
  // the user made themselves in the meantime must survive (issue #5: "so we
  // never wipe something the user copied since").
  PanelState {
    id: noClobberState
    binaryCandidates: [root.fx("panel-combo.sh")]
    timeoutMs: 3000
    wlCopyPath: root.fx("wl-copy-capture.sh")
    wlPastePath: root.fx("wl-paste-readback.sh")
    clipboardClearSeconds: 1
  }

  // Simulates the user copying something else into "the clipboard" shortly
  // after this panel's own copy -- a plain overwrite of the same fixture
  // file wl-copy-capture.sh/wl-paste-readback.sh share, standing in for an
  // external clipboard write this plugin has no part in. Using a shell
  // here is fine: this is test scaffolding clobbering a throwaway fixture
  // file, not the production stdin-only discipline PanelState.qml itself
  // is held to (see _copyToClipboard()'s docstring).
  Process {
    id: userOverwritesClipboard
    command: ["/usr/bin/bash", "-c", "printf %s \"$1\" > \"$2\"", "userwrite",
      "the-users-own-copy", root.fx("clipboard-capture.txt")]
  }

  function groupG() {
    noClobberState.open()
    root.waitUntil(function () { return noClobberState.loadState !== "loading" }, 3000, function () {
      noClobberState.moveSelection(1) // Example/alice, validity_seconds: 25
      noClobberState.activateSelected()
      root.waitUntil(function () { return noClobberState.revealState === "revealed" }, 3000, function () {
        // Well within clipboardClearSeconds (1s): overwrite what's in "the
        // clipboard" before the clear timer ever fires.
        root.sleep(200, function () {
          userOverwritesClipboard.running = true
          root.sleep(1800, function () {
            checkNotClobbered.running = true
          })
        })
      })
    })
  }

  Process {
    id: checkNotClobbered
    command: [root.fx("wl-paste-readback.sh")]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        root.check("G: a copy the user made themselves is never wiped by the clipboard-clear timer", text === "the-users-own-copy")
        root.runNext()
      }
    }
  }

  // ==== Group H: moving the selection clears an active reveal ============
  // (adversarial review, HIGH, confirmed) -- moveSelection() never called
  // clearReveal(), and isRevealedFor() matched by the revealed entry's own
  // issuer/account rather than by selectedIndex, so a revealed code kept
  // painting on screen no matter where the highlight moved: reveal, arrow
  // away, walk off -- the code stayed legible for its whole countdown
  // window regardless of the selection ever having left that row.
  PanelState {
    id: moveClearState
    binaryCandidates: [root.fx("panel-combo.sh")]
    timeoutMs: 3000
    wlCopyPath: root.fx("wl-copy-capture.sh")
    wlPastePath: root.fx("wl-paste-readback.sh")
  }

  function groupH() {
    moveClearState.open()
    root.waitUntil(function () { return moveClearState.loadState !== "loading" }, 3000, function () {
      moveClearState.activateSelected() // GitHub, TOTP -- reveals directly
      root.waitUntil(function () { return moveClearState.revealState === "revealed" }, 3000, function () {
        root.check("H: revealed before moving the selection", moveClearState.revealedEntry && moveClearState.revealedEntry.current === "482913")

        moveClearState.moveSelection(1) // GitHub -> Example
        root.check("H: moveSelection() clears the reveal SYNCHRONOUSLY, no wait needed", moveClearState.revealState === "idle")
        root.check("H: revealedEntry is dropped, not just hidden", moveClearState.revealedEntry === null)

        // The exact same class of bug via a DIFFERENT write path: Popup.qml's
        // row click sets selectedIndex directly rather than going through
        // moveSelection() -- must be caught too, not just the arrow-key path.
        moveClearState.activateSelected() // Example, TOTP -- reveals again
        root.waitUntil(function () { return moveClearState.revealState === "revealed" }, 3000, function () {
          root.check("H: revealed again after the first clear", moveClearState.revealState === "revealed")
          moveClearState.selectedIndex = 0 // simulates Popup.qml's TokenRow onClicked
          root.check("H: a direct selectedIndex write (the click path) ALSO clears the reveal", moveClearState.revealState === "idle" && moveClearState.revealedEntry === null)

          // And the filter-driven case: clamping can leave the NUMERIC
          // selectedIndex unchanged while the entry underneath it changes.
          moveClearState.activateSelected() // GitHub again
          root.waitUntil(function () { return moveClearState.revealState === "revealed" }, 3000, function () {
            moveClearState.setFilterText("bank") // narrows to just the HOTP row at index 0
            root.check("H: a filter change that re-points index 0 at a different entry also clears the reveal",
              moveClearState.revealState === "idle" && moveClearState.revealedEntry === null)
            root.runNext()
          })
        })
      })
    })
  }

  // ==== Group I: a failed clipboard copy must never be reported as a =====
  // success (adversarial review, HIGH, confirmed). Two distinct failure
  // shapes, because Quickshell's Process signals them differently:
  //   - a binary that doesn't exist at all fires NEITHER `started` NOR
  //     `exited` -- only an internal console WARN with no QML signal.
  //   - a binary that runs and exits nonzero fires a real `exited`.
  PanelState {
    id: copyNeverStartsState
    binaryCandidates: [root.fx("panel-combo.sh")]
    timeoutMs: 3000
    wlCopyPath: "/definitely/not/a/real/binary/wl-copy"
  }
  PanelState {
    id: copyExitFailsState
    binaryCandidates: [root.fx("panel-combo.sh")]
    timeoutMs: 3000
    wlCopyPath: root.fx("wl-copy-fail-exit.sh")
  }

  function groupI() {
    copyNeverStartsState.open()
    root.waitUntil(function () { return copyNeverStartsState.loadState !== "loading" }, 3000, function () {
      copyNeverStartsState.activateSelected()
      root.waitUntil(function () { return copyNeverStartsState.revealState === "revealed" }, 3000, function () {
        // The reveal itself (the otpclient-cli round trip) succeeded --
        // only the clipboard copy is broken. Give copyProc's
        // onRunningChanged a moment to observe the "never started" case.
        root.waitUntil(function () { return copyNeverStartsState.clipboardCopyState !== "copying" && copyNeverStartsState.clipboardCopyState !== "idle" }, 2000, function (settled) {
          root.check("I: a wl-copy that never starts is surfaced as clipboardCopyState 'failed', not silently 'copied'",
            settled && copyNeverStartsState.clipboardCopyState === "failed")
          root.check("I: a failure message is recorded, not just a bare flag", copyNeverStartsState.clipboardCopyError.length > 0)
          root.check("I: the code itself is still shown -- reveal succeeded even though the copy didn't", copyNeverStartsState.revealedEntry && copyNeverStartsState.revealedEntry.current === "482913")

          copyExitFailsState.open()
          root.waitUntil(function () { return copyExitFailsState.loadState !== "loading" }, 3000, function () {
            copyExitFailsState.activateSelected()
            root.waitUntil(function () { return copyExitFailsState.revealState === "revealed" }, 3000, function () {
              root.waitUntil(function () { return copyExitFailsState.clipboardCopyState !== "copying" && copyExitFailsState.clipboardCopyState !== "idle" }, 2000, function (settled2) {
                root.check("I: a wl-copy that starts but exits nonzero is ALSO surfaced as 'failed'",
                  settled2 && copyExitFailsState.clipboardCopyState === "failed")
                root.runNext()
              })
            })
          })
        })
      })
    })
  }

  // ==== Group J: the confirm gate is a DENY-list, not an ALLOW-list ======
  // (adversarial review, MEDIUM, confirmed). An entry whose type is
  // neither "TOTP" nor "HOTP" must still require confirmation -- gating on
  // isHotp(type) directly let it fall through unconfirmed into a --show
  // call that might be exactly the kind that mutates a counter.
  PanelState {
    id: unknownTypeState
    binaryCandidates: [root.fx("panel-unknown-type.sh")]
    timeoutMs: 3000
  }

  function groupJ() {
    unknownTypeState.open()
    root.waitUntil(function () { return unknownTypeState.loadState !== "loading" }, 3000, function () {
      root.check("J: fixture entry has an unrecognized (empty) type", unknownTypeState.selectedEntry && unknownTypeState.selectedEntry.type === "")

      var firstActivate = unknownTypeState.activateSelected()
      root.check("J: first activation on an unrecognized-type row is accepted (arms the gate)", firstActivate === true)
      root.check("J: it does NOT reveal unconfirmed -- this is the actual bug being regression-tested", unknownTypeState.revealState === "idle")
      root.check("J: the gate is armed for this row", unknownTypeState.hotpConfirmKey === Logic.entryKey({ issuer: "Mystery", account: "acct" }))

      var confirmed = unknownTypeState.activateSelected()
      root.check("J: the second, deliberate activation is accepted", confirmed === true)
      root.waitUntil(function () { return unknownTypeState.revealState !== "loading" }, 3000, function (ok) {
        root.check("J: only after confirming does it actually reveal", ok && unknownTypeState.revealState === "revealed")
        root.runNext()
      })
    })
  }

  // ==== Group K: maskRevealedCode conceals the SCREEN, never the copy ====
  // (adversarial review, MEDIUM, confirmed). An earlier version gated the
  // clipboard copy itself on !maskRevealedCode -- turning masking on would
  // have suppressed the copy while still painting the raw code on screen,
  // the exact opposite of "safe to have open on a shared screen".
  PanelState {
    id: maskState
    binaryCandidates: [root.fx("panel-combo.sh")]
    timeoutMs: 3000
    wlCopyPath: root.fx("wl-copy-capture.sh")
    wlPastePath: root.fx("wl-paste-readback.sh")
    maskRevealedCode: true
  }

  function groupK() {
    maskState.open()
    root.waitUntil(function () { return maskState.loadState !== "loading" }, 3000, function () {
      maskState.activateSelected()
      root.waitUntil(function () { return maskState.revealState === "revealed" }, 3000, function () {
        root.check("K: maskRevealedCode conceals the on-screen code", maskState.codeMaskedOnScreen === true)
        root.check("K: ...but the code itself is still held for display once unmasked", maskState.revealedEntry && maskState.revealedEntry.current === "482913")

        root.waitUntil(function () { return maskState.clipboardCopyState !== "copying" && maskState.clipboardCopyState !== "idle" }, 2000, function () {
          root.check("K: the copy STILL happened despite masking -- masking must never suppress it", maskState.clipboardCopyState === "copied")

          checkMaskedCopyLanded.running = true
        })
      })
    })
  }

  Process {
    id: checkMaskedCopyLanded
    command: [root.fx("wl-paste-readback.sh")]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        root.check("K: the actual clipboard content matches the (screen-masked) code", text === "482913")
        root.check("K: unmaskRevealedCode() is available to reveal it on screen on request", typeof maskState.unmaskRevealedCode === "function")
        maskState.unmaskRevealedCode()
        root.check("K: calling it clears the on-screen mask", maskState.codeMaskedOnScreen === false)
        root.runNext()
      }
    }
  }

  Component.onCompleted: {
    root.steps = [
      root.groupA,
      root.groupB,
      root.groupC,
      root.groupD,
      root.groupE,
      root.groupF,
      root.groupG,
      root.groupH,
      root.groupI,
      root.groupJ,
      root.groupK
    ]
    root.runNext()
  }
}
