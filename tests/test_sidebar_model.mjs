import assert from 'node:assert/strict'
import fs from 'node:fs'
import { loadModel, plain } from './host_harness.mjs'
import { sidebarFixture, desktopModel } from './sidebar_fixture.mjs'
assert.ok(fs.existsSync(new URL('../components/DockSidebarModel.js', import.meta.url)),
  'SB-02 must provide the production sidebar projection')
const Model = loadModel('DockSidebarModel')
let f = sidebarFixture()
let registry = Model.reconcileHandles(null, f.toplevels)
const project = (options = {}) => Model.project({ desktop: desktopModel.build(f.input),
  screens: f.screens, monitors: f.monitors, monitorOrder: f.settings.workspaceMonitorOrder,
  pinned: f.settings.pinned, hiddenApplications: f.settings.hiddenApplications || [],
  registry, folds: {}, collapsed: false, ...options })
let p = project()
const windows = result => result.rows.filter(row => row.kind === 'window')
const allWindows = result => result.monitorSections.flatMap(m => m.workspaces.flatMap(w => w.applications.flatMap(a => a.windows)))
  .concat(result.unassignedWindows)
const findWindow = (result, id) => allWindows(result).find(w => w.toplevel.id === id)
assert.deepEqual(Array.from(p.monitorSections, m => m.connector), ['DP-1', 'HDMI-A-1', 'USB-C-1', ''])
assert.deepEqual(Array.from(p.monitorSections, m => m.label),
  ['Left · DP-1', 'Right · HDMI-A-1', 'Portrait · USB-C-1', 'Unknown monitor'],
  'monitor headings include connector on first paint')
assert.deepEqual(Array.from(p.monitorSections, m => m.title),
  ['Left', 'Right', 'Portrait', 'Unknown monitor'],
  'monitor title stays short for two-line headers')
assert.ok(!p.rows.some(r => r.key === 'section:pinned' || r.kind === 'launcher'),
  'expanded projection keeps pins out of the hierarchy list')
assert.equal(p.monitorSections[2].workspaces.length, 0, 'connected empty monitor has a header, not an invented workspace')
assert.deepEqual(Array.from(p.monitorSections[3].workspaces, w => w.identity), ['id:11', 'id:12'])
assert.equal(p.monitorSections[0].workspaces.find(w => w.identity === 'id:4').applications.length, 0)
assert.ok(p.monitorSections[1].workspaces.some(w => w.identity === 'name:project alpha'))
assert.equal(p.monitorSections[0].workspaces.find(w => w.identity === 'id:3').active, true)
assert.equal(p.monitorSections[1].workspaces.find(w => w.identity === 'id:7').active, true)
assert.equal(p.monitorSections[0].workspaces.find(w => w.identity === 'id:3').focused, false,
  'active workspace on an unfocused monitor is not globally focused')
assert.equal(p.monitorSections[1].workspaces.find(w => w.identity === 'id:7').focused, true,
  'only the active workspace on the focused monitor is globally focused')
assert.equal(p.monitorSections.flatMap(m => m.workspaces).filter(w => w.focused).length, 1,
  'only one workspace carries focused accent state')
assert.equal(findWindow(p, 'sticky').workspaceIdentity, 'id:7')
assert.equal(findWindow(p, 'minimized').workspaceIdentity, 'id:3')
assert.equal(findWindow(p, 'minimized').minimized, true)
assert.equal(findWindow(p, 'b').urgent, true)
assert.equal(findWindow(p, 'hidden'), undefined)
assert.equal(findWindow(p, 'scratch'), undefined,
  'special-workspace windows are never presented in the sidebar')
assert.deepEqual(Array.from(p.launchers, l => l.desktopId), ['closed-app', 'chrome'],
  'pin shelf keeps settings.pinned order including running apps; hidden pins stay out')
assert.ok(p.launchers.find(l => l.desktopId === 'chrome').running === true)
assert.ok(p.launchers.find(l => l.desktopId === 'closed-app').running === false)
assert.ok(Model.indexRowsByKey(p)[p.launchers[0].key],
  'indexRowsByKey registers strip launchers for controller activation')
assert.equal(windows(p).length, f.toplevels.length - 2)
assert.equal(new Set(allWindows(p).map(w => w.key)).size, f.toplevels.length - 2)
const unknowns = p.unassignedWindows.filter(w => !w.toplevel.appId)
assert.notEqual(unknowns[0].applicationKey, unknowns[1].applicationKey, 'unidentified handles must never share a fake app group')
assert.notEqual(findWindow(p, 'pending-one').key, findWindow(p, 'pending-two').key)
const chrome3 = p.monitorSections[0].workspaces[0].applications.find(a => a.desktopId === 'chrome')
assert.deepEqual(Array.from(chrome3.windows, w => w.toplevel.id), ['a', 'b', 'minimized'])
assert.equal(chrome3.folded, false, 'classic saved grouping is inactive in sidebar')
assert.equal(chrome3.key, JSON.stringify(['app', 'id:3', 'chrome']))

// Real native badge traversal remains independent of visual order; one count owner per app.
const chromeOwner = p.rows.filter(r => r.desktopId === 'chrome' && r.primaryOwner)
assert.equal(chromeOwner.length, 1)
assert.equal(chromeOwner[0].toplevel.id, 'c', 'focused workspace traversal owns Chrome even when left monitor renders first')
const chrome7 = p.monitorSections[1].workspaces.find(w => w.identity === 'id:7').applications.find(a => a.desktopId === 'chrome')
let folded = project({ folds: { [chrome3.key]: true, [chrome7.key]: true } })
const foldedOwner = folded.rows.filter(r => r.desktopId === 'chrome' && r.primaryOwner)[0]
assert.equal(foldedOwner.toplevel.id, 'c', 'focused sole-window Chrome keeps badge ownership as the window row')
assert.equal(foldedOwner.kind, 'window')
assert.ok(!windows(folded).some(w => w.desktopId === 'chrome' && w.workspaceIdentity === 'id:3'),
  'folded multi-window Chrome hides member windows')
assert.ok(windows(folded).some(w => w.toplevel.id === 'c'), 'sole-window Chrome remains visible while other groups fold')
const rail = project({ folds: { [chrome3.key]: true, [chrome7.key]: true }, collapsed: true })
assert.deepEqual(Array.from(windows(rail), w => w.key), Array.from(windows(p), w => w.key), 'rail exposes every member in canonical order')
assert.ok(!rail.rows.some(r => r.kind === 'application'), 'rail does not replace windows with app launchers')
assert.equal(project({ folds: { [chrome3.key]: true } }).monitorSections[0].workspaces[0].applications[0].folded, true)
const foldedOnly = project({ folds: { [chrome3.key]: true } })
const foldedRail = project({ folds: { [chrome3.key]: true }, collapsed: true })
assert.ok(!windows(foldedOnly).some(w => w.desktopId === 'chrome' && w.workspaceIdentity === 'id:3'),
  'expanded folds hide multi-window members')
const railFoldedWindow = windows(foldedRail).find(w => w.desktopId === 'chrome' && w.workspaceIdentity === 'id:3')
assert.ok(railFoldedWindow, 'rail still exposes windows from a folded application group')
const unionIndex = Model.indexRowsByKey(foldedOnly, foldedRail)
assert.ok(unionIndex[railFoldedWindow.key], 'union lookup addresses rail-only folded windows')
assert.equal(unionIndex[chrome3.key], foldedOnly.rows.find(r => r.key === chrome3.key),
  'expanded canonical row wins duplicates in union index')
assert.ok(Model.indexRowsByKey(foldedOnly)[chrome3.key], 'one-arg indexRowsByKey stays valid')
assert.equal(new Set(p.badgeItems.map(i => i.presentationId)).size, p.badgeItems.length)

const oldKeys = Array.from(windows(p), w => w.key)
f.toplevels[0].title = '<b>Changed title</b>'
f.toplevels[0].activated = true
f.toplevels[2].activated = false
f.monitors[0].lastIpcObject.focused = false
f.monitors[1].lastIpcObject.focused = true
f.input.focusedWorkspace = 'id:3'
f.handles[4].address = '0x123'
f.input.toplevels = f.toplevels.slice().reverse()
registry = Model.reconcileHandles(registry, f.input.toplevels)
p = project()
assert.deepEqual(Array.from(windows(p), w => w.key), oldKeys, 'focus/title/address and source reorder do not shuffle members')
assert.equal(findWindow(p, 'a').title, '<b>Changed title</b>')
assert.equal(findWindow(p, 'pending-one').address, '0x123')
// Physical x/y order (DP-1 left, HDMI right); focused follows compositor IPC on DP-1.
const focusedFlags = Array.from(p.monitorSections, m => !!m.focused)
assert.equal(focusedFlags.filter(Boolean).length, 1, 'exactly one focused monitor section')
assert.equal(p.monitorSections.findIndex(m => m.focused), 0,
  'focused flag is on the left physical monitor after focus moves to DP-1')
assert.equal(p.rows.filter(r => r.kind === 'monitor' && r.focused).length, 1,
  'monitor rows carry focused for strip/rail without per-header sectionIndex')
// Deliberately reverse configured card order; miniatures stay physical.
{
  f.settings.workspaceMonitorOrder = ['USB-C-1', 'HDMI-A-1', 'DP-1']
  const reversed = project({ monitorOrder: f.settings.workspaceMonitorOrder })
  assert.deepEqual(Array.from(reversed.monitorSections, m => m.connector).filter(Boolean),
    ['USB-C-1', 'HDMI-A-1', 'DP-1'], 'cards follow reversed workspaceMonitorOrder')
  const strip = Model.physicalMonitorStrip(f.screens, f.monitors, reversed.monitorSections)
  assert.deepEqual(Array.from(strip, m => m.connector),
    ['DP-1', 'HDMI-A-1', 'USB-C-1'],
    'physical strip ignores configured order and nonspatial monitor ids')
  assert.equal(strip.findIndex(m => m.focused), 0,
    'focus joins onto physical DP-1 even when cards list it last')
  f.settings.workspaceMonitorOrder = []
}
const oldAKey = findWindow(p, 'a').key
f.handles[0].lastIpcObject.workspace = { id: 7 }
p = project()
assert.equal(findWindow(p, 'a').key, oldAKey, 'a workspace move does not change live-handle identity')
const stableApp = p.monitorSections[1].workspaces.find(w => w.identity === 'id:7').applications.find(a => a.desktopId === 'chrome').key
f.workspaces.find(w => w.id === 7).monitorID = 9
assert.equal(project().monitorSections[0].workspaces.find(w => w.identity === 'id:7').applications.find(a => a.desktopId === 'chrome').key, stableApp)
registry = Model.reconcileHandles(registry, f.toplevels.filter(t => t.id !== 'a'))
const replacement = { id: 'replacement', appId: 'chrome', title: 'New lifetime' }
registry = Model.reconcileHandles(registry, [replacement, ...f.toplevels.filter(t => t.id !== 'a')])
assert.notEqual(Model.handleEntry(registry, replacement).key, oldAKey, 'address reuse never reuses a closed handle token')
assert.equal(registry.entries.length, f.toplevels.length)
registry = Model.reconcileHandles(registry, [])
assert.equal(registry.entries.length, 0, 'registry is bounded by live handles')

// Reuse an actual Hyprland address after closing the old handle: a new key is required.
f = sidebarFixture()
registry = Model.reconcileHandles(null, f.toplevels)
const prior = findWindow(project(), 'a')
const fresh = {id:'fresh',appId:'chrome',title:'Fresh lifetime'}
f.input.toplevels = [fresh, ...f.toplevels.slice(1)]
f.input.hyprToplevels = [{...f.handles[0],wayland:fresh},...f.handles.slice(1)]
registry = Model.reconcileHandles(Model.reconcileHandles(registry,f.toplevels.slice(1)),f.input.toplevels)
const reused = findWindow(project(),'fresh')
assert.equal(reused.address,prior.address)
assert.notEqual(reused.key,prior.key)

// Screen selection is connector-based and sticky except for explicit preference at idle.
f = sidebarFixture()
const pick = (preferred, current, busy = false, screens = f.screens, order = []) =>
  Model.selectScreen(screens, f.monitors, order, preferred, current, busy)
assert.equal(pick('', '').name, 'DP-1')
assert.equal(pick('', 'HDMI-A-1').name, 'HDMI-A-1')
assert.equal(pick('USB-C-1', 'DP-1').name, 'USB-C-1')
assert.equal(pick('USB-C-1', 'DP-1', true).name, 'DP-1')
assert.equal(pick('Missing', 'HDMI-A-1').name, 'HDMI-A-1')
assert.equal(pick('dp-1', '').name, 'DP-1', 'saved connector matching is case-sensitive')
assert.equal(pick('', '', false, f.screens, ['USB-C-1']).name, 'USB-C-1')
assert.equal(pick('DP-1', 'DP-1', true, f.screens.filter(s => s.name !== 'DP-1')).name, 'HDMI-A-1', 'removal overrides busy retention')
assert.equal(pick('DP-1', 'DP-1', false, []), null)
assert.equal(pick('', 'HDMI-A-1', false, [{ name: 'NEW', x: -5000, y: 0, width: 1000 }, ...f.screens]).name, 'HDMI-A-1')
for (const width of [0, -1, 30, 56, 200, 600, 720, 1000, 1920]) {
  for (const requested of [240, 320, 480]) for (const collapsed of [false, true]) {
    const g = Model.geometry(width, requested, collapsed)
    assert.ok(g.width >= 0 && g.width <= Math.max(0, width))
    assert.equal(g.mapped, width > 0)
    if (collapsed) assert.equal(g.width, Math.min(72, Math.max(0, width)))
  }
}
assert.equal(Model.geometry(720, 480, false).width, 288, 'Qt dimensions are logical, not divided by scale again')
assert.equal(Model.geometry(1920, 320, false).width, 320)
assert.equal(Model.geometry(0, 320, false).width, 0)
assert.deepEqual(plain(Model.recoverAnchor({ key: 'gone', offset: 7 }, ['a', 'gone', 'b'], [{ key: 'a' }, { key: 'b' }])), { key: 'b', offset: 7 })
assert.deepEqual(plain(Model.recoverAnchor({ key: 'b', offset: 7 }, ['a', 'b'], [])), { key: '', offset: 0 })

// Phase 9: independent scroll memory keys (connector × mode); monitors do not clobber.
assert.equal(Model.scrollMemoryKey('DP-1', false), JSON.stringify(['DP-1', 'expanded']))
assert.equal(Model.scrollMemoryKey('DP-1', true), JSON.stringify(['DP-1', 'rail']))
{
  let states = {}
  states = Model.writeScrollState(states, 'DP-1', false, { key: 'w1', offset: 12 }, ['a', 'w1', 'b'])
  states = Model.writeScrollState(states, 'DP-2', false, { key: 'w2', offset: 3 }, ['w2'])
  states = Model.writeScrollState(states, 'DP-1', true, { key: 'r1', offset: 5 }, ['r1'])
  assert.deepEqual(plain(Model.readScrollState(states, 'DP-1', false).anchor), { key: 'w1', offset: 12 })
  assert.deepEqual(plain(Model.readScrollState(states, 'DP-1', true).anchor), { key: 'r1', offset: 5 })
  assert.deepEqual(plain(Model.readScrollState(states, 'DP-2', false).anchor), { key: 'w2', offset: 3 },
    'second monitor must not overwrite the first')
  const recovered = Model.recoverAnchor(
    Model.readScrollState(states, 'DP-1', false).anchor,
    Model.readScrollState(states, 'DP-1', false).keys,
    [{ key: 'a' }, { key: 'b' }])
  assert.deepEqual(plain(recovered), { key: 'b', offset: 12 },
    'mode refresh recovers from that mode key list via recoverAnchor')
}

// Empty/whitespace application IDs must neither steal closed pins nor merge handles.
f = sidebarFixture()
f.toplevels.find(t => t.id === 'unknown-one').appId = '  '
registry = Model.reconcileHandles(null, f.toplevels)
p = project()
assert.deepEqual(Array.from(p.launchers,l => l.desktopId),['closed-app', 'chrome'])
assert.notEqual(findWindow(p,'unknown-one').applicationKey,findWindow(p,'unknown-two').applicationKey)
const inputBefore = JSON.stringify(f.input)
project()
assert.equal(JSON.stringify(f.input), inputBefore, 'projection never rewrites source snapshots or saved groups')

// Single-window apps render one useful window row; multi-window apps stay grouped.
f = sidebarFixture()
registry = Model.reconcileHandles(null, f.toplevels)
p = project()
const terminalRows = p.rows.filter(r => r.desktopId === 'terminal')
assert.ok(terminalRows.length >= 1)
assert.ok(terminalRows.every(r => r.kind === 'window'), 'single-window apps must not emit a duplicate application header')
assert.equal(terminalRows[0].soleWindow, true)
const chromeLeft = p.monitorSections[0].workspaces[0].applications.find(a => a.desktopId === 'chrome')
assert.equal(chromeLeft.expandable, true)
assert.equal(chromeLeft.windowCount, 3)
assert.ok(p.rows.some(r => r.key === chromeLeft.key && r.kind === 'application'))
assert.ok(chromeLeft.windows.every(w => p.rows.some(r => r.key === w.key && r.nested === true)))
const chromeRight = p.monitorSections[1].workspaces.find(w => w.identity === 'id:7').applications.find(a => a.desktopId === 'chrome')
assert.equal(chromeRight.expandable, false)
assert.equal(chromeRight.windowCount, 1)
assert.ok(!p.rows.some(r => r.key === chromeRight.key), 'sole window on a workspace skips the application row')
assert.ok(p.launchers.length >= 2, 'expanded pins are strip-owned via projection.launchers')
assert.ok(p.launchers.every(l => l.kind === 'launcher'))
assert.ok(!p.rows.some(r => r.key === 'section:pinned' || r.kind === 'launcher'),
  'expanded hierarchy omits the pinned section row and strip launchers')
const railPins = project({ collapsed: true })
assert.ok(!railPins.rows.some(r => r.kind === 'launcher' || r.key === 'section:pinned'),
  'rail hierarchy also omits strip-owned pins')
assert.ok(railPins.launchers.length >= 2, 'rail retains strip pin discovery via launchers')
assert.ok(Model.indexRowsByKey(railPins)[railPins.launchers[0].key])

// Browser tabs nest under Chrome windows; default expanded; fold via folds[tabsKey].
f = sidebarFixture()
registry = Model.reconcileHandles(null, f.toplevels)
const soleChrome = findWindow(project(), 'c')
assert.ok(soleChrome, 'fixture sole Chrome window')
const tabId = 'a'.repeat(32)
const tabId2 = 'b'.repeat(32)
const withTabs = project({
  browserTabs: {
    [String(soleChrome.address).toLowerCase()]: [
      { targetId: tabId, title: 'Inbox - Gmail', active: true },
      { targetId: tabId2, title: 'Linear', active: false }
    ]
  }
})
const soleWithMeta = findWindow(withTabs, 'c')
assert.equal(soleWithMeta.tabsExpandable, true)
assert.equal(soleWithMeta.tabsFolded, false, 'tabs start expanded')
const defaultTabRows = withTabs.rows.filter(r => r.kind === 'browser-tab')
assert.equal(defaultTabRows.length, 2, 'expanded tabs are projected by default')
assert.deepEqual(Array.from(defaultTabRows, r => r.title), ['Inbox - Gmail', 'Linear'])
const foldedTabs = project({
  browserTabs: {
    [String(soleChrome.address).toLowerCase()]: [
      { targetId: tabId, title: 'Inbox - Gmail', active: true },
      { targetId: tabId2, title: 'Linear', active: false }
    ]
  },
  folds: { [soleWithMeta.tabsKey]: true }
})
assert.equal(findWindow(foldedTabs, 'c').tabsFolded, true)
assert.ok(!foldedTabs.rows.some(r => r.kind === 'browser-tab'),
  'folded tabs are not projected')
const expandedTabs = project({
  browserTabs: {
    [String(soleChrome.address).toLowerCase()]: [
      { targetId: tabId, title: 'Inbox - Gmail', active: true },
      { targetId: tabId2, title: 'Linear', active: false }
    ]
  }
})
const tabRows = expandedTabs.rows.filter(r => r.kind === 'browser-tab')
assert.equal(tabRows.length, 2)
assert.deepEqual(Array.from(tabRows, r => r.title), ['Inbox - Gmail', 'Linear'])
assert.equal(tabRows[0].targetId, tabId)
assert.equal(tabRows[0].nested, true)
assert.equal(tabRows[0].windowKey, soleWithMeta.key)
assert.ok(!project({
  browserTabs: { [String(soleChrome.address).toLowerCase()]: [
    { targetId: tabId, title: 'Hidden', active: true }] },
  sidebarBrowserTabsEnabled: false
}).rows.some(r => r.kind === 'browser-tab'), 'setting disables tab children')
assert.ok(!project({
  browserTabs: { [String(soleChrome.address).toLowerCase()]: [
    { targetId: tabId, title: 'Rail', active: true }] },
  collapsed: true
}).rows.some(r => r.kind === 'browser-tab'), 'collapsed rail omits tab children')

// Phase 3: tree metadata, sectionSpans, shared row metrics
const emptyProj = Model.emptyProjection()
assert.deepEqual(plain(emptyProj.sectionSpans), [], 'emptyProjection includes sectionSpans:[]')
assert.ok(Array.isArray(emptyProj.sectionSpans))

f = sidebarFixture()
registry = Model.reconcileHandles(null, f.toplevels)
p = project()
const emptyWs = p.rows.find(r => r.kind === 'workspace' && r.workspaceIdentity === 'id:4')
assert.ok(emptyWs, 'empty workspace header exists')
const emptyWsSpan = p.sectionSpans.find(s => s.kind === 'workspace' && s.key === emptyWs.key)
assert.ok(emptyWsSpan)
assert.equal(emptyWsSpan.firstKey, emptyWs.key)
assert.equal(emptyWsSpan.lastKey, emptyWs.key, 'empty workspace span is header-only')
assert.equal(emptyWsSpan.endPadding, 5)
assert.ok(p.sectionSpans.every(s => s.kind === 'monitor' || s.kind === 'workspace'),
  'no invented monitor span for unassigned')
assert.ok(p.rows.some(r => r.key === 'section:unassigned'), 'unassigned section row preserved')

const chromeApp = p.rows.find(r => r.key === chromeLeft.key)
assert.equal(chromeApp.treeDepth, 1)
const inlineId3 = p.workspaceTargets.find(w => w.workspaceIdentity === 'id:3')
assert.ok(inlineId3, 'id:3 stays an inline workspace target')
assert.equal(chromeApp.parentKey, inlineId3.key,
  'inline direct rows hang from their workspace target, never the monitor')
assert.equal(chromeApp.workspaceKey, inlineId3.key)
assert.equal(chromeApp.leadingWorkspace.workspaceIdentity, 'id:3',
  'first visible child carries the inline workspace target')
assert.equal(chromeApp.inlineWorkspaceGroup, true,
  'first child is marked as part of the inline workspace group')
assert.equal(chromeApp.monitorKey, p.rows.find(r => r.kind === 'monitor').key)
const nestedWins = p.rows.filter(r => r.kind === 'window' && r.applicationKey === chromeLeft.key)
assert.ok(nestedWins.length >= 2)
assert.ok(nestedWins.every(w => w.inlineWorkspaceGroup === true
  && !w.leadingWorkspace),
  'later descendants keep the group flag but not the badge owner')
assert.ok(nestedWins.every(w => w.treeDepth === 2 && w.parentKey === chromeApp.key),
  'grouped windows are depth-2 under the visible app row')
assert.equal(nestedWins[nestedWins.length - 1].isLastSibling, true)
assert.ok(nestedWins.slice(0, -1).every(w => w.isLastSibling === false))
const midNested = nestedWins[0]
assert.deepEqual(plain(midNested.ancestorContinues), [chromeApp.isLastSibling !== true],
  'ancestorContinues reflects whether the app stem continues')

// Direct-row siblings are scoped to one workspace: the badge-centered guide
// exists only while another direct row of the *same* workspace follows, and
// expanded descendants alone never keep it alive.
{
  assert.equal(chromeApp.isLastSibling, true,
    'id:3 has a single direct row, so its badge stem stops at the chip')
  assert.deepEqual(plain(midNested.ancestorContinues), [false],
    'expanded app children alone never continue the workspace-column guide')

  const id7Target = p.workspaceTargets.find(w => w.workspaceIdentity === 'id:7')
  const id7Direct = p.rows.filter(r => r.workspaceKey === id7Target.key && r.treeDepth === 1)
  assert.deepEqual(Array.from(id7Direct, r => r.kind), ['window', 'application', 'window'],
    'Code has three direct rows: the chrome window, the firefox group, sticky')
  assert.ok(id7Direct.every(r => r.parentKey === id7Target.key),
    'every direct row is parented to the same workspace target')
  assert.equal(id7Direct.filter(r => r.leadingWorkspace).length, 1,
    'multiple sibling apps share one workspace badge without a header row')
  assert.deepEqual(Array.from(id7Direct, r => r.isLastSibling), [false, false, true],
    'only the final direct row ends the badge-centered guide')
  const id7Nested = p.rows.filter(r => r.workspaceKey === id7Target.key && r.treeDepth === 2)
  assert.ok(id7Nested.length >= 2, 'the middle direct row still nests its windows')
  assert.deepEqual(plain(id7Nested[0].ancestorContinues), [true],
    'descendants of a non-final direct row keep the column continuous')
  assert.ok(p.rows.slice(p.rows.indexOf(id7Direct[2]) + 1)
    .some(r => r.workspaceKey !== id7Target.key),
    'rows of other workspaces follow without joining this sibling set')
}

const emptyWsParent = p.rows.find(r => r.kind === 'workspace' && r.workspaceIdentity === 'id:4')
assert.equal(emptyWsParent.parentKey, p.rows.find(r => r.kind === 'monitor').key,
  'explicit workspace headers remain monitor children')

const tabProj = project({
  browserTabs: {
    [String(soleChrome.address).toLowerCase()]: [
      { targetId: tabId, title: 'Inbox - Gmail', active: true },
      { targetId: tabId2, title: 'Linear', active: false }
    ]
  }
})
const tabParent = tabProj.rows.find(r => r.key === soleWithMeta.key)
const tabs = tabProj.rows.filter(r => r.kind === 'browser-tab')
assert.equal(tabs.length, 2)
assert.ok(tabs.every(t => t.parentKey === tabParent.key && t.treeDepth === tabParent.treeDepth + 1))
assert.equal(tabs[0].isLastSibling, false)
assert.equal(tabs[1].isLastSibling, true)
assert.equal(tabs[0].treeDepth, 2)
assert.equal(tabParent.isLastSibling, false,
  'direct rows still follow the Code window, so its guide continues')
assert.equal(tabs[0].ancestorContinues.length, 1)
assert.equal(tabs[0].ancestorContinues[0], tabParent.isLastSibling !== true)

const railMeta = project({ collapsed: true })
assert.ok(!railMeta.rows.some(r => r.kind === 'application' || r.kind === 'browser-tab'))
const railWin = railMeta.rows.find(r => r.kind === 'window' && r.desktopId === 'chrome'
  && r.workspaceIdentity === 'id:3')
assert.ok(railWin)
assert.equal(railWin.treeDepth, 1, 'rail windows sit directly under workspace')
assert.equal(railWin.parentKey, railWin.workspaceKey)
assert.equal(railWin.nested, false)

// Populated workspaces share their first visible child row. Empty workspaces
// remain explicit rows, and hidden workspace targets remain live activation /
// menu targets even though they are not part of the rendered row list.
{
  f = sidebarFixture()
  f.workspaces.push({ id: 13, name: 'Solo', monitorID: 5 })
  f.input.hyprWorkspaces = f.workspaces
  f.settings.workspaceMonitorScope = 'all'
  registry = Model.reconcileHandles(null, f.toplevels)
  const emptySolo = project()
  const emptyWorkspace = emptySolo.rows.find(r => r.kind === 'workspace'
    && r.workspaceIdentity === 'id:13')
  assert.ok(emptyWorkspace)
  assert.equal(emptyWorkspace.layoutPadWorkspaceEnd, true)
  assert.equal(emptyWorkspace.layoutPadMonitorEnd, true)
  assert.equal(Model.indexRowsByKey(emptySolo)[emptyWorkspace.key].kind, 'workspace')
  assert.ok(emptySolo.rows.some(r => r.kind === 'workspace' && r.workspaceIdentity === 'id:4'),
    'multi-workspace monitors retain their separate workspace rows')

  const soloHandle = f.handles.find(handle => handle.wayland.id === 'c')
  soloHandle.lastIpcObject.workspace = { id: 13 }
  soloHandle.lastIpcObject.monitor = 5
  const populatedSolo = project()
  const populatedMonitor = populatedSolo.rows.find(r => r.kind === 'monitor' && r.connector === 'USB-C-1')
  const soloRow = populatedSolo.rows.find(r => r.toplevel && r.toplevel.id === 'c')
  const populatedTarget = populatedSolo.workspaceTargets.find(w => w.workspaceIdentity === 'id:13')
  assert.equal(populatedSolo.rows.filter(r => r.kind === 'workspace'
    && r.workspaceIdentity === 'id:13').length, 0)
  assert.equal(populatedSolo.workspaceTargets.filter(w => w.workspaceIdentity === 'id:13').length, 1)
  assert.equal(soloRow.leadingWorkspace.workspaceIdentity, 'id:13')
  assert.equal(soloRow.inlineWorkspaceGroup, true)
  assert.equal(soloRow.parentKey, populatedTarget.key,
    'an inline sole row hangs from its workspace target, not the monitor')
  assert.equal(soloRow.monitorKey, populatedMonitor.key,
    'monitor targeting is preserved for the same row')
  assert.equal(soloRow.layoutGapBefore, 'children')
  assert.equal(soloRow.layoutPadWorkspaceEnd, true)
  assert.equal(soloRow.layoutPadMonitorEnd, true)
  assert.equal(populatedSolo.sectionSpans.some(s => s.kind === 'workspace'
    && s.key === populatedTarget.key && s.firstKey === soloRow.key
    && s.lastKey === soloRow.key), true,
    'inline workspace span begins and ends on the sole child')
  assert.equal(Model.indexRowsByKey(populatedSolo)[populatedTarget.key].kind, 'workspace')

  // Subsequent populated workspace on the same monitor gets a workspace gap,
  // not another children gap, and only its first visible row owns the badge.
  const id3Target = populatedSolo.workspaceTargets.find(w => w.workspaceIdentity === 'id:3')
  const id3First = populatedSolo.rows.find(r => r.leadingWorkspace
    && r.leadingWorkspace.workspaceIdentity === 'id:3')
  assert.ok(id3First, 'populated multi-app workspace still has a badge owner')
  assert.equal(id3First.layoutGapBefore, 'children',
    'first populated group on a monitor keeps the children gap')
  assert.ok(populatedSolo.rows.filter(r => r.workspaceKey === id3Target.key
    && r.leadingWorkspace).length === 1,
    'only the first visible child owns leadingWorkspace')
  const id3Span = populatedSolo.sectionSpans.find(s => s.kind === 'workspace'
    && s.key === id3Target.key)
  assert.ok(id3Span)
  assert.equal(id3Span.firstKey, id3First.key)
  const id3Last = [...populatedSolo.rows].reverse()
    .find(r => r.workspaceKey === id3Target.key)
  assert.equal(id3Span.lastKey, id3Last.key)

  // HDMI-A-1 has two populated workspaces; the second group uses "workspace".
  const hdmiGroups = populatedSolo.rows.filter(r => r.leadingWorkspace
    && r.monitorKey === populatedSolo.rows.find(m => m.kind === 'monitor'
      && m.connector === 'HDMI-A-1').key)
  assert.ok(hdmiGroups.length >= 2, 'HDMI has multiple inline workspace groups')
  assert.equal(hdmiGroups[0].layoutGapBefore, 'children')
  assert.equal(hdmiGroups[1].layoutGapBefore, 'workspace')

  const legacy = project({ sidebarInlineSoloWorkspace: false })
  assert.ok(legacy.rows.some(r => r.kind === 'workspace' && r.workspaceIdentity === 'id:13'))
  assert.equal(legacy.workspaceTargets.length, 0)
  assert.ok(project({ collapsed: true }).rows.some(r => r.kind === 'workspace'
    && r.workspaceIdentity === 'id:13'))
}

// Adjacent single-window workspaces (the reported "dangling stem" layout):
// workspace 1 keeps no downward badge stem even though workspace 2 follows on
// the same monitor and the sole window has expanded tabs underneath it.
{
  f = sidebarFixture()
  f.workspaces.push({ id: 13, name: '1', monitorID: 5 })
  f.workspaces.push({ id: 14, name: '2', monitorID: 5 })
  f.input.hyprWorkspaces = f.workspaces
  f.settings.workspaceMonitorScope = 'all'
  const firstHandle = f.handles.find(h => h.wayland.id === 'c')
  firstHandle.lastIpcObject.workspace = { id: 13 }
  firstHandle.lastIpcObject.monitor = 5
  const secondHandle = f.handles.find(h => h.wayland.id === 'terminal')
  secondHandle.lastIpcObject.workspace = { id: 14 }
  secondHandle.lastIpcObject.monitor = 5
  registry = Model.reconcileHandles(null, f.toplevels)
  const adjacent = project({
    browserTabs: { '0xc': [
      { targetId: tabId, title: 'Inbox - Gmail', active: true },
      { targetId: tabId2, title: 'Linear', active: false }
    ] }
  })
  const ws13 = adjacent.workspaceTargets.find(w => w.workspaceIdentity === 'id:13')
  const ws14 = adjacent.workspaceTargets.find(w => w.workspaceIdentity === 'id:14')
  const firstRow = adjacent.rows.find(r => r.toplevel && r.toplevel.id === 'c')
  const secondRow = adjacent.rows.find(r => r.toplevel && r.desktopId === 'terminal')
  assert.ok(ws13 && ws14 && firstRow && secondRow, 'both single-window groups project')
  assert.ok(adjacent.rows.indexOf(secondRow) > adjacent.rows.indexOf(firstRow),
    'the second workspace renders after the first one')
  assert.equal(firstRow.parentKey, ws13.key)
  assert.equal(secondRow.parentKey, ws14.key,
    'each direct row belongs to its own workspace, never to the monitor')
  assert.equal(firstRow.isLastSibling, true,
    'a later workspace on the same monitor must not keep the badge stem alive')
  assert.equal(secondRow.isLastSibling, true)
  assert.deepEqual(plain(firstRow.ancestorContinues), [],
    'a depth-1 row draws no ancestor stems of its own')
  const soleTabs = adjacent.rows.filter(r => r.kind === 'browser-tab')
  assert.equal(soleTabs.length, 2, 'expanded tabs still project under the sole window')
  assert.ok(soleTabs.every(t => t.parentKey === firstRow.key))
  assert.equal(soleTabs[0].isLastSibling, false)
  assert.equal(soleTabs[1].isLastSibling, true)
  assert.deepEqual(plain(soleTabs[0].ancestorContinues), [false],
    'expanded descendants alone never continue the workspace-column guide')
}

const Interaction = loadModel('DockSidebarInteractionModel')
const id = n => n
const sampleWin = { kind: 'window', layoutGapBefore: '', layoutPadWorkspaceEnd: false,
  layoutPadMonitorEnd: false }
const metrics = Interaction.sidebarRowMetrics(sampleWin, false, 34, id, false)
assert.equal(metrics.contentHeight, 28, 'default rowHeight 34 must not force expanded 28→34')
assert.equal(metrics.height, Interaction.estimatedSidebarRowHeight(sampleWin, false, 34, id, false))
assert.equal(Interaction.sidebarRowMetrics(
  { kind: 'monitor', sectionIndex: 0, layoutGapBefore: '' }, false, 34, id).contentHeight, 32)
assert.equal(Interaction.sidebarRowMetrics(
  { kind: 'monitor', sectionIndex: 1, layoutGapBefore: 'monitor' }, false, 34, id).gapBefore, 8)
assert.equal(Interaction.sidebarRowMetrics(
  { kind: 'window', layoutPadWorkspaceEnd: true, layoutPadMonitorEnd: true },
  false, 34, id).gapAfter, 10)
assert.equal(Interaction.sidebarRowMetrics(sampleWin, true, 34, id, false).contentHeight, 36)
assert.equal(Interaction.sidebarRowMetrics(sampleWin, true, 34, id, true).contentHeight, 58)

console.log('SB-02 sidebar native projection, stable identity, folding/rail, badges, screens and geometry: PASS')
