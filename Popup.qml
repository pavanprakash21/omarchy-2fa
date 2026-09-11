import QtQuick
import qs.Commons
import qs.Ui
import "PanelLogic.js" as Logic

// Popup.qml -- the 2FA panel's visual layer (issues #4/#5), rebuilt on
// qs.Ui's KeyboardPanel to fix issue #26.
//
// WAS a plain PopupWindow (xdg-popup), dismissed via HyprlandFocusGrab --
// the shape zeru.portwatch/PortsPopup.qml uses, per issue #4's explicit
// (but, issue #26 found, mistaken) citation of it as the reference
// implementation. portwatch's popup is mouse-only; it has no keyboard
// handling at all, so it was never actually exercising the one thing this
// panel has a HARD requirement for (issue #4: "every action is reachable
// from the keyboard alone").
//
// The bug (#26): an xdg-popup only ever receives compositor keyboard focus
// after a click/hover routes it through the parent surface. This popup's
// old onOpenChanged called searchField.forceActiveFocus() unconditionally,
// which sets Qt's own internal "which item gets the next key event WITHIN
// this surface" pointer -- but the Wayland *surface itself* never held
// compositor keyboard focus at all until the user had already clicked
// something. Typing before that first click did nothing; paste (which has
// no "an arrow key sometimes accidentally routes focus" fallback the way
// clicking elsewhere in the panel did) never worked, full stop.
//
// Fix: root element here IS qs.Ui's KeyboardPanel, not a hand-rolled
// PopupWindow. KeyboardPanel exists precisely for "click-driven AND
// keyboard-driven panels" (its own header comment) and already solves the
// focus problem with a brief WlrKeyboardFocus.Exclusive prime on every
// open (both first map and re-open-while-fading-out), handing off to
// OnDemand once primed -- see its header for exactly why Exclusive can't
// just be left on permanently (it would break pointer routing to other
// monitors). `focusTarget: searchField` below (KeyboardPanel's own
// documented hook) replaces the old manual forceActiveFocus() call --
// KeyboardPanel schedules it itself, via Qt.callLater, at the right point
// in the surface's map lifecycle.
//
// This is the same component every built-in keyboard-driven panel already
// uses (network, tailscale, agents, ...) -- not a novel construction.
// PanelKeyCatcher (qs.Ui's companion key dispatcher for KeyboardPanel) is
// deliberately NOT used here: this panel has exactly one focus owner the
// entire time it's open (the search field itself -- there is no separate
// "list navigation mode" to hand off from), so there is no scope in which
// PanelKeyCatcher's Keys.priority: BeforeItem would ever legitimately win a
// key over the field. Introducing it would only reproduce this exact bug
// from the other direction (see PanelKeyCatcher.qml's own caveat: it must
// be told `blocked: editor.activeFocus` whenever a panel's inline editor
// should receive keys instead of the catcher) for zero benefit. Instead,
// searchField keeps the same inline Keys.onPressed it already had, for
// exactly the four keys issue #4/#26 require (Down/Up/Enter/Escape);
// everything else -- letters, backspace, Ctrl+V paste -- falls through to
// TextField's own default editing, which now actually receives it because
// the surface holds real compositor focus. This mirrors how the built-in
// tailscale panel's own inline Mullvad-region search field is built: an
// explicit Keys.onPressed on the TextField for navigation keys, accepting
// each one, rather than relying on the panel's outer PanelKeyCatcher for a
// field that already owns focus.
//
// Also replaced by this rebuild, both intentionally:
//  - Outside-click / Escape dismissal is now KeyboardPanel's own built-in
//    mechanism (an overlay MouseArea plus per-output dismiss twins,
//    routed through close()) instead of HyprlandFocusGrab. No built-in
//    KeyboardPanel-based panel pairs it with HyprlandFocusGrab -- the two
//    are alternative solutions to the same problem, not complementary.
//    The user-visible contract (click away closes, Escape closes) is
//    unchanged.
//  - Popout coordination (bar.requestPopout/releasePopout, keyed by
//    `owner || root`) and on-screen positioning for all four bar edges are
//    now KeyboardPanel's own logic (the exact `owner || root` formula this
//    file used to hand-roll, and the exact same per-edge anchoring math
//    every other built-in KeyboardPanel panel already relies on) --
//    removed here so open/close isn't coordinated twice for the same
//    transition.
//
// Public API (anchorItem, bar, owner, open, state, the closeRequested
// signal) is kept identical to the old PopupWindow-based file so
// Widget.qml -- out of scope for this fix -- needs no changes:
//  - anchorItem/bar/owner/open are inherited straight from KeyboardPanel
//    now (same names, same meaning) rather than redeclared here.
//  - closeRequested is kept as a declared-but-never-emitted compatibility
//    signal purely so Widget.qml's existing `onCloseRequested: root.close()`
//    handler still resolves. It's no longer load-bearing: KeyboardPanel's
//    own close() already resolves through `owner` (Widget.qml passes
//    owner: root, and BarWidget's root.close() sets popup.open = false
//    directly), so Widget.qml's `opened: popup.open` binding already
//    observes every close this file can produce without an explicit
//    signal telling it to.
//
// Everything stateful still lives in PanelState.qml (`state`, injected by
// Widget.qml) so it can be driven headlessly by tests/panel.qmltest.qml.
// This file only paints `state`'s properties and forwards key/mouse input
// to `state`'s functions -- it owns no otpclient-cli/wl-copy process, no
// timer, and no copy of a decrypted code.
KeyboardPanel {
  id: root

  required property QtObject state

  // Compatibility no-op -- see header comment above.
  signal closeRequested()

  focusTarget: searchField
  // Same nominal size the old PopupWindow used (360 wide, content-fit up to
  // 440 tall) -- now additionally clamped to available screen space by
  // KeyboardPanel's own fittedContentWidth/fittedContentHeight, which the
  // old hand-rolled sizing never did.
  contentWidth: root.fittedContentWidth(360)
  contentHeight: root.fittedContentHeight(column.implicitHeight, 440)

  // ---- Theme tokens only -- issue #4's explicit list, plus the same
  // luminance guard zeru.portwatch/PortsPopup.qml applies for a light
  // popups.background a theme didn't separately tune popups.text for.
  // KeyboardPanel's own card already paints Color.popups.background/border
  // (its default `borderSpec`) -- these cover the token/text colors this
  // file still renders itself.
  readonly property color bg: Color.popups.background
  readonly property color accent: Color.accent
  readonly property color muted: Color.muted
  readonly property color urgent: Color.urgent

  function luminance(c) { return 0.299 * c.r + 0.587 * c.g + 0.114 * c.b }
  readonly property color fg: luminance(bg) > 0.6 ? "#1a1a1a" : Color.popups.text
  readonly property color safeMuted: luminance(bg) > 0.6 ? "#5a5a5a" : muted
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  Column {
    id: column
    width: parent.width
    spacing: 8

    // ---- Header: title + refresh (mouse convenience; keyboard users get
    // an equivalent refresh for free by closing and reopening the panel,
    // since inventory always reloads on open -- issue #4).
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
    // intercepted before the default TextField editing handles them; every
    // other key (letters, backspace, Ctrl+V paste, ...) still edits the
    // field normally. KeyboardPanel's `focusTarget: searchField` above
    // (not a manual forceActiveFocus() here) is what makes typing/pasting
    // work with no prior click -- see this file's header comment for why
    // that distinction is the entire fix for issue #26.
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
        // Names the fix, not the symptom (issue #6) -- mapped from the
        // TYPED state Backend/Cli.js report (loadErrorState), never a raw
        // Backend/Cli.js message string, so a decrypt/parse failure can
        // never surface a password/code/secret fragment here even if
        // Backend's own message text ever changed. See
        // PanelLogic.degradedStateMessage()'s own docstring.
        text: Logic.degradedStateMessage(root.state.loadErrorState, "list", root.state.loadErrorMessage)
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
    // Issue #6: a reveal-time failure (bad-password, db-missing, malformed,
    // would-prompt, crashed, instance-conflict, binary-missing, or a
    // same-row "no matching entry anymore" empty/busy) is surfaced on the
    // row it belongs to, not silently dropped -- see PanelState.qml's
    // isRevealFailedFor()/revealFailedKey docstrings for why this couldn't
    // just reuse isRevealed's own matching.
    readonly property bool isRevealFailed: root.state.isRevealFailedFor(modelData.issuer, modelData.account)

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
          // Never claims "copied" unconditionally -- Logic.revealStatusText
          // renders whatever root.state.clipboardCopyState actually is
          // ("copying"/"copied"/"failed"), and distinguishes a real
          // CLI-reported expiry from this UI's own fabricated HOTP
          // auto-clear window via revealCountdownIsFallback. See
          // PanelLogic.js's own docstring for exactly which adversarial
          // findings this covers.
          text: rowDelegate.isRevealed
            ? Logic.revealStatusText(rowDelegate.modelData.type, root.state.clipboardCopyState,
                root.state.revealedEntry.secondsRemaining, root.state.revealCountdownIsFallback)
            : (rowDelegate.isRevealFailed
              ? Logic.degradedStateMessage(root.state.revealErrorState, "show", root.state.revealErrorMessage)
              : (rowDelegate.confirmArmed
                ? Logic.confirmPromptText(rowDelegate.modelData.type)
                : (rowDelegate.isPending ? "Decrypting…" : rowDelegate.modelData.account)))
          color: rowDelegate.isRevealed
            ? (root.state.clipboardCopyState === "failed" ? root.urgent : root.accent)
            : ((rowDelegate.confirmArmed || rowDelegate.isRevealFailed) ? root.urgent : root.safeMuted)
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
          font.bold: rowDelegate.isRevealed
          elide: Text.ElideRight
          width: parent.width
        }

        Row {
          visible: rowDelegate.isRevealed
          width: parent.width
          spacing: 6

          Text {
            textFormat: Text.PlainText
            text: rowDelegate.modelData.account
            color: root.fg
            font.family: root.fontFamily
            font.pixelSize: Style.font.subtitle
            font.bold: true
            elide: Text.ElideRight
          }

          Text {
            id: codeText
            textFormat: Text.PlainText
            // Masked by maskRevealedCode (#8) -- concealed on screen but
            // already copied to the clipboard regardless (see
            // PanelState.qml's onShowSucceeded/codeMaskedOnScreen
            // docstrings: an earlier version had this backwards). A click
            // on the masked text reveals it on screen without issuing a
            // new decrypt.
            text: {
              var code = root.state.revealedEntry ? root.state.revealedEntry.current : ""
              return root.state.codeMaskedOnScreen ? "•".repeat(Math.max(6, code.length)) : code
            }
            color: root.fg
            font.family: root.fontFamily
            font.pixelSize: Style.font.subtitle
            font.bold: true

            MouseArea {
              anchors.fill: parent
              visible: root.state.codeMaskedOnScreen
              enabled: root.state.codeMaskedOnScreen
              cursorShape: Qt.PointingHandCursor
              onClicked: root.state.unmaskRevealedCode()
            }
          }
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
