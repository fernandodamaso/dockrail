pragma ComponentBehavior: Bound

import QtQuick
import qs.Commons
import qs.Commons as Commons
import qs.Ui as Ui

// Non-interactive drag hint for the background mode gesture: the directional
// prompt while moving, the release prompt once the destination is armed.
//
// Composed from Omarchy's native BorderSurface with semantic menu tokens. The
// root is disabled, so it can never take pointer input or hover away from the
// panel content it floats over, and it disappears with the gesture.
Item {
  id: root

  property string text: ""
  property bool animationsEnabled: true

  readonly property bool shown: root.text !== ""

  implicitWidth: label.implicitWidth + Style.space(20)
  implicitHeight: label.implicitHeight + Style.space(10)
  width: implicitWidth
  height: implicitHeight
  enabled: false
  visible: opacity > 0
  opacity: root.shown ? 1 : 0

  Behavior on opacity {
    enabled: root.animationsEnabled
    NumberAnimation {
      duration: 120
      easing.type: Easing.OutCubic
    }
  }

  Ui.BorderSurface {
    anchors.fill: parent
    radius: Style.cornerRadius
    color: Commons.Color.menu.background
    borderSpec: Border.surfaceSpec("menu", "border", Commons.Color.menu.border, Style.normalBorderWidth)

    Text {
      id: label

      anchors.centerIn: parent
      text: root.text
      textFormat: Text.PlainText
      color: Commons.Color.menu.text
      font.family: Style.font.family
      font.pixelSize: Style.font.bodySmall
      horizontalAlignment: Text.AlignHCenter
      verticalAlignment: Text.AlignVCenter
    }
  }
}
