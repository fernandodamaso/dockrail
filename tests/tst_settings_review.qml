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
      property QtObject featureReadinessBridge: QtObject {
        property var lastGoodFeatures: ({})
        property bool panelVisible:false
        function focused() {}
      }
      property QtObject settingsActions: QtObject {
        property bool inFlight:false
        property var installConfirmation:null
        property string status:"idle"
        function cancelInstall() {installConfirmation=null}
      }
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
      function defaultSetting(key) {return {margin:10}[key]}
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
      property bool themeOwned: false
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
      function shownSetting(key) { return themeOwned && key==="borderWidth" ? null : settings[key] }
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
      row:{key:key,ui:{label:key,help:"",pairedWith:flagKey,unit:key==="borderWidth"?"px":""}}})
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
  function kids(item) {
    var out=[]
    var list=item.children || []
    for (var i=0;i<list.length;i++) out.push(list[i])
    return out
  }
  function pairedChooser(row) {
    return kids(row).filter(function(item) {return item.options && item.open && item.close})[0]
  }
  function test_panel_content_respects_native_insets() {
    var host=createTemporaryObject(hostFactory,testCase)
    var panel=createTemporaryObject(panelFactory,host,{host:host,metadata:metadata})
    compare(panel.keyCatcher.width,panel.keyCatcher.parent.width)
    compare(panel.keyCatcher.height,panel.keyCatcher.parent.height)
  }
  function test_paired_popup_snapshots_before_external_write() {
    var row=makePaired("backgroundColor","backgroundColorEnabled")
    var chooser=pairedChooser(row)
    chooser.open()
    tryVerify(function(){return chooser.popupOpen})
    compare(row.expected.backgroundColor,"#112233")
    row.host.settings=Object.assign({},row.host.settings,{backgroundColor:"#445566"})
    chooser.changed("@accent")
    chooser.close()
    compare(row.host.writes.length,0)
    verify(row.conflict)
    compare(row.host.settings.backgroundColor,"#445566")
  }
  function test_paired_cancel_drops_snapshot() {
    var row=makePaired("backgroundColor","backgroundColorEnabled")
    var chooser=pairedChooser(row)
    chooser.open()
    tryVerify(function(){return chooser.popupOpen})
    row.dismissEditor()
    tryVerify(function(){return !chooser.popupOpen})
    verify(!row.editing)
    row.host.settings=Object.assign({},row.host.settings,{backgroundColor:"#445566"})
    verify(!row.conflict)
  }
  function test_paired_custom_choice_focuses_hex() {
    var row=makePaired("backgroundColor","backgroundColorEnabled")
    row.choose("custom")
    tryVerify(function(){return row.textFocused})
  }
  function test_paired_cancel_discards_pending_width() {
    var row=makePaired("borderWidth","borderWidthEnabled")
    row.adjust(1)
    row.cancelPending()
    row.adjust(1)
    compare(row.draftWidth,5)
  }
  function test_paired_external_write_preserves_typed_draft() {
    var row=makePaired("backgroundColor","backgroundColorEnabled")
    row.choose("custom")
    var field=findChild(row,"paired-hex")
    field.forceActiveFocus()
    field.selectAll()
    for (var character of "#abcdef") keyClick(character)
    compare(field.text,"#abcdef")
    row.host.settings=Object.assign({},row.host.settings,{backgroundColor:"#445566"})
    compare(field.text,"#abcdef")
    verify(row.conflict)
  }
  function test_row_uses_semantic_text_color() {
    var row=makeRow("margin")
    var label=kids(row).filter(function(item){return item.text==="Margin" && item.font && item.font.bold})[0]
    compare(String(label.color),"#f0f2f8")
  }
  function test_paired_hex_blur_commits_once() {
    var row=makePaired("backgroundColor","backgroundColorEnabled")
    row.choose("custom")
    tryVerify(function(){return row.textFocused})
    var field=findChild(row,"paired-hex")
    field.selectAll()
    for (var character of "#abcdef") keyClick(character)
    testCase.forceActiveFocus()
    tryVerify(function(){return row.host.writes.length===1})
    compare(row.host.writes[0].patch.backgroundColor,"#abcdef")
    compare(row.host.writes[0].patch.backgroundColorEnabled,true)
    compare(row.host.writes[0].expected.backgroundColor,"#112233")
    compare(Object.keys(row.host.writes[0].patch).length,2)
  }
  function test_reset_does_not_report_its_own_write_as_external() {
    var row=makeRow("margin")
    row.host.settings=Object.assign({},row.host.settings,{margin:18})
    verify(row.changedElsewhere)
    verify(row.resetToDefault())
    verify(!row.changedElsewhere)
  }
  function test_cancelled_dropdown_does_not_leave_a_stale_draft() {
    var row=makeRow("windowScope")
    var dropdown=findChild(row,"setting-dropdown")
    dropdown.open()
    tryVerify(function(){return dropdown.popupOpen})
    row.dismissEditor()
    tryVerify(function(){return !dropdown.popupOpen})
    verify(!row.editing)
    row.host.settings=Object.assign({},row.host.settings,{windowScope:"workspace"})
    verify(!row.conflict)
  }
  function test_section_keeps_editor_keys_when_cursor_moves() {
    var host=createTemporaryObject(pairHostFactory,testCase)
    var meta={settings:{
      backgroundColor:{type:"string",ui:{section:"appearance",group:"dock-surface",order:1,label:"Background",control:"color",pairedWith:"backgroundColorEnabled",visibility:"normal"}},
      borderWidth:{type:"integer",ui:{section:"appearance",group:"dock-surface",order:2,label:"Border",control:"slider",pairedWith:"borderWidthEnabled",visibility:"normal"}}}}
    var section=createTemporaryObject(generalFactory,host,{host:host,metadata:meta})
    var row=section.targets[0]
    pairedChooser(row).open()
    tryVerify(function(){return row.popupOpen})
    section.focusTarget(1)
    verify(section.popupOpen)
    pairedChooser(row).close()
    row.choose("custom")
    tryVerify(function(){return row.textFocused})
    section.focusTarget(1)
    verify(section.editorFocused)
    section.destroy()
    wait(0)
  }
  function test_border_width_displays_its_value() {
    var row=makePaired("borderWidth","borderWidthEnabled")
    verify(kids(row).some(function(item){return item.visible && item.text==="4px"}))
  }
  function test_theme_width_does_not_claim_zero_pixels() {
    var row=makePaired("borderWidth","borderWidthEnabled")
    row.host.themeOwned=true
    row.host.settings=Object.assign({},row.host.settings,{borderWidthEnabled:false})
    verify(kids(row).some(function(item){return item.visible && item.text && item.text.indexOf("Theme width")>=0}))
    verify(!kids(row).some(function(item){return item.visible && item.text && item.text.indexOf("shows 0px")>=0}))
  }
  function test_disabled_row_keeps_help_readable() {
    var row=makeRow("reserveSpace")
    row.host.settings=Object.assign({},row.host.settings,{autoHide:true})
    verify(!row.editable)
    compare(row.opacity,1)
  }
  function test_grouped_apps_busy_keyboard_does_not_submit() {
    var host=createTemporaryObject(pairHostFactory,testCase)
    var meta={settings:{workspaceGroups:{type:"array",ui:{section:"behavior",group:"windows",order:1,
      label:"Grouped apps",control:"app-list",visibility:"normal"}}}}
    var section=createTemporaryObject(generalFactory,host,{host:host,metadata:meta,section:"behavior"})
    host.settingsWriteState="saving"
    section.targets[0].activate()
    compare(host.ungroupCalls.length,0)
    section.destroy()
    wait(0)
  }
  function test_theme_default_cancels_pending_width_commit() {
    var row=makePaired("borderWidth","borderWidthEnabled")
    row.adjust(1)
    row.choose("default")
    wait(450)
    compare(row.host.writes.length,1)
    compare(row.host.settings.borderWidthEnabled,false)
    compare(row.host.settings.borderWidth,4)
  }
  function test_pointer_takes_over_pending_width_keyboard_draft() {
    var row=makePaired("borderWidth","borderWidthEnabled")
    var slider=kids(row).filter(function(item){return item.minimum!==undefined && item.released})[0]
    row.adjust(1)
    slider.dragging=true;slider.moved(6)
    wait(450)
    compare(row.host.writes.length,0)
    slider.dragging=false;slider.released(6)
    compare(row.host.writes.length,1)
    compare(row.host.settings.borderWidth,6)
  }
  function test_reset_cancels_pending_scalar_commit() {
    var row=makeRow("margin")
    row.adjust(1)
    verify(row.resetToDefault())
    wait(450)
    compare(row.host.settings.margin,10)
    compare(row.host.writes.length,1)
  }
  function test_behavior_groups_render_pointer_first() {
    var host=createTemporaryObject(pairHostFactory,testCase)
    var sectionMeta={settings:{
      clickAction:{type:"string",ui:{section:"behavior",group:"pointer",order:380,label:"Left click",control:"dropdown",visibility:"normal"}},
      showPreviews:{type:"boolean",ui:{section:"behavior",group:"windows",order:410,label:"Previews",control:"toggle",visibility:"normal"}},
      attentionBadgesEnabled:{type:"boolean",ui:{section:"behavior",group:"attention",order:430,label:"Badges",control:"toggle",visibility:"normal"}},
      dockHerdrIndicators:{type:"boolean",ui:{section:"behavior",group:"attention-on-the-dock",order:460,label:"Agent state",control:"toggle",visibility:"normal"}}}}
    var section=createTemporaryObject(generalFactory,host,{host:host,metadata:sectionMeta,section:"behavior"})
    compare(section.groups.map(function(group){return group.id}),
      ["pointer","windows","attention","attention-on-the-dock"])
    section.destroy()
    wait(0)
  }
  function test_grouped_apps_keyboard_ungroup() {
    var host=createTemporaryObject(pairHostFactory,testCase)
    var sectionMeta={settings:{
      workspaceGroups:{type:"array",ui:{section:"behavior",group:"windows",order:420,label:"Grouped apps",control:"app-list",visibility:"normal"}}}}
    var section=createTemporaryObject(generalFactory,host,{host:host,metadata:sectionMeta,section:"behavior"})
    var lists=section.targets.filter(function(target){return target.adjust && target.ungroupAt})
    compare(lists.length,1)
    lists[0].activate()
    compare(host.ungroupCalls.length,1)
    compare(host.ungroupCalls[0].desktopId,"org.example.App")
    section.destroy()
    wait(0)
  }
  function pairedRecoveryButtons(row) {
    return kids(row).filter(function(item) {
      return item.visible !== undefined && item.children
        && kids(item).some(function(child) { return child.text === "Reload" })
    })[0]
  }
  function test_paired_conflict_keyboard_recovery() {
    var row=makePaired("backgroundColor","backgroundColorEnabled")
    row.choose("custom")
    tryVerify(function(){return row.textFocused})
    var field=findChild(row,"paired-hex")
    field.forceActiveFocus()
    field.selectAll()
    for (var character of "#abcdef") keyClick(character)
    compare(field.text,"#abcdef")
    row.host.settings=Object.assign({},row.host.settings,{backgroundColor:"#445566"})
    verify(!row.saveHex())
    verify(row.conflict)
    compare(row.host.settings.backgroundColor,"#445566")
    row.activate()
    var recovery=pairedRecoveryButtons(row)
    verify(!!recovery)
    var reload=kids(recovery).filter(function(child){return child.text==="Reload"})[0]
    var keep=kids(recovery).filter(function(child){return child.text==="Keep editing"})[0]
    tryVerify(function(){return reload.activeFocus})
    keyClick(Qt.Key_Return)
    tryVerify(function(){return !row.conflict})
    compare(row.host.settings.backgroundColor,"#445566")
    verify(!row.editing)
    compare(field.text,"#445566")
    row.destroy()
    wait(0)
    var keepRow=makePaired("backgroundColor","backgroundColorEnabled")
    keepRow.choose("custom")
    tryVerify(function(){return keepRow.textFocused})
    var keepField=findChild(keepRow,"paired-hex")
    keepField.forceActiveFocus()
    keepField.selectAll()
    for (var keepCharacter of "#123456") keyClick(keepCharacter)
    compare(keepField.text,"#123456")
    keepRow.host.settings=Object.assign({},keepRow.host.settings,{backgroundColor:"#445566"})
    verify(!keepRow.saveHex())
    verify(keepRow.conflict)
    keepRow.activate()
    var keepRecovery=pairedRecoveryButtons(keepRow)
    var keepReload=kids(keepRecovery).filter(function(child){return child.text==="Reload"})[0]
    var keepButton=kids(keepRecovery).filter(function(child){return child.text==="Keep editing"})[0]
    tryVerify(function(){return keepReload.activeFocus})
    keyClick(Qt.Key_Tab)
    tryVerify(function(){return keepButton.activeFocus})
    keyClick(Qt.Key_Return)
    tryVerify(function(){return !keepRow.conflict})
    compare(keepRow.host.settings.backgroundColor,"#445566")
    compare(keepField.text,"#123456")
    verify(keepRow.editing)
  }
  function test_row_conflict_keyboard_recovery() {
    var row=makeRow("margin")
    row.beginEdit()
    row.draft=22
    row.host.settings=Object.assign({},row.host.settings,{margin:15})
    verify(!row.commitDraft())
    verify(row.conflict)
    row.activate()
    var recovery=kids(row).filter(function(item) {
      return item.children && kids(item).some(function(child){return child.text==="Reload"})
    })[0]
    verify(!!recovery)
    var reload=kids(recovery).filter(function(child){return child.text==="Reload"})[0]
    var keep=kids(recovery).filter(function(child){return child.text==="Keep editing"})[0]
    tryVerify(function(){return reload.activeFocus})
    keyClick(Qt.Key_Return)
    tryVerify(function(){return !row.conflict})
    compare(row.draft,15)
    compare(row.host.settings.margin,15)
    row.destroy()
    wait(0)
    var keepRow=makeRow("margin")
    keepRow.beginEdit()
    keepRow.draft=22
    keepRow.host.settings=Object.assign({},keepRow.host.settings,{margin:15})
    verify(!keepRow.commitDraft())
    verify(keepRow.conflict)
    keepRow.activate()
    var keepRecovery=kids(keepRow).filter(function(item) {
      return item.children && kids(item).some(function(child){return child.text==="Reload"})
    })[0]
    var keepReload=kids(keepRecovery).filter(function(child){return child.text==="Reload"})[0]
    var keepButton=kids(keepRecovery).filter(function(child){return child.text==="Keep editing"})[0]
    tryVerify(function(){return keepReload.activeFocus})
    keyClick(Qt.Key_Tab)
    tryVerify(function(){return keepButton.activeFocus})
    keyClick(Qt.Key_Return)
    tryVerify(function(){return !keepRow.conflict})
    compare(keepRow.draft,22)
    compare(keepRow.host.settings.margin,15)
  }
  Component { id: generalFactory; DockSettingsGeneralSection {width:470} }
}
