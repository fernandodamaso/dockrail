import QtQuick
import QtTest
import "../components"
import "../components/DockHerdrModel.js" as HerdrModel

TestCase {
  id: testCase
  name: "HerdrDockIndicators"
  when: windowShown
  visible: true
  width: 420
  height: 320
  property bool imageSaved: false

  function findByName(node, name) {
    if (!node) return null
    if (node.objectName === name) return node
    var children = node.children || []
    for (var i = 0; i < children.length; ++i) {
      var found = findByName(children[i], name)
      if (found) return found
    }
    return null
  }

  function summary(statuses) {
    var counters = ({ blocked: 0, working: 0, done: 0 })
    statuses.forEach(function(status) {
      if (counters[status] !== undefined) counters[status]++
    })
    var rows = []
    ;["blocked", "working", "done"].forEach(function(status) {
      if (counters[status]) rows.push({ status: status, count: counters[status] })
    })
    var indicator = counters.blocked ? "blocked"
      : counters.working ? "working" : counters.done ? "done" : ""
    return {
      count: statuses.length,
      indicatorStatus: indicator,
      counters: rows,
      rows: [],
      blockedTransitionRevision: 0
    }
  }

  Component {
    id: windowFactory
    QtObject { property string title: "Terminal" }
  }

  Component {
    id: dockItemFactory
    Item {
      id: indicator
      property var runningToplevels: []
      property var herdrSummary: summary([])
      property string attentionBadge: "none"
      property bool herdrReplacesAttention: false
      readonly property int runningCount: runningToplevels.length
      readonly property int herdrAgentCount: Number(herdrSummary.count || 0)
      width: 74
      height: 74
      visible: true

      function accessibleLabel() {
        var name = "org.test.Terminal"
        if (runningCount > 0)
          name += " · " + runningCount + (runningCount === 1 ? " window" : " windows")
        if (herdrAgentCount > 0)
          name += " · " + herdrAgentCount + (herdrAgentCount === 1 ? " agent" : " agents")
        var counters = herdrSummary.counters || []
        for (var i = 0; i < counters.length; ++i) {
          if (counters[i].status === "blocked")
            name += " · " + counters[i].count + " needs input"
          else if (counters[i].status === "working")
            name += " · " + counters[i].count + " working"
          else if (counters[i].status === "done")
            name += " · " + counters[i].count + " done"
        }
        return name
      }

      Accessible.role: Accessible.Button
      Accessible.name: accessibleLabel()

      Item {
        id: icon
        width: 52
        height: 52
        anchors.centerIn: parent

        Rectangle {
          id: countBadge
          objectName: "dock-corner-count-badge"
          visible: indicator.runningCount > 1 && !statusMark.visible
          width: Math.max(16, countText.implicitWidth + 8)
          height: 16
          radius: height / 2
          x: icon.width - width + 5
          y: -5
          color: "#7d8cff"

          Text {
            id: countText
            objectName: "dock-corner-count-text"
            anchors.centerIn: parent
            text: indicator.runningCount > 99 ? "99+" : String(indicator.runningCount)
          }
        }

        DockApplicationBadge {
          objectName: "dock-attention-badge"
          severity: indicator.herdrReplacesAttention ? "none" : indicator.attentionBadge
          x: icon.width - width + 3
          y: -3 + (countBadge.visible ? 16 : 0)
            + (statusMark.visible ? statusMark.height : 0)
        }

        DockHerdrStatusMark {
          id: statusMark
          objectName: "dock-herdr-status-mark"
          status: indicator.herdrSummary.indicatorStatus
          size: 26
          animationsEnabled: false
          x: icon.width - width + 8
          y: -8
        }
      }
    }
  }

  Component {
    id: bridgeSceneFactory
    Item {
      id: scene
      property alias service: service
      property alias bridge: bridge

      QtObject {
        id: service
        property string sourceEpoch: "epoch-1"
        property int sourceRevision: 0
        property bool running: true
        property int activeCount: 0
        property var publish: null
        property var writes: []

        function acquire() {
          var lease = {
            active: false,
            released: false,
            setActive: function(active, callback) {
              active = active === true
              service.publish = active ? callback : null
              if (lease.active === active) return
              lease.active = active
              service.activeCount += active ? 1 : -1
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
          service.writes = service.writes.concat([{ revision: revision, pids: pids }])
          return true
        }
        function send(view) {
          if (service.publish) service.publish(view)
        }
      }

      DockHerdrWindowAgents {
        id: bridge
        herdrService: service
      }
    }
  }

  function snapshot(bridge, status, revision, health) {
    return {
      schemaVersion: 1,
      providerEpoch: "epoch-1",
      revision: revision,
      servers: [{
        id: "srv",
        health: health || "live",
        capabilities: { focusAgent: true },
        clients: [{ pid: 41, startTime: 41,
          ancestors: [{ pid: 40, startTime: 40 }] }]
      }],
      agents: [{
        id: "agent-a", serverId: "srv", connectionGeneration: 1,
        paneId: "pane-a", status: status, title: "Agent"
      }],
      windowProcesses: {
        revision: bridge.windowProcessRevision,
        identities: [{ pid: 40, startTime: 40 }]
      }
    }
  }

  function readyBridge(status) {
    var scene = createTemporaryObject(bridgeSceneFactory, testCase)
    verify(scene !== null)
    var win = createTemporaryObject(windowFactory, scene)
    scene.bridge.toplevels = [win]
    scene.bridge.hyprToplevels = [{
      wayland: win, address: "0xabc", lastIpcObject: { pid: 40 }
    }]
    scene.bridge.dockConsumerActive = true
    scene.bridge.syncHerdrWindowProcesses()
    scene.service.send({
      status: "ready", revision: 1,
      data: snapshot(scene.bridge, status || "working", 1)
    })
    tryCompare(scene.bridge, "snapshotReady", true)
    return { scene: scene, win: win }
  }

  function sendSnapshot(value, status, revision, health) {
    value.scene.service.send({
      status: "ready", revision: revision,
      data: snapshot(value.scene.bridge, status, revision, health)
    })
  }

  function test_canvasStatesAndBadgeOwnership() {
    var item = createTemporaryObject(dockItemFactory, testCase)
    verify(item !== null)
    var mark = findByName(item, "dock-herdr-status-mark")
    var badge = findByName(item, "dock-corner-count-badge")
    var badgeText = findByName(item, "dock-corner-count-text")
    verify(mark !== null)
    verify(badge !== null)

    item.herdrSummary = summary([])
    compare(mark.visible, false, "no agents has no mark")
    compare(badge.visible, false)

    item.herdrSummary = summary(["working"])
    wait(0)
    compare(mark.visible, true)
    compare(HerdrModel.statusColorRole(mark.status), "accent")
    compare(badge.visible, false)

    item.herdrSummary = summary(["blocked"])
    wait(0)
    compare(mark.visible, true)
    compare(HerdrModel.statusColorRole(mark.status), "blocked")

    item.herdrSummary = summary(["done"])
    wait(0)
    compare(mark.visible, true)
    compare(HerdrModel.statusColorRole(mark.status), "done")

    item.herdrSummary = summary(["blocked", "working", "done"])
    wait(0)
    compare(HerdrModel.statusColorRole(mark.status), "blocked")
    compare(badge.visible, false, "agent count never owns the corner badge")
    compare(mark.y, -8, "status mark owns the top-right corner")

    // A stale/reconnecting projection is deliberately an empty summary.
    item.herdrSummary = summary([])
    wait(0)
    compare(mark.visible, false)
    compare(badge.visible, false)

    var one = createTemporaryObject(windowFactory, item)
    var two = createTemporaryObject(windowFactory, item)
    item.runningToplevels = [one, two]
    item.herdrSummary = summary(["blocked", "working", "done"])
    wait(0)
    compare(badge.visible, false, "status mark replaces the window count")
    item.herdrSummary = summary([])
    wait(0)
    compare(badge.visible, true, "window count returns without Herdr agents")
    compare(badgeText.text, "2")
    item.herdrSummary = summary(["blocked", "working", "done"])
    wait(0)
    verify(item.Accessible.name.indexOf("2 windows · 3 agents") >= 0)
    verify(item.Accessible.name.indexOf("1 needs input") >= 0)
    verify(item.Accessible.name.indexOf("1 working") >= 0)
    verify(item.Accessible.name.indexOf("1 done") >= 0)
  }

  function test_mixedUrgencyKeepsAttentionBadge() {
    var item = createTemporaryObject(dockItemFactory, testCase)
    var attention = findByName(item, "dock-attention-badge")
    verify(attention !== null)
    item.herdrSummary = summary(["blocked"])
    item.attentionBadge = "urgent"
    item.herdrReplacesAttention = false
    wait(0)
    compare(attention.visible, true, "non-Herdr urgency remains visible")
    item.herdrReplacesAttention = true
    wait(0)
    compare(attention.visible, false, "same blocked Herdr window owns the mark")
  }

  function test_representativeVisualCapture() {
    var item = createTemporaryObject(dockItemFactory, testCase, {
      x: 160,
      y: 110,
      herdrSummary: summary(["blocked", "working", "done"])
    })
    verify(item !== null)
    wait(0)
    testCase.imageSaved = false
    item.grabToImage(function(result) {
      testCase.imageSaved = result.saveToFile("/tmp/herdr-dock-indicator.png")
    }, Qt.size(item.width * 4, item.height * 4))
    tryCompare(testCase, "imageSaved", true)
  }

  function test_completionAcknowledgmentAndFreshCompletion() {
    var value = readyBridge("working")
    sendSnapshot(value, "done", 2)
    var done = value.scene.bridge.summaryForToplevels([value.win])
    compare(done.indicatorStatus, "done")
    compare(done.counters[0].status, "done", "raw state remains done")

    value.scene.bridge.focusedToplevel = value.win
    compare(value.scene.bridge.summaryForToplevels([value.win]).indicatorStatus, "")
    compare(value.scene.bridge.summaryForToplevels([value.win]).counters[0].status, "done")

    // A completion received while already focused is acknowledged atomically.
    sendSnapshot(value, "working", 3)
    sendSnapshot(value, "done", 4)
    compare(value.scene.bridge.summaryForToplevels([value.win]).indicatorStatus, "")

    value.scene.bridge.focusedToplevel = null
    sendSnapshot(value, "working", 5)
    sendSnapshot(value, "done", 6)
    compare(value.scene.bridge.summaryForToplevels([value.win]).indicatorStatus, "done")
  }

  function test_eachAgentCompletionIsIndependent() {
    var value = readyBridge("working")
    sendSnapshot(value, "done", 2)
    value.scene.bridge.focusedToplevel = value.win
    compare(value.scene.bridge.summaryForToplevels([value.win]).indicatorStatus, "")
    value.scene.bridge.focusedToplevel = null

    var withSecond = snapshot(value.scene.bridge, "done", 3)
    withSecond.agents.push({
      id: "agent-b", serverId: "srv", connectionGeneration: 1,
      paneId: "pane-b", status: "working", title: "Second agent"
    })
    value.scene.service.send({ status: "ready", revision: 3, data: withSecond })
    compare(value.scene.bridge.summaryForToplevels([value.win]).indicatorStatus, "working")

    withSecond = snapshot(value.scene.bridge, "done", 4)
    withSecond.agents.push({
      id: "agent-b", serverId: "srv", connectionGeneration: 1,
      paneId: "pane-b", status: "done", title: "Second agent"
    })
    value.scene.service.send({ status: "ready", revision: 4, data: withSecond })
    var summary = value.scene.bridge.summaryForToplevels([value.win])
    compare(summary.indicatorStatus, "done",
      "another agent completion is not covered by the first acknowledgment")
    compare(summary.count, 2)
  }

  function claudeSnapshot(bridge, claudeStatus, herdrStatus, revision, includeDesktop,
      includeBare) {
    var agents = [{
      id: "agent-a", serverId: "srv", connectionGeneration: 1,
      paneId: "pane-a", status: herdrStatus, title: "Agent"
    }]
    if (includeDesktop) agents.push({
      id: "session-1", serverId: "claude:desktop", connectionGeneration: 1,
      desktopSessionId: "local_6f1c2a4e-9b3d-4e7a-8c2f-1a2b3c4d5e6f",
      paneId: "", status: claudeStatus, title: "Session"
    })
    if (includeBare) agents.push({
      id: "session-2", serverId: "claude:desktop", connectionGeneration: 1,
      paneId: "", status: claudeStatus, title: "Unbound session"
    })
    return {
      schemaVersion: 1,
      providerEpoch: "epoch-1",
      revision: revision,
      servers: [{
        id: "srv", health: "live", capabilities: { focusAgent: true },
        clients: [{ pid: 41, startTime: 41,
          ancestors: [{ pid: 40, startTime: 40 }] }]
      }, {
        id: "claude:desktop", source: "claude", health: "live",
        capabilities: { focusAgent: true },
        clients: [{ pid: 51, startTime: 51,
          ancestors: [{ pid: 50, startTime: 50 }] }]
      }],
      agents: agents,
      windowProcesses: {
        revision: bridge.windowProcessRevision,
        identities: [{ pid: 40, startTime: 40 }, { pid: 50, startTime: 50 }]
      }
    }
  }

  function readyHerdrAndClaudeBridge() {
    var scene = createTemporaryObject(bridgeSceneFactory, testCase)
    verify(scene !== null)
    var herdr = createTemporaryObject(windowFactory, scene)
    var claude = createTemporaryObject(windowFactory, scene)
    scene.bridge.toplevels = [herdr, claude]
    scene.bridge.hyprToplevels = [
      { wayland: herdr, address: "0xabc", lastIpcObject: { pid: 40 } },
      { wayland: claude, address: "0xdef", lastIpcObject: { pid: 50 } }
    ]
    scene.bridge.dockConsumerActive = true
    scene.bridge.syncHerdrWindowProcesses()
    scene.service.send({
      status: "ready", revision: 1,
      data: claudeSnapshot(scene.bridge, "working", "working", 1, true, true)
    })
    tryCompare(scene.bridge, "snapshotReady", true)
    return { scene: scene, herdr: herdr, claude: claude }
  }

  function test_claudeCompletionSurvivesWindowFocus() {
    var value = readyHerdrAndClaudeBridge()
    var bridge = value.scene.bridge
    function sendSessions(revision, claudeStatus, herdrStatus, includeDesktop, includeBare) {
      value.scene.service.send({
        status: "ready", revision: revision,
        data: claudeSnapshot(bridge, claudeStatus, herdrStatus, revision,
          includeDesktop, includeBare)
      })
    }
    function send(revision, claudeStatus, herdrStatus, includeClaude) {
      sendSessions(revision, claudeStatus, herdrStatus, includeClaude !== false,
        includeClaude !== false)
    }
    function indicator(win) {
      return bridge.summaryForToplevels([win]).indicatorStatus
    }

    send(2, "done", "done")
    compare(indicator(value.claude), "done")
    compare(indicator(value.herdr), "done")

    // Focusing the Claude window does not open the session in Claude Desktop.
    bridge.focusedToplevel = value.claude
    compare(indicator(value.claude), "done", "Claude done survives focus")
    // Herdr keeps today's behaviour: focusing its window acknowledges it.
    bridge.focusedToplevel = value.herdr
    compare(indicator(value.herdr), "", "Herdr completion is acknowledged by focus")
    compare(indicator(value.claude), "done")
    bridge.focusedToplevel = value.claude
    compare(indicator(value.claude), "done", "Claude done survives a focus change")
    bridge.focusedToplevel = null
    compare(indicator(value.claude), "done", "Claude done survives losing focus")

    // A Claude completion arriving while its window is focused is not acknowledged.
    bridge.focusedToplevel = value.claude
    send(3, "working", "working")
    compare(indicator(value.claude), "working")
    send(4, "done", "working")
    compare(indicator(value.claude), "done", "fresh Claude completion while focused")
    bridge.focusedToplevel = value.herdr
    compare(indicator(value.claude), "done")

    // A Claude session without Desktop metadata has nothing that clears it, so
    // focusing its window acknowledges it. Only that session is listed here.
    sendSessions(5, "working", "working", false, true)
    sendSessions(6, "done", "done", false, true)
    compare(indicator(value.claude), "done", "bare Claude completion waits for focus")
    bridge.focusedToplevel = value.claude
    compare(indicator(value.claude), "", "bare Claude completion is acknowledged by focus")
    bridge.focusedToplevel = value.herdr
    compare(indicator(value.claude), "")

    // Opening the session in Claude Desktop makes the provider stop listing it.
    send(7, "done", "done", false)
    var gone = bridge.summaryForToplevels([value.claude])
    compare(gone.count, 0, "dropped Claude session has no rows")
    compare(gone.indicatorStatus, "", "dropped Claude session clears its done mark")
  }

  function test_gapReplayAndBlockedBounceRevision() {
    var value = readyBridge("working")
    sendSnapshot(value, "blocked", 2)
    var blocked = value.scene.bridge.summaryForToplevels([value.win])
    compare(blocked.indicatorStatus, "blocked")
    verify(blocked.blockedTransitionRevision > 0)
    var transition = blocked.blockedTransitionRevision

    value.scene.service.send({ status: "loading", revision: 3, data: null })
    compare(value.scene.bridge.summaryForToplevels([value.win]).count, 0)
    sendSnapshot(value, "blocked", 4, "connecting")
    compare(value.scene.bridge.summaryForToplevels([value.win]).count, 0,
      "reconnecting snapshots never render retained state")
    sendSnapshot(value, "blocked", 5)
    blocked = value.scene.bridge.summaryForToplevels([value.win])
    compare(blocked.blockedTransitionRevision, transition,
      "replayed blocked state does not bounce again")

    sendSnapshot(value, "working", 6)
    sendSnapshot(value, "done", 7)
    value.scene.bridge.focusedToplevel = value.win
    value.scene.service.send({ status: "loading", revision: 8, data: null })
    sendSnapshot(value, "done", 9)
    compare(value.scene.bridge.summaryForToplevels([value.win]).indicatorStatus, "",
      "replayed completion retains acknowledgment")
  }

  // Source-level guard: qmltestrunner cannot load DockItem (it needs the Quickshell
  // core plugin), so this checks the blocked-bounce gate text in DockItem.qml.
  function itemSource() {
    var request = new XMLHttpRequest()
    request.open("GET", Qt.resolvedUrl("../components/DockItem.qml"), false)
    request.send()
    if (!request.responseText) throw new Error("QML_XHR_ALLOW_FILE_READ=1 is required")
    return request.responseText
  }

  function test_blockedBounceHonoursSuppressionAndFocus() {
    var source = itemSource()
    var start = source.indexOf("  function requestHerdrBlockedMotion() {")
    verify(start >= 0, "DockItem requestHerdrBlockedMotion exists")
    var body = source.slice(start, source.indexOf("\n  }\n", start))
    var consume = body.indexOf("root.seenHerdrBlockedTransitionRevision = revision")
    var gate = body.indexOf("if (root.motionReady")
    verify(consume >= 0 && gate > consume, "skipped transitions are consumed before the gate")
    verify(body.indexOf("!root.urgentMotionSuppressed", gate) > gate,
      "blocked bounce honours urgent motion suppression")
    verify(body.indexOf("!root.focused", gate) > gate,
      "blocked bounce is skipped for the focused item")
    verify(body.indexOf("attentionMotion.play()") > gate, "blocked bounce plays after the gate")
  }

  function test_replacementAndSettingOff() {
    var scene = createTemporaryObject(bridgeSceneFactory, testCase)
    compare(scene.service.activeCount, 0, "setting off takes no active lease")
    compare(scene.bridge.summaryForToplevels([]).count, 0)

    var value = readyBridge("working")
    sendSnapshot(value, "done", 2)
    compare(value.scene.bridge.summaryForToplevels([value.win]).indicatorStatus, "done")
    var replacement = createTemporaryObject(windowFactory, value.scene)
    value.scene.bridge.toplevels = [replacement]
    value.scene.bridge.hyprToplevels = [{
      wayland: replacement, address: "0xabc", lastIpcObject: { pid: 40 }
    }]
    value.scene.bridge.syncHerdrWindowProcesses()
    sendSnapshot({ scene: value.scene, win: replacement }, "done", 3)
    compare(value.scene.bridge.summaryForToplevels([replacement]).indicatorStatus, "",
      "replacement bootstrap is not a synthetic completion")
    sendSnapshot({ scene: value.scene, win: replacement }, "working", 4)
    sendSnapshot({ scene: value.scene, win: replacement }, "done", 5)
    compare(value.scene.bridge.summaryForToplevels([replacement]).indicatorStatus, "done",
      "replacement does not inherit the old window acknowledgment")
  }
}
