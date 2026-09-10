import QtQuick
import Quickshell.Io
import "PanelLogic.js" as Logic

// PanelState.qml -- headless-testable controller for the 2FA panel (issues
// #4 and #5). Owns the Backend instance, the wl-copy/wl-paste clipboard
// processes, and every Timer that drives search/selection/reveal/
// countdown/HOTP-confirm state.
//
// Deliberately NOT a Window/PopupWindow, and deliberately not even
// depending on `bar` -- Popup.qml (the actual PopupWindow, wired up in
// Widget.qml for issue #3) binds its visuals to this object's properties
// and forwards key/mouse input to its functions. Splitting it out this way
// means everything in this file -- list load, search filtering, keyboard
// selection, the HOTP confirm gate, reveal/copy, and the countdown/clear
// timers -- can be driven and asserted by tests/panel.qmltest.qml under
// `quickshell -p` without ever mapping a window on screen, the same
// discipline Backend.qml/backend.qmltest.qml already established for the
// process layer.
//
// Binary/tool paths are overridable for exactly the reason Backend.qml's
// own binaryCandidates is: tests point every external process this file
// can spawn (otpclient-cli via Backend, wl-copy, wl-paste) at a fixture
// script instead of the real thing, so a test run never touches this
// machine's real OTPClient database or its real Wayland clipboard.
Item {
  id: root

  // ---- Backend passthrough (test hooks; see Backend.qml) -----------------
  property alias binaryCandidates: backend.binaryCandidates
  property alias timeoutMs: backend.timeoutMs
  readonly property var entries: backend.entries
  readonly property bool busy: backend.busy

  // ---- External tool paths (overridable for tests) -----------------------
  property string wlCopyPath: "/usr/bin/wl-copy"
  property string wlPastePath: "/usr/bin/wl-paste"

  // ---- Forward-compatible hooks for #8 (settings), not otherwise wired
  // to anything persisted from this issue set -----------------------------
  // <= 0 disables the optional post-copy clipboard-clear timer.
  property int clipboardClearSeconds: 0
  // When true, a reveal still copies to the clipboard but the code is never
  // painted on screen. Defaults false: issue #5's default reveal behavior
  // is to show what was just copied. #8 owns wiring this to a persisted
  // "maskCodes" setting.
  property bool maskRevealedCode: false

  // otpclient-cli never reports validity_seconds for HOTP (there is no
  // period to count down -- verified against a real database, see Cli.js's
  // module docstring) so `entry.secondsRemaining` comes back -1. This is a
  // fixed fallback window purely for this UI's own "don't leave a
  // decrypted code on screen forever" backstop -- not information from
  // otpclient-cli.
  readonly property int hotpRevealFallbackSeconds: 30

  // ---- Inventory / search / selection -------------------------------------
  property string filterText: ""
  readonly property var filteredEntries: Logic.filterEntries(root.entries, root.filterText)
  property int selectedIndex: -1
  readonly property var selectedEntry: Logic.entryAt(root.filteredEntries, root.selectedIndex)

  // idle -> loading -> ok | empty | error
  property string loadState: "idle"
  property string loadErrorState: ""
  property string loadErrorMessage: ""

  // ---- HOTP confirm gate ---------------------------------------------------
  // Non-empty while a row's FIRST activation is armed, waiting for the
  // deliberate second activation issue #5 requires before an HOTP counter
  // is allowed to advance (--show ADVANCES AND PERSISTS it -- see
  // Backend.qml's requestHotpCode() docstring). Keyed by issuer+account,
  // not index, so a re-sort/re-filter can't hand the armed confirmation to
  // a different token that happens to land on the same row position.
  property string hotpConfirmKey: ""

  // ---- Reveal state ---------------------------------------------------------
  // idle -> loading -> revealed | error
  property string revealState: "idle"
  // {issuer, account, type, current, secondsRemaining} -- the SAME single
  // object for the lifetime of one reveal. A new reveal (clearReveal(),
  // called first by _requestReveal()) always replaces it; never more than
  // one is held at a time, matching the discipline Backend.qml itself
  // applies to its stdout collectors -- this is that same discipline one
  // layer up, at the UI's own state.
  property var revealedEntry: null
  property string revealErrorMessage: ""
  property string _pendingKey: ""

  // Delegates to Logic.entryKey's JSON-encoded pairing (see PanelLogic.js)
  // rather than a hand-rolled separator, so a pending/confirm key built
  // from raw issuer/account strings here can never diverge from the one
  // Logic.entryKey() computes from a full entry object elsewhere in this
  // file and in Popup.qml.
  function _keyFor(issuer, account) { return Logic.entryKey({ issuer: issuer, account: account }) }

  // Whether a reveal is currently in flight for exactly this issuer/account
  // (used by Popup.qml to show a per-row spinner rather than a global one).
  function isRevealPendingFor(issuer, account) {
    return root.revealState === "loading" && root._pendingKey === root._keyFor(issuer, account)
  }

  // Whether the currently-revealed code (if any) belongs to this row.
  function isRevealedFor(issuer, account) {
    return root.revealState === "revealed" && !!root.revealedEntry
      && root.revealedEntry.issuer === issuer && root.revealedEntry.account === account
  }

  // ---- Lifecycle ------------------------------------------------------------

  // Called every time the panel opens. Issue #4 is explicit that inventory
  // is refreshed on open, not on a timer -- every refresh is a real 128 MiB
  // Argon2id decrypt, so this always issues a fresh --list rather than
  // reusing whatever `entries` still holds from last time.
  function open() {
    root.clearReveal()
    root.cancelHotpConfirm()
    root.filterText = ""
    root.selectedIndex = -1
    root.refresh()
  }

  // Called every time the panel closes. Drops the one code this file may be
  // holding (issue #5: "clear ... on panel close") and disarms any
  // unconfirmed HOTP gate so it doesn't survive to the next open.
  function close() {
    root.clearReveal()
    root.cancelHotpConfirm()
  }

  function refresh() {
    root.loadState = "loading"
    root.loadErrorState = ""
    root.loadErrorMessage = ""
    if (!backend.listInventory()) {
      // Refused synchronously -- some other call (this Backend instance,
      // or another monitor's, sharing Backend's process-wide gate) is
      // already in flight. Not one of otpclient-cli's own typed states, so
      // kept distinct from what Backend itself reports.
      root.loadState = "error"
      root.loadErrorState = "busy"
      root.loadErrorMessage = "Busy -- try again in a moment."
    }
  }

  function setFilterText(text) {
    root.filterText = String(text || "")
    // The set of visible rows just changed; an armed-but-unconfirmed HOTP
    // gate could otherwise survive onto a different row that lands in the
    // same position once results narrow.
    root.cancelHotpConfirm()
    root.selectedIndex = Logic.clampIndex(root.selectedIndex, root.filteredEntries.length)
  }

  function moveSelection(delta) {
    var next = Logic.clampIndex(root.selectedIndex + delta, root.filteredEntries.length)
    if (next === root.selectedIndex) return
    root.selectedIndex = next
    var entry = root.selectedEntry
    if (!entry || Logic.entryKey(entry) !== root.hotpConfirmKey) root.cancelHotpConfirm()
  }

  function cancelHotpConfirm() {
    hotpConfirmTimer.stop()
    root.hotpConfirmKey = ""
  }

  // Enter (or a click) on the selected row. Returns true if it did
  // something (armed a confirm, or issued a reveal request), false if
  // there was nothing to act on or a call was already in flight.
  function activateSelected() {
    var entry = root.selectedEntry
    if (!entry) return false
    if (backend.busy) return false // a call is already in flight; ignore rather than error

    if (Logic.isHotp(entry.type)) {
      var key = Logic.entryKey(entry)
      if (root.hotpConfirmKey === key) {
        // Second, deliberate activation of the same armed row -- issue #5's
        // required confirmation gate before an HOTP counter is allowed to
        // advance.
        root.cancelHotpConfirm()
        return root._requestReveal(entry, true)
      }
      root.hotpConfirmKey = key
      hotpConfirmTimer.restart()
      return true
    }

    root.cancelHotpConfirm()
    return root._requestReveal(entry, false)
  }

  function _requestReveal(entry, isHotp) {
    root.clearReveal()
    root.revealState = "loading"
    root._pendingKey = root._keyFor(entry.issuer, entry.account)
    var ok = isHotp
      ? backend.requestHotpCode(entry.issuer, entry.account)
      : backend.requestCode(entry.issuer, entry.account, entry.type)
    if (!ok) {
      root.revealState = "error"
      root.revealErrorMessage = "Busy -- try again in a moment."
      root._pendingKey = ""
    }
    return ok
  }

  // Drops the currently revealed code, if any. Called on countdown
  // timeout, on panel close, and before starting a new reveal -- never
  // more than one code held at a time (issue #5).
  function clearReveal() {
    countdownTimer.stop()
    clipboardClearTimer.stop()
    root.revealState = "idle"
    root.revealedEntry = null
    root.revealErrorMessage = ""
    root._pendingKey = ""
  }

  // ---- Backend wiring -------------------------------------------------------

  Backend {
    id: backend

    onListSucceeded: function (list) {
      root.loadState = "ok"
      root.loadErrorState = ""
      root.loadErrorMessage = ""
      root.selectedIndex = Logic.clampIndex(root.selectedIndex >= 0 ? root.selectedIndex : 0, root.filteredEntries.length)
    }
    onListFailed: function (state, message) {
      root.loadState = state === "empty" ? "empty" : "error"
      root.loadErrorState = state
      root.loadErrorMessage = message
      root.selectedIndex = -1
    }
    onShowSucceeded: function (issuer, account, entry) {
      if (root._keyFor(issuer, account) !== root._pendingKey) return // stale/foreign response
      root._pendingKey = ""
      root.revealErrorMessage = ""
      // entry.secondsRemaining is -1 whenever the CLI didn't report one at
      // all (always true for HOTP -- see hotpRevealFallbackSeconds's own
      // docstring). Normalize it into the displayed/held object itself,
      // right here, rather than leaving the raw -1 in `revealedEntry` until
      // the first countdownTimer tick a full second later papers over it --
      // otherwise a caller reading revealedEntry.secondsRemaining in that
      // first second (Popup.qml's own binding included) would show "-1s".
      var initial = Math.max(1, entry.secondsRemaining >= 0 ? entry.secondsRemaining : root.hotpRevealFallbackSeconds)
      var normalized = {}
      for (var k in entry) normalized[k] = entry[k]
      normalized.secondsRemaining = initial
      root.revealedEntry = normalized
      root.revealState = "revealed"
      countdownTimer.secondsLeft = initial
      countdownTimer.restart()
      if (!root.maskRevealedCode) root._copyToClipboard(entry.current)
    }
    onShowFailed: function (issuer, account, state, message) {
      if (root._keyFor(issuer, account) !== root._pendingKey) return
      root._pendingKey = ""
      root.revealState = "error"
      root.revealErrorMessage = message
      root.revealedEntry = null
    }
  }

  // ---- Countdown: local ticking of the reveal window ------------------------
  // Ticks the remaining seconds down once a second and clears the reveal at
  // zero -- issue #5's "Clear the code from the UI after the reveal window
  // elapses." Driven entirely by validity_seconds, which otpclient-cli
  // documents as seconds LEFT in the current period, not the period length
  // (verified: 18 at t=12s on a 30s token -- see Cli.js). The period itself
  // is never exposed, and issue #5 explicitly prefers an honest
  // seconds-remaining readout over a proportional ring built on an inferred
  // period "if that inference feels too clever" -- it does, here: a ring
  // would need to guess 30 vs. 60 (or misrepresent an HOTP fallback window
  // as if it meant something about the token), so Popup.qml renders this
  // countdown as plain text, never a ring.
  Timer {
    id: countdownTimer
    interval: 1000
    repeat: true
    property int secondsLeft: 0
    onTriggered: {
      secondsLeft -= 1
      if (root.revealedEntry) {
        var next = {}
        for (var k in root.revealedEntry) next[k] = root.revealedEntry[k]
        next.secondsRemaining = secondsLeft
        root.revealedEntry = next
      }
      if (secondsLeft <= 0) root.clearReveal()
    }
  }

  // ---- HOTP confirm auto-disarm ----------------------------------------------
  // Mirrors zeru.portwatch's armTimer for its own destructive-action
  // confirm gate: an armed-but-unconfirmed HOTP row disarms itself rather
  // than staying live indefinitely waiting for a click that may never come.
  Timer {
    id: hotpConfirmTimer
    interval: 3000
    onTriggered: root.hotpConfirmKey = ""
  }

  // ---- Clipboard --------------------------------------------------------------

  // Writes `code` to wl-copy over STDIN ONLY -- never as an argv element,
  // per issue #5 (argv is world-readable via /proc/<pid>/cmdline). Absolute
  // path, argv array, no shell -- the same line Cli.js holds for
  // otpclient-cli itself. stdinEnabled is flipped back off right after the
  // write: Quickshell's Process exposes `write()` but no separate
  // "close the write channel" call, and without closing it wl-copy blocks
  // forever waiting for more input instead of reading EOF, forking, and
  // taking ownership of the selection -- confirmed empirically against the
  // real /usr/bin/wl-copy on the machine this was built on (see the PR
  // description).
  function _copyToClipboard(code) {
    if (typeof code !== "string" || code.length === 0) return
    copyProc.command = [root.wlCopyPath]
    copyProc._payload = code
    copyProc.stdinEnabled = true
    copyProc.running = true
    if (root.clipboardClearSeconds > 0) {
      clipboardClearTimer.interval = root.clipboardClearSeconds * 1000
      clipboardClearTimer.restart()
    }
  }

  Process {
    id: copyProc
    property string _payload: ""
    onStarted: {
      write(copyProc._payload)
      copyProc._payload = ""
      copyProc.stdinEnabled = false
    }
  }

  // Clears the clipboard clipboardClearSeconds after a copy (#8) -- but
  // ONLY if the clipboard still holds the exact code this file put there,
  // so a user's own copy in the meantime is never clobbered (issue #5).
  // Reads the clipboard back via wl-paste first; nothing is written unless
  // the comparison (Logic.clipboardStillOurs) matches.
  Timer {
    id: clipboardClearTimer
    interval: 30000
    onTriggered: {
      if (!root.revealedEntry || !root.revealedEntry.current) return
      pasteProc._expected = root.revealedEntry.current
      pasteProc.command = [root.wlPastePath, "--no-newline"]
      pasteProc.running = true
    }
  }

  Process {
    id: pasteProc
    property string _expected: ""
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var expected = pasteProc._expected
        pasteProc._expected = ""
        if (Logic.clipboardStillOurs(text, expected)) clearCopyProc.running = true
      }
    }
  }

  // An empty/cleared selection via wl-copy's own --clear flag -- documented
  // wl-clipboard behavior -- rather than writing an empty string over
  // stdin, which would just copy an empty string as the new clipboard
  // content instead of clearing the offer entirely.
  Process {
    id: clearCopyProc
    command: [root.wlCopyPath, "--clear"]
  }

  // Test-only diagnostic -- NOT part of the public API, may change or
  // disappear without notice. Confirms the clipboard-copy Process's argv
  // never carries the code as an element (issue #5: the code goes over
  // stdin only, since argv is world-readable via /proc/<pid>/cmdline) --
  // mirrors Backend.qml's own __debugListStdoutText()/__debugShowStdoutText()
  // test hooks. See tests/panel.qmltest.qml.
  function __debugCopyArgvIsPathOnly() {
    return copyProc.command.length === 1 && copyProc.command[0] === root.wlCopyPath
  }
}
