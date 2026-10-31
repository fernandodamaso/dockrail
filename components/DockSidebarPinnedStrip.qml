pragma ComponentBehavior: Bound
import QtQuick
import Quickshell
import QtQuick.Shapes
import qs.Commons
import qs.Commons as Commons
import qs.Ui as Ui
import "DockSidebarInteractionModel.js" as InteractionModel

// Stable bottom pin shelf (Direction A). Settings.pinned order, including
// running apps (focus-or-launch). Overflow keeps the add action on one row.
//
// Projection rebuilds replace the launchers array. A local ListModel keeps
// exiting rows alive for the existing opacity/scale transitions.
Item {
  id: root
  required property var controller
  required property var panel
  required property var appearance
  readonly property var pins: controller.projection.launchers || []
  readonly property bool collapsed: panel && panel.panelCollapsed === true
  readonly property bool animationsEnabled:
    controller.settings.interfaceAnimationsEnabled !== false
  readonly property int animMs: animationsEnabled ? 180 : 0
  readonly property real iconSize: 22
  readonly property real cell: 32
  readonly property real cellHeight: 36
  readonly property real pinGap: Style.space(7)
  readonly property real shelfPadTop: Style.space(3)
  readonly property real shelfPadBottom: Style.space(5)
  readonly property var layout: InteractionModel.pinnedStripLayout(
    width, pins.length, cell, cell, pinGap)
  readonly property int visibleCount: layout.visible
  readonly property int hiddenCount: layout.hidden
  readonly property var hiddenPins: pins.slice(visibleCount)
  // Rail hides the strip entirely — zero height and no residual gap.
  implicitHeight: collapsed ? 0 : (shelfPadTop + Style.space(1) + Style.space(4) + sectionLabel.height
    + cellHeight + shelfPadBottom)
  height: implicitHeight
  visible: !collapsed
  enabled: !collapsed
  clip: true
  readonly property var addPinButton: addPin
  readonly property var firstFocusControl: root.visibleCount > 0
    ? pinRepeater.itemAt(0) : overflowButton.visible ? overflowButton : addPin
  Keys.onBacktabPressed: function(event) {
    if (root.firstFocusControl && root.firstFocusControl.activeFocus)
      event.accepted = root.panel.focusBeforeFooter()
  }
  property bool overflowOpen: false
  property bool overflowOpenedByKeyboard: false
  property double overflowDismissedAt: 0
  property string dragSourceKey: ""
  property int dragSourceIndex: -1
  property int dragTargetIndex: -1
  property var dragOrderKeys: []

  function pinKeys() {
    return (root.pins || []).map(function(pin) { return String(pin.key || "") })
  }

  function beginPinDrag(key) {
    if (root.collapsed || root.overflowOpen || root.dragSourceKey) return false
    var index = root.pinKeys().indexOf(key)
    if (index < 0 || index >= root.visibleCount
        || !root.controller.beginPinReorder(key)) return false
    root.dragSourceKey = key
    root.dragSourceIndex = index
    root.dragTargetIndex = index
    root.dragOrderKeys = root.pinKeys()
    root.close()
    return true
  }

  function updatePinDrag(scenePoint) {
    if (!root.dragSourceKey) return
    var point = pinArea.mapFromItem(null, scenePoint.x, scenePoint.y)
    // Dropping outside the pin shelf cancels the reorder, not a window action.
    if (point.x < 0 || point.x >= pinArea.width
        || point.y < 0 || point.y >= pinArea.height
        || (root.hiddenCount > 0
          && point.x >= root.visibleCount * (root.cell + root.pinGap))) {
      root.dragTargetIndex = -1
      return
    }
    root.dragTargetIndex = InteractionModel.pinnedStripDragTargetIndex(
      point.x, root.visibleCount, root.cell, root.pinGap)
  }

  function dragShift(index) {
    if (root.dragSourceIndex < 0 || root.dragTargetIndex < 0) return 0
    var step = root.cell + root.pinGap
    if (root.dragSourceIndex < root.dragTargetIndex
        && index > root.dragSourceIndex && index <= root.dragTargetIndex) return -step
    if (root.dragSourceIndex > root.dragTargetIndex
        && index >= root.dragTargetIndex && index < root.dragSourceIndex) return step
    return 0
  }

  function cancelPinDrag() {
    var owned = root.dragSourceKey !== ""
      && root.controller.pinDragKey === root.dragSourceKey
    root.dragSourceKey = ""
    root.dragSourceIndex = -1
    root.dragTargetIndex = -1
    root.dragOrderKeys = []
    if (owned) root.controller.cancelPinReorder()
  }

  function finishPinDrag() {
    if (!root.dragSourceKey) return
    var target = root.dragTargetIndex >= 0 && root.dragTargetIndex < root.visibleCount
      ? root.pins[root.dragTargetIndex] : null
    var key = target ? String(target.key || "") : ""
    var owned = root.controller.pinDragKey === root.dragSourceKey
    root.dragSourceKey = ""
    root.dragSourceIndex = -1
    root.dragTargetIndex = -1
    root.dragOrderKeys = []
    if (owned) root.controller.finishPinReorder(key, !key)
  }

  Keys.onEscapePressed: function(event) {
    if (!root.dragSourceKey) return
    root.cancelPinDrag()
    event.accepted = true
  }
  onVisibleCountChanged: if (root.dragSourceKey) root.cancelPinDrag()
  onVisibleChanged: if (!visible) root.cancelPinDrag()
  Component.onDestruction: root.cancelPinDrag()

  HoverHandler { cursorShape: Qt.ArrowCursor }
  // Hidden pin whose context menu is open. The popup closes when the menu
  // opens, so the +N button stands in as the menu anchor for that pin.
  property var overflowMenuPin: null
  readonly property string overflowMenuKey: {
    var key = overflowMenuPin ? String(overflowMenuPin.key || "") : ""
    if (!key) return ""
    return hiddenPins.some(function(pin) { return String(pin.key || "") === key }) ? key : ""
  }

  property var prevPins: []
  property var shownKeys: []
  property var exitStash: ({})
  property bool stripReady: false

  ListModel {
    id: displayModel
  }

  function launcherFor(key) {
    var want = String(key || "")
    var list = root.pins || []
    for (var i = 0; i < list.length; ++i) {
      if (String(list[i].key || "") === want) return list[i]
    }
    return root.exitStash[want] || null
  }

  function close() {
    overflowOpen = false
  }

  // Right-click / Menu key on a hidden pin: same app menu (incl. Unpin) as
  // a visible tile, anchored to +N and validated by its rowKey/ownership.
  function openOverflowContext(pin) {
    if (!pin) return false
    overflowMenuPin = pin
    close()
    Qt.callLater(function() {
      if (!root.overflowMenuKey) return
      root.panel.openContext(root.overflowMenuPin, overflowButton)
    })
    return true
  }

  function toggleOverflow() {
    if (overflowOpen) {
      close()
      return
    }
    if (Date.now() - overflowDismissedAt < 250) return
    overflowOpen = true
  }

  onHiddenCountChanged: if (hiddenCount === 0) close()
  onCollapsedChanged: if (collapsed) { close(); cancelPinDrag() }
  onWidthChanged: {
    if (root.dragSourceKey) root.cancelPinDrag()
    shownKeys = (pins || []).slice(0, visibleCount).map(function(pin) {
      return String(pin.key || "")
    })
  }
  onOverflowOpenChanged: {
    if (!overflowOpen) return
    Qt.callLater(function() {
      if (root.overflowOpenedByKeyboard) {
        var first = hiddenRepeater.itemAt(0)
        if (first) first.forceActiveFocus()
        return
      }
      overflowFlickable.forceActiveFocus(Qt.MouseFocusReason)
    })
  }

  function copyStash(src) {
    var out = ({})
    var keys = Object.keys(src || ({}))
    for (var i = 0; i < keys.length; ++i) out[keys[i]] = src[keys[i]]
    return out
  }

  function finishExit(key) {
    var want = String(key || "")
    for (var i = displayModel.count - 1; i >= 0; --i) {
      if (String(displayModel.get(i).key) === want && displayModel.get(i).exiting === true)
        displayModel.remove(i)
    }
    var next = root.copyStash(root.exitStash)
    delete next[want]
    root.exitStash = next
  }

  function syncDisplay() {
    var list = []
    var raw = root.pins || []
    for (var i = 0; i < raw.length; ++i) list.push(raw[i])

    var nextByKey = Object.create(null)
    for (var n = 0; n < list.length; ++n)
      nextByKey[String(list[n].key || "")] = list[n]

    var prevByKey = Object.create(null)
    for (var p = 0; p < root.prevPins.length; ++p)
      prevByKey[String(root.prevPins[p].key || "")] = root.prevPins[p]

    for (var d = displayModel.count - 1; d >= 0; --d) {
      var row = displayModel.get(d)
      var key = String(row.key || "")
      if (!nextByKey[key] && row.exiting !== true) {
        var stash = root.copyStash(root.exitStash)
        stash[key] = prevByKey[key] || root.launcherFor(key) || stash[key] || null
        root.exitStash = stash
        displayModel.setProperty(d, "exitSlot", root.shownKeys.indexOf(key))
        displayModel.setProperty(d, "exiting", true)
        if (!root.animationsEnabled) root.finishExit(key)
      } else if (nextByKey[key] && row.exiting === true) {
        displayModel.setProperty(d, "exiting", false)
        displayModel.setProperty(d, "exitSlot", -1)
      }
    }

    var displayed = Object.create(null)
    for (var e = 0; e < displayModel.count; ++e)
      displayed[String(displayModel.get(e).key)] = true

    for (var a = 0; a < list.length; ++a) {
      var addKey = String(list[a].key || "")
      if (!addKey || displayed[addKey]) continue
      displayModel.append({
        key: addKey,
        exiting: false,
        exitSlot: -1,
        // Animate only after the shelf has painted once (avoid boot fanfare).
        animateIn: root.stripReady && root.animationsEnabled
      })
      displayed[addKey] = true
    }

    // Reconcile order as well as membership. Move existing model rows instead
    // of resetting them; pending exits remain alive after the ordered live pins.
    for (var targetIndex = 0; targetIndex < list.length; ++targetIndex) {
      var targetKey = String(list[targetIndex].key || "")
      for (var currentIndex = targetIndex; currentIndex < displayModel.count; ++currentIndex) {
        if (String(displayModel.get(currentIndex).key) !== targetKey) continue
        if (currentIndex !== targetIndex) displayModel.move(currentIndex, targetIndex, 1)
        break
      }
    }

    var cleaned = root.copyStash(root.exitStash)
    var changed = false
    var stashKeys = Object.keys(cleaned)
    for (var s = 0; s < stashKeys.length; ++s) {
      if (nextByKey[stashKeys[s]]) {
        delete cleaned[stashKeys[s]]
        changed = true
      }
    }
    if (changed) root.exitStash = cleaned

    root.prevPins = list
    root.shownKeys = list.slice(0, root.visibleCount).map(function(pin) {
      return String(pin.key || "")
    })
  }

  onPinsChanged: {
    if (root.dragSourceKey
        && JSON.stringify(root.pinKeys()) !== JSON.stringify(root.dragOrderKeys))
      root.cancelPinDrag()
    syncDisplay()
  }
  Component.onCompleted: {
    syncDisplay()
    root.stripReady = true
  }
  Connections {
    target: root.controller
    function onRefreshed() { root.syncDisplay() }
    function onPinDragKeyChanged() {
      if (root.dragSourceKey && root.controller.pinDragKey !== root.dragSourceKey)
        root.cancelPinDrag()
    }
  }

  Ui.PanelSeparator {
    id: divider
    anchors.left: parent.left
    anchors.right: parent.right
    anchors.top: parent.top
    anchors.topMargin: root.shelfPadTop
  }

  Ui.PanelSectionHeader {
    id: sectionLabel
    objectName: "pinned-section-label"
    anchors.left: parent.left
    // The pin shelf has a different outer inset. Align only its label to the
    // hierarchy's content origin; leave pin cells and hit targets unchanged.
    anchors.leftMargin: {
      if (!root.panel || !root.panel.viewport) return Style.space(5) + Style.space(4)
      var item = root.panel.viewport, x = 0
      while (item && item !== root.parent) { x += item.x; item = item.parent }
      return x - root.x + root.panel.viewport.workspaceCardInset + Style.space(4)
    }
    anchors.top: divider.bottom
    anchors.topMargin: Style.space(4)
    height: Math.max(Style.space(26), implicitHeight)
    verticalAlignment: Text.AlignVCenter
    text: "PINNED"
  }

  Item {
    id: pinRow
    objectName: "sidebar-pin-strip"
    anchors.left: parent.left
    anchors.right: parent.right
    anchors.top: sectionLabel.bottom
    height: root.cellHeight

    Item {
      id: pinArea
      anchors.left: parent.left
      anchors.right: addPin.left
      anchors.rightMargin: root.pinGap
      height: parent.height
      clip: true

      Repeater {
        id: pinRepeater
        model: displayModel
        delegate: Item {
          id: pinCell
          required property int index
          required property string key
          required property bool exiting
          required property int exitSlot
          required property bool animateIn
          readonly property var modelData: root.launcherFor(key)
          readonly property string rowKey: String(key || "")
          readonly property string desktopId: String((modelData && modelData.desktopId) || "")
          readonly property var entry: {
            var apps = DesktopEntries.applications.values || []
            var revision = apps.length
            if (modelData && modelData.item && modelData.item.entry) return modelData.item.entry
            if (!pinCell.desktopId) return null
            return DesktopEntries.byId(pinCell.desktopId)
          }
          readonly property bool pinStripOwned: true
          // Drive opacity/scale through a settled flag so Behaviors actually run
          // (a direct binding to exiting alone skips the "from" frame on insert).
          property bool settled: !animateIn
          property bool mouseFocused: false
          width: root.cell
          height: root.cellHeight
          x: (exiting && exitSlot >= 0 ? exitSlot : index) * (root.cell + root.pinGap)
          z: pinDrag.active ? 2 : 0
          transform: Translate {
            x: pinDrag.active && root.dragSourceKey === pinCell.rowKey
              ? pinDrag.activeTranslation.x : root.dragShift(pinCell.index)
            y: pinDrag.active && root.dragSourceKey === pinCell.rowKey
              ? pinDrag.activeTranslation.y : 0
            Behavior on x {
              enabled: root.animationsEnabled && !pinDrag.active
              NumberAnimation { duration: 120; easing.type: Easing.OutCubic }
            }
          }
          transformOrigin: Item.Center
          opacity: exiting ? 0 : (settled ? 1 : 0)
          scale: exiting ? 0.55 : (settled ? 1 : 0.55)
          visible: (index < root.visibleCount && !!modelData)
            || (exiting && exitSlot >= 0)
          focus: true
          activeFocusOnTab: true
          Accessible.role: Accessible.Button
          Accessible.name: String((modelData && (modelData.label || modelData.desktopId)) || "Pinned application")

          Behavior on opacity {
            enabled: root.animationsEnabled
            NumberAnimation { duration: root.animMs; easing.type: Easing.OutCubic }
          }
          Behavior on scale {
            enabled: root.animationsEnabled
            NumberAnimation { duration: root.animMs; easing.type: Easing.OutCubic }
          }

          Component.onCompleted: {
            if (!pinCell.animateIn || !root.animationsEnabled) {
              pinCell.settled = true
              return
            }
            Qt.callLater(function() {
              if (!pinCell || pinCell.exiting) return
              pinCell.settled = true
              if (pinCell.index >= 0 && pinCell.index < displayModel.count)
                displayModel.setProperty(pinCell.index, "animateIn", false)
            })
          }

          onExitingChanged: {
            if (!exiting) return
            if (!root.animationsEnabled) {
              root.finishExit(pinCell.key)
              return
            }
            exitDelay.restart()
          }
          onActiveFocusChanged: if (!activeFocus) mouseFocused = false

          Timer {
            id: exitDelay
            interval: Math.max(root.animMs, 1)
            repeat: false
            onTriggered: root.finishExit(pinCell.key)
          }

          Keys.onPressed: function(event) {
            if (!pinCell.modelData || pinCell.exiting) return
            pinCell.mouseFocused = false
            if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter || event.key === Qt.Key_Space) {
              root.activatePin(pinCell.modelData)
              event.accepted = true
            } else if (event.key === Qt.Key_Menu) {
              root.panel.openContext(pinCell.modelData, pinCell)
              event.accepted = true
            }
          }

          // Shelf is the single block; cells only paint hover/press/focus fills.
          Rectangle {
            anchors.fill: parent
            radius: root.appearance.cardRadius
            color: pinPress.pressed ? Style.pressedFillFor(Commons.Color.foreground, Commons.Color.accent)
              : (pinHover.hovered
                  || (pinCell.activeFocus && !pinCell.mouseFocused))
                ? Style.hoverFillFor(Commons.Color.foreground, Commons.Color.accent)
                : Style.normalFill
            Behavior on color {
              enabled: root.animationsEnabled
              ColorAnimation { duration: 120 }
            }
          }

          DockAppIcon {
            id: pinIcon
            anchors.centerIn: parent
            width: root.iconSize
            height: root.iconSize
            roundedArtwork: false
            badgeRingColor: root.appearance.workspaceFill
            desktopId: pinCell.desktopId
            desktopIcon: pinCell.entry ? String(pinCell.entry.icon || "") : ""
            iconOverrides: root.controller.settings.iconOverrides || ({})
            reloadRevision: root.controller.host.iconReloadRevision || 0
            profileBadgesEnabled: false
            opacity: 1
            scale: pinHover.hovered ? 1.08 : 1
            Behavior on scale {
              enabled: root.animationsEnabled
              NumberAnimation { duration: 120; easing.type: Easing.OutCubic }
            }
          }

          HoverHandler { id: pinHover }
          DragHandler {
            id: pinDrag
            target: null
            acceptedButtons: Qt.LeftButton
            acceptedModifiers: Qt.NoModifier
            cursorShape: Qt.ClosedHandCursor
            enabled: !!pinCell.modelData && !pinCell.exiting
              && pinCell.index < root.visibleCount && !root.collapsed
              && (!root.controller.interactionBusy
                || root.dragSourceKey === pinCell.rowKey)
            onActiveChanged: {
              if (active && root.beginPinDrag(pinCell.rowKey))
                root.updatePinDrag(centroid.scenePosition)
            }
            onActiveTranslationChanged: {
              if (active && root.dragSourceKey === pinCell.rowKey)
                root.updatePinDrag(centroid.scenePosition)
            }
            // Qt drops active on cancellation too: only an actual release saves.
            onGrabChanged: function(transition, point) {
              if (transition === PointerDevice.UngrabExclusive
                  && root.dragSourceKey === pinCell.rowKey)
                root.finishPinDrag()
              else if (transition === PointerDevice.CancelGrabExclusive
                       || transition === PointerDevice.CancelGrabPassive)
                if (root.dragSourceKey === pinCell.rowKey) root.cancelPinDrag()
            }
            onEnabledChanged: {
              if (!enabled && root.dragSourceKey === pinCell.rowKey) root.cancelPinDrag()
            }
          }
          TapHandler {
            id: pinPress
            acceptedButtons: Qt.LeftButton
            enabled: !!pinCell.modelData && !pinCell.exiting
            onTapped: {
              pinCell.mouseFocused = true
              pinCell.forceActiveFocus(Qt.MouseFocusReason)
              root.activatePin(pinCell.modelData)
            }
          }
          TapHandler {
            acceptedButtons: Qt.RightButton
            enabled: !!pinCell.modelData && !pinCell.exiting
            onTapped: {
              pinCell.mouseFocused = true
              pinCell.forceActiveFocus(Qt.MouseFocusReason)
              root.panel.openContext(pinCell.modelData, pinCell)
            }
          }
          DockToolTip {
            anchorItem: pinCell
            position: "bottom"
            requestedVisible: pinHover.hovered && !root.controller.rowDragActive
              && !root.controller.pinReorderActive
              && !!pinCell.modelData && !pinCell.exiting
            text: String((pinCell.modelData && (pinCell.modelData.label || pinCell.modelData.desktopId)) || "Pinned app")
              + (pinCell.modelData && pinCell.modelData.running ? " · Running" : "")
            fontFamily: Style.font.family
            fontSize: Style.font.bodySmall
          }
        }
      }

      Ui.Button {
        id: overflowButton
        objectName: "sidebar-pin-strip-overflow"
        property bool pinStripOwned: true
        // Context-menu anchor identity for the hidden pin being managed.
        readonly property string rowKey: root.overflowMenuKey
        readonly property string desktopId: root.overflowMenuKey && root.overflowMenuPin
          ? String(root.overflowMenuPin.desktopId || "") : ""
        readonly property var entry: {
          var pin = root.overflowMenuKey ? root.overflowMenuPin : null
          if (!pin) return null
          if (pin.item && pin.item.entry) return pin.item.entry
          return desktopId ? DesktopEntries.byId(desktopId) : null
        }
        width: root.cell
        height: root.cellHeight
        x: root.visibleCount * (root.cell + root.pinGap)
        visible: root.hiddenCount > 0
        focusable: true
        enabled: !root.controller.interactionBusy || root.overflowOpen
        text: "+" + root.hiddenCount
        fontSize: Style.font.bodySmall
        tooltipText: "More pinned applications"
        Accessible.role: Accessible.Button
        Accessible.name: root.hiddenCount + " more pinned applications"
          selected: root.overflowOpen
          background: Style.normalFill
        Keys.onPressed: function(event) {
          if (event.key !== Qt.Key_Return && event.key !== Qt.Key_Enter
              && event.key !== Qt.Key_Space) return
          root.overflowOpenedByKeyboard = true
          root.toggleOverflow()
          event.accepted = true
        }
        onClicked: {
          root.overflowOpenedByKeyboard = false
          root.toggleOverflow()
          overflowButton.focus = false
        }
      }
    }

    Ui.Button {
      id: addPin
      objectName: "sidebar-pin-strip-add"
      property bool pinStripOwned: true
      width: root.cell
      height: root.cellHeight
      anchors.right: parent.right
      anchors.top: parent.top
      visible: !root.collapsed
      iconText: ""
      tooltipText: "Add a pinned application"
      Accessible.name: "Add pinned application"
      focusable: true
      enabled: !root.controller.interactionBusy
      onClicked: {
        root.panel.openPinPicker(addPin)
        addPin.focus = false
      }
      DockLucideIcon {
        anchors.centerIn: parent
        width: 13
        height: 13
        iconName: "plus"
        iconSize: 13
        tint: Commons.Color.foreground
      }
      Shape {
        anchors.fill: parent
        enabled: false
        ShapePath {
          strokeColor: Util.alpha(Commons.Color.foreground, 0.28)
          strokeWidth: 1
          strokeStyle: ShapePath.DashLine
          dashPattern: [4, 3]
          fillColor: "transparent"
          PathSvg { path: "M 8 0 H 24 Q 32 0 32 8 V 28 Q 32 36 24 36 H 8 Q 0 36 0 28 V 8 Q 0 0 8 0 Z" }
        }
      }
    }
  }

  PopupWindow {
    id: overflowPopup
    visible: root.overflowOpen && !root.collapsed && root.hiddenCount > 0
    implicitWidth: Style.space(184)
    implicitHeight: Math.min(root.hiddenCount * Style.space(32), Style.space(256))
    color: "transparent"
    grabFocus: true

    anchor {
      window: overflowButton.QsWindow.window
      adjustment: PopupAdjustment.Slide
      edges: Edges.Top | Edges.Left
      gravity: Edges.Bottom | Edges.Right
      rect.width: 1
      rect.height: 1
      onAnchoring: {
        if (!overflowPopup.anchor.window) return
        var edge = root.controller.edge
        var x = edge === "left" ? overflowButton.width + Style.space(8)
          : -overflowPopup.implicitWidth - Style.space(8)
        var y = overflowButton.height / 2 - overflowPopup.implicitHeight / 2
        var point = overflowPopup.anchor.window.contentItem.mapFromItem(overflowButton, x, y)
        overflowPopup.anchor.rect.x = Math.round(point.x)
        overflowPopup.anchor.rect.y = Math.round(Math.max(Style.space(8), Math.min(
          point.y, overflowPopup.anchor.window.height - overflowPopup.implicitHeight - Style.space(8))))
      }
    }

    onVisibleChanged: {
      if (visible) return
      if (root.overflowOpen) root.overflowDismissedAt = Date.now()
      root.close()
    }

    Ui.BorderSurface {
      id: overflowSurface
      anchors.fill: parent
      color: Commons.Color.menu.background
      borderSpec: Border.none()
      radius: Style.cornerRadius
      clip: true

      Flickable {
        id: overflowFlickable
        anchors.fill: parent
        anchors.leftMargin: overflowSurface.contentLeftInset
        anchors.rightMargin: overflowSurface.contentRightInset
        anchors.topMargin: overflowSurface.contentTopInset
        anchors.bottomMargin: overflowSurface.contentBottomInset
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        contentWidth: width
        contentHeight: hiddenColumn.implicitHeight
        Keys.onEscapePressed: root.close()

        Column {
          id: hiddenColumn
          width: parent.width

          Repeater {
            id: hiddenRepeater
            model: root.hiddenPins
            delegate: Ui.Button {
              id: hiddenPin
              required property var modelData
              readonly property string desktopId: String(modelData.desktopId || "")
              readonly property var entry: modelData.item && modelData.item.entry
                ? modelData.item.entry : DesktopEntries.byId(desktopId)
              width: hiddenColumn.width
              height: Style.space(32)
              focusable: true
              leftAlign: true
              text: ""
              Accessible.role: Accessible.MenuItem
              Accessible.name: String(modelData.label || desktopId)
                + (modelData.running ? " · Running" : "")
              onClicked: {
                root.close()
                root.activatePin(modelData)
              }
              Keys.onPressed: function(event) {
                if (event.key !== Qt.Key_Menu) return
                root.openOverflowContext(hiddenPin.modelData)
                event.accepted = true
              }
              TapHandler {
                acceptedButtons: Qt.RightButton
                onTapped: root.openOverflowContext(hiddenPin.modelData)
              }

              DockAppIcon {
                anchors.left: parent.left
                anchors.leftMargin: Style.space(8)
                anchors.verticalCenter: parent.verticalCenter
                width: Style.space(18)
                height: width
                roundedArtwork: false
                badgeRingColor: Commons.Color.menu.background
                desktopId: hiddenPin.desktopId
                desktopIcon: hiddenPin.entry ? String(hiddenPin.entry.icon || "") : ""
                iconOverrides: root.controller.settings.iconOverrides || ({})
                reloadRevision: root.controller.host.iconReloadRevision || 0
                profileBadgesEnabled: false
              }
              Text {
                anchors.left: parent.left
                anchors.leftMargin: Style.space(36)
                anchors.right: parent.right
                anchors.rightMargin: Style.space(8)
                anchors.verticalCenter: parent.verticalCenter
                text: String(hiddenPin.modelData.label || hiddenPin.desktopId)
                textFormat: Text.PlainText
                elide: Text.ElideRight
                color: Commons.Color.menu.text
                font.family: Style.font.family
                font.pixelSize: Style.font.bodySmall
              }
            }
          }
        }
      }
    }
  }

  function activatePin(target) {
    if (!target) return false
    return root.controller.activateTarget({
      key: target.key,
      kind: "launcher",
      desktopId: target.desktopId || ""
    }, false, "")
  }
}
