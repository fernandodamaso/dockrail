import assert from 'node:assert/strict'
import { loadModel, plain } from './host_harness.mjs'
import { sidebarFixture } from './sidebar_fixture.mjs'

const Sidebar = loadModel('DockSidebarModel')
const desktopModel = loadModel('DockDesktopModel')

function claudeServer(extra) {
  return Object.assign({
    id: 'claude:local',
    source: 'claude',
    product: 'Claude',
    transport: 'local',
    host: 'local',
    sessions: [],
    session: '',
    label: 'Claude',
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

function claudeAgent(sid, status, desktopSessionId) {
  return {
    id: 'claude:local:1:' + sid,
    serverId: 'claude:local',
    connectionGeneration: 1,
    transport: 'local',
    host: 'local',
    session: '',
    paneId: sid,
    status: status || 'working',
    live: true,
    workspaceId: '',
    workspaceLabel: '',
    tabId: '',
    tabTitle: '',
    title: 'dockrail',
    agent: 'claude',
    desktopSessionId: desktopSessionId === undefined ? 'local_' + sid : desktopSessionId,
    stateChangeSeq: '1',
  }
}

function herdrAgent(pane, status) {
  return {
    id: 'local-h:1:' + pane,
    serverId: 'local-h',
    connectionGeneration: 1,
    transport: 'local',
    host: 'local',
    session: 'default',
    paneId: pane,
    status: status || 'working',
    live: true,
    workspaceId: 'w1',
    workspaceLabel: 'Herdr workspace',
    tabId: 't1',
    tabTitle: 'Tab',
    title: 'herdr-' + pane,
    agent: 'codex',
    stateChangeSeq: '1',
  }
}

function mergedSnapshot(servers, agents, extra) {
  return Object.assign({
    schemaVersion: 1,
    providerEpoch: 'herdr=e1|claude=e2',
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

function projectWithAssociations(desktop, f, byWindowKey, snapshot, verifiedSources) {
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
    herdrAssociations: { byWindowKey, unmatchedServerIds: [] },
    herdrAssociationsVerified: true,
    herdrVerifiedSources: verifiedSources,
  }))
}

function projectWith(desktop, f, windowKey, snapshot, serverId, verifiedSources) {
  return projectWithAssociations(desktop, f, { [windowKey]: serverId }, snapshot, verifiedSources)
}

function windowKeyFor(f, toplevelId) {
  const registry = Sidebar.reconcileHandles({ nextToken: 1, entries: [] }, f.toplevels)
  const entry = registry.entries.find((_, i) => f.toplevels[i].id === toplevelId)
  assert.ok(entry)
  return entry.key
}

// Verified Claude sessions nest under the Claude Desktop window row.
{
  const f = sidebarFixture()
  const desktop = desktopModel.build(f.input)
  const key = windowKeyFor(f, 'terminal')
  const snapshot = mergedSnapshot(
    [claudeServer(), herdrServer()],
    [claudeAgent('s1', 'working'), claudeAgent('s2', 'blocked')])
  const projected = projectWith(desktop, f, key, snapshot, 'claude:local',
    { herdr: false, t3: false, t3Present: false, claude: true, claudePresent: true })
  const parent = projected.rows.find(row => row.key === key)
  assert.ok(parent)
  assert.equal(parent.herdrAssociated, true)
  assert.equal(parent.herdrDisplayLabel, 'Claude')
  assert.equal(parent.herdrStatusCounts.working, 1)
  assert.equal(parent.herdrStatusCounts.blocked, 1)
  const nested = projected.rows.filter(row =>
    row.windowKey === key && row.kind === 'herdr-agent')
  assert.equal(nested.length, 2)
  assert.ok(nested.every(row => row.treeDepth === parent.treeDepth + 1))
  assert.ok(nested.every(row => row.title === 'dockrail'))
  // Claude sessions carry no workspace, so the synthetic group label stays out.
  nested.forEach(row => {
    assert.equal(row.subtitle, 'Claude')
    assert.equal(row.workspaceLabel, '')
  })
  assert.ok(nested.every(row => row.serverLabel === 'Claude'))
  assert.ok(nested.every(row => row.actionable === true))
  assert.ok(nested.every(row => row.focusAgentSupported === true))
  assert.deepEqual(nested.map(row => row.paneId).sort(), ['s1', 's2'])
  const states = projected.rows.filter(row =>
    row.windowKey === key && row.kind === 'herdr-state')
  assert.equal(states.length, 0)
}

// Sessions without a known desktopSessionId still raise the verified window.
{
  const f = sidebarFixture()
  const desktop = desktopModel.build(f.input)
  const key = windowKeyFor(f, 'terminal')
  const snapshot = mergedSnapshot([claudeServer()], [claudeAgent('s1', 'working', '')])
  const projected = projectWith(desktop, f, key, snapshot, 'claude:local',
    { herdr: false, t3: false, t3Present: false, claude: true, claudePresent: true })
  const nested = projected.rows.filter(row =>
    row.windowKey === key && row.kind === 'herdr-agent')
  assert.equal(nested.length, 1)
  assert.equal(nested[0].actionable, true)
  assert.equal(nested[0].focusAgentSupported, true)
}

// A Claude server without the focusAgent capability keeps session rows read-only.
{
  const f = sidebarFixture()
  const desktop = desktopModel.build(f.input)
  const key = windowKeyFor(f, 'terminal')
  const snapshot = mergedSnapshot(
    [claudeServer({ capabilities: { focusAgent: false } })], [claudeAgent('s1', 'working')])
  const projected = projectWith(desktop, f, key, snapshot, 'claude:local',
    { herdr: false, t3: false, t3Present: false, claude: true, claudePresent: true })
  const nested = projected.rows.filter(row =>
    row.windowKey === key && row.kind === 'herdr-agent')
  assert.equal(nested.length, 1)
  assert.equal(nested[0].actionable, false)
  assert.equal(nested[0].focusAgentSupported, false)
}

// A session whose connectionGeneration disagrees with its server is not actionable.
{
  const f = sidebarFixture()
  const desktop = desktopModel.build(f.input)
  const key = windowKeyFor(f, 'terminal')
  const snapshot = mergedSnapshot(
    [claudeServer({ connectionGeneration: 2 })], [claudeAgent('s1', 'working')])
  const projected = projectWith(desktop, f, key, snapshot, 'claude:local',
    { herdr: false, t3: false, t3Present: false, claude: true, claudePresent: true })
  const nested = projected.rows.filter(row =>
    row.windowKey === key && row.kind === 'herdr-agent')
  assert.equal(nested.length, 1)
  assert.equal(nested[0].actionable, false)
  assert.equal(nested[0].focusAgentSupported, true)
}

// Setting off (claudePresent false) unassociates the Claude window entirely.
{
  const f = sidebarFixture()
  const desktop = desktopModel.build(f.input)
  const key = windowKeyFor(f, 'terminal')
  const snapshot = mergedSnapshot([claudeServer()], [claudeAgent('s1', 'working')])
  const projected = projectWith(desktop, f, key, snapshot, 'claude:local',
    { herdr: false, t3: false, t3Present: false, claude: false, claudePresent: false })
  const parent = projected.rows.find(row => row.key === key)
  assert.ok(parent)
  assert.equal(parent.herdrAssociated, false)
  assert.ok(!projected.rows.some(row => row.windowKey === key
    && (row.kind === 'herdr-agent' || row.kind === 'herdr-state')))
}

// Legacy callers without verifiedSources never associate Claude windows.
{
  const f = sidebarFixture()
  const desktop = desktopModel.build(f.input)
  const key = windowKeyFor(f, 'terminal')
  const snapshot = mergedSnapshot([claudeServer()], [claudeAgent('s1', 'working')])
  const projected = projectWith(desktop, f, key, snapshot, 'claude:local', undefined)
  const parent = projected.rows.find(row => row.key === key)
  assert.ok(parent)
  assert.equal(parent.herdrAssociated, false)
  assert.ok(!projected.rows.some(row => row.windowKey === key
    && (row.kind === 'herdr-agent' || row.kind === 'herdr-state')))
}

// Setting on but unverified shows the pending child, never session rows.
{
  const f = sidebarFixture()
  const desktop = desktopModel.build(f.input)
  const key = windowKeyFor(f, 'terminal')
  const snapshot = mergedSnapshot([claudeServer()], [claudeAgent('s1', 'working')])
  const projected = projectWith(desktop, f, key, snapshot, 'claude:local',
    { herdr: false, t3: false, t3Present: false, claude: false, claudePresent: true })
  const parent = projected.rows.find(row => row.key === key)
  assert.ok(parent)
  assert.equal(parent.herdrAssociated, true)
  assert.equal(parent.herdrDisplayLabel, 'Claude')
  const agents = projected.rows.filter(row =>
    row.windowKey === key && row.kind === 'herdr-agent')
  assert.equal(agents.length, 0)
  const states = projected.rows.filter(row =>
    row.windowKey === key && row.kind === 'herdr-state')
  assert.equal(states.length, 1)
  assert.equal(states[0].title, 'Claude unavailable')
  assert.equal(states[0].actionable, false)
}

// A null snapshot keeps the Claude label and pending child.
{
  const f = sidebarFixture()
  const desktop = desktopModel.build(f.input)
  const key = windowKeyFor(f, 'terminal')
  const projected = projectWith(desktop, f, key, null, 'claude:local',
    { herdr: false, t3: false, t3Present: false, claude: false, claudePresent: true })
  const parent = projected.rows.find(row => row.key === key)
  assert.ok(parent)
  assert.equal(parent.herdrDisplayLabel, 'Claude')
  const states = projected.rows.filter(row =>
    row.windowKey === key && row.kind === 'herdr-state')
  assert.equal(states.length, 1)
  assert.equal(states[0].title, 'Claude unavailable')
  assert.equal(states[0].actionable, false)
}

// A verified snapshot omitting the Claude server keeps the Claude label, not Herdr.
{
  const f = sidebarFixture()
  const desktop = desktopModel.build(f.input)
  const key = windowKeyFor(f, 'terminal')
  const snapshot = mergedSnapshot([herdrServer()], [])
  const projected = projectWith(desktop, f, key, snapshot, 'claude:local',
    { herdr: false, t3: false, t3Present: false, claude: true, claudePresent: true })
  const parent = projected.rows.find(row => row.key === key)
  assert.ok(parent)
  assert.equal(parent.herdrDisplayLabel, 'Claude')
  const agents = projected.rows.filter(row =>
    row.windowKey === key && row.kind === 'herdr-agent')
  assert.equal(agents.length, 0)
  const states = projected.rows.filter(row =>
    row.windowKey === key && row.kind === 'herdr-state')
  assert.equal(states.length, 1)
  assert.equal(states[0].title, 'Claude unavailable')
}

// Herdr windows are unaffected by claudePresent in the same projection.
{
  const f = sidebarFixture()
  const desktop = desktopModel.build(f.input)
  const claudeKey = windowKeyFor(f, 'terminal')
  const herdrKey = windowKeyFor(f, 'c')
  const snapshot = mergedSnapshot(
    [claudeServer(), herdrServer()],
    [claudeAgent('s1', 'working'), herdrAgent('h1', 'blocked')])
  const byWindowKey = { [claudeKey]: 'claude:local', [herdrKey]: 'local-h' }
  const herdrRows = verifiedSources => {
    const projected = projectWithAssociations(desktop, f, byWindowKey, snapshot, verifiedSources)
    const parent = projected.rows.find(row => row.key === herdrKey)
    assert.ok(parent)
    assert.equal(parent.herdrAssociated, true)
    assert.equal(parent.herdrDisplayLabel, 'Herdr')
    const claudeParent = projected.rows.find(row => row.key === claudeKey)
    assert.ok(claudeParent)
    return {
      parent: [parent.herdrAssociated, parent.herdrDisplayLabel, parent.herdrStatusCounts],
      agents: projected.rows.filter(row => row.windowKey === herdrKey
        && row.kind === 'herdr-agent').map(row => row.paneId),
      claudeAssociated: claudeParent.herdrAssociated,
    }
  }
  const on = herdrRows({ herdr: true, t3: false, t3Present: false, claude: true, claudePresent: true })
  const off = herdrRows({ herdr: true, t3: false, t3Present: false, claude: false, claudePresent: false })
  assert.equal(on.claudeAssociated, true)
  assert.equal(off.claudeAssociated, false)
  assert.deepEqual(on.parent, off.parent)
  assert.deepEqual(on.agents, ['h1'])
  assert.deepEqual(off.agents, ['h1'])
}

console.log('test_claude_sidebar_model: all assertions passed')
