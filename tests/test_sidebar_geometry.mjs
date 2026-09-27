import assert from 'node:assert/strict'
import {loadModel} from './host_harness.mjs'

const model = loadModel('DockSidebarModel')
const layout = loadModel('DockSidebarInteractionModel')

// At 256 px, the panel's 14 px inset plus these positions puts application
// titles at 75 px and nested window titles at 95 px. Both sibling app rows
// consume the same workspace geometry, regardless of which owns the badge.
const inline = layout.sidebarInlineWorkspaceGeometry(5, n => n)
assert.equal(14 + inline.labelX, 75)
assert.equal(14 + inline.labelX + layout.sidebarTreeGuideLayout(5).depthStep, 95)
assert.equal(inline.badgeX, 9, 'workspace badge has 4 px inside the 5 px card inset')
const inlineSelection = layout.sidebarSelectionInsets({
  kind: 'window', collapsed: false, insideWorkspaceCard: true,
  workspaceCardInset: 5, artX: inline.artX
})
assert.ok(inlineSelection.left >= inline.badgeX + inline.badgeWidth + 4,
  'inline hover/focus fill leaves at least 4 px after the workspace badge')

function g(screen, requested = 320, collapsed = false) {
  return model.screenGeometry(screen, requested, collapsed)
}

// Qt screen geometry is already logical. Scale/device-pixel metadata must never
// divide it a second time.
for (const scale of [1, 1.25, 1.5, 2]) {
  const geometry = g({name:'DP-1', x:-1920, width:1920, height:1080,
    scale, devicePixelRatio:scale, availableWidth:1200}, 320, false)
  assert.equal(geometry.width, 320, `logical width at ${scale}x`)
  assert.equal(geometry.maximum, 480)
  assert.equal(geometry.railWidth, 72)
}

assert.deepEqual(
  Object.fromEntries(['width','expandedWidth','minimum','maximum','railWidth'].map(k => [k, g({width:720,height:1280},320,false)[k]])),
  {width:288, expandedWidth:288, minimum:240, maximum:288, railWidth:72},
  'portrait screen uses the exact 40% cap')
assert.equal(g({width:100,height:400},320,false).width,72,'narrow output is bounded')
assert.equal(g({width:40,height:400},320,false).width,40,'extremely narrow output never exceeds screen')
assert.equal(g({width:0,height:400},320,false).mapped,false,'zero-width screen does not map')
assert.equal(g({width:0,height:400},320,false).width,0)
assert.equal(g({width:1920,height:1080},320,true).width,72,'rail width')

// availableWidth/workarea can already include our own exclusive zone. Width
// budgeting must use the unreserved full logical screen width instead.
const noFeedback = g({width:1000, availableWidth:600, height:800},400,false)
assert.equal(noFeedback.width,400)
assert.equal(noFeedback.maximum,400)

assert.equal(model.resizeWidth(320, 100, 140, 'left', 1920),360)
assert.equal(model.resizeWidth(320, 100, 140, 'right', 1920),280)
assert.equal(model.resizeWidth(320, -1600, -1640, 'right', 1920),360,
  'right-edge calculation uses stable screen-global delta on negative-origin output')
assert.equal(model.resizeWidth(320, 100, 1000, 'left', 1920),480,'drag clamps to configured maximum')
assert.equal(model.resizeWidth(320, 100, -1000, 'left', 1920),240,'drag clamps to configured minimum')
assert.equal(model.resizeWidth(288, 0, 100, 'left', 720),288,'runtime cap is respected')
assert.equal(model.resizeWidth(72, 0, 100, 'left', 100),72,'narrow runtime bounds are respected')

const screens = [{name:'HDMI-A-1',width:1200,x:0},{name:'DP-1',width:1920,x:1200}]
assert.equal(model.selectScreen(screens,[],[],'DP-1','HDMI-A-1',true).name,'HDMI-A-1',
  'preferred-monitor return is deferred while interacting')
assert.equal(model.selectScreen(screens,[],[],'DP-1','HDMI-A-1',false).name,'DP-1')
assert.equal(model.selectScreen([screens[1]],[],[],'DP-1','HDMI-A-1',true).name,'DP-1',
  'current-screen removal falls back immediately even during interaction')

assert.deepEqual(Array.from(model.selectScreens(screens,[],[],'',[],false), s => s.name),
  ['DP-1','HDMI-A-1'], 'empty preference mirrors every connected screen')
assert.deepEqual(Array.from(model.selectScreens(screens,[],[],'DP-1',[],false), s => s.name),
  ['DP-1'], 'connected preference maps a single panel')
assert.deepEqual(Array.from(model.selectScreens(screens,[],[],'NOT-CONNECTED',[],false), s => s.name),
  ['DP-1','HDMI-A-1'], 'disconnected preference falls back to all screens')
assert.equal(model.screenGeometry({name:'HDMI-A-1',width:720},420,false).width,288,
  'narrower mirrored output clamps independently')
assert.equal(model.screenGeometry({name:'DP-1',width:1920},420,false).width,420,
  'wider mirrored output keeps the shared requested width')

const DockModel = loadModel('DockModel')
assert.equal(JSON.stringify(DockModel.normalizeSetting('sidebarCollapsedByMonitor', {
  'DP-1': true, 'HDMI-A-1': false, bad: 'x', '': true, 'DP\n1': true
})), JSON.stringify({'DP-1': true, 'HDMI-A-1': false}),
  'collapse map keeps only safe connector booleans')
assert.equal(JSON.stringify(DockModel.normalizeSetting('sidebarCollapsedByMonitor', null)), '{}',
  'invalid collapse map becomes empty object')

// Topology fallback/reconnect changes only effective geometry; caller-owned
// requested width remains the same preference.
const requested = 420
assert.equal(g({width:800},requested,false).width,320)
assert.equal(g({width:1920},requested,false).width,420)
assert.equal(requested,420)

console.log('SB-03 sidebar logical geometry and stable resize delta: PASS')

// R1: one production rectangle contract for paint, clipped drops and gaps.
const drag = loadModel('DockSidebarInteractionModel')
assert.equal(typeof drag.workspaceGroupRects, 'function')
const painted = drag.workspaceGroupRects([
  {key:'ws1',monitorKey:'m0',workspaceIdentity:'id:1',y:30,height:40},
  {key:'ws3',monitorKey:'m0',workspaceIdentity:'id:3',y:80,height:40},
  {key:'ws7',monitorKey:'m1',workspaceIdentity:'id:7',y:160,height:50}
], 200, 5)
assert.deepEqual(JSON.parse(JSON.stringify(painted)), [
  {key:'ws1',monitorKey:'m0',workspaceIdentity:'id:1',kind:'workspace',x:5,y:30,width:190,height:45},
  {key:'ws3',monitorKey:'m0',workspaceIdentity:'id:3',kind:'workspace',x:5,y:75,width:190,height:45},
  {key:'ws7',monitorKey:'m1',workspaceIdentity:'id:7',kind:'workspace',x:5,y:160,width:190,height:50}
])
const clipped = drag.clipRect(painted[0],{x:0,y:40,width:200,height:60})
assert.deepEqual(JSON.parse(JSON.stringify(clipped)),{x:5,y:40,width:190,height:35})
assert.equal(drag.hitWindowDrop({x:10,y:72},[],painted,[],{x:0,y:0,width:200,height:100},''),'ws1','gap assigned to previous group')
assert.equal(drag.hitWindowDrop({x:10,y:77},[],painted,[],{x:0,y:0,width:200,height:100},'ws1'),'ws1','small shared-boundary stickiness')
assert.equal(drag.hitWindowDrop({x:10,y:80},[],painted,[],{x:0,y:0,width:200,height:100},'ws1'),'ws3','stickiness is bounded')
assert.equal(drag.hitWindowDrop({x:1,y:77},[],painted,[],{x:0,y:0,width:200,height:100},'ws1'),'','never stretch over horizontal inset')
assert.equal(drag.hitWindowDrop({x:10,y:160},[],painted,[],{x:0,y:0,width:200,height:220},'ws3'),'ws7','never sticky across monitors')
console.log('R1 painted workspace groups, insets, clipping and shared-boundary stickiness: PASS')

// Execute the actual viewport functions against fixed layout input, not a
// separately reimplemented painter/hit formula.
const {qmlMethods} = await import('./sidebar_interaction_fixture.mjs')
const productionRows = [
  {kind:'monitor',key:'m',monitorKey:'m'},
  {kind:'window',key:'win',monitorKey:'m',workspaceKey:'ws',workspaceIdentity:'id:3',layoutGapBefore:'children',layoutPadWorkspaceEnd:true}
]
const view = qmlMethods('DockSidebarViewport.qml', {
  InteractionModel:drag, Style:{space:n=>n},width:180,height:75,rowHeight:34,
  panelCollapsed:false,workspaceCardInset:5,workspacePlaceholder:null,sectionChromeRevision:0,
  visibleRows:productionRows,
  sectionSpans:[{kind:'monitor',key:'m',firstKey:'m',lastKey:'win'},
    {kind:'workspace',key:'ws',firstKey:'win',lastKey:'win'}],
  controller:{rowsByKey:Object.fromEntries(productionRows.map(r=>[r.key,r])),
    attentionForRow:()=>({countVisible:false}),rowDragActive:false,dragSession:null},
  list:{width:180,originY:0,contentItem:{},itemAtIndex:i=>({y:i*40})},
  mapFromItem:(_item,x,y)=>({x,y:y-10})
})
view.workspaceRects=view.workspaceGroupRects()
const paint=view.workspacePaintRect('ws'), groupHit=view.workspaceSpanHits()[0]
assert.equal(groupHit.key,'ws')
assert.equal(groupHit.x,paint.x)
assert.equal(groupHit.width,paint.width)
assert.equal(groupHit.y,paint.y-10)
assert.equal(groupHit.height,Math.min(paint.y-10+paint.height,view.height)-groupHit.y)
assert.ok(groupHit.y+groupHit.height<=view.height,'clipped above any Widget tail')
console.log('R1 actual viewport painter/drop geometry: PASS')

// Production header rectangles exclude group side gutters and footer extra height.
{
  const root = qmlMethods('DockSidebarViewport.qml', {
    InteractionModel: drag, width:200, height:220,
    list:{width:200, contentItem:{}},
    sectionSpans:[{kind:'monitor',key:'m',lastKey:'last'}],
    workspaceRects:[{monitorKey:'m',y:30,height:130}],
    controller:{rowsByKey:{m:{monitorIdentity:'id:0'}}},
    mapFromItem:(_item,x,y)=>({x,y})
  })
  root.sectionSpanRect=()=>({y:0,height:220})
  root.windowFooterActive=()=>true; root.footerExtraHeight=()=>50
  const headers = JSON.parse(JSON.stringify(root.monitorHeaderHits()))
  assert.deepEqual(headers.map(h=>[h.y,h.height]),[[0,30],[160,10]])
  for(const point of [{x:2,y:80},{x:20,y:175},{x:20,y:215}])
    assert.equal(drag.hitTarget(point,headers,{x:0,y:0,width:200,height:220},'window'),'')
  assert.equal(drag.hitTarget({x:20,y:10},headers,{x:0,y:0,width:200,height:220},'window'),'m')
}
console.log('R1 production header/padding geometry: PASS')
