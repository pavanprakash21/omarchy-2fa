#!/usr/bin/env node
// Pure-logic tests for Cli.js: argv building, JSON parsing, and stderr/exit
// classification. Runs under plain `node`, no Quickshell/QML involved --
// see tests/backend.qmltest.qml for the process/timeout-wiring tests that
// do need the real Quickshell runtime.
//
// Cli.js starts with `.pragma library`, a QML-JS-engine directive that is
// not valid standalone JavaScript, so it's stripped before the file is
// evaluated here. Everything after that line is plain ES5-ish JS.
//
// These cases were written/updated against a real otpclient-cli 5.1.6 and
// a scratch database (see the PR description); the stderr strings, JSON
// shapes and stdout-pollution case below are the actually-observed ones,
// not just what upstream source/docs implied.
"use strict";

const fs = require("fs");
const path = require("path");
const vm = require("vm");

const cliPath = path.join(__dirname, "..", "Cli.js");
const src = fs.readFileSync(cliPath, "utf8").replace(/^\s*\.pragma\s+library\s*\r?\n/, "");

const sandbox = {};
vm.createContext(sandbox);
new vm.Script(src, { filename: "Cli.js" }).runInContext(sandbox);
const Cli = sandbox;

let pass = 0;
let fail = 0;
const failures = [];

function deepEqual(a, b) {
  if (a === b) return true;
  if (typeof a !== typeof b) return false;
  if (a === null || b === null) return false;
  if (typeof a !== "object") return false;
  const ak = Object.keys(a).sort();
  const bk = Object.keys(b).sort();
  if (ak.length !== bk.length || ak.join(",") !== bk.join(",")) return false;
  return ak.every((k) => deepEqual(a[k], b[k]));
}

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
  const ok = deepEqual(actual, expected);
  if (!ok) {
    throw new Error(
      (msg ? msg + " -- " : "") +
        "expected " + JSON.stringify(expected) + ", got " + JSON.stringify(actual)
    );
  }
}

// ---- argv building: must never contain a shell string, never --export ----

test("listArgv is exactly --list --output=json", () => {
  assertEqual(Cli.listArgv(), ["--list", "--output=json"]);
});

test("showArgv always includes -m/--match-exact and -a before -i", () => {
  const argv = Cli.showArgv("GitHub", "pavan@smaply.com");
  assert(argv.indexOf("-m") !== -1, "must include -m");
  assertEqual(argv, ["--show", "-a", "pavan@smaply.com", "-i", "GitHub", "-m", "--output=json"]);
});

test("showArgv omits -i entirely when issuer is empty (account is the mandatory field)", () => {
  const argv = Cli.showArgv("", "pavan@smaply.com");
  assertEqual(argv, ["--show", "-a", "pavan@smaply.com", "-m", "--output=json"]);
});

test("showArgv keeps shell metacharacters as inert argv elements", () => {
  // The whole point of an argv array: this string is never seen by a shell.
  const evil = "$(rm -rf ~); `touch pwned`; issuer; & | > <";
  const argv = Cli.showArgv(evil, "acct");
  assert(argv.indexOf(evil) !== -1, "issuer must appear verbatim as one argv element");
  assertEqual(argv.length, 7, "argv must still be exactly 7 elements, not shell-expanded");
});

test("no function in Cli.js can build an --export invocation", () => {
  const src2 = fs.readFileSync(cliPath, "utf8");
  assert(!/--export/.test(src2), "the string --export must not appear anywhere in Cli.js");
  assert(typeof Cli.exportArgv === "undefined", "there must be no exportArgv function");
});

test("wrap() always uses -s KILL and an absolute /usr/bin/timeout", () => {
  const cmd = Cli.wrap("/usr/bin/otpclient-cli", ["--list", "--output=json"], 4000);
  assertEqual(cmd, ["/usr/bin/timeout", "-s", "KILL", "4", "/usr/bin/otpclient-cli", "--list", "--output=json"]);
});

test("timeoutSeconds rounds up and floors at 1", () => {
  assertEqual(Cli.timeoutSeconds(1), 1);
  assertEqual(Cli.timeoutSeconds(500), 1);
  assertEqual(Cli.timeoutSeconds(4000), 4);
  assertEqual(Cli.timeoutSeconds(4001), 5);
});

// ---- exit-code classification ------------------------------------------
// NOTE: exit codes turned out NOT to reliably discriminate outcomes against
// the real binary (wrong password, missing db, and a bad password-file
// mode were all observed to exit 255) -- stderr text and JSON shape carry
// the real signal, exercised further down. The codes below are only about
// the `timeout` wrapper's own documented contract (confirmed for the
// not-found/not-executable case; the timeout case itself is additionally,
// and primarily, detected in Backend.qml via QProcess exitStatus -- see
// its docstring -- since a real KILL was observed to arrive as
// exitStatus=CrashExit with exitCode=9, not a clean 137).

test("127/126 are missing-binary exits", () => {
  assert(Cli.isMissingExit(127));
  assert(Cli.isMissingExit(126));
  assert(!Cli.isMissingExit(0));
  assert(!Cli.isMissingExit(1));
});

test("124/137 are the documented (secondary/defensive) timeout exits", () => {
  assert(Cli.isTimeoutExit(124));
  assert(Cli.isTimeoutExit(137));
  assert(!Cli.isTimeoutExit(125));
});

test("125 is a wrapper-failure exit, classified as malformed", () => {
  assert(Cli.isWrapperFailedExit(125));
  const result = Cli.classify(125, "", "", "list");
  assertEqual(result.state, "malformed");
});

// ---- extractJson: stdout pollution (confirmed on a mutating HOTP call) --

test("extractJson skips diagnostic lines before the JSON payload", () => {
  const polluted = "Backup copy successfully created.\nBackup copy successfully created.\n" +
    '[\n  {"type": "HOTP", "account": "acct1", "issuer": "Bank", "current": "453172", "counter": 7}\n]\n';
  const data = Cli.extractJson(polluted);
  assert(Array.isArray(data));
  assertEqual(data[0].counter, 7);
});

test("extractJson returns null for unbalanced/truncated JSON rather than throwing", () => {
  assertEqual(Cli.extractJson("not actually json {"), null);
});

test("extractJson returns null when there is no JSON at all", () => {
  assertEqual(Cli.extractJson("Empty password not allowed\n"), null);
});

// ---- --list parsing --------------------------------------------------

test("parseList extracts issuer/account/group/type, never a code", () => {
  const json = JSON.stringify([
    { issuer: "GitHub", account: "pavan@smaply.com", group: "Work", type: "TOTP" },
    { issuer: "AWS", account: "root", group: "", type: "TOTP" },
  ]);
  const r = Cli.parseList(json);
  assert(r.ok);
  assertEqual(r.entries.length, 2);
  assertEqual(r.entries[0], { issuer: "GitHub", account: "pavan@smaply.com", group: "Work", type: "TOTP" });
  assert(!("current" in r.entries[0]), "list entries must never carry a code field");
});

test("classify(list) empty array -> empty state, not ok, not an error", () => {
  const r = Cli.classify(0, "[]", "", "list");
  assertEqual(r.state, "empty");
  assertEqual(r.entries, []);
});

test("classify(list) non-empty array -> ok", () => {
  const r = Cli.classify(0, '[{"issuer":"GitHub","account":"a"}]', "", "list");
  assertEqual(r.state, "ok");
  assertEqual(r.entries.length, 1);
});

test("parseList tolerates a garbage/missing field defensively", () => {
  const r = Cli.parseList(JSON.stringify([{ issuer: 42, account: null }, {}]));
  assert(r.ok);
  // 42/null coerce to "not usable", and the empty object has neither
  // issuer nor account -- both dropped.
  assertEqual(r.entries, []);
});

// ---- --show parsing ----------------------------------------------------

test("parseShow extracts the fields confirmed against the real --show payload", () => {
  // otpclient-cli was observed to always array-wrap --show's result.
  const json = JSON.stringify([{
    type: "TOTP",
    account: "pavan@smaply.com",
    issuer: "GitHub",
    current: "482913",
    validity_seconds: 7,
  }]);
  const r = Cli.parseShow(json);
  assert(r.ok);
  assertEqual(r.entry.current, "482913");
  assertEqual(r.entry.secondsRemaining, 7);
});

test("parseShow tolerates a bare (non-array-wrapped) object defensively", () => {
  const r = Cli.parseShow(JSON.stringify({ issuer: "x", account: "y", current: "000000" }));
  assert(r.ok);
  assertEqual(r.entry.current, "000000");
});

test("parseShow reports empty (not a parse failure) for the confirmed no-match shape", () => {
  // Real observed no-such-account behavior: exit 255, empty stderr, stdout "[]".
  const r = Cli.parseShow("[]");
  assert(!r.ok);
  assert(r.empty);
});

test("parseShow rejects an object with no current code as a real parse failure", () => {
  const r = Cli.parseShow(JSON.stringify({ issuer: "x", account: "y" }));
  assert(!r.ok);
  assert(!r.empty);
});

test("classify(show) with a valid payload -> ok", () => {
  const r = Cli.classify(0, JSON.stringify([{ issuer: "x", account: "y", current: "123456" }]), "", "show");
  assertEqual(r.state, "ok");
  assertEqual(r.entry.current, "123456");
});

test("classify(show) on stdout pollution + real JSON -> ok, never leaks the diagnostic lines into the message", () => {
  const polluted = "Backup copy successfully created.\nBackup copy successfully created.\n" +
    '[{"type": "HOTP", "account": "acct1", "issuer": "Bank", "current": "453172", "counter": 8}]\n';
  const r = Cli.classify(0, polluted, "", "show");
  assertEqual(r.state, "ok");
  assertEqual(r.entry.counter, 8);
});

test("classify(show) on the confirmed no-such-account shape -> empty, not malformed", () => {
  const r = Cli.classify(255, "[]\n", "", "show");
  assertEqual(r.state, "empty");
});

// ---- stderr-driven classification (verbatim strings confirmed against the real binary) --

test("'Incorrect password.' -> bad-password", () => {
  const r = Cli.classify(255, "", "Incorrect password.\n", "show");
  assertEqual(r.state, "bad-password");
});

test("'Error while loading the database: Missing database file' -> db-missing", () => {
  const r = Cli.classify(255, "", "Error while loading the database: Missing database file\n", "list");
  assertEqual(r.state, "db-missing");
});

test("legacy '...does not exist.' phrasing also maps to db-missing (defensive, unconfirmed on this version)", () => {
  const r = Cli.classify(1, "", "Database file/location (/x/otpclient.enc) does not exist.\n", "list");
  assertEqual(r.state, "db-missing");
});

test("'Empty password not allowed' -> would-prompt (defensive secondary path; see Backend.qml for the primary one)", () => {
  const r = Cli.classify(255, "", "Empty password not allowed\nNo password provided, exiting.\n", "show");
  assertEqual(r.state, "would-prompt");
});

test("unparseable stdout with no recognized stderr -> malformed, never throws", () => {
  const r = Cli.classify(0, "not actually json {", "", "list");
  assertEqual(r.state, "malformed");
});

test("classify never throws on totally empty input", () => {
  const r = Cli.classify(1, "", "", "show");
  assertEqual(r.state, "malformed");
});

// ---- report ---------------------------------------------------------

console.log(pass + " passed, " + fail + " failed");
if (fail > 0) {
  failures.forEach((f) => console.error("FAIL: " + f));
  process.exit(1);
}
