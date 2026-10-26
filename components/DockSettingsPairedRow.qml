pragma ComponentBehavior: Bound
import QtQuick
import qs.Ui as Ui
import qs.Commons
import "DockSettingsRegistry.js" as Registry
import "DockSettingsPairModel.js" as PairModel

// A pair is one user control and one stale-safe host writer transaction.
Column {
  id: root
  required property var host
  required property var row
  property bool hasCursor: false
  property bool feedbackActive: true
  readonly property string key: row.key
  readonly property string flagKey: row.ui.pairedWith || ""
  readonly property bool isWidth: key === "borderWidth"
  readonly property var current: host.settings[key]
  readonly property bool flag: host.settings[flagKey] === true
  readonly property bool writerBusy: host.settingsWriteState === "saving"
    || host.settingsReloadPending === true || host.settingsLoaded === false
  readonly property bool editable: host.settingsLoadState !== "invalid" && !writerBusy
  readonly property bool popupOpen: chooser.popupOpen
  readonly property bool textFocused: customHex.activeFocus
  readonly property string selection: flag ? (isWidth ? "custom" : (String(current).charAt(0) === "@" ? String(current) : "custom")) : "default"
  readonly property var shownValue: host.shownSetting ? host.shownSetting(key) : current
  readonly property var defaultValue: host.defaultSetting ? host.defaultSetting(key) : undefined
  readonly property var defaultFlag: host.defaultSetting ? host.defaultSetting(flagKey) : undefined
  readonly property bool resettable: host.settingsLoadState !== "invalid" && !writerBusy
    && host.defaultSetting !== undefined
  readonly property bool needsReset: resettable && defaultValue !== undefined && defaultFlag !== undefined
    && (JSON.stringify(current) !== JSON.stringify(defaultValue)
      || JSON.stringify(flag) !== JSON.stringify(defaultFlag))
  property bool editing: false
  property var expected: ({})
  property bool conflict: false
  property bool localWrite: false
  property bool initialized: false
  property bool changedElsewhere: false
  property string feedback: ""
  property bool customOpen: false
  signal edited()
  signal hovered()
  signal focusSections()
  spacing: Style.space(6)
  width: parent ? parent.width : 400
  opacity: editable ? 1 : 0.6
  Accessible.role: Accessible.Grouping
  Accessible.name: row.ui.label + (conflict ? ", changed while editing" : changedElsewhere ? ", changed elsewhere" : "")
  onCurrentChanged: {
    if (!initialized || localWrite) return
    if (editing && JSON.stringify(current) !== JSON.stringify(expected[key])) conflict = true
    if (!editing) draftWidth = Number(current || 0)
    if (feedbackActive) {
      changedElsewhere = true
      highlight.restart()
    }
  }
  onFlagChanged: {
    if (!initialized || localWrite) return
    if (editing && flag !== expected[flagKey]) conflict = true
    if (feedbackActive) {
      changedElsewhere = true
      highlight.restart()
    }
  }
  Component.onCompleted: initialized = true

  function beginEdit() {
    if (editing) return
    expected = PairModel.pairExpected(key,flagKey,current,flag)
    editing = true
  }
  function cancelPending() { keyboardCommit.stop(); editing = false; conflict = false; customOpen = false; feedback = "" }
  function hexBinding() { return root.flag && root.selection === "custom" ? String(root.current) : "" }
  function reloadDraft() {
    cancelPending()
    // Re-establish the declarative binding instead of assigning once, so the
    // field keeps tracking live values after Reload/Escape.
    customHex.text = Qt.binding(hexBinding)
  }
  function keepEditing() { expected[key] = current; expected[flagKey] = flag; conflict = false; feedback = "" }
  function commitPair(value, enabled) {
    if (!editable) return false
    beginEdit()
    if (conflict) { feedback = "Changed while editing. Reload or keep editing."; return false }
    var patch = PairModel.pairPatch(key,flagKey,value,enabled)
    localWrite = true
    var result = Registry.writeOutcome(host.saveSettingsIntent(patch,expected))
    localWrite = false
    if (result.accepted) {
      editing = false
      conflict = false
      changedElsewhere = false
      feedback = ""
      edited()
    } else {
      var error = result.reply && result.reply.error
      feedback = error ? error.code + ": " + error.message : "Could not save"
      if (error && error.code === "E_STALE") conflict = true
    }
    return result.accepted
  }
  function resetToDefault() {
    if (!resettable || defaultValue === undefined || defaultFlag === undefined) return false
    if (!editing) beginEdit()
    if (conflict) { feedback = "Changed while editing. Reload or keep editing."; return false }
    if (writerBusy) { feedback = "Saving… wait for readback before changing another value."; return false }
    // One atomic patch for both keys through the same stale-safe writer.
    var patch = PairModel.pairPatch(key,flagKey,defaultValue,defaultFlag === true)
    localWrite = true
    var outcome = Registry.writeOutcome(host.saveSettingsIntent(patch,expected))
    localWrite = false
    if (outcome.accepted) {
      editing = false
      conflict = false
      changedElsewhere = false
      customOpen = false
      feedback = ""
      edited()
    } else {
      var resetError = outcome.reply && outcome.reply.error
      feedback = resetError ? resetError.code + ": " + resetError.message : "Could not save"
      if (resetError && resetError.code === "E_STALE") conflict = true
    }
    return outcome.accepted
  }
  function choose(value) {
    if (value === "default") { customOpen = false; commitPair(current, false); return }
    if (value === "custom") {
      if (isWidth) {
        customOpen = false
        commitPair(current, true)
      } else {
        customOpen = true
        beginEdit()
      }
      return
    }
    customOpen = false
    commitPair(value, true)
  }
  function saveHex() {
    var color = customHex.text.trim()
    // Schema help permits an empty value with the override flag on.
    if (color !== "" && !PairModel.validHex(color) && color.charAt(0) !== "@") {
      feedback = "Enter a hex color (#RRGGBB or #AARRGGBB) or a @theme.token."
      return false
    }
    var saved = commitPair(color, true)
    if (saved) customOpen = false
    return saved
  }
  function adjust(delta) {
    if (!editable) return
    if (isWidth) {
      beginEdit()
      draftWidth = Math.max(0,Math.min(8,Number(draftWidth)+delta))
      keyboardCommit.restart()
    } else if (!flag) commitPair(current, true)
  }
  function activate() { if (isWidth) choose(flag ? "default" : "custom"); else chooser.open() }
  function dismissEditor() {
    if (popupOpen) { chooser.close(); return true }
    if (customOpen || editing) { reloadDraft(); return true }
    return false
  }
  function command() { return Registry.cliCommand(key,current) + " && " + Registry.cliCommand(flagKey,flag) }
  property int draftWidth: Number(current || 0)
  Timer { id: keyboardCommit; interval: 400; onTriggered: root.commitPair(root.draftWidth,true) }
  Timer { id: highlight; interval: 3000; onTriggered: root.changedElsewhere = false }
  HoverHandler { onHoveredChanged: if (hovered) root.hovered() }

  Text {
    width: parent.width
    text: root.row.ui.label
    color: root.hasCursor ? Color.accent : Color.foreground
    font.family: Style.font.family
    font.pixelSize: Style.font.body
    font.bold: true
  }
  Text {
    width: parent.width
    text: root.row.ui.help || ""
    wrapMode: Text.WordWrap
    color: Color.foreground
    opacity: 0.8
    font.family: Style.font.family
    font.pixelSize: Style.font.caption
  }
  Ui.ButtonGroup {
    visible: root.isWidth
    options: [{value:"default",label:"Theme default"},{value:"custom",label:"Custom"}]
    value: root.flag ? "custom" : "default"
    enabled: root.editable
    onChanged: value => root.choose(value)
  }
  Ui.SearchableDropdown {
    id: chooser
    visible: !root.isWidth
    width: Math.min(root.width,Style.space(300))
    options: PairModel.colorOptions()
    value: root.selection
    enabled: root.editable
    hasCursor: root.hasCursor
    Accessible.name: root.row.ui.label
    onChanged: value => {
      root.choose(value)
      chooser.value = Qt.binding(function() {return root.selection})
    }
  }
  Ui.PanelSlider {
    visible: root.isWidth && root.flag
    width: Math.min(root.width,Style.space(300))
    minimum: 0
    maximum: 8
    integer: true
    step: 1
    value: root.editing ? root.draftWidth : Number(root.current)
    enabled: root.editable
    onDraggingChanged: if (dragging) root.beginEdit()
    onMoved: value => {root.beginEdit();root.draftWidth=value}
    onReleased: value => {root.beginEdit();root.draftWidth=value;root.commitPair(value,true)}
  }
  Ui.TextField {
    id: customHex
    objectName: "paired-hex"
    visible: !root.isWidth && (root.customOpen || (root.flag && root.selection === "custom"))
    width: Math.min(root.width,Style.space(300))
    placeholderText: "#RRGGBB or #AARRGGBB"
    text: root.flag && root.selection === "custom" ? String(root.current) : ""
    enabled: root.editable
    Accessible.name: root.row.ui.label + " hex value"
    onActiveFocusChanged: if (activeFocus) root.beginEdit()
    onAccepted: root.saveHex()
    Keys.onEscapePressed: {root.reloadDraft();root.forceActiveFocus()}
  }
  Ui.Button {
    visible: !root.isWidth && root.customOpen
    text: "Apply hex color"
    enabled: root.editable && !root.conflict
    onClicked: root.saveHex()
  }
  Text {
    width: parent.width
    visible: root.isWidth && JSON.stringify(root.current) !== JSON.stringify(root.shownValue)
    text: Registry.displayValue(root.row.ui, Number(root.current)) + " → shows "
      + Registry.displayValue(root.row.ui, Number(root.shownValue))
    wrapMode: Text.WordWrap
    font.italic: true
    font.family: Style.font.family
    font.pixelSize: Style.font.caption
    color: Color.foreground
  }
  Text {
    width: parent.width
    visible: root.changedElsewhere || root.feedback !== "" || root.writerBusy
    text: root.feedback || (root.writerBusy ? "Saving…" : "Changed elsewhere")
    wrapMode: Text.WordWrap
    color: Color.foreground
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
      text: "Default: " + (root.defaultFlag === true ? String(root.defaultValue) : "Theme default")
      font.family: Style.font.family
      font.pixelSize: Style.font.caption
      color: Color.foreground
      wrapMode: Text.WordWrap
      width: Math.max(0, root.width - Style.space(80))
      anchors.verticalCenter: parent.verticalCenter
    }
  }
  Row {
    visible: root.conflict
    spacing: Style.space(8)
    Ui.Button {text:"Reload"; onClicked:root.reloadDraft()}
    Ui.Button {text:"Keep editing"; onClicked:root.keepEditing()}
  }
}
