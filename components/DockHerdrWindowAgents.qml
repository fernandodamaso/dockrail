import QtQuick
import "DockModel.js" as DockModel
import "DockHerdrModel.js" as HerdrModel
import "DockSidebarModel.js" as SidebarModel
import "DockWindowModel.js" as WindowModel

// Host-owned Herdr window identity and association bridge. This is the only
// SmartDock object that leases the provider or sends window-process revisions.
Item {
  id: root

  property var herdrService: null
  property var toplevels: []
  property var hyprToplevels: []
  property int scopeRevision: 0
  property bool sidebarConsumerActive: false
  property bool dockConsumerActive: false
  readonly property bool consumerActive: sidebarConsumerActive || dockConsumerActive

  property var registry: ({ nextToken: 1, entries: [] })
  property int windowProcessRevision: 0
  property string windowProcessFingerprint: ""
  property string windowProcessSentEpoch: ""
  property string herdrAssociationEpoch: ""
  property bool windowProcessBootstrapped: false
  property var windowProcessTargets: []
  property var herdrAssociations: ({ byWindowKey: ({}), unmatchedServerIds: [] })
  property var herdrVerifiedParents: ({})
  property var snapshot: null
  property string viewStatus: "loading"
  property int viewRevision: 0
  property bool snapshotReady: false
  property var agentsByAddress: ({})

  // Session-only dock indicator memory. A replacement toplevel receives a new
  // registry key, so it cannot inherit completion acknowledgment or blocked
  // transition state even when its compositor address and PID are reused.
  property var focusedToplevel: null
  property var agentIndicatorStates: ({})
  property var blockedTransitionByWindow: ({})
  property int blockedTransitionSequence: 0
  property int indicatorRevision: 0

  property var serviceLease: null
  property var consumerLeases: []
  property int activeSidebarConsumers: 0
  property bool initialized: false

  function emptyAssociations() {
    return ({ byWindowKey: ({}), unmatchedServerIds: [] })
  }

  function windowKeyFor(toplevel) {
    var entry = SidebarModel.handleEntry(root.registry, toplevel)
    return entry && typeof entry.key === "string" ? entry.key : ""
  }

  function handleFor(toplevel) {
    return WindowModel.handleForToplevel(toplevel, root.hyprToplevels)
  }

  function addressFor(toplevel) {
    var handle = root.handleFor(toplevel)
    return DockModel.normalizeWindowAddress(handle ? handle.address : "")
  }

  function isAlive(toplevel) {
    return !!toplevel && root.liveToplevels().indexOf(toplevel) >= 0
      && root.windowKeyFor(toplevel) !== ""
  }

  function liveToplevels() {
    var live = []
    ;(root.toplevels || []).forEach(function(toplevel) {
      if (toplevel && live.indexOf(toplevel) < 0) live.push(toplevel)
    })
    return live
  }

  function collectWindowProcessTargets() {
    var targets = []
    var entries = root.registry && root.registry.entries ? root.registry.entries : []
    for (var i = 0; i < entries.length; i++) {
      var entry = entries[i]
      if (!entry || !entry.toplevel || !entry.key) continue
      var handle = root.handleFor(entry.toplevel)
      if (!handle) continue
      var pid = (handle.lastIpcObject || ({})).pid
      if (typeof pid !== "number" || !isFinite(pid)
          || Math.floor(pid) !== pid || pid <= 0) continue
      targets.push({ key: entry.key, pid: pid })
    }
    return targets
  }

  function rememberHerdrVerifiedParents(associations, targets) {
    var pidByKey = Object.create(null)
    ;(targets || []).forEach(function(target) {
      if (target && target.key && typeof target.pid === "number")
        pidByKey[target.key] = target.pid
    })
    var next = Object.create(null)
    var byWindow = associations && associations.byWindowKey
      ? associations.byWindowKey : ({})
    Object.keys(byWindow).forEach(function(windowKey) {
      var serverId = byWindow[windowKey]
      var pid = pidByKey[windowKey]
      if (typeof serverId === "string" && serverId && typeof pid === "number")
        next[windowKey] = { serverId: serverId, pid: pid }
    })
    root.herdrVerifiedParents = next
  }

  function preservedHerdrAssociations(targets) {
    var pidByKey = Object.create(null)
    ;(targets || []).forEach(function(target) {
      if (target && target.key && typeof target.pid === "number")
        pidByKey[target.key] = target.pid
    })
    var byWindowKey = ({})
    var retained = Object.create(null)
    var verified = root.herdrVerifiedParents || ({})
    Object.keys(verified).forEach(function(windowKey) {
      var entry = verified[windowKey]
      if (!entry || pidByKey[windowKey] !== entry.pid || !entry.serverId) return
      byWindowKey[windowKey] = entry.serverId
      retained[windowKey] = { serverId: entry.serverId, pid: entry.pid }
    })
    root.herdrVerifiedParents = retained
    return ({ byWindowKey: byWindowKey, unmatchedServerIds: [] })
  }

  function clearHerdrAssociations(options) {
    if (options && options.preserveParents === true)
      root.herdrAssociations = root.preservedHerdrAssociations(root.windowProcessTargets)
    else {
      root.herdrAssociations = root.emptyAssociations()
      root.herdrVerifiedParents = ({})
    }
    root.herdrAssociationEpoch = ""
    root.snapshotReady = false
    root.agentsByAddress = ({})
  }

  function indicatorStateKey(windowKey, serverId, agentId) {
    return JSON.stringify([String(windowKey || ""), String(serverId || ""),
      String(agentId || "")])
  }

  function indicatorStateWindowKey(key) {
    try {
      var parts = JSON.parse(key)
      return Array.isArray(parts) ? String(parts[0] || "") : ""
    } catch (error) {
      return ""
    }
  }

  function liveServerById(serverId) {
    var servers = root.snapshot && Array.isArray(root.snapshot.servers)
      ? root.snapshot.servers : []
    for (var i = 0; i < servers.length; i++) {
      var server = servers[i]
      if (!server || String(server.id || "") !== String(serverId || "")) continue
      // Older/local snapshots did not publish health. Treat only an explicit
      // non-live health as a gap so those snapshots retain their live contract.
      return !server.health || String(server.health) === "live" ? server : null
    }
    return null
  }

  function agentsForWindowKey(windowKey) {
    if (!root.snapshotReady || !root.snapshot || !windowKey) return []
    var serverId = root.herdrAssociations.byWindowKey[windowKey]
    var server = serverId ? root.liveServerById(serverId) : null
    if (!server) return []
    var focusAgentSupported = HerdrModel.serverFocusAgentSupported(server)
    var agents = Array.isArray(root.snapshot.agents) ? root.snapshot.agents : []
    return agents.filter(function(agent) {
      return agent && String(agent.serverId || "") === String(serverId)
    }).map(function(agent) {
      return Object.assign({}, agent, {
        focusAgentSupported: focusAgentSupported
      })
    })
  }

  function pruneIndicatorStates() {
    var live = Object.create(null)
    var entries = root.registry && root.registry.entries ? root.registry.entries : []
    entries.forEach(function(entry) {
      if (entry && entry.key) live[entry.key] = true
    })
    var nextStates = ({})
    var changed = false
    Object.keys(root.agentIndicatorStates || ({})).forEach(function(key) {
      if (live[root.indicatorStateWindowKey(key)]) nextStates[key] = root.agentIndicatorStates[key]
      else changed = true
    })
    var nextBlocked = ({})
    Object.keys(root.blockedTransitionByWindow || ({})).forEach(function(windowKey) {
      if (live[windowKey]) nextBlocked[windowKey] = root.blockedTransitionByWindow[windowKey]
      else changed = true
    })
    if (!changed) return
    root.agentIndicatorStates = nextStates
    root.blockedTransitionByWindow = nextBlocked
    root.indicatorRevision++
  }

  function focusedWindowKey() {
    return root.windowKeyFor(root.focusedToplevel)
  }

  function updateIndicatorTransitions() {
    if (!root.snapshotReady || !root.snapshot) return
    var next = Object.assign({}, root.agentIndicatorStates || ({}))
    var blocked = Object.assign({}, root.blockedTransitionByWindow || ({}))
    var focusedKey = root.focusedWindowKey()
    var changed = false
    var entries = root.registry && root.registry.entries ? root.registry.entries : []
    entries.forEach(function(entry) {
      if (!entry || !entry.key) return
      var serverId = root.herdrAssociations.byWindowKey[entry.key]
      if (!serverId || !root.liveServerById(serverId)) return
      root.agentsForWindowKey(entry.key).forEach(function(agent) {
        var agentId = String(agent && agent.id || "")
        if (!agentId) return
        var status = HerdrModel.normalizeStatus(agent.status)
        var key = root.indicatorStateKey(entry.key, serverId, agentId)
        var previous = next[key]
        var state = previous ? Object.assign({}, previous) : {
          lastLiveStatus: status,
          completionSeq: 0,
          acknowledgedSeq: 0
        }
        if (previous) {
          if (status === "done" && previous.lastLiveStatus !== "done")
            state.completionSeq = Number(previous.completionSeq || 0) + 1
          if (status === "blocked" && previous.lastLiveStatus !== "blocked") {
            root.blockedTransitionSequence++
            blocked[entry.key] = root.blockedTransitionSequence
          }
          state.lastLiveStatus = status
        }
        // Focusing means the current completion has already been seen. Apply
        // this in the same live-snapshot turn so a completion that arrives
        // while focused never flashes an unseen check.
        if (entry.key === focusedKey && status === "done")
          state.acknowledgedSeq = state.completionSeq
        if (!previous || JSON.stringify(previous) !== JSON.stringify(state)) {
          next[key] = state
          changed = true
        }
      })
    })
    if (JSON.stringify(blocked) !== JSON.stringify(root.blockedTransitionByWindow)) {
      root.blockedTransitionByWindow = blocked
      changed = true
    }
    if (!changed) return
    root.agentIndicatorStates = next
    root.indicatorRevision++
  }

  function acknowledgeWindow(toplevel) {
    var windowKey = root.windowKeyFor(toplevel)
    if (!windowKey || !root.snapshotReady) return
    var serverId = root.herdrAssociations.byWindowKey[windowKey]
    if (!serverId || !root.liveServerById(serverId)) return
    var current = Object.create(null)
    root.agentsForWindowKey(windowKey).forEach(function(agent) {
      if (agent && agent.id) current[root.indicatorStateKey(
        windowKey, serverId, agent.id)] = true
    })
    var next = Object.assign({}, root.agentIndicatorStates || ({}))
    var changed = false
    Object.keys(next).forEach(function(key) {
      if (!current[key]) return
      var state = next[key]
      if (!state || state.lastLiveStatus !== "done"
          || Number(state.acknowledgedSeq || 0) >= Number(state.completionSeq || 0)) return
      next[key] = Object.assign({}, state, {
        acknowledgedSeq: Number(state.completionSeq || 0)
      })
      changed = true
    })
    if (!changed) return
    root.agentIndicatorStates = next
    root.indicatorRevision++
  }

  function summaryForToplevels(toplevels) {
    var revision = root.indicatorRevision
    var empty = HerdrModel.windowAgentSummary([], ({}))
    empty.herdrWindowCount = 0
    empty.blockedTransitionRevision = 0
    empty.blockedAddresses = []
    if (!root.snapshotReady || !root.snapshot) return empty

    var agents = []
    var acknowledged = ({})
    var windowCount = 0
    var blockedRevision = 0
    var blockedAddresses = []
    ;(toplevels || []).forEach(function(toplevel) {
      var windowKey = root.windowKeyFor(toplevel)
      var serverId = root.herdrAssociations.byWindowKey[windowKey]
      var rows = root.agentsForWindowKey(windowKey)
      if (!windowKey || !serverId || rows.length === 0) return
      windowCount++
      blockedRevision = Math.max(blockedRevision,
        Number(root.blockedTransitionByWindow[windowKey] || 0))
      var address = root.addressFor(toplevel).toLowerCase()
      var hasBlocked = false
      rows.forEach(function(agent) {
        var stateKey = root.indicatorStateKey(windowKey, serverId, agent.id)
        agents.push(Object.assign({}, agent, { indicatorKey: stateKey }))
        var state = root.agentIndicatorStates[stateKey]
        if (HerdrModel.normalizeStatus(agent.status) === "done" && state
            && Number(state.acknowledgedSeq || 0) >= Number(state.completionSeq || 0))
          acknowledged[stateKey] = true
        if (HerdrModel.normalizeStatus(agent.status) === "blocked") hasBlocked = true
      })
      if (hasBlocked && address && blockedAddresses.indexOf(address) < 0)
        blockedAddresses.push(address)
    })
    var summary = HerdrModel.windowAgentSummary(agents, acknowledged)
    summary.herdrWindowCount = windowCount
    summary.blockedTransitionRevision = blockedRevision
    summary.blockedAddresses = blockedAddresses
    return summary
  }

  function rebuildPublishedAgents() {
    var result = ({})
    if (!root.snapshotReady || !root.snapshot) {
      root.agentsByAddress = result
      return
    }
    var agents = Array.isArray(root.snapshot.agents) ? root.snapshot.agents : []
    var servers = Array.isArray(root.snapshot.servers) ? root.snapshot.servers : []
    var focusSupportedByServer = Object.create(null)
    servers.forEach(function(server) {
      if (!server || !server.id) return
      focusSupportedByServer[String(server.id)] =
        HerdrModel.serverFocusAgentSupported(server)
    })
    var entries = root.registry && root.registry.entries ? root.registry.entries : []
    for (var i = 0; i < entries.length; i++) {
      var entry = entries[i]
      if (!entry || !entry.key || !entry.toplevel) continue
      var serverId = root.herdrAssociations.byWindowKey[entry.key]
      var address = root.addressFor(entry.toplevel).toLowerCase()
      if (!serverId || !address) continue
      result[address] = agents.filter(function(agent) {
        return agent && String(agent.serverId || "") === serverId
      }).map(function(agent) {
        return Object.assign({}, agent, {
          focusAgentSupported: focusSupportedByServer[serverId] === true
        })
      })
    }
    root.agentsByAddress = result
  }

  function syncHerdrWindowProcesses() {
    if (!root.initialized) return
    root.registry = SidebarModel.reconcileHandles(root.registry, root.liveToplevels())
    root.pruneIndicatorStates()
    var targets = root.collectWindowProcessTargets()
    var fingerprint = HerdrModel.windowProcessFingerprint(targets)
    var fingerprintChanged = fingerprint !== root.windowProcessFingerprint
    var bootstrapping = !root.windowProcessBootstrapped
    if (fingerprintChanged || bootstrapping) {
      root.windowProcessBootstrapped = true
      root.windowProcessFingerprint = fingerprint
      root.windowProcessTargets = targets
      root.windowProcessRevision++
      root.clearHerdrAssociations({ preserveParents: true })
      root.windowProcessSentEpoch = ""
    } else {
      root.windowProcessTargets = targets
    }

    var provider = root.herdrService
    if (!root.consumerActive || !provider
        || typeof provider.setWindowProcesses !== "function"
        || provider.running === false) {
      root.windowProcessSentEpoch = ""
      root.clearHerdrAssociations({ preserveParents: true })
      return
    }
    var epoch = typeof provider.sourceEpoch === "string" ? provider.sourceEpoch : ""
    if (root.herdrAssociationEpoch && root.herdrAssociationEpoch !== epoch)
      root.clearHerdrAssociations({ preserveParents: true })
    if ((fingerprintChanged || bootstrapping || root.windowProcessSentEpoch !== epoch)
        && root.windowProcessRevision > 0) {
      var pids = HerdrModel.normalizeWindowProcessPids(targets.map(function(row) {
        return row.pid
      }))
      if (provider.setWindowProcesses(root.windowProcessRevision, pids)) {
        root.windowProcessSentEpoch = epoch
        if (!fingerprintChanged && !bootstrapping)
          root.clearHerdrAssociations({ preserveParents: true })
      }
    }
    if (root.viewStatus !== "ready" || !root.snapshot) {
      root.clearHerdrAssociations({ preserveParents: true })
      return
    }
    var resolved = HerdrModel.resolveAssociations({
      revision: root.windowProcessRevision,
      epoch: root.windowProcessSentEpoch,
      targets: root.windowProcessTargets
    }, root.snapshot)
    if (!resolved) {
      root.clearHerdrAssociations({ preserveParents: true })
      return
    }
    root.herdrAssociations = resolved
    root.herdrAssociationEpoch = root.snapshot.providerEpoch || epoch
    root.rememberHerdrVerifiedParents(resolved, root.windowProcessTargets)
    root.snapshotReady = root.herdrAssociationEpoch !== ""
    root.rebuildPublishedAgents()
    root.updateIndicatorTransitions()
  }

  function publishConsumer(lease) {
    if (!lease || lease.released || !lease.active || typeof lease.publish !== "function") return
    lease.revision++
    lease.publish({
      status: root.viewStatus,
      revision: lease.revision,
      data: root.viewStatus === "ready" ? root.snapshot : null
    })
  }

  function publishConsumers() {
    root.consumerLeases.slice().forEach(root.publishConsumer)
  }

  function createConsumerLease(owner) {
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
        lease.publish = active && typeof publish === "function" ? publish : null
        if (lease.active !== active) {
          lease.active = active
          root.activeSidebarConsumers += active ? 1 : -1
          root.activeSidebarConsumers = Math.max(0, root.activeSidebarConsumers)
          root.sidebarConsumerActive = root.activeSidebarConsumers > 0
        }
        if (active) root.publishConsumer(lease)
      },
      release: function() {
        if (lease.released) return
        if (lease.active) root.activeSidebarConsumers = Math.max(0,
          root.activeSidebarConsumers - 1)
        lease.active = false
        lease.publish = null
        lease.released = true
        root.sidebarConsumerActive = root.activeSidebarConsumers > 0
        root.consumerLeases = root.consumerLeases.filter(function(candidate) {
          return candidate !== lease
        })
      }
    }
    root.consumerLeases = root.consumerLeases.concat([lease])
    return lease
  }

  function acceptServiceView(value) {
    root.viewStatus = value && typeof value.status === "string" ? value.status : "error"
    root.viewRevision++
    root.snapshot = root.viewStatus === "ready" && value ? value.data : null
    root.syncHerdrWindowProcesses()
    root.publishConsumers()
  }

  function syncServiceLease() {
    if (root.serviceLease) {
      root.serviceLease.release()
      root.serviceLease = null
    }
    if (root.herdrService && typeof root.herdrService.acquire === "function")
      root.serviceLease = root.herdrService.acquire("host.herdr-window-agents")
    root.updateServiceLease()
  }

  function updateServiceLease() {
    if (!root.serviceLease) return
    root.serviceLease.setActive(root.consumerActive, function(value) {
      root.acceptServiceView(value)
    })
    if (!root.consumerActive) {
      root.viewStatus = "loading"
      root.snapshot = null
      root.clearHerdrAssociations({ preserveParents: true })
      root.publishConsumers()
    }
    root.syncHerdrWindowProcesses()
  }

  function currentAgent(windowKey, agentId) {
    if (!root.snapshotReady || !root.snapshot || !windowKey || !agentId) return null
    var serverId = root.herdrAssociations.byWindowKey[windowKey]
    if (!serverId) return null
    var agents = Array.isArray(root.snapshot.agents) ? root.snapshot.agents : []
    for (var i = 0; i < agents.length; i++) {
      var agent = agents[i]
      if (agent && String(agent.id || "") === String(agentId)
          && String(agent.serverId || "") === String(serverId)) return agent
    }
    return null
  }

  onHerdrServiceChanged: if (initialized) root.syncServiceLease()
  onConsumerActiveChanged: if (initialized) root.updateServiceLease()
  onToplevelsChanged: root.syncHerdrWindowProcesses()
  onHyprToplevelsChanged: root.syncHerdrWindowProcesses()
  onScopeRevisionChanged: root.syncHerdrWindowProcesses()
  onFocusedToplevelChanged: root.acknowledgeWindow(root.focusedToplevel)

  Connections {
    target: root.herdrService
    ignoreUnknownSignals: true
    function onRunningChanged() { root.syncHerdrWindowProcesses() }
    function onSourceEpochChanged() { root.syncHerdrWindowProcesses() }
    function onSourceRevisionChanged() { root.syncHerdrWindowProcesses() }
  }

  Component.onCompleted: {
    root.initialized = true
    root.syncServiceLease()
    root.syncHerdrWindowProcesses()
  }
  Component.onDestruction: {
    root.initialized = false
    root.consumerLeases.slice().forEach(function(lease) { lease.release() })
    if (root.serviceLease) root.serviceLease.release()
  }
}
