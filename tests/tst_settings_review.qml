import QtQuick
import QtTest
import "../components"

TestCase {
  id: testCase
  name: "SettingsReview"
  when: windowShown
  width: 800; height: 700
  visible:true
  property var metadata: ({settings:{margin:{type:"integer",minimum:0,ui:{label:"Margin",control:"number",uiMaximum:64}},windowScope:{type:"string",enum:["all","workspace","monitor"],ui:{label:"Scope",control:"dropdown"}},reserveSpace:{type:"boolean",ui:{label:"Reserve space",control:"toggle",requires:{autoHide:false}}}}})
  Component {
    id: hostFactory
    Item {
      property var settings: ({margin:10, windowScope:"all", autoHide:false, reserveSpace:true,workspaceMonitorOrder:[],workspaceLayout:"flat",sidebarCollapsedByMonitor:{},sidebarCollapsed:false,presentationMode:"classic"})
      property string settingsLoadState: "loaded"
      property string settingsWriteState: "saved"
      property bool settingsPersisted: true
      property string settingsWriteError: ""
      property string runtimeMode: "plugin"
      property string configPath: "/fixture/dock.json"
      property var featureReadinessBridge: null
      property var nextReply: null
      property var writes: []
      function saveSettingIntent(key, value, expected) {
        if (settings[key] !== expected) return {accepted:false,reply:{ok:false,error:{code:"E_STALE",message:"Changed"}}}
        if (nextReply) return nextReply
        writes = writes.concat([{key:key,value:value,expected:expected}])
        var next = Object.assign({},settings); next[key] = value; settings=next
        return {accepted:true,reply:{ok:true,data:{applied:true}}}
      }
      function currentPresentation() {return {entries:[],classicScreens:["DP-1"]}}
      function retrySettings() {return {ok:false,error:{code:"E_PERSISTENCE",message:"Disk full"},data:{applied:false}}}
      function releaseSettingsPanel(panel) {}
      function shownSetting(key) {return settings[key]}
    }
  }
  Component { id: rowFactory; DockSettingsRow {width:400} }
  Component { id: panelFactory; DockSettingsPanel {} }
  function makeRow(key) {
    var host=createTemporaryObject(hostFactory,testCase)
    return createTemporaryObject(rowFactory,host,{host:host, row:{key:key,spec:metadata.settings[key],ui:metadata.settings[key].ui},monitorCount:2})
  }
  function test_dependencies_disable_without_rewriting_request() {
    var row=makeRow("reserveSpace")
    verify(row.editable)
    row.host.settings=Object.assign({},row.host.settings,{autoHide:true})
    verify(!row.editable)
    compare(row.host.settings.reserveSpace,true)
  }
  function test_conflict_keeps_draft_until_explicit_resolution() {
    var row=makeRow("margin")
    row.beginEdit(); row.draft=22
    row.host.settings=Object.assign({},row.host.settings,{margin:15})
    verify(!row.commitDraft())
    compare(row.draft,22); verify(row.conflict)
    row.keepEditing(); compare(row.draft,22)
    verify(row.commitDraft()); compare(row.host.settings.margin,22)
  }
  function test_reload_and_validation_preserve_honest_draft() {
    var row=makeRow("margin")
    row.beginEdit(); row.draft=22
    row.host.nextReply={accepted:false,reply:{ok:false,error:{code:"E_VALIDATION",message:"No"}}}
    verify(!row.commitDraft()); compare(row.draft,22); verify(row.editing)
    row.reloadDraft(); compare(row.draft,10); verify(!row.editing)
  }
  function test_live_external_change_highlight() {
    var row=makeRow("margin")
    row.host.settings=Object.assign({},row.host.settings,{margin:18})
    verify(row.changedElsewhere)
    compare(row.current,18)
  }
  function test_pointer_dropdown_snapshots_and_restores_live_binding() {
    var row=makeRow("windowScope")
    var dropdown=findChild(row,"setting-dropdown")
    dropdown.open()
    tryVerify(function(){return dropdown.popupOpen})
    compare(row.expected,"all")
    row.host.settings=Object.assign({},row.host.settings,{windowScope:"workspace"})
    dropdown.value="monitor" // native selection mutates this before changed()
    dropdown.changed("monitor")
    dropdown.close()
    verify(row.conflict); compare(row.host.settings.windowScope,"workspace")
    compare(dropdown.value,"workspace")
    row.reloadDraft()
    row.host.settings=Object.assign({},row.host.settings,{windowScope:"all"})
    compare(dropdown.value,"all")
  }
  function test_reanchor_preserves_keyboard_pane() {
    var host=createTemporaryObject(hostFactory,testCase)
    var panel=createTemporaryObject(panelFactory,host,{host:host,metadata:metadata})
    panel.openFor(testCase,"bottom","layout")
    panel.focusPane="settings"
    panel.openFor(testCase,"left")
    compare(panel.focusPane,"settings")
    compare(panel.selectedSection,"layout")
  }
  function test_retry_handles_raw_host_envelope() {
    var host=createTemporaryObject(hostFactory,testCase)
    var panel=createTemporaryObject(panelFactory,host,{host:host,metadata:metadata})
    verify(!panel.reportWrite(host.retrySettings()))
    verify(panel.rowFeedback.indexOf("E_PERSISTENCE")>=0)
    verify(panel.reportWrite({ok:false,error:{code:"E_BUSY"},data:{applied:true}}))
    compare(panel.rowFeedback,"")
  }
}
