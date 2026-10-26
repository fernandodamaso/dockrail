// Headless endpoint with the native Button signal/focus contract.
import QtQuick
Rectangle {
  id: root
  property string text: ""
  property string iconText: ""
  property string tooltipText: ""
  property bool focusable: false
  property bool selected: false
  property bool bordered: false
  property bool hasCursor: false
  signal clicked()
  signal hovered(bool on)
  activeFocusOnTab: focusable
  implicitWidth: label.implicitWidth + 20
  implicitHeight: 32
  color: selected ? "#555" : "#333"
  Keys.onReturnPressed: if(focusable) clicked()
  Keys.onEnterPressed: if(focusable) clicked()
  Keys.onSpacePressed: if(focusable) clicked()
  Text {id:label; anchors.centerIn:parent; text:root.text; color:"white"}
  MouseArea {anchors.fill:parent; onClicked:root.clicked()}
  HoverHandler {onHoveredChanged:root.hovered(hovered)}
}
