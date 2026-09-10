// SPDX-License-Identifier: GPL-3.0-or-later
import QtQuick
import qs.Commons
import qs.Ui

// Placeholder bar widget for the 2FA plugin. Renders a static glyph only —
// on-demand reveal/copy of a TOTP/HOTP code lands in #3, backed by the
// OTPClient-reading service from #2. This exists purely so the plugin can
// be enabled and the widget placed in the bar ahead of that work.
BarWidget {
  id: root
  moduleName: "pavanprakash21.twofa"

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: "🔐"
    fontSize: Style.font.icon
    tooltipText: "2FA (coming soon)"
    interactive: false
  }
}
