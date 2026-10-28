import QtQuick
import QtQuick.Controls as Controls
import qs.Commons
import qs.Commons as Commons

Controls.TextField {
  id: root
  WidgetSemanticPalette { id: semanticPalette }
  property string validationState: "none"
  property string accessibleName: placeholderText

  implicitHeight: Math.max(34, Style.space(34))
  leftPadding: Style.space(9)
  rightPadding: Style.space(9)
  activeFocusOnTab: true
  selectByMouse: true
  echoMode: TextInput.Normal
  color: Commons.Color.foreground
  placeholderTextColor: semanticPalette.mutedText
  selectionColor: Commons.Color.accent
  selectedTextColor: Commons.Color.background
  font.family: Style.font.family
  font.pixelSize: Style.font.bodySmall

  background: Rectangle {
    radius: Math.min(3, Style.cornerRadius)
    color: Qt.darker(Commons.Color.background, 1.03)
    border.width: 1
    border.color: root.validationState === "error" ? semanticPalette.danger
      : root.activeFocus ? Commons.Color.accent : Util.alpha(Commons.Color.foreground, 0.16)
  }

  Accessible.role: Accessible.EditableText
  Accessible.name: root.accessibleName
}