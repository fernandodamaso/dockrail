pragma ComponentBehavior: Bound
import QtQuick
import Quickshell.Io
import "DockSettingsActionModel.js" as Actions

// Single-flight typed API: no free-form shell, generic command, or second
// settings writer. This process only owns Widget scaffolds/install and (once
// INF-4 is shipped) explicit managed agent launchers.
Item {
  id: root
  property bool inFlight: false
  property string action: ""
  property string status: "idle"
  property string errorCode: ""
  property string errorText: ""
  property var result: null
  property var installConfirmation: null
  property var executor: actionProcess
  readonly property string scriptPath: decodeURIComponent(
    String(Qt.resolvedUrl("../scripts/smartdock_settings_actions.py")).replace(/^file:\/\//, ""))
  width: 0
  height: 0
  visible: false

  function start(actionName, data) {
    if (inFlight) return {accepted:false, error:{code:"E_BUSY",message:"An action is already running."}}
    var argv = Actions.argumentsFor(actionName, data)
    if (!argv) return {accepted:false, error:{code:"E_VALIDATION",message:"Invalid typed action parameters."}}
    inFlight = true
    action = actionName
    status = "running"
    errorCode = ""
    errorText = ""
    executor.command = ["python3", "-B", scriptPath].concat(argv)
    executor.running = true
    return {accepted:true, action:actionName}
  }
  function prepareInstall(source) {
    installConfirmation = null
    return start("prepare-install", {source:source})
  }
  function confirmInstall(source, confirmed) {
    if (confirmed !== true || !installConfirmation
        || source !== installConfirmation.source || !installConfirmation.canInstall)
      return {accepted:false,error:{code:"E_CONFIRMATION",message:"Install requires the reviewed source confirmation."}}
    installConfirmation = null
    return start("install", {source:source})
  }
  function createWidget(id, name) { return start("create", {id:id, name:name}) }
  function manageLaunchers(add) { return start(add ? "launchers-add" : "launchers-remove", {}) }

  function finish(output, exitCode) {
    if (!inFlight) return false
    var previousAction = action
    inFlight = false
    action = ""
    result = Actions.replyFrom(output, exitCode)
    if (!result.ok) {
      status = "error"
      errorCode = result.error ? result.error.code : "E_ACTION"
      errorText = result.error ? result.error.message : "Action failed"
      return false
    }
    status = "success"
    if (previousAction === "prepare-install") {
      installConfirmation = result.data ? result.data.confirmation || null : null
      if (!installConfirmation) {
        status = "error"
        errorCode = "E_PROTOCOL"
        return false
      }
      status = "awaiting-confirmation"
    }
    return true
  }
  Process {
    id: actionProcess
    running: false
    property string output: ""
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: actionProcess.output = text
    }
    stderr: StdioCollector { waitForEnd: true }
    onExited: function(exitCode) {
      root.finish(actionProcess.output, exitCode)
      actionProcess.output = ""
    }
  }
}
