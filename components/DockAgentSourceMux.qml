import QtQuick
import "DockAgentSourceModel.js" as AgentSourceModel

// Merges Herdr and T3 provider views behind the exact DockHerdrService API
// consumers use (acquire, available, running, sourceEpoch, sourceRevision,
// setWindowProcesses, refresh, focusAgent, focusAgentFinished). Each source
// keeps its own provider epoch and revision; the merge happens after that
// point, so a stale or hung source can be isolated without blocking the
// healthy one.
Item {
  id: root

  // [{ id: "herdr", service: <DockHerdrService>, enabled: bool }, ...]
  property var sources: []
  property var leases: []
  property int activeCount: 0
  property string sourceEpoch: ""
  property int sourceRevision: -1
  property bool running: false
  property bool available: false
  signal focusAgentFinished(string requestId, bool ok, string errorCode)

  property var childLeases: ({})
  property var childServices: ({})
  property var childViews: ({})
  property var lagging: ({})
  property var focusRoutes: ({})
  property int pendingRevision: -1
  property bool lagDeadlineReached: false
  property var lastMerged: null

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
            // Publish before driving children: child leases publish
            // synchronously inside setActive, which re-enters this mux and
            // then the bridge while we are still activating.
            if (root.lastMerged) root.publishLease(lease, "ready", root.lastMerged)
            else root.publishLease(lease, "loading", null)
            root.syncChildLeases()
          } else if (root.lastMerged) {
            root.publishLease(lease, "ready", root.lastMerged)
          }
        } else {
          lease.publish = null
          if (lease.active) {
            lease.active = false
            root.activeCount = Math.max(0, root.activeCount - 1)
            root.syncChildLeases()
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
        root.syncChildLeases()
      }
    }
    root.leases = root.leases.concat([lease])
    return lease
  }

  function sourceEntry(id) {
    for (var i = 0; i < root.sources.length; i++) {
      var entry = root.sources[i]
      if (entry && entry.id === id) return entry
    }
    return null
  }

  function purgeFocusRoutes(sourceId) {
    var prefix = String(sourceId) + ":"
    var routes = Object.assign({}, root.focusRoutes || ({}))
    var changed = false
    for (var key in routes) {
      if (key.indexOf(prefix) === 0) {
        delete routes[key]
        changed = true
      }
    }
    if (changed) root.focusRoutes = routes
  }

  function syncChildLeases() {
    var wanted = Object.create(null)
    for (var i = 0; i < root.sources.length; i++) {
      (function(entry) {
        if (!entry || typeof entry.id !== "string") return
        wanted[entry.id] = true
        var lease = root.childLeases[entry.id]
        if (entry.service && root.childServices[entry.id] !== entry.service) {
          if (lease) lease.release()
          delete root.childViews[entry.id]
          delete root.childLeases[entry.id]
          delete root.childServices[entry.id]
          delete root.lagging[entry.id]
          root.purgeFocusRoutes(entry.id)
          lease = null
          if (root.pendingRevision >= 0 && !root.lagDeadlineReached && !lagTimer.running)
            lagTimer.start()
        }
        if (!entry.service) {
          if (lease) {
            lease.release()
            delete root.childLeases[entry.id]
            delete root.childServices[entry.id]
          }
          delete root.childViews[entry.id]
          delete root.lagging[entry.id]
          root.purgeFocusRoutes(entry.id)
          return
        }
        if (entry.enabled !== true) root.purgeFocusRoutes(entry.id)
        if (!lease) {
          lease = entry.service.acquire("agent-source-mux." + entry.id)
          root.childLeases[entry.id] = lease
          root.childServices[entry.id] = entry.service
        }
        var shouldBeActive = root.activeCount > 0 && entry.enabled === true
        if (lease.active !== shouldBeActive) {
          (function(sourceId, target, active) {
            target.setActive(active, function(value) {
              root.childPublished(sourceId, value)
            })
          })(entry.id, lease, shouldBeActive)
        }
      })(root.sources[i])
    }
    for (var id in root.childLeases) {
      if (!wanted[id]) {
        root.childLeases[id].release()
        delete root.childLeases[id]
        delete root.childServices[id]
        delete root.childViews[id]
        delete root.lagging[id]
        root.purgeFocusRoutes(id)
      }
    }
    if (root.activeCount > 0) root.republish()
  }

  function childPublished(sourceId, value) {
    root.childViews[sourceId] = value
    root.republish()
  }

  function childChanged(sourceId) {
    root.updateSourceEpoch()
    if (root.pendingRevision >= 0 && !root.lagDeadlineReached && !lagTimer.running)
      lagTimer.start()
    root.republish()
  }

  function updateSourceEpoch() {
    var rows = []
    for (var i = 0; i < root.sources.length; i++) {
      var entry = root.sources[i]
      if (!entry) continue
      rows.push({
        id: entry.id,
        epoch: entry.service ? String(entry.service.sourceEpoch || "") : "",
        enabled: entry.enabled === true,
        running: !!(entry.service && entry.service.running)
      })
    }
    root.sourceEpoch = AgentSourceModel.compositeEpoch(rows)
    var anyRunning = false
    var anyAvailable = false
    for (var j = 0; j < root.sources.length; j++) {
      var candidate = root.sources[j]
      if (!candidate || candidate.enabled !== true || !candidate.service) continue
      if (candidate.service.running) anyRunning = true
      if (candidate.service.available !== false) anyAvailable = true
    }
    root.running = anyRunning
    root.available = anyAvailable
  }

  function evaluateLag() {
    if (root.pendingRevision < 0) return
    var candidates = []
    var current = Object.create(null)
    var anyCurrent = false
    for (var i = 0; i < root.sources.length; i++) {
      var entry = root.sources[i]
      if (!entry || entry.enabled !== true) continue
      candidates.push(entry.id)
      var view = root.childViews[entry.id]
      var snapshot = view && view.status === "ready" ? view.data : null
      var revision = snapshot && snapshot.windowProcesses
        ? snapshot.windowProcesses.revision : -2
      if (revision === root.pendingRevision) {
        current[entry.id] = true
        anyCurrent = true
      }
    }
    if (candidates.length <= 1) {
      // A lone source is never lagging: Herdr alone keeps today's wait.
      // A lone current source also ends the race.
      for (var stale in root.lagging) delete root.lagging[stale]
      if (candidates.length === 1 && current[candidates[0]]) {
        root.pendingRevision = -1
        root.lagDeadlineReached = false
        lagTimer.stop()
      }
      return
    }
    // No current evidence anywhere: keep waiting, exclude nothing.
    if (!anyCurrent) return
    var allCurrent = true
    for (var j = 0; j < candidates.length; j++) {
      if (current[candidates[j]]) delete root.lagging[candidates[j]]
      else {
        // Keep both inventories during the grace interval, even if one
        // provider already echoed the requested window revision.
        if (root.lagDeadlineReached) root.lagging[candidates[j]] = true
        allCurrent = false
      }
    }
    // Every enabled source current: the race is over.
    if (allCurrent) {
      root.pendingRevision = -1
      root.lagDeadlineReached = false
      lagTimer.stop()
    }
  }

  function republish() {
    root.evaluateLag()
    root.updateSourceEpoch()
    var entries = []
    var statuses = []
    var laggingAny = false
    for (var i = 0; i < root.sources.length; i++) {
      var entry = root.sources[i]
      if (!entry || entry.enabled !== true || !entry.service) continue
      var view = root.childViews[entry.id]
      var status = view && typeof view.status === "string"
        ? view.status : (entry.service.running ? "loading" : "unavailable")
      statuses.push(status)
      if (root.lagging[entry.id]) {
        laggingAny = true
        continue
      }
      if (!entry.service.running) continue
      if (!view || view.status !== "ready" || !view.data
          || typeof view.data !== "object") continue
      entries.push({ id: entry.id, snapshot: view.data })
    }
    if (entries.length > 0) {
      root.sourceRevision++
      var merged = AgentSourceModel.mergeSnapshots(entries, root.sourceEpoch, root.sourceRevision)
      root.lastMerged = merged
      root.broadcast("ready", merged)
      return
    }
    root.lastMerged = null
    var idle = statuses.indexOf("loading") >= 0 || laggingAny
      ? "loading" : AgentSourceModel.mergeStatus(statuses)
    root.broadcast(idle, null)
  }

  function setWindowProcesses(revision, pids) {
    if (root.activeCount <= 0) return false
    if (typeof revision !== "number" || !isFinite(revision)
        || Math.floor(revision) !== revision || revision < 0) return false
    if (!Array.isArray(pids)) return false
    var called = 0
    var ok = true
    for (var i = 0; i < root.sources.length; i++) {
      var entry = root.sources[i]
      if (!entry || entry.enabled !== true || !entry.service) continue
      if (entry.service.running === false) continue
      if (typeof entry.service.setWindowProcesses !== "function") {
        ok = false
        continue
      }
      called++
      if (!entry.service.setWindowProcesses(revision, pids)) ok = false
    }
    if (called === 0) return false
    // A repeated send for the same revision must not postpone the deadline.
    if (revision !== root.pendingRevision) {
      root.pendingRevision = revision
      root.lagDeadlineReached = false
      for (var id in root.lagging) delete root.lagging[id]
      lagTimer.restart()
    }
    return ok
  }

  function refresh() {
    if (root.activeCount <= 0) return
    for (var i = 0; i < root.sources.length; i++) {
      var entry = root.sources[i]
      if (!entry || entry.enabled !== true || !entry.service) continue
      if (typeof entry.service.refresh === "function") entry.service.refresh()
    }
  }

  function focusAgent(target) {
    if (root.activeCount <= 0 || !target || typeof target !== "object") return ""
    var serverId = String(target.serverId || "")
    if (!serverId) return ""
    var merged = root.lastMerged
    var found = null
    if (merged && Array.isArray(merged.servers)) {
      for (var i = 0; i < merged.servers.length; i++) {
        if (merged.servers[i] && merged.servers[i].id === serverId) {
          found = merged.servers[i]
          break
        }
      }
    }
    var sourceId = found
      ? String(found.source || AgentSourceModel.sourceIdForServerId(serverId))
      : AgentSourceModel.sourceIdForServerId(serverId)
    var entry = root.sourceEntry(sourceId)
    if (!entry || entry.enabled !== true || !entry.service) return ""
    var epoch = found && typeof found.providerEpoch === "string" && found.providerEpoch
      ? found.providerEpoch : String(entry.service.sourceEpoch || "")
    var childId = entry.service.focusAgent(Object.assign({}, target, {
      providerEpoch: epoch
    }))
    if (typeof childId !== "string" || !childId) return ""
    var muxId = sourceId + ":" + childId
    var routes = Object.assign({}, root.focusRoutes)
    routes[muxId] = { sourceId: sourceId, childId: childId }
    root.focusRoutes = routes
    return muxId
  }

  function routeFocusFinished(sourceId, childId, ok, errorCode) {
    var muxId = String(sourceId) + ":" + String(childId)
    var routes = Object.assign({}, root.focusRoutes || ({}))
    if (!routes[muxId]) return
    delete routes[muxId]
    root.focusRoutes = routes
    var entry = root.sourceEntry(String(sourceId))
    if (!entry || entry.enabled !== true || !entry.service) return
    if (!root.childLeases[String(sourceId)]) return
    root.focusAgentFinished(muxId, ok === true, String(errorCode || ""))
  }

  onSourcesChanged: {
    root.syncChildLeases()
    root.updateSourceEpoch()
    root.republish()
  }

  Instantiator {
    model: root.sources
    delegate: Connections {
      target: modelData.service
      ignoreUnknownSignals: true
      function onRunningChanged() { root.republish() }
      function onSourceEpochChanged() { root.childChanged(modelData.id) }
      function onSourceRevisionChanged() { root.republish() }
      function onFocusAgentFinished(requestId, ok, errorCode) {
        root.routeFocusFinished(modelData.id, requestId, ok, errorCode)
      }
    }
  }

  Timer {
    id: lagTimer
    interval: 2000
    repeat: false
    onTriggered: {
      root.lagDeadlineReached = true
      root.republish()
    }
  }

  Component.onDestruction: {
    // Invalidate handed-out leases first so late release()/setActive() calls
    // from consumers destroyed after us return before touching root.
    root.leases.slice().forEach(function(lease) {
      lease.publish = null
      lease.released = true
    })
    root.leases = []
    root.activeCount = 0
    for (var id in root.childLeases) {
      try {
        root.childLeases[id].release()
      } catch (error) {}
    }
    root.childLeases = ({})
    root.childServices = ({})
  }
}
