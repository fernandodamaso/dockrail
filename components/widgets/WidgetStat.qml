import QtQuick
import qs.Commons
import qs.Commons as Commons

Item {
  id: root
  property string label: ""
  property string value: ""
  property string helper: ""
  implicitWidth: 100
  implicitHeight: content.implicitHeight + Style.space(12)

  Rectangle {
    anchors.fill: parent
    radius: Math.min(3, Style.cornerRadius)
    color: Util.alpha(Commons.Color.foreground, 0.04)
  }

  Column {
    id: content
    anchors.left: parent.left
    anchors.right: parent.right
    anchors.leftMargin: Style.space(8)
    anchors.rightMargin: Style.space(8)
    anchors.verticalCenter: parent.verticalCenter
    spacing: 2

    WidgetText { width: parent.width; text: root.label; role: "caption"; muted: true; allowWrap: false }
    WidgetText { width: parent.width; text: root.value; role: "title"; allowWrap: false }
    WidgetText {
      visible: root.helper !== ""
      width: parent.width
      text: root.helper
      role: "caption"
      muted: true
      allowWrap: false
    }
  }
}