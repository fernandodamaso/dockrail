import QtQuick
import QtTest
import "../components"

TestCase {
  id: testCase
  name: "AgentSourceMux"
  when: windowShown
  width: 320
  height: 240

  Component {
    id: stubFactory
    QtObject {
      property string sourceId: "herdr"
      property string sourceEpoch: "epoch-herdr"
      property int sourceRevision: 0
      property bool running: true
      property bool available: true
      property int acquireCount: 0
      property int activationCount: 0
      property int suspensionCount: 0
      property int childActive: 0
      property var writes: []
      property var publish: null
      property var focusCalls: []
      property int focusSequence: 0
      signal focusAgentFinished(string requestId, bool ok, string errorCode)

      function acquire(owner) {
        var self = this
        self.acquireCount++
        var lease = {
          active: false,
          released: false,
          setActive: function(active, callback) {
            active = active === true
            if (active) {
              self.publish = typeof callback === "function" ? callback : null
              if (!lease.active) {
                lease.active = true
                self.activationCount++
                self.childActive++
              }
            } else {
              self.publish = null
              if (lease.active) {
                lease.active = false
                self.suspensionCount++
                self.childActive--
              }
            }
          },
          release: function() {
            if (lease.released) return
            if (lease.active) lease.active = false
            lease.released = true
            self.publish = null
          }
        }
        return lease
      }
      function setWindowProcesses(revision, pids) {
        writes = writes.concat([{ revision: revision, pids: pids.slice() }])
        return childActive > 0
      }
      function publishSnapshot(snapshot) {
        sourceEpoch = snapshot.providerEpoch
        sourceRevision = snapshot.revision
        if (publish) publish({ status: "ready", revision: snapshot.revision, data: snapshot })
      }
      function publishStatus(status) {
        if (publish) publish({ status: status, revision: 0, data: null })
      }
      function focusAgent(target) {
        focusCalls = focusCalls.concat([Object.assign({}, target)])
        focusSequence++
        return "focus-" + focusSequence
      }
    }
  }

  Component {
    id: muxFactory
    DockAgentSourceMux {}
  }

  function snap(sourceId, serverId, epoch, revision, wpRevision, agents) {
    return {
      schemaVersion: 1,
      providerEpoch: epoch,
      revision: revision,
      capabilities: { focusAgent: true },
      servers: [{ id: serverId, source: sourceId,
        capabilities: { focusAgent: true }, clients: [] }],
      agents: agents || [],
      attention: [],
      liveCounts: { blocked: 0, agents: (agents || []).length },
      completeness: { state: "complete" },
      windowProcesses: { revision: wpRevision, identities: [] }
    }
  }

  function agent(serverId, pane) {
    return { id: serverId + ":1:" + pane, serverId: serverId,
      connectionGeneration: 1, paneId: pane, status: "working", live: true }
  }

  function scene() {
    var herdr = createTemporaryObject(stubFactory, testCase, { sourceId: "herdr" })
    verify(herdr !== null)
    var t3 = createTemporaryObject(stubFactory, testCase,
      { sourceId: "t3", sourceEpoch: "epoch-t3" })
    verify(t3 !== null)
    var mux = createTemporaryObject(muxFactory, testCase)
    verify(mux !== null)
    var published = []
    var finished = []
    var lease = mux.acquire("test")
    lease.setActive(true, function(value) { published.push(value) })
    mux.focusAgentFinished.connect(function(requestId, ok, errorCode) {
      finished.push({ requestId: requestId, ok: ok, errorCode: errorCode })
    })
    return { herdr: herdr, t3: t3, mux: mux, lease: lease,
      published: published, finished: finished }
  }

  function lastReady(value) {
    return readySince(value, 0)
  }

  function readySince(value, pos) {
    for (var i = value.published.length - 1; i >= pos; i--)
      if (value.published[i].status === "ready") return value.published[i].data
    return null
  }

  function test_singleSourcePassThrough() {
    var value = scene()
    value.mux.sources = [{ id: "herdr", service: value.herdr, enabled: true }]
    compare(value.herdr.acquireCount, 1)
    compare(value.herdr.activationCount, 1)
    var child = snap("herdr", "srv", "epoch-herdr", 7, 0, [agent("srv", "pane-a")])
    value.herdr.publishSnapshot(child)
    var merged = lastReady(value)
    verify(merged !== null)
    compare(merged.providerEpoch, "herdr=epoch-herdr")
    compare(merged.revision, 0)
    compare(merged.agents.length, 1)
    compare(merged.agents[0].id, "srv:1:pane-a")
    compare(merged.servers.length, 1)
    compare(merged.servers[0].id, "srv")
    compare(merged.servers[0].source, "herdr")
    compare(merged.servers[0].providerEpoch, "epoch-herdr")
    compare(merged.servers[0].sourceLiveCountsKnown, true)
    compare(value.mux.sourceEpoch, "herdr=epoch-herdr")
    verify(value.mux.running)
    verify(value.mux.available)
  }

  function test_neverReadyWithoutData() {
    var value = scene()
    value.mux.sources = [{ id: "herdr", service: value.herdr, enabled: true }]
    for (var i = 0; i < value.published.length; i++) {
      verify(value.published[i].status !== "ready")
      verify(value.published[i].data === null)
    }
    value.herdr.publishStatus("loading")
    var ready = lastReady(value)
    verify(ready === null)
    value.herdr.publishStatus("error")
    ready = lastReady(value)
    verify(ready === null)
    compare(value.published[value.published.length - 1].status, "error")
  }

  function test_singleSourceNeverLagging() {
    var value = scene()
    value.mux.sources = [{ id: "t3", service: value.t3, enabled: true }]
    value.t3.publishSnapshot(snap("t3", "t3:env", "epoch-t3", 1, 0, []))
    verify(value.mux.setWindowProcesses(9, []))
    var merged = lastReady(value)
    verify(merged !== null)
    compare(merged.servers.length, 1)
    wait(2600)
    merged = lastReady(value)
    verify(merged !== null)
    compare(merged.servers.length, 1)
    compare(merged.servers[0].id, "t3:env")
  }

  function test_staleT3CannotBlockHerdr() {
    var value = scene()
    value.mux.sources = [
      { id: "herdr", service: value.herdr, enabled: true },
      { id: "t3", service: value.t3, enabled: true }
    ]
    value.t3.publishSnapshot(snap("t3", "t3:env", "epoch-t3", 1, 0, []))
    value.herdr.publishSnapshot(snap("herdr", "srv", "epoch-herdr", 1, 0, []))
    verify(value.mux.setWindowProcesses(5, []))
    compare(value.herdr.writes.length, 1)
    compare(value.t3.writes.length, 1)
    value.herdr.publishSnapshot(snap("herdr", "srv", "epoch-herdr", 2, 5, []))
    var isolated = null
    var deadline = Date.now() + 4000
    while (!isolated && Date.now() < deadline) {
      wait(100)
      var merged = lastReady(value)
      if (merged && merged.servers.length === 1
          && merged.servers[0].id === "srv"
          && merged.windowProcesses.revision === 5) isolated = merged
    }
    verify(isolated !== null, "stale T3 must be isolated after 2s")
    value.t3.publishSnapshot(snap("t3", "t3:env", "epoch-t3", 2, 5, []))
    var rejoined = null
    deadline = Date.now() + 2000
    while (!rejoined && Date.now() < deadline) {
      wait(100)
      var both = lastReady(value)
      if (both && both.servers.length === 2
          && both.windowProcesses.revision === 5) rejoined = both
    }
    verify(rejoined !== null, "T3 rejoins on its echo")
  }

  function test_staleHerdrCannotBlockT3() {
    var value = scene()
    value.mux.sources = [
      { id: "herdr", service: value.herdr, enabled: true },
      { id: "t3", service: value.t3, enabled: true }
    ]
    value.herdr.publishSnapshot(snap("herdr", "srv", "epoch-herdr", 1, 0, []))
    value.t3.publishSnapshot(snap("t3", "t3:env", "epoch-t3", 1, 0, []))
    verify(value.mux.setWindowProcesses(5, []))
    value.t3.publishSnapshot(snap("t3", "t3:env", "epoch-t3", 2, 5, []))
    var isolated = null
    var deadline = Date.now() + 4000
    while (!isolated && Date.now() < deadline) {
      wait(100)
      var merged = lastReady(value)
      if (merged && merged.servers.length === 1
          && merged.servers[0].id === "t3:env"
          && merged.windowProcesses.revision === 5) isolated = merged
    }
    verify(isolated !== null, "stale Herdr must be isolated after 2s")
  }

  function test_bothStaleKeepWaiting() {
    var value = scene()
    value.mux.sources = [
      { id: "herdr", service: value.herdr, enabled: true },
      { id: "t3", service: value.t3, enabled: true }
    ]
    value.herdr.publishSnapshot(snap("herdr", "srv", "epoch-herdr", 1, 0, []))
    value.t3.publishSnapshot(snap("t3", "t3:env", "epoch-t3", 1, 0, []))
    verify(value.mux.setWindowProcesses(5, []))
    wait(2600)
    var merged = lastReady(value)
    verify(merged !== null)
    compare(merged.servers.length, 2)
    // Both stale sources agree on the old revision: the bridge keeps waiting.
    compare(merged.windowProcesses.revision, 0)
    value.herdr.publishSnapshot(snap("herdr", "srv", "epoch-herdr", 2, 5, []))
    var usable = null
    var deadline = Date.now() + 2000
    while (!usable && Date.now() < deadline) {
      wait(100)
      var current = lastReady(value)
      if (current && current.servers.length === 1
          && current.servers[0].id === "srv"
          && current.windowProcesses.revision === 5) usable = current
    }
    verify(usable !== null, "first source to catch up becomes usable")
  }

  function test_sameRevisionSendDoesNotExtendDeadline() {
    var value = scene()
    value.mux.sources = [
      { id: "herdr", service: value.herdr, enabled: true },
      { id: "t3", service: value.t3, enabled: true }
    ]
    value.t3.publishSnapshot(snap("t3", "t3:env", "epoch-t3", 1, 0, []))
    value.herdr.publishSnapshot(snap("herdr", "srv", "epoch-herdr", 1, 0, []))
    verify(value.mux.setWindowProcesses(5, []))
    value.herdr.publishSnapshot(snap("herdr", "srv", "epoch-herdr", 2, 5, []))
    wait(1000)
    verify(value.mux.setWindowProcesses(5, []))
    var isolated = null
    var deadline = Date.now() + 1800
    while (!isolated && Date.now() < deadline) {
      wait(100)
      var merged = lastReady(value)
      if (merged && merged.servers.length === 1
          && merged.servers[0].id === "srv") isolated = merged
    }
    verify(isolated !== null, "deadline must not extend past ~2s from the first send")
  }

  function test_serviceReplacementReacquires() {
    var value = scene()
    value.mux.sources = [{ id: "herdr", service: value.herdr, enabled: true }]
    value.herdr.publishSnapshot(snap("herdr", "srv", "epoch-herdr", 1, 0, []))
    verify(lastReady(value) !== null)
    var pos = value.published.length
    var replacement = createTemporaryObject(stubFactory, testCase,
      { sourceId: "herdr", sourceEpoch: "epoch-herdr-2" })
    value.mux.sources = [{ id: "herdr", service: replacement, enabled: true }]
    compare(replacement.acquireCount, 1)
    compare(replacement.activationCount, 1)
    compare(value.mux.sourceEpoch, "herdr=epoch-herdr-2")
    var stale = readySince(value, pos)
    verify(stale === null || stale.providerEpoch === "herdr=epoch-herdr-2")
    replacement.publishSnapshot(snap("herdr", "srv", "epoch-herdr-2", 1, 0, []))
    var merged = lastReady(value)
    verify(merged !== null)
    compare(merged.servers[0].id, "srv")
  }

  function test_repeatedSetActiveRepublishes() {
    var value = scene()
    value.mux.sources = [{ id: "herdr", service: value.herdr, enabled: true }]
    value.herdr.publishSnapshot(snap("herdr", "srv", "epoch-herdr", 1, 0, []))
    var count = value.published.length
    verify(count > 0)
    value.lease.setActive(true, function(update) { value.published.push(update) })
    compare(value.published.length > count, true)
    compare(value.published[value.published.length - 1].status, "ready")
  }

  function test_disablingRemovesServersAndAgents() {
    var value = scene()
    value.mux.sources = [
      { id: "herdr", service: value.herdr, enabled: true },
      { id: "t3", service: value.t3, enabled: true }
    ]
    value.herdr.publishSnapshot(
      snap("herdr", "srv", "epoch-herdr", 1, 0, [agent("srv", "pane-a")]))
    value.t3.publishSnapshot(
      snap("t3", "t3:env", "epoch-t3", 1, 0, [agent("t3:env", "thread-1")]))
    var merged = lastReady(value)
    verify(merged !== null)
    compare(merged.servers.length, 2)
    compare(merged.agents.length, 2)
    value.mux.sources = [
      { id: "herdr", service: value.herdr, enabled: true },
      { id: "t3", service: value.t3, enabled: false }
    ]
    merged = lastReady(value)
    verify(merged !== null)
    compare(merged.servers.length, 1)
    compare(merged.servers[0].id, "srv")
    compare(merged.agents.length, 1)
    compare(value.mux.sourceEpoch, "herdr=epoch-herdr")
    verify(!value.mux.childLeases["t3"].active)
  }

  function test_setWindowProcessesFanOut() {
    var value = scene()
    value.mux.sources = [
      { id: "herdr", service: value.herdr, enabled: true },
      { id: "t3", service: value.t3, enabled: true }
    ]
    verify(value.mux.setWindowProcesses(3, [1, 2]))
    compare(value.herdr.writes.length, 1)
    compare(value.t3.writes.length, 1)
    compare(value.herdr.writes[0].revision, 3)
    value.mux.sources = [
      { id: "herdr", service: value.herdr, enabled: true },
      { id: "t3", service: value.t3, enabled: false }
    ]
    verify(value.mux.setWindowProcesses(4, [1]))
    compare(value.herdr.writes.length, 2)
    compare(value.t3.writes.length, 1)
    value.lease.setActive(false)
    verify(!value.mux.setWindowProcesses(5, [1]))
  }

  function test_focusAgentRoutingAndEpochRewrite() {
    var value = scene()
    value.mux.sources = [
      { id: "herdr", service: value.herdr, enabled: true },
      { id: "t3", service: value.t3, enabled: true }
    ]
    value.herdr.publishSnapshot(snap("herdr", "srv", "epoch-herdr", 1, 0, []))
    value.t3.publishSnapshot(snap("t3", "t3:env", "epoch-t3", 1, 0, []))
    var requestId = value.mux.focusAgent({
      providerEpoch: "stale-mux-epoch",
      serverId: "t3:env",
      connectionGeneration: 1,
      agentId: "t3:env:1:thread-1",
      paneId: "thread-1",
      terminalId: ""
    })
    compare(requestId, "t3:focus-1")
    compare(value.t3.focusCalls.length, 1)
    compare(value.t3.focusCalls[0].providerEpoch, "epoch-t3")
    compare(value.herdr.focusCalls.length, 0)
    value.t3.focusAgentFinished("focus-1", true, "")
    compare(value.finished.length, 1)
    compare(value.finished[0].requestId, "t3:focus-1")
    compare(value.finished[0].ok, true)
    var missing = value.mux.focusAgent({
      providerEpoch: "x", serverId: "unknown-srv", connectionGeneration: 1,
      agentId: "a", paneId: "p", terminalId: ""
    })
    compare(missing, "herdr:focus-1")
    compare(value.herdr.focusCalls.length, 1)
    compare(value.herdr.focusCalls[0].providerEpoch, "epoch-herdr")
    value.mux.sources = [
      { id: "herdr", service: value.herdr, enabled: true },
      { id: "t3", service: value.t3, enabled: false }
    ]
    var disabled = value.mux.focusAgent({
      providerEpoch: "x", serverId: "t3:env", connectionGeneration: 1,
      agentId: "a", paneId: "p", terminalId: ""
    })
    compare(disabled, "")
  }

  function test_childRestartUpdatesEpoch() {
    var value = scene()
    value.mux.sources = [
      { id: "herdr", service: value.herdr, enabled: true },
      { id: "t3", service: value.t3, enabled: true }
    ]
    compare(value.mux.sourceEpoch, "herdr=epoch-herdr|t3=epoch-t3")
    value.t3.sourceEpoch = "epoch-t3-restarted"
    compare(value.mux.sourceEpoch, "herdr=epoch-herdr|t3=epoch-t3-restarted")
  }

  function test_lateFocusAfterReplacementDiscarded() {
    var value = scene()
    value.mux.sources = [
      { id: "herdr", service: value.herdr, enabled: true },
      { id: "t3", service: value.t3, enabled: true }
    ]
    value.herdr.publishSnapshot(snap("herdr", "srv", "epoch-herdr", 1, 0, []))
    value.t3.publishSnapshot(snap("t3", "t3:env", "epoch-t3", 1, 0, []))
    var requestId = value.mux.focusAgent({
      providerEpoch: "stale", serverId: "t3:env", connectionGeneration: 1,
      agentId: "a", paneId: "p", terminalId: ""
    })
    compare(requestId, "t3:focus-1")
    var replacement = createTemporaryObject(stubFactory, testCase,
      { sourceId: "t3", sourceEpoch: "epoch-t3-2" })
    value.mux.sources = [
      { id: "herdr", service: value.herdr, enabled: true },
      { id: "t3", service: replacement, enabled: true }
    ]
    value.t3.focusAgentFinished("focus-1", true, "")
    replacement.focusAgentFinished("focus-1", true, "")
    compare(value.finished.length, 0)
  }

  function test_pendingRevisionResetsWhenAllCurrent() {
    var value = scene()
    value.mux.sources = [
      { id: "herdr", service: value.herdr, enabled: true },
      { id: "t3", service: value.t3, enabled: true }
    ]
    verify(value.mux.setWindowProcesses(5, []))
    compare(value.mux.pendingRevision, 5)
    value.herdr.publishSnapshot(snap("herdr", "srv", "epoch-herdr", 1, 5, []))
    value.t3.publishSnapshot(snap("t3", "t3:env", "epoch-t3", 1, 5, []))
    compare(value.mux.pendingRevision, -1)
    var merged = lastReady(value)
    verify(merged !== null)
    compare(merged.windowProcesses.revision, 5)
  }
}
