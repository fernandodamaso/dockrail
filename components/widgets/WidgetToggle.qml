import QtQuick
import QtQuick.Controls as Controls
import qs.Commons
import qs.Commons as Commons

Controls.AbstractButton {
  id: root
  property string accessibleName: text
  checkable: true
  activeFocusOnTab: true
  implicitWidth: Math.max(38, content.implicitWidth)
  implicitHeight: Math.max(24, content.implicitHeight)

  function activateKey(key) {
    if (key !== Qt.Key_Return && key !== Qt.Key_Enter && key !== Qt.Key_Space) return false
    root.checked = !root.checked
    return true
  }

  contentItem: Row {
    id: content
    spacing: Style.space(7)

    Rectangle {
      anchors.verticalCenter: parent.verticalCenter
      width: 34
      height: 19
      radius: 10
      color: root.checked ? Commons.Color.accent : Util.alpha(Commons.Color.foreground, 0.15)
      border.width: root.activeFocus ? 1 : 0
      border.color: Commons.Color.accent

      Rectangle {
        width: 15
        height: 15
        radius: 8
        y: 2
        x: root.checked ? parent.width - width - 2 : 2
        color: root.checked ? Commons.Color.background : Util.alpha(Commons.Color.foreground, 0.78)
        Behavior on x { NumberAnimation { duration: 110 } }
      }
    }

    WidgetText {
      visible: root.text !== ""
      anchors.verticalCenter: parent.verticalCenter
      text: root.text
      allowWrap: false
    }
  }

  background: Item {}

  Keys.onPressed: function(event) {
    if (root.activateKey(event.key)) event.accepted = true
  }

  Accessible.role: Accessible.CheckBox
  Accessible.name: root.accessibleName
  Accessible.checked: root.checked
}