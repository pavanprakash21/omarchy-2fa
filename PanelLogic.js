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
// as Backend.qml's own requestCode() guard.
function isHotp(type) {
  return normalizeType(type) === "HOTP"
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
