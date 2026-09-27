pragma ComponentBehavior: Bound
import QtQuick
import qs.Commons
import qs.Ui as Ui
import "DockSidebarWidgetModel.js" as WidgetModel

// Panel-owned Widget management popup. This intentionally lives outside the
// independent Widget pane so Add/Manage remains available even when there are
// zero enabled Widget cards and the section collapses to zero height.
Item {
  id: root

  required property var controller
  required property var panel
  required property var viewport

  readonly property var popupWindow: managerPopup
  readonly property var registeredRows: WidgetModel.manageableRows(
    controller.widgetRegistry, controller.widgetIds)

  property bool managerOpen: false
  property Item managerAnchor: null
  readonly property bool managerAnchorVisible: {
    var item = root.managerAnchor
    while (item) {
      if (!item.visible || item.opacity === 0) return false
      if (item === root.panel.contentItem) return true
      item = item.parent
    }
    return false
  }
  readonly property point managerAnchorPosition: {
    var item = root.managerAnchor, x = 0, y = 0
    while (item && item !== root.panel.contentItem) { x += item.x; y += item.y; item = item.parent }
    return Qt.point(x, y)
  }
  onManagerAnchorPositionChanged: anchorTimer.restart()
  onManagerAnchorVisibleChanged: anchorTimer.restart()

  width: 0
  height: 0

  function anchorInsideViewport(anchor) {
    for (var item = anchor; item; item = item.parent) {
      if (item === root.viewport) return true
    }
    return false
  }

  function anchorOutsideViewport(anchor) {
    if (!root.anchorInsideViewport(anchor)) return false
    var point = root.viewport.mapFromItem(anchor, 0, 0)
    return point.y + anchor.height <= 0 || point.y >= root.viewport.height
  }

  function openFor(anchor) {
    if (root.panel.panelCollapsed || !anchor || !anchor.visible) return false
    if (root.managerOpen && root.managerAnchor === anchor) {
      root.close()
      return true
    }
    root.managerAnchor = anchor
    root.managerOpen = true
    anchorTimer.restart()
    return true
  }

  function close() {
    root.managerOpen = false
    root.managerAnchor = null
  }

  function updateAnchor() {
    if (!root.managerOpen) return
    var anchor = root.managerAnchor
    if (!anchor || !root.managerAnchorVisible || !root.panel.visible || root.panel.panelCollapsed
        || root.anchorOutsideViewport(anchor)) {
      root.close()
      return
    }
    managerPopup.anchor.updateAnchor()
  }

  onManagerAnchorChanged: {
    if (root.managerOpen && !root.managerAnchor) root.close()
  }

  QtObject {
    id: popupBar
    property string position: root.controller && root.controller.edge
      ? root.controller.edge : "left"
    property var activePopout: null

    function requestPopout(owner) {
      activePopout = owner
    }

    function releasePopout(owner) {
      if (activePopout === owner) activePopout = null
    }
  }

  Ui.PopupCard {
    id: managerPopup
    anchorItem: root.managerAnchor
    owner: root
    bar: popupBar
    open: root.managerOpen && root.panel.visible && !root.panel.panelCollapsed
    // Native click mode activates Omarchy's focus grab so an outside click
    // dismisses the popup through owner.close().
    triggerMode: "click"
    contentWidth: managerPopup.fittedContentWidth(Style.space(300))
    contentHeight: managerPopup.fittedContentHeight(
      managerIntro.implicitHeight
        + managerDivider.implicitHeight
        + managerLayout.spacing * 2
        + Math.min(managerRows.implicitHeight, Style.space(280)),
      Style.space(420))

    onOpenChanged: if (open) anchorTimer.restart()

    Column {
      id: managerLayout
      anchors.fill: parent
      spacing: Style.space(8)

      Item {
        id: managerIntro
        width: parent.width
        height: implicitHeight
        implicitHeight: Math.max(managerIntroText.implicitHeight, managerClose.implicitHeight)

        Column {
          id: managerIntroText
          anchors.left: parent.left
          anchors.right: managerClose.left
          anchors.rightMargin: Style.space(8)
          anchors.verticalCenter: parent.verticalCenter
          spacing: Style.space(2)

          Text {
            width: parent.width
            text: "Widgets"
            textFormat: Text.PlainText
            color: Color.foreground
            font.family: Style.font.family
            font.pixelSize: Style.font.body
            font.bold: true
            elide: Text.ElideRight
          }

          Text {
            width: parent.width
            text: "Choose what appears in the sidebar."
            textFormat: Text.PlainText
            color: Qt.darker(Color.foreground, 1.4)
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
            wrapMode: Text.WordWrap
          }
        }

        Ui.Button {
          id: managerClose
          anchors.right: parent.right
          anchors.verticalCenter: parent.verticalCenter
          width: Style.space(26)
          height: Style.space(26)
          iconText: ""
          tooltipText: "Close"
          Accessible.role: Accessible.Button
          Accessible.name: "Close Widget manager"
          focusable: true
          onClicked: root.close()

          DockLucideIcon {
            anchors.centerIn: parent
            width: 14
            height: 14
            iconName: "x"
            iconSize: 14
            tint: Color.foreground
          }
        }
      }

      Ui.PanelSeparator {
        id: managerDivider
        width: parent.width
      }

      Flickable {
        id: managerScroll
        width: parent.width
        height: Math.max(0, managerLayout.height
          - managerIntro.height - managerDivider.height - managerLayout.spacing * 2)
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        flickableDirection: Flickable.VerticalFlick
        interactive: contentHeight > height
        contentWidth: width
        contentHeight: managerRows.implicitHeight

        Column {
          id: managerRows
          width: managerScroll.width
          spacing: Style.space(2)

          Text {
            visible: root.registeredRows.length === 0
            width: parent.width
            text: "No optional Widgets are available in this build."
            textFormat: Text.PlainText
            color: Qt.darker(Color.foreground, 1.5)
            font.family: Style.font.family
            font.pixelSize: Style.font.bodySmall
            font.italic: true
            wrapMode: Text.WordWrap
            Accessible.role: Accessible.StaticText
            Accessible.name: text
          }

          Repeater {
            model: root.registeredRows

            delegate: Ui.CursorSurface {
              id: managerRow
              required property var modelData
              width: managerRows.width
              height: Style.space(36)
              readonly property bool enabledWidget:
                root.controller.widgetIds.indexOf(modelData.id) >= 0
              readonly property bool canToggle: enabledWidget || modelData.available
              enabled: canToggle
              opacity: canToggle ? 1.0 : 0.5
              hasCursor: canToggle && (managerMouse.containsMouse || activeFocus)
              activeFocusOnTab: canToggle
              Accessible.role: Accessible.Button
              Accessible.name: (enabledWidget ? "Remove " : "Add ")
                + modelData.label + (enabledWidget ? " from Widgets" : " to Widgets")
              Keys.onReturnPressed: if (canToggle)
                root.controller.setWidgetEnabled(modelData.id, !enabledWidget)
              Keys.onEnterPressed: if (canToggle)
                root.controller.setWidgetEnabled(modelData.id, !enabledWidget)
              Keys.onSpacePressed: if (canToggle)
                root.controller.setWidgetEnabled(modelData.id, !enabledWidget)

              DockLucideIcon {
                id: managerIcon
                anchors.left: parent.left
                anchors.leftMargin: Style.space(8)
                anchors.verticalCenter: parent.verticalCenter
                width: 18
                height: 18
                iconName: managerRow.modelData.iconName
                iconSize: 18
                tint: Color.foreground
              }

              Text {
                anchors.left: managerIcon.right
                anchors.leftMargin: Style.space(8)
                anchors.right: unavailableLabel.visible
                  ? unavailableLabel.left : managerSwitch.left
                anchors.rightMargin: Style.space(8)
                anchors.verticalCenter: parent.verticalCenter
                text: managerRow.modelData.label
                textFormat: Text.PlainText
                color: Color.foreground
                font.family: Style.font.family
                font.pixelSize: Style.font.bodySmall
                elide: Text.ElideRight
              }

              Text {
                id: unavailableLabel
                visible: !managerRow.modelData.available
                anchors.right: managerSwitch.left
                anchors.rightMargin: Style.space(8)
                anchors.verticalCenter: parent.verticalCenter
                text: "Unavailable"
                textFormat: Text.PlainText
                color: Qt.darker(Color.foreground, 1.5)
                font.family: Style.font.family
                font.pixelSize: Style.font.caption
              }

              Ui.ToggleSwitch {
                id: managerSwitch
                anchors.right: parent.right
                anchors.rightMargin: Style.space(6)
                anchors.verticalCenter: parent.verticalCenter
                checked: managerRow.enabledWidget
                interactive: false
                foreground: Color.foreground
                accent: Color.accent
              }

              MouseArea {
                id: managerMouse
                anchors.fill: parent
                enabled: managerRow.canToggle
                hoverEnabled: true
                cursorShape: enabled ? Qt.PointingHandCursor : Qt.ArrowCursor
                onClicked: {
                  managerRow.forceActiveFocus()
                  root.controller.setWidgetEnabled(
                    managerRow.modelData.id, !managerRow.enabledWidget)
                }
              }
            }
          }
        }
      }
    }
  }

  Connections {
    target: root.viewport.listView
    function onContentYChanged() {
      anchorTimer.restart()
    }
  }

  Connections {
    target: root.panel
    function onWidthChanged() {
      anchorTimer.restart()
    }
    function onHeightChanged() {
      anchorTimer.restart()
    }
    function onVisibleChanged() {
      if (!root.panel.visible) root.close()
    }
    function onPanelCollapsedChanged() {
      if (root.panel.panelCollapsed) root.close()
    }
  }

  Timer { id: anchorTimer; interval: 0; onTriggered: root.updateAnchor() }
  Connections {
    target: root.panel.widgetArea || null
    function onLayoutRevisionChanged() { anchorTimer.restart() }
    function onSectionVisibleChanged() { anchorTimer.restart() }
  }
  Component.onDestruction: root.close()
}
