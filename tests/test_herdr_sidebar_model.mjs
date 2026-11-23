import assert from 'node:assert/strict'
import { loadModel, plain, read } from './host_harness.mjs'
import { sidebarFixture } from './sidebar_fixture.mjs'

const Model = loadModel('DockHerdrModel')
const Sidebar = loadModel('DockSidebarModel')
const desktopModel = loadModel('DockDesktopModel')

function client(pid, startTime, ancestors) {
  return { pid, startTime, ancestors: ancestors || [] }
}

function server(id, clients) {
  return { id, clients: clients || [] }
}

function windowRow(key, pid, startTime) {
  return { key, pid, startTime }
}

// Unique terminal ancestor matches one window.
{
  const servers = [
    server('local-a', [
      client(41, 41, [
        { pid: 40, startTime: 40 },
        { pid: 1, startTime: 1 },
      ]),
    ]),
  ]
  const windows = [windowRow('win:ghostty', 40, 40)]
  const result = plain(Model.associateWindows(servers, windows))
  assert.deepEqual(result.byWindowKey, { 'win:ghostty': 'local-a' })
  assert.deepEqual(result.unmatchedServerIds, [])
}

// Inner+outer windows: only the closest matching ancestor associates.
{
  const servers = [
    server('local-a', [
      client(41, 41, [
        { pid: 40, startTime: 40 },
        { pid: 10, startTime: 10 },
      ]),
    ]),
  ]
  const windows = [
    windowRow('win:inner', 40, 40),
    windowRow('win:outer', 10, 10),
  ]
  const result = plain(Model.associateWindows(servers, windows))
  assert.deepEqual(result.byWindowKey, { 'win:inner': 'local-a' })
  assert.equal(result.byWindowKey['win:outer'], undefined)
  assert.deepEqual(result.unmatchedServerIds, [])
}

// Nearest identity shared by multiple windows: no farther fallback.
{
  const servers = [
    server('local-a', [
      client(41, 41, [
        { pid: 40, startTime: 40 },
        { pid: 10, startTime: 10 },
      ]),
    ]),
  ]
  const windows = [
    windowRow('win:a', 40, 40),
    windowRow('win:b', 40, 40),
    windowRow('win:far', 10, 10),
  ]
  const result = plain(Model.associateWindows(servers, windows))
  assert.deepEqual(result.byWindowKey, {})
  assert.deepEqual(result.unmatchedServerIds, ['local-a'])
}

// Multiple independently proven windows for one session (two clients).
{
  const servers = [
    server('local-shared', [
      client(11, 11, [{ pid: 100, startTime: 100 }]),
      client(12, 12, [{ pid: 200, startTime: 200 }]),
    ]),
  ]
  const windows = [
    windowRow('win:one', 100, 100),
    windowRow('win:two', 200, 200),
  ]
  const result = plain(Model.associateWindows(servers, windows))
  assert.deepEqual(result.byWindowKey, {
    'win:one': 'local-shared',
    'win:two': 'local-shared',
  })
  assert.deepEqual(result.unmatchedServerIds, [])
}

// Conflicting servers claiming the same unique window stay unmatched.
{
  const servers = [
    server('a', [client(1, 1, [{ pid: 40, startTime: 40 }])]),
    server('b', [client(2, 2, [{ pid: 40, startTime: 40 }])]),
  ]
  const windows = [windowRow('win:term', 40, 40)]
  const result = plain(Model.associateWindows(servers, windows))
  assert.deepEqual(result.byWindowKey, {})
  assert.deepEqual(result.unmatchedServerIds.sort(), ['a', 'b'])
}

// Shared terminal PID without exact surface identity stays unmatched.
{
  const servers = [
    server('local-a', [client(41, 41, [{ pid: 40, startTime: 40 }])]),
  ]
  const windows = [
    windowRow('win:a', 40, 40),
    windowRow('win:b', 40, 40),
  ]
  const result = plain(Model.associateWindows(servers, windows))
  assert.deepEqual(result.byWindowKey, {})
  assert.deepEqual(result.unmatchedServerIds, ['local-a'])
}

// PID reuse (startTime mismatch) and missing clients stay unmatched.
{
  const servers = [
    server('reuse', [client(41, 41, [{ pid: 40, startTime: 40 }])]),
    server('gone', []),
  ]
  const windows = [windowRow('win:term', 40, 99)]
  const result = plain(Model.associateWindows(servers, windows))
  assert.deepEqual(result.byWindowKey, {})
  assert.deepEqual(result.unmatchedServerIds.sort(), ['gone', 'reuse'])
}

// Never guesses by title / focus / row order: only process identity.
{
  const servers = [
    server('local-a', [client(41, 41, [{ pid: 999, startTime: 1 }])]),
  ]
  const windows = [{
    key: 'win:focused',
    pid: 40,
    startTime: 40,
    title: 'herdr',
    focused: true,
    index: 0,
  }]
  const result = plain(Model.associateWindows(servers, windows))
  assert.deepEqual(result.byWindowKey, {})
  assert.deepEqual(result.unmatchedServerIds, ['local-a'])
}

// --- Phase A bridge: revision/epoch gating and identity merge ---

function request(revision, epoch, targets) {
  return { revision, epoch, targets }
}

// Obsolete metadata reply after window replacement is withheld.
{
  const snap = {
    providerEpoch: 'epoch-a',
    servers: [server('local-a', [client(41, 41, [{ pid: 40, startTime: 40 }])])],
    windowProcesses: {
      revision: 1,
      identities: [{ pid: 40, startTime: 40 }],
    },
  }
  const withheld = Model.resolveAssociations(
    request(2, 'epoch-a', [{ key: 'window:2', pid: 40 }]),
    snap,
  )
  assert.equal(withheld, null)

  const applied = plain(Model.resolveAssociations(
    request(1, 'epoch-a', [{ key: 'window:1', pid: 40 }]),
    snap,
  ))
  assert.deepEqual(applied.byWindowKey, { 'window:1': 'local-a' })
}

// Missing / foreign process identity cannot associate.
{
  const snap = {
    providerEpoch: 'epoch-a',
    servers: [server('local-a', [client(41, 41, [{ pid: 40, startTime: 40 }])])],
    windowProcesses: {
      revision: 3,
      identities: [], // pid 40 unread / foreign UID omitted
    },
  }
  const result = plain(Model.resolveAssociations(
    request(3, 'epoch-a', [{ key: 'window:1', pid: 40 }]),
    snap,
  ))
  assert.deepEqual(result.byWindowKey, {})
  assert.deepEqual(result.unmatchedServerIds, ['local-a'])
}

// Successful use of a real resolved PID/startTime pair.
{
  const snap = {
    providerEpoch: 'epoch-b',
    servers: [server('local-a', [client(41, 41, [{ pid: 40, startTime: 9911 }])])],
    windowProcesses: {
      revision: 4,
      identities: [{ pid: 40, startTime: 9911 }],
    },
  }
  const result = plain(Model.resolveAssociations(
    request(4, 'epoch-b', [{ key: 'win:term', pid: 40 }]),
    snap,
  ))
  assert.deepEqual(result.byWindowKey, { 'win:term': 'local-a' })
  assert.deepEqual(result.unmatchedServerIds, [])
}

// Epoch mismatch withholds even when revision matches.
{
  const snap = {
    providerEpoch: 'epoch-new',
    servers: [server('local-a', [client(41, 41, [{ pid: 40, startTime: 40 }])])],
    windowProcesses: {
      revision: 5,
      identities: [{ pid: 40, startTime: 40 }],
    },
  }
  assert.equal(
    Model.resolveAssociations(
      request(5, 'epoch-old', [{ key: 'window:1', pid: 40 }]),
      snap,
    ),
    null,
  )
}

// Fingerprint changes when the handle/PID set changes, not on workspace alone.
{
  const a = Model.windowProcessFingerprint([
    { key: 'window:1', pid: 40 },
    { key: 'window:2', pid: 50 },
  ])
  const sameAfterWorkspace = Model.windowProcessFingerprint([
    { key: 'window:2', pid: 50 },
    { key: 'window:1', pid: 40 },
  ])
  assert.equal(a, sameAfterWorkspace)
  const replaced = Model.windowProcessFingerprint([
    { key: 'window:3', pid: 40 }, // new handle, reused PID
    { key: 'window:2', pid: 50 },
  ])
  assert.notEqual(a, replaced)
}

// PID normalization: unique positive ints, cap 256, reject junk.
{
  assert.deepEqual(
    plain(Model.normalizeWindowProcessPids([1, 1, 2, 0, -3, 2.5, '9', null])),
    [1, 2],
  )
  const many = Array.from({ length: 300 }, (_, i) => i + 1)
  assert.equal(Model.normalizeWindowProcessPids(many).length, 256)
}

console.log('herdr sidebar model association: PASS')

// --- Phase B: project matched agents into the tree ---

{
  // Matching: agents nest under the associated window; unmatched stay out of the tree.
  const f = sidebarFixture()
  const desktop = desktopModel.build(f.input)
  const registry = Sidebar.reconcileHandles({ nextToken: 1, entries: [] }, f.toplevels)
  const termEntry = registry.entries.find((_, i) => f.toplevels[i].id === 'terminal')
  assert.ok(termEntry)
  const windowKey = termEntry.key
  const snapshot = {
    providerEpoch: 'epoch-b',
    revision: 1,
    servers: [
      {
        id: 'local-matched', health: 'live', label: 'Matched',
        transport: 'local', host: 'local', session: 'default',
        connectionGeneration: 1, capabilities: { focusAgent: true },
      },
      {
        id: 'local-free', health: 'live', label: 'Free',
        transport: 'local', host: 'local', session: 'default',
        connectionGeneration: 1, capabilities: { focusAgent: true },
      },
    ],
    agents: [
      {
        id: 'local-matched:1:pane-a',
        serverId: 'local-matched',
        connectionGeneration: 1,
        paneId: 'pane-a',
        terminalId: 'term-a',
        name: 'named-a',
        workspaceId: 'w1',
        tabId: 'w1:t-shared',
        tabTitle: 'Shared multi tab',
        title: 'Codex Review',
        workspaceLabel: 'smart-omarchy-dock',
        agent: 'codex',
        status: 'working',
      },
      {
        id: 'local-matched:1:pane-b',
        serverId: 'local-matched',
        connectionGeneration: 1,
        paneId: 'pane-b',
        name: 'Claude Fix',
        workspaceId: 'w1',
        tabId: 'w1:t-shared',
        tabTitle: 'Shared multi tab',
        workspaceLabel: 'smart-omarchy-dock',
        agent: 'claude',
        status: 'idle',
      },
      {
        id: 'local-matched:1:pane-c',
        serverId: 'local-matched',
        connectionGeneration: 1,
        paneId: 'pane-c',
        workspaceId: 'w1',
        tabId: 'w1:t-blocked',
        tabTitle: 'Shared blocked tab',
        title: 'Needs input',
        workspaceLabel: 'smart-omarchy-dock',
        agent: 'opencode',
        status: 'blocked',
      },
      {
        id: 'local-free:1:pane-z',
        serverId: 'local-free',
        connectionGeneration: 1,
        paneId: 'pane-z',
        name: 'Unmatched Agent',
        agent: 'cursor',
        status: 'blocked',
      },
    ],
    liveCounts: { agents: 4, working: 1, idle: 1, blocked: 2, done: 0, unknown: 0, complete: true },
    completeness: { state: 'complete' },
  }
  const associations = {
    byWindowKey: { [windowKey]: 'local-matched' },
    unmatchedServerIds: ['local-free'],
  }
  const projected = plain(Sidebar.project({
    desktop,
    screens: f.screens,
    monitors: f.monitors,
    monitorOrder: [],
    pinned: f.settings.pinned,
    hiddenApplications: f.settings.hiddenApplications,
    registry,
    folds: ({}),
    collapsed: false,
    herdrSnapshot: snapshot,
    herdrAssociations: associations,
    herdrAssociationsVerified: true,
  }))
  const parent = projected.rows.find(row => row.key === windowKey)
  assert.ok(parent)
  assert.equal(parent.herdrAssociated, true)
  assert.equal(parent.herdrServerId, 'local-matched')
  const nested = projected.rows.filter(row =>
    row.windowKey === windowKey
    && row.kind === 'herdr-agent')
  // Sorted agents: blocked (c), idle (b), working (a)
  assert.deepEqual(nested.map(row => row.kind), [
    'herdr-agent', 'herdr-agent', 'herdr-agent',
  ])
  assert.ok(!projected.rows.some(row => row.kind === 'herdr-tab'))
  assert.ok(!projected.rows.some(row => row.kind === 'herdr-workspace'))

  assert.deepEqual(nested.map(row => row.status), ['blocked', 'idle', 'working'])
  assert.deepEqual(nested.map(row => row.title), ['Needs input', 'Claude Fix', 'Codex Review'])
  assert.deepEqual(nested.map(row => row.tabTitle),
    ['Shared blocked tab', 'Shared multi tab', 'Shared multi tab'])
  assert.deepEqual(nested.map(row => row.paneId), ['pane-c', 'pane-b', 'pane-a'])
  assert.deepEqual(nested.map(row => row.agentId), [
    'local-matched:1:pane-c',
    'local-matched:1:pane-b',
    'local-matched:1:pane-a',
  ])
  assert.equal(nested[0].subtitle, 'smart-omarchy-dock - OpenCode')
  assert.equal(nested[1].subtitle, 'smart-omarchy-dock - Claude')
  assert.equal(nested[2].subtitle, 'smart-omarchy-dock - Codex')
  assert.equal(nested[1].key, JSON.stringify(['herdr-agent', windowKey, 'local-matched:1:pane-b']))
  assert.equal(nested[1].windowKey, windowKey)
  assert.equal(nested[1].providerEpoch, 'epoch-b')
  assert.equal(nested[1].serverId, 'local-matched')
  assert.equal(nested[2].terminalId, 'term-a')
  nested.forEach(row => {
    assert.equal(row.actionable, true)
    assert.equal(row.parentKey, windowKey)
    assert.equal(row.treeDepth, parent.treeDepth + 1)
    assert.equal(typeof row.isLastSibling, 'boolean')
    assert.ok(Array.isArray(row.ancestorContinues))
  })

  assert.ok(!projected.rows.some(row => row.title === 'Unmatched Agent'),
    'unmatched agents stay out of the window tree')

  // Pure helpers: title fallback + sort ranks + tree grouping.
  assert.equal(Model.displayAgentTitle({ name: 'n', title: 'pane', tabTitle: 'tab' }), 'pane')
  assert.equal(Model.displayAgentTitle({ name: 'n', tabTitle: 'tab' }), 'n')
  assert.equal(Model.displayAgentTitle({ tabTitle: 'tab' }), 'tab')
  assert.equal(Model.displayAgentSecondary({ workspaceLabel: 'ws', agent: 'cursor' }),
    'ws - Cursor')
  assert.equal(Model.displayAgentSecondary({ agent: 'codex' }), 'Codex')
  assert.equal(Model.displayAgentTabSecondary({ tabTitle: 'Review', agent: 'codex' }),
    'Review · Codex')
  assert.equal(Model.displayAgentTabSecondary({ agent: 'claude' }), 'Claude')
  assert.equal(Model.displayAgentTabSecondary({ tabTitle: 'Build' }), 'Build')
  assert.equal(Model.displayAgentSecondary({
    workspaceLabel: 'ws', tabTitle: 'Review', agent: 'codex'
  }), 'ws - Codex', 'sidebar secondary text remains workspace-based')
  assert.deepEqual(
    Model.sortAgentsForDisplay([
      { id: '1', status: 'idle' },
      { id: '2', status: 'blocked' },
      { id: '3', status: 'done' },
      { id: '4', status: 'working' },
      { id: '5', status: 'unknown' },
    ]).map(a => a.status),
    ['blocked', 'done', 'idle', 'working', 'unknown'],
  )
  const summary = Model.windowAgentSummary([
    { id: 'idle', status: 'idle', title: 'Idle', focusAgentSupported: true },
    { id: 'done', status: 'done', title: 'Done', focusAgentSupported: false },
    { id: 'working', status: 'working', title: 'Working', focusAgentSupported: true },
    { id: 'blocked', status: 'blocked', title: 'Blocked', focusAgentSupported: true },
    { id: 'stale', status: 'stale', title: 'Stale', focusAgentSupported: false }
  ], {})
  assert.equal(summary.count, 5)
  assert.equal(summary.indicatorStatus, 'blocked')
  assert.deepEqual(plain(summary.counters), [
    { status: 'blocked', count: 1 }, { status: 'working', count: 1 },
    { status: 'done', count: 1 }, { status: 'idle', count: 1 },
    { status: 'unknown', count: 1 }
  ])
  assert.deepEqual(Array.from(summary.rows, row => row.id),
    ['blocked', 'done', 'idle', 'working', 'stale'])
  assert.equal(summary.rows[0].status, 'blocked', 'rows retain raw status')
  assert.equal(summary.rows[1].focusAgentSupported, false,
    'remote focus capability remains visible in summary rows')
  assert.equal(Model.windowAgentSummary([
    { id: 'done', status: 'done' }, { id: 'idle', status: 'idle' }
  ], { done: true }).indicatorStatus, '', 'acknowledged done is indicator-only')
  assert.equal(Model.windowAgentSummary([
    { id: 'done', status: 'done' }, { id: 'working', status: 'working' }
  ], { done: true }).indicatorStatus, 'working')
  const duplicateIds = Model.windowAgentSummary([
    { id: 'same', serverId: 'one', status: 'done', indicatorKey: 'window-one' },
    { id: 'same', serverId: 'two', status: 'done', indicatorKey: 'window-two' }
  ], { 'window-one': true })
  assert.equal(duplicateIds.count, 2, 'agent identity is scoped by server')
  assert.equal(duplicateIds.indicatorStatus, 'done',
    'acknowledging one window completion does not hide another with the same agent id')
  const grouped = plain(Model.groupAgentsForTree([
    { id: 'a', workspaceId: 'w1', workspaceLabel: 'Dock', tabId: 't1', tabTitle: 'One', status: 'idle' },
    { id: 'b', workspaceId: 'w1', workspaceLabel: 'Dock', tabId: 't1', tabTitle: 'One', status: 'working' },
    { id: 'c', workspaceId: 'w2', workspaceLabel: 'Other', tabId: 't9', tabTitle: 'Solo', status: 'blocked' },
  ]))
  assert.equal(grouped.length, 2)
  assert.equal(grouped[0].id, 'w2')
  assert.equal(grouped[0].tabs.length, 1)
  assert.equal(grouped[0].tabs[0].agents.length, 1)
  assert.equal(grouped[1].id, 'w1')
  assert.equal(grouped[1].tabs[0].agents.length, 2)

  // Unmatched fallback filter helpers: matched ids excluded.
  const matched = Sidebar.matchedHerdrServerIds(associations)
  assert.equal(matched['local-matched'], true)
  assert.equal(matched['local-free'], undefined)

  // Movement / status: agent keys stay stable when status changes.
  const statusFlip = plain(Sidebar.project({
    desktop,
    screens: f.screens,
    monitors: f.monitors,
    monitorOrder: [],
    pinned: f.settings.pinned,
    hiddenApplications: f.settings.hiddenApplications,
    registry,
    folds: ({}),
    collapsed: false,
    herdrSnapshot: Object.assign({}, snapshot, {
      agents: snapshot.agents.map(agent =>
        agent.id === 'local-matched:1:pane-a'
          ? Object.assign({}, agent, { status: 'done' })
          : agent),
    }),
    herdrAssociations: {
      byWindowKey: { [windowKey]: 'local-matched' },
      unmatchedServerIds: ['local-free'],
    },
    herdrAssociationsVerified: true,
  }))
  const flippedAgents = statusFlip.rows.filter(row => row.kind === 'herdr-agent')
  assert.ok(!statusFlip.rows.some(row => row.kind === 'herdr-tab'))
  assert.equal(flippedAgents.length, 3)
  assert.deepEqual(flippedAgents.map(row => row.status), ['blocked', 'done', 'idle'])
  assert.equal(flippedAgents[1].key, JSON.stringify(['herdr-agent', windowKey, 'local-matched:1:pane-a']))
  assert.equal(flippedAgents[2].key, JSON.stringify(['herdr-agent', windowKey, 'local-matched:1:pane-b']))

  // Empty healthy inventory vs unavailable / reconnecting / partial.
  assert.equal(Sidebar.herdrStateTitle({ health: 'live' }, {
    liveCounts: { agents: 0, complete: true },
    completeness: { state: 'complete' },
  }), 'No active agents')
  assert.equal(Sidebar.herdrStateTitle({ health: 'connecting' }, {
    liveCounts: null,
    completeness: { state: 'unknown' },
  }), 'Reconnecting')
  assert.equal(Sidebar.herdrStateTitle(null, null), 'Herdr unavailable')
  assert.equal(Sidebar.herdrStateTitle({ health: 'live' }, {
    liveCounts: null,
    completeness: { state: 'partial' },
  }), 'Partial inventory')

  const emptyProjected = plain(Sidebar.project({
    desktop,
    screens: f.screens,
    monitors: f.monitors,
    monitorOrder: [],
    pinned: f.settings.pinned,
    hiddenApplications: f.settings.hiddenApplications,
    registry,
    folds: ({}),
    collapsed: false,
    herdrSnapshot: {
      providerEpoch: 'epoch-b',
      servers: [{ id: 'local-matched', health: 'live' }],
      agents: [],
      liveCounts: { agents: 0, complete: true },
      completeness: { state: 'complete' },
    },
    herdrAssociations: {
      byWindowKey: { [windowKey]: 'local-matched' },
      unmatchedServerIds: [],
    },
    herdrAssociationsVerified: true,
  }))
  const emptyChild = emptyProjected.rows.find(row => row.kind === 'herdr-state'
    && row.windowKey === windowKey)
  assert.ok(emptyChild)
  assert.equal(emptyChild.title, 'No active agents')
  assert.equal(emptyChild.actionable, false)

  // Provider loss: preserved parent association emits non-actionable state only.
  const lost = plain(Sidebar.project({
    desktop,
    screens: f.screens,
    monitors: f.monitors,
    monitorOrder: [],
    pinned: f.settings.pinned,
    hiddenApplications: f.settings.hiddenApplications,
    registry,
    folds: ({}),
    collapsed: false,
    herdrSnapshot: null,
    herdrAssociations: {
      byWindowKey: { [windowKey]: 'local-matched' },
      unmatchedServerIds: [],
    },
    herdrAssociationsVerified: false,
  }))
  assert.ok(!lost.rows.some(row => row.kind === 'herdr-agent'))
  const lostState = lost.rows.find(row => row.kind === 'herdr-state' && row.windowKey === windowKey)
  assert.ok(lostState)
  assert.equal(lostState.title, 'Herdr unavailable')

  // Unverified preserved parent with a live snapshot still emits only state.
  const pendingAgents = plain(Sidebar.project({
    desktop,
    screens: f.screens,
    monitors: f.monitors,
    monitorOrder: [],
    pinned: f.settings.pinned,
    hiddenApplications: f.settings.hiddenApplications,
    registry,
    folds: ({}),
    collapsed: false,
    herdrSnapshot: snapshot,
    herdrAssociations: {
      byWindowKey: { [windowKey]: 'local-matched' },
      unmatchedServerIds: [],
    },
    herdrAssociationsVerified: false,
  }))
  assert.ok(!pendingAgents.rows.some(row => row.kind === 'herdr-agent'))
  const pendingState = pendingAgents.rows.find(row => row.kind === 'herdr-state'
    && row.windowKey === windowKey)
  assert.ok(pendingState)
  assert.equal(pendingState.title, 'Herdr unavailable')
  assert.equal(pendingState.actionable, false)

  // Nonempty partial/truncated snapshot keeps agents and appends a state child.
  const partialSnap = Object.assign({}, snapshot, {
    agents: [snapshot.agents[0]],
    liveCounts: { agents: 1, working: 1, idle: 0, blocked: 0, done: 0, unknown: 0, complete: false },
    completeness: { state: 'partial', truncated: true, agentTruncated: true },
  })
  const partialProjected = plain(Sidebar.project({
    desktop,
    screens: f.screens,
    monitors: f.monitors,
    monitorOrder: [],
    pinned: f.settings.pinned,
    hiddenApplications: f.settings.hiddenApplications,
    registry,
    folds: ({}),
    collapsed: false,
    herdrSnapshot: partialSnap,
    herdrAssociations: {
      byWindowKey: { [windowKey]: 'local-matched' },
      unmatchedServerIds: ['local-free'],
    },
    herdrAssociationsVerified: true,
  }))
  const partialAgents = partialProjected.rows.filter(row =>
    row.kind === 'herdr-agent' && row.windowKey === windowKey)
  const partialStates = partialProjected.rows.filter(row =>
    row.kind === 'herdr-state' && row.windowKey === windowKey)
  assert.equal(partialAgents.length, 1)
  assert.equal(partialAgents[0].actionable, true)
  assert.equal(partialAgents[0].paneId, 'pane-a')
  assert.equal(partialStates.length, 1)
  assert.equal(partialStates[0].title, 'Partial inventory')
  assert.equal(partialStates[0].actionable, false)

  // Fallback empty classification: unknown/partial must not claim healthy empty.
  const partialEmpty = Sidebar.herdrFallbackEmptyChild(
    { id: 'local-free', health: 'live' },
    { liveCounts: null, completeness: { state: 'partial' } },
  )
  assert.ok(partialEmpty)
  assert.equal(partialEmpty.title, 'Partial inventory')
  assert.notEqual(partialEmpty.title, 'No active coding agents')
  assert.notEqual(partialEmpty.title, 'No active agents')
  const truncatedEmpty = Sidebar.herdrFallbackEmptyChild(
    { id: 'local-free', health: 'live' },
    {
      liveCounts: { agents: 0, complete: false },
      completeness: { state: 'partial', truncated: true, agentTruncated: true },
    },
  )
  assert.equal(truncatedEmpty.title, 'Partial inventory')
  const healthyEmpty = Sidebar.herdrFallbackEmptyChild(
    { id: 'local-free', health: 'live' },
    { liveCounts: { agents: 0, complete: true }, completeness: { state: 'complete' } },
  )
  assert.equal(healthyEmpty.title, 'No active agents')
  assert.equal(Sidebar.herdrFallbackVisible({
    servers: [{ id: 'local-free', health: 'live' }],
    agents: [],
    liveCounts: { agents: 0, complete: true },
    completeness: { state: 'complete' },
  }, {
    byWindowKey: {},
    unmatchedServerIds: ['local-free'],
  }), false, 'healthy empty unmatched Herdr session must not create a Widget card')
  assert.equal(Sidebar.herdrFallbackVisible(snapshot, associations), true)
  assert.equal(Sidebar.herdrFallbackVisible(snapshot, {
    byWindowKey: { [windowKey]: 'local-matched', x: 'local-free' },
    unmatchedServerIds: [],
  }), false)

  // Rail omits nested herdr children (same as browser tabs).
  const rail = plain(Sidebar.project({
    desktop,
    screens: f.screens,
    monitors: f.monitors,
    monitorOrder: [],
    pinned: f.settings.pinned,
    hiddenApplications: f.settings.hiddenApplications,
    registry,
    folds: ({}),
    collapsed: true,
    herdrSnapshot: snapshot,
    herdrAssociations: associations,
    herdrAssociationsVerified: true,
  }))
  assert.ok(!rail.rows.some(row =>
    row.kind === 'herdr-agent' || row.kind === 'herdr-state'))

  // Browser rows still project beside herdr children when both apply.
  const chromeEntry = registry.entries.find((_, i) => f.toplevels[i].id === 'c')
  const withBrowser = plain(Sidebar.project({
    desktop,
    screens: f.screens,
    monitors: f.monitors,
    monitorOrder: [],
    pinned: f.settings.pinned,
    hiddenApplications: f.settings.hiddenApplications,
    registry,
    folds: ({}),
    collapsed: false,
    sidebarBrowserTabsEnabled: true,
    browserTabs: {
      [String(f.handles.find(h => h.wayland.id === 'c').address).toLowerCase()]: [
        { targetId: 't1', title: 'Docs', active: true },
      ],
    },
    herdrSnapshot: snapshot,
    herdrAssociations: {
      byWindowKey: { [windowKey]: 'local-matched', [chromeEntry.key]: 'local-matched' },
      unmatchedServerIds: ['local-free'],
    },
    herdrAssociationsVerified: true,
  }))
  assert.ok(withBrowser.rows.some(row => row.kind === 'browser-tab'))
  assert.ok(withBrowser.rows.some(row => row.kind === 'herdr-agent' && row.windowKey === windowKey))
}

// --- HERDR-REMOTE-02: remote labels, health truth, metadata and focus gates ---
{
  const f = sidebarFixture()
  const desktop = desktopModel.build(f.input)
  const registry = Sidebar.reconcileHandles({ nextToken: 1, entries: [] }, f.toplevels)
  const termEntry = registry.entries.find((_, i) => f.toplevels[i].id === 'terminal')
  assert.ok(termEntry)
  const windowKey = termEntry.key

  const remoteDefault = {
    id: 'remote-default',
    transport: 'remote',
    host: 'devbox',
    session: 'default',
    label: 'devbox',
    connectionGeneration: 7,
    health: 'live',
    capabilities: { focusAgent: false },
  }
  const remoteNamed = {
    id: 'remote-named',
    transport: 'remote',
    host: 'devbox',
    session: 'review',
    label: 'devbox',
    connectionGeneration: 2,
    health: 'connecting',
    capabilities: { focusAgent: false },
  }
  const remoteOther = {
    id: 'remote-other',
    transport: 'remote',
    host: 'buildbox',
    session: 'review',
    label: 'buildbox',
    connectionGeneration: 4,
    health: 'unavailable',
    capabilities: { focusAgent: false },
  }

  assert.equal(Model.serverDisplayLabel(remoteDefault), 'devbox')
  assert.equal(Model.serverDisplayLabel(remoteNamed), 'devbox · review')
  assert.equal(Model.serverDisplayLabel(remoteOther), 'buildbox · review')
  assert.equal(Model.serverFocusAgentSupported(remoteDefault), false)
  assert.equal(Model.serverFocusAgentSupported({
    ...remoteDefault, capabilities: { focusAgent: true },
  }), true)
  assert.equal(Model.serverFocusAgentSupported({
    ...remoteDefault, capabilities: {},
  }), false)
  assert.equal(Model.serverDisplayLabel({
    transport: 'local', label: 'Matched', session: 'default',
  }), 'Matched')

  const snapshot = {
    providerEpoch: 'epoch-remote',
    revision: 1,
    servers: [remoteDefault, remoteNamed, remoteOther],
    agents: [{
      id: 'remote-default:7:pane-r',
      serverId: 'remote-default',
      connectionGeneration: 7,
      transport: 'remote',
      host: 'devbox',
      session: 'default',
      paneId: 'pane-r',
      terminalId: 'term-r',
      workspaceId: 'rw',
      workspaceLabel: 'smartdock',
      tabId: 'rw:tab',
      tabTitle: 'Remote work',
      title: 'Remote Codex',
      agent: 'codex',
      status: 'working',
    }],
    liveCounts: {
      agents: 1, working: 1, idle: 0, done: 0, blocked: 0, unknown: 0,
      servers: 1, complete: false,
    },
    completeness: { state: 'partial' },
  }
  const projected = plain(Sidebar.project({
    desktop,
    screens: f.screens,
    monitors: f.monitors,
    monitorOrder: [],
    pinned: f.settings.pinned,
    hiddenApplications: f.settings.hiddenApplications,
    registry,
    folds: ({}),
    collapsed: false,
    herdrSnapshot: snapshot,
    herdrAssociations: {
      byWindowKey: { [windowKey]: 'remote-default' },
      unmatchedServerIds: ['remote-named', 'remote-other'],
    },
    herdrAssociationsVerified: true,
  }))
  const parent = projected.rows.find(row => row.key === windowKey)
  assert.ok(parent)
  assert.equal(parent.herdrDisplayLabel, 'devbox')
  assert.equal(parent.herdrTransport, 'remote')
  assert.equal(parent.herdrHost, 'devbox')
  assert.equal(parent.herdrSession, 'default')
  assert.equal(parent.herdrFocusAgentSupported, false)

  const remoteAgent = projected.rows.find(row =>
    row.kind === 'herdr-agent' && row.windowKey === windowKey)
  assert.ok(remoteAgent)
  assert.equal(remoteAgent.status, 'working')
  assert.equal(remoteAgent.actionable, false)
  assert.equal(remoteAgent.focusAgentSupported, false)
  assert.equal(remoteAgent.transport, 'remote')
  assert.equal(remoteAgent.host, 'devbox')
  assert.equal(remoteAgent.session, 'default')
  assert.equal(remoteAgent.serverLabel, 'devbox')
  assert.equal(remoteAgent.providerEpoch, 'epoch-remote')
  assert.equal(remoteAgent.serverId, 'remote-default')
  assert.equal(remoteAgent.connectionGeneration, 7)
  assert.equal(remoteAgent.agentId, 'remote-default:7:pane-r')
  assert.equal(remoteAgent.paneId, 'pane-r')
  assert.equal(remoteAgent.terminalId, 'term-r')

  assert.notEqual(Model.serverDisplayLabel(remoteNamed), Model.serverDisplayLabel(remoteOther))
  assert.equal(Sidebar.herdrAgentsForServer(snapshot, 'remote-named').length, 0)
  assert.equal(Sidebar.herdrAgentsForServer(snapshot, 'remote-other').length, 0)

  const reconnecting = Sidebar.herdrFallbackStateChild(remoteNamed, snapshot)
  assert.ok(reconnecting)
  assert.equal(reconnecting.title, 'Reconnecting')
  assert.notEqual(reconnecting.title, 'No active agents')
  const unavailable = Sidebar.herdrFallbackStateChild(remoteOther, snapshot)
  assert.ok(unavailable)
  assert.equal(unavailable.title, 'Herdr unavailable')
  assert.notEqual(unavailable.title, 'No active agents')
  const healthyZero = Sidebar.herdrFallbackStateChild({
    ...remoteOther, id: 'remote-zero', health: 'live',
  }, {
    liveCounts: { agents: 0, complete: true },
    completeness: { state: 'complete' },
  })
  assert.equal(healthyZero.title, 'No active agents')

  const supportedSnapshot = {
    ...snapshot,
    servers: [{
      ...remoteDefault,
      capabilities: { focusAgent: true },
    }],
    completeness: { state: 'complete' },
    liveCounts: {
      agents: 1, working: 1, idle: 0, done: 0, blocked: 0, unknown: 0,
      servers: 1, complete: true,
    },
  }
  const supportedProjection = plain(Sidebar.project({
    desktop,
    screens: f.screens,
    monitors: f.monitors,
    monitorOrder: [],
    pinned: f.settings.pinned,
    hiddenApplications: f.settings.hiddenApplications,
    registry,
    folds: ({}),
    collapsed: false,
    herdrSnapshot: supportedSnapshot,
    herdrAssociations: {
      byWindowKey: { [windowKey]: 'remote-default' },
      unmatchedServerIds: [],
    },
    herdrAssociationsVerified: true,
  }))
  const supportedAgent = supportedProjection.rows.find(row =>
    row.kind === 'herdr-agent' && row.windowKey === windowKey)
  assert.ok(supportedAgent)
  assert.equal(supportedAgent.actionable, true)
  assert.equal(supportedAgent.focusAgentSupported, true)

  const Interaction = loadModel('DockSidebarInteractionModel')
  assert.equal(Interaction.rowHoverFillEligible('herdr-agent', false), false)
  assert.equal(Interaction.rowHoverFillEligible('herdr-agent', true), true)
  assert.equal(Interaction.sidebarWindowDisplayTitle({
    kind: 'window', isHerdr: true, herdrLabel: 'devbox · review',
    windowTitle: 'original terminal',
  }), 'devbox · review')
  assert.equal(Interaction.sidebarWindowDisplayTitle({
    kind: 'window', isHerdr: true, windowTitle: 'original terminal',
  }), 'Herdr')

  const agentsView = read('components/DockHerdrAgentsView.qml')
  assert.ok(agentsView.includes('HerdrModel.serverDisplayLabel(server)'))
  assert.ok(agentsView.includes('transport === "remote"'))
  assert.ok(agentsView.includes('herdrFallbackStateChild'))
}

// Delegates must not acquire a provider (static source contract).
{
  const agentsView = read('components/DockHerdrAgentsView.qml')
  const widgetView = read('components/DockSidebarWidgetView.qml')
  assert.equal(agentsView.includes('acquire('), false)
  assert.equal(agentsView.includes('herdrService'), false)
  assert.equal(widgetView.includes('.acquire('), false)
  assert.ok(agentsView.includes('never acquires a provider'))
}

console.log('herdr sidebar model projection: PASS')

// --- Phase C: compact appearance, status counters, folding (combined layout) ---

{
  // Shared status normalization / unique-ID counting / ordered counters.
  assert.equal(Model.normalizeStatus('Working'), 'working')
  assert.equal(Model.normalizeStatus('DONE'), 'done')
  assert.equal(Model.normalizeStatus('future-state'), 'unknown')
  assert.equal(Model.normalizeStatus(null), 'unknown')
  assert.equal(Model.statusColorRole('working'), 'accent')
  assert.equal(Model.statusColorRole('idle'), 'idle')
  assert.equal(Model.statusColorRole('done'), 'done')
  assert.equal(Model.statusColorRole('blocked'), 'blocked')
  assert.equal(Model.statusColorRole('weird'), 'hollow')
  assert.equal(Model.statusLabel('done'), 'Done')
  assert.ok(Model.statusLabel('done').indexOf('success') < 0,
    'done is Herdr state, not proven task success')

  // Per-request deadlines: a newer request must not extend the oldest one.
  const focusPending = {
    'focus-a': { startedAt: 0 },
    'focus-b': { startedAt: 4900 },
  }
  assert.equal(Model.nextFocusDeadlineDelay(focusPending, 4900, 5000), 100)
  assert.deepEqual(
    plain(Model.expiredFocusRequestIds(focusPending, 5000, 5000)),
    ['focus-a'],
  )
  assert.equal(Model.nextFocusDeadlineDelay({ 'focus-b': { startedAt: 4900 } }, 5000, 5000), 4900)
  assert.equal(Model.nextFocusDeadlineDelay({}, 5000, 5000), -1)
  assert.equal(Model.nextFocusDeadlineDelay({ bad: { startedAt: 'nope' } }, 5000, 5000), 0)

  assert.equal(Model.displayAgentKind('codex'), 'Codex')
  assert.equal(Model.displayAgentKind('claude'), 'Claude')
  assert.equal(Model.displayAgentKind('cursor'), 'Cursor')
  assert.equal(Model.displayAgentKind(''), '')
  assert.equal(Model.displayAgentKind(null), '')
  assert.equal(Model.displayAgentKind('opencode'), 'OpenCode')

  // Combined layout fixture: long/markup-like names, missing kinds, all statuses,
  // multi-digit counts, narrow width, fold persistence (no new subscription).
  const f = sidebarFixture()
  const desktop = desktopModel.build(f.input)
  const registry = Sidebar.reconcileHandles({ nextToken: 1, entries: [] }, f.toplevels)
  const termEntry = registry.entries.find((_, i) => f.toplevels[i].id === 'terminal')
  assert.ok(termEntry)
  const windowKey = termEntry.key
  const herdrFoldKey = 'herdr:' + windowKey

  const manyAgents = []
  // 12 working + 3 idle + 1 done + 10 blocked + 2 unknown = 28 unique IDs
  for (let i = 0; i < 12; i++)
    manyAgents.push({
      id: 'local-matched:1:work-' + i,
      serverId: 'local-matched',
      connectionGeneration: 1,
      paneId: 'work-' + i,
      name: i === 0
        ? '<b>Long markup-like agent name that must stay plain text</b>'
        : 'Worker ' + i,
      agent: i === 0 ? 'codex' : (i === 1 ? '' : 'claude'),
      status: 'working',
    })
  for (let i = 0; i < 3; i++)
    manyAgents.push({
      id: 'local-matched:1:idle-' + i,
      serverId: 'local-matched',
      connectionGeneration: 1,
      paneId: 'idle-' + i,
      name: 'Idle ' + i,
      agent: 'cursor',
      status: 'idle',
    })
  manyAgents.push({
    id: 'local-matched:1:done-0',
    serverId: 'local-matched',
    connectionGeneration: 1,
    paneId: 'done-0',
    name: 'Done agent',
    agent: 'codex',
    status: 'done',
  })
  for (let i = 0; i < 10; i++)
    manyAgents.push({
      id: 'local-matched:1:block-' + i,
      serverId: 'local-matched',
      connectionGeneration: 1,
      paneId: 'block-' + i,
      name: 'Blocked ' + i,
      agent: 'claude',
      status: 'blocked',
    })
  manyAgents.push({
    id: 'local-matched:1:unk-0',
    serverId: 'local-matched',
    connectionGeneration: 1,
    paneId: 'unk-0',
    name: 'Unknown A',
    agent: '',
    status: 'future',
  })
  manyAgents.push({
    id: 'local-matched:1:unk-1',
    serverId: 'local-matched',
    connectionGeneration: 1,
    paneId: 'unk-1',
    name: 'Unknown B',
    agent: 'codex',
    status: null,
  })
  // Duplicate ID must not double-count (status totals only; projection uses unique IDs).
  const withDuplicate = manyAgents.concat([{
    id: 'local-matched:1:work-0',
    serverId: 'local-matched',
    connectionGeneration: 1,
    paneId: 'work-0-dup',
    name: 'Dup',
    agent: 'codex',
    status: 'idle',
  }])

  const counts = plain(Model.countAgentStatuses(withDuplicate))
  assert.equal(counts.working, 12)
  assert.equal(counts.idle, 3)
  assert.equal(counts.done, 1)
  assert.equal(counts.blocked, 10)
  assert.equal(counts.unknown, 2)
  assert.equal(counts.agents, 28)
  assert.equal(
    counts.working + counts.idle + counts.done + counts.blocked + counts.unknown,
    counts.agents,
  )
  const counters = plain(Model.statusCounters(counts))
  // Same order as agent list: blocked → working → done → idle → unknown
  assert.deepEqual(counters.map(c => c.status),
    ['blocked', 'working', 'done', 'idle', 'unknown'])
  assert.deepEqual(counters.map(c => c.count), [10, 12, 1, 3, 2])
  // Zero omission:
  assert.deepEqual(
    plain(Model.statusCounters({
      working: 2, idle: 0, done: 0, blocked: 1, unknown: 0, agents: 3,
    })).map(c => c.status),
    ['blocked', 'working'],
  )

  const Interaction = loadModel('DockSidebarInteractionModel')
  // Narrow width: reserve kind + counters + chevron first; name gets the remainder.
  const layout = plain(Interaction.herdrCompactLabelWidths({
    availableWidth: 160,
    kindWidth: 48,
    countersWidth: 72,
    controlsWidth: 28,
    gap: 6,
  }))
  // Narrow width: reserved chrome exceeds the row; name elides to zero.
  assert.equal(layout.reserved, 48 + 72 + 28 + 6 * 3)
  assert.equal(layout.nameWidth, 0)
  assert.equal(layout.kindWidth, 48)
  const roomy = plain(Interaction.herdrCompactLabelWidths({
    availableWidth: 320,
    kindWidth: 48,
    countersWidth: 72,
    controlsWidth: 28,
    gap: 6,
  }))
  assert.equal(roomy.nameWidth, 320 - roomy.reserved)
  assert.ok(roomy.nameWidth > 0)
  // Markup-like name stays literal plain text for display helpers.
  const displayName = Interaction.sidebarWindowDisplayTitle({
    kind: 'herdr-agent',
    title: '<b>Long markup-like agent name that must stay plain text</b>',
  })
  assert.equal(displayName, '<b>Long markup-like agent name that must stay plain text</b>')
  assert.equal(
    Interaction.herdrAgentKindLabel({ agentKind: 'codex' }),
    'Codex',
  )
  assert.equal(
    Interaction.herdrAgentKindLabel({ agentKind: '' }),
    '',
  )
  assert.ok(
    Interaction.herdrStatusAccessibleText('done').toLowerCase().includes('done'),
  )

  const snapshot = {
    providerEpoch: 'epoch-c',
    revision: 1,
    servers: [{
      id: 'local-matched', health: 'live', label: 'Matched',
      transport: 'local', host: 'local', session: 'default',
      connectionGeneration: 1, capabilities: { focusAgent: true },
    }],
    agents: manyAgents,
    liveCounts: {
      agents: 28, working: 12, idle: 3, done: 1, blocked: 10, unknown: 2, complete: true,
    },
    completeness: { state: 'complete' },
  }
  const associations = {
    byWindowKey: { [windowKey]: 'local-matched' },
    unmatchedServerIds: [],
  }

  // Expanded (missing fold key): agents visible; parent carries counts + fold key.
  const expanded = plain(Sidebar.project({
    desktop,
    screens: f.screens,
    monitors: f.monitors,
    monitorOrder: [],
    pinned: f.settings.pinned,
    hiddenApplications: f.settings.hiddenApplications,
    registry,
    folds: ({}),
    collapsed: false,
    herdrSnapshot: snapshot,
    herdrAssociations: associations,
    herdrAssociationsVerified: true,
  }))
  const parent = expanded.rows.find(row => row.key === windowKey)
  assert.ok(parent)
  assert.equal(parent.herdrFoldKey, herdrFoldKey)
  assert.equal(parent.herdrFolded, false)
  assert.equal(parent.herdrExpandable, true)
  assert.deepEqual(plain(parent.herdrStatusCounts), counts)
  assert.deepEqual(plain(parent.herdrStatusCounters).map(c => c.status),
    ['blocked', 'working', 'done', 'idle', 'unknown'])
  assert.deepEqual(plain(parent.herdrStatusCounters).map(c => c.count), [10, 12, 1, 3, 2])
  const agentRows = expanded.rows.filter(row =>
    row.kind === 'herdr-agent' && row.windowKey === windowKey)
  assert.equal(agentRows.length, 28)
  // Sort: blocked → done → idle → working → unknown
  assert.equal(agentRows[0].status, 'blocked')
  assert.equal(agentRows[10].status, 'done')
  assert.equal(agentRows[11].status, 'idle')
  assert.equal(agentRows[14].status, 'working')
  assert.equal(agentRows[26].status, 'unknown')
  const markup = agentRows.find(row =>
    row.title === '<b>Long markup-like agent name that must stay plain text</b>')
  assert.ok(markup)
  assert.equal(markup.agentKind, 'codex')
  assert.equal(markup.status, 'working')
  const missingKind = agentRows.find(row => row.agentId && String(row.agentId).endsWith('work-1'))
  assert.ok(missingKind)
  assert.equal(missingKind.agentKind, '')

  // Folded: children hidden; counts remain on parent. No new subscription field.
  const folded = plain(Sidebar.project({
    desktop,
    screens: f.screens,
    monitors: f.monitors,
    monitorOrder: [],
    pinned: f.settings.pinned,
    hiddenApplications: f.settings.hiddenApplications,
    registry,
    folds: { [herdrFoldKey]: true },
    collapsed: false,
    herdrSnapshot: snapshot,
    herdrAssociations: associations,
    herdrAssociationsVerified: true,
  }))
  const foldedParent = folded.rows.find(row => row.key === windowKey)
  assert.equal(foldedParent.herdrFolded, true)
  assert.deepEqual(plain(foldedParent.herdrStatusCounts), counts)
  assert.ok(!folded.rows.some(row =>
    (row.kind === 'herdr-agent' || row.kind === 'herdr-state')
    && row.windowKey === windowKey))

  // Production layout / chevron / rail / accessible Unknown are covered by
  // tests/tst_herdr_sidebar_appearance.qml and the controller fold harness.
  assert.ok(typeof Interaction.herdrCompactLabelWidths === 'function')
  // Production Row must right-anchor full-width counters (no clip) and use the
  // shared name-width helper. Host qmltestrunner cannot load DockSidebarRow
  // (Quickshell.Widgets plugin quickshell-widgetsplugin missing).
  const rowQml = read('components/DockSidebarRow.qml')
  assert.ok(rowQml.includes('herdrCompactLabelWidths'),
    'production row uses herdrCompactLabelWidths')
  assert.ok(rowQml.includes('anchors.right: herdrFold.visible ? herdrFold.left'),
    'production counters right-anchor to the fold')
  const countersBlock = rowQml.slice(rowQml.indexOf('id: herdrCounters'),
    rowQml.indexOf('id: herdrCounters') + 700)
  assert.ok(!countersBlock.includes('clip: true'),
    'herdr counters must not clip nonzero buckets')
  assert.ok(rowQml.includes('herdrStateStripFits'),
    'state icons yield when counters need the space')
  assert.ok(rowQml.includes('objectName: "sidebar-herdr-fold"'))
  assert.ok(rowQml.includes('herdrStatusAccessibleText(row.status)'),
    'agent accessible label always includes normalized status')
}

console.log('herdr sidebar model appearance: PASS')

// --- Flat agent rows: tabs never add rows or another nesting level ---
{
  const f = sidebarFixture()
  const desktop = desktopModel.build(f.input)
  const registry = Sidebar.reconcileHandles({ nextToken: 1, entries: [] }, f.toplevels)
  const termEntry = registry.entries.find((_, i) => f.toplevels[i].id === 'terminal')
  assert.ok(termEntry)
  const windowKey = termEntry.key
  function projectAgents(agents, completeness = { state: 'complete' }) {
    return plain(Sidebar.project({
      desktop,
      screens: f.screens,
      monitors: f.monitors,
      monitorOrder: [],
      pinned: f.settings.pinned,
      hiddenApplications: f.settings.hiddenApplications,
      registry,
      folds: ({}),
      collapsed: false,
      herdrSnapshot: {
        providerEpoch: 'epoch-flat',
        servers: [{
          id: 'local-matched', health: 'live', label: 'Matched',
          transport: 'local', host: 'local', session: 'default',
          connectionGeneration: 1, capabilities: { focusAgent: true },
        }],
        agents,
        liveCounts: { agents: agents.length, complete: true },
        completeness,
      },
      herdrAssociations: {
        byWindowKey: { [windowKey]: 'local-matched' },
        unmatchedServerIds: [],
      },
      herdrAssociationsVerified: true,
    }))
  }
  const soloAgents = [
    {
      id: 'local-matched:1:pane-a',
      serverId: 'local-matched',
      connectionGeneration: 1,
      paneId: 'pane-a',
      terminalId: 'term-a',
      name: 'Agent Alpha',
      workspaceId: 'w1',
      tabId: 'w1:t-solo',
      tabTitle: 'Solo tab',
      workspaceLabel: 'smart-omarchy-dock',
      agent: 'codex',
      status: 'working',
    },
    {
      id: 'local-matched:1:pane-b',
      serverId: 'local-matched',
      connectionGeneration: 1,
      paneId: 'pane-b',
      name: 'Agent Beta',
      workspaceId: 'w1',
      tabId: 'w1:t-solo',
      tabTitle: 'Solo tab',
      workspaceLabel: 'smart-omarchy-dock',
      agent: 'claude',
      status: 'idle',
    },
  ]
  const flat = projectAgents(soloAgents)
  const flatParent = flat.rows.find(row => row.key === windowKey)
  assert.ok(flatParent)
  const flatTabs = flat.rows.filter(row => row.kind === 'herdr-tab' && row.windowKey === windowKey)
  assert.equal(flatTabs.length, 0, 'single multi-agent tab must not emit a tab header')
  const flatAgents = flat.rows.filter(row => row.kind === 'herdr-agent' && row.windowKey === windowKey)
  assert.equal(flatAgents.length, 2)
  // Sorted: idle then working; titles are agent titles, not the tab title.
  assert.deepEqual(flatAgents.map(row => row.title), ['Agent Beta', 'Agent Alpha'])
  assert.deepEqual(flatAgents.map(row => row.agentId),
    ['local-matched:1:pane-b', 'local-matched:1:pane-a'])
  assert.deepEqual(flatAgents.map(row => row.paneId), ['pane-b', 'pane-a'])
  flatAgents.forEach(row => {
    assert.equal(row.parentKey, windowKey)
    assert.equal(row.treeDepth, flatParent.treeDepth + 1)
    assert.equal(row.tabTitle, 'Solo tab')
    assert.equal(row.actionable, true)
  })
  assert.equal(flatAgents[0].subtitle, 'smart-omarchy-dock - Claude')
  assert.equal(flatAgents[1].subtitle, 'smart-omarchy-dock - Codex')

  // Adding a second tab preserves tab/pane order but still emits only agents.
  const twoTabAgents = soloAgents.concat([{
    id: 'local-matched:1:pane-c',
    serverId: 'local-matched',
    connectionGeneration: 1,
    paneId: 'pane-c',
    name: 'Agent Gamma',
    workspaceId: 'w1',
    tabId: 'w1:t-second',
    tabTitle: 'Second tab',
    workspaceLabel: 'smart-omarchy-dock',
    agent: 'opencode',
    status: 'blocked',
  }])
  const grouped = projectAgents(twoTabAgents)
  const groupedAgents = grouped.rows.filter(row => row.kind === 'herdr-agent' && row.windowKey === windowKey)
  assert.ok(!grouped.rows.some(row => row.kind === 'herdr-tab'))
  assert.equal(groupedAgents.length, 3)
  assert.deepEqual(groupedAgents.map(row => row.paneId), ['pane-c', 'pane-b', 'pane-a'])
  assert.deepEqual(groupedAgents.map(row => row.tabTitle),
    ['Second tab', 'Solo tab', 'Solo tab'])
  const regroupedAlpha = groupedAgents.find(row => row.agentId === 'local-matched:1:pane-a')
  assert.ok(regroupedAlpha)
  assert.equal(regroupedAlpha.key, flatAgents[1].key)
  assert.equal(regroupedAlpha.parentKey, windowKey)
  assert.equal(regroupedAlpha.treeDepth, flatParent.treeDepth + 1)

  // One tab with one agent is still an actionable agent row.
  const single = projectAgents([soloAgents[0]])
  const singleAgents = single.rows.filter(row => row.kind === 'herdr-agent' && row.windowKey === windowKey)
  assert.ok(!single.rows.some(row => row.kind === 'herdr-tab'))
  assert.equal(singleAgents.length, 1)
  assert.equal(singleAgents[0].paneId, 'pane-a')
  assert.equal(singleAgents[0].actionable, true)

  // Workspace order remains represented by the flat agent order.
  const crossWorkspace = projectAgents([soloAgents[0], Object.assign({}, soloAgents[1], {
    workspaceId: 'w2',
    tabId: 'w2:t-other',
    tabTitle: 'Other workspace tab',
    workspaceLabel: 'other-repo',
  })])
  const crossAgents = crossWorkspace.rows.filter(row =>
    row.kind === 'herdr-agent' && row.windowKey === windowKey)
  assert.ok(!crossWorkspace.rows.some(row => row.kind === 'herdr-tab'))
  assert.equal(crossAgents.length, 2)
  assert.deepEqual(crossAgents.map(row => row.workspaceLabel),
    ['other-repo', 'smart-omarchy-dock'])

  // Partial inventory still reports its state row after the flattened agents.
  const partial = projectAgents(soloAgents, { state: 'partial' })
  const partialChildren = partial.rows.filter(row =>
    row.windowKey === windowKey && row.kind !== 'window')
  assert.deepEqual(partialChildren.map(row => row.kind),
    ['herdr-agent', 'herdr-agent', 'herdr-state'])
  assert.equal(partialChildren[2].status, 'partial')

  // Id-less agents are dropped by grouping; the valid pane remains an agent row.
  const idless = projectAgents([soloAgents[0], Object.assign({}, soloAgents[1], { id: '' })])
  const idlessAgents = idless.rows.filter(row =>
    row.kind === 'herdr-agent' && row.windowKey === windowKey)
  assert.ok(!idless.rows.some(row => row.kind === 'herdr-tab'))
  assert.equal(idlessAgents.length, 1)
  assert.equal(idlessAgents[0].paneId, 'pane-a')
}

console.log('herdr flat agent rows: PASS')
