import assert from 'node:assert/strict'
import fs from 'node:fs'
import vm from 'node:vm'

function loadModel(name, imports = {}) {
  const source = fs.readFileSync(
    new URL(`../components/${name}.js`, import.meta.url), 'utf8')
  const scope = vm.createContext(imports)
  vm.runInContext(source.replace(/^\.(pragma|import).*$/gm, ''), scope)
  return scope
}

function qmlMethods(file, state) {
  const source = fs.readFileSync(
    new URL(`../components/${file}`, import.meta.url), 'utf8')
  const scope = vm.createContext(state)
  scope.root = scope
  vm.runInContext((source.match(/^  function [\s\S]*?^  }/gm) || []).join('\n'),
    scope, { filename: file })
  return scope
}

const DockMenuModel = loadModel('DockMenuModel')
const HerdrModel = loadModel('DockHerdrModel')
const window = { title: 'Terminal' }
const captures = []
const actions = {
  captureAgentTarget(toplevel, agent) {
    captures.push(agent.id)
    return agent.focusAgentSupported === true
      ? { toplevel, agentId: agent.id } : null
  },
}
const menu = qmlMethods('DockContextMenu.qml', {
  DockMenuModel,
  HerdrModel,
  applicationName: 'Terminal',
  herdrAgentActions: actions,
  anchorItem: {
    previewHerdrLabel: 'worktree-herdr-dock',
    previewAgents: [
      { id: 'done', serverId: 'srv', status: 'done', title: 'Done task',
        agent: 'claude', focusAgentSupported: true, toplevel: window },
      { id: 'remote', serverId: 'srv', status: 'idle', title: 'Remote task',
        agent: 'claude', focusAgentSupported: false, toplevel: window },
      { id: 'blocked', serverId: 'srv', status: 'blocked', title: 'Needs input',
        agent: 'codex', focusAgentSupported: true, toplevel: window },
      { id: 'working', serverId: 'srv', status: 'working', title: 'In progress',
        agent: 'claude', focusAgentSupported: true, toplevel: window },
    ],
  },
})

const records = menu.captureHerdrMenuRecords()
assert.equal(records[0].kind, 'header')
assert.equal(records[0].text, 'Herdr · worktree-herdr-dock')
assert.equal(records[0].muted, true)
assert.deepEqual(Array.from(records.slice(1, -1), record => record.id), [
  'herdr:srv:blocked',
  'herdr:srv:done',
  'herdr:srv:remote',
  'herdr:srv:working',
], 'agent records: blocked, done, idle, then working last')
assert.equal(records.at(-1).kind, 'separator')
assert.equal(records.at(-1).id, 'herdr:separator')
assert.deepEqual(captures, ['blocked', 'done', 'remote', 'working'],
  'every exact target is captured in display order when the menu opens')

const remote = records.find(record => record.id === 'herdr:srv:remote')
assert.equal(remote.kind, 'agent')
assert.equal(remote.enabled, false)
assert.equal(remote.target, null)
assert.equal(remote.agentKind, 'Claude')

menu.anchorItem = { previewAgents: [] }
assert.deepEqual(Array.from(menu.captureHerdrMenuRecords()), [],
  'setting-off or not-ready input emits no records and preserves baseline')

const labels = records.map(record => record.text || record.title || '')
assert.equal(labels.some(label => label.includes('Go to waiting agent')), false)
assert.equal(labels.some(label => label === 'AGENTS'), false)

console.log('context menu Herdr record order and baseline gating: PASS')
