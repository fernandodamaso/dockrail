import QtQuick
import qs.Commons
import qs.Commons as Commons

Item {
  id: root
  WidgetSemanticPalette { id: semanticPalette }
  property string text: ""
  property string semantic: "neutral"
  property bool compact: false
  readonly property color tone: semanticPalette.tone(root.semantic)

  implicitWidth: label.implicitWidth + (root.compact ? 10 : 14)
  implicitHeight: root.compact ? 18 : 22

  Rectangle {
    anchors.fill: parent
    radius: height / 2
    color: Qt.tint(Commons.Color.background, Util.alpha(root.tone, 0.16))
    border.width: 1
    border.color: Util.alpha(root.tone, 0.28)
  }

  Text {
    id: label
    anchors.centerIn: parent
    text: root.text
    textFormat: Text.PlainText
    color: root.tone
    font.family: Style.font.family
    font.pixelSize: root.compact ? Style.font.caption : Style.font.bodySmall
    font.bold: true
    elide: Text.ElideRight
  }

  Accessible.role: Accessible.StaticText
  Accessible.name: root.text
}