import assert from 'node:assert/strict'
import fs from 'node:fs'
import vm from 'node:vm'

function load(name, imports = {}) {
  const scope = vm.createContext(imports)
  vm.runInContext(fs.readFileSync(new URL(`../components/${name}.js`, import.meta.url), 'utf8')
    .replace(/^\.(pragma|import).*$/gm, ''), scope)
  return scope
}

const DockModel = load('DockModel')
const DockWindowModel = load('DockWindowModel', { DockModel })
const WorkspaceModel = load('DockWorkspaceModel', { DockModel, DockWindowModel })

function app(desktopId, ...toplevels) {
  return { desktopId, pinned: false, toplevels }
}

function record(toplevel, workspace, monitor, extra = {}) {
  return {
    toplevel,
    address: extra.address || '',
    workspace,
    monitor,
    workspaceKnown: workspace !== '',
    monitorKnown: monitor !== '',
    minimized: extra.minimized === true,
    originValid: extra.originValid,
    sticky: extra.sticky === true,
    urgent: extra.urgent === true
  }
}

function monitorIdentitySummary(presentation) {
  return Array.from(presentation.groups, group => [
    group.identity, group.monitorIdentity || '', group.active === true
  ])
}

function monitorGroupSummary(presentation) {
  return Array.from(presentation.monitorGroups || [], group => [
    group.identity || '', group.connector || '', group.label || '',
    group.focused === true, group.activeWorkspace || '',
    group.firstWorkspaceIdentity || ''
  ])
}

const left = {
  id: 0,
  name: 'DP-1',
  description: 'Built-in panel',
  model: 'Panel 14',
  focused: false,
  activeWorkspace: { id: 1, name: '1' }
}
const right = {
  id: 1,
  name: 'HDMI-A-1',
  lastIpcObject: {
    id: 1,
    name: 'HDMI-A-1',
    description: 'Desk display',
    model: 'Desk 27',
    focused: true,
    activeWorkspace: { id: 3, name: '3' }
  }
}
const monitors = [left, right]
const descriptors = [
  { id: 10, name: 'Work', monitorID: 0 },
  { id: 1, monitorID: 0 },
  { id: 2, monitorID: 1 },
  { id: 3, monitorID: 1 },
  { name: 'Design', monitorID: 1 }
]
const one = { appId: 'one' }
const three = { appId: 'three' }
const ten = { appId: 'ten' }
const records = [
  record(one, 'id:1', 'id:0'),
  record(three, 'id:3', 'id:1'),
  record(ten, 'id:10', 'id:0')
]
const apps = [
  { desktopId: 'closed', pinned: true, toplevels: [] },
  app('one', one), app('three', three), app('ten', ten)
]

function buildAll(overrides = {}) {
  const activeWorkspace = DockWindowModel.focusedWorkspaceIdentity(
    overrides.monitors || monitors, null)
  return WorkspaceModel.buildWorkspacePresentation(
    overrides.apps || apps,
    overrides.records || records,
    overrides.workspaces || descriptors,
    {
      monitorScope: 'all',
      monitor: 'id:0',
      activeWorkspace,
      monitors: overrides.monitors || monitors,
      groupWindows: true
    })
}

const initial = buildAll()
assert.equal(initial.primaryWorkspaceIdentity, 'id:3',
  'global focus is retained separately from per-monitor active styling')
assert.deepEqual(monitorIdentitySummary(initial), [
  ['id:1', 'id:0', true],
  ['id:10', 'id:0', false],
  ['id:2', 'id:1', false],
  ['id:3', 'id:1', true],
  ['name:Design', 'id:1', false]
], 'each workspace appears once under one canonical monitor owner')
assert.deepEqual(monitorGroupSummary(initial), [
  ['id:0', 'DP-1', 'Panel 14', false, 'id:1', 'id:1'],
  ['id:1', 'HDMI-A-1', 'Desk 27', true, 'id:3', 'id:2']
], 'monitor metadata carries active/focus state and section boundaries')
assert.deepEqual(Array.from(initial.monitorGroups, group => group.description),
  ['Built-in panel', 'Desk display'],
  'compact labels retain the complete monitor description')
assert.deepEqual(Array.from(initial.groups.filter(group => group.active), group => group.identity),
  ['id:1', 'id:3'], 'each monitor active workspace gets active card styling')

const liveOverStale = buildAll({
  monitors: [
    { ...left, focused: true, activeWorkspace: { id: 1 },
      lastIpcObject: { id: 0, name: 'DP-1', focused: false,
        activeWorkspace: { id: 2 } } },
    { id: 1, name: 'HDMI-A-1', focused: false, activeWorkspace: { id: 3 },
      lastIpcObject: { ...right.lastIpcObject, focused: true,
        activeWorkspace: { id: 2 } } }
  ]
})
assert.equal(liveOverStale.primaryWorkspaceIdentity, 'id:1')
assert.deepEqual(Array.from(liveOverStale.groups.filter(group => group.active),
  group => group.identity), ['id:1', 'id:3'],
  'dedicated live monitor properties override stale IPC snapshots')
assert.equal(initial.globalLaunchers.length, 1, 'closed global launchers remain singleton')
assert.deepEqual(Array.from(initial.renderedItems, item => item.presentationId),
  ['id:3/three', 'id:1/one', 'id:10/ten', 'global/closed'],
  'badge traversal stays primary-focus first and otherwise uses old workspace order')

left.focused = true
right.lastIpcObject.focused = false
const focusTransferred = buildAll()
assert.equal(focusTransferred.primaryWorkspaceIdentity, 'id:1')
assert.deepEqual(Array.from(focusTransferred.groups.filter(group => group.active), group => group.identity),
  ['id:1', 'id:3'], 'focus transfer does not change per-monitor active cards')
assert.equal(WorkspaceModel.presentationsEqual(initial, focusTransferred), false,
  'focus-only transfer refreshes presentation metadata')
assert.deepEqual(Array.from(focusTransferred.renderedItems, item => item.presentationId),
  ['id:1/one', 'id:3/three', 'id:10/ten', 'global/closed'])

const reordered = buildAll({
  monitors: [right, left],
  workspaces: descriptors.slice().reverse(),
  records: records.slice().reverse()
})
assert.equal(WorkspaceModel.presentationsEqual(focusTransferred, reordered), true,
  'inventory order alone does not change semantic presentation')

const beforeDescription = focusTransferred
left.description = 'Renamed built-in panel'
const afterDescription = buildAll()
assert.equal(WorkspaceModel.presentationsEqual(beforeDescription, afterDescription), false,
  'same-object monitor description changes refresh metadata')
assert.equal((afterDescription.monitorGroups || [])[0]?.label, 'Panel 14')
assert.equal((afterDescription.monitorGroups || [])[0]?.description, 'Renamed built-in panel')

const beforeModel = afterDescription
left.model = 'Panel 15'
const afterModel = buildAll()
assert.equal(WorkspaceModel.presentationsEqual(beforeModel, afterModel), false,
  'same-object monitor model changes refresh the compact label')
assert.equal((afterModel.monitorGroups || [])[0]?.label, 'Panel 15')

const movingWindow = { appId: 'moving' }
const movingWorkspace = { id: 5, name: 'Five', monitorID: 0 }
const movingApps = [app('moving', movingWindow)]
const movingRecords = [record(movingWindow, 'id:5', 'id:0')]
function buildMoving(workspaces = [movingWorkspace], currentMonitors = monitors) {
  return WorkspaceModel.buildWorkspacePresentation(
    movingApps, movingRecords, workspaces, {
      monitorScope: 'all', monitor: 'id:0', activeWorkspace: 'id:1',
      monitors: currentMonitors, groupWindows: true
    })
}
const beforeMove = buildMoving()
assert.equal(beforeMove.groups.find(group => group.identity === 'id:5')?.monitorIdentity, 'id:0')
movingWorkspace.monitorID = 1
const afterMove = buildMoving()
assert.equal(afterMove.groups.find(group => group.identity === 'id:5')?.monitorIdentity, 'id:1',
  'authoritative workspace descriptor overrides stale client monitor')
assert.equal(WorkspaceModel.presentationsEqual(beforeMove, afterMove), false)

movingWorkspace.monitorID = 99
const unresolved = buildMoving()
assert.equal(unresolved.groups.find(group => group.identity === 'id:5')?.monitorIdentity, '',
  'unresolved authoritative descriptor is never replaced by stale client ownership')
assert.deepEqual(monitorGroupSummary(unresolved).slice(-1), [
  ['', '', 'Unknown monitor', false, '', 'id:5']
], 'known workspace with unresolved owner gets a temporary unknown monitor section')

const conflictA = { appId: 'conflict-a' }
const conflictB = { appId: 'conflict-b' }
const conflicted = WorkspaceModel.buildWorkspacePresentation(
  [app('conflict-a', conflictA), app('conflict-b', conflictB)],
  [record(conflictA, 'id:7', 'id:0'), record(conflictB, 'id:7', 'id:1')],
  [], {
    monitorScope: 'all', monitor: 'id:0', activeWorkspace: 'id:1',
    monitors, groupWindows: true
  })
assert.equal(conflicted.groups.find(group => group.identity === 'id:7')?.monitorIdentity, '',
  'conflicting live window owners remain unresolved instead of first-record wins')

const unknownWindow = { appId: 'unknown' }
const unknownLive = WorkspaceModel.buildWorkspacePresentation(
  [app('unknown', unknownWindow)],
  [record(unknownWindow, 'id:9', 'MISSING-CONNECTOR')],
  [], {
    monitorScope: 'all', monitor: 'id:0', activeWorkspace: 'id:1',
    monitors, groupWindows: true
  })
assert.equal(unknownLive.groups.find(group => group.identity === 'id:9')?.monitorIdentity, '',
  'known live workspace remains present when monitor ownership is temporarily unknown')
assert.equal(unknownLive.groups.find(group => group.identity === 'id:9')?.count, 1)
assert.equal(unknownLive.fallbackItems.length, 0,
  'known workspace with unknown monitor does not fall into Other windows')
assert.deepEqual(monitorGroupSummary(unknownLive).slice(-1), [
  ['', '', 'Unknown monitor', false, '', 'id:9']
])

const partialA = { appId: 'partial-a' }
const partialB = { appId: 'partial-b' }
const partiallyUnresolved = WorkspaceModel.buildWorkspacePresentation(
  [app('partial-a', partialA), app('partial-b', partialB)],
  [record(partialA, 'id:11', 'id:0'), record(partialB, 'id:11', 'MISSING-CONNECTOR')],
  [], {
    monitorScope: 'all', monitor: 'id:0', activeWorkspace: 'id:1',
    monitors, groupWindows: true
  })
assert.equal(partiallyUnresolved.groups.find(group => group.identity === 'id:11')?.monitorIdentity, '',
  'mixed known and unknown live owners stay unresolved rather than guessing the known owner')
assert.equal(partiallyUnresolved.groups.find(group => group.identity === 'id:11')?.count, 2)
assert.equal(partiallyUnresolved.fallbackItems.length, 0)

const minimizedWindow = { appId: 'minimized' }
const liveOwned = WorkspaceModel.buildWorkspacePresentation(
  [app('minimized', minimizedWindow)],
  [record(minimizedWindow, 'id:6', 'id:0', { minimized: true, originValid: true })],
  [{ id: 6, monitorID: 1 }], {
    monitorScope: 'all', monitor: 'id:0', activeWorkspace: 'id:1',
    monitors, groupWindows: true
  })
assert.equal(liveOwned.groups.find(group => group.identity === 'id:6')?.monitorIdentity, 'id:1',
  'live workspace ownership wins over minimized origin connector')

const reconnectWorkspace = { id: 8, monitor: 'HDMI-A-1' }
const connected = WorkspaceModel.buildWorkspacePresentation([], [], [reconnectWorkspace], {
  monitorScope: 'all', monitor: 'id:0', activeWorkspace: 'id:1', monitors, groupWindows: true
})
assert.equal(connected.groups.find(group => group.identity === 'id:8')?.monitorIdentity, 'id:1')
const disconnected = WorkspaceModel.buildWorkspacePresentation([], [], [reconnectWorkspace], {
  monitorScope: 'all', monitor: 'id:0', activeWorkspace: 'id:1', monitors: [left], groupWindows: true
})
assert.equal(disconnected.groups.find(group => group.identity === 'id:8')?.monitorIdentity, '')
const reconnectedMonitor = {
  id: 7, name: 'HDMI-A-1', focused: false,
  activeWorkspace: { id: 8, name: '8' }
}
const reconnected = WorkspaceModel.buildWorkspacePresentation([], [], [reconnectWorkspace], {
  monitorScope: 'all', monitor: 'id:0', activeWorkspace: 'id:1',
  monitors: [left, reconnectedMonitor], groupWindows: true
})
assert.equal(reconnected.groups.find(group => group.identity === 'id:8')?.monitorIdentity, 'id:7')
assert.equal(reconnected.groups.find(group => group.identity === 'id:8')?.identity, 'id:8',
  'reconnect changes monitor identity without changing workspace identity')

const currentMonitor = WorkspaceModel.buildWorkspacePresentation(apps, records, descriptors, {
  monitorScope: 'current-monitor', monitor: 'id:0', activeWorkspace: 'id:1',
  monitors, groupWindows: true
})
assert.equal(currentMonitor.primaryWorkspaceIdentity, 'id:1')
assert.deepEqual(Array.from(currentMonitor.monitorGroups || []), [],
  'current-monitor scope keeps the existing flat grouped appearance')
assert.deepEqual(Array.from(currentMonitor.groups, group => group.identity), ['id:1', 'id:10'])
assert.deepEqual(Array.from(currentMonitor.groups.filter(group => group.active), group => group.identity), ['id:1'])


// Captured 2026-10-31: stale client responses recreate deleted/renumbered
// workspaces as name-only Quickshell objects with no authoritative data.
const orphan3 = { id: -1, name: '3', monitor: null, lastIpcObject: {} }
const orphan4 = { id: -1, name: '4', monitor: null, lastIpcObject: {} }
function buildWithOrphans(descriptors, items = [], locations = []) {
  return WorkspaceModel.buildWorkspacePresentation(items, locations, descriptors, {
    monitorScope: 'all', monitor: 'id:0', activeWorkspace: 'id:1', monitors,
    groupWindows: true
  })
}
const withoutGhosts = buildWithOrphans([orphan3, orphan4])
assert.ok(!withoutGhosts.groups.some(g => ['name:3', 'name:4'].includes(g.identity)),
  'uninitialized orphan descriptors cannot create empty workspace cards')
assert.ok(!withoutGhosts.monitorGroups.some(g => !g.identity),
  'orphan descriptors cannot create a phantom monitor section')

const initializingWindow = { appId: 'initializing' }
const initializing = buildWithOrphans([orphan3], [app('initializing', initializingWindow)],
  [record(initializingWindow, 'name:3', '')])
assert.equal(initializing.groups.find(g => g.identity === 'name:3')?.count, 1,
  'a real window remains reachable while its workspace is uninitialized')
assert.ok(initializing.monitorGroups.some(g => !g.identity),
  'legitimate unresolved window ownership remains visible')

const knownWindow = buildWithOrphans([orphan3], [app('initializing', initializingWindow)],
  [record(initializingWindow, 'name:3', 'id:0')])
assert.equal(knownWindow.groups.find(g => g.identity === 'name:3')?.monitorIdentity, 'id:0',
  'a placeholder is not authoritative evidence against a known live owner')

const initializingNumbered = buildWithOrphans([
  { id: 8, name: '8', monitor: null, lastIpcObject: {} }
])
assert.ok(initializingNumbered.groups.some(g => g.identity === 'id:8'),
  'new workspaces with a valid ID remain visible before hydration')
const initializingNamed = buildWithOrphans([
  { id: -1, name: 'Design', monitor: left, lastIpcObject: {} }
])
assert.equal(initializingNamed.groups.find(g => g.identity === 'name:Design')?.monitorIdentity, 'id:0',
  'named workspaces with a known native monitor remain visible')
const hydratedNamed = buildWithOrphans([
  { id: -5, name: 'Design', monitor: null,
    lastIpcObject: { id: -5, name: 'Design', monitorID: 0 } }
])
assert.equal(hydratedNamed.groups.find(g => g.identity === 'name:Design')?.monitorIdentity, 'id:0',
  'hydrated named empty workspaces remain visible')

assert.equal(DockWindowModel.shouldRefreshWindowScope('changeworkspaceid'), true,
  'automatic workspace renumbering must refresh cached locations')

const renumbered = { id: 2, name: '2', monitor: left,
  lastIpcObject: { id: 3, name: '3', monitorID: 0 } }
assert.equal(DockWindowModel.workspaceIdentity(renumbered), 'id:2',
  'native workspace ID takes precedence over the older IPC snapshot after renumbering')
const afterRenumber = buildWithOrphans([renumbered])
assert.equal(afterRenumber.groups.find(g => g.identity === 'id:2')?.label, '2',
  'workspace label also follows the native rename')
assert.equal(DockWindowModel.workspaceIdentity({ id: -5, name: 'New name',
  lastIpcObject: { id: -5, name: 'Old name' } }), 'name:New name')
assert.equal(DockWindowModel.workspaceIdentity({ id: 2, name: '2',
  lastIpcObject: { id: -7, name: 'special:old' } }), 'id:2')

const capturedCache = JSON.parse(fs.readFileSync(
  new URL('./fixtures/ghost-workspace-cache.json', import.meta.url), 'utf8'))
const capturedPresentation = WorkspaceModel.buildWorkspacePresentation([], [],
  capturedCache.workspaces.map(w => ({ ...w, lastIpcObject: w.ipc,
    monitor: capturedCache.monitors.find(m => m.name === w.monitor) || null })), {
    monitorScope: 'all', monitor: 'id:1', activeWorkspace: 'id:2',
    monitors: capturedCache.monitors.map(m => ({ ...m, lastIpcObject: m.ipc }))
  })
assert.deepEqual(Array.from(capturedPresentation.groups, g => g.identity).sort(),
  ['id:1', 'id:11', 'id:2', 'id:99'],
  'the captured live cache renders only the four real workspaces')
assert.equal(capturedPresentation.monitorGroups.length, 2,
  'the captured live cache renders exactly two real monitor sections')

// Quickshell early-init placeholder aliases the real numbered workspace 11.
const placeholder11 = { id: -1, name: '11', monitor: left, lastIpcObject: {} }
const real11 = { id: 11, name: '11', monitor: left,
  lastIpcObject: { id: 11, name: '11', monitorID: 0 } }
const aliasWindowA = { appId: 'alias-a' }
const aliasWindowB = { appId: 'alias-b' }
const aliased = WorkspaceModel.buildWorkspacePresentation(
  [app('alias-a', aliasWindowA), app('alias-b', aliasWindowB)],
  [record(aliasWindowA, DockWindowModel.workspaceIdentity(placeholder11), 'id:0'),
    record(aliasWindowB, DockWindowModel.workspaceIdentity(real11), 'id:0')],
  [placeholder11, real11], {
    monitorScope: 'all', monitor: 'id:0', activeWorkspace: 'id:1',
    monitors, groupWindows: true
  })
const aliasGroups = aliased.groups.filter(g => g.label === '11' || g.identity === 'id:11')
assert.equal(aliasGroups.length, 1, 'placeholder and real workspace 11 collapse to one section')
assert.equal(aliasGroups[0].identity, 'id:11')
assert.equal(aliasGroups[0].count, 2, 'both windows stay in the collapsed workspace 11 section')

const aliasEmpty = WorkspaceModel.buildWorkspacePresentation([], [], [placeholder11], {
  monitorScope: 'all', monitor: 'id:0', activeWorkspace: 'id:1',
  monitors, groupWindows: true
})
assert.ok(!aliasEmpty.groups.some(g => ['id:11', 'name:11'].includes(g.identity)),
  'empty numbered placeholder does not create a workspace 11 section')
assert.equal(DockWindowModel.workspaceIdentity({ id: -1, name: '11', lastIpcObject: {} }), 'id:11')
assert.equal(DockWindowModel.workspaceIdentity({ id: -1, name: 'Design', lastIpcObject: {} }),
  'name:Design')

console.log('workspace monitor model: PASS')
