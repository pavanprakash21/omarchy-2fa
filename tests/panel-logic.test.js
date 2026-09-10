#!/usr/bin/env node
// Pure-logic tests for PanelLogic.js: search filtering, selection clamping,
// the HOTP/entry key used by the confirm gate and reveal-matching in
// PanelState.qml, and the clipboard-still-ours comparison. Runs under plain
// `node`, no Quickshell/QML involved -- see tests/panel.qmltest.qml for the
// Timer/Process/Backend-wiring tests that do need the real Quickshell
// runtime. Mirrors tests/cli.test.js's own split for the same reason.
"use strict";

const fs = require("fs");
const path = require("path");
const vm = require("vm");

const logicPath = path.join(__dirname, "..", "PanelLogic.js");
const src = fs.readFileSync(logicPath, "utf8").replace(/^\s*\.pragma\s+library\s*\r?\n/, "");

const sandbox = {};
vm.createContext(sandbox);
new vm.Script(src, { filename: "PanelLogic.js" }).runInContext(sandbox);
const Logic = sandbox;

let pass = 0;
let fail = 0;
const failures = [];

function test(name, fn) {
  try {
    fn();
    pass++;
  } catch (e) {
    fail++;
    failures.push(name + ": " + e.message);
  }
}

function assert(cond, msg) {
  if (!cond) throw new Error(msg || "assertion failed");
}

function assertEqual(actual, expected, msg) {
  const ok = JSON.stringify(actual) === JSON.stringify(expected);
  if (!ok) {
    throw new Error(
      (msg ? msg + " -- " : "") + "expected " + JSON.stringify(expected) + ", got " + JSON.stringify(actual)
    );
  }
}

const totp = { issuer: "GitHub", account: "pavan@smaply.com", type: "TOTP", group: "" };
const totp2 = { issuer: "Example", account: "alice@example.com", type: "TOTP", group: "" };
const hotp = { issuer: "Bank", account: "acct1", type: "HOTP", group: "" };

// ---- isHotp -----------------------------------------------------------

test("isHotp matches the literal uppercase string otpclient-cli reports", () => {
  assert(Logic.isHotp("HOTP"));
  assert(!Logic.isHotp("TOTP"));
});

test("isHotp is case-insensitive defensively, like Backend.qml's own guard", () => {
  assert(Logic.isHotp("hotp"));
  assert(Logic.isHotp("Hotp"));
});

test("isHotp is false for missing/undefined type, never throws", () => {
  assert(!Logic.isHotp(undefined));
  assert(!Logic.isHotp(""));
  assert(!Logic.isHotp(null));
});

// ---- isDefinitivelyTotp / requiresConfirmation (adversarial review #3) --
// The confirm gate must be a DENY-list (require confirmation for anything
// that isn't affirmatively TOTP), not an ALLOW-list (require it only for
// anything affirmatively HOTP) -- an earlier version gated on isHotp(type)
// directly, which let an unrecognized type through unconfirmed.

test("isDefinitivelyTotp is true only for the literal TOTP string", () => {
  assert(Logic.isDefinitivelyTotp("TOTP"));
  assert(Logic.isDefinitivelyTotp("totp")); // case-insensitive, like isHotp()
  assert(!Logic.isDefinitivelyTotp("HOTP"));
});

test("requiresConfirmation is the deny-list inverse of isDefinitivelyTotp", () => {
  assert(!Logic.requiresConfirmation("TOTP"));
  assert(Logic.requiresConfirmation("HOTP"));
});

test("requiresConfirmation is TRUE for an unrecognized/empty/missing type -- the actual bug", () => {
  // otpclient-cli has only ever been observed to emit "TOTP"/"HOTP", but an
  // allow-list gated on isHotp() would let any THIRD value slip through
  // unconfirmed straight into a --show call that might mutate a counter.
  assert(Logic.requiresConfirmation(""));
  assert(Logic.requiresConfirmation(undefined));
  assert(Logic.requiresConfirmation(null));
  assert(Logic.requiresConfirmation("something-else"));
});

// ---- revealStatusText (adversarial review #2, #5) ------------------------

test("revealStatusText renders a real CLI expiry as '<n>s remaining'", () => {
  assertEqual(Logic.revealStatusText("TOTP", "copied", 18, false), "TOTP code copied · 18s remaining");
});

test("revealStatusText renders the fabricated HOTP window as an auto-clear, never as an expiry", () => {
  const text = Logic.revealStatusText("HOTP", "copied", 30, true);
  assertEqual(text, "HOTP code copied · auto-clears in 30s");
  assert(!/remaining/.test(text), "must not use expiry wording for a fabricated countdown");
});

test("revealStatusText never claims success when the copy failed", () => {
  const text = Logic.revealStatusText("TOTP", "failed", 18, false);
  assert(/FAILED/.test(text), "must surface the failure, not report success");
  assert(!/code copied/i.test(text), "must not still say the code was copied");
});

test("revealStatusText distinguishes a still-in-flight copy from a completed one", () => {
  assert(!/copied/i.test(Logic.revealStatusText("TOTP", "copying", 18, false)));
});

test("revealStatusText tolerates a negative/garbage secondsRemaining without going negative", () => {
  assert(/^TOTP code copied · 0s remaining$/.test(Logic.revealStatusText("TOTP", "copied", -5, false)));
});

// ---- confirmPromptText ----------------------------------------------------

test("confirmPromptText names the HOTP counter consequence only for an actual HOTP type", () => {
  assert(/HOTP counter/.test(Logic.confirmPromptText("HOTP")));
});

test("confirmPromptText does not claim an HOTP-specific consequence for an unrecognized type", () => {
  assert(!/HOTP/.test(Logic.confirmPromptText("")));
  assert(!/HOTP/.test(Logic.confirmPromptText(undefined)));
});

// ---- degradedStateMessage (issue #6) --------------------------------------
// Every typed state Backend.qml/Cli.js can report (see their own docstrings)
// must render its OWN distinct, actionable message -- one that names the
// fix, not the symptom. Backend/Cli.js's own text (the `fallbackMessage`
// argument) must never leak through for a state this function recognizes --
// only for the unrecognized `default` case -- so a message here can never
// echo something Backend/Cli.js read back from otpclient-cli.

const ALL_KNOWN_STATES = [
  "binary-missing", "would-prompt", "bad-password", "db-missing",
  "malformed", "crashed", "instance-conflict", "busy", "empty"
];

test("degradedStateMessage renders a non-empty, distinct message for every known state", () => {
  const seen = new Set();
  for (const state of ALL_KNOWN_STATES) {
    const msg = Logic.degradedStateMessage(state, "list", "raw backend text");
    assert(typeof msg === "string" && msg.length > 0, "message for " + state + " must be non-empty");
    assert(!seen.has(msg), "message for " + state + " must be distinct from every other state's -- got a duplicate: " + msg);
    seen.add(msg);
  }
});

test("degradedStateMessage: binary-missing names the AUR-only fix, not just the symptom", () => {
  const msg = Logic.degradedStateMessage("binary-missing", "list", "otpclient-cli not found (checked: ...)");
  assert(/AUR/i.test(msg), "must mention otpclient is AUR-only");
  assert(/yay -S otpclient/.test(msg), "must give the actual install command");
});

test("degradedStateMessage: would-prompt names Secret Service, not just 'timed out'", () => {
  const msg = Logic.degradedStateMessage("would-prompt", "list", "did not respond within 4000ms and was killed");
  assert(/Secret Service/.test(msg), "must name Secret Service as the thing to enable");
});

test("degradedStateMessage: bad-password points at the OTPClient GUI re-unlock fix", () => {
  const msg = Logic.degradedStateMessage("bad-password", "show", "Incorrect database password.");
  assert(/OTPClient GUI/.test(msg), "must point at the GUI as the fix");
});

test("degradedStateMessage: db-missing points at the GUI's database setup and the config path", () => {
  const msg = Logic.degradedStateMessage("db-missing", "list", "OTPClient database not found.");
  assert(/OTPClient GUI/.test(msg));
  assert(/otpclient\.cfg/.test(msg));
});

test("degradedStateMessage: malformed is reported plainly, offers no repair", () => {
  const msg = Logic.degradedStateMessage("malformed", "list", "Could not parse otpclient-cli output.");
  assert(/no automatic repair/i.test(msg));
});

test("degradedStateMessage: crashed is distinguished from a config problem", () => {
  const msg = Logic.degradedStateMessage("crashed", "list", "otpclient-cli exited abnormally (signal death, exitCode=11)");
  assert(/crashed/i.test(msg));
  assert(!/Secret Service/.test(msg), "must not be confused with would-prompt's fix");
});

test("degradedStateMessage: instance-conflict names the OTPClient GUI as the likely, actionable cause", () => {
  const msg = Logic.degradedStateMessage("instance-conflict", "list", "raw stderr fragment");
  assert(/OTPClient GUI/.test(msg), "must call out the GUI being open -- the most actionable cause");
  assert(/close/i.test(msg), "must say what to do about it");
});

test("degradedStateMessage: empty is context-sensitive -- a list-time empty differs from a show-time one", () => {
  const listMsg = Logic.degradedStateMessage("empty", "list", "No entries in the database.");
  const showMsg = Logic.degradedStateMessage("empty", "show", "No matching entry for that issuer/account.");
  assert(listMsg !== showMsg, "list-empty and show-empty must not read identically");
  assert(!/error/i.test(listMsg), "a list-time empty database is a neutral state, not an error");
});

test("degradedStateMessage: an unrecognized state falls back to the given message, not a blank string", () => {
  assertEqual(Logic.degradedStateMessage("some-future-state", "list", "whatever Backend said"), "whatever Backend said");
});

test("degradedStateMessage: an unrecognized state with no fallback at all still returns something usable", () => {
  const msg = Logic.degradedStateMessage("some-future-state", "list", "");
  assert(typeof msg === "string" && msg.length > 0);
});

test("degradedStateMessage: NEVER echoes the raw fallback text for a state it recognizes -- issue #6's no-secret-echo requirement", () => {
  // A real password/code/secret can only ever reach this function inside
  // Backend/Cli.js's own `message` argument (fallbackMessage here) -- never
  // as the `state` string itself, which is always one of the fixed,
  // typed literals Backend.qml documents. Proving every KNOWN state's
  // branch ignores fallbackMessage entirely proves structurally that this
  // function can never launder something sensitive through, regardless of
  // what Backend/Cli.js's own wording does in the future.
  const canary = "SECRET-PASSWORD-OR-CODE-MUST-NOT-APPEAR";
  for (const state of ALL_KNOWN_STATES) {
    const msg = Logic.degradedStateMessage(state, "list", canary);
    assert(msg.indexOf(canary) === -1, "state '" + state + "' must not echo the raw backend message");
  }
  for (const state of ALL_KNOWN_STATES) {
    const msg = Logic.degradedStateMessage(state, "show", canary);
    assert(msg.indexOf(canary) === -1, "state '" + state + "' (show context) must not echo the raw backend message");
  }
});

// ---- entryKey -----------------------------------------------------------

test("entryKey is stable for the same issuer/account", () => {
  assertEqual(Logic.entryKey(totp), Logic.entryKey({ issuer: "GitHub", account: "pavan@smaply.com" }));
});

test("entryKey distinguishes different rows", () => {
  assert(Logic.entryKey(totp) !== Logic.entryKey(totp2));
  assert(Logic.entryKey(totp) !== Logic.entryKey(hotp));
});

test("entryKey cannot collide across a shifted issuer/account boundary", () => {
  // A naive "issuer + separator + account" string key collides here if the
  // separator can appear inside either field. JSON-encoding the pair must
  // not.
  const a = Logic.entryKey({ issuer: "A B", account: "C" });
  const b = Logic.entryKey({ issuer: "A", account: "B C" });
  assert(a !== b, "entryKey must not collide when a field itself contains the separator");
});

test("entryKey never throws on a null/undefined entry", () => {
  assertEqual(Logic.entryKey(null), "");
  assertEqual(Logic.entryKey(undefined), "");
});

// ---- filterEntries / matchesFilter ---------------------------------------

const inventory = [totp, totp2, hotp];

test("filterEntries with an empty filter returns every entry", () => {
  assertEqual(Logic.filterEntries(inventory, ""), inventory);
});

test("filterEntries with a whitespace-only filter also returns everything", () => {
  assertEqual(Logic.filterEntries(inventory, "   "), inventory);
});

test("filterEntries matches on issuer, case-insensitively", () => {
  assertEqual(Logic.filterEntries(inventory, "github"), [totp]);
});

test("filterEntries matches on account, case-insensitively", () => {
  assertEqual(Logic.filterEntries(inventory, "ALICE@EXAMPLE"), [totp2]);
});

test("filterEntries with no match returns an empty array, not null/undefined", () => {
  assertEqual(Logic.filterEntries(inventory, "nobody-has-this"), []);
});

test("filterEntries tolerates a non-array entries value", () => {
  assertEqual(Logic.filterEntries(null, "x"), []);
  assertEqual(Logic.filterEntries(undefined, ""), []);
});

test("filterEntries never mutates or returns the same array reference (fresh copy every time)", () => {
  const result = Logic.filterEntries(inventory, "");
  assert(result !== inventory, "must be a copy, not the same reference");
  result.push({ issuer: "injected" });
  assertEqual(inventory.length, 3, "the original inventory array must be untouched");
});

// ---- clampIndex / entryAt ------------------------------------------------

test("clampIndex on an empty list is always -1", () => {
  assertEqual(Logic.clampIndex(0, 0), -1);
  assertEqual(Logic.clampIndex(5, 0), -1);
  assertEqual(Logic.clampIndex(-1, 0), -1);
});

test("clampIndex clamps a negative index up to 0", () => {
  assertEqual(Logic.clampIndex(-1, 3), 0);
  assertEqual(Logic.clampIndex(-100, 3), 0);
});

test("clampIndex clamps an over-range index down to the last valid one", () => {
  assertEqual(Logic.clampIndex(3, 3), 2);
  assertEqual(Logic.clampIndex(999, 3), 2);
});

test("clampIndex never wraps -- arrow navigation stops at the ends", () => {
  assertEqual(Logic.clampIndex(-1, 5), 0);
  assertEqual(Logic.clampIndex(5, 5), 4);
});

test("entryAt returns the entry at a valid index", () => {
  assertEqual(Logic.entryAt(inventory, 1), totp2);
});

test("entryAt returns null for an out-of-range or negative index", () => {
  assertEqual(Logic.entryAt(inventory, -1), null);
  assertEqual(Logic.entryAt(inventory, 99), null);
});

test("entryAt returns null for a non-array list, never throws", () => {
  assertEqual(Logic.entryAt(null, 0), null);
});

// ---- clipboardStillOurs ---------------------------------------------------

test("clipboardStillOurs is true only when the clipboard still holds exactly our code", () => {
  assert(Logic.clipboardStillOurs("482913", "482913"));
});

test("clipboardStillOurs is false once the user has copied something else", () => {
  assert(!Logic.clipboardStillOurs("something-else", "482913"));
});

test("clipboardStillOurs is false for an empty/missing expected code (nothing of ours to protect)", () => {
  assert(!Logic.clipboardStillOurs("482913", ""));
  assert(!Logic.clipboardStillOurs("482913", undefined));
});

test("clipboardStillOurs is false when the clipboard is empty", () => {
  assert(!Logic.clipboardStillOurs("", "482913"));
});

// ---- report ---------------------------------------------------------

console.log(pass + " passed, " + fail + " failed");
if (fail > 0) {
  failures.forEach((f) => console.error("FAIL: " + f));
  process.exit(1);
}
