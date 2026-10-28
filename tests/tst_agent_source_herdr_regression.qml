import QtQuick
import QtTest
import "../components"
import "../components/DockSidebarModel.js" as SidebarModel

// Herdr end-to-end regression through the mux: the real bridge and the real
// actions behave identically whether wired straight to Herdr or through
// DockAgentSourceMux, and either stale source is isolated without leaking
// cached rows into the other side.
TestCase {
  id: testCase
  name: "AgentSourceHerdrRegression"
  when: windowShown
  width: 320
  height: 240

  Component {
    id: windowFactory
    QtObject { property string title: "Terminal" }
  }

  Component {
    id: stubFactory
    QtObject {
      property string sourceId: "herdr"
      property string sourceEpoch: "epoch-herdr"
      property int sourceRevision: 0
      property bool running: true
      property bool available: true
      property var writes: []
      property var publish: null
      property var focusCalls: []
      property int focusSequence: 0
      signal focusAgentFinished(string requestId, bool ok, string errorCode)
      function acquire(owner) {
        var self = this
        var lease = {
          active: false,
          released: false,
          setActive: function(active, callback) {
            active = active === true
            if (active) {
              self.publish = typeof callback === "function" ? callback : null
              lease.active = true
            } else {
              self.publish = null
              lease.active = false
            }
          },
          release: function() {
            lease.released = true
            lease.active = false
            self.publish = null
          }
        }
        return lease
      }
      function setWindowProcesses(revision, pids) {
        writes = writes.concat([{ revision: revision, pids: pids.slice() }])
        return true
      }
      function publishSnapshot(snapshot) {
        sourceEpoch = snapshot.providerEpoch
        sourceRevision = snapshot.revision
        if (publish) publish({ status: "ready", revision: snapshot.revision, data: snapshot })
      }
      function focusAgent(target) {
        focusCalls = focusCalls.concat([Object.assign({}, target)])
        focusSequence++
        return "focus-" + focusSequence
      }
    }
  }

  Component {
    id: windowActionsFactory
    QtObject {
      property var live: []
      property var handles: []
      property int raises: 0
      function isAlive(toplevel) { return live.indexOf(toplevel) >= 0 }
      function addressFor(toplevel) {
        for (var i = 0; i < handles.length; i++)
          if (handles[i].wayland === toplevel) return handles[i].address
        return ""
      }
      function activateToplevel(toplevel) {
        if (!isAlive(toplevel)) return false
        raises++
        return true
      }
    }
  }

  function herdrSnapshot(epoch, revision, wpRevision, agents) {
    return {
      schemaVersion: 1, providerEpoch: epoch, revision: revision,
      capabilities: { inventory: true, attention: true, remote: false, actions: true },
      servers: [{
        id: "srv", transport: "local", host: "local", session: "default",
        label: "Local Herdr", capabilities: { focusAgent: true },
        connectionGeneration: 1, health: "live", connected: true,
        clients: [{ pid: 41, startTime: 41, ancestors: [{ pid: 40, startTime: 40 }] }]
      }],
      agents: agents || [], attention: [],
      liveCounts: { blocked: 0, working: (agents || []).length },
      completeness: { state: "complete" },
      windowProcesses: { revision: wpRevision, identities: [{ pid: 40, startTime: 40 }] }
    }
  }

  function t3Snapshot(epoch, revision, wpRevision, agents, extra) {
    var snap = {
      schemaVersion: 1, providerEpoch: epoch, revision: revision,
      capabilities: { inventory: true, attention: true, remote: false, actions: true },
      servers: [{
        id: "t3:env-1", source: "t3", product: "T3 Code", transport: "local",
        host: "local", sessions: [], session: "", label: "T3 Code",
        capabilities: { focusAgent: true },
        connectionGeneration: 1, health: "live", connected: true,
        clients: [{ pid: 51, startTime: 51, ancestors: [{ pid: 50, startTime: 50 }] }]
      }],
      agents: agents || [], attention: [],
      liveCounts: { blocked: 0, working: (agents || []).length },
      completeness: { state: "complete" },
      windowProcesses: { revision: wpRevision, identities: [{ pid: 50, startTime: 50 }] }
    }
    if (extra) {
      if (extra.health) {
        snap.servers[0].health = extra.health
        snap.servers[0].connected = extra.health === "live"
      }
      if (extra.completeness) snap.completeness = extra.completeness
      if (extra.liveCounts !== undefined) snap.liveCounts = extra.liveCounts
      if (extra.serverPatch) Object.assign(snap.servers[0], extra.serverPatch)
    }
    return snap
  }

  function herdrAgent() {
    return { id: "srv:1:pane-a", serverId: "srv", connectionGeneration: 1,
      paneId: "pane-a", terminalId: "term-a", title: "Agent", status: "working", live: true }
  }

  function t3Agent() {
    return { id: "t3:env-1:1:thread-1", serverId: "t3:env-1", connectionGeneration: 1,
      paneId: "thread-1", title: "Thread", status: "working", live: true }
  }

  function wiring(service) {
    var winH = createTemporaryObject(windowFactory, testCase)
    var winT = createTemporaryObject(windowFactory, testCase)
    var windowActions = createTemporaryObject(windowActionsFactory, testCase)
    windowActions.live = [winH, winT]
    windowActions.handles = [
      { wayland: winH, address: "0xA1", lastIpcObject: { pid: 40 } },
      { wayland: winT, address: "0xB2", lastIpcObject: { pid: 50 } }
    ]
    var bridge = createTemporaryObject(Qt.createComponent("../components/DockHerdrWindowAgents.qml"),
      testCase, { herdrService: service, toplevels: windowActions.live,
        hyprToplevels: windowActions.handles })
    verify(bridge !== null)
    var actions = createTemporaryObject(Qt.createComponent("../components/DockHerdrAgentActions.qml"),
      testCase, { bridge: bridge, windowActions: windowActions, herdrService: service })
    verify(actions !== null)
    bridge.dockConsumerActive = true
    return { winH: winH, winT: winT, windowActions: windowActions,
      bridge: bridge, actions: actions }
  }

  function stubs() {
    var herdr = createTemporaryObject(stubFactory, testCase, { sourceId: "herdr" })
    var t3 = createTemporaryObject(stubFactory, testCase,
      { sourceId: "t3", sourceEpoch: "epoch-t3" })
    return { herdr: herdr, t3: t3 }
  }

  function test_disabledMuxMatchesDirectWiring() {
    var direct = stubs()
    var w1 = wiring(direct.herdr)
    w1.bridge.syncHerdrWindowProcesses()
    direct.herdr.publishSnapshot(herdrSnapshot("epoch-herdr", 1, w1.bridge.windowProcessRevision, [herdrAgent()]))
    tryCompare(w1.bridge, "snapshotReady", true)

    var pair = stubs()
    var mux = createTemporaryObject(Qt.createComponent("../components/DockAgentSourceMux.qml"), testCase)
    verify(mux !== null)
    mux.sources = [
      { id: "herdr", service: pair.herdr, enabled: true },
      { id: "t3", service: pair.t3, enabled: false }
    ]
    var w2 = wiring(mux)
    w2.bridge.syncHerdrWindowProcesses()
    pair.herdr.publishSnapshot(herdrSnapshot("epoch-herdr", 1, w2.bridge.windowProcessRevision, [herdrAgent()]))
    tryCompare(w2.bridge, "snapshotReady", true)

    compare(JSON.stringify(w1.bridge.herdrAssociations.byWindowKey),
      JSON.stringify(w2.bridge.herdrAssociations.byWindowKey))
    compare(JSON.stringify(w1.bridge.agentsByAddress),
      JSON.stringify(w2.bridge.agentsByAddress))
  }

  function test_focusCarriesHerdrEpochThroughMux() {
    var pair = stubs()
    var mux = createTemporaryObject(Qt.createComponent("../components/DockAgentSourceMux.qml"), testCase)
    mux.sources = [
      { id: "herdr", service: pair.herdr, enabled: true },
      { id: "t3", service: pair.t3, enabled: true }
    ]
    var w = wiring(mux)
    w.bridge.syncHerdrWindowProcesses()
    var revision = w.bridge.windowProcessRevision
    pair.herdr.publishSnapshot(herdrSnapshot("epoch-herdr", 1, revision, [herdrAgent()]))
    pair.t3.publishSnapshot(t3Snapshot("epoch-t3", 1, revision, [t3Agent()]))
    tryCompare(w.bridge, "snapshotReady", true)
    var agent = w.bridge.summaryForToplevels([w.winH]).rows[0]
    var target = w.actions.captureAgentTarget(w.winH,
      Object.assign({ key: "dock-row", kind: "herdr-agent" }, agent))
    verify(target !== null)
    verify(w.actions.activateHerdrTarget(target))
    compare(pair.herdr.focusCalls.length, 1)
    compare(pair.herdr.focusCalls[0].providerEpoch, "epoch-herdr")
    compare(pair.t3.focusCalls.length, 0)
    w.actions.onHerdrFocusFinished(pair.herdr.focusCalls.length
      ? "herdr:focus-1" : "herdr:focus-1", true, "")
    compare(w.windowActions.raises, 1)
  }

  function test_staleT3RejoinsHerdrBridge() {
    var pair = stubs()
    var mux = createTemporaryObject(Qt.createComponent("../components/DockAgentSourceMux.qml"), testCase)
    mux.sources = [
      { id: "herdr", service: pair.herdr, enabled: true },
      { id: "t3", service: pair.t3, enabled: true }
    ]
    var w = wiring(mux)
    w.bridge.syncHerdrWindowProcesses()
    var r1 = w.bridge.windowProcessRevision
    pair.herdr.publishSnapshot(herdrSnapshot("epoch-herdr", 1, r1, [herdrAgent()]))
    pair.t3.publishSnapshot(t3Snapshot("epoch-t3", 1, r1, [t3Agent()]))
    tryCompare(w.bridge, "snapshotReady", true)
    // New window forces a fresh window-process revision both must echo.
    var winNew = createTemporaryObject(windowFactory, testCase)
    w.windowActions.live = [w.winH, w.winT, winNew]
    w.windowActions.handles = w.windowActions.handles.concat(
      [{ wayland: winNew, address: "0xC3", lastIpcObject: { pid: 60 } }])
    w.bridge.toplevels = w.windowActions.live
    w.bridge.hyprToplevels = w.windowActions.handles
    w.bridge.syncHerdrWindowProcesses()
    var r2 = w.bridge.windowProcessRevision
    verify(r2 !== r1)
    pair.herdr.publishSnapshot(herdrSnapshot("epoch-herdr", 2, r2, [herdrAgent()]))
    var herdrOnly = null
    var deadline = Date.now() + 4000
    while (!herdrOnly && Date.now() < deadline) {
      wait(100)
      var rows = w.bridge.summaryForToplevels([w.winH, w.winT]).rows
      var t3rows = rows.filter(function(row) { return String(row.serverId || "") === "t3:env-1" })
      var hrows = rows.filter(function(row) { return String(row.serverId || "") === "srv" })
      if (hrows.length === 1 && t3rows.length === 0) herdrOnly = rows
    }
    verify(herdrOnly !== null, "Herdr recovers while T3 is stale")
    pair.t3.publishSnapshot(t3Snapshot("epoch-t3", 2, r2, [t3Agent()]))
    var both = null
    deadline = Date.now() + 2000
    while (!both && Date.now() < deadline) {
      wait(100)
      var rows2 = w.bridge.summaryForToplevels([w.winH, w.winT]).rows
      if (rows2.filter(function(row) { return String(row.serverId || "") === "t3:env-1" }).length === 1
          && rows2.filter(function(row) { return String(row.serverId || "") === "srv" }).length === 1)
        both = rows2
    }
    verify(both !== null, "T3 rejoins after its echo")
  }

  function test_truncatedT3KeepsHerdrTitle() {
    var pair = stubs()
    var mux = createTemporaryObject(Qt.createComponent("../components/DockAgentSourceMux.qml"), testCase)
    mux.sources = [
      { id: "herdr", service: pair.herdr, enabled: true },
      { id: "t3", service: pair.t3, enabled: true }
    ]
    var w = wiring(mux)
    w.bridge.syncHerdrWindowProcesses()
    var revision = w.bridge.windowProcessRevision
    pair.herdr.publishSnapshot(herdrSnapshot("epoch-herdr", 1, revision, []))
    pair.t3.publishSnapshot(t3Snapshot("epoch-t3", 1, revision, [], {
      completeness: { state: "partial", truncated: true, agentTruncated: true },
      serverPatch: { sourceCompleteness: { state: "partial", truncated: true, agentTruncated: true },
        sourceLiveCountsKnown: true }
    }))
    tryCompare(w.bridge, "snapshotReady", true)
    var merged = mux.lastMerged
    verify(merged !== null)
    var herdrServer = null
    var t3Server = null
    for (var i = 0; i < merged.servers.length; i++) {
      if (merged.servers[i].id === "srv") herdrServer = merged.servers[i]
      if (merged.servers[i].id === "t3:env-1") t3Server = merged.servers[i]
    }
    verify(herdrServer !== null && t3Server !== null)
    compare(SidebarModel.herdrStateTitle(herdrServer, merged), "No active agents")
  }

  function test_staleHerdrYieldsToT3AndRejoins() {
    var pair = stubs()
    var mux = createTemporaryObject(Qt.createComponent("../components/DockAgentSourceMux.qml"), testCase)
    mux.sources = [
      { id: "herdr", service: pair.herdr, enabled: true },
      { id: "t3", service: pair.t3, enabled: true }
    ]
    var w = wiring(mux)
    w.bridge.syncHerdrWindowProcesses()
    var r1 = w.bridge.windowProcessRevision
    pair.herdr.publishSnapshot(herdrSnapshot("epoch-herdr", 1, r1, [herdrAgent()]))
    pair.t3.publishSnapshot(t3Snapshot("epoch-t3", 1, r1, [t3Agent()]))
    tryCompare(w.bridge, "snapshotReady", true)
    var winNew = createTemporaryObject(windowFactory, testCase)
    w.windowActions.live = [w.winH, w.winT, winNew]
    w.windowActions.handles = w.windowActions.handles.concat(
      [{ wayland: winNew, address: "0xC3", lastIpcObject: { pid: 60 } }])
    w.bridge.toplevels = w.windowActions.live
    w.bridge.hyprToplevels = w.windowActions.handles
    w.bridge.syncHerdrWindowProcesses()
    var r2 = w.bridge.windowProcessRevision
    verify(r2 !== r1)
    pair.t3.publishSnapshot(t3Snapshot("epoch-t3", 2, r2, [t3Agent()]))
    var t3Only = null
    var deadline = Date.now() + 4000
    while (!t3Only && Date.now() < deadline) {
      wait(100)
      var rows = w.bridge.summaryForToplevels([w.winH, w.winT]).rows
      var t3rows = rows.filter(function(row) { return String(row.serverId || "") === "t3:env-1" })
      var hrows = rows.filter(function(row) { return String(row.serverId || "") === "srv" })
      if (t3rows.length === 1 && hrows.length === 0) t3Only = rows
    }
    verify(t3Only !== null, "T3 associates while Herdr is stale")
    var agent = w.bridge.summaryForToplevels([w.winT]).rows[0]
    var target = w.actions.captureAgentTarget(w.winT,
      Object.assign({ key: "dock-row", kind: "herdr-agent" }, agent))
    verify(target !== null)
    verify(w.actions.activateHerdrTarget(target))
    compare(pair.t3.focusCalls.length, 1)
    compare(pair.herdr.focusCalls.length, 0)
    pair.herdr.publishSnapshot(herdrSnapshot("epoch-herdr", 2, r2, [herdrAgent()]))
    var both = null
    deadline = Date.now() + 2000
    while (!both && Date.now() < deadline) {
      wait(100)
      var rows2 = w.bridge.summaryForToplevels([w.winH, w.winT]).rows
      if (rows2.length === 2) both = rows2
    }
    verify(both !== null, "Herdr rejoins after its echo")
  }

  function test_t3OutageWithdrawsCachedAgents() {
    var pair = stubs()
    var mux = createTemporaryObject(Qt.createComponent("../components/DockAgentSourceMux.qml"), testCase)
    mux.sources = [
      { id: "herdr", service: pair.herdr, enabled: true },
      { id: "t3", service: pair.t3, enabled: true }
    ]
    var w = wiring(mux)
    w.bridge.syncHerdrWindowProcesses()
    var revision = w.bridge.windowProcessRevision
    pair.herdr.publishSnapshot(herdrSnapshot("epoch-herdr", 1, revision, [herdrAgent()]))
    pair.t3.publishSnapshot(t3Snapshot("epoch-t3", 1, revision, [t3Agent()]))
    tryCompare(w.bridge, "snapshotReady", true)
    compare(w.bridge.summaryForToplevels([w.winH, w.winT]).rows.length, 2)
    pair.t3.publishSnapshot(t3Snapshot("epoch-t3", 2, revision, [], {
      health: "connecting", liveCounts: null,
      completeness: { state: "unknown", truncated: false }
    }))
    var withdrawn = null
    var deadline = Date.now() + 2000
    while (!withdrawn && Date.now() < deadline) {
      wait(100)
      var rows = w.bridge.summaryForToplevels([w.winH, w.winT]).rows
      if (rows.filter(function(row) { return String(row.serverId || "") === "t3:env-1" }).length === 0
          && rows.filter(function(row) { return String(row.serverId || "") === "srv" }).length === 1)
        withdrawn = rows
    }
    verify(withdrawn !== null, "outage withdraws cached T3 agents")
    var stale = w.actions.captureAgentTarget(w.winT,
      { key: "stale", kind: "herdr-agent", agentId: "t3:env-1:1:thread-1" })
    verify(!w.actions.activateHerdrTarget(stale))
    compare(w.windowActions.raises, 0)
  }
}
