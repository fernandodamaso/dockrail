import assert from 'node:assert/strict'
import { loadModel, plain } from './host_harness.mjs'
import { qmlMethods } from './sidebar_interaction_fixture.mjs'
import { sidebarFixture } from './sidebar_fixture.mjs'

const Herdr = loadModel('DockHerdrModel')
const Sidebar = loadModel('DockSidebarModel')
const Desktop = loadModel('DockDesktopModel')
const UPGRADE = 'Update Herdr to 0.9.1+ to jump to agents'

function server(version, id = 'srv') {
  const value = {
    id, transport: 'local', host: 'local', session: 'default', label: 'Herdr',
    health: 'live', connected: true, connectionGeneration: 7,
    capabilities: { focusAgent: true },
  }
  if (version !== undefined) value.version = version
  return value
}

for (const version of ['0.8.2', '0.9.0', '0.9.1-rc.1']) {
  const value = server(version)
  assert.equal(Herdr.serverNeedsFocusUpgrade(value), true, version)
  assert.equal(Herdr.serverFocusAgentSupported(value), false, version)
  assert.equal(Herdr.serverFocusUpgradeMessage(value), UPGRADE, version)
}
for (const version of ['0.9.1', '0.9.2', '1.0.0', '0.9.1+omarchy']) {
  const value = server(version)
  assert.equal(Herdr.serverNeedsFocusUpgrade(value), false, version)
  assert.equal(Herdr.serverFocusAgentSupported(value), true, version)
  assert.equal(Herdr.serverFocusUpgradeMessage(value), '', version)
}
for (const version of [undefined, '', 'development', 9]) {
  const value = server(version)
  assert.equal(Herdr.serverNeedsFocusUpgrade(value), false, String(version))
  assert.equal(Herdr.serverFocusAgentSupported(value), true, String(version))
  assert.equal(Herdr.serverFocusUpgradeMessage(value), '', String(version))
}
const disconnectedOld = server('0.8.9')
disconnectedOld.connected = false
assert.equal(Herdr.serverNeedsFocusUpgrade(disconnectedOld), false)
assert.equal(Herdr.serverFocusUpgradeMessage(disconnectedOld), '')

{
  const servers = [
    server('0.9.0', 'old'),
    server('0.9.1', 'new'),
    server(undefined, 'unknown'),
  ]
  const snapshot = {
    servers, agents: [],
    liveCounts: { agents: 0, complete: true },
    completeness: { state: 'complete' },
  }
  const view = qmlMethods('DockHerdrAgentsView.qml', {
    HerdrModel: Herdr, SidebarModel: Sidebar, servers, agents: [], snapshot,
  })
  const rows = plain(view.buildRows())
  assert.deepEqual(rows.filter(row => row.kind === 'notice').map(row => row.title), [UPGRADE])
  const sessions = Object.fromEntries(rows.filter(row => row.kind === 'session')
    .map(row => [row.key, row]))
  assert.equal(sessions['server:old'].focusAgentSupported, false)
  assert.equal(sessions['server:new'].focusAgentSupported, true)
  assert.equal(sessions['server:unknown'].focusAgentSupported, true)
}

function matched(version) {
  const fixture = sidebarFixture()
  const desktop = Desktop.build(fixture.input)
  const registry = Sidebar.reconcileHandles({ nextToken: 1, entries: [] }, fixture.toplevels)
  const entry = registry.entries.find((_, i) => fixture.toplevels[i].id === 'terminal')
  assert.ok(entry)
  const srv = server(version)
  const agent = {
    id: 'srv:7:pane-a', serverId: 'srv', connectionGeneration: 7,
    paneId: 'pane-a', terminalId: 'term-a', workspaceId: 'w',
    workspaceLabel: 'Project', tabId: 'tab', tabTitle: 'Tab',
    title: 'Agent A', agent: 'codex', status: 'working', live: true,
  }
  const snapshot = {
    providerEpoch: 'epoch-version', revision: 1, servers: [srv], agents: [agent],
    liveCounts: { agents: 1, complete: true },
    completeness: { state: 'complete' },
  }
  const projection = Sidebar.project({
    desktop, registry, screens: fixture.screens, monitors: fixture.monitors,
    monitorOrder: [], pinned: fixture.settings.pinned,
    hiddenApplications: fixture.settings.hiddenApplications,
    folds: {}, collapsed: false, herdrSnapshot: snapshot,
    herdrAssociations: { byWindowKey: { [entry.key]: 'srv' }, unmatchedServerIds: [] },
    herdrAssociationsVerified: true,
  })
  return projection.rows.filter(row => row.windowKey === entry.key)
}

{
  const rows = matched('0.9.0')
  assert.ok(rows.find(row => row.kind === 'herdr-state' && row.title === UPGRADE))
  const agent = rows.find(row => row.kind === 'herdr-agent')
  assert.ok(agent)
  assert.equal(agent.focusAgentSupported, false)
  assert.equal(agent.actionable, false)
}
for (const version of ['0.9.1', undefined, 'development']) {
  const rows = matched(version)
  assert.equal(rows.some(row => row.kind === 'herdr-state' && row.title === UPGRADE), false,
    String(version) + ': modern/unknown matched server must not be labeled old')
  const agent = rows.find(row => row.kind === 'herdr-agent')
  assert.ok(agent)
  assert.equal(agent.focusAgentSupported, true)
  assert.equal(agent.actionable, true)
}

console.log('Herdr server-version focus gating and notes: PASS')
