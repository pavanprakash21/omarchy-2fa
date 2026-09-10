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
