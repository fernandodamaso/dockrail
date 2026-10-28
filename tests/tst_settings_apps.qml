import QtQuick
import QtTest
import "../components"

TestCase {
  id: testCase
  name: "SettingsApps"
  when: windowShown
  visible: true
  width: 900
  height: 1000

  property var host: null
  property var section: null

  function schema() {
    var request = new XMLHttpRequest()
    request.open("GET", Qt.resolvedUrl("../config/settings-schema.json"), false)
    request.send()
    compare(request.status, 200)
    return JSON.parse(request.responseText)
  }

  Component {
    id: hostFactory
    Item {
      property var applications: [
        {id:"app.short",name:"Short",icon:"short"},
        {id:"app.long",name:"A very long application name that wraps across multiple lines so its pinned row is substantially taller than the neighboring pinned rows. More readable text is helpful.",icon:"long"},
        {id:"app.third",name:"Third",icon:"third"}
      ]
      property var settings: ({
        pinned:["app.short","app.long","app.third"],
        hiddenApplications:["hidden.first","hidden.second"],
        iconOverrides:{"app.short":"file:///icons/one.svg"},
        windowIconOverrides:[{appId:"app.short",titlePattern:"*console*",source:"file:///icons/two.svg"}],
        browserProfileBadgesEnabled:true,
        sidebarBrowserTabsEnabled:false,
        browserActivityMutedServices:["gmail"],
        showTrash:true,
        controlCommand:"original-command",
        sidebarWidgets:[],workspaceLayout:"flat",presentationMode:"classic",
        presentationModeByMonitor:{},sidebarCollapsedByMonitor:{},workspaceMonitorOrder:[]
      })
      property QtObject featureReadinessBridge: QtObject {
        property var lastGoodFeatures: ({chromeProfilesTabs:{installation:"installed",runtime:"ready"}})
        property bool panelVisible:false
        function focused() {}
      }
      property QtObject settingsActions: QtObject {
        property bool inFlight:false
        property string status:"idle"
        property var installConfirmation:null
        function cancelInstall() {installConfirmation=null}
      }
      property var sidebarWidgetRegistry: ({})
      property var connectedScreens: []
      property bool settingsDeveloperBuild: false
      property string runtimeMode: "plugin"
      property string configPath: "/test/dock.json"
      property string settingsLoadState: "loaded"
      property bool settingsLoaded: true
      property bool settingsReloadPending: false
      property string settingsWriteState: "saved"
      property bool settingsPersisted: true
      property string settingsWriteError: ""
      property var calls: []
      property string failCode: ""
      property int pickerClosures: 0

      function closeAppPickerFromSettings() {pickerClosures++}
      function currentPresentation() {return {entries:[],classicScreens:["DP-1"]}}
      function shownSetting(key) {return settings[key]}
      function defaultSetting(key) {return key==="controlCommand"?"default-command":undefined}
      function saveSettingIntent(key,value,expected) {
        if(JSON.stringify(settings[key])!==JSON.stringify(expected))
          return {accepted:false,reply:{ok:false,error:{code:"E_STALE",message:"Changed elsewhere"}}}
        if(failCode!=="")
          return {accepted:false,reply:{ok:false,error:{code:failCode,message:"Not saved"}}}
        calls=calls.concat([{kind:"setting",key:key,value:value,expected:expected}])
        var next=Object.assign({},settings);next[key]=value;settings=next
        return {accepted:true,reply:{ok:true,data:{applied:true}}}
      }
      function resetSettingIntent(key,expected) {
        return saveSettingIntent(key,defaultSetting(key),expected)
      }
      function changeApplication(action,args) {
        calls=calls.concat([{kind:"application",action:action,args:args}])
        var next=Object.assign({},settings)
        if(action==="move") {
          var order=settings.pinned.slice()
          var from=order.indexOf(args.id)
          if(from<0)return {ok:false,error:{code:"E_VALIDATION",message:"Missing ID"}}
          order.splice(from,1)
          var after=args.after!==undefined
          var anchor=after?args.after:args.before
          var index=order.indexOf(anchor)
          if(index<0)return {ok:false,error:{code:"E_VALIDATION",message:"Missing anchor"}}
          order.splice(index+(after?1:0),0,args.id)
          next.pinned=order
        } else if(action==="show") {
          next.hiddenApplications=args.all?[]:settings.hiddenApplications.filter(function(id){return id!==args.id})
        } else if(action==="unpin") {
          next.pinned=settings.pinned.filter(function(id){return id!==args.id})
        }
        settings=next
        return {ok:true,data:{applied:true}}
      }
      function unpinApplication(id) {return changeApplication("unpin",{id:id})}
      function windowIconTargetKey(appId,pattern) {return appId+"|"+pattern}
      function saveIconChange(args) {
        calls=calls.concat([{kind:"icon",args:args}])
        return {ok:true,data:{applied:true}}
      }
      function releaseSettingsPanel(panel) {}
      function retrySettings() {return {ok:true,data:{applied:false}}}
    }
  }
  Component {
    id: sectionFactory
    DockSettingsAppsSection { width: 470; panelActive: true }
  }
  Component {
    id: panelFactory
    DockSettingsPanel {}
  }

  function init() {
    failOnWarning(/.*Binding loop.*/)
    host=createTemporaryObject(hostFactory,testCase)
    section=createTemporaryObject(sectionFactory,host,{host:host,metadata:schema()})
    verify(section!==null)
    tryVerify(function(){return section.targets.filter(function(x){return !!x.pinnedId}).length===3})
  }
  function cleanup() {
    if(section)section.destroy()
    wait(0)
    if(host)host.destroy()
    section=null;host=null
    wait(0)
  }
  function pinnedRows() {
    return section.targets.filter(function(x){return !!x.pinnedId})
  }

  function test_stale_advanced_reset_never_replaces_a_new_cli_value() {
    var field=findChild(section,"apps-command-field")
    verify(field!==null)
    section.beginCommand()
    section.commandDraft="unfinished-command"
    host.settings=Object.assign({},host.settings,{controlCommand:"external-command"})
    verify(section.commandConflict)
    var reset=findChild(section,"apps-command-reset")
    verify(!reset.enabled)
    verify(!section.resetCommand())
    compare(host.settings.controlCommand,"external-command")
    compare(host.calls.length,0)
    section.reloadCommand()
    compare(section.commandDraft,"external-command")
    compare(field.text,"external-command")
  }

  function test_reset_is_scoped_to_edit_start_and_restores_text() {
    section.beginCommand()
    section.commandDraft="unfinished-command"
    verify(section.resetCommand())
    compare(host.settings.controlCommand,"default-command")
    compare(section.commandDraft,"default-command")
    compare(findChild(section,"apps-command-field").text,"default-command")
    compare(host.calls.length,1)
    compare(host.calls[0].expected,"original-command")
  }

  function test_validation_retains_advanced_draft() {
    section.beginCommand()
    section.commandDraft="my-command"
    host.failCode="E_VALIDATION"
    verify(!section.saveCommand())
    compare(section.commandDraft,"my-command")
    compare(host.settings.controlCommand,"original-command")
    verify(section.commandFeedback.indexOf("E_VALIDATION")>=0)
  }

  function test_drag_target_uses_actual_wrapped_row_geometry() {
    var pins=pinnedRows()
    verify(pins[1].height>pins[0].height)
    var grip=findChild(pins[0],"apps-pin-grip")
    verify(grip!==null)
    var from=grip.mapToItem(section,0,grip.height/2).y
    var to=pins[1].mapToItem(section,0,pins[1].height/2).y-2
    var oldY=grip.y
    grip.y+=(to-from)
    compare(section.draggedPinTarget(grip),"app.long")
    grip.y=oldY
    var expected=host.settings.pinned.slice()
    verify(section.dropPinned("app.short","app.long",expected))
    compare(host.settings.pinned,["app.long","app.short","app.third"])
  }

  function test_keyboard_reorder_keeps_selected_application() {
    var row=pinnedRows()[0]
    section.focusTarget(section.targets.indexOf(row))
    section.reorderSelected(1)
    compare(host.settings.pinned,["app.long","app.short","app.third"])
    wait(0)
    compare(section.selectedTarget.pinnedId,"app.short")
  }

  function test_drag_stale_snapshot_refuses_mutation() {
    var expected=host.settings.pinned.slice()
    host.settings=Object.assign({},host.settings,{pinned:["app.third","app.short","app.long"]})
    verify(!section.dropPinned("app.short","app.long",expected))
    compare(host.calls.length,0)
    verify(section.feedback.indexOf("changed while dragging")>=0)
  }

  function test_pinned_enter_focuses_existing_unpin_button() {
    var row=pinnedRows()[0]
    section.focusTarget(section.targets.indexOf(row))
    row.activate()
    var button=findChild(row,"apps-unpin-button")
    verify(button!==null)
    tryVerify(function(){return button.activeFocus})
    compare(host.calls.length,0)
  }

  function test_hidden_show_all_checks_captured_list() {
    section.askShowAll()
    verify(section.awaitingShowAll)
    host.settings=Object.assign({},host.settings,{hiddenApplications:["hidden.second"]})
    verify(!section.confirmShowAll())
    compare(host.settings.hiddenApplications,["hidden.second"])
    compare(host.calls.length,0)
  }

  function test_hidden_show_all_preserves_pins() {
    var pins=host.settings.pinned.slice()
    section.askShowAll()
    verify(section.confirmShowAll())
    compare(host.settings.hiddenApplications,[])
    compare(host.settings.pinned,pins)
    compare(host.calls[0].action,"show")
    verify(host.calls[0].args.all)
  }

  function test_icon_change_handoff_is_exact_and_removal_uses_host() {
    var item=section.targets.filter(function(x){return x.modelData && x.modelData.kind==="window"})[0]
    verify(item!==undefined)
    var requested=null
    section.requestIconChange.connect(function(value){requested=value})
    item.activate()
    verify(requested!==null)
    compare(requested.appId,"app.short")
    compare(requested.titlePattern,"*console*")
    verify(section.resetIcon(requested))
    compare(host.calls.length,1)
    compare(host.calls[0].kind,"icon")
    compare(host.calls[0].args.remove.kind,"window")
    compare(host.calls[0].args.remove.titlePattern,"*console*")
  }

  function test_muted_selection_does_not_overwrite_cli_change() {
    var select=findChild(section,"apps-muted-select")
    verify(select!==null)
    select.open()
    tryVerify(function(){return select.popupOpen})
    host.settings=Object.assign({},host.settings,{browserActivityMutedServices:["whatsapp"]})
    select.changed(["instagram"])
    compare(host.settings.browserActivityMutedServices,["whatsapp"])
    compare(select.values,["whatsapp"])
    compare(host.calls.length,0)
    verify(section.feedback.indexOf("changed elsewhere")>=0)
  }

  function test_muted_selection_saves_through_single_host_intent() {
    var select=findChild(section,"apps-muted-select")
    select.open()
    select.changed(["gmail","whatsapp"])
    compare(host.settings.browserActivityMutedServices,["gmail","whatsapp"])
    compare(host.calls[0].kind,"setting")
    compare(host.calls[0].key,"browserActivityMutedServices")
    compare(host.calls[0].expected,["gmail"])
  }

  function test_panel_closure_clears_confirmation_and_picker_owner() {
    var panel=createTemporaryObject(panelFactory,host,{host:host,metadata:schema()})
    verify(panel!==null)
    verify(panel.openFor(testCase,"bottom","apps"))
    tryVerify(function(){return panel.activeSectionView!==null})
    var apps=panel.activeSectionView
    apps.askShowAll()
    verify(apps.awaitingShowAll)
    panel.close()
    verify(!apps.awaitingShowAll)
    compare(host.pickerClosures,1)
    panel.openFor(testCase,"bottom","apps")
    verify(!apps.awaitingShowAll)
    panel.selectSection("layout")
    compare(host.pickerClosures,2)
    panel.destroy()
  }
}
