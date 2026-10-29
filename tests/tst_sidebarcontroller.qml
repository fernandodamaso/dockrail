import QtQuick
import QtTest
import "../components"

TestCase {
  name: "SidebarController"
  when: windowShown
  width: 600; height: 400
  QtObject {
    id: writer
    property var writes: []
    property bool busy: false
    function saveSetting(key, value) {
      if (busy) return {ok:false,error:{code:"E_BUSY"},data:{applied:false}}
      writes = writes.concat([{key:key,value:value}])
      return {ok:false,error:{code:"E_BUSY"},data:{applied:true,persisted:false}}
    }
  }
  Component { id: factory; DockSidebarController { host: writer } }
  Component { id: bridgeFactory; DockHerdrWindowAgents {} }

  function createHerdrController(service, properties) {
    var values = Object.assign({}, properties)
    var bridge = createTemporaryObject(bridgeFactory, this, {
      herdrService: service,
      toplevels: values.toplevels || [],
      hyprToplevels: values.hyprToplevels || []
    })
    verify(bridge !== null)
    var descriptor = values.widgetRegistry["herdr.agents"]
    values.widgetRegistry = {
      "herdr.agents": Object.assign({}, descriptor, {
        acquire: function(owner) { return bridge.createConsumerLease(owner) }
      })
    }
    values.host = {
      windowActions: null,
      herdrWindowAgents: bridge,
      herdrAgentActions: null,
      saveSetting: function(key, value) { return writer.saveSetting(key, value) }
    }
    var controller = createTemporaryObject(factory, this, values)
    verify(controller !== null)
    bridge.toplevels = Qt.binding(function() { return controller.toplevels })
    bridge.hyprToplevels = Qt.binding(function() { return controller.hyprToplevels })
    return controller
  }
  Component {
    id: toplevelFactory
    QtObject {
      property string appId: "browser"
      property string title: ""
    }
  }
  function test_actual_controller_identity_folds_and_collapse_intent() {
    // Native toplevel handles must keep QObject identity across property injection.
    var a = createTemporaryObject(toplevelFactory, this, {title:"A"})
    var b = createTemporaryObject(toplevelFactory, this, {title:"B"})
    var screen = {name:"DP-1",width:1920,height:1080}
    var c = createTemporaryObject(factory, this, {
      settings: {presentationMode:"sidebar",pinned:[],workspaceGroups:[],sidebarCollapsed:false},
      screens:[screen], monitors:[{id:0,name:"DP-1",activeWorkspace:{id:1}}],
      workspaces:[{id:1,monitorID:0}], toplevels:[a,b],
      hyprToplevels:[{wayland:a,address:"0xa",lastIpcObject:{workspace:{id:1},monitor:0}},
        {wayland:b,address:"0xb",lastIpcObject:{workspace:{id:1},monitor:0}}]
    })
    verify(c !== null)
    verify(c.toplevels[0] === a)
    verify(c.hyprToplevels[0].wayland === a)
    c.refresh()
    compare(c.selectedConnector,"DP-1")
    compare(c.registry.entries.length,2)
    var windows = c.projection.rows.filter(function(r) {return r.kind === "window"})
    compare(windows.length,2)
    var first = windows[0].key
    compare(windows[0].workspaceIdentity,"id:1")
    var apps = c.projection.rows.filter(function(r) {return r.kind === "application"})
    compare(apps.length,1)
    var app = apps[0]
    c.toggleApplication(app.key); c.refresh()
    compare(c.projection.rows.filter(function(r) {return r.kind === "window"}).length,0)
    // Shared projection stays expanded; fold still hides members. Rail chrome is
    // per-panel via collapsedFor, not a second projection mode.
    verify(c.folds[app.key])
    compare(c.collapsedFor(screen), false)
    c.settings = Object.assign({}, c.settings, {
      sidebarCollapsedByMonitor: { "DP-1": true }
    })
    compare(c.collapsedFor(screen), true)
    compare(c.collapsedFor({name:"HDMI-A-1"}), false)
    writer.writes=[]; writer.busy=false
    var reply=c.requestCollapse(screen)
    verify(reply.data.applied)
    compare(writer.writes.length,1)
    compare(writer.writes[0].key,"sidebarCollapsedByMonitor")
    compare(writer.writes[0].value["DP-1"], false)
    writer.busy=true; c.requestCollapse(screen)
    compare(writer.writes.length,1)
    c.toplevels=[b]; c.refresh()
    compare(c.registry.entries.length,1)
    c.screens=[]; c.refresh()
    compare(c.selectedScreen,null)
    compare(c.projection.rows.length,0)
  }

  Component {
    id: herdrServiceFactory
    QtObject {
      id: svc
      property var writes: []
      property string sourceEpoch: "epoch-1"
      property int sourceRevision: 1
      property bool running: true
      property var latestSnapshot: null
      property int activeCount: 0
      property var leases: []
      function setWindowProcesses(revision, pids) {
        svc.writes = svc.writes.concat([{ revision: revision, pids: pids.slice() }])
        return true
      }
      function acquire(owner) {
        var lease = {
          provider: svc, active: false, released: false, publish: null, revision: 0,
          setActive: function(active, publish) {
            if (lease.released) return
            active = active === true
            if (active) {
              lease.publish = publish
              if (!lease.active) {
                lease.active = true
                svc.activeCount++
              }
              if (svc.latestSnapshot && publish)
                publish({ status: "ready", revision: ++lease.revision, data: svc.latestSnapshot })
            } else {
              lease.publish = null
              if (lease.active) {
                lease.active = false
                svc.activeCount = Math.max(0, svc.activeCount - 1)
              }
            }
          },
          release: function() {
            if (lease.released) return
            if (lease.active) {
              lease.active = false
              if (svc) svc.activeCount = Math.max(0, svc.activeCount - 1)
            }
            lease.publish = null
            lease.released = true
          }
        }
        svc.leases = svc.leases.concat([lease])
        return lease
      }
      function publishSnapshot(snap) {
        svc.latestSnapshot = snap
        svc.sourceEpoch = snap.providerEpoch
        svc.sourceRevision = snap.revision
        svc.running = true
        svc.leases.forEach(function(lease) {
          if (lease.publish)
            lease.publish({ status: "ready", revision: ++lease.revision, data: snap })
        })
      }
      function simulateRestart() {
        svc.running = false
        svc.sourceEpoch = ""
        svc.sourceRevision = -1
        svc.latestSnapshot = null
        svc.leases.forEach(function(lease) {
          if (lease.publish)
            lease.publish({ status: "error", revision: ++lease.revision, data: null })
        })
        svc.running = true
        svc.leases.forEach(function(lease) {
          if (lease.publish)
            lease.publish({ status: "loading", revision: ++lease.revision, data: null })
        })
      }
    }
  }

  function test_herdr_window_process_identity_revision_and_gating() {
    var service = createTemporaryObject(herdrServiceFactory, this)
    verify(service !== null)
    var a = createTemporaryObject(toplevelFactory, this, { title: "A" })
    var b = createTemporaryObject(toplevelFactory, this, { title: "B" })
    var screen = { name: "DP-1", width: 1920, height: 1080 }
    var c = createHerdrController(service, {
      widgetRegistry: {
        "herdr.agents": {
          id: "herdr.agents",
          available: true,
          acquire: function(owner) { return service.acquire(owner) }
        }
      },
      settings: {
        presentationMode: "sidebar",
        pinned: [],
        workspaceGroups: [],
        sidebarCollapsed: false,
        sidebarWidgets: ["herdr.agents"]
      },
      screens: [screen],
      monitors: [{ id: 0, name: "DP-1", activeWorkspace: { id: 1 } }],
      workspaces: [{ id: 1, monitorID: 0 }],
      toplevels: [a],
      hyprToplevels: [{
        wayland: a, address: "0xa",
        lastIpcObject: { workspace: { id: 1 }, monitor: 0, pid: 40 }
      }]
    })
    verify(c !== null)
    c.refresh()
    compare(service.writes.length, 1)
    compare(service.writes[0].revision, 1)
    compare(service.writes[0].pids, [40])
    var firstKey = c.registry.entries[0].key
    compare(c.windowProcessRevision, 1)

    // Workspace move alone does not bump identity revision.
    c.hyprToplevels = [{
      wayland: a, address: "0xa",
      lastIpcObject: { workspace: { id: 2 }, monitor: 0, pid: 40 }
    }]
    c.refresh()
    compare(c.windowProcessRevision, 1)
    compare(service.writes.length, 1)

    // Replacement handle with same PID bumps revision and reissues.
    c.toplevels = [b]
    c.hyprToplevels = [{
      wayland: b, address: "0xb",
      lastIpcObject: { workspace: { id: 1 }, monitor: 0, pid: 40 }
    }]
    c.refresh()
    verify(c.windowProcessRevision > 1)
    verify(service.writes.length >= 2)
    var replacementRevision = c.windowProcessRevision
    compare(service.writes[service.writes.length - 1].revision, replacementRevision)
    compare(service.writes[service.writes.length - 1].pids, [40])
    var secondKey = c.registry.entries[0].key
    verify(secondKey !== firstKey)

    // Obsolete reply for revision 1 is withheld after replacement.
    service.publishSnapshot({
      schemaVersion: 1,
      providerEpoch: "epoch-1",
      revision: 10,
      servers: [{
        id: "local-a",
        capabilities: { focusAgent: true },
        clients: [{ pid: 41, startTime: 41, ancestors: [{ pid: 40, startTime: 40 }] }]
      }],
      windowProcesses: { revision: 1, identities: [{ pid: 40, startTime: 40 }] }
    })
    wait(0)
    compare(JSON.stringify(c.herdrAssociations.byWindowKey), "{}")

    // Matching revision+epoch applies the association.
    service.publishSnapshot({
      schemaVersion: 1,
      providerEpoch: "epoch-1",
      revision: 11,
      servers: [{
        id: "local-a",
        capabilities: { focusAgent: true },
        clients: [{ pid: 41, startTime: 41, ancestors: [{ pid: 40, startTime: 40 }] }]
      }],
      windowProcesses: {
        revision: replacementRevision,
        identities: [{ pid: 40, startTime: 40 }]
      }
    })
    wait(0)
    var assoc = c.herdrAssociations.byWindowKey
    compare(assoc[secondKey], "local-a")
  }

  function test_herdr_associations_cleared_on_provider_restart() {
    var service = createTemporaryObject(herdrServiceFactory, this)
    verify(service !== null)
    var a = createTemporaryObject(toplevelFactory, this, { title: "A" })
    var screen = { name: "DP-1", width: 1920, height: 1080 }
    var c = createHerdrController(service, {
      widgetRegistry: {
        "herdr.agents": {
          id: "herdr.agents",
          available: true,
          acquire: function(owner) { return service.acquire(owner) }
        }
      },
      settings: {
        presentationMode: "sidebar",
        pinned: [],
        workspaceGroups: [],
        sidebarCollapsed: false,
        sidebarWidgets: ["herdr.agents"]
      },
      screens: [screen],
      monitors: [{ id: 0, name: "DP-1", activeWorkspace: { id: 1 } }],
      workspaces: [{ id: 1, monitorID: 0 }],
      toplevels: [a],
      hyprToplevels: [{
        wayland: a, address: "0xa",
        lastIpcObject: { workspace: { id: 1 }, monitor: 0, pid: 40 }
      }]
    })
    verify(c !== null)
    c.refresh()
    var windowKey = c.registry.entries[0].key
    service.publishSnapshot({
      schemaVersion: 1,
      providerEpoch: "epoch-1",
      revision: 5,
      servers: [{
        id: "local-a",
        capabilities: { focusAgent: true },
        clients: [{ pid: 41, startTime: 41, ancestors: [{ pid: 40, startTime: 40 }] }]
      }],
      windowProcesses: { revision: 1, identities: [{ pid: 40, startTime: 40 }] }
    })
    wait(0)
    compare(c.herdrAssociations.byWindowKey[windowKey], "local-a")

    // Provider exit without handle change preserves the verified parent label
    // only; unmatched inventory and the association epoch are cleared.
    service.simulateRestart()
    wait(0)
    compare(c.herdrAssociations.byWindowKey[windowKey], "local-a")
    compare(JSON.stringify(c.herdrAssociations.unmatchedServerIds), "[]")
    compare(c.herdrAssociationEpoch, "")
    // No actionable agent rows while the provider is down.
    verify(!c.projection.rows.some(function(row) { return row.kind === "herdr-agent" }))

    // New epoch with agents before a matching process reply must not emit
    // actionable agent rows under the preserved parent label.
    service.publishSnapshot({
      schemaVersion: 1,
      providerEpoch: "epoch-2",
      revision: 1,
      servers: [{
        id: "local-a",
        capabilities: { focusAgent: true },
        health: "live",
        clients: [{ pid: 41, startTime: 41, ancestors: [{ pid: 40, startTime: 40 }] }]
      }],
      agents: [{
        id: "local-a:2:pane-1",
        serverId: "local-a",
        connectionGeneration: 2,
        paneId: "pane-1",
        name: "Premature Agent",
        agent: "codex",
        status: "working"
      }],
      liveCounts: { agents: 1, working: 1, complete: true },
      completeness: { state: "complete" },
      windowProcesses: { revision: 0, identities: [] }
    })
    wait(0)
    compare(c.herdrAssociations.byWindowKey[windowKey], "local-a")
    compare(c.herdrAssociationEpoch, "")
    verify(!c.projection.rows.some(function(row) { return row.kind === "herdr-agent" }))
    verify(c.projection.rows.some(function(row) {
      return row.kind === "herdr-state" && row.windowKey === windowKey
        && row.title === "Herdr unavailable"
    }))

    // Restored only after a matching current-epoch reply.
    var requestRevision = c.windowProcessRevision
    service.publishSnapshot({
      schemaVersion: 1,
      providerEpoch: "epoch-2",
      revision: 2,
      servers: [{
        id: "local-a",
        capabilities: { focusAgent: true },
        health: "live",
        clients: [{ pid: 41, startTime: 41, ancestors: [{ pid: 40, startTime: 40 }] }]
      }],
      agents: [{
        id: "local-a:2:pane-1",
        serverId: "local-a",
        connectionGeneration: 2,
        paneId: "pane-1",
        name: "Verified Agent",
        agent: "codex",
        status: "working"
      }],
      liveCounts: { agents: 1, working: 1, complete: true },
      completeness: { state: "complete" },
      windowProcesses: {
        revision: requestRevision,
        identities: [{ pid: 40, startTime: 40 }]
      }
    })
    wait(0)
    compare(c.herdrAssociations.byWindowKey[windowKey], "local-a")
    compare(c.herdrAssociationEpoch, "epoch-2")
    verify(c.projection.rows.some(function(row) {
      return row.kind === "herdr-agent" && row.windowKey === windowKey
        && row.actionable === true
        && row.title === "Verified Agent"
    }))
  }

  function test_herdr_preserved_parents_prune_on_unrelated_vs_replaced() {
    var service = createTemporaryObject(herdrServiceFactory, this)
    verify(service !== null)
    var a = createTemporaryObject(toplevelFactory, this, { title: "A" })
    var b = createTemporaryObject(toplevelFactory, this, { title: "B" })
    var screen = { name: "DP-1", width: 1920, height: 1080 }
    var c = createHerdrController(service, {
      widgetRegistry: {
        "herdr.agents": {
          id: "herdr.agents",
          available: true,
          acquire: function(owner) { return service.acquire(owner) }
        }
      },
      settings: {
        presentationMode: "sidebar",
        pinned: [],
        workspaceGroups: [],
        sidebarCollapsed: false,
        sidebarWidgets: ["herdr.agents"]
      },
      screens: [screen],
      monitors: [{ id: 0, name: "DP-1", activeWorkspace: { id: 1 } }],
      workspaces: [{ id: 1, monitorID: 0 }],
      toplevels: [a],
      hyprToplevels: [{
        wayland: a, address: "0xa",
        lastIpcObject: { workspace: { id: 1 }, monitor: 0, pid: 40 }
      }]
    })
    verify(c !== null)
    c.refresh()
    var windowKey = c.registry.entries[0].key
    service.publishSnapshot({
      schemaVersion: 1,
      providerEpoch: "epoch-1",
      revision: 5,
      servers: [{
        id: "local-a",
        capabilities: { focusAgent: true },
        clients: [{ pid: 41, startTime: 41, ancestors: [{ pid: 40, startTime: 40 }] }]
      }],
      windowProcesses: { revision: 1, identities: [{ pid: 40, startTime: 40 }] }
    })
    wait(0)
    compare(c.herdrAssociations.byWindowKey[windowKey], "local-a")

    // Provider loss retains the verified parent.
    service.simulateRestart()
    wait(0)
    compare(c.herdrAssociations.byWindowKey[windowKey], "local-a")

    // Unrelated window create/remove must not wipe the unchanged parent.
    c.toplevels = [a, b]
    c.hyprToplevels = [{
      wayland: a, address: "0xa",
      lastIpcObject: { workspace: { id: 1 }, monitor: 0, pid: 40 }
    }, {
      wayland: b, address: "0xb",
      lastIpcObject: { workspace: { id: 1 }, monitor: 0, pid: 50 }
    }]
    c.refresh()
    compare(c.herdrAssociations.byWindowKey[windowKey], "local-a")
    compare(c.herdrAssociationEpoch, "")

    c.toplevels = [a]
    c.hyprToplevels = [{
      wayland: a, address: "0xa",
      lastIpcObject: { workspace: { id: 1 }, monitor: 0, pid: 40 }
    }]
    c.refresh()
    compare(c.herdrAssociations.byWindowKey[windowKey], "local-a")

    // Replaced handle (new key, same PID) drops the preserved parent.
    c.toplevels = [b]
    c.hyprToplevels = [{
      wayland: b, address: "0xb",
      lastIpcObject: { workspace: { id: 1 }, monitor: 0, pid: 40 }
    }]
    c.refresh()
    var replacedKey = c.registry.entries[0].key
    verify(replacedKey !== windowKey)
    compare(JSON.stringify(c.herdrAssociations.byWindowKey), "{}")
  }

  function test_herdr_empty_targets_unresolved_fallback_then_resolve() {
    var service = createTemporaryObject(herdrServiceFactory, this)
    verify(service !== null)
    var screen = { name: "DP-1", width: 1920, height: 1080 }
    var c = createHerdrController(service, {
      widgetRegistry: {
        "herdr.agents": {
          id: "herdr.agents",
          available: true,
          acquire: function(owner) { return service.acquire(owner) }
        }
      },
      settings: {
        presentationMode: "sidebar",
        pinned: [],
        workspaceGroups: [],
        sidebarCollapsed: false,
        sidebarWidgets: ["herdr.agents"]
      },
      screens: [screen],
      monitors: [{ id: 0, name: "DP-1", activeWorkspace: { id: 1 } }],
      workspaces: [{ id: 1, monitorID: 0 }],
      toplevels: [],
      hyprToplevels: []
    })
    verify(c !== null)
    c.refresh()
    compare(c.windowProcessRevision, 1)
    compare(service.writes.length, 1)
    compare(service.writes[0].revision, 1)
    compare(service.writes[0].pids.length, 0)

    service.publishSnapshot({
      schemaVersion: 1,
      providerEpoch: "epoch-1",
      revision: 3,
      servers: [{
        id: "local-a",
        capabilities: { focusAgent: true },
        clients: [{ pid: 41, startTime: 41, ancestors: [{ pid: 40, startTime: 40 }] }]
      }],
      windowProcesses: { revision: 1, identities: [] }
    })
    wait(0)
    compare(JSON.stringify(c.herdrAssociations.byWindowKey), "{}")
    compare(JSON.stringify(c.herdrAssociations.unmatchedServerIds), '["local-a"]')

    var win = createTemporaryObject(toplevelFactory, this, { title: "Term" })
    c.toplevels = [win]
    c.hyprToplevels = [{
      wayland: win, address: "0xc",
      lastIpcObject: { workspace: { id: 1 }, monitor: 0, pid: 40 }
    }]
    c.refresh()
    compare(c.windowProcessRevision, 2)
    compare(service.writes.length, 2)
    compare(service.writes[1].pids, [40])
    var key = c.registry.entries[0].key

    service.publishSnapshot({
      schemaVersion: 1,
      providerEpoch: "epoch-1",
      revision: 4,
      servers: [{
        id: "local-a",
        capabilities: { focusAgent: true },
        clients: [{ pid: 41, startTime: 41, ancestors: [{ pid: 40, startTime: 40 }] }]
      }],
      windowProcesses: { revision: 2, identities: [{ pid: 40, startTime: 40 }] }
    })
    wait(0)
    compare(c.herdrAssociations.byWindowKey[key], "local-a")
    compare(JSON.stringify(c.herdrAssociations.unmatchedServerIds), "[]")
  }

  function test_herdr_fold_toggle_persists_and_prunes_with_window() {
    var service = createTemporaryObject(herdrServiceFactory, this)
    verify(service !== null)
    var term = createTemporaryObject(toplevelFactory, this, { title: "Herdr" })
    var other = createTemporaryObject(toplevelFactory, this, { title: "Other" })
    var screen = { name: "DP-1", width: 1920, height: 1080 }
    var c = createHerdrController(service, {
      widgetRegistry: {
        "herdr.agents": {
          id: "herdr.agents",
          available: true,
          acquire: function(owner) { return service.acquire(owner) }
        }
      },
      settings: {
        presentationMode: "sidebar",
        pinned: [],
        workspaceGroups: [],
        sidebarCollapsed: false,
        sidebarWidgets: ["herdr.agents"]
      },
      screens: [screen],
      monitors: [{ id: 0, name: "DP-1", activeWorkspace: { id: 1 } }],
      workspaces: [{ id: 1, monitorID: 0 }],
      toplevels: [term, other],
      hyprToplevels: [{
        wayland: term, address: "0xh",
        lastIpcObject: { workspace: { id: 1 }, monitor: 0, pid: 40 }
      }, {
        wayland: other, address: "0xo",
        lastIpcObject: { workspace: { id: 1 }, monitor: 0, pid: 50 }
      }]
    })
    verify(c !== null)
    c.refresh()
    var windowKey = c.registry.entries[0].key
    var foldKey = "herdr:" + windowKey
    service.publishSnapshot({
      schemaVersion: 1,
      providerEpoch: "epoch-fold",
      revision: 1,
      servers: [{
        id: "local-a",
        capabilities: { focusAgent: true },
        health: "live",
        clients: [{ pid: 41, startTime: 41, ancestors: [{ pid: 40, startTime: 40 }] }]
      }],
      agents: [{
        id: "local-a:1:pane-a",
        serverId: "local-a",
        connectionGeneration: 1,
        paneId: "pane-a",
        name: "Codex",
        agent: "codex",
        status: "working"
      }],
      liveCounts: { agents: 1, working: 1, idle: 0, done: 0, blocked: 0, unknown: 0, complete: true },
      completeness: { state: "complete" },
      windowProcesses: { revision: 1, identities: [{ pid: 40, startTime: 40 }] }
    })
    wait(0)
    compare(c.herdrAssociations.byWindowKey[windowKey], "local-a")
    c.refresh()
    var parent = c.projection.rows.filter(function(row) { return row.key === windowKey })[0]
    verify(parent)
    compare(parent.herdrFoldKey, foldKey)
    compare(parent.herdrFolded, false)
    verify(c.projection.rows.some(function(row) {
      return row.kind === "herdr-agent" && row.windowKey === windowKey
        && row.actionable === true
    }))
    verify(c.toggleHerdrAgents(windowKey))
    c.refresh()
    verify(c.folds[foldKey])
    parent = c.projection.rows.filter(function(row) { return row.key === windowKey })[0]
    compare(parent.herdrFolded, true)
    compare(parent.herdrStatusCounters.length, 1)
    compare(parent.herdrStatusCounters[0].status, "working")
    verify(!c.projection.rows.some(function(row) {
      return row.kind === "herdr-agent" && row.windowKey === windowKey
    }))
    // Fold memory survives another refresh.
    c.refresh()
    verify(c.folds[foldKey])
    // Actual rail mode must not erase Herdr fold memory or restart the lease.
    var leaseBeforeRail = service.activeCount
    c.settings = Object.assign({}, c.settings, {
      sidebarCollapsedByMonitor: { "DP-1": true }
    })
    compare(c.collapsedFor(screen), true)
    c.refresh()
    verify(c.folds[foldKey])
    compare(service.activeCount, leaseBeforeRail)
    verify(!c.railProjection.rows.some(function(row) {
      return row.kind === "herdr-agent" && row.windowKey === windowKey
    }))
    c.settings = Object.assign({}, c.settings, {
      sidebarCollapsedByMonitor: { "DP-1": false }
    })
    compare(c.collapsedFor(screen), false)
    c.refresh()
    verify(c.folds[foldKey])
    parent = c.projection.rows.filter(function(row) { return row.key === windowKey })[0]
    verify(parent)
    compare(parent.herdrFolded, true)
    // Hide must not prune Herdr fold while the window handle remains live.
    var desktopId = String(parent.desktopId || term.appId || "browser")
    c.settings = Object.assign({}, c.settings, {
      hiddenApplications: [desktopId]
    })
    c.refresh()
    verify(c.folds[foldKey])
    verify(c.registry.entries.some(function(entry) { return entry.key === windowKey }))
    verify(!c.projection.rows.some(function(row) { return row.key === windowKey }))
    c.settings = Object.assign({}, c.settings, {
      hiddenApplications: []
    })
    c.refresh()
    verify(c.folds[foldKey])
    parent = c.projection.rows.filter(function(row) { return row.key === windowKey })[0]
    verify(parent)
    compare(parent.herdrFolded, true)
    // Unrelated window removal must not prune the herdr fold.
    c.toplevels = [term]
    c.hyprToplevels = [{
      wayland: term, address: "0xh",
      lastIpcObject: { workspace: { id: 1 }, monitor: 0, pid: 40 }
    }]
    c.refresh()
    verify(c.folds[foldKey])
    // Window disappearance prunes the herdr fold key.
    c.toplevels = []
    c.hyprToplevels = []
    c.refresh()
    verify(!c.folds[foldKey])
  }

  Component { id: refreshSpyFactory; SignalSpy { signalName: "refreshed" } }

  // Claude has no sidebar Widget lease: bridge view and association changes
  // must schedule a projection refresh by themselves.
  function test_bridge_view_changes_refresh_without_widget_lease() {
    var service = createTemporaryObject(herdrServiceFactory, this)
    verify(service !== null)
    var a = createTemporaryObject(toplevelFactory, this, { title: "A" })
    var screen = { name: "DP-1", width: 1920, height: 1080 }
    var c = createHerdrController(service, {
      widgetRegistry: {
        "herdr.agents": {
          id: "herdr.agents",
          available: true,
          acquire: function(owner) { return service.acquire(owner) }
        }
      },
      settings: {
        presentationMode: "sidebar",
        pinned: [],
        workspaceGroups: [],
        sidebarCollapsed: false,
        sidebarWidgets: []
      },
      screens: [screen],
      monitors: [{ id: 0, name: "DP-1", activeWorkspace: { id: 1 } }],
      workspaces: [{ id: 1, monitorID: 0 }],
      toplevels: [a],
      hyprToplevels: [{
        wayland: a, address: "0xa",
        lastIpcObject: { workspace: { id: 1 }, monitor: 0, pid: 40 }
      }]
    })
    verify(c !== null)
    var bridge = c.host.herdrWindowAgents
    verify(bridge !== null)
    // The dock-side setting keeps the bridge leased without any sidebar Widget.
    bridge.dockConsumerActive = true
    compare(bridge.consumerActive, true)
    compare(c.widgetIds.length, 0)
    var spy = createTemporaryObject(refreshSpyFactory, this, { target: c })
    verify(spy !== null)
    wait(0)
    var before = spy.count

    // A provider snapshot bumps viewRevision and must refresh the sidebar.
    var revisionBefore = bridge.viewRevision
    service.publishSnapshot({
      schemaVersion: 1,
      providerEpoch: "epoch-1",
      revision: 10,
      servers: [{
        id: "local-a",
        capabilities: { focusAgent: true },
        clients: [{ pid: 41, startTime: 41, ancestors: [{ pid: 40, startTime: 40 }] }]
      }],
      windowProcesses: { revision: 1, identities: [{ pid: 40, startTime: 40 }] }
    })
    verify(bridge.viewRevision > revisionBefore)
    tryVerify(function() { return spy.count > before }, 2000)

    // An association change alone also schedules a refresh.
    wait(0)
    before = spy.count
    bridge.herdrAssociations = { byWindowKey: ({}), unmatchedServerIds: [] }
    tryVerify(function() { return spy.count > before }, 2000)

    // Refreshes settle: no callLater ping-pong after the scheduled work runs.
    wait(0)
    var settled = spy.count
    wait(0)
    compare(spy.count, settled)
  }
}
