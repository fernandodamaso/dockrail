import assert from 'node:assert/strict'
import {loadModel, plain, hostHarness} from './host_harness.mjs'
const model = loadModel('DockSettingsRegistry')
// A live dependency change must disable editing, without changing the request.
assert.equal(typeof model.editability, 'function', 'registry must evaluate schema dependencies')
assert.equal(model.editability({requires:{autoHide:false}}, {autoHide:true}, 2).enabled, false)
assert.equal(model.editability({requires:{autoHide:false}}, {autoHide:false}, 2).enabled, true)
assert.equal(model.writeOutcome({ok:false,error:{code:'E_PERSISTENCE',message:'disk'}}).accepted, false)
assert.equal(model.writeOutcome({ok:false,error:{code:'E_BUSY'},data:{applied:true}}).pending, true)
assert.equal(model.writeOutcome({ok:false,error:{code:'E_BUSY'},data:{applied:false}}).accepted, false)
assert.deepEqual(plain(model.manualMonitorOrder(['DP-2','OFFLINE','DP-1'], ['DP-1','DP-3'])), ['DP-2','OFFLINE','DP-1','DP-3'])
assert.deepEqual(plain(model.moveMonitor(['DP-2','OFFLINE','DP-1'], 'DP-1', -1)), ['DP-2','DP-1','OFFLINE'])
assert.equal(model.cliCommand('margin', 12), "dockrail config set margin '12'")
const h = hostHarness({presentationMode:'classic',presentationModeByMonitor:{'DP-1':'sidebar','OFFLINE':'classic'}})
h.host.connectedScreens = [{name:'DP-1',width:1920,height:1080}]
const token = h.host.ScreenPresentationModel.modeGestureToken(h.host.currentPresentation(),'DP-1')
const result = h.host.monitorModeIntent('DP-1','default',token)
assert.equal(result.accepted,true, 'Default must use the same connected-output intent')
assert.deepEqual(plain(h.host.settings.presentationModeByMonitor),{OFFLINE:'classic'})
assert.equal(h.host.monitorModeIntent('DP-1','sidebar',token).reply.error.code,'E_STALE')
console.log('Settings dependencies, outcomes, monitor order and connected-output intents passed')
// Anchor lifetime: stale/hidden anchors cannot make IPC report success.
assert.equal(typeof h.host.unregisterSettingsAnchor,'function')
h.host.settingsAnchors=[]
h.host.settingsAnchor=null
h.host.settingsConnector=''
h.host.activeIconDialog=null
h.host.settingsPanel={panelOpen:false,openFor(anchor,edge,section){this.anchor=anchor;this.section=section;this.panelOpen=true;return true},close(){this.panelOpen=false}}
const hidden={visible:false,width:30,height:30,QsWindow:{window:{screen:{name:'DP-1'}}}}
const visible={visible:true,width:30,height:30,QsWindow:{window:{screen:{name:'DP-1'}}}}
h.host.registerSettingsAnchor(hidden,'DP-1','classic')
h.host.registerSettingsAnchor(visible,'DP-1','classic')
assert.equal(h.host.openSettings(null,''),true)
assert.equal(h.host.settingsPanel.anchor,visible)
h.host.unregisterSettingsAnchor(visible)
assert.equal(h.host.openSettings(null,''),false)
// Focused-monitor summon: IPC/CLI opening prefers the focused output.
h.host.settingsAnchors=[]
h.host.settingsAnchor=null
h.host.settingsConnector='DP-1'
h.host.connectedScreens=[{name:'DP-1',width:1920,height:1080},{name:'DP-2',width:1920,height:1080}]
h.host.hyprMonitors=[{name:'DP-1',focused:false},{name:'DP-2',focused:true}]
const vis1={visible:true,width:30,height:30,QsWindow:{window:{screen:{name:'DP-1'}}}}
const vis2={visible:true,width:30,height:30,QsWindow:{window:{screen:{name:'DP-2'}}}}
h.host.registerSettingsAnchor(vis1,'DP-1','classic')
h.host.registerSettingsAnchor(vis2,'DP-2','classic')
h.host.settingsPanel={panelOpen:false,openFor(anchor,edge,section){this.anchor=anchor;this.section=section;this.panelOpen=true;return true},close(){this.panelOpen=false}}
assert.equal(h.host.focusedSettingsConnector(),'DP-2')
assert.equal(h.host.openSettingsForFocused(),true)
assert.equal(h.host.settingsPanel.anchor,vis2)
assert.equal(h.host.settingsConnector,'DP-2')
// Per-key reset uses the same writer with the default value.
assert.equal(typeof h.host.resetSettingIntent,'function')
const before=h.host.settings.margin
const reset=h.host.resetSettingIntent('margin',before)
assert.equal(reset.accepted,true)
assert.equal(h.host.settings.margin,h.defaults.margin)
console.log('Settings focused summon, anchor lifecycle and per-row reset passed')
