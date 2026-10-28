import QtQuick
import QtQuick.Controls as Controls
import qs.Commons
import qs.Commons as Commons

Controls.ComboBox {
  id: root
  WidgetSemanticPalette { id: semanticPalette }
  property string accessibleName: ""
  property string validationState: "none"

  implicitHeight: Math.max(34, Style.space(34))
  leftPadding: Style.space(9)
  rightPadding: Style.space(32)
  activeFocusOnTab: true
  font.family: Style.font.family
  font.pixelSize: Style.font.bodySmall

  contentItem: Text {
    text: root.displayText
    textFormat: Text.PlainText
    color: Commons.Color.foreground
    verticalAlignment: Text.AlignVCenter
    elide: Text.ElideRight
    font: root.font
  }

  indicator: WidgetIcon {
    x: root.width - width - Style.space(9)
    y: Math.round((root.height - height) / 2)
    iconName: "chevron-down"
    sizeToken: "sm"
    containerVariant: "plain"
    tint: Util.alpha(Commons.Color.foreground, 0.72)
  }

  background: Rectangle {
    radius: Math.min(3, Style.cornerRadius)
    color: Qt.darker(Commons.Color.background, 1.03)
    border.width: 1
    border.color: root.validationState === "error" ? semanticPalette.danger
      : root.activeFocus ? Commons.Color.accent : Util.alpha(Commons.Color.foreground, 0.16)
  }

  Accessible.role: Accessible.ComboBox
  Accessible.name: root.accessibleName
}