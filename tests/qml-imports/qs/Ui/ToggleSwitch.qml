// Headless ToggleSwitch surface with caller-owned state; the native QS
// ToggleSwitch draws its own track, knob, and focus ring.
import QtQuick
Item {
  id:root
  property bool checked:false
  property bool interactive:true
  property bool busy:false
  property bool hasCursor:false
  property color foreground:"white"
  property color accent:"white"
  implicitWidth:44
  implicitHeight:26
  signal toggled()
  Rectangle {anchors.centerIn:parent; width:36;height:22;color:root.checked?root.accent:root.foreground;opacity:0.4}
}
