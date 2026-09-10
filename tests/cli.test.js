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

// ---- database override (issue #17): -d/--database, threaded from
// PanelState's `database` setting (issue #8) -- must stay byte-identical
// to today when unset, and must appear as its OWN discrete argv element,
// never interpolated, when set. See tests/backend.qmltest.qml's
// "database wiring" scenarios for the real-Process-level half of this
// same guarantee (a fixture that actually answers differently depending
// on whether the flag showed up).

test("listArgv is byte-identical to today when database is omitted", () => {
  assertEqual(Cli.listArgv(), ["--list", "--output=json"]);
});

test("listArgv is byte-identical to today when database is an empty string", () => {
  assertEqual(Cli.listArgv(""), ["--list", "--output=json"]);
});

test("listArgv prepends --database as its own discrete element when set to a path", () => {
  const argv = Cli.listArgv("/home/user/.local/share/otpclient/test.db");
  assertEqual(argv, ["--database", "/home/user/.local/share/otpclient/test.db", "--list", "--output=json"]);
});

test("listArgv accepts a bare database NAME (as printed by --list-databases), same flag", () => {
  // -d/--database documents accepting EITHER a path or a name from
  // --list-databases -- Cli.js must not try to tell them apart.
  const argv = Cli.listArgv("work-database");
  assertEqual(argv, ["--database", "work-database", "--list", "--output=json"]);
});

test("showArgv is byte-identical to today when database is omitted", () => {
  const argv = Cli.showArgv("GitHub", "pavan@smaply.com");
  assertEqual(argv, ["--show", "-a", "pavan@smaply.com", "-i", "GitHub", "-m", "--output=json"]);
});

test("showArgv is byte-identical to today when database is an empty string", () => {
  const argv = Cli.showArgv("GitHub", "pavan@smaply.com", "");
  assertEqual(argv, ["--show", "-a", "pavan@smaply.com", "-i", "GitHub", "-m", "--output=json"]);
});

test("showArgv prepends --database as its own discrete element when set to a path", () => {
  const argv = Cli.showArgv("GitHub", "pavan@smaply.com", "/fixture/expected.db");
  assertEqual(argv, ["--database", "/fixture/expected.db", "--show", "-a", "pavan@smaply.com", "-i", "GitHub", "-m", "--output=json"]);
});

test("showArgv accepts a bare database NAME too, same flag, same discrete-element shape", () => {
  const argv = Cli.showArgv("GitHub", "pavan@smaply.com", "work-database");
  assertEqual(argv, ["--database", "work-database", "--show", "-a", "pavan@smaply.com", "-i", "GitHub", "-m", "--output=json"]);
});

test("database value never gets interpolated into another argv element, even with shell metacharacters", () => {
  const evil = "$(rm -rf ~); `touch pwned`; & | > <";
  const argv = Cli.listArgv(evil);
  assert(argv.indexOf(evil) !== -1, "the database value must appear verbatim as its own argv element");
  assertEqual(argv, ["--database", evil, "--list", "--output=json"]);
});

test("listInventory()/requestCode()/requestHotpCode() share one argv builder path -- same database value, same flag placement", () => {
  // Not a Backend.qml integration test (that's tests/backend.qmltest.qml) --
  // just confirming, at the pure-argv level, that both builders treat an
  // identical `database` value identically, so Backend.qml passing its one
  // `database` property to both can't produce two different shapes.
  const db = "/fixture/expected.db";
  const listArgv = Cli.listArgv(db);
  const showArgv = Cli.showArgv("Bank", "acct1", db);
  assertEqual(listArgv.slice(0, 2), ["--database", db]);
  assertEqual(showArgv.slice(0, 2), ["--database", db]);
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

// ---- PATH-lookup fallback (adversarial review item #6) -------------------

test("isPathLookupCandidate distinguishes absolute paths from bare names", () => {
  assert(!Cli.isPathLookupCandidate("/usr/bin/otpclient-cli"));
  assert(Cli.isPathLookupCandidate("otpclient-cli"));
  assert(!Cli.isPathLookupCandidate(""));
});

test("wrapViaPath resolves through /usr/bin/env with the exact candidate name, still under -s KILL", () => {
  const cmd = Cli.wrapViaPath("otpclient-cli", ["--list", "--output=json"], 4000);
  assertEqual(cmd, ["/usr/bin/timeout", "-s", "KILL", "4", "/usr/bin/env", "otpclient-cli", "--list", "--output=json"]);
});

test("wrapTimeout is the exact shared primitive wrap()/wrapViaPath() are built from", () => {
  assertEqual(Cli.wrapTimeout(["/bin/foo", "-x"], 4000), ["/usr/bin/timeout", "-s", "KILL", "4", "/bin/foo", "-x"]);
});

// ---- issue #21: Backend.qml's default binaryCandidates must not include a
// PATH-lookup fallback -- this project's own README documents exactly one
// supported install method (AUR, landing at /usr/bin), so a bare-name
// default candidate resolved via PATH (see wrapViaPath()/
// isPathLookupCandidate() above) was pure attack surface under this
// project's own threat model (issue #9: "a compromised or substituted
// otpclient-cli ... binary on a poisoned PATH") with no corresponding,
// documented use case. The mechanism itself is intentionally NOT deleted
// (still real, tested infrastructure for an explicit, future opt-in --
// see tests/backend.qmltest.qml's "path-lookup" scenario, which overrides
// binaryCandidates directly rather than relying on this default) -- only
// the default's silent inclusion of it is what issue #21 requires gone.
// A plain source-text check, not a QML-runtime one: Backend.qml's
// `property var` default is right there in the file as a JS array literal.
test("Backend.qml's default binaryCandidates has no bare (PATH-lookup) candidate", () => {
  const backendPath = path.join(__dirname, "..", "Backend.qml");
  const backendSrc = fs.readFileSync(backendPath, "utf8");
  const m = backendSrc.match(/property var binaryCandidates:\s*(\[[^\]]*\])/);
  assert(m, "could not find Backend.qml's binaryCandidates property declaration");
  const candidates = JSON.parse(m[1].replace(/'/g, '"'));
  assert(candidates.length > 0, "binaryCandidates default must not be empty");
  candidates.forEach((c) => {
    assert(!Cli.isPathLookupCandidate(c),
      "Backend.qml's default binaryCandidates still contains a bare PATH-lookup candidate: " + c);
  });
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

// ---- instance-conflict (adversarial review item #3: corrected concurrency
// story -- concurrent invocations don't corrupt the database, but they do
// race for a GApplication D-Bus name, and the loser prints this) ----------

test("isInstanceConflictStderr matches the confirmed GDBus/org.gtk.Actions signature", () => {
  const err = 'Failed to register: GDBus.Error:org.freedesktop.DBus.Error.UnknownMethod: No such interface "org.gtk.Actions" on object at path /com/github/paolostivanin/OTPClient';
  assert(Cli.isInstanceConflictStderr(err));
});

test("isInstanceConflictStderr does not false-positive on an unrelated stderr line", () => {
  assert(!Cli.isInstanceConflictStderr("Incorrect password."));
  assert(!Cli.isInstanceConflictStderr(""));
});

test("classify() routes the D-Bus collision to instance-conflict, not malformed", () => {
  const err = 'Failed to register: GDBus.Error:org.freedesktop.DBus.Error.UnknownMethod: No such interface "org.gtk.Actions" on object at path /com/github/paolostivanin/OTPClient';
  const r = Cli.classify(1, "", err, "list");
  assertEqual(r.state, "instance-conflict");
});

test("unparseable stdout with no recognized stderr -> malformed, never throws", () => {
  const r = Cli.classify(0, "not actually json {", "", "list");
  assertEqual(r.state, "malformed");
});

test("classify never throws on totally empty input", () => {
  const r = Cli.classify(1, "", "", "show");
  assertEqual(r.state, "malformed");
});

// ---- issue #22: no untrusted (issuer/account) content reaches a log sink --
// requestCode()'s HOTP-misuse console.warn() used to interpolate issuer/
// account -- untrusted, otpauth://-import-derived strings -- straight into
// a log line. A plain source-text check: confirms the ONE console.* call
// in this plugin's otpclient-facing surface (verified separately, by
// `grep -rn "console\." --include=*.qml --include=*.js .`, to be the only
// one outside tests/) does not reference either variable.
test("Backend.qml's HOTP-refusal console.warn does not interpolate issuer/account", () => {
  const backendPath = path.join(__dirname, "..", "Backend.qml");
  const backendSrc = fs.readFileSync(backendPath, "utf8");
  const m = backendSrc.match(/console\.warn\(([^\n]*)\)/);
  assert(m, "could not find the console.warn(...) call in Backend.qml");
  const warnArgs = m[1];
  assert(!/\bissuer\b/.test(warnArgs), "console.warn still references `issuer` -- untrusted content reaching a log sink (issue #22)");
  assert(!/\baccount\b/.test(warnArgs), "console.warn still references `account` -- untrusted content reaching a log sink (issue #22)");
});

// ---- report ---------------------------------------------------------

console.log(pass + " passed, " + fail + " failed");
if (fail > 0) {
  failures.forEach((f) => console.error("FAIL: " + f));
  process.exit(1);
}
