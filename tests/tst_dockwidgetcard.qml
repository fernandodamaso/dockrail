import QtQuick
import QtTest
import qs.Commons
import qs.Commons as Commons
import "../components"

TestCase {
  id: testCase
  name: "DockWidgetCard"
  when: windowShown
  visible: true
  width: 360
  height: 240

  property int toggleCount: 0

  QtObject {
    id: testAppearance
    property color monitorFill: "#343747"
    property color workspaceHoverFill: "#484c60"
    property real cardRadius: 2
  }

  function init() {
    testAppearance.monitorFill = "#343747"
    testAppearance.workspaceHoverFill = "#484c60"
    testAppearance.cardRadius = 2
    mockController.count = 0
    mockController.label = "Demo Widget"
    mouseMove(testCase, 350, 230)
  }


  QtObject {
    id: mockController
    property var herdrAssociations: ({})
    property int count: 0
    property string label: "Demo Widget"
    function widgetView(id) {
      return {
        descriptor: { id: id, label: mockController.label, iconName: "layout-grid" },
        data: { count: mockController.count },
        status: "unavailable",
        active: false,
        revision: 0,
        provider: null
      }
    }
    function openWidgetPopup() { return false }
    function closeWidgetPopup() {}
  }

  Component {
    id: cardFactory
    DockWidgetCard {
      width: 280
      controller: mockController
      widgetId: "demo.widget"
      collapsed: false
      onToggleRequested: testCase.toggleCount += 1
    }
  }

  Component {
    id: inputFactory
    TextInput { x: 25; y: 12; width: 100; height: 24; text: "Body input" }
  }

  function findByName(node, name) {
    if (!node) return null
    if (node.objectName === name) return node
    if (node.children) {
      for (var i = 0; i < node.children.length; ++i) {
        var hit = findByName(node.children[i], name)
        if (hit) return hit
      }
    }
    return null
  }

  // Qt Quick Text quantizes alpha to 8 bits; JS colors may retain 16-bit precision.
  function compareColor(actual, expected) {
    for (var channel of ["r", "g", "b", "a"])
      fuzzyCompare(actual[channel], expected[channel], 1 / 255)
  }

  function makeCard() {
    testCase.toggleCount = 0
    var card = createTemporaryObject(cardFactory, testCase)
    verify(card !== null)
    waitForRendering(card)
    return card
  }

  function test_optional_appearance_matches_sidebar_fallback() {
    var card = makeCard()
    compare(card.appearance, null)
    var surface = findByName(card, "widget-card-surface")
    compare(surface.color, Qt.tint(Commons.Color.background, Util.alpha(Commons.Color.foreground, 0.035)))
    compare(surface.radius, Math.min(3, Style.cornerRadius))
  }

  function test_appearance_fill_and_radius_remain_live_on_hover_and_focus() {
    var card = makeCard()
    card.appearance = testAppearance
    var surface = findByName(card, "widget-card-surface")
    compare(surface.color, testAppearance.monitorFill)
    compare(surface.radius, 2)
    mouseMove(card, 20, 15)
    compare(surface.color, testAppearance.monitorFill)
    card.forceActiveFocus()
    compare(surface.color, testAppearance.monitorFill)
    verify(surface.border.width > 0)
    testAppearance.monitorFill = "#a2b3c4"
    testAppearance.cardRadius = 0
    compare(surface.color, testAppearance.monitorFill)
    compare(surface.radius, 0)
    card.appearance = null
    compare(surface.color, Qt.tint(Commons.Color.background, Util.alpha(Commons.Color.foreground, 0.035)))
    compare(surface.radius, Math.min(3, Style.cornerRadius))
  }

  function test_title_matches_monitor_hierarchy_and_divider_is_subtle() {
    var card = makeCard()
    var title = findByName(card, "widget-card-title")
    compare(title.font.pixelSize, Style.font.body)
    compare(title.font.weight, Font.DemiBold)
    compare(title.color, Commons.Color.foreground)
    card.collapsed = true
    compareColor(title.color, Util.alpha(Commons.Color.foreground, 0.85))
    card.forceActiveFocus()
    compare(title.color, Commons.Color.foreground)
    var divider = findByName(card, "widget-card-divider")
    verify(divider !== null)
    compare(divider.height, 1)
    compareColor(divider.color, Util.alpha(Commons.Color.foreground, 0.07))
  }

  function test_header_geometry_data() {
    return [ { tag: "no badge", count: 0 }, { tag: "one", count: 1 },
      { tag: "99 plus", count: 100 } ]
  }

  function test_header_geometry(data) {
    mockController.count = data.count
    mockController.label = "A very long Widget title that must elide before the fixed drag grip"
    var card = makeCard()
    card.width = 240
    waitForRendering(card)
    var grip = findByName(card, "widget-card-grip")
    var icon = findByName(card, "widget-card-grip-icon")
    var badge = findByName(card, "widget-card-badge")
    var title = findByName(card, "widget-card-title")
    var collapse = findByName(card, "widget-card-collapse")
    verify(grip !== null && icon !== null && badge !== null)
    compare(badge.visible, data.count > 0)
    tryCompare(icon, "ready", true)
    compare(icon.iconName, "grip-vertical")
    compare(grip.activeFocusOnTab, false)
    compare(grip.visible, true)
    compare(grip.enabled, true)
    compare(grip.width, Style.space(22))
    verify(title.width > 0)
    verify(title.truncated)
    verify(title.x + title.width <= grip.x)
    if (badge.visible) {
      verify(grip.x + grip.width <= badge.x)
      verify(badge.x + badge.width <= collapse.x)
      compare(findByName(card, "widget-card-badge-text").text, data.count > 99 ? "99+" : "1")
    } else {
      verify(grip.x + grip.width <= collapse.x)
    }
    var positions = [grip.x, badge.x, collapse.x, title.width]
    compare(icon.opacity, 0)
    mouseMove(card, 20, 15)
    tryCompare(icon, "opacity", 1)
    compare([grip.x, badge.x, collapse.x, title.width], positions)
    mouseMove(testCase, 350, 230)
    tryCompare(icon, "opacity", 0)
    card.forceActiveFocus()
    tryCompare(icon, "opacity", 1)
    compare([grip.x, badge.x, collapse.x, title.width], positions)
    compare(grip.Accessible.name, "Drag " + card.title + " to reorder")
  }

  function test_body_input_focus_reveals_grip_without_changing_idle_surface() {
    var card = makeCard()
    card.appearance = testAppearance
    var body = findByName(card, "widget-card-body")
    verify(body !== null)
    var input = createTemporaryObject(inputFactory, body)
    var icon = findByName(card, "widget-card-grip-icon")
    verify(icon !== null)
    compare(icon.opacity, 0)
    input.forceActiveFocus()
    verify(input.activeFocus)
    verify(!card.activeFocus)
    tryCompare(icon, "opacity", 1)
    compare(findByName(card, "widget-card-header-highlight").color, testAppearance.workspaceHoverFill)
    compare(findByName(card, "widget-card-surface").color, testAppearance.monitorFill)
    verify(findByName(card, "widget-card-surface").border.width > 0)
    keyClick(Qt.Key_End)
    keyClick(Qt.Key_Space)
    for (var letter of [Qt.Key_E, Qt.Key_D, Qt.Key_I, Qt.Key_T, Qt.Key_E, Qt.Key_D])
      keyClick(letter)
    compare(input.text, "Body input edited")
    compare(testCase.toggleCount, 0)
  }

  function test_hidden_grip_drag_survives_hover_loss_and_cancel() {
    var card = makeCard()
    var grip = findByName(card, "widget-card-grip-icon")
    verify(grip !== null)
    compare(grip.opacity, 0)
    var handle = findByName(card, "widget-card-drag-handle")
    var started = 0
    var finished = []
    card.dragStarted.connect(function() { started += 1 })
    card.dragFinished.connect(function(x, y, cancelled) { finished.push(cancelled) })
    mousePress(handle, 8, 15, Qt.LeftButton)
    mouseMove(handle, 8, 15 + card.dragThreshold + 2, Qt.LeftButton)
    compare(started, 1)
    compare(card.dragActive, true)
    mouseMove(testCase, 345, 225, Qt.LeftButton)
    compare(grip.opacity, 1)
    card.visible = false
    tryCompare(card, "dragActive", false)
    compare(finished, [true])
    mouseRelease(testCase, 345, 225, Qt.LeftButton)
    compare(finished, [true])
    compare(testCase.toggleCount, 0)
  }

  function test_down_chevron_rotation_tracks_collapsed_state() {
    var card = makeCard()
    var arrow = findByName(card, "widget-card-collapse-icon")
    verify(arrow !== null)
    compare(arrow.iconName, "chevron-down")
    compare(arrow.rotation, 180)
    card.collapsed = true
    compare(arrow.rotation, 0)
  }

  function test_idle_wrapper_has_no_border_and_focus_restores_feedback() {
    var card = makeCard()
    var surface = findByName(card, "widget-card-surface")
    verify(surface !== null)
    compare(surface.border.width, 0)

    card.forceActiveFocus()
    verify(card.activeFocus)
    verify(surface.border.width > 0)
  }

  function test_header_highlight_does_not_cover_focus_border() {
    var card = makeCard()
    card.appearance = testAppearance
    card.forceActiveFocus()
    waitForRendering(card)
    var image = grabImage(card)
    compareColor(image.pixel(Math.floor(card.width / 2), 0), Commons.Color.accent)
  }

  function test_title_single_click_does_not_toggle() {
    var card = makeCard()
    var title = findByName(card, "widget-card-title")
    verify(title !== null)
    mouseClick(title, title.width / 2, title.height / 2, Qt.LeftButton)
    compare(testCase.toggleCount, 0)
  }

  function test_title_double_click_toggles_exactly_once() {
    var card = makeCard()
    var title = findByName(card, "widget-card-title")
    verify(title !== null)
    mouseDoubleClickSequence(title, title.width / 2, title.height / 2, Qt.LeftButton)
    compare(testCase.toggleCount, 1)
  }

  function test_title_drag_past_threshold_does_not_start_reorder() {
    var card = makeCard()
    var title = findByName(card, "widget-card-title")
    verify(title !== null)
    var started = 0
    card.dragStarted.connect(function() { started += 1 })
    mousePress(title, title.width / 2, title.height / 2, Qt.LeftButton)
    mouseMove(title, title.width / 2, title.height / 2 + card.dragThreshold + 8, Qt.LeftButton)
    mouseRelease(title, title.width / 2, title.height / 2 + card.dragThreshold + 8, Qt.LeftButton)
    compare(started, 0)
    compare(card.dragActive, false)
    compare(testCase.toggleCount, 0)
  }

  function test_drag_handle_past_threshold_starts_without_toggle() {
    var card = makeCard()
    var handle = findByName(card, "widget-card-drag-handle")
    verify(handle !== null)
    var started = 0
    card.dragStarted.connect(function() { started += 1 })
    mousePress(handle, 8, handle.height / 2, Qt.LeftButton)
    mouseMove(handle, 8, handle.height / 2 + 2, Qt.LeftButton)
    compare(started, 0)
    compare(card.dragActive, false)
    mouseMove(handle, 8, handle.height / 2 + card.dragThreshold + 1, Qt.LeftButton)
    compare(started, 1)
    compare(card.dragActive, true)
    compare(testCase.toggleCount, 0)
    mouseRelease(handle, 8, handle.height / 2 + card.dragThreshold + 1, Qt.LeftButton)
    compare(card.dragActive, false)
    compare(testCase.toggleCount, 0)
  }

  function test_rejected_drag_start_clears_drag_active() {
    var card = makeCard()
    var handle = findByName(card, "widget-card-drag-handle")
    verify(handle !== null)
    card.dragStarted.connect(function() { card.dragActive = false })
    mousePress(handle, 8, handle.height / 2, Qt.LeftButton)
    mouseMove(handle, 8, handle.height / 2 + card.dragThreshold + 2, Qt.LeftButton)
    compare(card.dragActive, false)
    mouseRelease(handle, 8, handle.height / 2 + card.dragThreshold + 2, Qt.LeftButton)
    compare(testCase.toggleCount, 0)
  }

  function test_context_menu_removal_emits_once() {
    var card = makeCard()
    var removed = 0
    card.removeRequested.connect(function() { removed++ })
    var menu = findChild(card, "widget-card-menu")
    verify(menu !== null)
    mouseClick(card, 20, 15, Qt.RightButton)
    tryCompare(menu, "visible", true)
    keyClick(Qt.Key_Down)
    keyClick(Qt.Key_Return)
    compare(removed, 1)
    compare(testCase.toggleCount, 0)
  }

  function test_chevron_single_click_still_toggles() {
    var card = makeCard()
    var chevron = findByName(card, "widget-card-collapse")
    verify(chevron !== null)
    mouseClick(chevron, chevron.width / 2, chevron.height / 2, Qt.LeftButton)
    compare(testCase.toggleCount, 1)
  }

  function test_keyboard_return_enter_space_still_toggle() {
    var card = makeCard()
    card.forceActiveFocus()
    verify(card.activeFocus)
    keyClick(Qt.Key_Space)
    keyClick(Qt.Key_Return)
    keyClick(Qt.Key_Enter)
    compare(testCase.toggleCount, 3)
  }
}
