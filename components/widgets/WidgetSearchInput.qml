import QtQuick
import qs.Commons
import qs.Commons as Commons

WidgetTextInput {
  id: root
  property string searchIconName: "search"
  leftPadding: Style.space(30)

  WidgetIcon {
    anchors.left: parent.left
    anchors.leftMargin: Style.space(9)
    anchors.verticalCenter: parent.verticalCenter
    iconName: root.searchIconName
    sizeToken: "sm"
    containerVariant: "plain"
    tint: Util.alpha(Commons.Color.foreground, 0.52)
    opacity: 0.72
    accessibleName: "Search"
  }
}