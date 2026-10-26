import assert from 'node:assert/strict';
import fs from 'node:fs';
import { loadModel, plain, hostHarness, read } from './host_harness.mjs';
import { qmlMethods } from './sidebar_interaction_fixture.mjs';
assert.ok(fs.existsSync(new URL('../components/DockSidebarWidgetModel.js', import.meta.url)),
  'SB-05 must provide the production widget model');
const Model = loadModel('DockSidebarWidgetModel');

// Test adapters implement the documented lease API. All lifecycle decisions,
// generation checks, geometry, validation and snapshots are production code.
function adapter(id, shared = false) {
  const counts = {acquire:0, release:0, start:0, stop:0, subscriptions:0, notifications:0};
  const callbacks = [];
  let running = shared, active = false;
  const provider = {privateContent:'never put task titles or credentials in diagnostics'};
  const descriptor = {id, label:id, available:true, status:'loading', revision:1,
    expandedView:{}, compactView:{}, popupView:{},
    acquire(owner) {
      assert.ok(owner);
      counts.acquire++;
      let released = false;
      return {provider,
        setActive(value, publish) {
          assert.ok(!released);
          active = value;
          if (value) {
            callbacks.push(publish);
            if (!running) { running = true; counts.start++; counts.subscriptions++; }
            publish({status:'ready', revision:1, data:{text:provider.privateContent}});
          } else if (running && !shared) {running = false; counts.stop++;}
        },
        release() {
          assert.ok(!released, 'lease released twice'); released = true; counts.release++;
          if (running && !shared) {running = false; counts.stop++;}
        }};
    }};
  return {descriptor, provider, counts, callbacks, emit(value) { callbacks.at(-1)(value); },
    get active() {return active;}, get running() {return running;}};
}
const a = adapter('fixture.one'), b = adapter('fixture.two');
const registry = {'fixture.one':a.descriptor, 'fixture.two':b.descriptor};
assert.equal(Model.idsError([], []), '');
assert.equal(Model.idsError(['fixture.two','fixture.one'], Object.keys(registry)), '');
for (const value of [null, {}, 'fixture.one', [1], ['fixture.one','fixture.one'],
  ['unknown'], ['../evil.qml'], ['sh -c whoami'], ['constructor'], [' fixture.one']]) {
  assert.notEqual(Model.idsError(value, Object.keys(registry)), '', JSON.stringify(value));
}
assert.deepEqual(plain(Model.requestedIds(['future.clock','future.clock',4,'../x','fixture.one'])), ['future.clock','fixture.one']);
assert.deepEqual(plain(Model.requestedIds({})), []);
// QML settings/property maps often expose arrays as array-like objects.
assert.deepEqual(plain(Model.requestedIds({0:'future.clock',1:'fixture.one',length:2})),
  ['future.clock','fixture.one']);
assert.equal(Model.idsError({0:'fixture.one',length:1}, Object.keys(registry)), '');
let updates = 0;
const manager = Model.createManager(() => updates++);
const owner = {};
manager.reconcile([], registry, true, owner);
assert.deepEqual(plain(manager.ids()), []);
assert.equal(a.counts.acquire,0);
manager.reconcile(['future.clock','fixture.two','fixture.one'], registry, true, owner);
assert.deepEqual(plain(manager.ids()), ['future.clock','fixture.two','fixture.one']);
assert.equal(manager.view('future.clock').status,'unavailable');
assert.equal(manager.view('future.clock').available,false);
assert.equal(manager.view('fixture.one').status,'ready');
assert.equal(a.counts.acquire,1);
assert.equal(b.counts.acquire,1);
assert.equal(a.counts.subscriptions,1);
assert.equal(manager.view('fixture.one').data.text,'never put task titles or credentials in diagnostics');
const baseline = {...a.counts};
for (let i=0;i<40;i++) {
  // Reconcile the same enabled set as resize/collapse and host refresh would.
  manager.reconcile(['future.clock','fixture.two','fixture.one'], registry, true, owner);
  Model.collapsedMap(i % 2 === 0 ? {'fixture.one':true} : {'fixture.one':false});
}
assert.deepEqual(a.counts,baseline,'presentation reflow must not restart providers');
const reordered = {'fixture.one':{...a.descriptor,revision:2},'fixture.two':b.descriptor};
manager.reconcile(['fixture.one','fixture.two','future.clock'],reordered,true,owner);
assert.equal(a.counts.acquire,1,'descriptor metadata refresh does not reacquire');
assert.deepEqual(plain(manager.ids()),['fixture.one','fixture.two','future.clock']);
a.emit({status:'error',revision:2,data:{token:'SECRET'},message:'SECRET'});
assert.equal(manager.view('fixture.one').status,'error');
assert.equal(manager.view('fixture.two').status,'ready');
a.emit({status:'ready',revision:3,data:{title:'PRIVATE WINDOW'}});
assert.equal(manager.view('fixture.one').status,'ready','provider recovers without restarting');
assert.equal(a.counts.acquire,1);
const beforeSuspend = a.callbacks.at(-1);
manager.reconcile(manager.ids(),registry,false,owner);
assert.equal(a.active,false);
assert.equal(a.counts.stop,1);
const suspendedUpdates = updates;
beforeSuspend({status:'ready',revision:900,data:{secret:'late while suspended'}});
assert.equal(updates,suspendedUpdates,'suspended callback cannot update views');
manager.reconcile(manager.ids(),registry,true,owner);
assert.equal(a.counts.acquire,1,'mode switch retains the enabled provider lease');
assert.equal(a.counts.subscriptions,2);
beforeSuspend({status:'error',revision:901});
assert.equal(manager.view('fixture.one').status,'ready','old activation callback is stale after resume');
const callback = a.callbacks.at(-1);
manager.reconcile(['fixture.two','future.clock'],registry,true,owner);
assert.equal(a.counts.release,1);
assert.equal(a.counts.stop,2);
assert.equal(manager.view('fixture.one'),null);
const afterRemoval = updates;
callback({status:'ready',revision:999,data:{secret:'late'}});
assert.equal(updates,afterRemoval);
manager.reconcile(['fixture.one','fixture.two'],registry,true,owner);
callback({status:'error',revision:1000});
assert.equal(manager.view('fixture.one').status,'ready','re-enabled ID is a new lifetime');
assert.equal(a.counts.acquire,2);
const replacement = adapter('fixture.one');
const replaced = {'fixture.one':replacement.descriptor,'fixture.two':b.descriptor};
const staleBeforeReplacement = a.callbacks.at(-1);
manager.reconcile(['fixture.one','fixture.two'],replaced,true,owner);
assert.equal(a.counts.release,2,'a deliberate acquisition-boundary replacement releases the old lease');
assert.equal(replacement.counts.acquire,1,'a deliberate acquisition-boundary replacement acquires the new lease');
assert.equal(manager.view('fixture.one').provider,replacement.provider,
  'the manager now exposes the replacement provider');
const replacementRevision = manager.view('fixture.one').revision;
staleBeforeReplacement({status:'error',revision:replacementRevision+10});
assert.equal(manager.view('fixture.one').status,'ready','callbacks from the replaced adapter are ignored');
const d = plain(manager.diagnostics());
assert.ok(!JSON.stringify(d).match(/SECRET|PRIVATE|credentials|privateContent/));
assert.equal(d.rows.length,2);
assert.ok(d.counters.ignoredUpdates>=3);
manager.dispose();
manager.dispose();
assert.equal(a.counts.release,2);
assert.equal(b.counts.release,1);
assert.equal(replacement.counts.release,1);
assert.deepEqual(plain(manager.ids()),[]);

// Shared services belong to their owner. The sidebar may release its lease,
// never call stop/destroy on the provider or another consumer's subscription.
const shared = adapter('shared.provider',true);
const sharedManager = Model.createManager(() => {});
sharedManager.reconcile(['shared.provider'],{'shared.provider':shared.descriptor},true,owner);
sharedManager.reconcile([],{},false,owner);
assert.equal(shared.counts.release,1);
assert.equal(shared.counts.stop,0);
assert.ok(shared.running);

// Provider exceptions and malformed updates are contained without logging text.
let invalidRelease = 0;
const errors = Model.createManager(() => {});
const badRegistry = {
  broken:{id:'broken',available:true,acquire(){throw new Error('SECRET');}},
  invalid:{id:'invalid',available:true,acquire(){return {release(){invalidRelease++;}};}},
  'fixture.two':b.descriptor
};
errors.reconcile(['broken','invalid','fixture.two','unknown'],badRegistry,true,owner);
assert.equal(errors.view('broken').status,'error');
assert.equal(errors.view('invalid').status,'error');
assert.equal(invalidRelease,1);
assert.equal(errors.view('fixture.two').status,'ready');
assert.ok(!JSON.stringify(errors.diagnostics()).includes('SECRET'));
b.emit({status:'not-a-status',revision:Infinity,data:{}});
assert.equal(errors.view('fixture.two').status,'error');
b.emit({status:'ready',revision:4});
assert.equal(errors.view('fixture.two').status,'ready');
errors.viewFailed('fixture.two',errors.view('fixture.two'));
assert.equal(errors.view('fixture.two').status,'error');
errors.reconcile(['fixture.two'],{},true,owner);
assert.equal(errors.view('fixture.two').status,'unavailable');
assert.equal(b.counts.release,2,'registry removal releases once');
errors.dispose();
const many=Model.createManager(() => {});
many.reconcile(Array.from({length:100},(_,i)=>'unknown.'+i),{},true,owner);
assert.ok(many.diagnostics().rows.length<=32);
assert.equal(many.diagnostics().total,100);
many.dispose();

// Widget management helpers are presentation-only and never touch provider leases.
assert.deepEqual(plain(Model.collapsedMap({'fixture.one':true,'fixture.two':false,'../bad':true})),
  {'fixture.one':true,'fixture.two':false});
assert.equal(Model.collapsedError({'fixture.one':true,'future.clock':false}), '');
for (const value of [null, [], {'../bad':true}, {'constructor':true}, {'fixture.one':'yes'}])
  assert.notEqual(Model.collapsedError(value), '', JSON.stringify(value));
assert.deepEqual(plain(Model.registeredIds(registry)), ['fixture.one','fixture.two']);
assert.deepEqual(plain(Model.registeredRows(registry).map(row => ({
  id:row.id,label:row.label,available:row.available,manageable:row.manageable
}))), [
  {id:'fixture.one',label:'fixture.one',available:true,manageable:true},
  {id:'fixture.two',label:'fixture.two',available:true,manageable:true}
]);
const absentHerdrRegistry = Object.assign({}, registry, {
  'herdr.agents': Object.assign({}, a.descriptor, {
    id:'herdr.agents', label:'Herdr agents', manageable:false, available:false
  })
});
const presentHerdrRegistry = Object.assign({}, registry, {
  'herdr.agents': Object.assign({}, a.descriptor, {
    id:'herdr.agents', label:'Herdr agents', manageable:true, available:true
  })
});
assert.deepEqual(plain(Model.manageableRows(absentHerdrRegistry, []).map(row => row.id)),
  ['fixture.one','fixture.two'],
  'absent optional integrations stay out of Add/Manage');
assert.deepEqual(plain(Model.manageableRows(presentHerdrRegistry, []).map(row => row.id)),
  ['fixture.one','fixture.two','herdr.agents'],
  'installed Herdr is offered in Add/Manage');
const enabledAbsentRows = plain(Model.manageableRows(
  absentHerdrRegistry, ['herdr.agents']).map(row => ({id:row.id,available:row.available})));
assert.deepEqual(enabledAbsentRows, [
  {id:'fixture.one',available:true},
  {id:'fixture.two',available:true},
  {id:'herdr.agents',available:false}
], 'an enabled Herdr widget remains removable after the binary disappears');
assert.equal(typeof Model.footerLayout, 'undefined',
  'the retired bounded footer layout must not survive the shared-scroll migration');

// FDM-999: independent sibling scroll ownership, with one host-owned lifecycle.
const viewportSource = read('components/DockSidebarViewport.qml');
const sidebarSource = read('components/DockSidebar.qml');
const areaSource = read('components/DockSidebarWidgetArea.qml');
const managerSource = read('components/DockSidebarWidgetManager.qml');
const hostSource = read('DockHost.qml');
const cardSource = read('components/DockWidgetCard.qml');
const runtimeSidebarSource = read('tests/runtime/sidebar.qml');
// FDM-997: optional appearance propagation cannot alter scroll/provider ownership.
assert.match(sidebarSource, /DockSidebarWidgetArea\s*\{[^}]*appearance: root\.sidebarAppearance/);
assert.match(areaSource, /property var appearance: null/);
assert.match(areaSource, /DockWidgetCard\s*\{[^}]*appearance: root\.appearance/);
assert.match(cardSource, /property var appearance: null/);
assert.doesNotMatch(cardSource, /0\.025/, 'header/body must share one idle surface');
assert.match(areaSource, /Ui\.PanelSectionHeader\s*\{[\s\S]*?text: "WIDGETS"/);
assert.match(read('components/DockSidebarPinnedStrip.qml'), /Ui\.PanelSectionHeader\s*\{[\s\S]*?text: "PINNED"/);
assert.match(areaSource, /iconName: "plus"/);
assert.doesNotMatch(normalHeader(areaSource), /text: "Add\/Manage"/);
function normalHeader(source) { return source.slice(source.indexOf('id: sectionHeader'), source.indexOf('id: cardColumn')); }


assert.doesNotMatch(viewportSource, /\bcontentTail\w*\b|ContentTailDrag|footer:\s*Item/,
  'retired Widget-tail APIs must be removed, not left as unused hooks');
assert.doesNotMatch(runtimeSidebarSource, /\bfooter\.layout\.cap\b/,
  'the runtime sidebar fixture must observe the split allocation, not the retired footer cap');
assert.doesNotMatch(runtimeSidebarSource, /\b(?:contentTail\w*|ContentTailDrag|endContentTailDrag|sharedTail\w*)\b/,
  'the runtime sidebar fixture must not revive a retired shared-tail API');
assert.match(viewportSource, /readonly property real naturalContentHeight:/);
assert.match(sidebarSource, /id:\s*middleRegion/);
assert.match(sidebarSource, /hierarchyContentHeight:\s*sidebarViewport\.naturalContentHeight/);
assert.match(sidebarSource, /readonly property var widgetArea:\s*sidebarWidgets/);
assert.match(sidebarSource, /height:\s*middleRegion\.split\.blankHeight/);
assert.match(sidebarSource, /anchors\.bottom:\s*pinnedStrip\.top/);
assert.doesNotMatch(sidebarSource, /widgetOverflowButton|id:\s*widgetOverflow/);
assert.doesNotMatch(areaSource, /footerLayout|openOverflow|overflowNeeded/);
const normalArea = areaSource.slice(0, areaSource.indexOf('  PopupWindow {'));
assert.equal((normalArea.match(/\bFlickable\s*\{/g) || []).length, 1);
assert.match(areaSource, /readonly property int presentedWidgetCount:\s*presentationWidgetIds\.length/);
assert.match(areaSource, /SidebarModel\.herdrFallbackVisible/);
assert.match(areaSource, /boundsBehavior:\s*Flickable\.StopAtBounds/);
assert.match(areaSource, /blocking:\s*false/);
assert.match(areaSource, /presentationClipItem:\s*widgetScroll/);
assert.match(areaSource, /presentationRevision:\s*root\.layoutRevision/);
assert.match(areaSource, /anchorOutsideViewport/);
assert.match(sidebarSource, /DockSidebarWidgetManager\s*\{/,
  'Widget manager must be panel-owned, not tied to a zero-height Widget section');
assert.match(sidebarSource, /onClicked:\s*root\.openWidgetManager\(widgetManage\)/,
  'header Add\/Manage must open the persistent panel-owned manager directly');
assert.doesNotMatch(sidebarSource, /widgetArea\.openManager\(widgetManage\)/,
  'header Add\/Manage must not depend on the Widget section existing');
assert.match(managerSource, /Ui\.PopupCard\s*\{[\s\S]*?id:\s*managerPopup/,
  'Widget manager must use Omarchy native PopupCard chrome');
assert.match(managerSource, /triggerMode:\s*"click"/,
  'Widget manager must use Omarchy outside-click dismissal');
assert.match(managerSource,
  /WidgetModel\.manageableRows\(\s*controller\.widgetRegistry, controller\.widgetIds\)/,
  'manager must retain enabled unavailable integrations for removal');
assert.match(managerSource, /contentHeight:\s*managerPopup\.fittedContentHeight/,
  'Widget manager must size to content instead of reserving a fixed tall window');
assert.match(managerSource, /Ui\.ToggleSwitch\s*\{/,
  'Widget enablement uses the native Omarchy switch affordance');
assert.match(hostSource, /id:\s*"herdr\.agents"[\s\S]*?label:\s*"Herdr agents"/);
assert.match(hostSource, /manageable:\s*root\.herdrBinaryInstalled/);
assert.match(hostSource,
  /available:\s*root\.herdrBinaryInstalled\s*&&\s*root\.herdrService\.available !== false/);
assert.match(hostSource, /acquire:\s*root\.acquireHerdrWidget/,
  'FDM-1032 stable host method identity must remain the acquisition boundary');
assert.match(hostSource,
  /command:\s*\["sh", "-c", "command -v herdr >\/dev\/null 2>&1"\]/,
  'picker readiness must use a bounded binary probe, not provider startup');
assert.match(managerSource, /readonly property bool canToggle: enabledWidget \|\| modelData\.available/,
  'enabled unavailable rows must retain their removal path');
assert.doesNotMatch(managerSource, /popupGeometryFor\(root\.managerAnchor,\s*360,\s*420\)/,
  'legacy fixed manager geometry must not return');
assert.doesNotMatch(managerSource, /text:\s*parent\.enabledWidget\s*\?\s*"Remove"\s*:\s*"Add"/,
  'manager rows should not use text Add\/Remove buttons');
assert.match(cardSource, /Remove from Widgets/);
assert.match(cardSource, /presentation: "expanded"/);
assert.doesNotMatch(cardSource, /presentation: "compact"/);
assert.match(cardSource, /Accessible\.name: root\.badgeCount \+ " notifications"/);

// Header Add/Manage remains callable even when the Widget section is absent.
{
  let opened = null;
  const anchor = {visible:true};
  const shell = qmlMethods('DockSidebar.qml', {
    widgetManager: {
      openFor(value) {
        opened = value;
        return true;
      }
    }
  });
  assert.equal(shell.openWidgetManager(anchor), true);
  assert.equal(opened, anchor);
}

// Production controller mutations write only through the existing host intent.
{
  const intents = [];
  const c = qmlMethods('DockSidebarController.qml', {
    SidebarWidgetModel: Model,
    host: { saveSettingIntent(key,value,expected) {
      intents.push({key,value:plain(value),expected:plain(expected)});
      return {accepted:true,pending:false,reply:{ok:true,data:{applied:true},warnings:[]}};
    }},
    settings:{sidebarWidgets:['fixture.one','fixture.two'],sidebarWidgetCollapsed:{}},
    widgetRegistry:registry, widgetIds:['fixture.one','fixture.two'],
    widgetCollapsed:{}, widgetPopupId:'', widgetPopupAnchor:null,
    widgetDragId:'', interactionBusy:false, resizeActive:false, rowDragActive:false,
    mutationFeedback:'',
    closeWidgetPopup() { this.widgetPopupId = ''; this.widgetPopupAnchor = null },
  });
  assert.equal(c.reorderWidget('fixture.one',1).noop,true,
    'dropping immediately after the source is a no-op');
  const moved=c.reorderWidget('fixture.one',2);
  assert.equal(moved.accepted,true);
  assert.deepEqual(intents.at(-1),{
    key:'sidebarWidgets',value:['fixture.two','fixture.one'],
    expected:['fixture.one','fixture.two']
  });
  c.setWidgetCollapsed('fixture.one',true);
  assert.equal(intents.at(-1).key,'sidebarWidgetCollapsed');
  assert.deepEqual(intents.at(-1).value,{'fixture.one':true});
  c.settings={sidebarWidgets:['fixture.one','fixture.two'],sidebarWidgetCollapsed:{'fixture.one':true}};
  c.widgetCollapsed={'fixture.one':true};
  c.setWidgetEnabled('fixture.one',false);
  assert.deepEqual(intents.at(-1).value,['fixture.two']);
  assert.equal(c.widgetCollapsedFor('fixture.one'),true,
    'removal does not clear the saved collapse preference');
}

// Widget reorder gestures: persist through hostIntent, cancel/no-op cleanly, reject busy starts.
{
  const intents = [];
  const three = adapter('fixture.three');
  const reorderRegistry = {
    'fixture.one': a.descriptor,
    'fixture.two': b.descriptor,
    'fixture.three': three.descriptor,
  };
  const c = qmlMethods('DockSidebarController.qml', {
    SidebarWidgetModel: Model,
    host: { saveSettingIntent(key,value,expected) {
      intents.push({key,value:plain(value),expected:plain(expected)});
      return {accepted:true,pending:false,reply:{ok:true,data:{applied:true},warnings:[]}};
    }},
    settings:{sidebarWidgets:['fixture.one','fixture.two','fixture.three'],sidebarWidgetCollapsed:{}},
    widgetRegistry:reorderRegistry,
    widgetIds:['fixture.one','fixture.two','fixture.three'],
    widgetCollapsed:{}, widgetPopupId:'', widgetPopupAnchor:null,
    widgetDragId:'', interactionBusy:false, resizeActive:false, rowDragActive:false,
    mutationFeedback:'',
    closeWidgetPopup() { this.widgetPopupId = ''; this.widgetPopupAnchor = null },
  });
  assert.equal(c.beginWidgetReorder('fixture.one'), true);
  assert.equal(c.widgetDragId, 'fixture.one');
  assert.equal(c.interactionBusy, true);
  assert.equal(c.beginWidgetReorder('fixture.two'), false, 'busy rejects a second reorder start');
  const before = intents.length;
  assert.equal(c.finishWidgetReorder(1, false).noop, true, 'drop beside source is a no-op');
  assert.equal(intents.length, before);
  assert.equal(c.widgetDragId, '');
  assert.equal(c.interactionBusy, false);
  assert.equal(c.finishWidgetReorder(2, false).noop, true, 'finish is idempotent once consumed');

  assert.equal(c.beginWidgetReorder('fixture.one'), true);
  const persisted = c.finishWidgetReorder(3, false);
  assert.equal(persisted.accepted, true);
  assert.equal(persisted.noop, undefined);
  assert.deepEqual(intents.at(-1), {
    key: 'sidebarWidgets',
    value: ['fixture.two', 'fixture.three', 'fixture.one'],
    expected: ['fixture.one', 'fixture.two', 'fixture.three'],
  }, 'accepted finish persists the new order through hostIntent');

  assert.equal(c.beginWidgetReorder('fixture.two'), true);
  const cancelBefore = intents.length;
  c.cancelWidgetReorder();
  assert.equal(c.widgetDragId, '');
  assert.equal(c.interactionBusy, false);
  assert.equal(c.finishWidgetReorder(0, false).noop, true,
    'finish after cancel does not write');
  assert.equal(intents.length, cancelBefore);
  c.cancelWidgetReorder();
  assert.equal(c.interactionBusy, false, 'cancel remains idempotent');

  c.interactionBusy = true;
  assert.equal(c.beginWidgetReorder('fixture.one'), false, 'busy rejects start without session');
  c.interactionBusy = false;
  assert.equal(c.beginWidgetReorder('missing.widget'), false);
}

// Widget area drag cleanup stays synced with controller cancel and preserves hidden IDs.
{
  const controller = qmlMethods('DockSidebarController.qml', {
    SidebarWidgetModel: Model,
    host: { saveSettingIntent() {
      return {accepted:true,pending:false,reply:{ok:true,data:{applied:true},warnings:[]}};
    }},
    settings:{sidebarWidgets:['hidden.one','fixture.one','fixture.two'],sidebarWidgetCollapsed:{}},
    widgetRegistry:registry,
    widgetIds:['hidden.one','fixture.one','fixture.two'],
    widgetCollapsed:{}, widgetPopupId:'', widgetPopupAnchor:null,
    widgetDragId:'', interactionBusy:false, resizeActive:false, rowDragActive:false,
    mutationFeedback:'',
    closeWidgetPopup() { this.widgetPopupId = ''; this.widgetPopupAnchor = null },
  });
  const viewport = {};
  const widgetScroll = {width:280,height:200,contentItem:{},mapFromItem(_item,x,y){return {x,y}}};
  const area = qmlMethods('DockSidebarWidgetArea.qml', {
    controller,
    panel: { panelCollapsed: false, visible: true, contentItem: {}, height: 400, width: 280, screen: {width:1920,height:1080} },
    viewport, widgetScroll, sectionVisible:true, presentedWidgetCount:2, pendingRestore:true,
    layoutTimer:{restart(){}}, geometryTimer:{restart(){}},
    presentationWidgetIds: ['fixture.one', 'fixture.two'],
    dragWidgetId: '',
    dragTargetSlot: -1,
    dragSceneX: 0,
    dragSceneY: 0,
    cardRepeater: { itemAt() { return null } },
    cardColumn: { mapFromItem() { return {x:0,y:0} } },
  });
  assert.equal(area.fullReorderSlot(0), 1, 'visible slot 0 maps past the hidden prefix');
  assert.equal(area.fullReorderSlot(2), 3, 'append stays after the last visible id in the full list');
  assert.equal(area.beginDrag('fixture.one', 10, 20), true);
  assert.equal(area.dragWidgetId, 'fixture.one');
  assert.equal(area.dragTargetSlot, 2, 'target is computed in the independent Widget column');
  controller.cancelWidgetReorder();
  area.syncDragFromController();
  assert.equal(area.dragWidgetId, '');
  assert.equal(area.dragTargetSlot, -1, 'controller cancel clears Widget auto-scroll target');
  area.finishDrag(0, 0, true);
  area.finishDrag(0, 0, true);
  assert.equal(controller.interactionBusy, false, 'finish stays idempotent after cancel');
}

// A deferred view error from an old instance/revision cannot poison recovery.
{
  const fixture=adapter("fixture.one");
  const manager=Model.createManager(()=>{});
  const descriptors={'fixture.one':fixture.descriptor};
  manager.reconcile(['fixture.one'],descriptors,true,{});
  const old=manager.view('fixture.one');
  manager.reconcile([],descriptors,true,{});
  manager.reconcile(['fixture.one'],descriptors,true,{});
  manager.viewFailed('fixture.one',old);
  assert.notEqual(manager.view('fixture.one').errorCode,'view-error');
  manager.dispose();
}
// Actual config/host command methods, not a reimplemented write transport.
const h=hostHarness({sidebarWidgets:['future.clock'],extensionData:{preserve:true}});
assert.deepEqual(h.request('config.get',{key:'sidebarWidgets'}).data.settings.sidebarWidgets,['future.clock']);
assert.equal(h.request('config.apply',{patch:{sidebarWidgets:['fixture.one']}}).ok,false);
assert.equal(h.request('config.apply',{patch:{sidebarWidgets:[]}}).ok,true);
assert.deepEqual(h.request('config.get',{key:'sidebarWidgets'}).data.settings.sidebarWidgets,[]);
const controllerSource=read('components/DockSidebarController.qml');
assert.match(controllerSource,/SidebarWidgetModel\.createManager/,'the actual host-owned controller must create the manager');
assert.match(controllerSource,/widgetManager\.dispose\(/,'the host must clean up leases');
assert.match(read('DockHost.qml'),/widgetRegistry: root\.sidebarWidgetRegistry/,'production registry supplied by host, not settings');
console.log('Widget registry lifecycle, split-scroll management helpers and host config: PASS');
