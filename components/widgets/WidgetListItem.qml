import QtQuick
import qs.Commons
import qs.Commons as Commons

Item {
  id: root
  WidgetSemanticPalette { id: semanticPalette }
  property string iconName: ""
  property url iconSource: ""
  property bool preserveBrandIcon: false
  property string title: ""
  property string subtitle: ""
  property string trailing: ""
  property string attention: "none"
  property string reference: ""
  property bool interactive: false
  property bool reducedMotion: false
  property real attentionOffset: 0
  readonly property bool motionActive: !root.reducedMotion
    && (root.attention === "urgent" || root.attention === "overdue")
  signal triggered()

  activeFocusOnTab: root.interactive
  implicitHeight: Math.max(44, copy.implicitHeight + Style.space(12))
  clip: false

  transform: Translate { x: root.attentionOffset }

  Rectangle {
    anchors.fill: parent
    radius: Math.min(6, Style.cornerRadius)
    color: root.attention === "urgent" || root.attention === "overdue"
      ? semanticPalette.surface("danger", 0.086)
      : hover.hovered && root.interactive ? Util.alpha(Commons.Color.foreground, 0.05) : "transparent"
    border.width: root.activeFocus ? 1 : 0
    border.color: Commons.Color.accent
  }

  HoverHandler { id: hover }

  TapHandler {
    enabled: root.interactive
    onTapped: root.triggered()
  }

  WidgetIcon {
    id: icon
    visible: root.iconName !== "" || String(root.iconSource).length > 0
    anchors.left: parent.left
    anchors.leftMargin: Style.space(6)
    anchors.verticalCenter: parent.verticalCenter
    iconName: root.iconName
    source: root.iconSource
    preserveBrand: root.preserveBrandIcon
    containerVariant: "soft"
    sizeToken: "sm"
  }

  Column {
    id: copy
    anchors.left: icon.visible ? icon.right : parent.left
    anchors.leftMargin: Style.space(7)
    anchors.right: trailingGroup.left
    anchors.rightMargin: Style.space(8)
    anchors.verticalCenter: parent.verticalCenter
    spacing: 2

    WidgetText {
      width: parent.width
      text: root.title
      role: "body"
      allowWrap: false
    }
    WidgetText {
      visible: root.subtitle !== ""
      width: parent.width
      text: root.subtitle
      role: "caption"
      muted: true
      maxLines: 2
    }
  }

  Row {
    id: trailingGroup
    anchors.right: parent.right
    anchors.rightMargin: Style.space(6)
    anchors.verticalCenter: parent.verticalCenter
    spacing: Style.space(4)

    WidgetBadge {
      visible: root.reference !== ""
      text: root.reference
      semantic: root.attention === "urgent" || root.attention === "overdue" ? "danger" : "neutral"
      compact: true
    }

    WidgetText {
      visible: root.trailing !== ""
      text: root.trailing
      role: "caption"
      muted: root.attention === "none"
      color: root.attention === "urgent" || root.attention === "overdue" ? semanticPalette.danger : Commons.Color.foreground
      allowWrap: false
    }
  }

  SequentialAnimation on attentionOffset {
    running: root.motionActive
    loops: Animation.Infinite
    NumberAnimation { to: 3; duration: 75; easing.type: Easing.OutCubic }
    NumberAnimation { to: 0; duration: 90; easing.type: Easing.OutCubic }
    PauseAnimation { duration: 1200 }
  }

  onMotionActiveChanged: if (!root.motionActive) root.attentionOffset = 0

  Keys.onPressed: function(event) {
    if (!root.interactive) return
    if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter || event.key === Qt.Key_Space) {
      root.triggered()
      event.accepted = true
    }
  }

  Accessible.role: root.interactive ? Accessible.Button : Accessible.StaticText
  Accessible.name: root.title + (root.subtitle !== "" ? ". " + root.subtitle : "")
}