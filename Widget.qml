// SPDX-License-Identifier: GPL-3.0-or-later
import QtQuick
import Quickshell.Io
import qs.Commons
import qs.Ui

// Widget.qml -- the bar-side half of the 2FA plugin (issue #3): the icon,
// its layout in both bar orientations, and the panel's open/close
// lifecycle. Issues #4 (list/search/keyboard nav) and #5 (reveal/copy) live
// in PanelState.qml (state/logic, headlessly testable) and Popup.qml (the
// PopupWindow that paints it) -- this file only wires the two together and
// exposes the lifecycle contract the bar host and IPC route to.
BarWidget {
  id: root
  moduleName: "pavanprakash21.twofa"

  // WidgetButton (below) already sizes itself to bar.barSize on the cross
  // axis when `bar.vertical` (see qs.Ui/WidgetButton.qml's own
  // implicitWidth/implicitHeight: `vertical ? barSize : ...`), which is the
  // same outcome issue #3 asks for by pointing at
  // zeru.portwatch/Widget.qml:16-18's hand-rolled version of that formula --
  // portwatch hand-rolls it because it doesn't use WidgetButton at all.
  // Since this widget is a single icon glyph in a WidgetButton (preferred
  // over hand-rolling per qs.Ui), mirroring the built-in clock widget's
  // `implicitWidth: button.implicitWidth` is the equivalent, non-hand-rolled
  // path to the same requirement: Bar.qml forces a vertical slot's width to
  // bar.barSize regardless of implicitWidth, and WidgetButton's own vertical
  // branch already reports barSize as its implicitWidth in that case, so
  // there is nothing left to clip.
  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  // Not every theme tunes bar.foreground for a light bar.background --
  // same luminance fallback as zeru.portwatch/Widget.qml:22-26, applied to
  // the icon glyph via WidgetButton.foreground below.
  //
  // Issue #7 (dock hosting): when hosted in rosakodu.dock, `bar` is a
  // `dockBarContext` proxy (DockPanel.qml's own name for it), not the real
  // Bar -- and that proxy has no `background` property at all (it only
  // carries foreground/barForeground/urgent/muted/accent). The base class's
  // `bar ? x : fallback` idiom only guards a *missing bar*; it does not
  // guard a present-but-partial one, so `luminance(bar.background)` would
  // read `undefined.r` and throw inside this binding. Fall back to
  // `bar.barForeground` (which the dock proxy *does* define) rather than
  // guessing at a contrast we have no background to check.
  function luminance(c) { return 0.299 * c.r + 0.587 * c.g + 0.114 * c.b }
  readonly property color iconColor: bar
    ? (bar.background !== undefined
        ? (luminance(bar.background) > 0.6 ? "#1a1a1a" : bar.barForeground)
        : bar.barForeground)
    : Color.foreground

  // Dock hosting (issue #7): rosakodu.dock draws its own icon glyph for a
  // hosted widget instead of showing it (DockPanel.qml loads it at
  // opacity: 0.0) -- getWidgetIcon() falls back to `item.icon` for any
  // plugin id it doesn't special-case (DockPanel.qml:1323), and our
  // manifest.json declares no icon, so without this the dock would render
  // its generic ""-style placeholder glyph instead of ours. Kept as
  // the single source of truth for the glyph so the bar (button.text below)
  // and the dock can never drift.
  //
  // Issue #8's `icon` setting overrides the glyph through this SAME
  // single source of truth (rather than re-deriving a second one on
  // button.text alone), so a user override reaches the dock too, not
  // just the bar.
  readonly property string icon: root.setting("icon", "󰦝")

  // Dock hosting (issue #7): the same dock glyph reads `item.fontFamily`
  // (falling back to `item.font.family`, then Style.font.family --
  // DockPanel.qml:2771) to pick the font it draws the icon with. Plain
  // Items like this one have no `font` property, so without this the dock
  // would already land on Style.font.family via its own fallback chain --
  // exposing it here just makes that explicit instead of accidental.
  readonly property string fontFamily: Style.font.family

  // ---- Panel lifecycle (issue #3). `opened` mirrors the shape the bar's
  // popout coordinator and dock both expect (Bar.qml calls
  // closeForPopoutSwitch()/close() on whatever widget currently holds
  // activePopout; the IPC handler below calls open()/close()/toggle()
  // directly).
  readonly property bool opened: popup.open

  function open() { popup.open = true }
  function close() { popup.open = false }
  function toggle() { if (root.opened) root.close(); else root.open() }
  function closeForPopoutSwitch() { root.close() }

  // The bar's click dispatcher only routes a click to a widget that
  // exposes this, and only then shows a pointer cursor for it (see
  // Bar.qml's moduleTargetClickable()) -- WidgetButton below already
  // registers itself as a click target covering the whole slot and calls
  // this on press, but issue #3 asks for it on the widget root too (as
  // zeru.portwatch/Widget.qml does), for a dock or any other caller that
  // addresses the bar-widget instance directly rather than going through
  // WidgetButton.
  function triggerPress(button) { root.toggle() }

  // Panel state/logic (issues #4/#5) -- see PanelState.qml's own docstring
  // for why this is a plain Item and not part of this file or Popup.qml.
  //
  // Issue #8 settings, read through the base class's setting()/shell.json
  // mechanism and handed down as plain property bindings -- PanelState.qml
  // itself never touches shell.json (see its own "Settings (issue #8)"
  // section for each key's default/meaning). Minimal, additive change to
  // this file only to pass these straight through.
  //
  // `database` (issue #17): now actually reaches Backend.qml/Cli.js via
  // PanelState's own `database` alias -- previously accepted here and
  // silently dropped (see PanelState.qml's doc comment on that property).
  PanelState {
    id: state
    maskRevealedCode: root.setting("maskCodes", true)
    revealSeconds: root.setting("revealSeconds", 5)
    clipboardClearSeconds: root.setting("clipboardClearSeconds", 0)
    database: root.setting("database", "")
  }

  onOpenedChanged: {
    if (root.opened) state.open()
    else state.close()
  }

  IpcHandler {
    target: "pavanprakash21.twofa"

    function open(): void { root.open() }
    function close(): void { root.close() }
    function toggle(): void { root.toggle() }
  }

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: root.icon
    fontSize: Style.font.icon
    foreground: root.iconColor
    tooltipText: "2FA"
    active: root.opened

    onPressed: function (b) { root.triggerPress(b) }
  }

  Popup {
    id: popup
    anchorItem: root
    bar: root.bar
    owner: root
    state: state

    onCloseRequested: root.close()
  }
}
