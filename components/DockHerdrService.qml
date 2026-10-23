import QtQuick
import Quickshell
import Quickshell.Io
import "DockHerdrModel.js" as HerdrModel

// One demand-driven Herdr owner for every SmartDock consumer. Merely loading
// this component starts no process. Active leases share one provider process.
Item {
  id: root

  readonly property int ownerCount: leases.length
  property var leases: []
  property int activeCount: 0
  property var latestSnapshot: null
  property string sourceEpoch: ""
  property int sourceRevision: -1
  property int restartDelay: 1000
  property bool stoppingForIdle: false
  property var pendingFocus: ({})
  property int focusSeq: 0
  readonly property int focusDeadlineMs: 5000
  signal focusAgentFinished(string requestId, bool ok, string errorCode)
  readonly property bool running: providerProcess.running
  readonly property bool available: providerPath.length > 0
  property string providerRelativePath: "../provider/herdr/bin/smartdock-herdr-provider"
  readonly property string providerPath: localPath(
    Qt.resolvedUrl(root.providerRelativePath))

  function localPath(url) {
    var value = String(url || "")
    return value.indexOf("file://") === 0 ? decodeURIComponent(value.slice(7)) : value
  }

  function settleFocus(requestId, ok, errorCode) {
    var pending = Object.assign({}, root.pendingFocus || ({}))
    if (!pending[requestId]) return
    delete pending[requestId]
    root.pendingFocus = pending
    root.scheduleFocusDeadline()
    root.focusAgentFinished(requestId, ok === true, String(errorCode || ""))
  }

  function settleAllFocus(errorCode) {
    focusDeadlineTimer.stop()
    var pending = root.pendingFocus || ({})
    var ids = Object.keys(pending)
    root.pendingFocus = ({})
    for (var i = 0; i < ids.length; i++)
      root.focusAgentFinished(ids[i], false, String(errorCode || "provider_unavailable"))
  }

  function scheduleFocusDeadline() {
    var delay = HerdrModel.nextFocusDeadlineDelay(
      root.pendingFocus, Date.now(), root.focusDeadlineMs)
    if (delay < 0) {
      focusDeadlineTimer.stop()
      return
    }
    // One-shot timer always tracks the oldest pending request. A newer focus
    // request therefore cannot postpone an older request's deadline.
    focusDeadlineTimer.interval = Math.max(1, delay)
    focusDeadlineTimer.restart()
  }

  function focusAgent(target) {
    if (root.activeCount <= 0 || !providerProcess.running) return ""
    if (!target || typeof target !== "object") return ""
    var epoch = String(target.providerEpoch || "")
    var serverId = String(target.serverId || "")
    var agentId = String(target.agentId || "")
    var paneId = String(target.paneId || "")
    var generation = Math.floor(Number(target.connectionGeneration))
    if (!epoch || !serverId || !agentId || !paneId) return ""
    if (!isFinite(generation) || generation <= 0) return ""
    var terminalId = String(target.terminalId || "")
    root.focusSeq += 1
    var requestId = "focus-" + String(root.focusSeq)
    var payload = JSON.stringify({
      kind: "focus-agent",
      requestId: requestId,
      providerEpoch: epoch,
      serverId: serverId,
      connectionGeneration: generation,
      agentId: agentId,
      paneId: paneId,
      terminalId: terminalId
    })
    if (payload.length > 4096) return ""
    var pending = Object.assign({}, root.pendingFocus || ({}))
    pending[requestId] = {
      providerEpoch: epoch,
      serverId: serverId,
      connectionGeneration: generation,
      agentId: agentId,
      paneId: paneId,
      terminalId: terminalId,
      startedAt: Date.now()
    }
    root.pendingFocus = pending
    providerProcess.write(payload + "\n")
    root.scheduleFocusDeadline()
    return requestId
  }

  function publishLease(lease, status, data) {
    if (!lease || lease.released || !lease.active || typeof lease.publish !== "function") return
    lease.revision++
    lease.publish({
      status: status,
      revision: lease.revision,
      data: status === "ready" ? data : null
    })
  }

  function broadcast(status, data) {
    root.leases.slice().forEach(function(lease) {
      root.publishLease(lease, status, data)
    })
  }

  function acquire(owner) {
    var lease = {
      owner: owner || null,
      provider: root,
      active: false,
      released: false,
      publish: null,
      revision: 0,
      setActive: function(active, publish) {
        if (lease.released) return
        active = active === true
        if (active) {
          var wasActive = lease.active
          lease.publish = typeof publish === "function" ? publish : null
          if (!wasActive) {
            lease.revision = 0
            lease.active = true
            root.activeCount++
            root.publishLease(lease, "loading", null)
            if (root.activeCount === 1) root.startProvider()
          }
          if (root.latestSnapshot)
            root.publishLease(lease, "ready", root.latestSnapshot)
        } else {
          lease.publish = null
          if (lease.active) {
            lease.active = false
            root.activeCount = Math.max(0, root.activeCount - 1)
            if (root.activeCount === 0) root.stopProvider()
          }
        }
      },
      release: function() {
        if (lease.released) return
        if (lease.active) {
          lease.active = false
          root.activeCount = Math.max(0, root.activeCount - 1)
        }
        lease.publish = null
        lease.released = true
        root.leases = root.leases.filter(function(candidate) {
          return candidate !== lease
        })
        if (root.activeCount === 0) root.stopProvider()
      }
    }
    root.leases = root.leases.concat([lease])
    return lease
  }

  function startProvider() {
    if (root.activeCount <= 0) return
    root.stoppingForIdle = false
    shutdownTimer.stop()
    if (providerProcess.running) return
    restartTimer.stop()
    focusDeadlineTimer.stop()
    root.settleAllFocus("provider_unavailable")
    root.latestSnapshot = null
    root.sourceEpoch = ""
    root.sourceRevision = -1
    root.broadcast("loading", null)
    providerProcess.command = ["python3", "-B", root.providerPath]
    providerProcess.running = true
    startupTimer.restart()
  }

  function stopProvider() {
    restartTimer.stop()
    startupTimer.stop()
    focusDeadlineTimer.stop()
    root.stoppingForIdle = true
    root.latestSnapshot = null
    root.sourceEpoch = ""
    root.sourceRevision = -1
    root.restartDelay = 1000
    root.settleAllFocus("provider_unavailable")
    if (providerProcess.running) {
      providerProcess.write("quit\n")
      shutdownTimer.restart()
    }
  }

  function refresh() {
    if (root.activeCount > 0 && providerProcess.running)
      providerProcess.write("refresh\n")
  }

  function setWindowProcesses(revision, pids) {
    if (root.activeCount <= 0 || !providerProcess.running) return false
    if (typeof revision !== "number" || !isFinite(revision)
        || Math.floor(revision) !== revision || revision < 0) return false
    if (!Array.isArray(pids)) return false
    var normalized = []
    var seen = Object.create(null)
    for (var i = 0; i < pids.length; i++) {
      var pid = pids[i]
      if (typeof pid !== "number" || !isFinite(pid)
          || Math.floor(pid) !== pid || pid <= 0) return false
      var key = String(pid)
      if (seen[key]) continue
      if (normalized.length >= 256) return false
      seen[key] = true
      normalized.push(pid)
    }
    var payload = JSON.stringify({
      kind: "window-processes",
      revision: revision,
      pids: normalized
    })
    if (payload.length > 4096) return false
    providerProcess.write(payload + "\n")
    return true
  }

  function acceptLine(line) {
    if (root.activeCount <= 0 || !line || line.length > 1048576) return
    var value
    try {
      value = JSON.parse(line)
    } catch (error) {
      root.broadcast("error", null)
      return
    }
    if (value && value.kind === "action-result") {
      var requestId = String(value.requestId || "")
      if (!requestId || !(root.pendingFocus && root.pendingFocus[requestId])) return
      var ok = value.ok === true
      var errorCode = ok ? "" : String(value.error || "unsupported")
      root.settleFocus(requestId, ok, errorCode)
      return
    }
    if (!value || value.schemaVersion !== 1
        || typeof value.providerEpoch !== "string"
        || typeof value.revision !== "number"
        || !isFinite(value.revision)
        || Math.floor(value.revision) !== value.revision
        || value.revision < 0) {
      root.broadcast("error", null)
      return
    }
    if (root.sourceEpoch && value.providerEpoch !== root.sourceEpoch) return
    if (root.sourceRevision >= 0 && value.revision <= root.sourceRevision) return
    root.sourceEpoch = value.providerEpoch
    root.sourceRevision = value.revision
    root.latestSnapshot = value
    root.restartDelay = 1000
    root.broadcast("ready", value)
  }

  function providerStopped(exitCode) {
    startupTimer.stop()
    shutdownTimer.stop()
    focusDeadlineTimer.stop()
    root.settleAllFocus("provider_unavailable")
    if (root.stoppingForIdle || root.activeCount <= 0) return
    root.latestSnapshot = null
    root.sourceEpoch = ""
    root.sourceRevision = -1
    root.broadcast("error", null)
    if (!restartTimer.running) {
      restartTimer.interval = root.restartDelay
      root.restartDelay = Math.min(30000, root.restartDelay * 2)
      restartTimer.restart()
    }
  }

  Process {
    id: providerProcess
    running: false
    stdinEnabled: true
    stdout: SplitParser {
      onRead: data => root.acceptLine(data)
    }
    // Drain stderr without surfacing private provider/session data in logs.
    stderr: SplitParser {
      onRead: function(data) {}
    }
    onExited: function(exitCode) {
      root.providerStopped(exitCode)
    }
  }

  Timer {
    id: focusDeadlineTimer
    interval: 1
    repeat: false
    onTriggered: {
      var pending = root.pendingFocus || ({})
      var now = Date.now()
      var expired = HerdrModel.expiredFocusRequestIds(
        pending, now, root.focusDeadlineMs)
      if (!expired.length) {
        root.scheduleFocusDeadline()
        return
      }
      var next = Object.assign({}, pending)
      for (var i = 0; i < expired.length; i++)
        delete next[expired[i]]
      root.pendingFocus = next
      // Publish after removing all expired entries so callbacks cannot observe
      // already-dead requests or have a new request reschedule stale state.
      for (var j = 0; j < expired.length; j++)
        root.focusAgentFinished(expired[j], false, "timeout")
      root.scheduleFocusDeadline()
    }
  }

  Timer {
    id: startupTimer
    interval: 750
    repeat: false
    onTriggered: {
      if (root.activeCount > 0 && !providerProcess.running)
        root.providerStopped(-1)
    }
  }

  Timer {
    id: restartTimer
    interval: 1000
    repeat: false
    onTriggered: root.startProvider()
  }

  Timer {
    id: shutdownTimer
    interval: 750
    repeat: false
    onTriggered: {
      if (root.activeCount === 0 && providerProcess.running)
        providerProcess.running = false
    }
  }

  Component.onDestruction: {
    root.leases.slice().forEach(function(lease) {
      lease.publish = null
      lease.released = true
    })
    root.leases = []
    root.activeCount = 0
    root.stopProvider()
  }
}
