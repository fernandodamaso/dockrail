import QtQuick
import QtQuick.Controls as Controls
import qs.Commons
import qs.Commons as Commons

Controls.AbstractButton {
  id: root
  property string accessibleName: text
  checkable: true
  activeFocusOnTab: true
  implicitWidth: Math.max(18, content.implicitWidth)
  implicitHeight: Math.max(20, content.implicitHeight)

  function activateKey(key) {
    if (key !== Qt.Key_Return && key !== Qt.Key_Enter && key !== Qt.Key_Space) return false
    root.checked = !root.checked
    return true
  }

  contentItem: Row {
    id: content
    spacing: Style.space(6)

    Rectangle {
      anchors.verticalCenter: parent.verticalCenter
      width: 17
      height: 17
      radius: 4
      color: root.checked ? Commons.Color.accent : "transparent"
      border.width: root.activeFocus ? 2 : 1
      border.color: root.checked ? Commons.Color.accent
        : root.activeFocus ? Commons.Color.accent : Util.alpha(Commons.Color.foreground, 0.34)

      WidgetIcon {
        anchors.centerIn: parent
        visible: root.checked
        iconName: "check"
        sizeToken: "xs"
        tint: Commons.Color.background
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