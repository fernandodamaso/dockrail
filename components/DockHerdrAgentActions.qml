import QtQuick
import "DockHerdrModel.js" as HerdrModel

// Host-owned exact-capture Herdr focus orchestration. Targets are captured and
// revalidated against DockHerdrWindowAgents, never sidebar projection rows.
Item {
  id: root

  required property var bridge
  required property var windowActions
  property var herdrService: null
  property string latestFocusRequestId: ""
  property var pendingFocusByRequest: ({})
  property var pendingFocusByAgent: ({})
  property var focusErrors: ({})

  function herdrAgentFocusKey(target) {
    if (!target) return ""
    return [String(target.windowKey || ""), String(target.serverId || ""),
      String(target.agentId || ""), String(target.paneId || "")].join("\0")
  }

  function serverFocusSupported(serverId) {
    var servers = root.bridge && root.bridge.snapshot && Array.isArray(root.bridge.snapshot.servers)
      ? root.bridge.snapshot.servers : []
    for (var i = 0; i < servers.length; i++) {
      if (servers[i] && String(servers[i].id || "") === String(serverId))
        return HerdrModel.serverFocusAgentSupported(servers[i])
    }
    return false
  }

  function captureAgentTarget(toplevel, agent) {
    if (!toplevel || !agent || !root.bridge || !root.windowActions) return null
    var windowKey = root.bridge.windowKeyFor(toplevel)
    var canonical = root.bridge.currentAgent(windowKey, String(agent.agentId || agent.id || ""))
    if (!canonical) return null
    var serverId = root.bridge.herdrAssociations.byWindowKey[windowKey]
    var supported = root.serverFocusSupported(serverId)
    var generation = Math.floor(Number(canonical.connectionGeneration))
    var paneId = String(canonical.paneId || "")
    var agentId = String(canonical.id || "")
    var epoch = String(root.bridge.herdrAssociationEpoch || "")
    var address = String(root.bridge.addressFor(toplevel) || "").toLowerCase()
    if (!supported || !windowKey || !address || !epoch || !serverId || !agentId
        || !paneId || !isFinite(generation) || generation <= 0) return null
    return {
      key: String(agent.key || ""),
      kind: String(agent.kind || "herdr-agent"),
      windowKey: windowKey,
      toplevel: toplevel,
      address: address,
      providerEpoch: epoch,
      serverId: String(serverId),
      connectionGeneration: generation,
      agentId: agentId,
      paneId: paneId,
      terminalId: String(canonical.terminalId || ""),
      focusAgentSupported: true
    }
  }

  function targetIsCurrent(target) {
    if (!target || !root.bridge || !root.windowActions
        || target.focusAgentSupported !== true) return false
    if (!root.bridge.isAlive(target.toplevel)
        || !root.windowActions.isAlive(target.toplevel)) return false
    if (root.bridge.windowKeyFor(target.toplevel) !== String(target.windowKey || "")) return false
    if (String(root.bridge.addressFor(target.toplevel) || "").toLowerCase()
        !== String(target.address || "").toLowerCase()) return false
    if (!root.bridge.snapshotReady
        || root.bridge.herdrAssociationEpoch !== String(target.providerEpoch || "")) return false
    if (root.bridge.herdrAssociations.byWindowKey[target.windowKey]
        !== String(target.serverId || "")) return false
    if (!root.serverFocusSupported(target.serverId)) return false
    var agent = root.bridge.currentAgent(target.windowKey, target.agentId)
    return !!agent
      && String(agent.serverId || "") === String(target.serverId || "")
      && Number(agent.connectionGeneration) === Number(target.connectionGeneration)
      && String(agent.paneId || "") === String(target.paneId || "")
      && String(agent.terminalId || "") === String(target.terminalId || "")
  }

  function clearFocusError(key) {
    if (!key || !root.focusErrors[key]) return
    var next = Object.assign({}, root.focusErrors)
    delete next[key]
    root.focusErrors = next
  }

  function setFocusError(key, errorCode) {
    if (!key) return
    var next = Object.assign({}, root.focusErrors || ({}))
    next[key] = { code: String(errorCode || "unsupported"), expiresAt: Date.now() + 4000 }
    root.focusErrors = next
    focusErrorTimer.restart()
  }

  function focusErrorFor(key) {
    var entry = root.focusErrors && root.focusErrors[key]
    if (!entry) return ""
    if (Date.now() >= Number(entry.expiresAt || 0)) {
      root.clearFocusError(key)
      return ""
    }
    return String(entry.code || "")
  }

  function activateHerdrTarget(target) {
    if (!root.targetIsCurrent(target)) return false
    root.clearFocusError(target.key)
    var agentKey = root.herdrAgentFocusKey(target)
    var existingId = root.pendingFocusByAgent[agentKey]
    if (existingId && root.pendingFocusByRequest[existingId]) {
      root.latestFocusRequestId = existingId
      return true
    }
    if (!root.herdrService || typeof root.herdrService.focusAgent !== "function") {
      root.setFocusError(target.key, "provider_unavailable")
      return false
    }
    return !!root.enqueueHerdrFocus(target, agentKey, false)
  }

  function enqueueHerdrFocus(target, agentKey, afterRaise) {
    if (!root.targetIsCurrent(target) || !root.herdrService
        || typeof root.herdrService.focusAgent !== "function") return ""
    var requestId = root.herdrService.focusAgent({
      providerEpoch: target.providerEpoch,
      serverId: target.serverId,
      connectionGeneration: Math.floor(Number(target.connectionGeneration)),
      agentId: target.agentId,
      paneId: target.paneId,
      terminalId: target.terminalId
    })
    if (!requestId) {
      if (!afterRaise) root.setFocusError(target.key, "provider_unavailable")
      return ""
    }
    var pending = Object.assign({}, target, {
      agentKey: agentKey,
      afterRaise: afterRaise === true
    })
    var byRequest = Object.assign({}, root.pendingFocusByRequest)
    byRequest[requestId] = pending
    root.pendingFocusByRequest = byRequest
    var byAgent = Object.assign({}, root.pendingFocusByAgent)
    byAgent[agentKey] = requestId
    root.pendingFocusByAgent = byAgent
    root.latestFocusRequestId = requestId
    return requestId
  }

  function onHerdrFocusFinished(requestId, ok, errorCode) {
    var pending = root.pendingFocusByRequest[requestId]
    if (!pending) return
    var byRequest = Object.assign({}, root.pendingFocusByRequest)
    delete byRequest[requestId]
    root.pendingFocusByRequest = byRequest
    if (root.pendingFocusByAgent[pending.agentKey] === requestId) {
      var byAgent = Object.assign({}, root.pendingFocusByAgent)
      delete byAgent[pending.agentKey]
      root.pendingFocusByAgent = byAgent
    }
    var isLatest = root.latestFocusRequestId === requestId
    if (!ok) {
      if (isLatest) root.setFocusError(pending.key, errorCode || "unsupported")
      return
    }
    if (!isLatest || !root.targetIsCurrent(pending) || pending.afterRaise) return
    // The first focus is confirmed. Revalidate before raising, then again before
    // requesting pane focus because activation can synchronously change state.
    if (!root.windowActions.activateToplevel(pending.toplevel, true, "", true)) return
    if (!root.targetIsCurrent(pending)) return
    root.enqueueHerdrFocus(pending, pending.agentKey, true)
  }

  Connections {
    target: root.herdrService
    ignoreUnknownSignals: true
    function onFocusAgentFinished(requestId, ok, errorCode) {
      root.onHerdrFocusFinished(requestId, ok, errorCode)
    }
  }

  Timer {
    id: focusErrorTimer
    interval: 1000
    repeat: true
    onTriggered: {
      var errors = root.focusErrors || ({})
      var next = Object.assign({}, errors)
      var changed = false
      Object.keys(errors).forEach(function(key) {
        if (Date.now() >= Number(errors[key].expiresAt || 0)) {
          delete next[key]
          changed = true
        }
      })
      if (changed) root.focusErrors = next
      if (!Object.keys(root.focusErrors).length) focusErrorTimer.stop()
    }
  }
}
