import QtQuick
import QtTest
import "../components/DockModel.js" as DockModel
import "../components/DockWindowModel.js" as DockWindowModel

TestCase {
  name: "WindowScope"

  function window(appId) {
    return { appId: appId }
  }

  function handle(toplevel, address, workspaceId, workspaceName, monitor, urgent) {
    return {
      wayland: toplevel,
      address: address,
      lastIpcObject: {
        workspace: { id: workspaceId, name: workspaceName },
        monitor: monitor,
        urgent: urgent === true
      }
    }
  }

  function context(scope, workspaceId, workspaceName, monitorId, urgentOutside) {
    return DockWindowModel.windowScopeContext(
      scope,
      { id: workspaceId, name: workspaceName },
      { id: monitorId, name: "MON-" + monitorId },
      urgentOutside)
  }

  function hasFunction(name) {
    var available = typeof DockWindowModel[name] === "function"
    verify(available, name + " must be implemented")
    return available
  }

  function test_normalizesScopeSettingsCompatibly() {
    if (!hasFunction("normalizeWindowScope")) return
    if (!hasFunction("normalizeShowUrgentOutsideScope")) return

    compare(DockWindowModel.normalizeWindowScope(undefined), "all")
    compare(DockWindowModel.normalizeWindowScope("invalid"), "all")
    compare(DockWindowModel.normalizeWindowScope("all"), "all")
    compare(DockWindowModel.normalizeWindowScope("workspace"), "workspace")
    compare(DockWindowModel.normalizeWindowScope("monitor"), "monitor")
    compare(DockWindowModel.normalizeWindowScope("workspace-monitor"),
      "workspace-monitor")
    compare(DockWindowModel.normalizeShowUrgentOutsideScope(undefined), true)
    compare(DockWindowModel.normalizeShowUrgentOutsideScope(false), false)
    compare(DockWindowModel.normalizeShowUrgentOutsideScope("false"), true)
  }

  function test_buildsWorkspaceAndMonitorContextIncludingSpecialWorkspaces() {
    if (!hasFunction("windowScopeContext")) return
    if (!hasFunction("focusedWorkspaceIdentity")) return

    var normal = context("workspace-monitor", 2, "2", 1, true)
    compare(normal.scope, "workspace-monitor")
    compare(normal.workspace, "id:2")
    compare(normal.monitor, "id:1")
    compare(normal.showUrgentOutsideScope, true)

    var special = context("workspace", -99, "special:magic", 1, true)
    compare(special.workspace, "special:magic")

    var monitors = [
      { lastIpcObject: { focused: false, activeWorkspace: { id: 1, name: "1" } } },
      { lastIpcObject: { focused: true,
        activeWorkspace: { id: -7, name: "special:notes" } } }
    ]
    compare(DockWindowModel.focusedWorkspaceIdentity(
      monitors, { id: 3, name: "3" }), "special:notes")

    monitors = [
      { focused: true, activeWorkspace: { id: 1 },
        lastIpcObject: { focused: false, activeWorkspace: { id: 2 } } },
      { focused: false, activeWorkspace: { id: 2 },
        lastIpcObject: { focused: true, activeWorkspace: { id: 2 } } }
    ]
    compare(DockWindowModel.focusedWorkspaceIdentity(monitors, null), "id:1")
  }

  function test_resolvesKnownNormalAndMinimizedLocations() {
    if (!hasFunction("locationForToplevel")) return

    var regular = window("demo")
    var minimized = window("demo")
    var handles = [
      handle(regular, "0xaaa", 2, "2", 1, false),
      handle(minimized, "0xbbb", -99, "special:smartdock-minimized", 0, false)
    ]
    var origins = {
      "0xbbb": { workspace: "special:notes", monitor: "1" }
    }

    var regularLocation = DockWindowModel.locationForToplevel(
      regular, handles, origins)
    compare(regularLocation.workspace, "id:2")
    compare(regularLocation.monitor, "id:1")
    compare(regularLocation.workspaceKnown, true)
    compare(regularLocation.monitorKnown, true)
    compare(regularLocation.minimized, false)

    var minimizedLocation = DockWindowModel.locationForToplevel(
      minimized, handles, origins)
    compare(minimizedLocation.workspace, "special:notes")
    compare(minimizedLocation.monitor, "id:1")
    compare(minimizedLocation.workspaceKnown, true)
    compare(minimizedLocation.monitorKnown, true)
    compare(minimizedLocation.minimized, true)
  }

  function test_liveLocationWinsDuringWorkspaceMove() {
    var app = window("demo")
    var moving = handle(app, "0xaaa", 1, "1", 0, false)
    moving.workspace = { id: 2, name: "2" }
    moving.monitor = { id: 1, name: "MON-1" }
    var location = DockWindowModel.locationForToplevel(app, [moving], {})
    compare(location.workspace, "id:2")
    compare(location.monitor, "id:1")

    moving.workspace = { id: -99, name: "special:smartdock-minimized" }
    location = DockWindowModel.locationForToplevel(app, [moving], {
      "0xaaa": { workspace: "2", monitor: "1" }
    })
    compare(location.minimized, true)
    compare(location.workspace, "id:2")
  }

  function test_unknownNewAndMinimizedLocationsFailOpen() {
    if (!hasFunction("locationForToplevel")) return
    if (!hasFunction("locationMatchesContext")) return

    var newlyMapped = window("new")
    var unknownMinimized = window("min")
    var handles = [
      handle(unknownMinimized, "0xccc", -99,
        "special:smartdock-minimized", 1, false)
    ]
    var scoped = context("workspace-monitor", 4, "4", 0, false)

    var newLocation = DockWindowModel.locationForToplevel(
      newlyMapped, handles, {})
    compare(newLocation.workspaceKnown, false)
    compare(newLocation.monitorKnown, false)
    compare(DockWindowModel.locationMatchesContext(newLocation, scoped), true)

    var minimizedLocation = DockWindowModel.locationForToplevel(
      unknownMinimized, handles, {})
    compare(minimizedLocation.minimized, true)
    compare(minimizedLocation.workspaceKnown, false)
    compare(minimizedLocation.monitorKnown, false)
    compare(DockWindowModel.locationMatchesContext(minimizedLocation, scoped), true)
  }

  function test_matchesEachScopeModeIndependently() {
    if (!hasFunction("locationMatchesContext")) return

    var local = {
      workspace: "id:2", monitor: "id:1",
      workspaceKnown: true, monitorKnown: true, urgent: false
    }
    var otherWorkspace = {
      workspace: "id:3", monitor: "id:1",
      workspaceKnown: true, monitorKnown: true, urgent: false
    }
    var otherMonitor = {
      workspace: "id:2", monitor: "id:0",
      workspaceKnown: true, monitorKnown: true, urgent: false
    }

    compare(DockWindowModel.locationMatchesContext(
      otherWorkspace, context("all", 2, "2", 1, false)), true)
    compare(DockWindowModel.locationMatchesContext(
      local, context("workspace", 2, "2", 0, false)), true)
    compare(DockWindowModel.locationMatchesContext(
      otherWorkspace, context("workspace", 2, "2", 1, false)), false)
    compare(DockWindowModel.locationMatchesContext(
      local, context("monitor", 9, "9", 1, false)), true)
    compare(DockWindowModel.locationMatchesContext(
      otherMonitor, context("monitor", 2, "2", 1, false)), false)
    compare(DockWindowModel.locationMatchesContext(
      local, context("workspace-monitor", 2, "2", 1, false)), true)
    compare(DockWindowModel.locationMatchesContext(
      otherWorkspace, context("workspace-monitor", 2, "2", 1, false)), false)
    compare(DockWindowModel.locationMatchesContext(
      otherMonitor, context("workspace-monitor", 2, "2", 1, false)), false)
  }

  function test_trueHyprlandUrgentIsTheOnlyOutsideScopeException() {
    if (!hasFunction("filterToplevelsByScope")) return

    var local = window("demo")
    var urgent = window("demo")
    var attentionOnly = window("demo")
    var handles = [
      handle(local, "0x1", 1, "1", 0, false),
      handle(urgent, "0x2", 2, "2", 1, true),
      {
        wayland: attentionOnly,
        address: "0x3",
        attention: true,
        lastIpcObject: {
          workspace: { id: 2, name: "2" },
          monitor: 1,
          urgent: false
        }
      }
    ]

    var allowUrgent = context("workspace-monitor", 1, "1", 0, true)
    var filtered = DockWindowModel.filterToplevelsByScope(
      [local, urgent, attentionOnly], handles, {}, allowUrgent)
    compare(filtered.length, 2)
    verify(filtered.indexOf(local) >= 0)
    verify(filtered.indexOf(urgent) >= 0)
    compare(filtered.indexOf(attentionOnly), -1)

    var denyUrgent = context("workspace-monitor", 1, "1", 0, false)
    filtered = DockWindowModel.filterToplevelsByScope(
      [local, urgent, attentionOnly], handles, {}, denyUrgent)
    compare(filtered.length, 1)
    compare(filtered[0], local)
  }

  function test_filtersBeforeGroupingAndKeepsClosedPinnedLaunchers() {
    if (!hasFunction("filterToplevelsByScope")) return

    var local = window("demo")
    var remote = window("demo")
    var urgentRemote = window("demo")
    var handles = [
      handle(local, "0x11", 1, "1", 0, false),
      handle(remote, "0x12", 2, "2", 1, false),
      handle(urgentRemote, "0x13", 2, "2", 1, true)
    ]
    var filtered = DockWindowModel.filterToplevelsByScope(
      [local, remote, urgentRemote], handles, {},
      context("workspace-monitor", 1, "1", 0, true))
    var entries = [
      { id: "demo.desktop", startupClass: "demo" },
      { id: "closed.desktop", startupClass: "closed" }
    ]
    var items = DockModel.buildVisibleItems(
      ["demo.desktop", "closed.desktop"], filtered, entries, handles,
      false, true, [])

    compare(items.length, 2)
    compare(items[0].desktopId, "demo.desktop")
    compare(items[0].toplevels.length, 2)
    verify(items[0].toplevels.indexOf(local) >= 0)
    verify(items[0].toplevels.indexOf(urgentRemote) >= 0)
    compare(items[0].toplevels.indexOf(remote), -1)
    compare(items[1].desktopId, "closed.desktop")
    compare(items[1].toplevels.length, 0)
  }

  function test_urgentOutOfScopeWindowExposesOnlyItselfUngroupedAndHiddenWins() {
    if (!hasFunction("filterToplevelsByScope")) return

    var remote = window("demo")
    var urgentRemote = window("demo")
    var handles = [
      handle(remote, "0x21", 2, "2", 1, false),
      handle(urgentRemote, "0x22", 2, "2", 1, true)
    ]
    var filtered = DockWindowModel.filterToplevelsByScope(
      [remote, urgentRemote], handles, {},
      context("workspace", 1, "1", 0, true))
    compare(filtered.length, 1)
    compare(filtered[0], urgentRemote)

    var entries = [{ id: "demo.desktop", startupClass: "demo" }]
    var ungrouped = DockModel.buildVisibleItems(
      [], filtered, entries, handles, false, false, [])
    compare(ungrouped.length, 1)
    compare(ungrouped[0].toplevels.length, 1)
    compare(ungrouped[0].toplevels[0], urgentRemote)

    var hidden = DockModel.buildVisibleItems(
      [], filtered, entries, handles, false, true, ["demo.desktop"])
    compare(hidden.length, 0)
  }

  function test_copiesOriginSnapshotWithCanonicalKeysWithoutMutatingSource() {
    if (!hasFunction("copyOriginSnapshot")) return

    var record = { workspace: "2", monitor: "1" }
    var source = {
      "0XBEEF": record,
      "not-an-address": { workspace: "9", monitor: "9" }
    }
    var snapshot = DockWindowModel.copyOriginSnapshot(source)

    compare(Object.keys(snapshot).length, 1)
    compare(snapshot["0xbeef"].workspace, "2")
    compare(snapshot["0xbeef"].monitor, "1")
    verify(snapshot["0xbeef"] !== record)
    compare(record.workspace, "2")
    compare(source["0XBEEF"].workspace, "2")
    verify(snapshot["not-an-address"] === undefined)
  }

  function test_prunesStaleOriginAddressesWithoutLosingLiveOrigins() {
    if (!hasFunction("pruneOriginSnapshot")) return

    var minimized = window("demo")
    var handles = [
      handle(minimized, "0xbeef", -99, "special:smartdock-minimized", 0, false)
    ]
    var origins = {
      "0xbeef": { workspace: "2", monitor: "1" },
      "0xdead": { workspace: "3", monitor: "0" }
    }
    var pruned = DockWindowModel.pruneOriginSnapshot(
      origins, handles, [minimized])

    compare(Object.keys(pruned).length, 1)
    compare(pruned["0xbeef"].workspace, "2")
    compare(pruned["0xbeef"].monitor, "1")
  }

  function test_scopeRefreshEventsCoverMovesUrgencyWorkspacesAndHotplug() {
    if (!hasFunction("shouldRefreshWindowScope")) return

    var refreshEvents = [
      "openwindow", "closewindow", "movewindow", "movewindowv2",
      "workspace", "workspacev2", "createworkspace", "createworkspacev2",
      "destroyworkspace", "destroyworkspacev2", "moveworkspace", "moveworkspacev2",
      "renameworkspace", "changeworkspaceid", "focusedmon", "focusedmonv2", "configreloaded",
      "urgent", "fullscreen", "monitoradded", "monitoraddedv2",
      "monitorremoved", "monitorremovedv2"
    ]
    for (var i = 0; i < refreshEvents.length; ++i)
      compare(DockWindowModel.shouldRefreshWindowScope(refreshEvents[i]), true,
        refreshEvents[i])

    compare(DockWindowModel.shouldRefreshWindowScope("windowtitle"), false)
    compare(DockWindowModel.shouldRefreshWindowScope(""), false)
  }
}
