// Headless endpoint fixture; native behavior requires Omarchy qualification.
import QtQuick
Item {
  id: root
  property Item anchorItem
  property QtObject bar
  property var owner
  property bool open: false
  property int contentWidth: 680
  property int contentHeight: 600
  property Item focusTarget
  property var screen: ({height:800})
  readonly property int availableCardHeight: 750
  readonly property int verticalContentInset: 24
  function fittedContentHeight(value) { return Math.min(750,value+24) }
  width: contentWidth
  height: contentHeight
  // Native KeyboardPanel places content inside the card's border and padding.
  default property alias contentItem: holder.data
  property Item contentHolder: Item {
    id: holder
    parent: root
    x: 12; y: 12
    width: root.width - 24
    height: root.height - 24
  }
}
