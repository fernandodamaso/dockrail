import QtQuick
import qs.Commons
import qs.Commons as Commons

Item {
  id: root
  WidgetSemanticPalette { id: semanticPalette }
  property real value: 0
  property string semantic: "info"
  readonly property real normalizedValue: Math.max(0, Math.min(1, isFinite(root.value) ? root.value : 0))
  readonly property color tone: semanticPalette.tone(root.semantic)

  implicitWidth: 120
  implicitHeight: 7

  Rectangle {
    anchors.fill: parent
    radius: height / 2
    color: Util.alpha(Commons.Color.foreground, 0.10)
  }

  Rectangle {
    width: parent.width * root.normalizedValue
    height: parent.height
    radius: height / 2
    color: root.tone
  }

  Accessible.role: Accessible.ProgressBar
  Accessible.name: Math.round(root.normalizedValue * 100) + " percent"
}