import QtQuick
import QtTest
import "../components/DockDesktopModel.js" as DesktopModel
import "../components/DockWindowModel.js" as DockWindowModel

TestCase {
  name: "DesktopModel"

  function snapshot(mode) {
    var first = { appId: "example.browser", title: "First" }
    var second = { appId: "example.browser", title: "Second" }
    return {
      mode: mode,
      settings: {
        pinned: ["example.browser", "example.closed"], hiddenApplications: [],
        workspaceGroups: [], workspaceMonitorScope: "all", workspaceMonitorOrder: [],
        sortByWorkspace: false
      },
      applications: [], toplevels: [first, second], filteredToplevels: [first],
      hyprToplevels: [
        { wayland: first, address: "0xa", lastIpcObject: { workspace: { id: 1 }, monitor: 0 } },
        { wayland: second, address: "0xb", lastIpcObject: { workspace: { id: 3 }, monitor: 1 } }
      ],
      hyprWorkspaces: [{ id: 1, monitorID: 0 }, { id: 2, monitorID: 0 }, { id: 3, monitorID: 1 }],
      hyprMonitors: [
        { id: 0, name: "DP-1", x: 1920, y: 0, focused: true, activeWorkspace: { id: 1 } },
        { id: 1, name: "HDMI-A-1", x: 0, y: 0, activeWorkspace: { id: 3 } }
      ],
      dockMonitor: { id: 0 }, focusedWorkspace: "id:1", minimizedOrigins: ({})
    }
  }

  function test_real_qml_imports_and_native_grouped_shape() {
    var input = snapshot("classic-grouped")
    var result = DesktopModel.build(input)
    compare(result.records.length, 2)
    verify(result.records[0].toplevel === input.toplevels[0])
    compare(result.workspacePresentation.monitorGroups[0].identity, "id:1")
    compare(result.workspacePresentation.primaryWorkspaceIdentity, "id:1")
    compare(result.workspacePresentation.globalLaunchers.length, 1)
    compare(result.workspacePresentation.globalLaunchers[0].desktopId, "example.closed")
    compare(result.workspacePresentation.groups.length, 3)
    verify(Array.isArray(result.workspacePresentation.renderedItems))
    verify(Array.isArray(result.workspacePresentation.fallbackItems))
    // Grouped inventory and filtered flat inventory remain deliberately distinct.
    compare(result.visibleItems.filter(function(item) { return item.toplevels.length > 0 }).length, 1)
  }

  function test_flat_has_no_workspace_replacement() {
    var input = snapshot("classic-flat")
    var result = DesktopModel.build(input)
    compare(result.workspacePresentation, null)
    compare(result.records.length, 1)
    verify(result.records[0].toplevel === input.filteredToplevels[0])
    compare(result.visibleItems.length, 2)
  }

  function test_unsupported_mode_is_not_silently_classic() {
    var rejected = false
    try { DesktopModel.build(snapshot("unsupported")) } catch (error) { rejected = true }
    verify(rejected)
  }

  function test_groupedPresentationDropsSpecialWorkspaceWindows() {
    var normal = { appId: "example.browser", title: "Normal" }
    var scratch = { appId: "example.browser", title: "Scratch" }
    var input = snapshot("classic-grouped")
    input.toplevels = [normal, scratch]
    input.filteredToplevels = [normal]
    input.hyprToplevels = [
      { wayland: normal, address: "0xa",
        lastIpcObject: { workspace: { id: 1 }, monitor: 0 } },
      { wayland: scratch, address: "0xb",
        lastIpcObject: { workspace: { id: -98, name: "special:scratchpad" }, monitor: 0 } }
    ]
    var result = DesktopModel.build(input)
    compare(result.records.length, 1)
    compare(result.records[0].toplevel, normal)
    var group = result.workspacePresentation.groups.filter(function(value) {
      return value.identity === "id:1"
    })[0]
    compare(group.items.length, 1)
    compare(group.items[0].toplevels.length, 1)
    compare(result.workspacePresentation.fallbackItems.length, 0)
  }
}
