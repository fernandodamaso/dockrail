import QtQuick
import Qt5Compat.GraphicalEffects
import qs.Commons
import qs.Commons as Commons

Item {
  id: root
  property string iconName: ""
  property url source: ""
  property bool preserveBrand: false
  property bool themeTinted: !root.preserveBrand
  property string sizeToken: "md"
  property string containerVariant: "plain"
  property color tint: Commons.Color.foreground
  property string accessibleName: ""
  property string fallbackText: "?"

  readonly property int glyphSize: root.sizeToken === "xs" ? 12
    : root.sizeToken === "sm" ? 14
    : root.sizeToken === "lg" ? 22
    : root.sizeToken === "xl" ? 28 : 16
  readonly property int containerSize: root.containerVariant === "plain"
    ? root.glyphSize : root.glyphSize + (root.sizeToken === "lg" || root.sizeToken === "xl" ? 12 : 10)
  readonly property bool usesLucide: root.iconName !== "" && String(root.source).length === 0
  readonly property url resolvedSource: root.usesLucide
    ? Qt.resolvedUrl("../../assets/lucide/" + root.iconName + ".svg") : root.source
  readonly property bool failed: String(root.resolvedSource).length === 0 || sourceImage.status === Image.Error
  readonly property bool ready: sourceImage.status === Image.Ready

  implicitWidth: root.containerSize
  implicitHeight: root.containerSize

  Rectangle {
    anchors.fill: parent
    radius: Math.min(8, width / 3)
    visible: root.containerVariant !== "plain"
    color: root.containerVariant === "tile"
      ? Qt.tint(Commons.Color.background, Util.alpha(Commons.Color.accent, 0.22))
      : root.containerVariant === "soft"
        ? Qt.tint(Commons.Color.background, Util.alpha(Commons.Color.foreground, 0.08))
        : "transparent"
    border.width: root.containerVariant === "outlined" ? 1 : 0
    border.color: Util.alpha(Commons.Color.foreground, 0.18)
  }

  Image {
    id: sourceImage
    anchors.centerIn: parent
    width: root.glyphSize
    height: root.glyphSize
    source: root.resolvedSource
    sourceSize: Qt.size(width * 2, height * 2)
    fillMode: Image.PreserveAspectFit
    asynchronous: true
    visible: root.ready && (!root.themeTinted || root.preserveBrand)
    smooth: true
  }

  ColorOverlay {
    anchors.fill: sourceImage
    source: sourceImage
    color: root.tint
    visible: root.ready && root.themeTinted && !root.preserveBrand
  }

  Text {
    anchors.centerIn: parent
    visible: root.failed
    text: root.fallbackText
    textFormat: Text.PlainText
    color: Util.alpha(Commons.Color.foreground, 0.72)
    font.family: Style.font.family
    font.pixelSize: Math.max(10, root.glyphSize - 2)
    font.bold: true
  }

  Accessible.role: Accessible.StaticText
  Accessible.name: root.accessibleName !== "" ? root.accessibleName
    : root.iconName !== "" ? root.iconName + " icon" : "Widget icon"
}