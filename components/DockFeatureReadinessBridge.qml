pragma ComponentBehavior: Bound
import QtQuick
import Quickshell.Io
import "DockFeatureReadinessModel.js" as ReadinessModel

// Exactly one host-owned read-only bridge. Python remains the only detector.
// No UI surface may start a second doctor probe or infer OS facts in QML.
Item {
  id: root
  property bool panelVisible: false
  property var lastGoodFeatures: null
  property bool inFlight: false
  property string lastError: ""
  property int deadlineMs: 3500
  property int pollMs: 6000
  readonly property bool needsPolling: ReadinessModel.shouldPoll(panelVisible, lastGoodFeatures)
  readonly property bool polling: poller.running
  property var executor: doctorProcess

  width: 0
  height: 0
  visible: false

  function refresh() {
    if (!ReadinessModel.canRefresh(panelVisible, inFlight)) return false
    inFlight = true
    lastError = ""
    deadline.restart()
    executor.command = ["dockrail", "doctor", "--json"]
    executor.running = true
    return true
  }
  function focused() { return refresh() }
  function acceptDoctorText(raw, exitCode) {
    if (!inFlight) return false
    deadline.stop()
    inFlight = false
    if (exitCode !== 0) {
      lastError = "dockrail doctor failed"
      return false
    }
    var parsed = ReadinessModel.parseReply(raw)
    if (!parsed) {
      lastError = "Invalid feature readiness reply"
      return false
    }
    lastGoodFeatures = parsed
    lastError = ""
    return true
  }
  function timedOut() {
    if (!inFlight) return
    inFlight = false
    lastError = "Readiness check timed out; displaying last known status"
    if (executor.running) executor.running = false
  }
  onPanelVisibleChanged: {
    if (panelVisible) refresh()
    else {
      poller.stop()
      deadline.stop()
      if (inFlight) {
        inFlight = false
        if (executor.running) executor.running = false
      }
    }
  }
  onNeedsPollingChanged: {
    if (needsPolling) poller.start()
    else poller.stop()
  }
  Component.onDestruction: {
    poller.stop()
    deadline.stop()
    if (executor.running) executor.running = false
  }
  Timer {
    id: poller
    interval: root.pollMs
    repeat: true
    running: root.needsPolling
    onTriggered: root.refresh()
  }
  Timer {
    id: deadline
    interval: root.deadlineMs
    repeat: false
    onTriggered: root.timedOut()
  }
  Process {
    id: doctorProcess
    running: false
    command: ["dockrail", "doctor", "--json"]
    property string output: ""
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: doctorProcess.output = text
    }
    stderr: StdioCollector { waitForEnd: true }
    onExited: function(exitCode) {
      root.acceptDoctorText(doctorProcess.output, exitCode)
      doctorProcess.output = ""
    }
  }
}
