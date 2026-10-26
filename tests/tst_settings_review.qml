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
  Component {
    id: pairHostFactory
    Item {
      property var settings: ({backgroundColor:"#112233",backgroundColorEnabled:true,borderWidth:4,borderWidthEnabled:true,workspaceGroups:[{desktopId:"org.example.App",workspace:"id:1"}]})
      property string settingsLoadState: "loaded"
      property string settingsWriteState: "saved"
      property bool settingsReloadPending: false
      property bool settingsLoaded: true
      property var writes: []
      property var ungroupCalls: []
      property var connectedScreens: []
      function saveSettingsIntent(patch, expected) {
        for (var key in expected)
          if (JSON.stringify(settings[key]) !== JSON.stringify(expected[key]))
            return {accepted:false,reply:{ok:false,error:{code:"E_STALE",message:"Changed"}}}
        writes = writes.concat([{patch:patch,expected:expected}])
        var next = Object.assign({},settings)
        for (var applied in patch) next[applied] = patch[applied]
        settings = next
        return {accepted:true,reply:{ok:true,data:{applied:true}}}
      }
      function defaultSetting(key) {
        return {backgroundColor:"",backgroundColorEnabled:false,borderWidth:2,borderWidthEnabled:false}[key]
      }
      function shownSetting(key) { return settings[key] }
      function ungroupWorkspaceApplication(desktopId, workspace) {
        ungroupCalls = ungroupCalls.concat([{desktopId:desktopId,workspace:workspace}])
        var next = Object.assign({},settings,{workspaceGroups:[]})
        settings = next
        return {accepted:true,reply:{ok:true,data:{applied:true}}}
      }
      function currentPresentation() {return {entries:[],classicScreens:["DP-1"]}}
    }
  }
  Component { id: pairedFactory; DockSettingsPairedRow {width:400} }
  function makePaired(key, flagKey) {
    var host=createTemporaryObject(pairHostFactory,testCase)
    return createTemporaryObject(pairedFactory,host,{host:host,
      row:{key:key,ui:{label:key,help:"",pairedWith:flagKey}}})
  }
  function test_paired_reset_writes_one_atomic_default_patch() {
    var row=makePaired("backgroundColor","backgroundColorEnabled")
    verify(row.needsReset)
    verify(row.resetToDefault())
    compare(row.host.writes.length,1)
    compare(row.host.settings.backgroundColor,"")
    compare(row.host.settings.backgroundColorEnabled,false)
    verify(!row.needsReset)
  }
  function test_paired_external_change_marks_changed_elsewhere() {
    var row=makePaired("borderWidth","borderWidthEnabled")
    row.host.settings=Object.assign({},row.host.settings,{borderWidth:6})
    verify(row.changedElsewhere)
    compare(row.current,6)
  }
  function test_paired_adjust_from_default_keeps_custom_value() {
    var row=makePaired("backgroundColor","backgroundColorEnabled")
    row.host.settings=Object.assign({},row.host.settings,{backgroundColorEnabled:false})
    compare(row.selection,"default")
    row.adjust(1)
    compare(row.host.settings.backgroundColorEnabled,true)
    compare(row.host.settings.backgroundColor,"#112233")
  }
  function test_paired_empty_hex_commits_with_flag_on() {
    var row=makePaired("backgroundColor","backgroundColorEnabled")
    row.customOpen=true
    row.beginEdit()
    var field=findChild(row,"paired-hex")
    verify(!!field)
    field.text=""
    verify(row.saveHex())
    compare(row.host.settings.backgroundColor,"")
    compare(row.host.settings.backgroundColorEnabled,true)
  }
  function test_behavior_groups_render_pointer_first() {
    var host=createTemporaryObject(pairHostFactory,testCase)
    var sectionMeta={settings:{
      clickAction:{type:"string",ui:{section:"behavior",group:"pointer",order:380,label:"Left click",control:"dropdown",visibility:"normal"}},
      showPreviews:{type:"boolean",ui:{section:"behavior",group:"windows",order:410,label:"Previews",control:"toggle",visibility:"normal"}},
      attentionBadgesEnabled:{type:"boolean",ui:{section:"behavior",group:"attention",order:430,label:"Badges",control:"toggle",visibility:"normal"}},
      dockHerdrIndicators:{type:"boolean",ui:{section:"behavior",group:"attention-on-the-dock",order:460,label:"Agent state",control:"toggle",visibility:"normal"}}}}
    var section=createTemporaryObject(generalFactory,testCase,{host:host,metadata:sectionMeta,section:"behavior"})
    compare(section.groups.map(function(group){return group.id}),
      ["pointer","windows","attention","attention-on-the-dock"])
  }
  function test_grouped_apps_keyboard_ungroup() {
    var host=createTemporaryObject(pairHostFactory,testCase)
    var sectionMeta={settings:{
      workspaceGroups:{type:"array",ui:{section:"behavior",group:"windows",order:420,label:"Grouped apps",control:"app-list",visibility:"normal"}}}}
    var section=createTemporaryObject(generalFactory,testCase,{host:host,metadata:sectionMeta,section:"behavior"})
    var lists=section.targets.filter(function(target){return target.adjust && target.ungroupAt})
    compare(lists.length,1)
    lists[0].activate()
    compare(host.ungroupCalls.length,1)
    compare(host.ungroupCalls[0].desktopId,"org.example.App")
  }
  Component { id: generalFactory; DockSettingsGeneralSection {width:470} }
}
