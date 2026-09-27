import assert from 'node:assert/strict'
import { loadModel, plain, read } from './host_harness.mjs'
import { interactionFixture } from './sidebar_interaction_fixture.mjs'
const f=interactionFixture(),c=f.controller
assert.equal(typeof c.beginRowDrag,'function','SB-04 must own one live, cancellable sidebar drag session')
const target=c.captureTarget(c.projection.rows[0].key)
assert.equal(c.beginRowDrag(target),true)
assert.equal(c.interactionBusy,true)
assert.equal(c.beginRowDrag(target),false)
assert.equal(c.updateRowDrag('ws3'),true)
assert.equal(f.requests.length+f.batches.length,0,'hover has no dispatch')
assert.equal(c.finishRowDrag('ws3'),true)
assert.equal(f.requests.length,0,'follow dispatches as one ordered batch, not single silent moves')
assert.equal(f.batches.length,1,'follow moves then activates/focuses in one submission')
{
  const batch = String(f.batches[0][2] || f.batches[0])
  const moveAt = batch.indexOf('movetoworkspacesilent 3,address:0x1')
  const wsAt = batch.indexOf('workspace 3')
  const focusAt = batch.indexOf('focuswindow address:0x1')
  assert.ok(moveAt >= 0 && wsAt > moveAt && focusAt > wsAt,'existing drops move first, then activate/focus the captured window')
  assert.doesNotMatch(batch,/movecurrentworkspacetomonitor|moveworkspacetomonitor/i,
    'follow must not pull the existing destination workspace onto the source monitor')
}
assert.equal(c.interactionBusy,false);assert.equal(c.finishRowDrag('ws3'),false,'release is consumed once')
f.clear();c.beginRowDrag(target);c.updateRowDrag('ws3');c.cancelRowDrag('escape');c.finishRowDrag('ws3')
assert.equal(f.requests.length+f.batches.length,0,'cancelled drops dispatch nothing')
f.clear();c.beginRowDrag(target);f.actions.pinWindowToWorkspace(f.windows[0]);assert.equal(c.finishRowDrag('ws3'),false)
assert.equal(f.requests.length+f.batches.length,0);f.actions.unpinWindowFromWorkspace(f.windows[0])
c.beginRowDrag(target);f.handles[0].lastIpcObject.workspace={id:3};assert.equal(c.finishRowDrag('ws3'),false,'source move cancels frozen drag')
f.handles[0].lastIpcObject.workspace={name:'Design work'}
c.beginRowDrag(target);c.updateRowDrag('ws3');f.workspaces[2].monitorID=1
assert.equal(c.finishRowDrag('ws3'),false,'hover target ownership is revalidated');f.workspaces[2].monitorID=0
f.Hyprland.usingLua=true
c.beginRowDrag(c.captureTarget('ws'));assert.equal(c.finishRowDrag('mon'),true)
assert.deepEqual(f.requests,['hl.dsp.workspace.move({ workspace = "name:Design work", monitor = "0" })'])
f.clear();c.beginRowDrag(c.captureTarget('ws'));f.actions.pinWorkspaceToMonitor('name:Design work')
assert.equal(c.finishRowDrag('mon'),false);assert.equal(f.requests.length+f.batches.length,0)
// Geometry helper consumes actual mapped/clipped row rectangles, not index guesses.
const model=loadModel('DockSidebarInteractionModel')
const viewport={x:0,y:0,width:100,height:100}
const hits=[{key:'off',kind:'workspace',workspaceIdentity:'id:9',x:0,y:-50,width:100,height:25},
 {key:'workspace',kind:'window',workspaceIdentity:'id:3',x:0,y:-10,width:100,height:40},
 {key:'monitor',kind:'monitor',monitorIdentity:'0',x:0,y:30,width:100,height:30},
 {key:'unknown',kind:'window',workspaceIdentity:'',x:0,y:60,width:100,height:40}]
assert.equal(model.hitTarget({x:2,y:2},hits,viewport,'window'),'workspace')
for(const point of [{x:2,y:-1},{x:2,y:31},{x:2,y:70},{x:2,y:101},{x:101,y:2}])
 assert.equal(model.hitTarget(point,hits,viewport,'window'),'')
assert.equal(model.hitTarget({x:2,y:31},hits,viewport,'workspace'),'monitor')
assert.equal(model.hitTarget({x:2,y:2},hits,viewport,'workspace'),'')
// Monitor-card workspace drops: span geometry clipped to the hierarchy viewport.
assert.equal(typeof model.clipRect, 'function', 'clipRect clips painted monitor cards to the viewport')
assert.deepEqual(plain(model.clipRect({x:0,y:-20,width:100,height:60}, viewport)),
  {x:0,y:0,width:100,height:40}, 'partially scrolled card keeps the visible sliver')
assert.equal(model.clipRect({x:0,y:110,width:100,height:40}, viewport), null,
  'fully below the viewport is not a hit')
assert.equal(model.clipRect({x:0,y:40,width:100,height:0}, viewport), null,
  'zero-height gap between monitor cards is excluded')
const monCard = plain(model.clipRect({x:0,y:10,width:100,height:70}, viewport))
assert.deepEqual(monCard, {x:0,y:10,width:100,height:70})
const cardHits = [{
  key: 'mon-dp1', kind: 'monitor', monitorIdentity: '0',
  x: monCard.x, y: monCard.y, width: monCard.width, height: monCard.height
}]
assert.equal(model.hitTarget({x:20,y:55}, cardHits, viewport, 'workspace'), 'mon-dp1',
  'workspace drop over a window/empty area inside the destination monitor card')
assert.equal(model.hitTarget({x:20,y:12}, cardHits, viewport, 'workspace'), 'mon-dp1',
  'workspace drop over the monitor heading still resolves to the card key')
assert.equal(model.hitTarget({x:20,y:5}, cardHits, viewport, 'workspace'), '',
  'gap above the monitor card is not a destination')
assert.equal(model.hitTarget({x:20,y:55}, cardHits, viewport, 'window'), '',
  'window-to-workspace dragging retains row-hit rules, not monitor cards')
assert.equal(model.autoScrollStep(-1,100),0);assert.equal(model.autoScrollStep(101,100),0)
assert.ok(model.autoScrollStep(2,100)<0);assert.ok(model.autoScrollStep(98,100)>0)
assert.equal(model.autoScrollStep(50,100),0)
// Drag-ghost travel: clamp by the complete visible pill width.
// (The caller passes pointer+12 cursor offset; the helper only clamps.)
assert.equal(model.dragProxyOffset(200,252,168),84,'the full expanded pill stays inside the panel')
assert.equal(model.dragProxyOffset(300,252,32),220,'rail ghost remains inside the panel')
assert.equal(model.dragProxyOffset(-50,252,22),0,'pointer left of the panel parks at origin')
assert.equal(model.dragProxyOffset(200,252,160),92,'full proxy width deliberately stays inside the viewport')
assert.equal(model.dragProxyOffset(50,0,22),0,'hidden panel parks the proxy at origin')
assert.equal(model.dragProxyOffset(NaN,252,22),0,'non-numeric pointer never displaces the proxy')
assert.match(read('components/DockSidebarViewport.qml'),/dragProxyOffset\([\s\S]*?,\s*root\.width,\s*width\)/,
  'ghost horizontal travel clamps by the complete visible pill width')
console.log('SB-04 production drag policy and clipped hit geometry: PASS')

// Source validity remains live while visual projection order is frozen.
for (const invalidate of [
  f=>f.windows.splice(0,1),
  f=>{f.handles[0].address='0x9'},
  f=>{f.monitors.pop()},
  f=>{f.controller.mappedScreens=[{name:'HDMI-A-1'}]},
  f=>{f.controller.mappedScreens=[]}
]) {
  const x=interactionFixture(),xc=x.controller
  assert.equal(xc.beginRowDrag(xc.captureTarget(xc.projection.rows[0].key)),true)
  xc.updateRowDrag('ws3');invalidate(x)
  assert.equal(xc.finishRowDrag('ws3'),false)
  assert.equal(x.requests.length+x.batches.length,0)
  assert.equal(xc.interactionBusy,false)
}
const busy=interactionFixture();busy.controller.resizeActive=true
assert.equal(busy.controller.beginRowDrag(busy.controller.captureTarget(busy.controller.projection.rows[0].key)),false)
const mf=interactionFixture(),mc=mf.controller
mf.actions.minimizedOrigins={'0x1':{workspace:'name:Design work',monitor:'id:1'}}
mf.handles[0].lastIpcObject.workspace={name:'special:smartdock-minimized'}
assert.equal(mc.beginRowDrag(mc.captureTarget(mc.projection.rows[0].key)),true)
assert.equal(mc.finishRowDrag('ws3'),true)
assert.equal(mf.requests.length,0,'follow restores minimized windows through the batch path')
assert.equal(mf.batches.length,1,'follow-mode restores/moves minimized windows before focusing')
assert.ok(String(mf.batches[0][2]).indexOf('movetoworkspace 3,address:0x1') >= 0,
  'minimized follow restores into the destination instead of only updating the saved origin')
assert.ok(String(mf.batches[0][2]).indexOf('focuswindow address:0x1') >= 0)
assert.equal(mf.actions.minimizedOrigins['0x1'],undefined,'restored windows clear their saved origin')
// Default non-follow callers retain origin-only behavior.
const nf=interactionFixture()
nf.actions.minimizedOrigins={'0x1':{workspace:'name:Design work',monitor:'id:1'}}
nf.handles[0].lastIpcObject.workspace={name:'special:smartdock-minimized'}
const captured=nf.actions.captureWorkspaceMove([nf.windows[0]])
assert.equal(nf.actions.moveCapturedToplevels(captured,'id:3'),true)
assert.equal(nf.requests.length+nf.batches.length,0,'origin-only moves dispatch nothing')
assert.equal(nf.actions.minimizedOrigins['0x1'].workspace,'3')
console.log('SB-04 drag closure/address/topology/mode/resize/minimized regressions: PASS')

// Phase A follow ordering for multiple captured windows: prefer the active member.
{
  const multi=interactionFixture()
  const members=multi.actions.captureWorkspaceMove([multi.windows[0],multi.windows[1]])
  assert.equal(multi.actions.moveCapturedToplevels(members,'id:3',true),true)
  const batch=String(multi.batches[0][2] || multi.batches[0])
  assert.ok(batch.indexOf('address:0x1') >= 0 && batch.indexOf('address:0x2') >= 0)
  // Active toplevel is windows[1] (0x2); its focus must win over the first member.
  assert.ok(batch.lastIndexOf('focuswindow address:0x2') > batch.indexOf('workspace 3'))
  // Rejected or unchanged moves never switch focus.
  multi.clear()
  multi.handles[0].lastIpcObject.workspace={id:3}
  multi.handles[1].lastIpcObject.workspace={id:3}
  assert.equal(multi.actions.moveCapturedToplevels(members,'id:3',true),false,'same-workspace follow is a no-op')
  assert.equal(multi.requests.length+multi.batches.length,0)
}

// Phase B/C temporary monitor-footer targets: allocation, monitor targeting, geometry.
{
  const footerModel=loadModel('DockSidebarInteractionModel')
  assert.equal(footerModel.newWorkspaceFooterTargetHeight(false),32)
  assert.equal(footerModel.newWorkspaceFooterTargetHeight(true),36)
  assert.equal(footerModel.newWorkspaceFooterExtra(false,n=>n),42,
    'expanded footer reserves equal 5px top and bottom padding')
  assert.equal(footerModel.newWorkspaceFooterExtra(true,n=>n),46,
    'collapsed footer reserves equal 5px top and bottom padding')
  const footerKey=footerModel.newWorkspaceFooterKey('id:0')
  assert.equal(footerModel.parseNewWorkspaceFooterKey(footerKey),'id:0')
  assert.equal(footerModel.isNewWorkspaceFooterKey(footerKey),true)
  assert.equal(footerModel.isNewWorkspaceFooterKey('ws3'),false)
  assert.equal(footerModel.isMonitorFinalKey('b',[{kind:'monitor',lastKey:'b'}]),true)
  assert.equal(footerModel.isMonitorFinalKey('a',[{kind:'monitor',lastKey:'b'}]),false)
  assert.doesNotMatch(read('components/DockWindowActions.qml'),/resolveWorkspaceDropTarget\(.*footer|footer.*resolveWorkspaceDropTarget/,
    'new-workspace keys must not pass through existing workspace resolution')

  // Same-monitor creation allocates the lowest free numeric id (1 and 3 exist → 2).
  const same=interactionFixture(),sc=same.controller
  sc.beginRowDrag(sc.captureTarget(sc.projection.rows[0].key))
  const sameKey=footerModel.newWorkspaceFooterKey('id:0')
  assert.deepEqual(plain(sc.dragDestination(sameKey)),{key:sameKey,kind:'new-workspace',monitor:'id:0'})
  assert.equal(sc.updateRowDrag(sameKey),true,'hover highlights without creating anything')
  assert.equal(same.requests.length+same.batches.length,0)
  assert.equal(sc.finishRowDrag(sameKey),true)
  const sameBatch=String(same.batches[0][2])
  assert.ok(sameBatch.indexOf('movetoworkspacesilent 2,address:0x1') >= 0,'move first')
  assert.ok(sameBatch.indexOf('moveworkspacetomonitor 2 0') > sameBatch.indexOf('movetoworkspacesilent 2,address:0x1'),'then relocate the new workspace to the requested monitor')
  assert.ok(sameBatch.indexOf('workspace 2') > sameBatch.indexOf('moveworkspacetomonitor 2 0'))
  assert.ok(sameBatch.indexOf('focuswindow address:0x1') > sameBatch.indexOf('workspace 2'))

  // Cross-monitor creation targets the requested monitor in the legacy backend.
  const cross=interactionFixture(),xcross=cross.controller
  xcross.beginRowDrag(xcross.captureTarget(xcross.projection.rows[0].key))
  const crossKey=footerModel.newWorkspaceFooterKey('id:1')
  assert.equal(xcross.finishRowDrag(crossKey),true)
  assert.ok(String(cross.batches[0][2]).includes('moveworkspacetomonitor 2 1'))

  // Both backends target the requested monitor.
  for (const lua of [false,true]) {
    const both=interactionFixture()
    both.Hyprland.usingLua=lua
    const bc=both.controller
    bc.beginRowDrag(bc.captureTarget(bc.projection.rows[0].key))
    assert.equal(bc.finishRowDrag(footerModel.newWorkspaceFooterKey('id:1')),true)
    const text=lua ? String(both.requests[0]) : String(both.batches[0][2])
    assert.ok(text.includes(lua ? 'monitor = "1"' : 'moveworkspacetomonitor 2 1'),
      'new-workspace commands target the requested monitor in both backends')
    assert.ok(!/current|movecurrentworkspacetomonitor/i.test(text) || text.includes('moveworkspacetomonitor'),
      'explicit relocation, never a focus-dependent current selector')
  }

  // Allocation avoids retained origins and pin records.
  const retained=interactionFixture(),rc=retained.controller
  retained.actions.minimizedOrigins={'0x9':{workspace:'2',monitor:'id:0'}}
  retained.actions.windowWorkspacePins={'0x8':{toplevel:{},address:'0x8',workspace:'id:4'}}
  rc.beginRowDrag(rc.captureTarget(rc.projection.rows[0].key))
  assert.equal(rc.finishRowDrag(footerModel.newWorkspaceFooterKey('id:0')),true)
  const retainedId=String(retained.batches[0][2]).match(/movetoworkspacesilent (\d+),address:0x1/)[1]
  assert.equal(retainedId,'5','allocation avoids occupied ids across monitors and retained origins')

  // Cancelled/stale/disallowed drops dispatch nothing.
  const cancelled=interactionFixture(),cc=cancelled.controller
  cc.beginRowDrag(cc.captureTarget(cc.projection.rows[0].key))
  cc.updateRowDrag(footerModel.newWorkspaceFooterKey('id:0'))
  cc.cancelRowDrag('escape')
  assert.equal(cc.finishRowDrag(footerModel.newWorkspaceFooterKey('id:0')),false)
  assert.equal(cancelled.requests.length+cancelled.batches.length,0)
  const disallowed=interactionFixture(),dc=disallowed.controller
  dc.beginRowDrag(dc.captureTarget('ws'))
  assert.equal(dc.dragDestination(footerModel.newWorkspaceFooterKey('id:0')),null,
    'workspace drags reject new-workspace footers')
  assert.equal(dc.finishRowDrag(footerModel.newWorkspaceFooterKey('id:0')),false)
  assert.equal(disallowed.requests.length+disallowed.batches.length,0)
  const stale=interactionFixture(),stc=stale.controller
  stc.beginRowDrag(stc.captureTarget(stc.projection.rows[0].key))
  stale.handles[0].address='0x9'
  assert.equal(stc.finishRowDrag(footerModel.newWorkspaceFooterKey('id:0')),false)
  assert.equal(stale.requests.length+stale.batches.length,0)
  const pinned=interactionFixture(),pc=pinned.controller
  pc.beginRowDrag(pc.captureTarget(pc.projection.rows[0].key))
  pinned.actions.pinWindowToWorkspace(pinned.windows[0])
  assert.equal(pc.finishRowDrag(footerModel.newWorkspaceFooterKey('id:0')),false)
  assert.equal(pinned.requests.length+pinned.batches.length,0)

  // Expanded/collapsed footer geometry agrees with height estimation; workspace chrome excludes it.
  const viewportSource=read('components/DockSidebarViewport.qml')
  assert.match(viewportSource,/function footerExtraHeight\(\)/)
  assert.match(viewportSource,/function footerHits\(\)/)
  assert.match(viewportSource,/footerExtraHeight\(\)/)
  const rowSource=read('components/DockSidebarRow.qml')
  assert.match(rowSource,/showNewWorkspaceFooter/)
  assert.match(rowSource,/footerTargetHeight/)
  assert.match(rowSource,/New workspace/)
  assert.match(rowSource,/iconName: root\.footerBlocked \? "ban" : "plus"/)
  assert.match(rowSource,/footerAccessibleLabel/)
  assert.match(viewportSource,/sectionSpanRect[\s\S]*?contentHeight \+ Style\.space\(5\)/,
    'workspace backgrounds end at content plus padding, excluding the footer')
  assert.match(viewportSource,/refreshDragTarget\(\)/,
    'stationary pointers retarget after geometry changes')
  assert.match(read('components/DockSidebarController.qml'),/moveCapturedWindowToNewWorkspaceResult\(session\.target, destination\.monitor\)/,
    'sidebar drop completion hands new-workspace destinations to the shared host action')
  assert.match(read('components/DockSidebarController.qml'),/moveCapturedToplevels\(\[session\.target\], destination\.identity, true\)/,
    'sidebar window drops follow the moved window')
}
console.log('SB-04 follow, new-workspace allocation, monitor targeting and footer geometry: PASS')

// R1 task 1: rejection is presentation only, source-kind aware, and never dispatches.
function startWindowDrag(fixture) {
  const ctl = fixture.controller
  assert.equal(ctl.beginRowDrag(ctl.captureTarget(ctl.projection.rows[0].key)), true)
  return ctl
}
function rejected(ctl, key, sourceKind, reason) {
  assert.equal(ctl.updateRowDrag(key), false)
  assert.equal(ctl.dragRejection?.sourceKind, sourceKind)
  assert.equal(ctl.dragRejection?.reason, reason)
  assert.equal(ctl.dragRejection?.key, key)
  assert.equal(ctl.dragTarget, null)
}
{
  const x = interactionFixture(), ctl = startWindowDrag(x)
  rejected(ctl, 'ws', 'window', 'same-workspace')
  assert.equal(ctl.dragRejection.identity, 'name:Design work')
  x.actions.pinWindowToWorkspace(x.windows[0])
  rejected(ctl, 'ws3', 'window', 'pinned')
  assert.equal(ctl.dragRejection.identity, 'name:Design work', 'pin label describes the actual pin')
  x.actions.unpinWindowFromWorkspace(x.windows[0])
  assert.equal(ctl.updateRowDrag('ws3'), true)
  assert.equal(ctl.dragRejection, null, 'rejected → valid clears feedback')
  ctl.updateRowDrag('')
  assert.equal(ctl.dragRejection, null, 'outside all geometry clears feedback')
  x.workspaces.pop()
  rejected(ctl, 'ws3', 'window', 'unknown-location')
  assert.equal(ctl.dragRejection.identity, undefined, 'do not label an unknown destination')
  rejected(ctl, 'deleted-row', 'window', 'stale')
  x.handles[1].lastIpcObject.workspace = {id:1}
  rejected(ctl, ctl.projection.rows[1].key, 'window', 'stale')
  assert.equal(x.requests.length + x.batches.length, 0)
  x.handles[0].address = '0x9'
  assert.equal(ctl.updateRowDrag('ws3'), false)
  assert.equal(ctl.dragSession, null, 'stale source cancels rather than keeping its ghost')
  assert.equal(ctl.dragRejection, null)
}
{
  const x = interactionFixture(), ctl = x.controller
  ctl.projection.rows.push({kind:'monitor',key:'mon1',monitorIdentity:'1',connector:'HDMI-A-1'})
  assert.equal(ctl.beginRowDrag(ctl.captureTarget('ws')), true)
  rejected(ctl, 'mon1', 'workspace', 'same-monitor')
  x.actions.pinWorkspaceToMonitor('name:Design work')
  rejected(ctl, 'mon', 'workspace', 'workspace-pinned')
  assert.equal(ctl.dragRejection.monitor, 'id:1')
  x.actions.unpinWorkspaceFromMonitor('name:Design work')
  // Existing classic policy cannot encode whitespace workspace selectors.
  rejected(ctl, 'mon', 'workspace', 'unknown-location')
  x.Hyprland.usingLua = true
  assert.equal(ctl.updateRowDrag('mon'), true)
  assert.equal(ctl.dragRejection, null)
  ctl.projection.rows.push({kind:'monitor',key:'missing',monitorIdentity:'99'})
  rejected(ctl, 'missing', 'workspace', 'unknown-location')
  rejected(ctl, 'removed', 'workspace', 'stale')
  assert.equal(x.requests.length + x.batches.length, 0)
  ctl.cancelRowDrag('escape')
  assert.equal(ctl.dragRejection, null)
  assert.equal(ctl.beginRowDrag(ctl.captureTarget('ws')), true)
  assert.equal(ctl.dragRejection, null)
  rejected(ctl, 'mon1', 'workspace', 'same-monitor')
  assert.equal(ctl.finishRowDrag('mon1'), false)
  assert.equal(ctl.dragRejection, null)
  assert.equal(ctl.finishRowDrag('mon'), false, 'release consumed even when rejected')
  assert.equal(x.requests.length + x.batches.length, 0)
}
console.log('R1 source-kind rejection and stale-source cancellation: PASS')

// Geometry selects exactly one intent before policy; rejected groups do not
// fall through to monitor destinations behind the same rectangle.
assert.equal(typeof model.hitWindowDrop, 'function')
{
  const bounds={x:0,y:0,width:100,height:140}
  const groups=[{key:'own',kind:'workspace',workspaceIdentity:'id:1',monitorKey:'mon',x:9,y:30,width:82,height:50}]
  const headers=[{key:'mon',kind:'monitor',headerOnly:true,monitorIdentity:'id:0',x:0,y:0,width:100,height:100}]
  const footers=[{key:model.newWorkspaceFooterKey('id:0'),kind:'new-workspace',x:5,y:85,width:90,height:30}]
  assert.equal(model.hitWindowDrop({x:10,y:40},footers,groups,headers,bounds,''),'own')
  assert.equal(model.hitWindowDrop({x:10,y:90},footers,groups,headers,bounds,''),footers[0].key)
  assert.equal(model.hitWindowDrop({x:10,y:130},footers,groups,[],bounds,''),'','Widget tail excluded')
  assert.equal(model.hitWindowDrop({x:10,y:145},footers,groups,headers,bounds,''),'','clipped out')
  groups[0].workspaceIdentity = ''
  assert.equal(model.hitWindowDrop({x:10,y:40},footers,groups,headers,bounds,''),'own','geometric identity survives unavailable policy; no fallback')
  assert.notEqual(footers[0].key,'ws:id:0')
}
const slotRows = {
  mon:{kind:'monitor',key:'mon'},
  w2:{key:'w2',monitorKey:'mon',workspaceIdentity:'id:2'},
  w9:{key:'w9',monitorKey:'mon',workspaceIdentity:'id:9'},
  wn:{key:'wn',monitorKey:'mon',workspaceIdentity:'name:Work'}
}
const slotSpans=[{kind:'monitor',key:'mon',firstKey:'mon',lastKey:'wn'},
  ...['w2','w9','wn'].map(k=>({kind:'workspace',key:k,firstKey:k,lastKey:k}))]
assert.equal(model.workspacePlaceholderSlot('id:3','mon',slotSpans,slotRows).beforeKey,'w9')
assert.equal(model.workspacePlaceholderSlot('name:Alpha','mon',slotSpans,slotRows).beforeKey,'wn')
assert.equal(model.workspacePlaceholderSlot('name:Zed','mon',slotSpans,slotRows).afterKey,'wn')
assert.equal(model.workspacePlaceholderSlot('id:3','missing',slotSpans,slotRows),null)
assert.equal(model.workspacePlaceholderSlot('id:3','empty',[{kind:'monitor',key:'empty',firstKey:'empty',lastKey:'empty'}],{}).afterKey,'empty')
console.log('R1 first-hit priority and sorted numeric/named workspace placeholder: PASS')

// R1 Task 4: headers use the active workspace's live owner, never repair it.
for (const lua of [false, true]) {
  const x = interactionFixture(), ctl = x.controller
  x.Hyprland.usingLua = lua
  startWindowDrag(x)
  assert.equal(ctl.updateRowDrag('mon'), true, 'explicit header targets its active workspace')
  assert.equal(ctl.dragTarget.kind, 'monitor')
  assert.equal(ctl.dragTarget.identity, 'id:1')
  assert.equal(ctl.dragTarget.monitor, 'id:0')
  assert.equal(ctl.finishRowDrag('mon'), true)
  assert.equal(x.batches.length+x.requests.length, 1)
  assert.doesNotMatch(JSON.stringify([x.batches,x.requests]), /moveworkspacetomonitor|workspace\.move/,
    'an existing header destination must never be relocated')
}
for (const when of ['hover', 'release', 'dispatch']) {
  const x = interactionFixture(), ctl = x.controller
  x.monitors[0].activeWorkspace = {id:3}
  startWindowDrag(x)
  if (when !== 'hover') assert.equal(ctl.updateRowDrag('mon'), true)
  if (when === 'dispatch') {
    const cancel = ctl.cancelRowDrag
    ctl.cancelRowDrag = reason => { const result = cancel(reason); x.workspaces[2].monitorID=1; return result }
  } else x.workspaces[2].monitorID=1 // stale header still claims workspace 3 on DP-1
  if (when === 'hover') rejected(ctl, 'mon', 'window', 'owner-mismatch')
  assert.equal(ctl.finishRowDrag('mon'), false, when + ' owner conflict is refused')
  assert.equal(x.requests.length+x.batches.length, 0)
}
for (const invalid of [
  x => { x.monitors[0].activeWorkspace = null },
  x => { x.monitors[0].activeWorkspace = {id:99} },
  x => { x.monitors[0].activeWorkspace = {id:3} },
  x => { x.monitors.pop() }
]) {
  const x=interactionFixture(), ctl=x.controller
  startWindowDrag(x); ctl.updateRowDrag('mon'); invalid(x)
  assert.equal(ctl.finishRowDrag('mon'), false, 'release repeats active identity and topology checks')
  assert.equal(x.requests.length+x.batches.length, 0)
}
{
  const x=interactionFixture(), ctl=x.controller
  startWindowDrag(x); x.actions.pinWindowToWorkspace(x.windows[0])
  rejected(ctl, 'mon', 'window', 'pinned'); assert.equal(ctl.finishRowDrag('mon'), false)
  assert.equal(x.batches.length, 0)
}
for (const minimized of [false, true]) {
  const x=interactionFixture(), ctl=x.controller
  x.handles[0].lastIpcObject.workspace = {id:3}; x.handles[0].lastIpcObject.monitor=0
  ctl.projection.rows[0].workspaceIdentity='id:3'; ctl.projection.rows[0].monitorIdentity='0'
  if (minimized) {
    x.actions.minimizedOrigins={'0x1':{workspace:'id:3', monitor:'id:0'}}
    x.handles[0].lastIpcObject.workspace={name:'special:smartdock-minimized'}
  }
  startWindowDrag(x)
  assert.equal(ctl.updateRowDrag('mon'), true, 'provisional same-monitor other-workspace policy')
  assert.equal(ctl.finishRowDrag('mon'), true)
  assert.equal(x.batches.length, 1)
}
{
  const x=interactionFixture(), ctl=x.controller
  x.Hyprland.usingLua=true
  x.workspaces.push({name:'Docs',monitorID:0}); x.monitors[0].activeWorkspace={name:'Docs'}
  startWindowDrag(x); assert.equal(ctl.updateRowDrag('mon'),true)
  assert.equal(ctl.dragTarget.identity,'name:Docs'); assert.equal(ctl.finishRowDrag('mon'),true)
}
{
  const x=interactionFixture(), ctl=x.controller
  x.handles[0].lastIpcObject.workspace={id:1}; x.handles[0].lastIpcObject.monitor=0
  ctl.projection.rows[0].workspaceIdentity='id:1'
  startWindowDrag(x); rejected(ctl,'mon','window','same-workspace')
  assert.equal(ctl.finishRowDrag('mon'),false)
}
const headerHit={...cardHits[0], headerOnly:true, height:20}
assert.equal(model.hitTarget({x:20,y:12},[headerHit],viewport,'window'),'mon-dp1')
assert.equal(model.hitTarget({x:20,y:55},[headerHit],viewport,'window'),'')
assert.equal(model.hitTarget({x:20,y:55},cardHits,viewport,'window'),'')
console.log('R1 live-owner monitor header drops: PASS')
