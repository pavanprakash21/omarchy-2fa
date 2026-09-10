import QtQuick
import Quickshell.Io
// Widget.qml/Popup.qml/PanelState.qml/PanelLogic.js resolve as same-directory
// sibling types with no explicit import; Ui/ and Commons/ are staged copies
// of the real /usr/share/omarchy/shell modules Widget.qml transitively
// depends on (`qs.Ui`, `qs.Commons`) -- see tests/run-qml-tests.sh for why
// they're staged rather than faked: a hand-rolled stub of that contract is
// exactly the kind of guess issue #7 says not to make.

// Integration test for issue #7 (dock hosting compatibility). rosakodu.dock
// hosts our widget by injecting a `dockBarContext` proxy as `bar`
// (DockPanel.qml's configureHostedWidget(), around line 1102) instead of the
// real Bar/qs.Ui/PluginBarApi facade. That proxy is a strict SUBSET of the
// real contract -- most importantly it has no `background` property at all
// (see DockPanel.qml's own `QtObject { id: dockBarContext ... }` around line
// 1189, transcribed below). Before this fix, Widget.qml's `iconColor`
// binding called `luminance(bar.background)` unconditionally whenever `bar`
// was truthy -- reading `.r` off `undefined` inside a property binding. The
// base class's `bar ? x : fallback` idiom (BarWidget.qml) only guards a
// *missing* bar; it says nothing about a present-but-partial one, so it did
// not catch this.
//
// This file never calls open()/toggle() on the loaded widget, so its child
// Popup (a real PopupWindow) stays at `open: false` the whole run and never
// maps a window or touches Hyprland/the clipboard -- same hermeticity
// guarantee panel.qmltest.qml gives PanelState, just proven one level up.
//
// Run with tests/run-qml-tests.sh.
Item {
  id: root

  property int failed: 0

  function check(name, cond) {
    if (cond) {
      console.log("PASS " + name)
    } else {
      console.log("FAIL " + name)
      root.failed++
    }
  }

  function isRealColor(c) {
    return c !== undefined && c !== null
      && typeof c.r === "number" && !isNaN(c.r)
      && typeof c.g === "number" && !isNaN(c.g)
      && typeof c.b === "number" && !isNaN(c.b)
  }

  // Transcribed from DockPanel.qml's `dockBarContext` (the object
  // configureHostedWidget() actually injects as `bar`) -- deliberately NOT
  // the real Bar/PluginBarApi (qs.Ui's own facade). No `background`,
  // `transparent`, `clickTargets`, `layoutConfig`, `registerClickTarget`,
  // `unregisterClickTarget`, `targetBelongsToWindow`, or `moduleWidgets` --
  // those are exactly the members the real facade has that this one omits.
  QtObject {
    id: dockBarContext
    property bool vertical: false
    property int barSize: 56
    property int barH: 56
    property int barW: 56
    property string position: "left"
    property var screen: null
    property var shell: null
    property color foreground: "#e6e6e6"
    property color barForeground: "#e6e6e6"
    property color urgent: "#ff5555"
    property color muted: "#888888"
    property color accent: "#88c0ff"
    property bool foregroundAnimationEnabled: true
    property string fontFamily: "monospace"
    property var activePopout: null
    function showTooltip(item, text) {}
    function hideTooltip(item) {}
    function requestPopout(key) { activePopout = key }
    function releasePopout(key) { if (activePopout === key) activePopout = null }
    function isBarWidgetOpen(id) { return false }
    function switchPanelFrom(panel, dir) { return false }
    function run(cmd) {}
  }

  // A bar-shaped object that DOES carry `background`, standing in for the
  // real Bar/PluginBarApi contract -- regression guard that the fix doesn't
  // change behavior when the full contract is present.
  QtObject {
    id: fullBarContext
    property bool vertical: false
    property int barSize: 40
    property color foreground: "#101315"
    property color barForeground: "#101315"
    property color background: "#ffffff"
    property color urgent: "#ff5555"
    property bool foregroundAnimationEnabled: true
    property string fontFamily: "monospace"
    property var activePopout: null
    function showTooltip(item, text) {}
    function hideTooltip(item) {}
    function requestPopout(key) {}
    function releasePopout(key) {}
  }

  Loader {
    id: widgetLoader
    source: "Widget.qml"
  }

  Component.onCompleted: {
    if (widgetLoader.status !== Loader.Ready || !widgetLoader.item) {
      root.check("Widget.qml loads under a dock-shaped bar", false)
      console.log("ALL_DONE failed=" + Math.max(1, root.failed))
      return
    }
    var item = widgetLoader.item

    // ---- Scenario 1: no bar at all -- the base class's own
    // `bar ? x : fallback` idiom, kept as a baseline it must still pass.
    item.bar = null
    check("no-bar: iconColor is a real color", isRealColor(item.iconColor))
    check("no-bar: vertical falls back to false", item.vertical === false)
    check("no-bar: barSize falls back to a positive default", item.barSize > 0)

    // ---- Scenario 2: dockBarContext -- the actual issue #7 shape. Must not
    // throw and must not silently produce a wrong/leftover color.
    item.bar = dockBarContext
    check("dock: iconColor is a real color, not an undefined-derived one",
      isRealColor(item.iconColor))
    check("dock: iconColor falls back to bar.barForeground (nothing to contrast against)",
      Qt.colorEqual(item.iconColor, dockBarContext.barForeground))
    check("dock: vertical/barSize pass through the dockBarContext values",
      item.vertical === dockBarContext.vertical && item.barSize === dockBarContext.barSize)
    check("dock: exposes a non-empty icon for the dock's getWidgetIcon() item.icon fallback",
      typeof item.icon === "string" && item.icon.length > 0)
    check("dock: exposes a non-empty fontFamily for the dock's DockGlyph fallback",
      typeof item.fontFamily === "string" && item.fontFamily.length > 0)
    check("dock: lifecycle contract (open/close/toggle/triggerPress) still present",
      typeof item.open === "function" && typeof item.close === "function"
      && typeof item.toggle === "function" && typeof item.triggerPress === "function")
    check("dock: never opened by merely being hosted (no window mapped)",
      item.opened === false)

    // ---- Scenario 3: a full bar-shaped object with a real `background` --
    // confirms the guard added for issue #7 does not change the existing
    // light/dark contrast behavior when the contract IS complete.
    item.bar = fullBarContext
    check("full-bar: iconColor still computes the light-background contrast branch",
      isRealColor(item.iconColor) && !Qt.colorEqual(item.iconColor, fullBarContext.barForeground))

    console.log(root.failed === 0 ? "ALL_DONE ok" : ("ALL_DONE failed=" + root.failed))
  }
}
