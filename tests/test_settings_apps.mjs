import assert from 'node:assert/strict'
import {hostHarness,loadModel,plain,read} from './host_harness.mjs'

const Apps=loadModel('DockSettingsAppsModel')
const Icon=loadModel('DockIconModel')
const Registry=loadModel('DockSettingsRegistry')
const metadata=JSON.parse(read('config/settings-schema.json'))
const appKeys=Registry.sectionRows(metadata,'apps').map(row=>row.key)
assert.deepEqual(Array.from(appKeys),[
  'pinned','hiddenApplications','iconOverrides','windowIconOverrides',
  'browserProfileBadgesEnabled','sidebarBrowserTabsEnabled',
  'browserActivityMutedServices','showTrash','controlCommand'
])
assert.equal(metadata.settings.controlCommand.ui.visibility,'advanced')
const catalog=[{id:'code',name:'Editor',icon:'code'},
  {id:'Hidden.App',name:'Hidden app',icon:'hidden'}]
assert.deepEqual(plain(Apps.applicationRows(['Code','Missing.App'],catalog)),[
  {id:'Code',index:0,name:'Editor',available:true,icon:'code'},
  {id:'Missing.App',index:1,name:'Missing.App',available:false,icon:''}
])
const pins=['Code','Hidden.App','Missing.App']
assert.deepEqual(plain(Apps.moveArguments(pins,'Code',1)),{id:'Code',after:'Hidden.App'})
assert.deepEqual(plain(Apps.moveArguments(pins,'Missing.App',-1)),{id:'Missing.App',before:'Hidden.App'})
assert.equal(Apps.moveArguments(pins,'Code',-1),null)
assert.equal(Apps.moveArguments(pins,'unknown',1),null)
assert.deepEqual(plain(Apps.dragArguments(pins,'Code','Missing.App')),
  {id:'Code',after:'Missing.App'})
assert.deepEqual(plain(Apps.dragArguments(pins,'Missing.App','Code')),
  {id:'Missing.App',before:'Code'})
assert.equal(Apps.dragArguments(pins,'Code','Code'),null)
const h=hostHarness({
  pinned:pins,hiddenApplications:['Hidden.App','Missing.App'],
  iconOverrides:{
    code:'file:///icons/a.svg',
    'google-chrome@profile:Work':'file:///icons/work.svg'
  },
  windowIconOverrides:[
    {appId:'com.mitchellh.ghostty',titlePattern:'*solar*',source:'file:///icons/sun.svg'},
    {appId:'com.mitchellh.ghostty',titlePattern:'*lunar*',source:'file:///icons/moon.svg'}
  ],
  browserActivityMutedServices:['gmail','legacy.service'],
  showTrash:true,controlCommand:'omarchy-menu toggle apps',
  extensionData:{keep:1}
},catalog)
const entries=plain(Apps.iconRows(h.host.settings,catalog))
assert.equal(entries.length,4)
assert.deepEqual(entries.map(e=>e.kind),['app','profile','window','window'])
assert.equal(entries[0].name,'Editor')
assert.equal(entries[1].profileKey,'Work')
assert.equal(entries[2].titlePattern,'*solar*')
assert.deepEqual(plain(Apps.muteOptions(h.host.settings.browserActivityMutedServices)).map(x=>x.value),
  ['gmail','whatsapp','instagram','legacy.service'])
// Only the host's primitive app intents commit. Hidden state and unknown keys
// survive app ordering, and Show all never changes pin membership.
let reply=h.host.changeApplication('move',Apps.moveArguments(h.host.settings.pinned,'Code',1))
assert.equal(reply.ok,true)
assert.deepEqual(plain(h.host.settings.pinned),['Hidden.App','Code','Missing.App'])
assert.deepEqual(plain(h.host.settings.hiddenApplications),['Hidden.App','Missing.App'])
reply=h.host.changeApplication('show',{id:'Hidden.App'})
assert.equal(reply.ok,true)
assert.deepEqual(plain(h.host.settings.hiddenApplications),['Missing.App'])
reply=h.host.changeApplication('show',{all:true})
assert.equal(reply.ok,true)
assert.deepEqual(plain(h.host.settings.hiddenApplications),[])
assert.deepEqual(plain(h.host.settings.pinned),['Hidden.App','Code','Missing.App'])
assert.deepEqual(plain(h.host.settings.extensionData),{keep:1})
// Individual icon reset uses the same captured-snapshot Change Icon intent.
// No second icon writer or whole icon collection replacement.
const solar=entries[2]
const snapshot={kind:'window',key:Icon.windowRuleKey(solar.appId,solar.titlePattern),
  appId:solar.appId,titlePattern:solar.titlePattern,source:solar.source}
reply=h.host.saveIconChange({remove:snapshot,set:null})
assert.equal(reply.ok,true)
assert.deepEqual(plain(h.host.settings.windowIconOverrides),
  [{appId:'com.mitchellh.ghostty',titlePattern:'*lunar*',source:'file:///icons/moon.svg'}])
const stale=h.host.saveIconChange({remove:snapshot,set:null})
assert.equal(stale.error.code,'E_CONFLICT')
reply=h.host.saveIconChange({remove:{kind:'profile',key:entries[1].key,source:entries[1].source},set:null})
assert.equal(reply.ok,true)
assert.deepEqual(plain(h.host.settings.iconOverrides),{code:'file:///icons/a.svg'})
const before=h.writes.length
reply=h.host.saveSettingIntent('controlCommand','omarchy-menu toggle apps --compact',
  h.host.settings.controlCommand)
assert.equal(reply.ok,true)
assert.equal(h.writes.length,before+1)
assert.equal(h.host.settings.controlCommand,'omarchy-menu toggle apps --compact')
assert.equal(h.host.saveSettingIntent('controlCommand','bad','old command').reply.error.code,'E_STALE')
const section=read('components/DockSettingsAppsSection.qml')
const panel=read('components/DockSettingsPanel.qml')
const host=read('DockHost.qml')
const iconDialog=read('components/DockIconDialog.qml')
assert.match(section,/Apps\.moveArguments\(/)
assert.match(section,/host\.changeApplication\("move"/)
assert.match(section,/host\.changeApplication\("show",\{all:true\}\)/)
assert.match(section,/host\.unpinApplication\(/)
assert.match(section,/host\.saveIconChange\(\{remove:target,set:null\}\)/)
assert.match(section,/host\.saveSettingIntent\("controlCommand"/)
assert.match(section,/Ui\.MultiSelect/)
assert.match(section,/DockSettingsRow/)
assert.match(section,/drag\.target:grip/)
assert.match(section,/onTextEdited:root\.commandDraft=text/)
assert.match(section,/host\.featureReadinessBridge\.lastGoodFeatures/)
assert.match(panel,/onRequestShowAll:showAllConfirm\.opened=true/)
assert.match(panel,/Ui\.ConfirmDialog/)
assert.match(panel,/Shortcut \{ sequence: "Alt\+Up"/)
assert.match(panel,/id:appsLoader/)
assert.match(host,/DockAppPicker \{/)
assert.match(host,/DockIconDialog \{mutationController:root\}/)
assert.match(host,/function openIconFromSettings/)
assert.match(iconDialog,/DockIconModel\.windowIconTarget\(root\.openedSettings/,
  'Change Icon opens the exact existing title-rule, not a different matching window')
assert.doesNotMatch(section,/Quickshell\.execDetached|controlCommand\s*\(|\.setText\(/)
console.log('SET-07: schema homes, app intents, icon slots, Chrome and advanced invariants passed')
