// Headless endpoint fixture; native behavior requires Omarchy qualification.
import QtQuick
Row {property var options:[]; property string value:""; property int cursorIndex:-1; signal changed(string value); signal hovered(int index,bool on); Repeater {model:options; Button {required property var modelData; text:modelData.label; onClicked:parent.changed(modelData.value)}}}
