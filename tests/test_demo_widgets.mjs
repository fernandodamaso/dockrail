import assert from 'node:assert/strict'
import fs from 'node:fs'
import test from 'node:test'

const read = path => fs.readFileSync(new URL('../' + path, import.meta.url), 'utf8')
const ids = ['demo.display', 'demo.lists', 'demo.inputs', 'demo.actions-states']

test('source-owned demo registry is gated by an explicit development session', () => {
  const host = read('DockHost.qml')
  assert.match(host, /DockDemoWidgetRegistry\s*\{/)
  assert.match(host, /root\.settingsDeveloperBuild \? demoWidgetRegistry\.descriptors : \(\{\}\)/)
  assert.match(host, /Quickshell\.env\("DOCKRAIL_DEV_BUILD"\)/)
  assert.match(host, /registry\["herdr\.agents"\]/)
  const registry = read('components/DockDemoWidgetRegistry.qml')
  for (const id of ids) assert.match(registry, new RegExp(id.replace(/[.-]/g, '\\$&')))
  assert.doesNotMatch(registry, /\bProcess\s*\{|https?:\/\//)
})

test('all four demo bodies are real Widget-kit compositions', () => {
  const bodies = [
    'components/widgets/DemoWidgetDisplayBody.qml',
    'components/widgets/DemoWidgetListsBody.qml',
    'components/widgets/DemoWidgetInputsBody.qml',
    'components/widgets/DemoWidgetActionsStatesBody.qml',
  ]
  for (const path of bodies) {
    const source = read(path)
    assert.match(source, /property var widgetContext:\s*\(\{\}\)/)
    assert.doesNotMatch(source, /\bProcess\s*\{|\bFileView\s*\{|https?:\/\//)
  }
})

test('installer never enables demo Widgets in user configuration', () => {
  const installer = read('install.sh')
  assert.doesNotMatch(installer, /demo-widgets-seeded|seed_demo_widgets/)
  assert.doesNotMatch(installer, /demo\.(display|lists|inputs|actions-states)/)
  assert.equal(fs.existsSync(new URL('../scripts/smartdock_seed_demo_widgets.py', import.meta.url)), false)
})

test('Widget demo Lucide assets are bundled', () => {
  for (const name of ['search','check','chevron-down','circle-alert','cloud-off','inbox','loader-circle','clock-3'])
    assert.equal(fs.existsSync(new URL('../assets/lucide/' + name + '.svg', import.meta.url)), true, name)
})
