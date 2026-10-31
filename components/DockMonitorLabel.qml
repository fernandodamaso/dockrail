pragma ComponentBehavior: Bound

import QtQuick
import qs.Commons
import qs.Ui

Item {
  id: root

  required property string label
  required property string description
  required property string connector
  required property bool focused
  required property string position
  required property int slotSize
  property int monitorNumber: 1

  readonly property string displayText: {
    var value = String(root.label || "").trim()
    if (value) return value
    var fallback = String(root.connector || "").trim()
    return fallback || "Monitor"
  }
  readonly property string accessibilityText: {
    var details = String(root.description || "").trim() || root.displayText
    var connectorText = String(root.connector || "").trim()
    if (!connectorText || connectorText === details) return details
    return details + " — " + connectorText
  }

  readonly property real contentWidth: monitorGlyph.width
    + Style.spacing.labelGap + monitorIndex.implicitWidth

  implicitWidth: Math.ceil(contentWidth)
  width: implicitWidth
  height: root.slotSize + 10

  Accessible.role: Accessible.StaticText
  Accessible.name: root.accessibilityText

  OpticalGlyph {
    id: monitorGlyph

    anchors.left: parent.left
    anchors.verticalCenter: parent.verticalCenter
    width: Math.ceil(Style.font.body * 1.35)
    height: width
    text: "󰍺"
    fontSize: Style.font.body
    color: root.focused ? Color.foreground : Color.muted
  }

  Text {
    id: monitorIndex

    anchors.left: monitorGlyph.right
    anchors.leftMargin: Style.spacing.labelGap
    anchors.verticalCenter: parent.verticalCenter
    textFormat: Text.PlainText
    text: root.monitorNumber > 0 ? String(root.monitorNumber) : "?"
    color: root.focused ? Color.foreground : Color.muted
    font.family: Style.font.family
    font.pixelSize: Style.font.body
    font.weight: Font.DemiBold
    renderType: Text.NativeRendering
  }
}
