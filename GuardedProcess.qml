import QtQuick
import Quickshell.Io
import "Cli.js" as Cli

// GuardedProcess.qml -- the only way PanelState.qml is allowed to spawn a
// subprocess (issue #20).
//
// Backend.qml's otpclient-cli invocations have always been wrapped in an
// OS-level `timeout -s KILL <n>` *and* backed by a QML watchdog Timer
// (listWatchdog/showWatchdog) -- see its own module docstring. PanelState.
// qml's clipboard machinery (copyProc/pasteProc/clearCopyProc, added across
// issues #5 and #8) never got that discipline, and issue #20 is the FOURTH
// time this exact bug class -- "a decrypted code is retained longer than
// intended" -- has turned up at a newly added call site in this plugin:
//   1. StdioCollector.text retained codes for the whole session (backend).
//   2. A revealed code survived a selection change (UI) -- recurring at
//      THREE separate call sites before being routed through
//      PanelState.qml's own _syncRevealToSelection() choke point.
//   3. pasteProc (this issue): no timeout, no watchdog, no forced cleanup
//      -- a hung `wl-paste` held a plaintext code in `pasteProc._expected`
//      indefinitely, with the child never reaped either.
//
// Patching pasteProc alone would just be waiting for a fifth call site to
// repeat the same mistake. Instead, every subprocess PanelState.qml spawns
// -- copyProc, pasteProc, clearCopyProc, and whatever comes after them --
// is now an instance of THIS component instead of a raw Quickshell.Io.
// Process, so a future call site gets the following for free, by
// construction, rather than having to remember to bolt it on itself:
//
//   1. TIMEOUT: `argv` is always wrapped in `timeout -s KILL <n>` before
//      being handed to the real Process underneath -- Cli.wrapTimeout(),
//      the exact same helper Cli.js's own wrap()/wrapViaPath() use for
//      every otpclient-cli invocation, factored out specifically so this
//      isn't a second, independently-maintained copy of that logic (see
//      Cli.js's own doc comment on wrapTimeout()).
//   2. WATCHDOG: a QML Timer backs the OS-level timeout up, mirroring
//      Backend.qml's listWatchdog/showWatchdog -- belt and suspenders, in
//      case `timeout` itself never reports back.
//   3. SECRET CLEANUP ON THE ABNORMAL PATH: `secret` is whatever this one
//      invocation is holding on the caller's behalf (a plaintext code
//      staged for a stdin write, or one being compared against a
//      clipboard readback). The watchdog firing, or a caller explicitly
//      calling stop(), ALWAYS force-stops the process and blanks `secret`
//      unconditionally -- there is no path through a hang, or an explicit
//      stop, that leaves a stale plaintext value sitting here. (The
//      NORMAL exit path deliberately does NOT auto-clear `secret` itself
//      -- see guardedExited's own doc comment for why that's the caller's
//      job, same as it always was.)
//
// A caller sets `argv` (the real command, WITHOUT the timeout wrapper --
// this component adds that itself) and `timeoutMs`, and stages whatever it
// needs into `secret`. `running`/`stdinEnabled`/`stdout`/`stderr`/`write()`
// are the same names the underlying Process already exposes, forwarded
// straight through -- a caller wires this up exactly like a plain Process.
//
// Structured as an Item wrapping an internal Process (the same shape
// Backend.qml itself uses for listProc/listWatchdog and showProc/
// showWatchdog), rather than Process itself as the root type, because
// Quickshell's Process has no default property to hold the watchdog Timer
// below as a child -- confirmed empirically (`quickshell -p` refuses to
// load a Process with a bare child item: "Cannot assign to non-existent
// default property").
Item {
  id: root

  // The real command this invocation runs, e.g. [wlCopyPath] --
  // deliberately never including the timeout wrapper itself (`command`
  // below, on the internal Process, is what adds that).
  property var argv: []

  // Hard wall-clock ceiling for this ONE invocation, in milliseconds --
  // same role as Backend.qml's own timeoutMs, just scoped per-process here
  // since PanelState.qml's three clipboard processes don't share a single
  // otpclient-cli-style deadline. See PanelState.qml's clipboardTimeoutMs.
  property int timeoutMs: 4000

  // Whatever secret this invocation must not outlive -- e.g. the plaintext
  // code copyProc is about to write to wl-copy's stdin, or the one
  // pasteProc is comparing a clipboard readback against. Never read by
  // this component itself; it only ever blanks it (see stop()/the
  // watchdog below).
  property string secret: ""

  // Straight pass-through to the internal Process -- a caller uses these
  // exactly as it would on a plain Process.
  property alias running: proc.running
  property alias stdinEnabled: proc.stdinEnabled
  property alias stdout: proc.stdout
  property alias stderr: proc.stderr
  property alias processId: proc.processId

  function write(data) { proc.write(data) }

  // Relayed straight from the internal Process -- a caller writes
  // `onStarted:` exactly as it would on a plain Process.
  signal started()

  // Fires exactly where the underlying Process's own `exited` would have
  // -- kept as a distinctly-named signal so a caller's handler never has
  // to guess whether this was a normal exit or the watchdog's forced one
  // (guardedTimedOut below is that other case, and the two are mutually
  // exclusive). Deliberately does NOT touch `secret` itself: unlike the
  // watchdog/stop() path, a normal exit is exactly the moment several
  // callers here still need to READ `secret` (pasteProc's onStreamFinished
  // compares it against the clipboard readback before clearing it itself,
  // the same read-then-clear pattern Backend.qml's own StdioCollector
  // handling already uses) -- auto-clearing it here first would race that
  // read. The caller remains responsible for clearing `secret` on this
  // path, exactly as it always was; this component only guarantees the
  // OTHER path -- a hang, or an explicit stop() -- can never skip it.
  signal guardedExited(int exitCode, int exitStatus)
  // Fires ONLY when the watchdog (not a real process exit) is what ended
  // this invocation -- mirrors Backend.qml's would-prompt watchdog path.
  // `secret` is already blanked by the time this fires.
  signal guardedTimedOut()

  // Force-stops the process (a no-op if it isn't running) and
  // unconditionally blanks `secret` -- synchronously, regardless of
  // whether anything was in flight at all. This is what PanelState.qml's
  // clearReveal() calls on every clipboard process it owns (issue #20's
  // second requirement): a reveal that has already been dropped --
  // countdown, panel close, or a selection change -- must not leave an
  // in-flight (or hung) clipboard process holding the code for even one
  // more moment, rather than waiting out its own timeout+watchdog window.
  function stop() {
    if (proc.running) proc.running = false
    root.secret = ""
  }

  Process {
    id: proc
    command: Cli.wrapTimeout(root.argv, root.timeoutMs)

    onStarted: root.started()
    onRunningChanged: {
      if (running) watchdog.restart()
      else watchdog.stop()
    }
    onExited: function (exitCode, exitStatus) {
      root.guardedExited(exitCode, exitStatus)
    }
  }

  // Backstop behind `timeout -s KILL`, exactly as Backend.qml's
  // listWatchdog/showWatchdog back up Cli.js's OS-level deadline: if the
  // wrapped `timeout` process itself never reports back at all, this still
  // guarantees the child is force-stopped and `secret` cannot outlive it,
  // rather than leaving a decrypted code staged here indefinitely (the
  // exact failure mode issue #20 found in pasteProc._expected, which had
  // neither this nor the OS-level timeout at all).
  Timer {
    id: watchdog
    interval: root.timeoutMs + 2000
    onTriggered: {
      if (proc.running) {
        root.stop()
        root.guardedTimedOut()
      }
    }
  }
}
