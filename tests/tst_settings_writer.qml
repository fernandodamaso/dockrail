import QtQuick
import QtTest
import "SettingsSourceHarness.js" as Source

TestCase {
  id:testCase
  name:"SettingsProductionWriter"
  when:windowShown
  width:800; height:700
  visible:true
  property var host:null
  function init(){host=Source.createHost(testCase)}
  function cleanup(){host.destroy();host=null}
  function cli(command,args){return host.control.handle(JSON.stringify({apiVersion:1,command:command,arguments:args||{}}))}
  function test_apply_persist_and_readback(){
    var result=host.saveSettingIntent("margin",12,host.settings.margin)
    verify(result.accepted); verify(host.settingsPersisted)
    compare(JSON.parse(host.file.cachedText).margin,12)
    compare(cli("config.get",{key:"margin"}).data.settings.margin,12)
  }
  function test_persistence_failure_retry_keeps_current_snapshot(){
    host.file.fail=true
    ignoreWarning(/Dock: could not save/)
    var result=host.saveSettingIntent("margin",12,host.settings.margin)
    verify(result.accepted); compare(host.settingsWriteState,"error"); verify(!host.settingsPersisted)
    host.file.fail=false
    verify(host.settingsPanel.reportWrite(host.retrySettings()))
    compare(host.settingsWriteState,"saved"); verify(host.settingsPersisted)
    compare(JSON.parse(host.file.cachedText).margin,12)
  }
  function test_cli_race_rejects_single_and_multi_key_drafts(){
    var initial=host.settings.margin
    verify(cli("config.apply",{patch:{margin:19}}).ok)
    compare(host.saveSettingIntent("margin",12,initial).reply.error.code,"E_STALE")
    var before=host.settings.autoHide
    var pair=host.saveSettingsIntent({margin:12,autoHide:!before},{margin:initial,autoHide:before})
    compare(pair.reply.error.code,"E_STALE"); compare(host.settings.autoHide,before)
  }
  function test_busy_after_acceptance_is_saving(){
    host.file.defer=true
    var result=host.saveSettingsIntent({margin:12},{margin:host.settings.margin})
    verify(result.accepted); verify(result.pending); compare(host.settingsWriteState,"saving")
    verify(host.settingsPanel.reportWrite(result))
    compare(host.saveSettingIntent("margin",14,12).accepted,false)
    host.settingsSaved(); verify(host.settingsPersisted)
  }
  function test_invalid_config_blocks_writer_and_panel(){
    ignoreWarning(/Dock: could not load/)
    host.settingsFileLoaded("{bad")
    compare(host.settingsLoadState,"invalid")
    verify(host.settingsPanel.readOnly)
    compare(host.saveSettingIntent("margin",12,host.settings.margin).reply.error.code,"E_CONFIG_INVALID")
  }
  function test_three_display_mode_cards() {
    var cards=host.settingsPanel.layoutView.layoutCards
    compare(cards.length,3)
    compare(cards[0].id,"displays"); compare(cards[1].id,"sidebar"); compare(cards[2].id,"classic")
    verify(cards[2].rows.some(function(row){return row.key==="margin"}))
    verify(cards[2].rows.some(function(row){return row.key==="autoHide"}))
    verify(cards[2].rows.some(function(row){return row.key==="workspaceLayout"}))
  }
  function test_full_layout_keeps_draft_across_cli_update() {
    host.connectedScreens=[{name:"DP-1",width:1920,height:1080}]
    host.settingsPanel.openFor(testCase,"bottom","layout")
    var layout=host.settingsPanel.layoutView
    tryVerify(function(){return layout.targets.some(function(item){return item.key==="margin"})})
    var row=layout.targets.filter(function(item){return item.key==="margin"})[0]
    row.beginEdit(); row.draft=22
    verify(cli("config.apply",{patch:{margin:19,workspaceLayout:"grouped"}}).ok)
    wait(0)
    var current=layout.targets.filter(function(item){return item.key==="margin"})[0]
    compare(current,row,"Live updates must not recreate interaction rows")
    verify(row.conflict); compare(row.draft,22)
    verify(!row.commitDraft())
  }
  function test_layout_keyboard_writes_connected_monitor() {
    host.connectedScreens=[{name:"DP-1",width:1920,height:1080}]
    host.settingsPanel.openFor(testCase,"bottom","layout")
    var panel=host.settingsPanel, layout=panel.layoutView
    tryVerify(function(){return layout.targets.length>0})
    panel.keyCatcher.forceActiveFocus()
    keyClick(Qt.Key_Tab)
    compare(panel.focusPane,"settings")
    keyClick(Qt.Key_L)
    compare(host.settings.presentationModeByMonitor["DP-1"],"sidebar")
    compare(host.settings.presentationMode,"classic")
    verify(host.settingsPersisted)
    keyClick(Qt.Key_J)
    compare(layout.cursor,1)
    keyClick(Qt.Key_Tab)
    compare(panel.focusPane,"sections")
  }
  function test_layout_order_keyboard_preserves_disconnected_entries() {
    host.connectedScreens=[{name:"DP-1",width:1920,height:1080},{name:"DP-2",width:1920,height:1080}]
    host.saveSettingIntent("workspaceMonitorOrder",["DP-2","OFFLINE","DP-1"],[])
    host.settingsPanel.openFor(testCase,"bottom","layout")
    var layout=host.settingsPanel.layoutView
    verify(layout.chooseAutomaticOrder())
    compare(host.settings.workspaceMonitorOrder.length,0)
    verify(layout.chooseAutomaticOrder())
    compare(host.settings.workspaceMonitorOrder.join(","),"DP-2,OFFLINE,DP-1")
    tryVerify(function(){return layout.targets.some(function(item){return item.modelData==="DP-1"})})
    var target=layout.targets.filter(function(item){return item.modelData==="DP-1"})[0]
    layout.focusTarget(layout.targets.indexOf(target))
    host.settingsPanel.focusPane="settings"
    host.settingsPanel.keyCatcher.forceActiveFocus()
    keyClick(Qt.Key_Up,Qt.AltModifier)
    compare(host.settings.workspaceMonitorOrder.join(","),"DP-2,DP-1,OFFLINE")
  }
  function test_layout_stale_topology_rejects_without_overwrite() {
    host.connectedScreens=[{name:"DP-1",width:1920,height:1080}]
    var token={connector:"DP-1",mode:"classic",source:"default",hasOverride:false,overrideValue:null,inheritedMode:"classic"}
    host.connectedScreens=[]
    verify(!host.settingsPanel.layoutView.chooseMonitor("DP-1","sidebar",token))
    compare(Object.keys(host.settings.presentationModeByMonitor).length,0)
  }
  function test_icon_handoff_closes_single_settings_panel(){
    host.settingsPanel.openFor(testCase,"bottom","layout")
    verify(host.settingsPanel.panelOpen)
    var dialog={dialogActive:true,closeDialog:function(){this.dialogActive=false}}
    verify(host.claimIconDialog(dialog))
    verify(!host.settingsPanel.panelOpen)
    compare(host.activeIconDialog,dialog)
    host.releaseIconDialog(dialog)
  }
}
