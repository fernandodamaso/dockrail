import QtQuick
import QtTest
import "../components"
import "SettingsActionsSourceHarness.js" as ActionsSource

TestCase {
  id:testCase
  name:"SettingsWidgets"
  when:windowShown
  visible:true
  width:800; height:900
  property var host
  property var section
  property var broker
  Component {
    id:hostFactory
    Item {
      property var settings: ({sidebarWidgets:["test.alpha","test.beta","test.gamma"]})
      property string settingsLoadState:"loaded"
      property string settingsWriteState:"saved"
      property bool settingsLoaded:true
      property bool settingsReloadPending:false
      property bool settingsDeveloperBuild:false
      property var sidebarWidgetRegistry: ({
        "test.alpha":{id:"test.alpha",label:"Alpha",available:true,acquire:function(){}},
        "test.beta":{id:"test.beta",label:"Beta",available:true,acquire:function(){}},
        "test.gamma":{id:"test.gamma",label:"Gamma",available:true,acquire:function(){}},
        "herdr.agents":{id:"herdr.agents",label:"Coding agents",available:true,acquire:function(){}}})
      property var featureReadinessBridge: ({lastGoodFeatures:{herdrAgents:{runtime:"limited"}}})
      property var settingsPanel: ({sectionImplemented:function(){return false}})
      property var settingsActions:null
      property var calls:[]
      property var sidebarController: controller
      QtObject {
        id:controller
        function setWidgetEnabled(id,enabled) {
          host.calls=host.calls.concat([{id:id,enabled:enabled}])
          var order=host.settings.sidebarWidgets.slice(),at=order.indexOf(id)
          if(enabled && at<0) order.push(id)
          if(!enabled && at>=0) order.splice(at,1)
          host.settings=Object.assign({},host.settings,{sidebarWidgets:order})
          return {accepted:true,reply:{ok:true,data:{applied:true}}}
        }
        function reorderWidget(id,slot) {
          host.calls=host.calls.concat([{id:id,slot:slot}])
          var order=host.settings.sidebarWidgets.slice(),at=order.indexOf(id)
          order.splice(at,1)
          if(slot>at)slot--
          order.splice(slot,0,id)
          host.settings=Object.assign({},host.settings,{sidebarWidgets:order})
          return {accepted:true,reply:{ok:true,data:{applied:true}}}
        }
      }
    }
  }
  Component {id:sectionFactory; DockSettingsWidgetsSection {width:470; panelActive:true}}
  function init() {
    failOnWarning(/.*Binding loop.*/)
    host=createTemporaryObject(hostFactory,testCase)
    broker=ActionsSource.createBroker(host);host.settingsActions=broker
    section=createTemporaryObject(sectionFactory,host,{host:host,metadata:{settings:{}}})
    tryVerify(function(){return section.targets.filter(function(item){return !!item.widgetId}).length===4})
  }
  function cleanup() {section.destroy();wait(0);broker.destroy();host.destroy();section=null;broker=null;host=null;wait(0)}
  function complete(data) {
    broker.executor.running=false
    broker.finish(JSON.stringify({apiVersion:1,ok:true,data:data}),0)
  }
  function namedText(node,text) {
    if(node.text===text)return node
    for(var child of node.children||[]) {
      var match=namedText(child,text)
      if(match)return match
    }
    return null
  }
  function allText(node,text) {
    var matches=node.text===text?[node]:[]
    for(var child of node.children||[])matches=matches.concat(allText(child,text))
    return matches
  }
  function test_reorder_retains_widget_focus_and_repeats() {
    section.focusTarget(0)
    section.reorderSelected(1)
    compare(host.settings.sidebarWidgets,["test.beta","test.alpha","test.gamma"])
    compare(section.selectedTarget.widgetId,"test.alpha")
    section.reorderSelected(1)
    compare(host.settings.sidebarWidgets,["test.beta","test.gamma","test.alpha"])
    compare(section.selectedTarget.widgetId,"test.alpha")
    var count=host.calls.length
    section.reorderSelected(1)
    compare(host.calls.length,count)
  }
  function test_reorder_ignores_stationary_pointer_entering_rebuilt_row() {
    section.focusTarget(1)
    section.reorderSelected(-1)
    var other=section.targets.filter(function(item){return item.widgetId==="test.alpha"})[0]
    section.hovered(other)
    wait(0)
    compare(section.selectedTarget.widgetId,"test.beta")
  }
  function test_stale_reorder_does_not_overwrite_cli_order() {
    var before=host.settings.sidebarWidgets.slice()
    host.settings=Object.assign({},host.settings,{sidebarWidgets:["test.gamma","test.beta","test.alpha"]})
    verify(!section.move("test.alpha",1,before))
    compare(host.calls.length,0)
    compare(host.settings.sidebarWidgets,["test.gamma","test.beta","test.alpha"])
  }
  function test_busy_reorder_and_toggle_do_not_submit() {
    host.settingsWriteState="saving"
    verify(!section.move("test.alpha",1))
    verify(!section.toggle("test.beta",false))
    compare(host.calls.length,0)
  }
  function test_features_link_does_not_open_an_unimplemented_section() {
    var buttons=allText(section,"Herdr setup in Features…")
    verify(buttons.length>0)
    compare(buttons.filter(function(button){return button.visible}).length,0)
  }
  function test_create_requires_review_before_installing() {
    section.createOpen=true
    section.startCreate()
    verify(broker.inFlight)
    compare(broker.action,"create")
    complete({created:{id:"io.local.my-widget",name:"My widget",sourcePath:"/fixture/new-widget"},enabled:false})
    tryVerify(function(){return broker.inFlight})
    compare(broker.action,"prepare-install")
    complete({confirmation:{manifest:{id:"io.local.my-widget",name:"My widget"},source:"/fixture/new-widget",id:"io.local.my-widget",name:"My widget",replacesExisting:false,canInstall:true,requiresConfirmation:true}})
    compare(broker.status,"awaiting-confirmation")
    compare(broker.executor.calls.length,2)
    verify(section.installOpen)
    section.commitInstall()
    verify(broker.inFlight)
    compare(broker.action,"install")
    complete({package:{id:"io.local.my-widget"},enabledBySettings:false})
    compare(host.settings.sidebarWidgets,["test.alpha","test.beta","test.gamma"])
    verify(!section.installOpen)
    verify(namedText(section,"Open folder").visible)
  }
  function test_close_during_create_does_not_start_install() {
    section.startCreate()
    section.cancelPending()
    complete({created:{id:"io.local.my-widget",name:"My widget",sourcePath:"/fixture/new-widget"},enabled:false})
    wait(0)
    verify(!broker.inFlight)
    compare(broker.executor.calls.length,1)
    compare(section.createdPath,"/fixture/new-widget")
    verify(namedText(section,"Open folder").visible)
  }
  function test_failed_prepare_displays_current_error() {
    section.installOpen=true
    var field=findChild(section,"widget-source");field.text="/fixture/bad"
    section.startPrepare()
    broker.executor.running=false
    verify(!broker.finish(JSON.stringify({apiVersion:1,ok:false,error:{code:"E_VALIDATION",message:"Invalid widget manifest"}}),1))
    compare(section.actionFeedback,"E_VALIDATION: Invalid widget manifest")
  }
  function test_prepare_does_not_announce_success_before_confirmation() {
    var states=[]
    var observer=function(){states.push(broker.status)}
    broker.statusChanged.connect(observer)
    verify(broker.prepareInstall("/fixture/widget").accepted)
    complete({confirmation:{source:"/fixture/widget",id:"test.alpha",name:"Alpha",canInstall:true,replacesExisting:false}})
    broker.statusChanged.disconnect(observer)
    compare(states,["running","awaiting-confirmation"])
  }
  function test_cancelled_prepare_does_not_restore_confirmation() {
    section.installOpen=true
    verify(broker.prepareInstall("/fixture/widget").accepted)
    section.cancelPending()
    complete({confirmation:{source:"/fixture/widget",id:"test.delta",name:"Delta",canInstall:true,replacesExisting:false}})
    compare(broker.installConfirmation,null)
  }
  function test_install_of_already_enabled_id_is_rejected() {
    section.installOpen=true
    findChild(section,"widget-source").text="/fixture/widget"
    verify(broker.prepareInstall("/fixture/widget").accepted)
    complete({confirmation:{source:"/fixture/widget",id:"test.alpha",name:"Alpha",canInstall:true,replacesExisting:false}})
    section.commitInstall()
    verify(!broker.inFlight)
    verify(section.actionFeedback.indexOf("already")>=0)
  }
  function test_pointer_drag_moves_multiple_rows() {
    var mouse=findChild(section,"widget-drag-test.gamma")
    verify(mouse)
    var height=section.targets[0].height
    mousePress(mouse,12,17,Qt.LeftButton)
    mouseMove(mouse,12,7,25)
    mouseMove(mouse,12,17-height*2,50)
    mouseRelease(mouse,12,17-height*2,Qt.LeftButton)
    tryCompare(host,"calls",[{id:"test.gamma",slot:0}])
    compare(host.settings.sidebarWidgets,["test.gamma","test.alpha","test.beta"])
  }
  function test_escape_cancels_pointer_reorder() {
    var area=findChild(section,"widget-drag-test.alpha")
    verify(area!==null)
    mousePress(area,12,17,Qt.LeftButton)
    mouseMove(area,12,90,100)
    try {verify(section.dismissEditor())}
    finally {mouseRelease(area,12,90,Qt.LeftButton)}
    compare(host.calls.length,0)
    compare(host.settings.sidebarWidgets,["test.alpha","test.beta","test.gamma"])
  }
  function test_first_boundary_reorder_does_not_submit() {
    section.focusTarget(0)
    var count=host.calls.length
    section.reorderSelected(-1)
    compare(host.calls.length,count)
    compare(host.settings.sidebarWidgets,["test.alpha","test.beta","test.gamma"])
  }
  function test_cli_change_during_drag_cancels_without_reorder() {
    var mouse=findChild(section,"widget-drag-test.beta")
    verify(mouse)
    mousePress(mouse,12,17,Qt.LeftButton)
    mouseMove(mouse,12,30,25)
    verify(section.dragId==="test.beta")
    host.settings=Object.assign({},host.settings,{sidebarWidgets:["test.gamma","test.beta","test.alpha"]})
    tryVerify(function(){return section.dragId===""})
    verify(section.actionFeedback.indexOf("Review the list")>=0)
    var fresh=findChild(section,"widget-drag-test.beta")
    verify(fresh)
    mouseRelease(fresh,12,30,Qt.LeftButton)
    compare(host.calls.length,0)
    compare(host.settings.sidebarWidgets,["test.gamma","test.beta","test.alpha"])
  }
  function test_add_widget_and_install_have_keyboard_cursor_targets() {
    var add=namedText(section,"Add new widget")
    var install=namedText(section,"Install from folder or git…")
    verify(section.targets.indexOf(add)>=0)
    verify(section.targets.indexOf(install)>=0)
  }
  function collectTexts(node, predicate, out) {
    if(node.text !== undefined && predicate(node.text)) out.push(node)
    for(var child of node.children||[]) collectTexts(child, predicate, out)
    return out
  }
  function test_package_markup_displays_literally() {
    var markupName="<b>Example</b><img src=\"https://example.invalid/image\">"
    var markupDesc="<i>Description</i><img src=\"https://example.invalid/desc\">"
    host.sidebarWidgetRegistry=({
      "test.alpha":{id:"test.alpha",label:markupName,description:markupDesc,available:true,acquire:function(){}},
      "test.beta":{id:"test.beta",label:"Beta",available:true,acquire:function(){}},
      "test.gamma":{id:"test.gamma",label:"Gamma",available:true,acquire:function(){}},
      "herdr.agents":{id:"herdr.agents",label:"Coding agents",available:true,acquire:function(){}}})
    host.settings=Object.assign({},host.settings,{sidebarWidgets:["test.alpha","test.beta","test.gamma"]})
    tryVerify(function(){return allText(section,markupName).length>0})
    var labels=allText(section,markupName)
    verify(labels.length>0)
    for(var label of labels) compare(label.textFormat,Text.PlainText)
    var descs=allText(section,markupDesc)
    verify(descs.length>0)
    for(var desc of descs) compare(desc.textFormat,Text.PlainText)
    section.installOpen=true
    findChild(section,"widget-source").text="/fixture/markup"
    verify(broker.prepareInstall("/fixture/markup").accepted)
    complete({confirmation:{manifest:{id:"test.markup",name:markupName},source:"/fixture/markup",id:"test.markup",name:markupName,canInstall:true,replacesExisting:false}})
    var reviews=collectTexts(section,function(text){return text.indexOf("Package:")>=0 && text.indexOf(markupName)>=0},[])
    verify(reviews.length>0)
    for(var review of reviews) {
      compare(review.textFormat,Text.PlainText)
      verify(review.text.indexOf(markupName)>=0)
    }
    section.cancelPending()
    wait(0)
    var createdMsg="Created test.markup from /fixture/markup-widget"
    section.createdStatus=createdMsg
    var createdTexts=collectTexts(section,function(text){return text.indexOf("test.markup")>=0 && text.indexOf("/fixture/markup-widget")>=0},[])
    verify(createdTexts.length>0)
    for(var created of createdTexts) compare(created.textFormat,Text.PlainText)
    section.cancelPending()
    wait(0)
    section.installOpen=true
    findChild(section,"widget-source").text="/fixture/bad-markup"
    section.startPrepare()
    broker.executor.running=false
    var markupError="<b>Evil</b><img src=\"https://example.invalid/err\">"
    verify(!broker.finish(JSON.stringify({apiVersion:1,ok:false,error:{code:"E_VALIDATION",message:markupError}}),1))
    var errors=collectTexts(section,function(text){return text.indexOf(markupError)>=0},[])
    verify(errors.length>0)
    for(var err of errors) compare(err.textFormat,Text.PlainText)
  }
}
