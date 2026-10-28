pragma ComponentBehavior: Bound
import QtQuick
import qs.Ui as Ui
import qs.Commons
import qs.Commons as Commons
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
  readonly property bool recoveryFocused: reloadAction.activeFocus || keepAction.activeFocus
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
  property string hexDraft: ""
  property bool hexDirty: false
  signal edited()
  signal hovered()
  signal focusSections()
  spacing: Style.space(6)
  width: parent ? parent.width : 400
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
    hexDraft = customHex.text
    editing = true
  }
  function cancelPending() {
    keyboardCommit.stop()
    editing = false
    conflict = false
    customOpen = false
    hexDirty = false
    draftWidth = Number(current || 0)
    feedback = ""
  }
  function hexBinding() {
    return root.editing ? root.hexDraft
      : root.flag && root.selection === "custom" ? String(root.current) : ""
  }
  function reloadDraft() {
    cancelPending()
    // Re-establish the declarative binding instead of assigning once, so the
    // field keeps tracking live values after Reload/Escape.
    customHex.text = Qt.binding(hexBinding)
  }
  function keepEditing() { expected[key] = current; expected[flagKey] = flag; conflict = false; feedback = "" }
  function commitPair(value, enabled) {
    keyboardCommit.stop()
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
      hexDirty = false
      if (isWidth) draftWidth = Number(current)
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
    keyboardCommit.stop()
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
      hexDirty = false
      if (isWidth) draftWidth = Number(defaultValue)
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
        Qt.callLater(function() { if (root.customOpen) customHex.forceActiveFocus() })
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
    if (conflict) return
    if (!editable) return
    if (isWidth) {
      beginEdit()
      draftWidth = Math.max(0,Math.min(8,Number(draftWidth)+delta))
      keyboardCommit.restart()
    } else if (!flag) commitPair(current, true)
  }
  function activate() {
    if (conflict) { reloadAction.forceActiveFocus(); return }
    if (isWidth) choose(flag ? "default" : "custom"); else chooser.open()
  }
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
    color: root.hasCursor ? Commons.Color.accent : Commons.Color.foreground
    font.family: Style.font.family
    font.pixelSize: Style.font.body
    font.bold: true
  }
  Text {
    width: parent.width
    text: root.row.ui.help || ""
    wrapMode: Text.WordWrap
    color: Commons.Color.foreground
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
    onPopupOpenChanged: {
      if (popupOpen) root.beginEdit()
      else if (root.editing && !root.customOpen && !root.conflict) root.reloadDraft()
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
    onDraggingChanged: if (dragging) {keyboardCommit.stop();root.beginEdit()}
    onMoved: value => {keyboardCommit.stop();root.beginEdit();root.draftWidth=value}
    onReleased: value => {root.beginEdit();root.draftWidth=value;root.commitPair(value,true)}
  }
  Ui.TextField {
    id: customHex
    objectName: "paired-hex"
    visible: !root.isWidth && (root.customOpen || (root.flag && root.selection === "custom"))
    width: Math.min(root.width,Style.space(300))
    placeholderText: "#RRGGBB or #AARRGGBB"
    text: root.hexBinding()
    enabled: root.editable
    Accessible.name: root.row.ui.label + " hex value"
    onActiveFocusChanged: if (activeFocus) root.beginEdit()
    onTextEdited: {
      var value = text
      root.beginEdit()
      root.hexDraft = value
      root.hexDirty = true
    }
    onAccepted: root.saveHex()
    onEditingFinished: if (root.hexDirty && !root.conflict) root.saveHex()
    Keys.onEscapePressed: {root.reloadDraft();root.forceActiveFocus()}
  }
  Ui.Button {
    visible: !root.isWidth && root.customOpen
    text: "Apply hex color"
    enabled: root.editable && !root.conflict
    onClicked: if (root.editing) root.saveHex()
  }
  Text {
    width: parent.width
    visible: root.isWidth && root.flag
    text: Registry.displayValue(root.row.ui, Number(root.editing ? root.draftWidth : root.current))
    color: Commons.Color.foreground
    font.family: Style.font.family
    font.pixelSize: Style.font.caption
    Accessible.name: root.row.ui.label + ": " + text
  }
  Text {
    width: parent.width
    visible: root.isWidth && JSON.stringify(root.current) !== JSON.stringify(root.shownValue)
    text: root.shownValue === null ? "Theme width; saved custom value: " + Registry.displayValue(root.row.ui, Number(root.current))
      : Registry.displayValue(root.row.ui, Number(root.current)) + " → shows "
        + Registry.displayValue(root.row.ui, Number(root.shownValue))
    wrapMode: Text.WordWrap
    font.italic: true
    font.family: Style.font.family
    font.pixelSize: Style.font.caption
    color: Commons.Color.foreground
  }
  Text {
    width: parent.width
    visible: root.changedElsewhere || root.feedback !== "" || root.writerBusy
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
      text: "Default: " + (root.defaultFlag === true ? String(root.defaultValue) : "Theme default")
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
      objectName: "paired-reload"
      text: "Reload"
      focusable: true
      onClicked: { root.reloadDraft(); root.forceActiveFocus() }
      Keys.onEscapePressed: { root.reloadDraft(); root.forceActiveFocus() }
    }
    Ui.Button {
      id: keepAction
      objectName: "paired-keep"
      text: "Keep editing"
      focusable: true
      onClicked: { root.keepEditing(); root.forceActiveFocus() }
      Keys.onEscapePressed: { root.reloadDraft(); root.forceActiveFocus() }
    }
  }
}
