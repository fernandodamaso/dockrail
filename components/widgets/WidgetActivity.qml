pragma ComponentBehavior: Bound
import QtQuick
import qs.Commons
import qs.Commons as Commons

Column {
  id: root
  WidgetSemanticPalette { id: semanticPalette }
  property var model: []
  width: parent ? parent.width : implicitWidth
  spacing: 0

  Repeater {
    model: root.model
    delegate: Item {
      required property var modelData
      required property int index
      width: root.width
      height: Math.max(42, activityCopy.implicitHeight + Style.space(10))

      Rectangle {
        x: 6
        y: 0
        width: 1
        height: parent.height
        visible: index < root.model.length - 1
        color: Util.alpha(Commons.Color.foreground, 0.12)
      }

      Rectangle {
        x: 3
        y: 15
        width: 7
        height: 7
        radius: 4
        color: semanticPalette.tone(modelData && modelData.semantic ? String(modelData.semantic) : "info")
      }

      Column {
        id: activityCopy
        anchors.left: parent.left
        anchors.leftMargin: Style.space(18)
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        spacing: 2
        WidgetText {
          width: parent.width
          text: modelData && modelData.title ? String(modelData.title) : ""
          allowWrap: false
        }
        WidgetText {
          width: parent.width
          text: modelData && modelData.detail ? String(modelData.detail) : ""
          role: "caption"
          muted: true
          maxLines: 2
        }
      }
    }
  }
}