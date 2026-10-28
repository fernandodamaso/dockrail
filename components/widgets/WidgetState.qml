import QtQuick
import qs.Commons
import qs.Commons as Commons

Item {
  id: root
  WidgetSemanticPalette { id: semanticPalette }
  property string kind: "empty"
  property string title: ""
  property string message: ""
  property bool reducedMotion: false
  property bool compact: false
  property string actionText: ""
  // Total vertical inset beyond content (split top/bottom). -1 keeps prior defaults.
  property int verticalPadding: -1
  signal actionTriggered()

  readonly property bool motionActive: root.kind === "loading" && !root.reducedMotion
  readonly property string defaultTitle: root.kind === "loading" ? "Loading"
    : root.kind === "error" ? "Something went wrong"
    : root.kind === "unavailable" ? "Unavailable"
    : root.kind === "stale" ? "Data may be stale" : "Nothing here yet"
  readonly property string iconName: root.kind === "loading" ? "loader-circle"
    : root.kind === "error" ? "circle-alert"
    : root.kind === "unavailable" ? "cloud-off"
    : root.kind === "stale" ? "clock-3" : "inbox"
  readonly property string fallbackText: root.kind === "loading" ? "…"
    : root.kind === "error" ? "!"
    : root.kind === "unavailable" ? "×"
    : root.kind === "stale" ? "↻" : "–"
  readonly property string semantic: root.kind === "error" ? "danger"
    : root.kind === "stale" ? "warning" : root.kind === "loading" ? "info" : "neutral"
  readonly property int resolvedVerticalPadding: root.verticalPadding >= 0
    ? root.verticalPadding
    : Style.space(root.compact ? 8 : 16)

  implicitHeight: content.implicitHeight + root.resolvedVerticalPadding
  clip: true

  Rectangle {
    anchors.fill: parent
    radius: Math.min(7, Style.cornerRadius)
    color: root.kind === "error" ? semanticPalette.surface("danger", 0.063)
      : root.kind === "stale" ? semanticPalette.surface("warning", 0.063)
      : Util.alpha(Commons.Color.foreground, 0.025)
    border.width: 1
    border.color: Util.alpha(Commons.Color.foreground, 0.08)
  }

  Column {
    id: content
    anchors.left: parent.left
    anchors.right: parent.right
    anchors.leftMargin: Style.space(root.compact ? 8 : 12)
    anchors.rightMargin: Style.space(root.compact ? 8 : 12)
    anchors.verticalCenter: parent.verticalCenter
    spacing: Style.space(4)

    WidgetIcon {
      id: stateIcon
      anchors.horizontalCenter: parent.horizontalCenter
      iconName: root.iconName
      sizeToken: root.compact ? "sm" : "md"
      containerVariant: root.compact ? "plain" : "soft"
      tint: semanticPalette.tone(root.semantic)
      accessibleName: root.defaultTitle
      fallbackText: root.fallbackText
    }

    WidgetText {
      width: parent.width
      text: root.title !== "" ? root.title : root.defaultTitle
      role: "label"
      horizontalAlignment: Text.AlignHCenter
      allowWrap: false
    }

    WidgetText {
      visible: root.message !== ""
      width: parent.width
      text: root.message
      role: "caption"
      muted: true
      horizontalAlignment: Text.AlignHCenter
      maxLines: 2
    }

    WidgetButton {
      visible: root.actionText !== ""
      anchors.horizontalCenter: parent.horizontalCenter
      text: root.actionText
      variant: root.kind === "error" ? "danger" : "secondary"
      onClicked: root.actionTriggered()
    }
  }

  RotationAnimation {
    target: stateIcon
    property: "rotation"
    from: 0
    to: 360
    duration: 850
    loops: Animation.Infinite
    running: root.motionActive
  }

  onMotionActiveChanged: if (!root.motionActive) stateIcon.rotation = 0

  Accessible.role: Accessible.StaticText
  Accessible.name: (root.title !== "" ? root.title : root.defaultTitle)
    + (root.message !== "" ? ". " + root.message : "")
}