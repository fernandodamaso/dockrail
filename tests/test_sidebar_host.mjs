import assert from 'node:assert/strict'
import {hostHarness, plain, read, loadModel} from './host_harness.mjs'
const initial = {position:'bottom', workspaceLayout:'grouped', workspaceMonitorScope:'current-monitor',
  workspaceGroups:[{desktopId:'chrome',workspace:'id:3'}], windowScope:'workspace-monitor',
  reserveSpace:false, autoHide:true, showPreviews:true, iconSize:64, magnification:1.5,
  pinned:['chrome'], extensionData:{keep:['opaque']}, clickAction:'launch', scrollAction:'cycle-windows'}
const h = hostHarness(initial)
const before = plain(h.host.settings)
const dry = h.request('config.apply',{patch:{presentationMode:'sidebar'},dryRun:true})
assert.equal(dry.ok,true)
assert.equal(dry.data.presentation.mode,'sidebar')
assert.equal(h.host.settings.presentationMode,'classic')
for (const [key, value] of Object.entries({presentationMode:'classic', sidebarEdge:'left',
  sidebarMonitor:'', sidebarExpandedWidth:320, sidebarCollapsed:false,
  sidebarCollapsedByMonitor:{}})) {
  assert.equal(h.defaults[key] === value || JSON.stringify(h.defaults[key]) === JSON.stringify(value), true,
    'sidebar defaults are bundled, not a second writer: ' + key)
  assert.equal(JSON.stringify(h.request('config.schema',{key}).data.settings[key].default),
    JSON.stringify(value))
}
for (const patch of [{presentationMode:'other'}, {sidebarEdge:'top'}, {sidebarCollapsed:'true'},
    {sidebarExpandedWidth:239}, {sidebarExpandedWidth:481}, {sidebarExpandedWidth:320.5},
    {sidebarExpandedWidth:'320'}, {sidebarMonitor:3}, {sidebarMonitor:'DP-1\n'},
    {sidebarMonitor:'DP-1\u0085'}]) {
  assert.equal(h.request('config.apply',{patch}).ok, false, JSON.stringify(patch))
}
assert.equal(h.writes.length, 0)
h.host.connectedScreens = [{name:'DP-1',width:720,height:1280}]
h.host.hyprMonitors = [{name:'DP-1',id:1,lastIpcObject:{name:'DP-1',id:1,x:0,y:0,scale:1.5}}]
let reply = h.request('config.apply',{patch:{presentationMode:'sidebar',sidebarMonitor:'NOT-CONNECTED'}})
assert.equal(reply.ok,true)
assert.equal(reply.data.persisted,true)
let effective = h.request('config.get',{effective:true})
for (const key of Object.keys(initial)) assert.deepEqual(plain(h.host.settings[key]), initial[key])
assert.equal(effective.data.settings.windowScope,'all')
assert.equal(effective.data.settings.reserveSpace,true)
assert.equal(effective.data.settings.autoHide,false)
assert.equal(effective.data.settings.showPreviews,false)
assert.equal(effective.data.settings.sidebarExpandedWidth,288)
assert.equal(effective.data.settings.sidebarMonitor,'DP-1')
assert.equal(effective.data.settings.iconSize,32)
assert.equal(effective.data.settings.clickAction,null)
assert.equal(effective.data.settings.scrollAction,null)
assert.ok(effective.data.presentation.inactiveClassicSettings.includes('workspaceGroups'))
assert.equal(effective.data.presentation.width,288)
assert.equal(h.host.settings.sidebarExpandedWidth,320)
assert.equal(h.host.settings.sidebarMonitor,'NOT-CONNECTED')
reply = h.host.saveSetting('sidebarCollapsed',true)
assert.equal(reply.ok,true)
assert.deepEqual(Array.from(reply.data.changedKeys),['sidebarCollapsed'])
assert.equal(h.request('status').data.presentation.width,72)
assert.equal(h.host.settings.sidebarExpandedWidth,320)
const writes = h.writes.length
h.fault.defer = true
h.host.saveSetting('sidebarCollapsed',false)
assert.equal(h.host.settings.sidebarCollapsed,false, 'accepted-but-saving retains live intent')
reply = h.host.saveSetting('sidebarCollapsed',true)
assert.equal(reply.ok,false)
assert.equal(h.host.settings.sidebarCollapsed,false, 'preflight busy cannot replay a stale intent')
assert.equal(h.writes.length,writes+1)
h.fault.defer=false
h.host.settingsSaved()
h.request('config.reset',{key:'sidebarMonitor'})
h.request('config.apply',{patch:{presentationMode:'classic'}})
for (const key of Object.keys(initial)) assert.deepEqual(plain(h.host.settings[key]),initial[key])
const model=loadModel('DockSidebarModel')
assert.equal(model.geometry(720,320,false).width,288)
const host=read('DockHost.qml')
assert.equal((host.match(/\n  DockWindowActions \{/g)||[]).length,1)
assert.equal((host.match(/\n  DockSidebarController \{/g)||[]).length,1)
// Per-screen presentation ownership replaces the single global renderer loader:
// one stable owner per connected output, each mapping at most one surface.
assert.doesNotMatch(host,
  /\bpresentationLoader\b|\bsyncRenderer\b|\bactivateRenderer\b|rendererMode|rendererReady|rendererInitialized|rendererEdge|rendererScreen|commitModeGesture\b/,
  'the single global renderer state machine is gone')
assert.match(host,/id: presentationOwners/)
assert.match(host,/model: root\.connectedScreens/)
assert.match(host,/DockScreenPresentation \{/)
assert.match(host,/surfaceComponent: mode === "sidebar" \? sidebarSurface : classicSurface/)
assert.match(host,/readonly property var sidebarPanels:/)
assert.match(host,/function commitMonitorModeGesture\(connector, destination, capturedState, menuOrigin\)/)
assert.match(host,/function currentPresentation\(\)/)
// Ownership lifecycle is generic and behavior-tested with fake components by
// tests/tst_screenownership.qml; here only the teardown-first contract is pinned.
const ownerSource=read('components/DockScreenPresentation.qml')
assert.match(ownerSource,
  /function syncSurface\(\) \{[\s\S]*?surfaceLoader\.active = false\s*\n\s*surfaceLoader\.sourceComponent = root\.surfaceComponent\s*\n\s*Qt\.callLater\(root\.activateSurface\)/,
  'syncSurface tears down synchronously before deferring creation')
// Host presentation resolves per screen from live settings through the same
// pure resolver the sidebar controller and CLI diagnostics call.
h.host.connectedScreens=[{name:'DP-1',width:1920,height:1080},
  {name:'DP-2',width:1920,height:1080}]
h.host.hyprMonitors=[{name:'DP-1',x:0},{name:'DP-2',x:1920}]
h.host.sidebarState={selectedScreen:h.host.connectedScreens[0],
  mappedScreens:h.host.connectedScreens,interactionBusy:false}
h.host.settings={...h.host.settings,presentationMode:'sidebar'}
let presentation=h.host.currentPresentation()
assert.equal(presentation.defaultMode,'sidebar')
assert.deepEqual([...presentation.sidebarScreens].map(s=>s.name),['DP-1','DP-2'],
  'the inherited sidebar default still mirrors every connected screen')
h.host.settings={...h.host.settings,presentationModeByMonitor:{'DP-2':'classic'}}
presentation=h.host.currentPresentation()
assert.deepEqual([...presentation.classicScreens].map(s=>s.name),['DP-2'])
assert.deepEqual([...presentation.sidebarScreens].map(s=>s.name),['DP-1'])
assert.equal(presentation.sourceByMonitor['DP-2'],'override')
assert.equal(presentation.sourceByMonitor['DP-1'],'inherited')
assert.equal(presentation.mixed,true)
console.log('SB-02 typed configuration, requested/effective diagnostics and sole writer: PASS')
