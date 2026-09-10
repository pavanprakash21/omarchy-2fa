.pragma library

// PanelLogic.js -- pure helpers for the 2FA panel (issues #4/#5). Nothing
// here touches a QML/Quickshell type, so it can be loaded and exercised
// with plain `node` outside the shell runtime (see
// tests/panel-logic.test.js), the same split Cli.js/Backend.qml already
// use for the process layer. PanelState.qml owns all state, Timers and
// Process objects; this file only computes things from plain data that's
// already in hand.

function normalizeType(type) {
  return String(type || "").toUpperCase()
}

// otpclient-cli's --list/--show both report `type` as the literal strings
// "TOTP"/"HOTP" (confirmed against a real database -- see the PR
// description), but this is matched case-insensitively defensively, same
// as Backend.qml's own requestCode() guard. Used for DISPLAY only (the
// TOTP/HOTP badge) -- see isDefinitivelyTotp()/requiresConfirmation() below
// for the confirm-gate decision, which is deliberately NOT the negation of
// this function.
function isHotp(type) {
  return normalizeType(type) === "HOTP"
}

// True only for the literal, confirmed-safe "TOTP" string. Adversarial
// review (issue #5) found that gating the confirm-before-reveal gate on
// isHotp(type) is an ALLOW-list: an entry whose type is empty, missing, or
// some third value neither "TOTP" nor "HOTP" would fall through
// activateSelected()'s non-HOTP branch and reveal immediately, no
// confirmation armed. otpclient-cli only ever emits "TOTP"/"HOTP" today
// (verified against a real database), so this can't currently diverge from
// !isHotp() in practice -- but the failure mode on the other side (an
// unrecognized type silently allowed to fire an unconfirmed --show, which
// may be the very call that advances and persists a real HOTP counter) is
// bad enough that the gate must be a DENY-list instead: require
// confirmation for anything that is not affirmatively, definitely TOTP.
function isDefinitivelyTotp(type) {
  return normalizeType(type) === "TOTP"
}

// The confirm-gate predicate activateSelected() actually uses. Inverted
// from isHotp() on purpose -- see isDefinitivelyTotp()'s docstring.
function requiresConfirmation(type) {
  return !isDefinitivelyTotp(type)
}

// issuer+account is the only thing that uniquely and stably identifies a
// row across a --list refresh or a search filter -- there is no other id
// in the inventory payload (see Cli.js's normalizeEntry). Both fields are
// arbitrary user-controlled text (from an imported otpauth:// URI), so a
// plain string concatenation could in principle collide across two
// different rows if either field ever contained the separator itself.
// JSON-encoding the pair sidesteps that entirely: JSON.stringify escapes
// each string's own content, so the array's element boundary can never be
// confused with a character inside either field.
function entryKey(entry) {
  if (!entry) return ""
  return JSON.stringify([String(entry.issuer || ""), String(entry.account || "")])
}

function matchesFilter(entry, needleLower) {
  if (!needleLower) return true
  var hay = (String(entry.issuer || "") + " " + String(entry.account || "")).toLowerCase()
  return hay.indexOf(needleLower) !== -1
}

// Type-to-filter search over issuer+account (issue #4). Case-insensitive
// substring match; an empty/whitespace-only filter passes everything
// through unchanged (and returns the SAME kind of array -- a fresh copy --
// so callers never accidentally mutate the backend's own `entries` cache).
function filterEntries(entries, filterText) {
  var list = Array.isArray(entries) ? entries : []
  var needle = String(filterText || "").trim().toLowerCase()
  if (!needle) return list.slice()
  var out = []
  for (var i = 0; i < list.length; i++) {
    if (matchesFilter(list[i], needle)) out.push(list[i])
  }
  return out
}

// Clamps a selection index into [0, length-1], or -1 for an empty list.
// Never wraps -- arrow-key navigation stops at the ends rather than
// cycling, which is the least surprising behavior for a short list guarded
// by a search field.
function clampIndex(index, length) {
  if (length <= 0) return -1
  if (index < 0) return 0
  if (index > length - 1) return length - 1
  return index
}

function entryAt(list, index) {
  if (!Array.isArray(list) || index < 0 || index >= list.length) return null
  return list[index]
}

// Issue #5: "Clear only if the clipboard still holds the code we put
// there, so we never wipe something the user copied since." A plain
// string-equality check against the one code this session is still
// holding (PanelState.qml drops it at the same moments it would need to
// clear the clipboard for anyway -- see clearReveal()), never a stored
// hash or a second copy kept solely for this comparison.
function clipboardStillOurs(clipboardText, expectedCode) {
  return typeof expectedCode === "string" && expectedCode.length > 0 && clipboardText === expectedCode
}

// The status line Popup.qml renders under a revealed row's issuer. Two
// things this MUST NOT get wrong, both found by adversarial review of an
// earlier version that hard-coded "<type> code copied" unconditionally:
//
// 1. `clipboardCopyState` -- never claim "copied" unless the wl-copy
//    invocation actually succeeded. copyProc's wiring in PanelState.qml
//    (onExited/onRunningChanged) is what actually detects a failed copy
//    (including "the process never started at all", which Quickshell does
//    not expose as a proper QML signal for); this function only renders
//    whatever state it's told.
// 2. `isFallbackCountdown` -- a REAL CLI-reported expiry (TOTP's
//    validity_seconds) must read differently from this UI's own fabricated
//    auto-clear window (used when otpclient-cli reports no expiry at all,
//    i.e. every HOTP reveal -- see PanelState.qml's
//    hotpRevealFallbackSeconds). Wording them the same would tell the user
//    an HOTP code is "expiring" on a clock it doesn't actually have.
function revealStatusText(type, clipboardCopyState, secondsRemaining, isFallbackCountdown) {
  var seconds = Math.max(0, Number(secondsRemaining) || 0)
  var countdownPhrase = isFallbackCountdown
    ? ("auto-clears in " + seconds + "s")
    : (seconds + "s remaining")
  var typeLabel = String(type || "Code")

  if (clipboardCopyState === "failed") {
    return typeLabel + " code shown -- clipboard copy FAILED · " + countdownPhrase
  }
  if (clipboardCopyState === "copying") {
    return typeLabel + " code ready · copying to clipboard…"
  }
  return typeLabel + " code copied · " + countdownPhrase
}

// Maps a Backend-reported typed state (see Backend.qml's listFailed/
// showFailed docstring: binary-missing, would-prompt, bad-password,
// db-missing, malformed, empty, crashed, instance-conflict -- plus this
// panel's own synthetic "busy" for a call refused because another is
// already in flight) to a message that NAMES THE FIX, not the symptom --
// issue #6's core requirement. Backend/Cli.js's own messages are written
// for a developer reading a log (exit codes, elapsed-ms, raw stderr
// fragments); none of them tell a user what to actually go and do.
//
// Every branch below is a fixed, static string -- this function never
// echoes `fallbackMessage` (Backend/Cli.js's own text) except for the one
// `default` case of a state this function doesn't recognize at all. That's
// deliberate, not just tidy: issue #6 requires that no error message ever
// echo a password, a code, or a database secret, and Cli.js's own messages,
// while reviewed to avoid that today, are a moving part this file doesn't
// own (see the "consume, do not modify" note on Backend.qml/Cli.js) --
// hard-coding this panel's copy per typed STATE rather than laundering
// Backend's own MESSAGE text through here means a future change to
// Backend/Cli.js's wording can never leak something sensitive into this
// panel without also changing the typed state string itself, which is
// reviewed and tested independently (tests/backend.qmltest.qml).
//
// `context` is "list" or "show" -- the two callers, Popup.qml's panel-wide
// load-error banner and a single row's reveal-error text. Only `empty`
// actually differs by context: a --list with zero rows is issue #6's own
// neutral "empty database" state (rendered separately by Popup.qml's
// loadState === "empty" branch, which never calls this function at all --
// see there); a --show with an empty result means the specific account
// this row named didn't resolve anymore, which is a much rarer, narrower
// thing to explain.
function degradedStateMessage(state, context, fallbackMessage) {
  switch (state) {
    case "binary-missing":
      return "otpclient isn't installed. It's AUR-only (not in extra) -- " +
        "install it with: yay -S otpclient, then reopen this panel."
    case "would-prompt":
      return "OTPClient's Secret Service integration is off, so otpclient-cli " +
        "is waiting on a password prompt this panel can never answer. Open " +
        "OTPClient -> Preferences and enable \"Use Secret Service\" so the " +
        "keyring supplies the password automatically."
    case "bad-password":
      return "The password OTPClient has stored for this database is stale " +
        "or wrong. Unlock the database once in the OTPClient GUI to refresh " +
        "it in the keyring."
    case "db-missing":
      return "No OTPClient database found at the configured path. Set one up " +
        "in the OTPClient GUI, or check the path in " +
        "~/.config/otpclient/otpclient.cfg."
    case "malformed":
      return "otpclient-cli returned output this panel could not understand. " +
        "Reported as-is -- no automatic repair is attempted, since that could " +
        "touch your database."
    case "crashed":
      return "otpclient-cli crashed. This looks like a bug in otpclient-cli " +
        "or a damaged database, not something wrong with this panel's own " +
        "configuration -- try running otpclient-cli --list in a terminal for " +
        "more detail."
    case "instance-conflict":
      return "otpclient-cli couldn't run because another OTPClient process " +
        "already has the database open -- most commonly the OTPClient GUI " +
        "itself. Close it and try again."
    case "busy":
      return "Busy -- try again in a moment."
    case "empty":
      return context === "show"
        ? "No matching entry for this account anymore. Close and reopen the panel to refresh the list."
        : "No entries in your OTPClient database."
    default:
      return String(fallbackMessage || "Couldn't complete the request.")
  }
}

// The armed-confirmation prompt for a row gated by requiresConfirmation().
// Only names the HOTP counter-advance consequence when the type is
// affirmatively HOTP -- an unrecognized type (the same deny-list edge case
// isDefinitivelyTotp() exists for) gets a generic warning instead of a
// claim about what specifically will happen that this code can't actually
// back up.
function confirmPromptText(type) {
  return isHotp(type)
    ? "Press Enter again to confirm -- this advances the HOTP counter"
    : "Press Enter again to confirm this reveal"
}
