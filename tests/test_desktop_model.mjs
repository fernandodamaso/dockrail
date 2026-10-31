import assert from 'node:assert/strict'
import crypto from 'node:crypto'
import fs from 'node:fs'
import vm from 'node:vm'

const root = new URL('../', import.meta.url)
const read = path => fs.readFileSync(new URL(path, root), 'utf8')
const hash = value => crypto.createHash('sha256').update(value).digest('hex')
const plain = value => JSON.parse(JSON.stringify(value))
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
const imports = { DockModel, DockIconModel, DockWindowModel, WorkspaceModel, WorkspaceGroupModel }
const source = read('components/Dock.qml')
const method = (text, name) => {
  const match = text.match(new RegExp(`^  function ${name}\\([^]*?^  }`, 'm'))
  assert.ok(match, `actual Dock.${name} method exists`)
  return match[0]
}
const original = method(read('tests/fixtures/desktop-classic-refresh.js'), 'refreshVisibleItems')
const current = method(source, 'refreshVisibleItems')
const capture = process.argv.includes('--capture-baseline')
const baselineOnly = capture || process.argv.includes('--baseline')
if (baselineOnly) assert.equal(current, original, 'baseline must use the unmodified production path')
let DesktopModel
if (!baselineOnly) {
  assert.ok(fs.existsSync(new URL('components/DockDesktopModel.js', root)),
    'SB-01 requires the shared desktop builder (expected RED before extraction)')
  DesktopModel = load('DockDesktopModel', imports)
  assert.equal(typeof DesktopModel.build, 'function')
}

// Deliberately ordered differently from physical monitor position and focus.
// Every case uses real production helpers, with synthetic desktop snapshots only.
function fixture(options = {}) {
  const settings = {
    position: 'bottom', workspaceLayout: 'grouped', windowScope: 'all',
    workspaceMonitorScope: 'all', workspaceMonitorOrder: [], sortByWorkspace: false,
    showUrgentOutsideScope: true, groupWindows: false, windowIconOverrides: [],
    pinned: ['app.browser', 'app.closed', 'app.hidden'], hiddenApplications: ['app.hidden'],
    workspaceGroups: [{ desktopId: 'app.browser', workspace: 'id:1' }],
    autoHide: true, reserveSpace: false, showPreviews: true,
    clickAction: 'focus', scrollAction: 'cycle', magnification: 1.7,
    extensionData: { retained: ['not', 'a', 'migration'] }, ...options
  }
  const monitors = [
    { id: 0, name: 'DP-1', x: 1920, y: 0, focused: true, activeWorkspace: { id: 1 } },
    { id: 1, name: 'HDMI-A-1', x: 0, y: 0, focused: false, activeWorkspace: { id: 3 } }
  ]
  const toplevels = []
  const handles = []
  function window(id, appId, workspace, monitor, extras = {}) {
    const toplevel = { id, appId, title: `Window ${id}`, activated: id === 'a',
      ...extras.toplevel }
    toplevels.push(toplevel)
    if (extras.noHandle) return
    handles.push({ wayland: toplevel, address: extras.pending ? '' : `0x${id}`,
      lastIpcObject: { workspace, monitor, urgent: id === 'c', pinned: extras.sticky === true } })
  }
  window('a', 'app.browser', { id: 1 }, 0)
  window('b', 'app.browser', { id: 1 }, 0)
  window('c', 'app.browser', { id: 3 }, 1)
  window('d', 'app.editor', { name: 'design' }, 1)
  window('e', 'app.editor', { id: 2 }, 0, { sticky: true })
  window('f', 'app.browser', { name: 'special:smartdock-minimized' }, 1)
  window('aa', 'app.hidden', { id: 3 }, 1)
  window('ab', 'app.editor', { id: 6 }, 9) // unresolved owner
  window('ac', 'app.editor', { id: 7 }, 0) // conflicting native owner evidence
  window('ad', 'app.editor', { name: 'special:scratch' }, 1)
  window('ae', 'app.editor', { id: 3 }, 1, { pending: true })
  window('af', 'app.editor', { id: 3 }, 1, { pending: true })
  window('ba', 'app.unknown', null, null, { noHandle: true })
  window('bb', 'app.editor', { name: 'special:smartdock-minimized' }, 1) // missing origin
  const workspaces = [
    { id: 1, monitorID: 0 }, { id: 2, monitorID: 0 },
    { id: 3, monitorID: 1 }, { id: 4, monitorID: 1 }, // native empty
    { name: 'design', monitorID: 1 }, { id: 6, monitorID: 9 },
    { id: 7, monitorID: 0 }, { id: 7, monitorID: 1 }
  ]
  const origins = { '0xf': { workspace: '1', monitor: '0' } }
  return { settings, monitors, toplevels, handles, workspaces, origins }
}
function inputFor(f) {
  const s = f.settings
  const settings = { ...s,
    position: DockModel.normalizeSetting('position', s.position),
    sortByWorkspace: DockModel.normalizeSetting('sortByWorkspace', s.sortByWorkspace),
    workspaceMonitorScope: DockModel.normalizeSetting('workspaceMonitorScope', s.workspaceMonitorScope),
    workspaceMonitorOrder: DockModel.normalizeSetting('workspaceMonitorOrder', s.workspaceMonitorOrder),
    workspaceGroups: WorkspaceGroupModel.normalizeWorkspaceGroups(s.workspaceGroups),
    hiddenApplications: DockModel.normalizeSetting('hiddenApplications', s.hiddenApplications) }
  const grouped = !['left', 'right'].includes(settings.position)
    && DockModel.normalizeSetting('workspaceLayout', s.workspaceLayout) === 'grouped'
  const focusedWorkspace = DockWindowModel.focusedWorkspaceIdentity(f.monitors, null)
  const dockMonitor = f.monitors[s.dockIndex || 0]
  const filteredToplevels = DockWindowModel.filterToplevelsByScope(
    f.toplevels, f.handles, f.origins, DockWindowModel.windowScopeContext(
      s.windowScope, focusedWorkspace, dockMonitor, s.showUrgentOutsideScope))
  return { mode: grouped ? 'classic-grouped' : 'classic-flat', settings,
    applications: ['app.browser', 'app.closed', 'app.editor', 'app.hidden'].map(id =>
      ({ id, name: id, icon: id })),
    toplevels: f.toplevels, hyprToplevels: f.handles, hyprWorkspaces: f.workspaces,
    hyprMonitors: f.monitors, minimizedOrigins: f.origins, focusedWorkspace,
    dockMonitor, filteredToplevels }
}
function scopeFor(input, refresh) {
  const events = []
  const scope = vm.createContext({ ...imports, DesktopModel,
    ...input.settings, settings: input.settings,
    applications: input.applications, toplevels: input.toplevels,
    hyprToplevels: input.hyprToplevels, hyprWorkspaces: input.hyprWorkspaces,
    hyprMonitors: input.hyprMonitors, filteredToplevels: input.filteredToplevels,
    dockHyprMonitor: input.dockMonitor, focusedScopeWorkspace: input.focusedWorkspace,
    groupedRequested: input.mode === 'classic-grouped',
    windowActions: { minimizedOriginsSnapshot: input.minimizedOrigins },
    workspaceDragActive: false, workspacePresentationDirty: false, workspaceMonitorDrag: null,
    revealAfterWorkspaceDrag: false, screen: { name: input.dockMonitor?.name || '' },
    windowPreview: { dismissImmediately() { events.push(['dismiss']) } },
    badgeTracker: { syncWorkspaceScopes(owner, items) {
      events.push(['badges', owner, Array.from(items, item => item.presentationId)])
    } },
    Qt: { callLater(fn) { events.push(['callLater']); fn() } },
    revealActiveWorkspace() { events.push(['reveal']) }
  })
  scope.root = scope
  let visibleItems = []
  let workspacePresentation = { primaryWorkspaceIdentity: '', monitorGroups: [], groups: [],
    globalLaunchers: [], fallbackItems: [], renderedItems: [] }
  Object.defineProperty(scope, 'visibleItems', {
    get: () => visibleItems, set(value) { events.push(['flat']); visibleItems = value } })
  Object.defineProperty(scope, 'workspacePresentation', {
    get: () => workspacePresentation,
    set(value) { events.push(['workspace']); workspacePresentation = value } })
  vm.runInContext(refresh, scope)
  return { scope, events }
}
function output(scope) {
  // Classic characterization ignores newly attached catalog metadata so the
  // frozen behavioral baseline stays comparable; sidebar tests cover entry.
  return JSON.parse(JSON.stringify({
    visibleItems: scope.visibleItems,
    workspacePresentation: scope.workspacePresentation
  }, function(key, value) { return key === 'entry' ? undefined : value }))
}
const captures = []
let count = 0
function compareCase(name, f) {
  const input = inputFor(f)
  const before = JSON.stringify(input)
  const reference = scopeFor(input, original)
  const actual = scopeFor(input, current)
  reference.scope.revealAfterWorkspaceDrag = actual.scope.revealAfterWorkspaceDrag = true
  reference.scope.refreshVisibleItems()
  actual.scope.refreshVisibleItems()
  assert.deepEqual(output(actual.scope), output(reference.scope), `${name}: exact classic output`)
  assert.deepEqual(actual.events, reference.events, `${name}: badge/dismiss/assignment/reveal order`)
  captures.push([name, output(reference.scope), reference.events.slice()])
  if (DesktopModel) {
    const built = DesktopModel.build(input)
    assert.deepEqual(Object.keys(built).sort(), ['records', 'visibleItems', 'workspacePresentation'])
    assert.deepEqual(output({ visibleItems: built.visibleItems, workspacePresentation: null }),
      output({ visibleItems: reference.scope.visibleItems, workspacePresentation: null }),
      `${name}: flat result without entry noise`)
    assert.deepEqual(built.workspacePresentation == null ? null
      : output({ visibleItems: [], workspacePresentation: built.workspacePresentation }).workspacePresentation,
      input.mode === 'classic-grouped'
        ? output(reference.scope).workspacePresentation : null,
      `${name}: native workspace result without entry noise`)
    const members = input.mode === 'classic-grouped' ? input.toplevels : input.filteredToplevels
    assert.deepEqual(Array.from(built.records, record => record.toplevel), Array.from(members),
      `${name}: records retain original live handles, including pending addresses`)
    assert.deepEqual(plain(built.records), plain(members.map(toplevel => ({ toplevel,
      ...DockWindowModel.locationForToplevel(toplevel, input.hyprToplevels, input.minimizedOrigins) }))))
    for (const item of [...built.visibleItems, ...(built.workspacePresentation?.renderedItems || [])]) {
      for (const member of item.toplevels) assert.ok(input.toplevels.includes(member), 'never clone a live handle')
      if (!item.desktopId) continue
      const expected = DockModel.entryForAppId(item.desktopId, input.applications) || null
      assert.equal(item.entry || null, expected,
        `${name}: catalog entry attachment preserves classic member identity`)
    }
  }
  assert.equal(JSON.stringify(input), before, `${name}: settings/desktop snapshot are not mutated`)
  // A no-op refresh must retain both snapshots (including an inactive grouped snapshot).
  const previousItems = actual.scope.visibleItems
  const previousWorkspace = actual.scope.workspacePresentation
  reference.events.length = actual.events.length = 0
  reference.scope.refreshVisibleItems()
  actual.scope.refreshVisibleItems()
  assert.equal(actual.scope.visibleItems, previousItems, `${name}: flat equality guard`)
  assert.equal(actual.scope.workspacePresentation, previousWorkspace, `${name}: grouped equality guard`)
  assert.deepEqual(actual.events, reference.events, `${name}: equal refresh side effects`)
  // Read barriers make this fail if extraction slips above the drag-freeze return.
  actual.scope.workspaceDragActive = true
  actual.scope.workspacePresentationDirty = false
  Object.defineProperty(actual.scope, 'toplevels', { get() { throw Error('read during frozen drag') } })
  actual.events.length = 0
  actual.scope.refreshVisibleItems()
  assert.equal(actual.scope.workspacePresentationDirty, true)
  assert.deepEqual(actual.events, [], 'drag freeze performs no build/badge/preview action')
  count++
}
for (const position of ['top', 'bottom', 'left', 'right'])
  for (const workspaceLayout of ['flat', 'grouped'])
    for (const workspaceMonitorScope of ['all', 'current-monitor'])
      for (const windowScope of DockWindowModel.windowScopeValues())
        for (const sortByWorkspace of [false, true])
          for (const grouped of [false, true]) {
            const options = { position, workspaceLayout, workspaceMonitorScope, windowScope,
              sortByWorkspace, workspaceGroups: grouped
                ? [{ desktopId: 'app.browser', workspace: 'id:1' }] : [] }
            compareCase(JSON.stringify(options), fixture(options))
          }
for (const [name, options] of Object.entries({
  'explicit-monitor-order': { workspaceMonitorOrder: ['DP-1', 'HDMI-A-1'] },
  'second-dock': { dockIndex: 1, workspaceMonitorScope: 'current-monitor' },
  'inactive-legacy-grouping': { groupWindows: true, workspaceGroups: [] },
  'urgent-exception-off': { windowScope: 'workspace-monitor', showUrgentOutsideScope: false },
  'retained-classic-preferences': { autoHide: false, reserveSpace: true, showPreviews: false,
    magnification: 1, clickAction: 'minimize', scrollAction: 'none' }
})) compareCase(name, fixture(options))
const focused = fixture()
focused.monitors[0].focused = false
focused.monitors[1].focused = true
focused.toplevels[0].activated = false
focused.toplevels[2].activated = true
compareCase('focus-only-change', focused)
const empty = fixture()
empty.toplevels = []; empty.handles = []
compareCase('native-empty-with-closed-pins', empty)
const absent = fixture()
absent.monitors = []; absent.workspaces = []
compareCase('unresolved-topology', absent)

const digest = { base: '1a81fe650f686f1b8dfb10b25f5c0d1de6a4bab8',
  refreshSha256: hash(original), cases: count, outputsSha256: hash(JSON.stringify(captures)) }
const baselineUrl = new URL('tests/fixtures/desktop-classic-baseline.json', root)
if (capture) fs.writeFileSync(baselineUrl, JSON.stringify(digest, null, 2) + '\n')
else assert.deepEqual(digest, JSON.parse(fs.readFileSync(baselineUrl, 'utf8')),
  'frozen base outputs must not drift with changes to shared production helpers')

// Execute the real lifecycle bodies: moving model construction must not alter
// drag coalescing, reveal scheduling, mode teardown, or badge owner cleanup.
const events = []
const lifecycle = vm.createContext({
  workspaceDragActive: true, workspacePresentationDirty: false,
  fullscreenModeActive: true, liveWorkspaceFullscreenOwners: { 'id:1': 'owner' },
  workspaceDrag: { pointerScene: 'point', updatePointer(p) { events.push(['pointer', p]) } },
  visibleItemsRefreshTimer: { restart() { events.push(['restart']) }, stop() { events.push(['stop']) } },
  windowPreview: { dismissImmediately() { events.push(['dismiss']) } },
  cancelWorkspaceGesture(reason) { events.push(['cancel', reason]) },
  cancelGroupedPinReorder() {},
  workspaceMonitorDrag: { unregisterDock() { events.push(['unregister']) } },
  badgeTracker: { syncWorkspaceScopes(owner, items) { events.push(['badges', owner, plain(items)]) } },
  screen: { name: 'DP-1' }, grouped: false
})
lifecycle.root = lifecycle
for (const name of ['scheduleVisibleItemsRefresh', 'prepareWorkspacePresentation', 'finishWorkspacePresentation'])
  vm.runInContext(method(source, name), lifecycle)
lifecycle.scheduleVisibleItemsRefresh()
assert.equal(lifecycle.workspacePresentationDirty, true)
assert.deepEqual(events.splice(0), [['pointer', 'point']])
lifecycle.workspaceDragActive = false
lifecycle.scheduleVisibleItemsRefresh()
assert.deepEqual(events.splice(0), [['restart']])
lifecycle.prepareWorkspacePresentation()
assert.equal(lifecycle.dragFullscreenModeActive, true)
assert.equal(lifecycle.dragWorkspaceFullscreenOwners, lifecycle.liveWorkspaceFullscreenOwners)
assert.deepEqual(events.splice(0), [['stop'], ['dismiss']])
lifecycle.finishWorkspacePresentation()
assert.equal(lifecycle.workspacePresentationDirty, false)
assert.equal(lifecycle.revealAfterWorkspaceDrag, true)
assert.deepEqual(events.splice(0), [['restart']])
for (const [handler, expected] of [
  ['onGroupedChanged', [['cancel', 'layout changed'], ['dismiss'], ['badges', 'DP-1', []]]],
  ['Component.onDestruction', [['cancel', 'surface destroyed'], ['unregister'], ['badges', 'DP-1', []]]]
]) {
  const block = source.match(new RegExp(`^  ${handler.replace('.', '\\.')}: \\{([^]*?)^  }`, 'm'))
  assert.ok(block)
  vm.runInContext(block[1], lifecycle)
  assert.deepEqual(events.splice(0), expected, handler)
}
console.log(`SB-01 desktop characterization: PASS (${count} baseline cases; identity, purity, lifecycle)`)
