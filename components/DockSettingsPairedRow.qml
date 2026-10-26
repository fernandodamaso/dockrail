pragma ComponentBehavior: Bound
import QtQuick
import qs.Ui as Ui
import qs.Commons
import "DockSettingsRegistry.js" as Registry

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
  property bool editing: false
  property var expected: ({})
  property bool conflict: false
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
  Accessible.name: row.ui.label
  onCurrentChanged: if (editing && JSON.stringify(current) !== JSON.stringify(expected[key])) conflict = true
  onFlagChanged: if (editing && flag !== expected[flagKey]) conflict = true

  function beginEdit() {
    if (editing) return
    expected = ({})
    expected[key] = current
    expected[flagKey] = flag
    editing = true
  }
  function cancelPending() { keyboardCommit.stop(); editing = false; conflict = false; customOpen = false; feedback = "" }
  function reloadDraft() { cancelPending(); customHex.text = String(current || "") }
  function keepEditing() { expected[key] = current; expected[flagKey] = flag; conflict = false; feedback = "" }
  function commitPair(value, enabled) {
    if (!editable) return false
    beginEdit()
    if (conflict) { feedback = "Changed while editing. Reload or keep editing."; return false }
    var patch = ({})
    patch[key] = value
    patch[flagKey] = enabled
    var result = Registry.writeOutcome(host.saveSettingsIntent(patch,expected))
    if (result.accepted) {
      editing = false
      conflict = false
      feedback = ""
      edited()
    } else {
      var error = result.reply && result.reply.error
      feedback = error ? error.code + ": " + error.message : "Could not save"
      if (error && error.code === "E_STALE") conflict = true
    }
    return result.accepted
  }
  function choose(value) {
    if (value === "default") { customOpen = false; commitPair(current, false); return }
    if (value === "custom") {
      customOpen = true
      beginEdit()
      return
    }
    customOpen = false
    commitPair(value, true)
  }
  function saveHex() {
    var color = customHex.text.trim()
    if (!/^#[0-9a-fA-F]{6}(?:[0-9a-fA-F]{2})?$/.test(color)) {
      feedback = "Enter a hex color (#RRGGBB or #AARRGGBB)."
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
    } else if (!flag) choose("@accent")
  }
  function activate() { if (isWidth) choose(flag ? "default" : "custom"); else chooser.open() }
  function dismissEditor() {
    if (popupOpen) { chooser.close(); return true }
    if (customOpen || editing) { reloadDraft(); return true }
    return false
  }
  function command() { return Registry.cliCommand(key,current) + " && " + Registry.cliCommand(flagKey,flag) }
  property int draftWidth: Number(current || 0)
  onCurrentChanged: if (!editing) draftWidth = Number(current || 0)
  Timer { id: keyboardCommit; interval: 400; onTriggered: root.commitPair(root.draftWidth,true) }
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
  Ui.Dropdown {
    id: chooser
    visible: !root.isWidth
    width: Math.min(root.width,Style.space(300))
    options: [{value:"default",label:"Theme default"},
      {value:"@accent",label:"Theme accent"},
      {value:"@foreground",label:"Theme foreground"},
      {value:"@menu.background",label:"Theme menu background"},
      {value:"custom",label:"Custom hex…"}]
    value: root.selection
    enabled: root.editable
    hasCursor: root.hasCursor
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
  Ui.BorderSurface {
    visible: !root.isWidth && (root.customOpen || (root.flag && root.selection === "custom"))
    width: Math.min(root.width,Style.space(300))
    height: Style.space(36)
    color: Color.background
    borderSpec: Border.surfaceSpec("popups","border",Color.foreground,1)
    radius: Style.cornerRadius
    TextInput {
      id: customHex
      anchors.fill: parent
      anchors.margins: Style.space(8)
      text: root.flag && root.selection === "custom" ? String(root.current) : ""
      color: Color.foreground
      font.family: Style.font.family
      font.pixelSize: Style.font.body
      selectByMouse: true
      enabled: root.editable
      onActiveFocusChanged: if (activeFocus) root.beginEdit()
      onAccepted: root.saveHex()
      Keys.onEscapePressed: {root.reloadDraft();root.forceActiveFocus()}
    }
  }
  Ui.Button {
    visible: !root.isWidth && root.customOpen
    text: "Apply hex color"
    enabled: root.editable && !root.conflict
    onClicked: root.saveHex()
  }
  Text {
    width: parent.width
    visible: root.feedback !== "" || root.writerBusy || root.conflict
    text: root.feedback || (root.conflict ? "Changed while editing; reload or keep editing." : "Saving…")
    color: Color.foreground
    wrapMode: Text.WordWrap
    font.family: Style.font.family
    font.pixelSize: Style.font.caption
  }
  Row {
    visible: root.conflict
    spacing: Style.space(8)
    Ui.Button {text:"Reload"; onClicked:root.reloadDraft()}
    Ui.Button {text:"Keep editing"; onClicked:root.keepEditing()}
  }
}
