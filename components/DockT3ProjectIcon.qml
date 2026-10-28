import QtQuick
import qs.Commons as Commons
import "widgets"

// T3 project identity colors are separate from Dockrail's agent status colors.
Item {
  id: root
  property var icon: null
  readonly property string kind: icon ? String(icon.kind || "") : ""
  readonly property string localSvg: root.kind === "lucide"
    && typeof root.icon.source === "string"
    && root.icon.source.indexOf("data:image/svg+xml;base64,") === 0 ? root.icon.source : ""
  readonly property bool darkBackground:
    0.2126 * Commons.Color.background.r + 0.7152 * Commons.Color.background.g + 0.0722 * Commons.Color.background.b < 0.5
  readonly property var palette: ({
    gray: ["#99a1af", "#4a5565"], red: ["#ff6467", "#e7000b"],
    orange: ["#ff8904", "#f54900"], amber: ["#ffb900", "#e17100"],
    yellow: ["#fdc700", "#d08700"], lime: ["#9ae600", "#5ea500"],
    green: ["#05df72", "#00a63e"], emerald: ["#00d492", "#009966"],
    teal: ["#00d5be", "#009689"], cyan: ["#00d3f2", "#0092b8"],
    sky: ["#00bcff", "#0084d1"], blue: ["#51a2ff", "#155dfc"],
    indigo: ["#7c86ff", "#4f39f6"], violet: ["#a684ff", "#7f22fe"],
    purple: ["#c27aff", "#9810fa"], fuchsia: ["#ed6aff", "#c800de"],
    pink: ["#fb64b6", "#e60076"], rose: ["#ff637e", "#ec003f"]
  })
  readonly property color tint: icon && palette[String(icon.color || "")]
    ? palette[String(icon.color)][darkBackground ? 0 : 1] : Commons.Color.foreground

  implicitWidth: 14
  implicitHeight: 14
  clip: true
  visible: icon !== null
  Accessible.ignored: true

  Rectangle {
    objectName: "t3-project-monogram-background"
    anchors.fill: parent
    visible: root.kind === "monogram"
    radius: Math.min(3, Commons.Style.cornerRadius)
    color: Commons.Util.alpha(root.tint, 0.14)
  }

  Text {
    objectName: "t3-project-text"
    anchors.fill: parent
    visible: root.kind === "emoji" || root.kind === "monogram"
    text: root.kind === "emoji" ? String(root.icon.emoji || "")
      : root.kind === "monogram" ? String(root.icon.text || "") : ""
    textFormat: Text.PlainText
    color: root.tint
    font.family: Commons.Style.font.family
    font.pixelSize: root.kind === "emoji" ? parent.height : parent.height * 0.58
    font.bold: root.kind === "monogram"
    fontSizeMode: Text.HorizontalFit
    minimumPixelSize: 1
    horizontalAlignment: Text.AlignHCenter
    verticalAlignment: Text.AlignVCenter
    renderType: Text.NativeRendering
  }

  Loader {
    anchors.fill: parent
    active: root.localSvg !== ""
    sourceComponent: WidgetIcon {
      objectName: "t3-project-lucide"
      source: root.localSvg
      sizeToken: "sm"
      tint: root.tint
      Accessible.ignored: true
    }
  }
}
