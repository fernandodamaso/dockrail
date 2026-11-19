import assert from 'node:assert/strict'
import fs from 'node:fs'
import vm from 'node:vm'

// Special workspaces are overlays, not desktop space. The desktop model clamps
// its inventory so neither the grouped dock nor the sidebar can present a
// window that lives on one — while Dockrail's own minimize workspace keeps
// resolving to the recorded origin and unknown locations fail open.
const root = new URL('../', import.meta.url)
const read = path => fs.readFileSync(new URL(path, root), 'utf8')
function load(name, imports = {}) {
  const scope = vm.createContext(imports)
  vm.runInContext(read(`components/${name}.js`).replace(/^\.(pragma|import).*$/gm, ''), scope)
  return scope
}
const DockModel = load('DockModel')
const DockIconModel = load('DockIconModel')
const DockWindowModel = load('DockWindowModel', { DockModel })
const WorkspaceModel = load('DockWorkspaceModel', { DockModel, DockWindowModel })
const WorkspaceGroupModel = load('DockWorkspaceGroupModel', { DockModel })
const DesktopModel = load('DockDesktopModel',
  { DockModel, DockWindowModel, WorkspaceModel, WorkspaceGroupModel })

// Addresses must be valid hex handles: Dockrail ignores malformed ones and the
// minimized-origin lookup is keyed by address.
function desktop(specs, originsById = {}) {
  const toplevels = []
  const hyprToplevels = []
  const minimizedOrigins = {}
  specs.forEach((spec, index) => {
    const toplevel = { id: spec.id, appId: spec.appId, title: spec.id }
    toplevels.push(toplevel)
    if (spec.noHandle) return
    const address = `0x${(0x100 + index).toString(16)}`
    if (originsById[spec.id]) minimizedOrigins[address] = originsById[spec.id]
    hyprToplevels.push({
      wayland: toplevel, address,
      lastIpcObject: { workspace: spec.workspace, monitor: 0, urgent: false }
    })
  })
  return {
    input: {
      mode: 'classic-grouped',
      settings: {
        pinned: [], hiddenApplications: [], workspaceGroups: [],
        workspaceMonitorScope: 'all', workspaceMonitorOrder: [], sortByWorkspace: false
      },
      applications: [], toplevels, filteredToplevels: toplevels, hyprToplevels,
      hyprWorkspaces: [{ id: 1, monitorID: 0 }, { id: 3, monitorID: 0 }],
      hyprMonitors: [{ id: 0, name: 'DP-1', focused: true, activeWorkspace: { id: 1 } }],
      dockMonitor: { id: 0 }, focusedWorkspace: 'id:1', minimizedOrigins
    },
    toplevels
  }
}

function ids(records) {
  return Array.from(records, record => record.toplevel.id).sort()
}

// A special-workspace window is absent while a normal window and a Dockrail
// minimized window stay present.
{
  const { input, toplevels } = desktop([
    { id: 'a', appId: 'app.editor', workspace: { id: 1 } },
    { id: 's', appId: 'app.editor', workspace: { id: -98, name: 'special:scratchpad' } },
    { id: 'm', appId: 'app.terminal', workspace: { id: -99, name: 'special:smartdock-minimized' } }
  ], { m: { workspace: '3', monitor: '0' } })
  const built = DesktopModel.build(input)
  assert.deepEqual(ids(built.records), ['a', 'm'], 'special window never reaches the inventory')
  const group = built.workspacePresentation.groups.find(value => value.identity === 'id:1')
  assert.equal(group.items.length, 1, 'the app keeps one presentable member')
  assert.equal(group.items[0].toplevels.length, 1, 'window count ignores the scratchpad window')
  assert.equal(built.workspacePresentation.fallbackItems.length, 0,
    'no window falls outside the workspace cards')
  assert.ok(toplevels.includes(group.items[0].toplevels[0]), 'live handle identity is preserved')
  const origin = built.workspacePresentation.groups.find(value => value.identity === 'id:3')
  assert.equal(origin.items.length, 1, 'a minimized window keeps its recorded origin card')
}

// A minimized window whose recorded origin is itself a special workspace stays
// hidden; an unresolvable origin and an unknown location both fail open.
{
  const { input, toplevels } = desktop([
    { id: 'f', appId: 'app.editor', workspace: { id: -99, name: 'special:smartdock-minimized' } },
    { id: 'e', appId: 'app.terminal', workspace: { id: -99, name: 'special:smartdock-minimized' } },
    { id: 'c', appId: 'app.unknown', noHandle: true }
  ], { f: { workspace: 'special:scratchpad', monitor: 'id:0' } })
  const built = DesktopModel.build(input)
  assert.deepEqual(ids(built.records), ['c', 'e'],
    'special origin stays hidden; unknown origin and unknown location fail open')
  assert.ok(toplevels.includes(built.records.find(record => record.toplevel.id === 'c').toplevel))
}

// Every special workspace counts, not only the one named scratchpad.
{
  const { input } = desktop([
    { id: 'a', appId: 'app.editor', workspace: { id: 1 } },
    { id: 'b', appId: 'app.editor', workspace: { id: -97, name: 'special:qconsole' } }
  ])
  assert.deepEqual(ids(DesktopModel.build(input).records), ['a'])
}

// The sidebar mode clamps the same way.
{
  const { input } = desktop([
    { id: 'a', appId: 'app.editor', workspace: { id: 1 } },
    { id: 'b', appId: 'app.editor', workspace: { id: -98, name: 'special:scratchpad' } }
  ])
  input.mode = 'sidebar'
  assert.deepEqual(ids(DesktopModel.build(input).records), ['a'])
}

console.log('special-workspace visibility: PASS')
