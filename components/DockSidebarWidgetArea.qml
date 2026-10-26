pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Window
import QtQuick.Controls as Controls
import Qt5Compat.GraphicalEffects
import Quickshell
import qs.Commons
import qs.Ui as Ui
import "widgets"
import "DockSidebarWidgetModel.js" as WidgetModel
import "DockSidebarInteractionModel.js" as InteractionModel
import "DockSidebarModel.js" as SidebarModel

// Panel-local presentation only. The controller still owns leases/settings/popup.
Item {
  id: root
  property var appearance: null
  required property var controller
  required property var panel
  required property var viewport
  required property real windowRowHeight
  readonly property real contentInset: (viewport && viewport.workspaceCardInset !== undefined
    ? viewport.workspaceCardInset : Style.space(5)) + Style.space(4)

  readonly property var presentationWidgetIds: {
    var revision = root.controller.widgetRevision
    var ids = root.controller.widgetIds || []
    function fallbackVisibleFor(widgetId, source) {
      var view = root.controller.widgetView(widgetId)
      var snap = view && view.status === "ready" && view.data ? view.data : null
      var filtered = SidebarModel.filterSnapshotBySource(snap, source)
      if (SidebarModel.herdrFallbackVisible(filtered, root.controller.herdrAssociations))
        return true
      if (source === "t3" && filtered && typeof filtered === "object") {
        var matched = SidebarModel.matchedHerdrServerIds(root.controller.herdrAssociations)
        var servers = Array.isArray(filtered.servers) ? filtered.servers : []
        for (var i = 0; i < servers.length; i++) {
          var server = servers[i]
          if (!server || typeof server !== "object") continue
          if (matched[String(server.id || "")] === true) continue
          if (SidebarModel.t3PairingHint(server)) return true
        }
      }
      return false
    }
    var showHerdr = fallbackVisibleFor("herdr.agents", "herdr")
    var showT3 = fallbackVisibleFor("t3.threads", "t3")
    return ids.filter(function(id) {
      if (id === "herdr.agents") return showHerdr
      if (id === "t3.threads") return showT3
      return true
    })
  }
  readonly property int presentedWidgetCount: presentationWidgetIds.length
  readonly property real naturalWidgetHeaderHeight: Math.max(Style.space(32), sectionLabel.implicitHeight) + Style.space(6)
  readonly property real naturalWidgetContentHeight: presentedWidgetCount ? cardColumn.implicitHeight + Style.space(8) : 0
  readonly property bool sectionVisible: !panel.panelCollapsed && presentedWidgetCount > 0
    && height >= naturalWidgetHeaderHeight
  readonly property var scrollView: widgetScroll
  readonly property var manageControl: manageButton
  readonly property var popupWindow: popup
  readonly property var managerWindow: panel.widgetManager ? panel.widgetManager.popupWindow : null
  readonly property var cards: cardRepeater
  readonly property real maximumScroll: Math.max(0, widgetScroll.contentHeight - widgetScroll.height)
  readonly property real fadeHeight: Math.min(28, widgetScroll.height)
  readonly property bool remainingBelow: widgetScroll.contentY + widgetScroll.height < widgetScroll.contentHeight - 0.5
  property int layoutRevision: 0
  property int anchorRevision: 0
  property string dragWidgetId: ""
  property var dragOrder: []
  property int dragTargetSlot: -1
  property real dragSceneX: 0
  property real dragSceneY: 0
  property var savedAnchor: ({})
  property bool pendingRestore: true
  property bool restoring: false
  property bool wheelActive: false
  property real lastContentY: 0
  property Item pendingFocusedItem: null
  property string focusedWidgetId: ""
  property Item lastFocusedControl: null
  property bool ownsWidgetFocus: false
  property var focusRecovery: null
  readonly property bool inputBusy: wheelActive || widgetScroll.moving || verticalScrollBar.pressed || dragWidgetId !== ""
  // Read ancestor geometry, not just contentY: hierarchy/font changes move us.
  readonly property point panelOrigin: {
    var item = root, x = 0, y = 0
    while (item && item !== root.panel.contentItem) { x += item.x; y += item.y; item = item.parent }
    return Qt.point(x, y)
  }
  visible: sectionVisible
  implicitHeight: naturalWidgetHeaderHeight + naturalWidgetContentHeight

  function cardRects() {
    var out = []
    for (var i = 0; i < cardRepeater.count; ++i) {
      var card = cardRepeater.itemAt(i)
      if (card) out.push({id:card.widgetId, y:card.y, height:card.height})
    }
    return out
  }
  function cardFor(item) {
    while (item && item !== root) {
      if (item.parent === cardColumn && item.widgetId !== undefined) return item
      item = item.parent
    }
    return null
  }
  function containsItem(parentItem, item) {
    while (item) { if (item === parentItem) return true; item = item.parent }
    return false
  }
  function effectivelyVisible(item) {
    while (item) {
      if (!item.visible || item.opacity === 0) return false
      if (item === root.panel.contentItem) return true
      item = item.parent
    }
    return false
  }
  function captureAnchor() {
    if (root.restoring || root.pendingRestore || !root.sectionVisible || widgetScroll.height <= 0) return
    root.savedAnchor = WidgetModel.widgetScrollAnchor(root.cardRects(), widgetScroll.contentY)
  }
  function requestLayout() {
    root.pendingRestore = true
    layoutTimer.restart()
    geometryTimer.restart()
  }
  function settleLayout() {
    cardColumn.forceLayout()
    if (!root.sectionVisible || widgetScroll.height <= 0) { root.recoverFocus(); return }
    if (root.inputBusy) return
    root.restoring = true
    widgetScroll.contentY = WidgetModel.widgetScrollPosition(root.savedAnchor, root.cardRects(), root.maximumScroll)
    root.lastContentY = widgetScroll.contentY
    root.restoring = false
    root.pendingRestore = false
    root.captureAnchor()
    root.recoverFocus()
    if (root.pendingFocusedItem) {
      var item = root.pendingFocusedItem
      root.pendingFocusedItem = null
      root.ensureFocusedItemVisible(item)
    }
  }
  function ensureFocusedItemVisible(item) {
    if (!item || !root.cardFor(item) || widgetScroll.height <= 0) return
    if (root.pendingRestore || root.inputBusy) { root.pendingFocusedItem = item; layoutTimer.restart(); return }
    var point = cardColumn.mapFromItem(item, 0, 0)
    widgetScroll.contentY = WidgetModel.widgetFocusScroll(point.y, item.height,
      widgetScroll.contentY, widgetScroll.height, root.maximumScroll)
    root.captureAnchor()
  }
  function trackFocus() {
    var item = root.Window.window ? root.Window.window.activeFocusItem : null
    var card = root.cardFor(item)
    if (card) {
      root.ownsWidgetFocus = true
      root.focusedWidgetId = card.widgetId
      root.lastFocusedControl = item
      root.ensureFocusedItemVisible(item)
    } else if (root.Window.window && item === root.Window.window.contentItem && root.ownsWidgetFocus
        && (root.focusRecovery || !root.lastFocusedControl || !root.lastFocusedControl.visible)) {
      if (!root.focusRecovery) root.focusRecovery = {id:root.focusedWidgetId, ids:root.savedAnchor.ids || []}
      root.requestLayout()
    } else if (item) {
      root.ownsWidgetFocus = false
      root.focusedWidgetId = ""
    }
  }
  function recoverFocus() {
    if (!root.focusRecovery) return
    var recovery = root.focusRecovery
    root.focusRecovery = null
    if (!root.ownsWidgetFocus || !root.panel.visible) return
    var rects = root.cardRects(), ids = rects.map(function(r) { return r.id })
    var old = recovery.ids || [], at = old.indexOf(recovery.id), chosen = ids.indexOf(recovery.id)
    for (var i = at + 1; i < old.length && chosen < 0; ++i) chosen = ids.indexOf(old[i])
    for (var j = at - 1; j >= 0 && chosen < 0; --j) chosen = ids.indexOf(old[j])
    var target = root.sectionVisible && widgetScroll.height > 0 && chosen >= 0
      ? cardRepeater.itemAt(chosen) : root.sectionVisible ? manageButton : root.panel.widgetManageControl
    if (target) {
      if (target.collapsed === true) target.focusCollapseControl()
      else target.forceActiveFocus(Qt.TabFocusReason)
    }
  }
  function focusSectionBoundary(backwards) {
    if (backwards) return root.viewport.focusLastRow()
    if (widgetScroll.height > 0 && cardRepeater.count) {
      cardRepeater.itemAt(0).forceActiveFocus(Qt.TabFocusReason)
      return true
    }
    var target = root.panel.footerControl
    if (!target) return false
    target.forceActiveFocus(Qt.TabFocusReason)
    return true
  }
  function prepareCollapse(card) {
    var item = root.Window.window ? root.Window.window.activeFocusItem : null
    if (!card.collapsed && card.hasCardFocus && item !== card) card.focusCollapseControl()
  }
  function ownsPopupAnchor() { return root.containsItem(root, root.controller.widgetPopupAnchor) }
  function itemIntersectsViewport(item) {
    // Coordinate mapping alone does not establish a scroll dependency.
    var revision = root.layoutRevision
    if (!root.sectionVisible || !root.panel.visible || widgetScroll.height <= 0 || !item) return false
    var point = widgetScroll.mapFromItem(item, 0, 0)
    return point.x + item.width > 0 && point.x < widgetScroll.width
      && point.y + item.height > 0 && point.y < widgetScroll.height
  }
  function anchorInsideViewport(anchor) { return root.containsItem(widgetScroll.contentItem, anchor) }
  function anchorOutsideViewport(anchor) { return root.anchorInsideViewport(anchor) && !root.itemIntersectsViewport(anchor) }
  function popupGeometryFor(anchor, wantedWidth, wantedHeight) {
    var point = anchor && panel.contentItem ? panel.contentItem.mapFromItem(anchor, 0, anchor.height / 2) : {y:0}
    return WidgetModel.popupGeometry(panel.screen ? panel.screen.width : 1,
      Math.min(panel.height, panel.screen ? panel.screen.height : panel.height), panel.width,
      controller.edge, point.y, wantedWidth, wantedHeight)
  }
  readonly property var popupGeometry: {
    var revision = root.layoutRevision
    return root.popupGeometryFor(root.ownsPopupAnchor() ? root.controller.widgetPopupAnchor : null, 320, 400)
  }
  function closePopup() { if (root.ownsPopupAnchor()) root.controller.closeWidgetPopup() }
  function openWidget(id, anchor) {
    root.closeManager()
    if (root.ownsPopupAnchor() && root.controller.widgetPopupId === id) root.closePopup()
    else root.controller.openWidgetPopup(id, anchor)
  }
  function openManager(anchor) {
    root.closePopup()
    if (!root.panel || typeof root.panel.openWidgetManager !== "function") return false
    return root.panel.openWidgetManager(anchor)
  }
  function closeManager() {
    if (root.panel && root.panel.widgetManager && typeof root.panel.widgetManager.close === "function")
      root.panel.widgetManager.close()
  }
  function updatePopupAnchor() {
    if (!root.controller.widgetPopupId || !root.ownsPopupAnchor()) return
    var anchor = root.controller.widgetPopupAnchor
    if (!root.effectivelyVisible(anchor) || !root.panel.visible || root.anchorOutsideViewport(anchor)) {
      root.closePopup(); return
    }
    popup.anchor.updateAnchor()
  }
  function dragPointInBody(sceneX, sceneY) {
    var p = widgetScroll.mapFromItem(null, sceneX, sceneY)
    return root.sectionVisible && widgetScroll.height > 0
      && p.x >= 0 && p.x < widgetScroll.width && p.y >= 0 && p.y < widgetScroll.height
  }
  function slotForSceneY(sceneY) {
    var point = cardColumn.mapFromItem(null, root.dragSceneX, sceneY)
    for (var i = 0; i < root.presentedWidgetCount; ++i) {
      var card = cardRepeater.itemAt(i)
      if (card && point.y < card.y + card.height / 2) return i
    }
    return root.presentedWidgetCount
  }
  function fullReorderSlot(presentationSlot) {
    var ids = root.presentationWidgetIds, fullIds = root.controller.widgetIds || []
    if (ids.length === fullIds.length) return presentationSlot
    if (presentationSlot >= ids.length) {
      var last = ids.length ? fullIds.indexOf(ids[ids.length - 1]) : -1
      return last < 0 ? fullIds.length : last + 1
    }
    var target = fullIds.indexOf(ids[presentationSlot])
    return target < 0 ? fullIds.length : target
  }
  function beginDrag(id, sceneX, sceneY) {
    if (!root.dragPointInBody(sceneX, sceneY) || root.presentationWidgetIds.indexOf(id) < 0) return false
    root.closeManager()
    root.captureAnchor()
    if (!root.controller.beginWidgetReorder(id)) return false
    root.dragOrder = root.presentationWidgetIds.slice()
    root.dragWidgetId = id
    root.updateDrag(sceneX, sceneY)
    return true
  }
  function updateDrag(sceneX, sceneY) {
    if (!root.dragWidgetId) return
    root.dragSceneX = sceneX; root.dragSceneY = sceneY
    root.dragTargetSlot = root.dragPointInBody(sceneX, sceneY) ? root.slotForSceneY(sceneY) : -1
  }
  function syncDragFromController() {
    if (root.controller.widgetDragId) return
    root.dragWidgetId = ""; root.dragTargetSlot = -1
  }
  function finishDrag(sceneX, sceneY, cancelled) {
    if (!root.dragWidgetId) return
    var valid = cancelled !== true && root.dragPointInBody(sceneX, sceneY)
      && JSON.stringify(root.dragOrder) === JSON.stringify(root.presentationWidgetIds)
      && root.controller.widgetDragId === root.dragWidgetId
    if (valid) root.updateDrag(sceneX, sceneY)
    var slot = root.dragTargetSlot
    root.dragWidgetId = ""; root.dragTargetSlot = -1
    root.controller.finishWidgetReorder(root.fullReorderSlot(slot), !valid || slot < 0)
    root.requestLayout()
  }
  function lastTabStop(item) {
    if (!item || !item.visible || !item.enabled) return null
    var last = item.activeFocusOnTab ? item : null
    for (var i = 0; item.children && i < item.children.length; ++i) {
      var child = root.lastTabStop(item.children[i])
      if (child) last = child
    }
    return last
  }
  function focusLastControl() {
    if (!root.sectionVisible) return false
    var target = widgetScroll.height > 0 && cardRepeater.count
      ? root.lastTabStop(cardRepeater.itemAt(cardRepeater.count - 1)) : manageButton
    if (!target) target = manageButton
    target.forceActiveFocus(Qt.BacktabFocusReason)
    return true
  }

    Item {
      id: sectionHeader
      width: parent.width
      height: Math.max(Style.space(32), sectionLabel.implicitHeight)

      Ui.PanelSectionHeader {
        id: sectionLabel
        objectName: "widget-section-label"
        anchors.left: parent.left
        anchors.leftMargin: root.contentInset
        anchors.verticalCenter: parent.verticalCenter
        text: "WIDGETS"
      }

      Ui.Button {
        id: manageButton
        objectName: "widget-section-manage"
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        width: Style.space(28)
        height: Style.space(28)
        iconText: ""
        tooltipText: "Add or manage Widgets"
        Accessible.role: Accessible.Button
        Accessible.name: tooltipText
        focusable: true
        onClicked: root.openManager(manageButton)
        Keys.onBacktabPressed: function(event) { event.accepted = root.focusSectionBoundary(true) }
        Keys.onTabPressed: function(event) { event.accepted = root.focusSectionBoundary(false) }

        WidgetIcon {
          objectName: "widget-section-plus"
          anchors.centerIn: parent
          width: 13
          height: 13
          iconName: "plus"
          sizeToken: "xs"
          containerVariant: "plain"
          tint: Color.foreground
          accessibleName: manageButton.tooltipText
        }
      }
    }
  Flickable {
    id: widgetScroll
    objectName: "sidebar-widget-scroll"
    y: root.naturalWidgetHeaderHeight
    width: parent.width
    height: root.sectionVisible ? Math.max(0, root.height - y) : 0
    visible: height > 0
    clip: true
    contentWidth: width
    contentHeight: root.naturalWidgetContentHeight
    boundsBehavior: Flickable.StopAtBounds
    flickableDirection: Flickable.VerticalFlick
    onContentYChanged: {
      if (root.pendingRestore && root.inputBusy && !root.restoring && root.savedAnchor.id) {
        var delta = contentY - Math.max(0, Math.min(root.maximumScroll, root.lastContentY))
        root.savedAnchor = Object.assign({}, root.savedAnchor, {offset:root.savedAnchor.offset + delta})
      }
      root.lastContentY = contentY
      root.captureAnchor()
      geometryTimer.restart()
    }
    onContentHeightChanged: root.requestLayout()
    onMovementEnded: { if (root.pendingRestore) layoutTimer.restart(); else root.captureAnchor() }
    WheelHandler {
      target: null
      blocking: false
      onWheel: function(event) {
        root.wheelActive = true
        wheelIdle.restart()
        // Nonblocking observation: children retain first refusal/native wheel actions.
        event.accepted = false
      }
    }
    // Alpha mask, not another surface tint; no input item overlays the content.
    layer.enabled: root.remainingBelow && height > 0 && GraphicsInfo.api !== GraphicsInfo.Software
    layer.effect: OpacityMask {
      maskSource: Rectangle {
        width: widgetScroll.width; height: widgetScroll.height
        gradient: Gradient {
          GradientStop { position: Math.max(0, 1 - root.fadeHeight / Math.max(1, widgetScroll.height)); color: "white" }
          GradientStop { position: 1; color: "transparent" }
        }
      }
    }
    Controls.ScrollBar.vertical: Controls.ScrollBar {
      id: verticalScrollBar
      parent: root
      x: root.width - width + root.viewport.scrollBarOutset
      y: widgetScroll.y
      width: root.viewport.scrollGutter
      height: widgetScroll.height
      padding: 0
      policy: widgetScroll.contentHeight > widgetScroll.height && widgetScroll.height > 0
        ? Controls.ScrollBar.AsNeeded : Controls.ScrollBar.AlwaysOff
      contentItem: Rectangle {
        implicitWidth: root.viewport.scrollGutter
        implicitHeight: 40
        radius: width / 2
        color: Util.alpha(Color.foreground, verticalScrollBar.pressed ? 0.45 : verticalScrollBar.hovered ? 0.32 : 0.18)
      }
      background: Item { implicitWidth: root.viewport.scrollGutter }
    }
    Column {
      id: cardColumn
      width: parent.width
      spacing: Style.space(6)

      Repeater {
        id: cardRepeater
        model: root.presentationWidgetIds
        onItemAdded: root.requestLayout()
        onItemRemoved: root.requestLayout()

        delegate: DockWidgetCard {
          id: widgetCard
          appearance: root.appearance
          contentInset: root.contentInset
          required property string modelData
          required property int index
          width: cardColumn.width
          controller: root.controller
          widgetId: modelData
          collapsed: root.controller.widgetCollapsedFor(modelData)
          interfaceAnimationsEnabled: root.controller.settings
            && root.controller.settings.interfaceAnimationsEnabled !== false
          presentationVisible: root.sectionVisible && root.panel.visible && root.itemIntersectsViewport(widgetCard)
          presentationClipItem: widgetScroll
          presentationRevision: root.layoutRevision
          bodyNavigationEnabled: widgetScroll.height > 0
          dropBefore: root.dragWidgetId !== "" && root.dragTargetSlot === index
          dropAfter: root.dragWidgetId !== ""
            && root.dragTargetSlot === root.presentationWidgetIds.length
            && index === root.presentationWidgetIds.length - 1
          onToggleRequested: {
            root.prepareCollapse(widgetCard)
            root.controller.toggleWidgetCollapsed(modelData)
          }
          onCollapsedChanged: {
            if (collapsed && root.ownsWidgetFocus && root.focusedWidgetId === widgetId)
              widgetCard.focusCollapseControl()
          }
          onHeightChanged: root.requestLayout()
          onYChanged: root.requestLayout()
          onRemoveRequested: root.controller.setWidgetEnabled(modelData, false)
          onDragStarted: function(sceneX, sceneY) {
            if (!root.beginDrag(modelData, sceneX, sceneY))
              dragActive = false
          }
          onDragMoved: function(sceneX, sceneY) { root.updateDrag(sceneX, sceneY) }
          onDragFinished: function(sceneX, sceneY, cancelled) {
            root.finishDrag(sceneX, sceneY, cancelled)
          }
        }
      }
    }
  }

  PopupWindow {
    id: popup
    visible: root.ownsPopupAnchor() && root.controller.widgetPopupId !== "" && root.panel.visible
    color: "transparent"
    grabFocus: false
    implicitWidth: root.popupGeometry.width
    implicitHeight: root.popupGeometry.height

    anchor {
      window: root.panel
      adjustment: PopupAdjustment.Slide
      edges: Edges.Top | Edges.Left
      gravity: Edges.Bottom | Edges.Right
      rect.width: 1
      rect.height: 1
      onAnchoring: {
        popup.anchor.rect.x = Math.round(root.popupGeometry.x)
        popup.anchor.rect.y = Math.round(root.popupGeometry.y)
      }
    }

    onVisibleChanged: {
      geometryTimer.restart()
    }

    Ui.BorderSurface {
      id: popupSurface
      anchors.fill: parent
      color: Color.menu.background
      borderSpec: Border.surfaceSpec("menu", "border", Color.menu.border, Style.normalBorderWidth)
      clip: true

      Ui.Button {
        id: popupClose
        x: popupSurface.contentLeftInset
        y: popupSurface.contentTopInset
        width: Math.max(0, parent.width - popupSurface.contentLeftInset - popupSurface.contentRightInset)
        height: Math.min(root.windowRowHeight, popup.height)
        text: "Close"
        focusable: false
        Accessible.role: Accessible.Button
        Accessible.name: "Close Widget popup"
        onClicked: root.closePopup()
      }

      Flickable {
        id: popupScroll
        anchors.top: popupClose.bottom
        anchors.bottom: parent.bottom
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.leftMargin: popupSurface.contentLeftInset
        anchors.rightMargin: popupSurface.contentRightInset
        anchors.bottomMargin: popupSurface.contentBottomInset
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        flickableDirection: Flickable.VerticalFlick
        contentWidth: width
        contentHeight: popupContent.implicitHeight

        Column {
          id: popupContent
          width: parent.width

          DockSidebarWidgetView {
            id: popupView
            controller: root.controller
            widgetId: root.controller.widgetPopupId
            presentation: "popup"
            popupAnchor: root.controller.widgetPopupAnchor
            viewEnabled: popup.visible
            interfaceAnimationsEnabled: root.controller.settings
              && root.controller.settings.interfaceAnimationsEnabled !== false
            presentationVisible: popup.visible
            presentationClipItem: popupScroll
            presentationRevision: popupScroll.contentY
            width: parent.width
            height: implicitHeight
          }

          Text {
            visible: popup.visible && !popupView.hasView
            height: visible ? implicitHeight : 0
            width: parent.width
            text: popupView.snapshot ? String(popupView.snapshot.status || "unavailable") : "Unavailable"
            textFormat: Text.PlainText
            color: Color.foreground
            font.family: Style.font.family
            font.pixelSize: Style.font.body
            wrapMode: Text.Wrap
          }
        }
      }
    }
  }
  Timer { id: layoutTimer; interval: 0; onTriggered: root.settleLayout() }
  Timer {
    id: geometryTimer
    interval: 0
    onTriggered: {
      root.layoutRevision = (root.layoutRevision + 1) % 1000000000
      root.anchorRevision = root.layoutRevision
      root.updatePopupAnchor()
    }
  }
  Timer { id: wheelIdle; interval: 150; onTriggered: root.wheelActive = false }
  Timer {
    interval: 16; repeat: true
    running: root.dragWidgetId !== ""
    onTriggered: {
      if (!root.dragPointInBody(root.dragSceneX, root.dragSceneY)) return
      var point = widgetScroll.mapFromItem(null, root.dragSceneX, root.dragSceneY)
      var delta = InteractionModel.autoScrollStep(point.y, widgetScroll.height)
      if (!delta) return
      widgetScroll.contentY = Math.max(0, Math.min(root.maximumScroll, widgetScroll.contentY + delta))
      root.updateDrag(root.dragSceneX, root.dragSceneY)
    }
  }
  Connections {
    target: root.Window.window
    function onActiveFocusItemChanged() { root.trackFocus() }
  }
  Connections {
    target: root.controller
    function onWidgetAnchorChanged() { geometryTimer.restart() }
    function onWidgetDragIdChanged() { root.syncDragFromController() }
    function onSurfaceInvalidated() { root.closePopup(); root.closeManager(); root.finishDrag(0, 0, true) }
    function onEdgeChanged() { root.finishDrag(0, 0, true); geometryTimer.restart() }
  }
  Connections {
    target: root.panel
    function onWidthChanged() { root.requestLayout() }
    function onHeightChanged() { root.requestLayout() }
    function onScreenChanged() { root.finishDrag(0, 0, true); geometryTimer.restart() }
    function onVisibleChanged() {
      if (!root.panel.visible) { root.closePopup(); root.closeManager(); root.finishDrag(0, 0, true) }
      root.requestLayout()
    }
    function onPanelCollapsedChanged() {
      if (root.panel.panelCollapsed) { root.closePopup(); root.closeManager(); root.finishDrag(0, 0, true) }
      root.requestLayout()
    }
  }
  Keys.onPressed: function(event) {
    if (event.key === Qt.Key_Escape && root.dragWidgetId) {
      root.finishDrag(0, 0, true); event.accepted = true
    }
  }
  onPresentationWidgetIdsChanged: {
    if (root.dragWidgetId && JSON.stringify(root.dragOrder) !== JSON.stringify(root.presentationWidgetIds))
      root.finishDrag(0, 0, true)
    if (root.ownsWidgetFocus && root.focusedWidgetId && root.presentationWidgetIds.indexOf(root.focusedWidgetId) < 0)
      root.focusRecovery = {id:root.focusedWidgetId, ids:root.savedAnchor.ids || []}
    root.requestLayout()
  }
  onSectionVisibleChanged: {
    if (!sectionVisible) { root.closePopup(); root.finishDrag(0, 0, true) }
    root.requestLayout()
  }
  onInputBusyChanged: if (!inputBusy && root.pendingRestore) layoutTimer.restart()
  onNaturalWidgetHeaderHeightChanged: root.requestLayout()
  onPanelOriginChanged: geometryTimer.restart()
  onWidthChanged: root.requestLayout()
  onHeightChanged: root.requestLayout()
  Component.onCompleted: root.requestLayout()
  Component.onDestruction: { root.finishDrag(0, 0, true); root.closePopup() }
}
