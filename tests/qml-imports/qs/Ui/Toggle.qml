import QtQuick
Item {
  id: root
  property string label: ""
  property string description: ""
  property bool checked: false
  property bool hasCursor: false
  signal clicked()
  signal hovered(bool on)
  implicitHeight: 50
  implicitWidth: 200
  MouseArea { anchors.fill:parent; onClicked:root.clicked() }
}
