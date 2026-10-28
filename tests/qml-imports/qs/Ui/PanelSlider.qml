import QtQuick
Item {
  property real minimum:0
  property real maximum:100
  property real value:0
  property real step:1
  property bool integer:false
  property bool dragging:false
  property real liveValue:value
  signal moved(real value)
  signal released(real value)
  implicitHeight:30
}
