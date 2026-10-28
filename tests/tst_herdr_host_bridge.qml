import QtQuick
import QtTest
import "../components"

TestCase {
  id: testCase
  name: "HerdrHostBridge"
  when: windowShown
  width: 320
  height: 240

  Component {
    id: windowFactory
    QtObject { property string title: "Terminal" }
  }

  Component {
    id: sceneFactory
    Item {
      id: scene
      property alias service: service
      property alias bridge: bridge
      property alias actions: actions
      property alias windowActions: windowActions

      QtObject {
        id: service
        property string sourceEpoch: "epoch-1"
        property int sourceRevision: 0
        property bool running: true
        property int activeCount: 0
        property int acquireCount: 0
        property int activationCount: 0
        property int suspensionCount: 0
        property string acquiredOwner: ""
        property var writes: []
        property var publish: null
        property var focusCalls: []
        property int focusSequence: 0
        signal focusAgentFinished(string requestId, bool ok, string errorCode)

        function acquire(owner) {
          service.acquireCount++
          service.acquiredOwner = String(owner || "")
          var lease = {
            active: false,
            released: false,
            setActive: function(active, callback) {
              active = active === true
              service.publish = active ? callback : null
              if (active === lease.active) return
              lease.active = active
              if (active) {
                service.activeCount++
                service.activationCount++
              } else {
                service.activeCount--
                service.suspensionCount++
              }
            },
            release: function() {
              if (lease.released) return
              if (lease.active) service.activeCount--
              lease.active = false
              lease.released = true
              service.publish = null
            }
          }
          return lease
        }
        function setWindowProcesses(revision, pids) {
          service.writes = service.writes.concat([{
            revision: revision, pids: pids.slice()
          }])
          return true
        }
        function publishSnapshot(snapshot) {
          service.sourceEpoch = snapshot.providerEpoch
          service.sourceRevision = snapshot.revision
          if (service.publish) service.publish({
            status: "ready", revision: snapshot.revision, data: snapshot
          })
        }
        function focusAgent(target) {
          service.focusCalls = service.focusCalls.concat([Object.assign({}, target)])
          service.focusSequence++
          return "focus-" + service.focusSequence
        }
      }

      QtObject {
        id: windowActions
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

      DockHerdrWindowAgents {
        id: bridge
        herdrService: service
        toplevels: windowActions.live
        hyprToplevels: windowActions.handles
      }

      DockHerdrAgentActions {
        id: actions
        bridge: bridge
        windowActions: windowActions
        herdrService: service
      }
    }
  }

  function snapshot(bridge, generation, epoch) {
    return {
      schemaVersion: 1,
      providerEpoch: epoch || "epoch-1",
      revision: generation,
      servers: [{
        id: "srv",
        capabilities: { focusAgent: true },
        clients: [{ pid: 41, startTime: 41,
          ancestors: [{ pid: 40, startTime: 40 }] }]
      }],
      agents: [{
        id: "srv:" + generation + ":pane-a",
        serverId: "srv",
        connectionGeneration: generation,
        paneId: "pane-a",
        terminalId: "term-a",
        title: "Agent",
        status: "working"
      }],
      windowProcesses: {
        revision: bridge.windowProcessRevision,
        identities: [{ pid: 40, startTime: 40 }]
      }
    }
  }

  function readyScene() {
    var scene = createTemporaryObject(sceneFactory, testCase)
    verify(scene !== null)
    var win = createTemporaryObject(windowFactory, scene)
    scene.windowActions.live = [win]
    scene.windowActions.handles = [{
      wayland: win, address: "0xABC",
      lastIpcObject: { pid: 40 }
    }]
    scene.bridge.dockConsumerActive = true
    scene.bridge.syncHerdrWindowProcesses()
    scene.service.publishSnapshot(snapshot(scene.bridge, 1, "epoch-1"))
    tryCompare(scene.bridge, "snapshotReady", true)
    return { scene: scene, win: win }
  }

  function test_dockLeaseAndEmptyBootstrap() {
    var scene = createTemporaryObject(sceneFactory, testCase)
    verify(scene !== null)
    compare(scene.service.acquireCount, 1)
    compare(scene.service.acquiredOwner, "host.herdr-window-agents")
    compare(scene.service.activeCount, 0)
    scene.bridge.dockConsumerActive = true
    compare(scene.service.activeCount, 1)
    compare(scene.service.writes.length, 1)
    compare(scene.service.writes[0].pids, [])
    // Auto-hide reveal does not alter classic-presentation demand.
    scene.bridge.dockConsumerActive = true
    compare(scene.service.activationCount, 1)
    scene.bridge.dockConsumerActive = false
    compare(scene.service.activeCount, 0)
    compare(scene.service.suspensionCount, 1)
  }

  function test_focusWithoutSidebarRaisesAndRefocuses() {
    var value = readyScene()
    var scene = value.scene
    var agent = scene.bridge.summaryForToplevels([value.win]).rows[0]
    compare(agent.focusAgentSupported, true,
      "dock rows inherit the associated server focus capability")
    var target = scene.actions.captureAgentTarget(value.win,
      Object.assign({ key: "dock-row", kind: "herdr-agent" }, agent))
    verify(target !== null)
    verify(scene.actions.activateHerdrTarget(target))
    compare(scene.service.focusCalls.length, 1)
    scene.actions.onHerdrFocusFinished("focus-1", true, "")
    compare(scene.windowActions.raises, 1)
    compare(scene.service.focusCalls.length, 2)
    scene.actions.onHerdrFocusFinished("focus-2", true, "")
    compare(scene.windowActions.raises, 1)
  }

  function test_pendingEpochGenerationAndCloseRejectRaise() {
    var value = readyScene()
    var scene = value.scene
    var target = scene.actions.captureAgentTarget(value.win, {
      key: "row", kind: "herdr-agent", agentId: scene.bridge.snapshot.agents[0].id
    })
    verify(scene.actions.activateHerdrTarget(target))
    scene.service.sourceEpoch = "epoch-2"
    scene.bridge.syncHerdrWindowProcesses()
    scene.actions.onHerdrFocusFinished("focus-1", true, "")
    compare(scene.windowActions.raises, 0)

    value = readyScene()
    scene = value.scene
    target = scene.actions.captureAgentTarget(value.win, {
      key: "row", kind: "herdr-agent", agentId: scene.bridge.snapshot.agents[0].id
    })
    verify(scene.actions.activateHerdrTarget(target))
    scene.service.publishSnapshot(snapshot(scene.bridge, 2, "epoch-1"))
    scene.actions.onHerdrFocusFinished("focus-1", true, "")
    compare(scene.windowActions.raises, 0)

    value = readyScene()
    scene = value.scene
    target = scene.actions.captureAgentTarget(value.win, {
      key: "row", kind: "herdr-agent", agentId: scene.bridge.snapshot.agents[0].id
    })
    verify(scene.actions.activateHerdrTarget(target))
    scene.windowActions.live = []
    scene.windowActions.handles = []
    scene.bridge.syncHerdrWindowProcesses()
    scene.actions.onHerdrFocusFinished("focus-1", true, "")
    compare(scene.windowActions.raises, 0)
  }

  function test_sameAddressPidReplacementGetsFreshToken() {
    var value = readyScene()
    var scene = value.scene
    var oldKey = scene.bridge.windowKeyFor(value.win)
    var oldTarget = scene.actions.captureAgentTarget(value.win, {
      key: "row", kind: "herdr-agent", agentId: scene.bridge.snapshot.agents[0].id
    })
    var replacement = createTemporaryObject(windowFactory, scene)
    scene.windowActions.live = [replacement]
    scene.windowActions.handles = [{
      wayland: replacement, address: "0xABC",
      lastIpcObject: { pid: 40 }
    }]
    scene.bridge.syncHerdrWindowProcesses()
    var replacementKey = scene.bridge.windowKeyFor(replacement)
    verify(replacementKey !== oldKey)
    compare(scene.bridge.windowKeyFor(value.win), "")
    compare(JSON.stringify(scene.bridge.agentsByAddress), "{}")
    verify(!scene.actions.targetIsCurrent(oldTarget))
    verify(!scene.actions.activateHerdrTarget(oldTarget))
    compare(scene.windowActions.raises, 0)
  }

  function t3Snapshot(bridge, generation, epoch) {
    return {
      schemaVersion: 1,
      providerEpoch: epoch || "epoch-1",
      revision: generation,
      servers: [{
        id: "t3:env-1",
        source: "t3",
        product: "T3 Code",
        capabilities: { focusAgent: true },
        clients: [{ pid: 41, startTime: 41,
          ancestors: [{ pid: 40, startTime: 40 }] }]
      }],
      agents: [{
        id: "t3:env-1:" + generation + ":thread-1",
        serverId: "t3:env-1",
        connectionGeneration: generation,
        paneId: "thread-1",
        terminalId: "term-1",
        title: "Same Title",
        status: "working"
      }],
      windowProcesses: {
        revision: bridge.windowProcessRevision,
        identities: [{ pid: 40, startTime: 40 }]
      }
    }
  }

  function readyT3Scene() {
    var scene = createTemporaryObject(sceneFactory, testCase)
    verify(scene !== null)
    var win = createTemporaryObject(windowFactory, scene)
    scene.windowActions.live = [win]
    scene.windowActions.handles = [{
      wayland: win, address: "0xABC",
      lastIpcObject: { pid: 40 }
    }]
    scene.bridge.dockConsumerActive = true
    scene.bridge.syncHerdrWindowProcesses()
    scene.service.publishSnapshot(t3Snapshot(scene.bridge, 1, "epoch-1"))
    tryCompare(scene.bridge, "snapshotReady", true)
    return { scene: scene, win: win }
  }

  function test_t3ThreadDispatchesOneUrl() {
    var value = readyT3Scene()
    var scene = value.scene
    compare(scene.service.acquireCount, 1,
      "one shared action owner acquires the provider")
    var agent = scene.bridge.summaryForToplevels([value.win]).rows[0]
    compare(agent.focusAgentSupported, true,
      "dock rows inherit the associated T3 server focus capability")
    var target = scene.actions.captureAgentTarget(value.win,
      Object.assign({ key: "dock-row", kind: "herdr-agent" }, agent))
    verify(target !== null)
    compare(target.serverId, "t3:env-1")
    compare(target.paneId, "thread-1")
    var dispatched = []
    scene.actions.openT3ThreadUrl = function(url) {
      dispatched.push(String(url))
      return true
    }
    verify(scene.actions.activateHerdrTarget(target))
    compare(scene.service.focusCalls.length, 1)
    compare(dispatched.length, 0, "first validation dispatches nothing yet")
    scene.actions.onHerdrFocusFinished("focus-1", true, "")
    compare(scene.windowActions.raises, 1)
    compare(scene.service.focusCalls.length, 2, "two validation calls")
    compare(dispatched.length, 0, "raise plus revalidation dispatch nothing yet")
    scene.actions.onHerdrFocusFinished("focus-2", true, "")
    compare(scene.service.focusCalls.length, 2, "no third provider call")
    compare(scene.windowActions.raises, 1, "no second raise")
    compare(dispatched, ["t3code://threads/env-1/thread-1"])
  }

  function test_t3StaleTargetDispatchesNothing() {
    var value = readyT3Scene()
    var scene = value.scene
    var target = scene.actions.captureAgentTarget(value.win, {
      key: "row", kind: "herdr-agent", agentId: scene.bridge.snapshot.agents[0].id
    })
    var dispatched = []
    scene.actions.openT3ThreadUrl = function(url) {
      dispatched.push(String(url))
      return true
    }
    verify(scene.actions.activateHerdrTarget(target))
    scene.service.sourceEpoch = "epoch-2"
    scene.bridge.syncHerdrWindowProcesses()
    scene.actions.onHerdrFocusFinished("focus-1", true, "")
    compare(scene.windowActions.raises, 0)
    compare(dispatched.length, 0, "invalidated T3 target dispatches nothing")
  }
}
