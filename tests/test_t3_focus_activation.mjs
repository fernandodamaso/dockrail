import assert from 'node:assert/strict'
import { loadModel } from './host_harness.mjs'
import { interactionFixture, qmlMethods } from './sidebar_interaction_fixture.mjs'

const T3Activation = loadModel('DockT3ActivationModel')
const ClaudeActivation = loadModel('DockClaudeActivationModel')

// Pure URL construction: exact segment encoding, strict rejection.
assert.equal(T3Activation.threadUrl('t3:env-1', 'thread-1'),
  't3code://threads/env-1/thread-1')

{
  const env = 'env:1'
  const thread = 'th%re/ad?x#y:z🎉'
  const url = T3Activation.threadUrl('t3:' + env, thread)
  assert.equal(url, 't3code://threads/' + encodeURIComponent(env)
    + '/' + encodeURIComponent(thread))
  assert.equal(url.indexOf('?'), -1, 'no query string')
  assert.equal(url.indexOf('#'), -1, 'no fragment')
  const parts = url.split('/')
  assert.equal(decodeURIComponent(parts[3]), env, 'env survives one decode')
  assert.equal(decodeURIComponent(parts[4]), thread, 'thread survives one decode')
}

// Delegated subagent paneIds are composite keys around ~130 characters and
// must survive URL construction with an exact one-decode round-trip.
{
  const pane = 'thread:delegated-task:command%3Amcp%3A3568125c-36bc-4c51-ad74-c99cfb70b4f3%3Adelegate-task%3A1f065176-dc85-4257-8b42-365890c229f8'
  assert.equal(pane.length, 129)
  const url = T3Activation.threadUrl('t3:env-1', pane)
  assert.ok(url !== '', 'accepts delegated-task composite paneId')
  assert.equal(decodeURIComponent(url.split('/')[4]), pane, 'pane survives one decode')
}

for (const bad of [
  ['t3:env-1', ''],
  ['t3:', 'thread-1'],
  ['', 'thread-1'],
  ['t3:env-1', '.'],
  ['t3:env-1', '..'],
  ['t3:.', 'thread-1'],
  ['t3:..', 'thread-1'],
  ['herdr:x', 'thread-1'],
  ['env-1', 'thread-1'],
  ['t3:env-1', 'has space\ttab'],
  ['t3:env-1', 'line\nbreak'],
  ['t3:env-1', 'del\u007Fchar'],
  ['t3:env-1', '\uD800lone'],
  ['t3:env-1', 'trail\uDFFF'],
  ['t3:env-1', 'x'.repeat(513)],
  ['t3:' + 'y'.repeat(510), 'thread-1'],
]) {
  assert.equal(T3Activation.threadUrl(bad[0], bad[1]), '',
    'rejects ' + JSON.stringify(bad))
}
assert.equal(T3Activation.threadUrl(null, 't'), '')
assert.equal(T3Activation.threadUrl('t3:e', null), '')
assert.equal(T3Activation.threadUrl('t3:e', 42), '')
// Paired surrogates (real emoji) are valid opaque identity.
assert.ok(T3Activation.threadUrl('t3:env-1', 'ok🎉') !== '')

// Controller fixture: one activation server (T3, Claude or Herdr) plus injected
// URL dispatchers. Agent rows carry the given desktopSessionId.
function activationFixture(serverId, source, desktopSessionId) {
  const f = interactionFixture()
  const windowRow = f.controller.projection.rows[0]
  const windowKey = windowRow.key
  const shared = {
    windowKey,
    providerEpoch: 'epoch-1',
    serverId,
    connectionGeneration: 1,
    nested: true,
    toplevel: windowRow.toplevel,
    address: windowRow.address,
    desktopId: '',
    workspaceIdentity: windowRow.workspaceIdentity,
    monitorIdentity: windowRow.monitorIdentity,
    transport: 'local',
    host: 'local',
    session: '',
    focusAgentSupported: true,
  }
  const agentRow = Object.assign({}, shared, {
    kind: 'herdr-agent',
    key: JSON.stringify(['herdr-agent', windowKey, serverId + ':1:thread-1']),
    agentId: serverId + ':1:thread-1',
    paneId: 'thread-1',
    terminalId: 'term-1',
    title: 'Same Title',
    actionable: true,
  })
  const secondAgent = Object.assign({}, shared, {
    kind: 'herdr-agent',
    key: JSON.stringify(['herdr-agent', windowKey, serverId + ':1:thread-2']),
    agentId: serverId + ':1:thread-2',
    paneId: 'thread-2',
    terminalId: 'term-2',
    title: 'Same Title',
    actionable: true,
  })
  f.controller.projection.rows.push(agentRow, secondAgent)
  f.controller.herdrAssociations = {
    byWindowKey: { [windowKey]: serverId }, unmatchedServerIds: [],
  }
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
    desktopSessionId,
  }))
  const liveToplevels = [windowRow.toplevel]
  const bridge = {
    snapshotReady: true,
    herdrAssociationEpoch: agentRow.providerEpoch,
    herdrAssociations: { byWindowKey: { 'bridge-window': serverId }, unmatchedServerIds: [] },
    snapshot: {
      servers: [{ id: serverId, source, capabilities: { focusAgent: true } }],
      agents: canonicalAgents,
    },
    raises: 0,
    raiseSucceeds: true,
    windowKeyFor(toplevel) { return liveToplevels.includes(toplevel) ? 'bridge-window' : '' },
    addressFor() { return windowRow.address },
    isAlive(toplevel) { return liveToplevels.includes(toplevel) },
    currentAgent(windowKeyValue, agentId) {
      if (windowKeyValue !== 'bridge-window'
          || this.herdrAssociations.byWindowKey[windowKeyValue] !== serverId) return null
      return canonicalAgents.find(agent => agent.id === agentId) || null
    },
  }
  const windowActions = {
    isAlive(toplevel) { return liveToplevels.includes(toplevel) },
    addressFor() { return windowRow.address },
    activateToplevel(toplevel) {
      if (!liveToplevels.includes(toplevel) || !bridge.raiseSucceeds) return false
      bridge.raises += 1
      return true
    },
  }
  const dispatches = []
  const claudeDispatches = []
  const HerdrModel = loadModel('DockHerdrModel')
  const agentActions = qmlMethods('DockHerdrAgentActions.qml', {
    HerdrModel,
    T3Activation,
    ClaudeActivation,
    Qt: { openUrlExternally() { return false } },
    bridge,
    windowActions,
    herdrService: provider,
    latestFocusRequestId: '',
    pendingFocusByRequest: {},
    pendingFocusByAgent: {},
    focusErrors: {},
    focusErrorTimer: { restart() {}, stop() {} },
  })
  agentActions.openT3ThreadUrl = url => {
    dispatches.push(String(url))
    return true
  }
  agentActions.openClaudeSessionUrl = url => {
    claudeDispatches.push(String(url))
    return true
  }
  f.controller.herdrAgentActions = agentActions
  f.bridge = bridge
  f.windowActions = windowActions
  f.focusCalls = focusCalls
  f.dispatches = dispatches
  f.claudeDispatches = claudeDispatches
  f.canonicalAgents = canonicalAgents
  f.agentActions = agentActions
  f.agentRow = agentRow
  f.secondAgent = secondAgent
  f.windowKey = windowKey
  f.liveToplevels = liveToplevels
  return f
}

function t3Fixture() {
  return activationFixture('t3:env-1', 't3', '')
}

// First success raises and revalidates with zero dispatches; second success
// dispatches exactly one URL built from serverId plus raw paneId, even with a
// composite agentId and duplicate titles.
{
  const f = t3Fixture()
  const target = f.agentActions.captureAgentTarget(f.agentRow.toplevel, f.agentRow)
  assert.ok(target)
  assert.equal(f.agentActions.activateHerdrTarget(target), true)
  assert.equal(f.focusCalls.length, 1)
  assert.equal(f.dispatches.length, 0)
  f.agentActions.onHerdrFocusFinished('focus-1', true, '')
  assert.equal(f.bridge.raises, 1)
  assert.equal(f.focusCalls.length, 2, 'second validation requested')
  assert.equal(f.dispatches.length, 0, 'no dispatch before second validation')
  f.agentActions.onHerdrFocusFinished('focus-2', true, '')
  assert.equal(f.dispatches.length, 1)
  assert.equal(f.dispatches[0], 't3code://threads/env-1/thread-1')
  assert.equal(f.claudeDispatches.length, 0, 'T3 never dispatches Claude routes')
  assert.equal(f.focusCalls.length, 2, 'no third provider call')
  assert.equal(f.bridge.raises, 1, 'no second raise')
}

// Herdr second success keeps existing focus/raise/refocus with zero URLs.
{
  const f = t3Fixture()
  f.bridge.snapshot.servers[0] = { id: 't3:env-1', capabilities: { focusAgent: true } }
  const target = f.agentActions.captureAgentTarget(f.agentRow.toplevel, f.agentRow)
  assert.ok(target)
  assert.equal(f.agentActions.activateHerdrTarget(target), true)
  f.agentActions.onHerdrFocusFinished('focus-1', true, '')
  assert.equal(f.focusCalls.length, 2)
  f.agentActions.onHerdrFocusFinished('focus-2', true, '')
  assert.equal(f.dispatches.length, 0, 'Herdr rows never dispatch thread URLs')
  assert.equal(f.bridge.raises, 1)
}

// First provider failure: no raise, no dispatch, error recorded.
{
  const f = t3Fixture()
  const target = f.agentActions.captureAgentTarget(f.agentRow.toplevel, f.agentRow)
  f.agentActions.activateHerdrTarget(target)
  f.agentActions.onHerdrFocusFinished('focus-1', false, 'agent_gone')
  assert.equal(f.bridge.raises, 0)
  assert.equal(f.dispatches.length, 0)
  assert.equal(f.agentActions.focusErrorFor(f.agentRow.key), 'agent_gone')
}

// Second provider failure: raised window stays, no dispatch.
{
  const f = t3Fixture()
  const target = f.agentActions.captureAgentTarget(f.agentRow.toplevel, f.agentRow)
  f.agentActions.activateHerdrTarget(target)
  f.agentActions.onHerdrFocusFinished('focus-1', true, '')
  assert.equal(f.bridge.raises, 1)
  f.agentActions.onHerdrFocusFinished('focus-2', false, 'agent_gone')
  assert.equal(f.dispatches.length, 0)
  assert.equal(f.agentActions.focusErrorFor(f.agentRow.key), 'agent_gone')
}

// Dispatch rejection keeps the raised window and records unsupported.
{
  const f = t3Fixture()
  f.agentActions.openT3ThreadUrl = url => {
    f.dispatches.push(String(url))
    return false
  }
  const target = f.agentActions.captureAgentTarget(f.agentRow.toplevel, f.agentRow)
  f.agentActions.activateHerdrTarget(target)
  f.agentActions.onHerdrFocusFinished('focus-1', true, '')
  f.agentActions.onHerdrFocusFinished('focus-2', true, '')
  assert.equal(f.dispatches.length, 1)
  assert.equal(f.dispatches[0], 't3code://threads/env-1/thread-1')
  assert.equal(f.bridge.raises, 1, 'raised window is retained')
  assert.equal(f.agentActions.focusErrorFor(f.agentRow.key), 'unsupported')
}

// Unavailable dispatcher never throws and records unsupported.
{
  const f = t3Fixture()
  f.agentActions.openT3ThreadUrl = null
  const target = f.agentActions.captureAgentTarget(f.agentRow.toplevel, f.agentRow)
  f.agentActions.activateHerdrTarget(target)
  f.agentActions.onHerdrFocusFinished('focus-1', true, '')
  f.agentActions.onHerdrFocusFinished('focus-2', true, '')
  assert.equal(f.dispatches.length, 0)
  assert.equal(f.agentActions.focusErrorFor(f.agentRow.key), 'unsupported')
}

// Failed raise performs no second validation and no dispatch.
{
  const f = t3Fixture()
  f.bridge.raiseSucceeds = false
  const target = f.agentActions.captureAgentTarget(f.agentRow.toplevel, f.agentRow)
  f.agentActions.activateHerdrTarget(target)
  f.agentActions.onHerdrFocusFinished('focus-1', true, '')
  assert.equal(f.bridge.raises, 0)
  assert.equal(f.focusCalls.length, 1)
  assert.equal(f.dispatches.length, 0)
}

// Source disabled between validations: stale target dispatches nothing.
{
  const f = t3Fixture()
  const target = f.agentActions.captureAgentTarget(f.agentRow.toplevel, f.agentRow)
  f.agentActions.activateHerdrTarget(target)
  f.bridge.snapshot.servers[0].capabilities.focusAgent = false
  f.agentActions.onHerdrFocusFinished('focus-1', true, '')
  assert.equal(f.bridge.raises, 0)
  assert.equal(f.dispatches.length, 0)
}

// Generation, epoch, thread-removal, window-closure and address changes all
// fail closed without dispatching or substituting another thread.
for (const mutate of [
  f => { f.canonicalAgents[0].connectionGeneration = 2 },
  f => { f.bridge.herdrAssociationEpoch = 'epoch-2' },
  f => { f.canonicalAgents.splice(0, 1) },
  f => { f.liveToplevels.length = 0 },
]) {
  const f = t3Fixture()
  const target = f.agentActions.captureAgentTarget(f.agentRow.toplevel, f.agentRow)
  f.agentActions.activateHerdrTarget(target)
  f.agentActions.onHerdrFocusFinished('focus-1', true, '')
  mutate(f)
  f.agentActions.onHerdrFocusFinished('focus-2', true, '')
  assert.equal(f.dispatches.length, 0, 'stale target must not dispatch')
}
{
  const f = t3Fixture()
  const target = f.agentActions.captureAgentTarget(f.agentRow.toplevel, f.agentRow)
  f.agentActions.activateHerdrTarget(target)
  f.agentActions.onHerdrFocusFinished('focus-1', true, '')
  f.bridge.addressFor = () => '0xREPLACED'
  f.agentActions.onHerdrFocusFinished('focus-2', true, '')
  assert.equal(f.dispatches.length, 0, 'address replacement must not dispatch')
}

// Repeated clicks coalesce to one pending request and one dispatch.
{
  const f = t3Fixture()
  const target = f.agentActions.captureAgentTarget(f.agentRow.toplevel, f.agentRow)
  assert.equal(f.agentActions.activateHerdrTarget(target), true)
  assert.equal(f.agentActions.activateHerdrTarget(target), true)
  assert.equal(f.focusCalls.length, 1, 'duplicate click coalesces')
  f.agentActions.onHerdrFocusFinished('focus-1', true, '')
  f.agentActions.onHerdrFocusFinished('focus-2', true, '')
  assert.equal(f.dispatches.length, 1)
}

// A/B out of order: delayed A dispatches nothing; B dispatches its own URL.
{
  const f = t3Fixture()
  const a = f.agentActions.captureAgentTarget(f.agentRow.toplevel, f.agentRow)
  const b = f.agentActions.captureAgentTarget(f.secondAgent.toplevel, f.secondAgent)
  f.agentActions.activateHerdrTarget(a)
  f.agentActions.activateHerdrTarget(b)
  assert.equal(f.focusCalls.length, 2)
  f.agentActions.onHerdrFocusFinished('focus-1', true, '')
  assert.equal(f.bridge.raises, 0, 'superseded A must not raise')
  assert.equal(f.dispatches.length, 0)
  f.agentActions.onHerdrFocusFinished('focus-2', true, '')
  assert.equal(f.bridge.raises, 1)
  assert.equal(f.focusCalls.length, 3)
  f.agentActions.onHerdrFocusFinished('focus-3', true, '')
  assert.deepEqual(f.dispatches, ['t3code://threads/env-1/thread-2'])
}

// Claude sessions: the raised window opens the Claude Desktop session route
// exactly once after the second validation; no thread URL and no third call.
const CLAUDE_SESSION = 'local_9c9eb232-bfa0-4023-ac76-79aee015b3c5'
{
  const f = activationFixture('claude:local', 'claude', CLAUDE_SESSION)
  const target = f.agentActions.captureAgentTarget(f.agentRow.toplevel, f.agentRow)
  assert.ok(target)
  assert.equal(target.desktopSessionId, CLAUDE_SESSION)
  assert.equal(f.agentActions.activateHerdrTarget(target), true)
  f.agentActions.onHerdrFocusFinished('focus-1', true, '')
  assert.equal(f.bridge.raises, 1)
  assert.equal(f.claudeDispatches.length, 0, 'no dispatch before second validation')
  f.agentActions.onHerdrFocusFinished('focus-2', true, '')
  assert.deepEqual(f.claudeDispatches, ['claude://code/continue?session=' + CLAUDE_SESSION])
  assert.equal(f.dispatches.length, 0, 'Claude never dispatches thread URLs')
  assert.equal(f.focusCalls.length, 2, 'no third provider call')
  assert.equal(f.bridge.raises, 1, 'no second raise')
  assert.equal(f.agentActions.focusErrorFor(f.agentRow.key), '')
}

// Unknown desktopSessionId: the raised window is success; nothing opens and no
// error is recorded.
{
  const f = activationFixture('claude:local', 'claude', '')
  const target = f.agentActions.captureAgentTarget(f.agentRow.toplevel, f.agentRow)
  assert.ok(target)
  assert.equal(target.desktopSessionId, '')
  f.agentActions.activateHerdrTarget(target)
  f.agentActions.onHerdrFocusFinished('focus-1', true, '')
  f.agentActions.onHerdrFocusFinished('focus-2', true, '')
  assert.equal(f.bridge.raises, 1)
  assert.equal(f.claudeDispatches.length, 0)
  assert.equal(f.dispatches.length, 0)
  assert.equal(f.agentActions.focusErrorFor(f.agentRow.key), '')
}

// Rejected, unavailable and throwing dispatchers record unsupported and keep
// the raised window.
for (const opener of [
  url => { return false },
  null,
  url => { throw new Error('boom') },
]) {
  const f = activationFixture('claude:local', 'claude', CLAUDE_SESSION)
  f.agentActions.openClaudeSessionUrl = opener
  const target = f.agentActions.captureAgentTarget(f.agentRow.toplevel, f.agentRow)
  f.agentActions.activateHerdrTarget(target)
  f.agentActions.onHerdrFocusFinished('focus-1', true, '')
  f.agentActions.onHerdrFocusFinished('focus-2', true, '')
  assert.equal(f.bridge.raises, 1, 'raised window is retained')
  assert.equal(f.claudeDispatches.length, 0)
  assert.equal(f.agentActions.focusErrorFor(f.agentRow.key), 'unsupported')
}

// Stale Claude target after the raise opens nothing.
{
  const f = activationFixture('claude:local', 'claude', CLAUDE_SESSION)
  const target = f.agentActions.captureAgentTarget(f.agentRow.toplevel, f.agentRow)
  f.agentActions.activateHerdrTarget(target)
  f.agentActions.onHerdrFocusFinished('focus-1', true, '')
  f.canonicalAgents[0].connectionGeneration = 2
  f.agentActions.onHerdrFocusFinished('focus-2', true, '')
  assert.equal(f.claudeDispatches.length, 0, 'stale Claude target must not dispatch')
}

// Herdr servers never open Claude or T3 routes, even with a session id present.
{
  const f = activationFixture('local-h', undefined, CLAUDE_SESSION)
  const target = f.agentActions.captureAgentTarget(f.agentRow.toplevel, f.agentRow)
  assert.ok(target)
  f.agentActions.activateHerdrTarget(target)
  f.agentActions.onHerdrFocusFinished('focus-1', true, '')
  f.agentActions.onHerdrFocusFinished('focus-2', true, '')
  assert.equal(f.bridge.raises, 1)
  assert.equal(f.claudeDispatches.length, 0)
  assert.equal(f.dispatches.length, 0)
  assert.equal(f.agentActions.focusErrorFor(f.agentRow.key), '')
}

console.log('t3 focus activation: PASS')
