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
  // Conceals the on-screen code for a reveal; a copy to the clipboard
  // still ALWAYS happens regardless of this (see onShowSucceeded below --
  // adversarial review found an earlier version had this backwards,
  // suppressing the copy instead of the on-screen paint, which is the
  // opposite of "safe to have open on a shared screen"). Defaults false:
  // issue #5's default reveal behavior is to show what was just copied.
  // #8 owns wiring this to a persisted "maskCodes" setting; the masked
  // code is still revealable on screen via the explicit unmaskRevealedCode()
  // action below, since #8's whole point is a default, not a one-way lock.
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

  // Whether the CURRENTLY revealed code's on-screen display is concealed
  // (see maskRevealedCode's docstring). Snapshotted from maskRevealedCode
  // at reveal time rather than bound live to it, so toggling the setting
  // mid-reveal can't retroactively unmask something already being shown
  // masked, or vice versa -- and so unmaskRevealedCode() below has
  // somewhere of its own to write "reveal it anyway" without mutating the
  // setting itself.
  property bool codeMaskedOnScreen: false

  // True when the current reveal's countdown is THIS UI's own fabricated
  // auto-clear window (hotpRevealFallbackSeconds), not a real CLI-reported
  // expiry (TOTP's validity_seconds). Computed from whether the CLI
  // actually reported one (entry.secondsRemaining >= 0), not from the
  // entry's `type` string -- deliberately data-driven rather than
  // identity-driven, so it stays correct even for the same unrecognized-
  // type edge case isDefinitivelyTotp()/requiresConfirmation() exist for.
  // Popup.qml must word a fabricated countdown differently from a real
  // one (see PanelLogic.revealStatusText()) -- an HOTP code does not
  // expire on a clock, and showing one tick down like a TOTP code would
  // say something false about how the token works.
  property bool revealCountdownIsFallback: false

  // Outcome of the LAST clipboard-copy attempt for the current reveal --
  // "idle" | "copying" | "copied" | "failed". Adversarial review found a
  // failed wl-copy invocation (including the binary not existing at all)
  // was previously reported to the user as a successful copy, with no
  // signal anywhere that anything had gone wrong. See copyProc's wiring
  // below for how "failed" is actually detected.
  property string clipboardCopyState: "idle"
  property string clipboardCopyError: ""

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

  // Explicit "show me anyway" action for a masked reveal (maskRevealedCode
  // -- #8). The clipboard copy already happened unconditionally when the
  // reveal succeeded (see onShowSucceeded) -- this only affects the
  // on-screen paint.
  function unmaskRevealedCode() {
    root.codeMaskedOnScreen = false
  }

  // Drops the current reveal (and/or an armed HOTP confirm) the moment the
  // selection no longer points at the row either one belongs to.
  //
  // Adversarial review (HIGH, confirmed): moveSelection() never called
  // clearReveal(), and isRevealedFor() matches by the revealed entry's own
  // issuer/account rather than by selectedIndex, so Popup.qml kept
  // painting a plaintext code on screen no matter where the highlight
  // moved -- reveal, arrow to another row, walk away, and the code stays
  // legible for its full countdown window regardless.
  //
  // Selection can change in more ways than just moveSelection() stepping
  // it by one, which is why this is a function called explicitly at every
  // site that can change what row is selected, rather than something
  // hung off selectedIndex's own change signal alone:
  //   - Popup.qml's row click sets selectedIndex directly.
  //   - setFilterText() can re-clamp selectedIndex to a value that's
  //     numerically UNCHANGED but now denotes a completely different
  //     entry, because the list underneath it narrowed -- a plain
  //     onSelectedIndexChanged handler would miss exactly that case.
  //
  // Reads Logic.entryAt(filteredEntries, selectedIndex) directly rather
  // than the selectedEntry convenience property -- confirmed empirically
  // that when this runs from an onSelectedIndexChanged handler,
  // selectedEntry's OWN binding (which also depends on selectedIndex) can
  // still be evaluating against the OLD selectedIndex at that point: QML
  // delivers a property's changed signal to every connected receiver in
  // connection order, and there is no guarantee an explicit
  // onSelectedIndexChanged handler runs after every OTHER binding that
  // also depends on selectedIndex has refreshed. filteredEntries has no
  // such dependency on selectedIndex, so computing the entry from it
  // directly here sidesteps the ordering hazard entirely.
  function _syncRevealToSelection() {
    var entry = Logic.entryAt(root.filteredEntries, root.selectedIndex)
    var key = entry ? Logic.entryKey(entry) : ""

    if (root.hotpConfirmKey !== "" && root.hotpConfirmKey !== key) root.cancelHotpConfirm()

    var revealKey = root.revealedEntry ? Logic.entryKey(root.revealedEntry) : ""
    var pendingKey = root._pendingKey
    if ((revealKey !== "" && revealKey !== key) || (pendingKey !== "" && pendingKey !== key)) {
      root.clearReveal()
    }
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
    root.selectedIndex = Logic.clampIndex(root.selectedIndex, root.filteredEntries.length)
    // Explicit call, not just reliance on onSelectedIndexChanged below:
    // clamping can leave selectedIndex at the SAME numeric value while the
    // entry it now points at is a completely different one, because the
    // list underneath just narrowed -- see _syncRevealToSelection()'s
    // docstring.
    root._syncRevealToSelection()
  }

  function moveSelection(delta) {
    var next = Logic.clampIndex(root.selectedIndex + delta, root.filteredEntries.length)
    if (next === root.selectedIndex) return
    root.selectedIndex = next // onSelectedIndexChanged below runs _syncRevealToSelection()
  }

  // Catches every OTHER way selectedIndex can change -- a row click in
  // Popup.qml sets it directly, and a fresh --list's onListSucceeded
  // re-clamps it -- without each of those call sites having to remember to
  // call _syncRevealToSelection() itself. setFilterText() above still calls
  // it explicitly too, for the one case (see its own comment) this signal
  // can't catch on its own: the index value not changing at all.
  onSelectedIndexChanged: root._syncRevealToSelection()

  function cancelHotpConfirm() {
    hotpConfirmTimer.stop()
    root.hotpConfirmKey = ""
  }

  // Enter (or a click) on the selected row. Returns true if it did
  // something (armed a confirm, or issued a reveal request), false if
  // there was nothing to act on or a call was already in flight.
  //
  // Gated on Logic.requiresConfirmation(), a DENY-list, not
  // Logic.isHotp()'s ALLOW-list -- adversarial review (MEDIUM, confirmed):
  // an entry whose type is empty/missing/unrecognized (not reachable
  // through today's otpclient-cli, which only ever emits "TOTP"/"HOTP",
  // but not provably unreachable forever either) fell through isHotp()'s
  // false branch and revealed immediately, no confirmation armed, on a
  // --show call that might be exactly the one that advances and persists
  // a real counter. requiresConfirmation() is true for anything that
  // isn't affirmatively, definitely TOTP, so the unknown case is treated
  // as needing confirmation rather than being silently allowed through.
  function activateSelected() {
    var entry = root.selectedEntry
    if (!entry) return false
    if (backend.busy) return false // a call is already in flight; ignore rather than error

    if (Logic.requiresConfirmation(entry.type)) {
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

  // `viaHotpPath` selects which Backend entry point handles the request --
  // requestHotpCode() (gated behind activateSelected()'s confirm step
  // above, for anything requiresConfirmation() flagged) or requestCode()
  // (confirmed-TOTP only). Functionally identical otpclient-cli invocation
  // either way; the distinction is entirely about which caller has already
  // done its job gating it.
  function _requestReveal(entry, viaHotpPath) {
    root.clearReveal()
    root.revealState = "loading"
    root._pendingKey = root._keyFor(entry.issuer, entry.account)
    var ok = viaHotpPath
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
  // timeout, on panel close, on selection change (see
  // _syncRevealToSelection()), and before starting a new reveal -- never
  // more than one code held at a time (issue #5).
  function clearReveal() {
    countdownTimer.stop()
    clipboardClearTimer.stop()
    root.revealState = "idle"
    root.revealedEntry = null
    root.revealErrorMessage = ""
    root._pendingKey = ""
    root.codeMaskedOnScreen = false
    root.revealCountdownIsFallback = false
    root.clipboardCopyState = "idle"
    root.clipboardCopyError = ""
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
      // docstring). Recorded BEFORE normalizing it below, since that's the
      // one moment this function can still tell a real CLI-reported expiry
      // apart from this UI's own fabricated auto-clear window (see
      // revealCountdownIsFallback's docstring -- adversarial review found
      // Popup.qml rendering both identically, which tells the user an HOTP
      // code is "expiring" on a clock it doesn't have).
      var isFallback = !(entry.secondsRemaining >= 0)
      // Normalize the seconds into the displayed/held object itself, right
      // here, rather than leaving the raw -1 in `revealedEntry` until the
      // first countdownTimer tick a full second later papers over it --
      // otherwise a caller reading revealedEntry.secondsRemaining in that
      // first second (Popup.qml's own binding included) would show "-1s".
      var initial = Math.max(1, isFallback ? root.hotpRevealFallbackSeconds : entry.secondsRemaining)
      var normalized = {}
      for (var k in entry) normalized[k] = entry[k]
      normalized.secondsRemaining = initial
      root.revealedEntry = normalized
      root.revealCountdownIsFallback = isFallback
      root.codeMaskedOnScreen = root.maskRevealedCode
      root.revealState = "revealed"
      countdownTimer.secondsLeft = initial
      countdownTimer.restart()
      // ALWAYS copies, regardless of maskRevealedCode -- adversarial
      // review (MEDIUM, confirmed): masking must conceal the on-screen
      // code, never suppress the copy that's the entire point of revealing
      // it. maskRevealedCode only gates codeMaskedOnScreen above.
      root._copyToClipboard(entry.current)
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
    if (typeof code !== "string" || code.length === 0) {
      root._onClipboardCopyResult(false, "No code to copy.")
      return
    }
    root.clipboardCopyState = "copying"
    root.clipboardCopyError = ""
    copyProc._started = false
    copyProc._finished = false
    copyProc.command = [root.wlCopyPath]
    copyProc._payload = code
    copyProc.stdinEnabled = true
    copyProc.running = true
    if (root.clipboardClearSeconds > 0) {
      clipboardClearTimer.interval = root.clipboardClearSeconds * 1000
      clipboardClearTimer.restart()
    }
  }

  // Records the outcome of the LAST copy attempt on root, for Popup.qml to
  // render (PanelLogic.revealStatusText()) instead of the unconditional
  // "code copied" adversarial review found -- see clipboardCopyState's
  // docstring.
  function _onClipboardCopyResult(success, message) {
    // A response for a copy that's since been superseded (a new reveal
    // already started, or the reveal was cleared entirely) must not
    // retroactively flip clipboardCopyState back from "idle"/a newer
    // attempt's own state.
    if (root.revealState !== "revealed" && root.revealState !== "loading") return
    root.clipboardCopyState = success ? "copied" : "failed"
    root.clipboardCopyError = success ? "" : message
  }

  // Quickshell's Process exposes `started` and `exited` as real QML
  // signals, but a process that fails to start at all (bad path, not
  // executable) fires NEITHER -- only an internal console WARN
  // ("Process failed to start...") that isn't reachable from QML.
  // Adversarial review reproduced exactly this by pointing wlCopyPath at a
  // nonexistent binary: revealState still settled to "revealed" with no
  // error anywhere, because nothing here was listening for the one signal
  // Quickshell doesn't give a name to. `running` flipping back to false
  // WITHOUT `started` or `exited` having fired first is the only
  // observable signature of that case (confirmed empirically -- see the PR
  // description) -- onRunningChanged below is what catches it.
  Process {
    id: copyProc
    property string _payload: ""
    property bool _started: false
    property bool _finished: false

    onStarted: {
      copyProc._started = true
      write(copyProc._payload)
      copyProc._payload = ""
      copyProc.stdinEnabled = false
    }
    onExited: function (exitCode, exitStatus) {
      copyProc._finished = true
      if (exitCode === 0 && exitStatus === 0) {
        root._onClipboardCopyResult(true, "")
      } else {
        root._onClipboardCopyResult(false, "wl-copy exited with an error (code " + exitCode + ").")
      }
    }
    onRunningChanged: {
      if (running) return // _started/_finished already reset by _copyToClipboard() before this
      if (!copyProc._started && !copyProc._finished) {
        root._onClipboardCopyResult(false, "wl-copy could not be started.")
      }
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
