import QtQuick
Item {
  id: root
  property bool opened: false
  property string message: ""
  property string confirmText: "Confirm"
  property string cancelText: "Cancel"
  signal canceled()
  signal confirmed()
  visible: opened
  function handleKey(event) {
    if (!opened) return false
    if (event.key === Qt.Key_Escape) { canceled(); return true }
    if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) { confirmed(); return true }
    return false
  }
}
