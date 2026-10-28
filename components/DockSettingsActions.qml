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
  property bool installReviewCancelled: false
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
    if (inFlight) return {accepted:false,error:{code:"E_BUSY",message:"An action is already running."}}
    installReviewCancelled = false
    installConfirmation = null
    return start("prepare-install", {source:source})
  }
  function cancelInstall() {
    installConfirmation = null
    if (inFlight && action === "prepare-install") installReviewCancelled = true
    if (!inFlight) status = "idle"
  }
  function confirmInstall(source, confirmed) {
    if (inFlight) return {accepted:false,error:{code:"E_BUSY",message:"An action is already running."}}
    if (confirmed !== true || !installConfirmation
        || source !== installConfirmation.source || !installConfirmation.canInstall)
      return {accepted:false,error:{code:"E_CONFIRMATION",message:"Install requires the reviewed source confirmation."}}
    var outcome = start("install", {source:source,manifest:installConfirmation.manifest})
    if (outcome.accepted) installConfirmation = null
    return outcome
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
      errorCode = result.error ? result.error.code : "E_ACTION"
      errorText = result.error ? result.error.message : "Action failed"
      status = "error"
      return false
    }
    if (previousAction === "prepare-install") {
      if (installReviewCancelled) {
        installReviewCancelled = false
        status = "idle"
        return true
      }
      installConfirmation = result.data ? result.data.confirmation || null : null
      if (!installConfirmation) {
        errorCode = "E_PROTOCOL"
        errorText = "Install review did not return a confirmation."
        status = "error"
        return false
      }
      status = "awaiting-confirmation"
    } else status = "success"
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
