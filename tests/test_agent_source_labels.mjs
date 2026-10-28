import assert from 'node:assert/strict'
import { loadModel } from './host_harness.mjs'

const Model = loadModel('DockHerdrModel')

const herdrServer = { id: 'local-a', label: 'Local Herdr' }
const t3Server = { source: 't3', product: 'T3 Code', label: 'T3 Code' }
const t3Bare = { source: 't3' }

for (const candidate of [{}, null, herdrServer]) {
  assert.equal(Model.serverSource(candidate), 'herdr')
  assert.equal(Model.serverProduct(candidate), 'Herdr')
  assert.equal(Model.agentNoun(candidate), 'agent')
  assert.equal(Model.focusHint(candidate), 'Click a row to focus its pane.')
}

for (const candidate of [t3Server, t3Bare]) {
  assert.equal(Model.serverSource(candidate), 't3')
  assert.equal(Model.serverProduct(candidate), 'T3 Code')
  assert.equal(Model.agentNoun(candidate), 'thread')
  assert.equal(Model.focusHint(candidate), 'Click a row to open this thread in T3 Code.')
}

assert.equal(Model.serverProduct({ source: 't3', product: '  ' }), 'T3 Code')

for (const candidate of [{ source: 'claude', product: 'Claude' }, { source: 'claude' }]) {
  assert.equal(Model.serverSource(candidate), 'claude')
  assert.equal(Model.serverProduct(candidate), 'Claude')
  assert.equal(Model.agentNoun(candidate), 'session')
  assert.equal(Model.serverFocusAgentSupported(
    Object.assign({ capabilities: { focusAgent: false } }, candidate)), false)
}

const SourceModel = loadModel('DockAgentSourceModel')
assert.equal(SourceModel.sourceIdForServerId('claude:desktop'), 'claude')
assert.equal(SourceModel.sourceIdForServerId('t3:env'), 't3')
assert.equal(SourceModel.sourceIdForServerId('local-a'), 'herdr')

console.log('test_agent_source_labels: all assertions passed')
