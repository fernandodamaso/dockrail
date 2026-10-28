pragma ComponentBehavior: Bound
import QtQuick
import qs.Ui as Ui
import qs.Commons
import qs.Commons as Commons
import "DockSettingsRegistry.js" as Registry

// A canonical schema row. Drafts are interaction snapshots, never preview state.
Column {
  id: root
  required property var host
  required property var row
  property int monitorCount: 0
  property bool hasCursor: false
  property bool feedbackActive: true
  readonly property string key: row.key
  readonly property var spec: row.spec
  readonly property var ui: row.ui
  readonly property var current: host.settings[key]
  readonly property var dependency: Registry.editability(ui, host.settings, monitorCount)
  readonly property bool writerBusy: host.settingsWriteState === "saving"
    || host.settingsReloadPending === true || host.settingsLoaded === false
  readonly property bool editable: host.settingsLoadState !== "invalid" && dependency.enabled && !writerBusy
  readonly property bool resettable: host.settingsLoadState !== "invalid" && !writerBusy
    && host.defaultSetting !== undefined
  readonly property var defaultValue: host.defaultSetting ? host.defaultSetting(key) : undefined
  readonly property bool needsReset: resettable && defaultValue !== undefined
    && JSON.stringify(current) !== JSON.stringify(defaultValue)
  readonly property var shown: host.shownSetting(key)
  readonly property bool popupOpen: dropdown.popupOpen
  readonly property bool textFocused: number.visible && number.field.activeFocus
  readonly property bool recoveryFocused: reloadAction.activeFocus || keepAction.activeFocus
  property bool editing: false
  property var expected: null
  property var draft: null
  property bool conflict: false
  property bool localWrite: false
  property bool initialized: false
  property bool changedElsewhere: false
  property string feedback: ""
  property string groupHeading: ""
  property bool pictureTiles: key === "workspaceLayout"
  signal edited()
  signal hovered()
  signal focusSections()
  spacing: Style.space(6)
  Accessible.role: Accessible.Grouping
  Accessible.name: ui.label + (conflict ? ", changed while editing" : changedElsewhere ? ", changed elsewhere" : "")
  onCurrentChanged: {
    if (!initialized || localWrite) return
    if (editing && JSON.stringify(current) !== JSON.stringify(expected)) conflict = true
    if (feedbackActive) {
      changedElsewhere = true
      highlight.restart()
    }
  }
  Component.onCompleted: initialized = true
  function beginEdit() {
    if (editing) return
    expected = JSON.parse(JSON.stringify(current))
    draft = current
    editing = true
  }
  function reloadDraft() {
    expected = current
    draft = current
    editing = false
    conflict = false
    feedback = ""
    keyboardCommit.stop()
    if (number.visible) number.field.contentItem.text = String(current)
  }
  function keepEditing() {
    expected = JSON.parse(JSON.stringify(current))
    conflict = false
    feedback = ""
  }
  function commitDraft() {
    keyboardCommit.stop()
    if (writerBusy) { feedback = "Saving… wait for readback before changing another value."; return false }
    if (!editable && !conflict) return false
    if (!editing) beginEdit()
    if (conflict) { feedback = "Changed while editing. Reload or keep editing."; return false }
    localWrite = true
    var outcome = Registry.writeOutcome(host.saveSettingIntent(key, draft, expected))
    localWrite = false
    if (outcome.accepted) {
      editing = false
      conflict = false
      changedElsewhere = false
      feedback = ""
      edited()
    } else {
      var error = outcome.reply && outcome.reply.error
      feedback = error ? error.code + ": " + error.message : "Could not save"
      if (error && error.code === "E_STALE") conflict = true
    }
    return outcome.accepted
  }
  function commitValue(value) {
    if (writerBusy) { feedback = "Saving… wait for readback before changing another value."; return false }
    beginEdit(); draft = value; return commitDraft()
  }
  function resetToDefault() {
    if (!resettable || defaultValue === undefined) return false
    keyboardCommit.stop()
    if (!editing) beginEdit()
    if (conflict) { feedback = "Changed while editing. Reload or keep editing."; return false }
    if (writerBusy) { feedback = "Saving… wait for readback before changing another value."; return false }
    localWrite = true
    var resetIntent = host.resetSettingIntent
      ? host.resetSettingIntent(key, expected)
      : host.saveSettingIntent(key, defaultValue, expected)
    var outcome = Registry.writeOutcome(resetIntent)
    localWrite = false
    if (outcome.accepted) {
      editing = false
      conflict = false
      changedElsewhere = false
      feedback = ""
      edited()
    } else {
      var resetError = outcome.reply && outcome.reply.error
      feedback = resetError ? resetError.code + ": " + resetError.message : "Could not save"
      if (resetError && resetError.code === "E_STALE") conflict = true
    }
    return outcome.accepted
  }
  function cancelPending() {
    keyboardCommit.stop()
    if (editing) reloadDraft()
  }
  function adjust(delta) {
    if (conflict) return
    if (!editable || writerBusy) return
    beginEdit()
    if (ui.control === "toggle") { draft = delta > 0; commitDraft(); return }
    if (spec.enum) {
      var index = spec.enum.indexOf(draft)
      draft = spec.enum[Math.max(0, Math.min(spec.enum.length - 1, index + delta))]
      commitDraft()
    } else if (ui.control === "slider" || ui.control === "number") {
      var step = spec.effectiveStep || (spec.type === "integer" ? 1 : 0.05)
      draft = Math.max(spec.minimum || 0, Math.min(ui.uiMaximum || spec.maximum || 100,
        Math.round((Number(draft) + step * delta) * 1000) / 1000))
      keyboardCommit.restart()
    }
  }
  function activate() {
    if (conflict) { reloadAction.forceActiveFocus(); return }
    if (!editable || writerBusy) return
    if (ui.control === "toggle") commitValue(!current)
    else if (ui.control === "dropdown") { beginEdit(); dropdown.open() }
    else if (ui.control === "number") { beginEdit(); number.field.forceActiveFocus() }
    else if (editing) commitDraft()
  }
  function dismissEditor() {
    if (popupOpen) { dropdown.close(); return true }
    if (editing) { reloadDraft(); return true }
    return false
  }
  function options() {
    return (spec.enum || []).map(function(value) { return {value:value,
      label:(ui.optionLabels && ui.optionLabels[value] || value)
        + (ui.destructiveOptions && ui.destructiveOptions.indexOf(value) >= 0 ? " · destructive" : "")} })
  }
  Timer { id: highlight; interval:3000; onTriggered: root.changedElsewhere = false }
  Timer { id: keyboardCommit; interval:400; onTriggered: root.commitDraft() }
  HoverHandler { onHoveredChanged: if (hovered) root.hovered() }
  Ui.PanelSectionHeader {
    visible: root.groupHeading !== ""
    text: root.groupHeading
    width: parent.width
  }
  Text {
    width: parent.width
    visible: root.ui.control !== "toggle"
    text: root.ui.label
    wrapMode: Text.WordWrap
    font.family: Style.font.family
    font.pixelSize: Style.font.body
    font.bold: true
    color: root.hasCursor ? Commons.Color.accent : Commons.Color.foreground
  }
  Text {
    width: parent.width
    visible: text !== "" && root.ui.control !== "toggle"
    text: root.ui.help || ""
    wrapMode: Text.WordWrap
    font.family: Style.font.family
    font.pixelSize: Style.font.caption
    color: Commons.Color.foreground
  }
  Text {
    width: parent.width
    visible: !root.dependency.enabled || JSON.stringify(root.current) !== JSON.stringify(root.shown)
    text: !root.dependency.enabled ? root.dependency.reason + "; your choice is kept."
      : Registry.displayValue(root.ui, root.current) + " → shows " + Registry.displayValue(root.ui, root.shown)
    wrapMode: Text.WordWrap
    font.italic: true
    font.family: Style.font.family
    font.pixelSize: Style.font.caption
    color: Commons.Color.foreground
  }
  Ui.Toggle {
    width: parent.width
    visible: root.ui.control === "toggle"
    label: root.ui.label
    description: root.ui.help || ""
    checked: root.current === true
    enabled: root.editable
    hasCursor: root.hasCursor
    onClicked: root.commitValue(!root.current)
  }
  Ui.ButtonGroup {
    visible: root.ui.control === "segmented" && !root.pictureTiles
    options: root.options()
    value: String(root.current)
    enabled: root.editable
    onChanged: value => root.commitValue(value)
  }
  Row {
    visible: root.pictureTiles
    width: parent.width
    spacing: Style.space(8)
    Repeater {
      model: [{value:"flat",label:"Single row",icon:"app-window",help:"All apps side by side"},
        {value:"grouped",label:"Card per workspace",icon:"layout-grid",help:"A numbered card for each workspace"}]
      delegate: Ui.Button {
        required property var modelData
        width: (root.width - Style.space(8)) / 2
        height: Style.space(108)
        text: ""
        selected: root.current === modelData.value
        bordered: true
        focusable: true
        enabled: root.editable
        Accessible.name: modelData.label + ". " + modelData.help
        onClicked: root.commitValue(modelData.value)
        Column {
          anchors.centerIn: parent
          width: parent.width - Style.space(12)
          spacing: Style.space(8)
          DockLucideIcon { anchors.horizontalCenter: parent.horizontalCenter; iconName: modelData.icon; iconSize:24; width:24; height:24; tint:Commons.Color.foreground }
          Text { width:parent.width; text:modelData.label; horizontalAlignment:Text.AlignHCenter; wrapMode:Text.WordWrap; color:Commons.Color.foreground; font.family:Style.font.family; font.pixelSize:Style.font.body }
        }
      }
    }
  }
  Ui.Dropdown {
    id: dropdown
    objectName: "setting-dropdown"
    visible: root.ui.control === "dropdown"
    width: Math.min(root.width, Style.space(300))
    options: root.options()
    value: String(root.current)
    enabled: root.editable
    hasCursor: root.hasCursor
    onPopupOpenChanged: {
      if (popupOpen) root.beginEdit()
      else if (root.editing && !root.conflict) root.reloadDraft()
    }
    onChanged: value => {
      root.commitValue(value)
      // The native Dropdown assigns its own value during selection.
      dropdown.value = Qt.binding(function() { return String(root.current) })
    }
  }
  Ui.NumberField {
    id: number
    visible: root.ui.control === "number"
    value: Number(root.editing ? root.draft : root.current)
    from: root.spec.minimum || 0
    to: root.ui.uiMaximum || root.spec.maximum || 64
    enabled: root.editable
    hasCursor: root.hasCursor
    onModified: value => root.commitValue(value)
    Keys.onEscapePressed: { root.reloadDraft(); root.forceActiveFocus() }
    Keys.onTabPressed: { root.commitDraft(); root.focusSections() }
  }
  Connections {
    target: number.field
    function onActiveFocusChanged() { if (number.field.activeFocus) root.beginEdit() }
  }
  Connections {
    target: number.field.contentItem
    function onTextEdited() {
      root.beginEdit()
      var value = Number(number.field.contentItem.text)
      if (isFinite(value)) root.draft = value
    }
  }
  Ui.PanelSlider {
    id: slider
    width: Math.min(root.width, Style.space(300))
    visible: root.ui.control === "slider"
    minimum: root.spec.minimum === undefined ? 0 : root.spec.minimum
    maximum: root.spec.maximum === undefined ? 100 : root.spec.maximum
    value: Number(root.editing ? root.draft : root.current)
    step: root.spec.effectiveStep || (root.spec.type === "integer" ? 1 : 0.05)
    integer: root.spec.type === "integer"
    enabled: root.editable
    onDraggingChanged: if (dragging) { keyboardCommit.stop(); root.beginEdit() }
    onMoved: value => { keyboardCommit.stop(); root.beginEdit(); root.draft = value }
    onReleased: value => { root.beginEdit(); root.draft = value; root.commitDraft() }
  }
  Text {
    visible: root.ui.control === "slider"
    width: parent.width
    text: Registry.displayValue(root.ui, Number(root.editing ? root.draft : root.current))
    color: Commons.Color.foreground
    font.family: Style.font.family
    font.pixelSize: Style.font.caption
    Accessible.role: Accessible.StaticText
    Accessible.name: root.ui.label + ": " + text
  }
  Text {
    visible: root.changedElsewhere || root.feedback !== "" || root.writerBusy
    width: parent.width
    text: root.feedback || (root.writerBusy ? "Saving…" : "Changed elsewhere")
    wrapMode: Text.WordWrap
    color: Commons.Color.foreground
    font.family: Style.font.family
    font.pixelSize: Style.font.caption
    Accessible.role: Accessible.StaticText
    Accessible.name: text
  }
  Row {
    visible: root.needsReset
    spacing: Style.space(8)
    Ui.Button {
      text: "Reset"
      tooltipText: "Reset to default"
      focusable: true
      enabled: root.resettable
      onClicked: root.resetToDefault()
    }
    Text {
      text: "Default: " + String(root.defaultValue)
      font.family: Style.font.family
      font.pixelSize: Style.font.caption
      color: Commons.Color.foreground
      wrapMode: Text.WordWrap
      width: Math.max(0, root.width - Style.space(80))
      anchors.verticalCenter: parent.verticalCenter
    }
  }
  Row {
    visible: root.conflict
    spacing: Style.space(8)
    Ui.Button {
      id: reloadAction
      objectName: "row-reload"
      text: "Reload"
      focusable: true
      onClicked: { root.reloadDraft(); root.forceActiveFocus() }
      Keys.onEscapePressed: { root.reloadDraft(); root.forceActiveFocus() }
    }
    Ui.Button {
      id: keepAction
      objectName: "row-keep"
      text: "Keep editing"
      focusable: true
      onClicked: { root.keepEditing(); root.forceActiveFocus() }
      Keys.onEscapePressed: { root.reloadDraft(); root.forceActiveFocus() }
    }
  }
}
