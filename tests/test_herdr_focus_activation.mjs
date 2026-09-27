import assert from 'node:assert/strict'
import { loadModel } from './host_harness.mjs'
import { interactionFixture, qmlMethods } from './sidebar_interaction_fixture.mjs'

function herdrFixture() {
  const f = interactionFixture()
  const windowRow = f.controller.projection.rows[0]
  const windowKey = windowRow.key
  const agentKey = JSON.stringify(['herdr-agent', windowKey, 'srv:1:pane-a'])
  const secondAgentKey = JSON.stringify(['herdr-agent', windowKey, 'srv:1:pane-b'])
  const shared = {
    windowKey,
    providerEpoch: 'epoch-1',
    serverId: 'srv',
    connectionGeneration: 1,
    nested: true,
    toplevel: windowRow.toplevel,
    address: windowRow.address,
    desktopId: '',
    workspaceIdentity: windowRow.workspaceIdentity,
    monitorIdentity: windowRow.monitorIdentity,
    transport: 'local',
    host: 'local',
    session: 'default',
    focusAgentSupported: true,
  }
  const agentRow = Object.assign({}, shared, {
    kind: 'herdr-agent',
    key: agentKey,
    agentId: 'srv:1:pane-a',
    paneId: 'pane-a',
    terminalId: 'term-a',
    actionable: true,
  })
  const secondAgent = Object.assign({}, shared, {
    kind: 'herdr-agent',
    key: secondAgentKey,
    agentId: 'srv:1:pane-b',
    paneId: 'pane-b',
    terminalId: 'term-b',
    actionable: true,
  })
  f.controller.projection.rows.push(agentRow, secondAgent)
  f.controller.herdrAssociations = { byWindowKey: { [windowKey]: 'srv' }, unmatchedServerIds: [] }
  const focusCalls = []
  let focusSeq = 0
  const provider = {
    focusAgent(target) {
      focusCalls.push(Object.assign({}, target))
      focusSeq += 1
      return 'focus-' + String(focusSeq)
    },
  }
  f.controller.host.herdrService = provider
  const canonicalAgents = [agentRow, secondAgent].map(row => ({
    id: row.agentId,
    serverId: row.serverId,
    connectionGeneration: row.connectionGeneration,
    paneId: row.paneId,
    terminalId: row.terminalId,
  }))
  const canonicalAgent = canonicalAgents[0]
  const bridge = {
    snapshotReady: true,
    herdrAssociationEpoch: agentRow.providerEpoch,
    herdrAssociations: { byWindowKey: { 'bridge-window': 'srv' }, unmatchedServerIds: [] },
    snapshot: {
      servers: [{ id: 'srv', capabilities: { focusAgent: true } }],
      agents: canonicalAgents,
    },
    windowKeyFor(toplevel) { return f.ToplevelManager.toplevels.values.includes(toplevel) ? 'bridge-window' : '' },
    addressFor(toplevel) { return f.actions.addressFor(toplevel) },
    isAlive(toplevel) { return f.ToplevelManager.toplevels.values.includes(toplevel) },
    currentAgent(windowKeyValue, agentId) {
      if (windowKeyValue !== 'bridge-window'
          || this.herdrAssociations.byWindowKey[windowKeyValue] !== 'srv') return null
      return canonicalAgents.find(agent => agent.id === agentId) || null
    },
  }
  const agentActions = qmlMethods('DockHerdrAgentActions.qml', {
    HerdrModel: loadModel('DockHerdrModel'),
    bridge, windowActions: f.actions, herdrService: provider,
    latestFocusRequestId: '', pendingFocusByRequest: {}, pendingFocusByAgent: {},
    focusErrors: {}, focusErrorTimer: { restart() {}, stop() {} },
  })
  f.controller.herdrAgentActions = agentActions
  f.focusCalls = focusCalls
  f.bridge = bridge
  f.canonicalAgent = canonicalAgent
  f.agentActions = agentActions
  f.agentRow = agentRow
  f.secondAgent = secondAgent
  f.windowKey = windowKey
  return f
}

// All entry points share the action owner, including cached preview/menu targets.
for (const change of [
  { connected: true, version: '0.8.2' },
  { connected: true, version: '0.9.0' },
  { capabilities: { focusAgent: false } },
]) {
  const fixture = herdrFixture()
  const target = fixture.controller.captureTarget(fixture.agentRow.key)
  assert.ok(target)
  Object.assign(fixture.bridge.snapshot.servers[0], change)
  assert.equal(fixture.agentActions.captureAgentTarget(
    fixture.agentRow.toplevel, fixture.agentRow), null,
  'known unsupported servers cannot produce focus targets')
  assert.equal(fixture.agentActions.targetIsCurrent(target), false,
    'a captured target must recheck current server support')
  assert.equal(fixture.agentActions.activateHerdrTarget(target), false)
  assert.equal(fixture.focusCalls.length, 0)
}

const f = herdrFixture()
const c = f.controller

function contextMenuFor(fixture) {
  const menu = qmlMethods('DockContextMenu.qml', {
    herdrAgentActions: fixture.agentActions,
    sidebarMode: false,
    externalTargetValidator: null,
  })
  menu.dismiss = () => { menu.dismissed = true }
  return menu
}

const captured = c.captureTarget(f.agentRow.key)
assert.ok(captured)
assert.equal(captured.paneId, 'pane-a')
assert.equal(c.dragSourceLocation(captured), null, 'herdr rows are not drag sources')

assert.equal(c.activateTarget(captured, false, 'DP-1', 0), true)
assert.equal(f.focusCalls.length, 1)
assert.equal(f.agentActions.latestFocusRequestId, 'focus-1')
assert.equal(f.focusCalls[0].paneId, 'pane-a')
// First activation does not raise yet — waits for focus success.
assert.equal(f.requests.length + f.batches.length, 0)

// The context-menu route works without a mapped sidebar and delegates to the
// host-owned exact-target handler rather than raising a window itself.
const menuOnly = herdrFixture()
const menuOnlyTarget = menuOnly.agentActions.captureAgentTarget(
  menuOnly.agentRow.toplevel, menuOnly.agentRow)
const menu = contextMenuFor(menuOnly)
assert.equal(menu.dispatchAction({
  kind: 'agent', enabled: true, target: menuOnlyTarget
}, 0), true)
assert.equal(menu.dismissed, true)
assert.equal(menuOnly.focusCalls.length, 1)
assert.equal(menuOnly.requests.length + menuOnly.batches.length, 0,
  'menu focus does not raise before provider confirmation')

// Modifier on release → no focus.
f.focusCalls.length = 0
assert.equal(c.activateTarget(captured, false, 'DP-1', 1), false)
assert.equal(f.focusCalls.length, 0)
assert.equal(c.activateTarget(captured, true, 'DP-1', 0), false)

// Same-agent coalesce while pending.
assert.equal(c.activateTarget(captured, false, 'DP-1', 0), true)
assert.equal(f.focusCalls.length, 0, 'duplicate same-agent request coalesces')

// Success raises window then re-focuses to defeat tab restore.
f.focusCalls.length = 0
f.clear()
f.agentActions.onHerdrFocusFinished('focus-1', true, '')
assert.match(JSON.stringify(f.requests.concat(f.batches)), /focuswindow|0x1/)
assert.equal(f.focusCalls.length, 1, 'confirm focus after raise')
assert.equal(f.focusCalls[0].paneId, 'pane-a')
assert.equal(f.agentActions.latestFocusRequestId, 'focus-2')
f.focusCalls.length = 0
f.clear()
f.agentActions.onHerdrFocusFinished('focus-2', true, '')
assert.equal(f.requests.length + f.batches.length, 0, 'confirm success does not raise again')
assert.equal(f.focusCalls.length, 0)

// Removal between press/release.
const gone = herdrFixture()
const goneTarget = gone.controller.captureTarget(gone.agentRow.key)
gone.ToplevelManager.toplevels.values = []
assert.equal(gone.controller.activateTarget(goneTarget, false, 'DP-1', 0), false)
assert.equal(gone.focusCalls.length, 0)

// A same-address replacement cannot inherit a menu-open capture and no raise
// is attempted through either the menu or the exact-target handler.
const replaced = herdrFixture()
const replacedTarget = replaced.agentActions.captureAgentTarget(
  replaced.agentRow.toplevel, replaced.agentRow)
const replacedWindow = { appId: 'editor', title: 'replacement' }
replaced.ToplevelManager.toplevels.values = [replacedWindow]
replaced.handles[0].wayland = replacedWindow
const replacedMenu = contextMenuFor(replaced)
assert.equal(replacedMenu.dispatchAction({
  kind: 'agent', enabled: true, target: replacedTarget
}, 0), false)
assert.equal(replaced.focusCalls.length, 0)
assert.equal(replaced.requests.length + replaced.batches.length, 0,
  'stale menu target is rejected without raising the replacement')

// A then B: delayed A must not raise after B.
const race = herdrFixture()
const a = race.controller.captureTarget(race.agentRow.key)
const b = race.controller.captureTarget(race.secondAgent.key)
assert.equal(race.controller.activateTarget(a, false, 'DP-1', 0), true)
assert.equal(race.controller.activateTarget(b, false, 'DP-1', 0), true)
assert.equal(race.focusCalls.length, 2)
assert.equal(race.agentActions.latestFocusRequestId, 'focus-2')
race.focusCalls.length = 0
race.clear()
race.agentActions.onHerdrFocusFinished('focus-1', true, '')
assert.equal(race.requests.length + race.batches.length, 0, 'delayed A must not raise after B')
assert.equal(race.focusCalls.length, 0)
race.agentActions.onHerdrFocusFinished('focus-2', true, '')
assert.match(JSON.stringify(race.requests.concat(race.batches)), /focuswindow|0x1/)
assert.equal(race.focusCalls.length, 1)
assert.equal(race.focusCalls[0].paneId, 'pane-b')

// Failure sets fixed error code only.
const fail = herdrFixture()
const failTarget = fail.controller.captureTarget(fail.agentRow.key)
assert.equal(fail.controller.activateTarget(failTarget, false, 'DP-1', 0), true)
fail.agentActions.onHerdrFocusFinished('focus-1', false, 'agent_gone')
assert.equal(fail.controller.herdrFocusErrorFor(fail.agentRow.key), 'agent_gone')
assert.deepEqual(Object.keys(fail.agentActions.pendingFocusByRequest), [])
assert.deepEqual(Object.keys(fail.agentActions.pendingFocusByAgent), [])

// Capability false or absent: visible row data may exist, but capture/focus is inert.
const unsupported = herdrFixture()
unsupported.agentRow.actionable = false
unsupported.agentRow.focusAgentSupported = false
unsupported.bridge.snapshot.servers[0].capabilities.focusAgent = false
assert.equal(unsupported.controller.captureTarget(unsupported.agentRow.key), null)
assert.equal(unsupported.focusCalls.length, 0)
assert.deepEqual(Object.keys(unsupported.agentActions.pendingFocusByRequest), [])

const absent = herdrFixture()
delete absent.secondAgent.focusAgentSupported
absent.bridge.snapshot.servers[0].capabilities.focusAgent = false
assert.equal(absent.controller.captureTarget(absent.secondAgent.key), null)
assert.equal(absent.focusCalls.length, 0)

// Reconnect/generation change invalidates an already captured action identity.
const staleGeneration = herdrFixture()
const staleTarget = staleGeneration.controller.captureTarget(staleGeneration.agentRow.key)
assert.ok(staleTarget)
staleGeneration.canonicalAgent.connectionGeneration = 2
assert.equal(staleGeneration.controller.activateTarget(staleTarget, false, 'DP-1', 0), false)
assert.equal(staleGeneration.focusCalls.length, 0)

// Server/association disappearance also fails closed without enqueuing.
const serverGone = herdrFixture()
const serverGoneTarget = serverGone.controller.captureTarget(serverGone.agentRow.key)
assert.ok(serverGoneTarget)
serverGone.bridge.herdrAssociations = { byWindowKey: {}, unmatchedServerIds: ['srv'] }
assert.equal(serverGone.controller.activateTarget(serverGoneTarget, false, 'DP-1', 0), false)
assert.equal(serverGone.focusCalls.length, 0)

// A source-level supported-remote fixture follows the same exact identity path.
// FDM-980 still advertises real remote servers as unsupported until qualified.
const remoteSupported = herdrFixture()
remoteSupported.agentRow.transport = 'remote'
remoteSupported.agentRow.host = 'devbox'
remoteSupported.agentRow.session = 'review'
const remoteTarget = remoteSupported.controller.captureTarget(remoteSupported.agentRow.key)
assert.ok(remoteTarget)
assert.equal(remoteSupported.controller.activateTarget(remoteTarget, false, 'DP-1', 0), true)
assert.equal(remoteSupported.focusCalls.length, 1)
assert.deepEqual(remoteSupported.focusCalls[0], {
  providerEpoch: 'epoch-1',
  serverId: 'srv',
  connectionGeneration: 1,
  agentId: 'srv:1:pane-a',
  paneId: 'pane-a',
  terminalId: 'term-a',
})

// Immediate provider rejection never creates pending UI state.
const rejected = herdrFixture()
rejected.controller.host.herdrService.focusAgent = () => ''
rejected.agentActions.herdrService = rejected.controller.host.herdrService
const rejectedTarget = rejected.controller.captureTarget(rejected.agentRow.key)
assert.ok(rejectedTarget)
assert.equal(rejected.controller.activateTarget(rejectedTarget, false, 'DP-1', 0), false)
assert.deepEqual(Object.keys(rejected.agentActions.pendingFocusByRequest), [])
assert.deepEqual(Object.keys(rejected.agentActions.pendingFocusByAgent), [])

console.log('herdr focus activation: PASS')
