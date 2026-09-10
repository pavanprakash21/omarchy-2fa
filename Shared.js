.pragma library

// Shared, process-wide gate for otpclient-cli invocations.
//
// Backend.qml is a plain QML Item, not a singleton type -- the bar renders
// one instance per monitor, so a per-instance in-flight flag only ever
// prevented ONE Backend instance from overlapping with itself. It did
// nothing for a second monitor's Backend also calling into otpclient-cli
// (see Cli.js's CONCURRENCY note for why overlapping invocations are worth
// avoiding even though they don't corrupt anything: it's about not
// routinely wasting an invocation to a GApplication D-Bus race, not data
// safety).
//
// `.pragma library` gives every QML file that imports this module the same
// JS object for the lifetime of the running quickshell process -- this is
// what actually closes that gap, without registering a qmldir/module
// (which would mean reaching into files outside this plugin's process
// layer, e.g. to declare `pragma Singleton` through a proper QML module).
// It only reaches as far as this one quickshell process: it cannot and
// does not attempt to coordinate with a wholly separate process (a second
// quickshell instance, or the OTPClient GUI) -- that collision is instead
// detected from its own distinctive stderr signature and surfaced as the
// "instance-conflict" typed state (see Cli.js's isInstanceConflictStderr).
var gate = {
  inFlight: false,
  activeKind: ""
}

function tryAcquire(kind) {
  if (gate.inFlight) return false
  gate.inFlight = true
  gate.activeKind = kind
  return true
}

function release() {
  gate.inFlight = false
  gate.activeKind = ""
}

function isInFlight() {
  return gate.inFlight
}

function activeKind() {
  return gate.activeKind
}
