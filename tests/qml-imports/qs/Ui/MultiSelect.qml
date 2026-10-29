import QtQuick
Item {
  id: root
  property var options: []
  property var values: []
  property bool showLabel: true
  property bool popupOpen: false
  property bool hasCursor: false
  signal changed(var values)
  function open() {popupOpen=true}
  function close() {popupOpen=false}
  function toggle() {popupOpen=!popupOpen}
  implicitHeight: 30
}
