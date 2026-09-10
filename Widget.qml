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
  function luminance(c) { return 0.299 * c.r + 0.587 * c.g + 0.114 * c.b }
  readonly property color iconColor: bar
    ? (luminance(bar.background) > 0.6 ? "#1a1a1a" : bar.barForeground)
    : Color.foreground

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
  // this file only to pass these three straight through.
  PanelState {
    id: state
    maskRevealedCode: root.setting("maskCodes", true)
    revealSeconds: root.setting("revealSeconds", 5)
    clipboardClearSeconds: root.setting("clipboardClearSeconds", 0)
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
    // Issue #8's `icon` setting overrides the bar glyph. Default matches
    // this widget's original hard-coded glyph exactly.
    text: root.setting("icon", "󰦝")
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
