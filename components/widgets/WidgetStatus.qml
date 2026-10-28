import QtQuick
import qs.Commons
import qs.Commons as Commons

Row {
  id: root
  WidgetSemanticPalette { id: semanticPalette }
  property string label: ""
  property string semantic: "neutral"
  property string reference: ""
  property string referenceSemantic: ""
  property bool compact: true
  spacing: Style.space(6)

  readonly property color tone: root.semantic === "neutral"
    ? Util.alpha(Commons.Color.foreground, 0.72) : semanticPalette.tone(root.semantic)

  Rectangle {
    anchors.verticalCenter: parent.verticalCenter
    width: 7
    height: 7
    radius: 4
    color: root.tone
  }

  WidgetText {
    anchors.verticalCenter: parent.verticalCenter
    text: root.label
    role: "caption"
    allowWrap: false
    muted: root.semantic === "neutral"
  }

  WidgetBadge {
    visible: root.reference !== ""
    anchors.verticalCenter: parent.verticalCenter
    text: root.reference
    semantic: root.referenceSemantic === "" ? root.semantic : root.referenceSemantic
    compact: root.compact
  }
}