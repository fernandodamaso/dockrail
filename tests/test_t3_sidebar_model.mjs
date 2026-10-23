import assert from 'node:assert/strict'
import { loadModel, plain } from './host_harness.mjs'
import { sidebarFixture } from './sidebar_fixture.mjs'

const Sidebar = loadModel('DockSidebarModel')
const desktopModel = loadModel('DockDesktopModel')

function t3Server(extra) {
  return Object.assign({
    id: 't3:env-1',
    source: 't3',
    product: 'T3 Code',
    transport: 'local',
    host: 'local',
    sessions: [],
    session: '',
    label: 'T3 Code',
    capabilities: { focusAgent: true },
    connectionGeneration: 1,
    health: 'live',
    connected: true,
    clients: [],
  }, extra || {})
}

function herdrServer(extra) {
  return Object.assign({
    id: 'local-h',
    transport: 'local',
    host: 'local',
    session: 'default',
    label: 'Local Herdr',
    capabilities: { focusAgent: true },
    connectionGeneration: 1,
    health: 'live',
    connected: true,
    clients: [],
  }, extra || {})
}

function t3Agent(pane, status) {
  return {
    id: 't3:env-1:1:' + pane,
    serverId: 't3:env-1',
    connectionGeneration: 1,
    transport: 'local',
    host: 'local',
    session: '',
    paneId: pane,
    status: status || 'working',
    live: true,
    workspaceId: 'p1',
    workspaceLabel: 'Example project',
    tabId: 'p1',
    tabTitle: 'Example project',
    title: 'Thread ' + pane,
    agent: 'codex',
    stateChangeSeq: '1',
    observedAgeMs: 0,
  }
}

function mergedSnapshot(servers, agents, extra) {
  return Object.assign({
    schemaVersion: 1,
    providerEpoch: 'herdr=e1|t3=e2',
    revision: 3,
    capabilities: { focusAgent: true },
    servers,
    agents: agents || [],
    attention: [],
    liveCounts: { blocked: 0, working: (agents || []).length },
    completeness: { state: 'complete', truncated: false },
    windowProcesses: { revision: 1, identities: [] },
  }, extra || {})
}

function projectWith(desktop, f, windowKey, snapshot, serverId, verifiedSources) {
  return plain(Sidebar.project({
    desktop,
    screens: f.screens,
    monitors: f.monitors,
    monitorOrder: [],
    pinned: f.settings.pinned,
    hiddenApplications: f.settings.hiddenApplications,
    registry: Sidebar.reconcileHandles({ nextToken: 1, entries: [] }, f.toplevels),
    folds: ({}),
    collapsed: false,
    herdrSnapshot: snapshot,
    herdrAssociations: { byWindowKey: { [windowKey]: serverId }, unmatchedServerIds: [] },
    herdrAssociationsVerified: true,
    herdrVerifiedSources: verifiedSources,
  }))
}

function windowKeyFor(f, toplevelId) {
  const registry = Sidebar.reconcileHandles({ nextToken: 1, entries: [] }, f.toplevels)
  const entry = registry.entries.find((_, i) => f.toplevels[i].id === toplevelId)
  assert.ok(entry)
  return entry.key
}

// T3 threads nest under the T3 Code window row.
{
  const f = sidebarFixture()
  const desktop = desktopModel.build(f.input)
  const key = windowKeyFor(f, 'terminal')
  const snapshot = mergedSnapshot(
    [t3Server(), herdrServer()],
    [t3Agent('thread-1', 'working'), t3Agent('thread-2', 'blocked')])
  const projected = projectWith(desktop, f, key, snapshot, 't3:env-1',
    { herdr: true, t3: true, t3Present: true })
  const parent = projected.rows.find(row => row.key === key)
  assert.ok(parent)
  assert.equal(parent.herdrAssociated, true)
  assert.equal(parent.herdrDisplayLabel, 'T3 Code')
  const nested = projected.rows.filter(row =>
    row.windowKey === key && row.kind === 'herdr-agent')
  assert.equal(nested.length, 2)
  assert.ok(nested.every(row => row.treeDepth === parent.treeDepth + 1))
  assert.ok(nested.every(row => row.actionable === true))
  assert.deepEqual(nested.map(row => row.paneId).sort(), ['thread-1', 'thread-2'])
}

// Unverified T3 shows the pending child, never thread rows.
{
  const f = sidebarFixture()
  const desktop = desktopModel.build(f.input)
  const key = windowKeyFor(f, 'terminal')
  const snapshot = mergedSnapshot([t3Server()], [t3Agent('thread-1', 'working')])
  const projected = projectWith(desktop, f, key, snapshot, 't3:env-1',
    { herdr: true, t3: false, t3Present: true })
  const parent = projected.rows.find(row => row.key === key)
  assert.ok(parent)
  assert.equal(parent.herdrDisplayLabel, 'T3 Code')
  const agents = projected.rows.filter(row =>
    row.windowKey === key && row.kind === 'herdr-agent')
  assert.equal(agents.length, 0)
  const states = projected.rows.filter(row =>
    row.windowKey === key && row.kind === 'herdr-state')
  assert.equal(states.length, 1)
  assert.equal(states[0].title, 'T3 Code unavailable')
}

// Removed T3 widget unassociates the window entirely.
{
  const f = sidebarFixture()
  const desktop = desktopModel.build(f.input)
  const key = windowKeyFor(f, 'terminal')
  const snapshot = mergedSnapshot([t3Server()], [t3Agent('thread-1', 'working')])
  const projected = projectWith(desktop, f, key, snapshot, 't3:env-1',
    { herdr: true, t3: false, t3Present: false })
  const parent = projected.rows.find(row => row.key === key)
  assert.ok(parent)
  assert.equal(parent.herdrAssociated, false)
  assert.ok(!projected.rows.some(row => row.windowKey === key
    && (row.kind === 'herdr-agent' || row.kind === 'herdr-state')))
}

// Herdr windows keep label and pending child when Herdr is unverified.
{
  const f = sidebarFixture()
  const desktop = desktopModel.build(f.input)
  const t3key = windowKeyFor(f, 'terminal')
  const hkey = windowKeyFor(f, 'c')
  const snapshot = mergedSnapshot(
    [t3Server(), herdrServer()],
    [t3Agent('thread-1', 'working')])
  const associations = { byWindowKey: { [t3key]: 't3:env-1', [hkey]: 'local-h' },
    unmatchedServerIds: [] }
  const projected = plain(Sidebar.project({
    desktop,
    screens: f.screens,
    monitors: f.monitors,
    monitorOrder: [],
    pinned: f.settings.pinned,
    hiddenApplications: f.settings.hiddenApplications,
    registry: Sidebar.reconcileHandles({ nextToken: 1, entries: [] }, f.toplevels),
    folds: ({}),
    collapsed: false,
    herdrSnapshot: snapshot,
    herdrAssociations: associations,
    herdrAssociationsVerified: false,
    herdrVerifiedSources: { herdr: false, t3: true, t3Present: true },
  }))
  const hparent = projected.rows.find(row => row.key === hkey)
  assert.ok(hparent)
  assert.equal(hparent.herdrDisplayLabel, 'Herdr')
  const hstates = projected.rows.filter(row =>
    row.windowKey === hkey && row.kind === 'herdr-state')
  assert.equal(hstates.length, 1)
  assert.equal(hstates[0].title, 'Herdr unavailable')
  const t3agents = projected.rows.filter(row =>
    row.windowKey === t3key && row.kind === 'herdr-agent')
  assert.equal(t3agents.length, 1)
}

// State titles and per-source partial inventory.
{
  const f = sidebarFixture()
  const desktop = desktopModel.build(f.input)
  const key = windowKeyFor(f, 'terminal')
  const snapshot = mergedSnapshot([t3Server()], [])
  const projected = projectWith(desktop, f, key, snapshot, 't3:env-1',
    { herdr: true, t3: true, t3Present: true })
  const states = projected.rows.filter(row =>
    row.windowKey === key && row.kind === 'herdr-state')
  assert.equal(states.length, 1)
  assert.equal(states[0].title, 'No active threads')

  const truncated = mergedSnapshot(
    [t3Server({ sourceCompleteness: { state: 'partial', truncated: true },
      sourceLiveCountsKnown: true }), herdrServer()], [])
  const both = plain(Sidebar.project({
    desktop,
    screens: f.screens,
    monitors: f.monitors,
    monitorOrder: [],
    pinned: f.settings.pinned,
    hiddenApplications: f.settings.hiddenApplications,
    registry: Sidebar.reconcileHandles({ nextToken: 1, entries: [] }, f.toplevels),
    folds: ({}),
    collapsed: false,
    herdrSnapshot: truncated,
    herdrAssociations: { byWindowKey: { [key]: 't3:env-1',
      [windowKeyFor(f, 'c')]: 'local-h' }, unmatchedServerIds: [] },
    herdrAssociationsVerified: true,
    herdrVerifiedSources: { herdr: true, t3: true, t3Present: true },
  }))
  const t3states = both.rows.filter(row =>
    row.windowKey === key && row.kind === 'herdr-state')
  assert.equal(t3states[0].title, 'Partial inventory')
  const hstates = both.rows.filter(row =>
    row.windowKey === windowKeyFor(f, 'c') && row.kind === 'herdr-state')
  assert.equal(hstates[0].title, 'No active agents')
}

// Pairing hints own the copy for auth-error servers.
{
  assert.equal(Sidebar.t3PairingHint(t3Server({ errorCode: 'pairing_required' })),
    'Pair T3 Code: run `dockrail t3 pair`')
  assert.equal(Sidebar.t3PairingHint(t3Server({ errorCode: 'pairing_expired' })),
    'T3 Code pairing expired: run `dockrail t3 pair`')
  assert.equal(Sidebar.t3PairingHint(t3Server({ errorCode: 'authentication_required' })),
    'T3 Code pairing expired: run `dockrail t3 pair`')
  assert.equal(Sidebar.t3PairingHint(t3Server({ errorCode: 'server_not_running' })), '')
  assert.equal(Sidebar.t3PairingHint(herdrServer({ errorCode: 'pairing_required' })), '')
  assert.equal(Sidebar.t3PairingHint(null), '')
  assert.equal(
    Sidebar.herdrStateTitle(t3Server({ health: 'unavailable', errorCode: 'pairing_required' }),
      mergedSnapshot([], [])),
    'Pair T3 Code: run `dockrail t3 pair`')
}

// Retained T3 parent without a snapshot keeps label and pending child.
{
  const f = sidebarFixture()
  const desktop = desktopModel.build(f.input)
  const key = windowKeyFor(f, 'terminal')
  const projected = projectWith(desktop, f, key, null, 't3:env-1',
    { herdr: true, t3: true, t3Present: true })
  const parent = projected.rows.find(row => row.key === key)
  assert.ok(parent)
  assert.equal(parent.herdrDisplayLabel, 'T3 Code')
  const agents = projected.rows.filter(row =>
    row.windowKey === key && row.kind === 'herdr-agent')
  assert.equal(agents.length, 0)
  const states = projected.rows.filter(row =>
    row.windowKey === key && row.kind === 'herdr-state')
  assert.equal(states.length, 1)
  assert.equal(states[0].title, 'T3 Code unavailable')
  assert.equal(states[0].actionable, false)
}

// Removed T3 widget without a snapshot unassociates; Herdr parent is retained.
{
  const f = sidebarFixture()
  const desktop = desktopModel.build(f.input)
  const key = windowKeyFor(f, 'terminal')
  const hkey = windowKeyFor(f, 'c')
  const projected = plain(Sidebar.project({
    desktop,
    screens: f.screens,
    monitors: f.monitors,
    monitorOrder: [],
    pinned: f.settings.pinned,
    hiddenApplications: f.settings.hiddenApplications,
    registry: Sidebar.reconcileHandles({ nextToken: 1, entries: [] }, f.toplevels),
    folds: ({}),
    collapsed: false,
    herdrSnapshot: null,
    herdrAssociations: { byWindowKey: { [key]: 't3:env-1', [hkey]: 'local-h' },
      unmatchedServerIds: [] },
    herdrAssociationsVerified: false,
    herdrVerifiedSources: { herdr: false, t3: false, t3Present: false },
  }))
  const parent = projected.rows.find(row => row.key === key)
  assert.ok(parent)
  assert.equal(parent.herdrAssociated, false)
  const hparent = projected.rows.find(row => row.key === hkey)
  assert.ok(hparent)
  assert.equal(hparent.herdrDisplayLabel, 'Herdr')
  const hstates = projected.rows.filter(row =>
    row.windowKey === hkey && row.kind === 'herdr-state')
  assert.equal(hstates.length, 1)
  assert.equal(hstates[0].title, 'Herdr unavailable')
}

// Non-null snapshot omitting the retained T3 server shows pending, not rows.
{
  const f = sidebarFixture()
  const desktop = desktopModel.build(f.input)
  const key = windowKeyFor(f, 'terminal')
  const snapshot = mergedSnapshot([herdrServer()], [])
  const projected = projectWith(desktop, f, key, snapshot, 't3:env-1',
    { herdr: true, t3: true, t3Present: true })
  const parent = projected.rows.find(row => row.key === key)
  assert.ok(parent)
  assert.equal(parent.herdrDisplayLabel, 'T3 Code')
  const agents = projected.rows.filter(row =>
    row.windowKey === key && row.kind === 'herdr-agent')
  assert.equal(agents.length, 0)
  const states = projected.rows.filter(row =>
    row.windowKey === key && row.kind === 'herdr-state')
  assert.equal(states.length, 1)
  assert.equal(states[0].title, 'T3 Code unavailable')
}

console.log('test_t3_sidebar_model: all assertions passed')
