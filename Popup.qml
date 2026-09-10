import QtQuick
import Quickshell
import Quickshell.Hyprland
import qs.Commons
import qs.Ui
import "PanelLogic.js" as Logic

// Popup.qml -- the 2FA panel's visual layer (issues #4/#5). A plain
// PopupWindow anchored to the bar icon, dismissed by HyprlandFocusGrab --
// the same shape as zeru.portwatch/PortsPopup.qml, per issue #4's explicit
// direction, rather than the heavier first-party KeyboardPanel
// (PanelWindow + layer-shell) some built-in plugins use.
//
// Everything stateful lives in PanelState.qml (`state`, injected by
// Widget.qml) so it can be driven headlessly by tests/panel.qmltest.qml.
// This file only paints `state`'s properties and forwards key/mouse input
// to `state`'s functions -- it owns no otpclient-cli/wl-copy process, no
// timer, and no copy of a decrypted code.
PopupWindow {
  id: root

  required property Item anchorItem
  required property QtObject bar
  property var owner: null
  required property QtObject state
  property bool open: false

  signal closeRequested()

  readonly property var coordinatorKey: owner || root
  readonly property var anchorWindow: anchorItem ? anchorItem.QsWindow.window : null

  // ---- Theme tokens only -- issue #4's explicit list, plus the same
  // luminance guard zeru.portwatch/PortsPopup.qml applies for a light
  // popups.background a theme didn't separately tune popups.text for.
  readonly property color bg: Color.popups.background
  readonly property color borderColor: Color.popups.border
  readonly property color accent: Color.accent
  readonly property color muted: Color.muted
  readonly property color urgent: Color.urgent

  function luminance(c) { return 0.299 * c.r + 0.587 * c.g + 0.114 * c.b }
  readonly property color fg: luminance(bg) > 0.6 ? "#1a1a1a" : Color.popups.text
  readonly property color safeMuted: luminance(bg) > 0.6 ? "#5a5a5a" : muted
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  readonly property int margin: 10
  readonly property int cardPadding: 12

  implicitWidth: 360
  implicitHeight: Math.min(440, Math.max(220, content.implicitHeight + cardPadding * 2))

  visible: open || card.opacity > 0
  color: "transparent"

  function close() { root.open = false; root.closeRequested() }

  onOpenChanged: {
    if (open) {
      Qt.callLater(function () {
        if (root.open) searchField.forceActiveFocus()
      })
    }
    if (!bar) return
    if (open) bar.requestPopout(coordinatorKey)
    else if (bar.activePopout === coordinatorKey) bar.releasePopout(coordinatorKey)
  }

  // Clicking away or pressing Escape closes the panel -- issue #4's
  // explicit requirement, same mechanism as
  // zeru.portwatch/PortsPopup.qml:55-60.
  HyprlandFocusGrab {
    active: root.open
    windows: root.anchorWindow ? [root, root.anchorWindow] : [root]
    onCleared: root.close()
  }

  anchor {
    id: popupAnchor
    window: root.anchorWindow
    adjustment: PopupAdjustment.Slide
    edges: Edges.Top | Edges.Left
    gravity: Edges.Bottom | Edges.Right
    rect.width: 1
    rect.height: 1

    onAnchoring: {
      if (!root.anchorItem || !root.bar || !root.anchorWindow) return

      var target = root.anchorItem
      var w = root.implicitWidth
      var h = root.implicitHeight
      var localX = target.width / 2 - w / 2
      var localY = target.height + root.margin

      if (root.bar.position === "bottom") {
        localY = -h - root.margin
      } else if (root.bar.position === "left") {
        localX = target.width + root.margin
        localY = target.height / 2 - h / 2
      } else if (root.bar.position === "right") {
        localX = -w - root.margin
        localY = target.height / 2 - h / 2
      }

      var point = root.anchorWindow.contentItem.mapFromItem(target, localX, localY)

      if (root.bar.position === "top" || root.bar.position === "bottom") {
        point.x = Math.max(root.margin, Math.min(point.x, root.anchorWindow.width - w - root.margin))
      } else {
        point.y = Math.max(root.margin, Math.min(point.y, root.anchorWindow.height - h - root.margin))
      }

      popupAnchor.rect.x = Math.round(point.x)
      popupAnchor.rect.y = Math.round(point.y)
    }
  }

  Rectangle {
    id: card
    anchors.fill: parent
    radius: Style.cornerRadius
    color: root.bg
    border.color: root.borderColor
    border.width: 2
    opacity: root.open ? 1 : 0

    Behavior on opacity {
      NumberAnimation { duration: 130; easing.type: Easing.OutCubic }
    }

    Column {
      id: content
      anchors.fill: parent
      anchors.margins: root.cardPadding
      spacing: 8

      // ---- Header: title + refresh (mouse convenience; keyboard users
      // get an equivalent refresh for free by closing and reopening the
      // panel, since inventory always reloads on open -- issue #4).
      Row {
        width: parent.width
        height: Math.max(titleText.implicitHeight, refreshBtn.height)

        Text {
          id: titleText
          textFormat: Text.PlainText
          text: "2FA"
          color: root.fg
          font.family: root.fontFamily
          font.pixelSize: Style.font.title
          font.bold: true
          width: parent.width - refreshBtn.width
          anchors.verticalCenter: parent.verticalCenter
        }

        Item {
          id: refreshBtn
          width: 22
          height: 22
          anchors.verticalCenter: parent.verticalCenter

          Text {
            anchors.centerIn: parent
            textFormat: Text.PlainText
            text: "󰑐"
            color: root.fg
            font.family: root.fontFamily
            font.pixelSize: 13
            opacity: refreshArea.containsMouse ? 1 : 0.6
          }

          MouseArea {
            id: refreshArea
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: {
              root.state.refresh()
              searchField.forceActiveFocus()
            }
          }
        }
      }

      // ---- Search / type-to-filter (issue #4). Up/Down/Enter/Escape are
      // intercepted before the default TextField editing handles them;
      // every other key (letters, backspace, ...) still edits the field
      // normally, so typing filters the list without a separate "focus
      // search" step -- the field already holds focus whenever the panel
      // is open (see onOpenChanged above).
      TextField {
        id: searchField
        width: parent.width
        placeholderText: "Search issuer or account…"
        foreground: root.fg
        accent: root.accent

        onTextChanged: root.state.setFilterText(text)

        Keys.onPressed: function (event) {
          switch (event.key) {
          case Qt.Key_Down:
            root.state.moveSelection(1)
            event.accepted = true
            break
          case Qt.Key_Up:
            root.state.moveSelection(-1)
            event.accepted = true
            break
          case Qt.Key_Return:
          case Qt.Key_Enter:
            root.state.activateSelected()
            event.accepted = true
            break
          case Qt.Key_Escape:
            if (root.state.hotpConfirmKey !== "") root.state.cancelHotpConfirm()
            else root.close()
            event.accepted = true
            break
          default:
            break
          }
        }
      }

      // ---- Body: loading / empty / error / the row list. Exactly one of
      // these is visible at a time, per issue #4's "loading, empty, and
      // error states rendered inline" requirement.
      Text {
        width: parent.width
        visible: root.state.loadState === "loading"
        textFormat: Text.PlainText
        text: "Decrypting your database…"
        color: root.safeMuted
        font.family: root.fontFamily
        font.pixelSize: Style.font.body
        wrapMode: Text.WordWrap

        SequentialAnimation on opacity {
          running: root.state.loadState === "loading"
          loops: Animation.Infinite
          NumberAnimation { from: 1.0; to: 0.4; duration: 550; easing.type: Easing.InOutSine }
          NumberAnimation { from: 0.4; to: 1.0; duration: 550; easing.type: Easing.InOutSine }
        }
      }

      Text {
        width: parent.width
        visible: root.state.loadState === "empty"
        textFormat: Text.PlainText
        text: "No entries in your OTPClient database."
        color: root.safeMuted
        font.family: root.fontFamily
        font.pixelSize: Style.font.body
        wrapMode: Text.WordWrap
      }

      Column {
        width: parent.width
        visible: root.state.loadState === "error"
        spacing: 4

        Text {
          width: parent.width
          textFormat: Text.PlainText
          text: root.state.loadErrorMessage || "Couldn't read the OTPClient database."
          color: root.urgent
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
          wrapMode: Text.WordWrap
        }

        Text {
          width: parent.width
          textFormat: Text.PlainText
          text: "Close and reopen the panel to try again."
          color: root.safeMuted
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          wrapMode: Text.WordWrap
        }
      }

      Flickable {
        id: flick
        width: parent.width
        height: Math.min(300, listCol.implicitHeight)
        visible: root.state.loadState === "ok"
        contentWidth: width
        contentHeight: listCol.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds

        Column {
          id: listCol
          width: flick.width

          Repeater {
            model: root.state.loadState === "ok" ? root.state.filteredEntries : []
            delegate: TokenRow { width: listCol.width }
          }
        }
      }
    }
  }

  // ---- One inventory row: issuer primary, account secondary, a TOTP/HOTP
  // badge -- issue #4. Swaps its right-hand content to the revealed code +
  // seconds-remaining countdown (plain text, never a proportional ring --
  // see PanelState.qml's countdown Timer for why) once this row is the
  // revealed one, or to a "press again to confirm" affordance while an
  // HOTP row is armed -- issue #5.
  component TokenRow: Rectangle {
    id: rowDelegate
    required property var modelData
    required property int index

    readonly property string rowKey: Logic.entryKey(modelData)
    readonly property bool isHotp: Logic.isHotp(modelData.type)
    readonly property bool isSelected: index === root.state.selectedIndex
    readonly property bool confirmArmed: root.state.hotpConfirmKey === rowKey
    readonly property bool isPending: root.state.isRevealPendingFor(modelData.issuer, modelData.account)
    readonly property bool isRevealed: root.state.isRevealedFor(modelData.issuer, modelData.account)

    height: isRevealed ? 64 : 46
    radius: Style.cornerRadius
    color: isSelected
      ? Style.selectedFillFor(root.fg, root.accent, root.urgent)
      : (rowHover.hovered ? Style.hoverFillFor(root.fg, root.accent, root.urgent) : "transparent")

    Behavior on height {
      NumberAnimation { duration: 120; easing.type: Easing.OutCubic }
    }

    HoverHandler { id: rowHover }

    MouseArea {
      anchors.fill: parent
      cursorShape: Qt.PointingHandCursor
      onClicked: {
        root.state.selectedIndex = rowDelegate.index
        root.state.activateSelected()
        searchField.forceActiveFocus()
      }
    }

    Row {
      anchors.left: parent.left
      anchors.leftMargin: 10
      anchors.right: badge.left
      anchors.rightMargin: 8
      anchors.verticalCenter: parent.verticalCenter
      spacing: 8

      Column {
        anchors.verticalCenter: parent.verticalCenter
        spacing: 1
        width: parent.width

        Text {
          textFormat: Text.PlainText
          text: rowDelegate.modelData.issuer || "(no issuer)"
          color: root.fg
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
          font.bold: true
          elide: Text.ElideRight
          width: parent.width
        }

        Text {
          textFormat: Text.PlainText
          visible: text !== ""
          text: rowDelegate.isRevealed
            ? (rowDelegate.modelData.type + " code copied · " + Math.max(0, root.state.revealedEntry.secondsRemaining) + "s")
            : (rowDelegate.confirmArmed
              ? "Press Enter again to confirm -- this advances the HOTP counter"
              : (rowDelegate.isPending ? "Decrypting…" : rowDelegate.modelData.account))
          color: rowDelegate.isRevealed ? root.accent : (rowDelegate.confirmArmed ? root.urgent : root.safeMuted)
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
          font.bold: rowDelegate.isRevealed
          elide: Text.ElideRight
          width: parent.width
        }

        Text {
          textFormat: Text.PlainText
          visible: rowDelegate.isRevealed
          text: rowDelegate.modelData.account + "  ·  " + (root.state.revealedEntry ? root.state.revealedEntry.current : "")
          color: root.fg
          font.family: root.fontFamily
          font.pixelSize: Style.font.subtitle
          font.bold: true
          elide: Text.ElideRight
          width: parent.width
        }
      }
    }

    Rectangle {
      id: badge
      anchors.right: parent.right
      anchors.rightMargin: 10
      anchors.verticalCenter: parent.verticalCenter
      width: badgeLabel.implicitWidth + 12
      height: 18
      radius: 9
      color: rowDelegate.isHotp
        ? Qt.rgba(root.urgent.r, root.urgent.g, root.urgent.b, 0.16)
        : Qt.rgba(root.accent.r, root.accent.g, root.accent.b, 0.16)

      Text {
        id: badgeLabel
        anchors.centerIn: parent
        textFormat: Text.PlainText
        text: rowDelegate.modelData.type || "?"
        color: rowDelegate.isHotp ? root.urgent : root.accent
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        font.bold: true
      }
    }
  }
}
