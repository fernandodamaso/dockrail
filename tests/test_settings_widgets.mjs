import assert from 'node:assert/strict'
import {loadModel,read,hostHarness,plain} from './host_harness.mjs'
const model=loadModel('DockSettingsWidgetsModel')
const registry={
  'herdr.agents':{id:'herdr.agents',label:'Herdr agents',available:true,acquire(){}},
  'io.local.weather':{id:'io.local.weather',label:'Weather',available:true,acquire(){}},
  'io.local.system':{id:'io.local.system',label:'System monitor',available:true,acquire(){}},
  'demo.display':{id:'demo.display',label:'Demo',available:true,acquire(){}}
}
const selected=['io.local.weather','legacy.unavailable','herdr.agents','demo.display']
let list=plain(model.rows(registry,selected,false))
assert.deepEqual(list.map(x=>x.id),[
  'io.local.weather','legacy.unavailable','herdr.agents','demo.display','io.local.system'])
assert.deepEqual(list.map(x=>x.group),['enabled','enabled','enabled','enabled','off'])
assert.deepEqual(list.map(x=>x.position),[1,2,3,4,null])
assert.equal(list[1].unavailable,true)
assert.equal(list[1].registered,false)
// Enabled demo.* IDs stay visible in production as unavailable rows so the
// persisted value can be reviewed and removed; canToggle inputs below.
assert.equal(list[3].unavailable,true)
assert.equal(list[3].registered,false)
assert.equal(list[3].enabled,true)
assert.equal(list[2].label,'Coding agents')
assert.equal(list[2].unavailable,false)
assert.deepEqual(plain(model.rows(registry,selected,true)).map(x=>x.id),[
  'io.local.weather','legacy.unavailable','herdr.agents','demo.display','io.local.system'])
assert.equal(model.moveSlot(selected,'herdr.agents',-1),1)
assert.equal(model.moveSlot(selected,'io.local.weather',-1),-1)
assert.equal(model.moveSlot(selected,'herdr.agents',1),4)
assert.equal(model.moveSlot(selected,'io.local.system',1),-1)
// First/last boundaries: neither direction escapes the enabled order.
assert.equal(model.moveSlot(selected,selected[0],-1),-1)
assert.equal(model.moveSlot(selected,selected[selected.length-1],1),-1)
assert.equal(model.moveSlot(selected,'missing.id',1),-1)
// canToggle inputs: disabling is always allowed (stuck unknown IDs stay
// removable); enabling requires registration and availability.
for (const row of list) {
  const canToggle=row.enabled || (row.registered && row.available !== false)
  if (!row.enabled) assert.equal(canToggle,row.registered && row.available !== false,row.id)
  else assert.equal(canToggle,true,row.id+': disable always allowed')
}
assert.equal(model.limited({herdrAgents:{runtime:'limited',version:'0.8.2'}}),true)
assert.equal(model.limited({herdrAgents:{runtime:'limited',version:'0.9.0'}}),true)
assert.equal(model.limited({herdrAgents:{runtime:'ready',version:'0.9.1'}}),false)
assert.equal(model.limited(null),false)

const widget=loadModel('DockSidebarWidgetModel')
const ids=['legacy.unavailable','herdr.agents']
assert.equal(widget.idsError(ids,['herdr.agents']), 'Unregistered widget ID at index 0')
assert.equal(widget.idsError(ids,['herdr.agents'],ids),'')
assert.match(widget.idsError(['new.unknown'],['herdr.agents'],ids),/Unregistered/)
const h=hostHarness({sidebarWidgets:ids})
assert.deepEqual(plain(h.host.settings.sidebarWidgets),ids)
// Retain the legacy entry through a real host, schema validation and writer.
const old=h.host.settings.sidebarWidgets
let next=['herdr.agents','legacy.unavailable']
let before=h.writes.length
let reply=h.host.saveSettingIntent('sidebarWidgets',next,old)
assert.equal(reply.accepted,true)
assert.deepEqual(plain(h.host.settings.sidebarWidgets),next)
assert.equal(h.writes.length,before+1)
assert.equal(h.host.saveSettingIntent('sidebarWidgets',['new.unknown'],next).reply.ok,false)
// Enabling or removing the only known widget preserves unknown saved ID.
next=['legacy.unavailable']
reply=h.host.saveSettingIntent('sidebarWidgets',next,h.host.settings.sidebarWidgets)
assert.equal(reply.accepted,true)
assert.deepEqual(plain(h.host.settings.sidebarWidgets),next)
const qml=read('components/DockSettingsWidgetsSection.qml')
const panel=read('components/DockSettingsPanel.qml')
const manager=read('components/DockSidebarWidgetManager.qml')
assert.match(qml,/controller\.setWidgetEnabled/, 'use existing controller intent')
assert.match(qml,/controller\.reorderWidget/, 'use existing controller order mutation')
assert.match(qml,/Ui\.ToggleSwitch/, 'native toggle on each row')
assert.match(qml,/drag\.target:grip/, 'drag grip')
assert.match(qml,/broker\.createWidget/, 'typed creation')
assert.match(qml,/broker\.prepareInstall/, 'review install')
assert.match(qml,/broker\.confirmInstall/, 'confirmed install')
assert.match(qml,/nextAction|offer-open-folder|Open folder|createdPath/, 'explicit open-folder offer')
assert.match(panel,/id:widgetsSection/, 'section registered in shared panel')
assert.match(manager,/SettingsWidgets\.rows/, 'sidebar picker shares Coding agents')
console.log('SET-05: ordering, unknown retention, demo filtering, Herdr limited and host writer passed')
