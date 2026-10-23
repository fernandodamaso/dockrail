import assert from 'node:assert/strict'
import { loadModel, plain } from './host_harness.mjs'

const Model = loadModel('DockAgentSourceModel')
const merge = (entries, epoch, revision) =>
  plain(Model.mergeSnapshots(entries, epoch, revision))

function snapshot(epoch, revision, servers, agents, extra) {
  return Object.assign({
    schemaVersion: 1,
    providerEpoch: epoch,
    revision,
    capabilities: { focusAgent: true },
    servers,
    agents: agents || [],
    attention: [],
    liveCounts: { blocked: 0, agents: (agents || []).length },
    completeness: { state: 'complete' },
    windowProcesses: { revision: 0, identities: [] },
  }, extra || {})
}

function server(id, extra) {
  return Object.assign({ id, clients: [] }, extra || {})
}

// compositeEpoch ordering and exclusion.
{
  const sources = [
    { id: 'herdr', epoch: 'e1', enabled: true, running: true },
    { id: 't3', epoch: '', enabled: true, running: true },
    { id: 't3', epoch: 'e2', enabled: false, running: true },
    { id: 't3', epoch: 'e3', enabled: true, running: false },
    { id: 't3', epoch: 'e4', enabled: true, running: true },
  ]
  assert.equal(Model.compositeEpoch(sources), 'herdr=e1|t3=e4')
  assert.equal(Model.compositeEpoch([]), '')
  assert.equal(Model.compositeEpoch(null), '')
}

// sourceIdForServerId prefix rule.
{
  assert.equal(Model.sourceIdForServerId('t3:env-1'), 't3')
  assert.equal(Model.sourceIdForServerId('t3:unpaired'), 't3')
  assert.equal(Model.sourceIdForServerId('local-a'), 'herdr')
  assert.equal(Model.sourceIdForServerId(''), 'herdr')
  assert.equal(Model.sourceIdForServerId(null), 'herdr')
}

// Single-source merge equals the source apart from epoch/revision/stamps.
{
  const child = snapshot('child-epoch', 7, [server('local-a')], [{ id: 'a' }])
  const merged = merge([{ id: 'herdr', snapshot: child }], 'mux-epoch', 3)
  assert.equal(merged.schemaVersion, 1)
  assert.equal(merged.providerEpoch, 'mux-epoch')
  assert.equal(merged.revision, 3)
  assert.deepEqual(merged.agents, [{ id: 'a' }])
  assert.deepEqual(merged.liveCounts, child.liveCounts)
  assert.deepEqual(merged.completeness, child.completeness)
  assert.equal(merged.sourceErrorCode, undefined)
  assert.equal(merged.servers.length, 1)
  assert.equal(merged.servers[0].id, 'local-a')
  assert.equal(merged.servers[0].source, 'herdr')
  assert.equal(merged.servers[0].providerEpoch, 'child-epoch')
  assert.deepEqual(merged.servers[0].sourceCompleteness, child.completeness)
  assert.equal(merged.servers[0].sourceLiveCountsKnown, true)
  assert.deepEqual(merged.windowProcesses, { revision: 0, identities: [] })
}

// Mismatched window-process revisions merge to -1 with no identities.
{
  const a = snapshot('e', 1, [], [], { windowProcesses: { revision: 5, identities: [{ pid: 1 }] } })
  const b = snapshot('e', 1, [], [], { windowProcesses: { revision: 6, identities: [{ pid: 1 }] } })
  const merged = merge([{ id: 'herdr', snapshot: a }, { id: 't3', snapshot: b }], 'mux', 1)
  assert.deepEqual(merged.windowProcesses, { revision: -1, identities: [] })
}

// Matching revisions union identities deduped by pid.
{
  const a = snapshot('e', 1, [], [], {
    windowProcesses: { revision: 5, identities: [{ pid: 1 }, { pid: 2 }] },
  })
  const b = snapshot('e', 1, [], [], {
    windowProcesses: { revision: 5, identities: [{ pid: 2 }, { pid: 3 }] },
  })
  const merged = merge([{ id: 'herdr', snapshot: a }, { id: 't3', snapshot: b }], 'mux', 1)
  assert.deepEqual(merged.windowProcesses,
    { revision: 5, identities: [{ pid: 1 }, { pid: 2 }, { pid: 3 }] })
}

// Top-level copy comes from Herdr even when T3 is truncated or erroring.
{
  const herdr = snapshot('he', 1, [server('local-a')], [{ id: 'h' }])
  const t3 = snapshot('te', 2, [server('t3:env', { source: 't3' })], [{ id: 't' }], {
    liveCounts: null,
    completeness: { state: 'partial', truncated: true, agentTruncated: true },
    sourceErrorCode: 'normalized_output_too_large',
  })
  const merged = merge([{ id: 'herdr', snapshot: herdr }, { id: 't3', snapshot: t3 }], 'mux', 9)
  assert.deepEqual(merged.liveCounts, herdr.liveCounts)
  assert.deepEqual(merged.completeness, herdr.completeness)
  assert.equal(merged.sourceErrorCode, undefined)
  assert.equal(merged.agents.length, 2)
  assert.equal(merged.servers.length, 2)
  assert.equal(merged.servers[1].source, 't3')
  assert.equal(merged.servers[1].sourceLiveCountsKnown, false)
  assert.deepEqual(merged.servers[1].sourceCompleteness, t3.completeness)
}

// T3-only merge takes top-level copy from T3.
{
  const t3 = snapshot('te', 2, [server('t3:env', { source: 't3' })], [], {
    sourceErrorCode: 'normalized_output_too_large',
  })
  const merged = merge([{ id: 't3', snapshot: t3 }], 'mux', 1)
  assert.equal(merged.sourceErrorCode, 'normalized_output_too_large')
  assert.deepEqual(merged.liveCounts, t3.liveCounts)
}

// Status merge table.
{
  assert.equal(Model.mergeStatus(['ready', 'loading']), 'ready')
  assert.equal(Model.mergeStatus(['loading', 'unavailable']), 'loading')
  assert.equal(Model.mergeStatus(['unavailable', 'error']), 'unavailable')
  assert.equal(Model.mergeStatus(['error']), 'error')
  assert.equal(Model.mergeStatus([]), 'error')
}

console.log('test_agent_source_model: all assertions passed')
