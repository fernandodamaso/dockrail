import QtQuick
import QtQuick.Controls as Controls
import QtTest
import qs.Commons
import "../components"
import "../components/widgets"
import "fixtures"
import "SidebarSplitSourceHarness.js" as SplitHarness
import "../components/DockSidebarWidgetModel.js" as WidgetModel

TestCase {
  id: testCase
  name: "SidebarSplitScroll"
  when: windowShown
  visible: true
  width: 760; height: 780
  property var areas: []
  property bool innerEnabled: false
  property var activeHerdrService: null
  property var activeHerdrWindows: []
  property var activeHerdrHandles: []
  QtObject {
    id: writer
    property int writes: 0
    property var lastValue: []
    function saveSetting(key,value) { writes++; lastValue=value; return {ok:true,data:{applied:true}} }
  }
  Component { id: controllerFactory; DockSidebarController { host:writer } }
  Component {
    id: herdrServiceFactory
    QtObject {
      id: service
      property string sourceEpoch: "epoch-1"
      property int sourceRevision: 0
      property bool running: false
      property int activeCount: 0
      property int acquireCount: 0
      property int releaseCount: 0
      property int starts: 0
      property int stops: 0
      property int suspensions: 0
      property var publish: null
      property var windowWrites: []
      function acquire(owner) {
        service.acquireCount++
        var lease={active:false,released:false,
          setActive:function(active,callback) {
            active=active===true
            if(active===lease.active) { if(active)service.publish=callback;return }
            lease.active=active
            service.publish=active?callback:null
            if(active) {
              service.activeCount++;service.starts++;service.running=true
              callback({status:"loading",revision:1,data:null})
            } else {
              service.activeCount=Math.max(0,service.activeCount-1)
              service.suspensions++
              if(service.activeCount===0) {service.running=false;service.stops++}
            }
          },
          release:function() {
            if(lease.released)return
            if(lease.active) {
              lease.active=false;service.activeCount=Math.max(0,service.activeCount-1)
              if(service.activeCount===0) {service.running=false;service.stops++}
            }
            service.publish=null;lease.released=true;service.releaseCount++
          }}
        return lease
      }
      function setWindowProcesses(revision,pids) {
        service.windowWrites=service.windowWrites.concat([{revision:revision,pids:pids.slice()}])
        return true
      }
      function publishSnapshot(value) {
        service.sourceEpoch=value.providerEpoch
        service.sourceRevision=value.revision
        if(service.publish)service.publish({status:"ready",revision:value.revision+1,data:value})
      }
    }
  }
  Component {
    id: herdrBridgeFactory
    DockHerdrWindowAgents {
      herdrService: testCase.activeHerdrService
      toplevels: testCase.activeHerdrWindows
      hyprToplevels: testCase.activeHerdrHandles
    }
  }
  Component { id: providerFactory; SidebarWidgetFixture {} }
  Component { id: windowFactory; QtObject { property string appId: "foot"; property string title: "Herdr terminal" } }
  Component {
    id: registryRefreshFactory
    Timer {
      property var registryHost
      property var manager
      property var backend
      property var acquireFunction
      property int refreshes: 0
      interval: 900
      repeat: true
      onTriggered: {
        registryHost.externalDescriptors=({})
        testCase.verify(registryHost.sidebarWidgetRegistry["herdr.agents"].acquire===acquireFunction)
        testCase.compare(manager.diagnostics().counters.acquisitions,1)
        testCase.compare(manager.diagnostics().counters.releases,0)
        testCase.compare(backend.starts,1)
        testCase.compare(backend.stops,0)
        testCase.compare(backend.activeCount,1)
        testCase.compare(backend.suspensions,0)
        testCase.compare(backend.acquireCount,1)
        testCase.compare(backend.releaseCount,0)
        refreshes++
        if(refreshes>=5)stop()
      }
    }
  }
  Component {
    id: bodyFactory
    Item {
      property var widgetContext: ({})
      implicitHeight: width < 230 ? 410 : 290
      WidgetTextInput { objectName:"split-input-first"; y:10; width:parent.width; text:"first" }
      Controls.ScrollView {
        objectName:"nested-scroll"
        visible:testCase.innerEnabled
        y:65; width:parent.width; height:90
        contentHeight:500
        clip:true
        Rectangle { width:parent.width; height:500; color:"#607080" }
      }
      WidgetTextInput { objectName:"split-input-last"; y:parent.implicitHeight-40; width:parent.width; text:"last" }
    }
  }
  Component {
    id: panelFactory
    Item {
      id: panel
      width:280; height:600
      property var controller
      property var screen:({name:"TEST",width:1920,height:1080})
      property bool panelCollapsed:false
      property var contentItem:panel
      property var widgetArea:null
      property var widgetManager:null
      property alias widgetManageControl:mainManage
      property alias viewport:hierarchy
      property alias footerControl:footer
      property real availableHeight:440
      property var split:WidgetModel.sidebarSplitLayout({availableHeight:availableHeight,
        hierarchyContentHeight:hierarchy.contentHeight,widgetHeaderHeight:widgetArea?widgetArea.naturalWidgetHeaderHeight:32,
        widgetContentHeight:widgetArea?widgetArea.naturalWidgetContentHeight:0,
        presentedWidgetCount:widgetArea?widgetArea.presentedWidgetCount:0,
        rail:panelCollapsed,minHierarchyHeight:102,minWidgetHeight:72,requestedSplitPx:null})
      function openWidgetManager(anchor) { return widgetManager?widgetManager.openFor(anchor):false }
      Controls.Button { id:mainManage; objectName:"main-manage"; width:80; height:30; text:"Manage" }
      Flickable {
        id:hierarchy
        y:40; width:parent.width; height:panel.split.hierarchyHeight
        contentHeight:800; contentWidth:width; clip:true
        boundsBehavior:Flickable.StopAtBounds
        property real workspaceCardInset:5
        property real scrollGutter:6
        property real scrollBarOutset:4
        property var listView:hierarchy
        function focusLastRow() { forceActiveFocus(Qt.BacktabFocusReason); return true }
        Rectangle { width:parent.width; height:800; color:"#303440" }
      }
      Controls.Button { id:footer; y:480; text:"Applications"; width:parent.width; height:30 }
    }
  }
  function init() { writer.writes=0;writer.lastValue=[];areas=[];innerEnabled=false }
  function cleanup() { for(var i=0;i<areas.length;i++)areas[i].destroy();areas=[];wait(0) }
  function build(x,customIds,sharedController,sharedProvider) {
    var p=sharedProvider||createTemporaryObject(providerFactory,testCase)
    var ids=customIds||["fixture.one","fixture.two","fixture.three"]
    var registry={}
    ids.forEach(function(id){registry[id]=Object.assign({},p.descriptor,{id:id,expandedView:bodyFactory})})
    var c=sharedController||createTemporaryObject(controllerFactory,testCase,{widgetRegistry:registry,
      settings:{presentationMode:"sidebar",sidebarWidgets:ids,pinned:[],interfaceAnimationsEnabled:false},
      screens:[{name:"TEST",width:1920,height:1080}],monitors:[],workspaces:[],toplevels:[],hyprToplevels:[]})
    c.refresh()
    var panel=createTemporaryObject(panelFactory,testCase,{x:x||0,controller:c})
    var area=SplitHarness.makeArea(panel,{width:panel.width})
    areas.push(area);panel.widgetArea=area
    area.y=Qt.binding(function(){return panel.viewport.y+panel.split.hierarchyHeight})
    area.height=Qt.binding(function(){return panel.split.widgetHeight})
    area.width=Qt.binding(function(){return panel.width})
    wait(50)
    return {panel:panel,area:area,controller:c,provider:p}
  }
  function settle(f) {
    tryCompare(f.area.scrollView,"moving",false)
    tryCompare(f.area,"inputBusy",false)
    if(f.area.sectionVisible&&f.area.scrollView.height>0)tryCompare(f.area,"pendingRestore",false)
    wait(30)
  }
  function setIds(f,ids) { f.controller.settings=Object.assign({},f.controller.settings,{sidebarWidgets:ids});f.controller.refresh();wait(50) }
  function named(node,name) {
    if(node.objectName===name)return node
    for(var i=0;node.children&&i<node.children.length;i++){var found=named(node.children[i],name);if(found)return found}
    return null
  }
  function test_independent_scroll_and_demand() {
    var f=build()
    compare(f.area.presentedWidgetCount,3)
    verify(f.area.scrollView!==f.panel.viewport)
    verify(f.area.naturalWidgetContentHeight>f.area.height)
    var h=f.area.height,n=f.area.naturalWidgetContentHeight,y=f.panel.viewport.contentY
    mouseWheel(f.area.scrollView,120,120,0,-120)
    tryVerify(function(){return f.area.scrollView.contentY>0})
    compare(f.panel.viewport.contentY,y);compare(f.area.height,h);compare(f.area.naturalWidgetContentHeight,n)
    tryCompare(f.area.scrollView,"moving",false)
    var wy=f.area.scrollView.contentY
    mouseWheel(f.panel.viewport,120,80,0,-120)
    tryVerify(function(){return f.panel.viewport.contentY>0})
    tryCompare(f.panel.viewport,"moving",false)
    compare(f.area.scrollView.contentY,wy)
    var hy=f.panel.viewport.contentY
    mouseWheel(f.area,120,10,0,-120)
    compare(f.panel.viewport.contentY,hy);compare(f.area.scrollView.contentY,wy)
    compare(f.provider.acquisitions,3);compare(f.provider.subscriptions,1)
  }
  function test_wheel_isolation_at_both_bounds() {
    var f=build();settle(f)
    for(var bottom of [false,true]) {
      f.area.scrollView.contentY=bottom?f.area.maximumScroll:0
      f.panel.viewport.contentY=200
      var wy=f.area.scrollView.contentY,hy=f.panel.viewport.contentY
      mouseWheel(f.area.scrollView,120,120,0,bottom?-120:120);settle(f)
      fuzzyCompare(f.area.scrollView.contentY,wy,0.01);compare(f.panel.viewport.contentY,hy)
      f.panel.viewport.contentY=bottom?f.panel.viewport.contentHeight-f.panel.viewport.height:0
      hy=f.panel.viewport.contentY
      mouseWheel(f.panel.viewport,100,60,0,bottom?-120:120);tryCompare(f.panel.viewport,"moving",false)
      fuzzyCompare(f.panel.viewport.contentY,hy,0.01);compare(f.area.scrollView.contentY,wy)
    }
  }
  function test_id_anchor_width_reflow_and_collapse_above() {
    var f=build();settle(f)
    f.area.scrollView.contentY=f.area.cards.itemAt(1).y+24;settle(f)
    compare(f.area.savedAnchor.id,"fixture.two");fuzzyCompare(f.area.savedAnchor.offset,24,0.1)
    f.panel.width=220;settle(f)
    fuzzyCompare(f.area.scrollView.contentY,f.area.cards.itemAt(1).y+24,0.1)
    compare(f.provider.acquisitions,3);compare(f.provider.releases,0)
    f.controller.settings=Object.assign({},f.controller.settings,{sidebarWidgetCollapsed:{"fixture.one":true}})
    f.controller.refresh();settle(f)
    fuzzyCompare(f.area.scrollView.contentY,f.area.cards.itemAt(1).y+24,0.1)
  }
  function test_removed_anchor_prefers_next_surviving_old_neighbor() {
    var f=build();settle(f)
    f.area.scrollView.contentY=f.area.cards.itemAt(1).y+24;settle(f)
    setIds(f,["fixture.one","fixture.three"]);settle(f)
    compare(f.area.savedAnchor.id,"fixture.three")
    fuzzyCompare(f.area.scrollView.contentY,f.area.cards.itemAt(1).y,0.1)
    compare(writer.writes,0)
  }
  function test_zero_space_and_rail_preserve_expanded_anchor_and_leases() {
    var f=build();settle(f)
    f.area.scrollView.contentY=f.area.cards.itemAt(1).y+24;settle(f)
    var demand=f.area.naturalWidgetContentHeight
    for(var mode of ["short","rail"]) {
      if(mode==="rail")f.panel.panelCollapsed=true;else f.panel.availableHeight=15
      wait(50);compare(f.area.height,0);verify(!f.area.visible)
      compare(f.area.naturalWidgetContentHeight,demand);compare(f.area.savedAnchor.id,"fixture.two")
      compare(f.provider.acquisitions,3);compare(f.provider.releases,0)
      if(mode==="rail")f.panel.panelCollapsed=false;else f.panel.availableHeight=440
      settle(f);fuzzyCompare(f.area.scrollView.contentY,f.area.cards.itemAt(1).y+24,0.1)
    }
  }
  function test_header_only_and_zero_one_zero_presented_cards() {
    var f=build();settle(f)
    f.panel.availableHeight=f.area.naturalWidgetHeaderHeight;settle(f)
    verify(f.area.visible);compare(f.area.scrollView.height,0);compare(f.panel.split.hierarchyHeight,0)
    f.panel.availableHeight=440;settle(f)
    setIds(f,[]);compare(f.area.presentedWidgetCount,0);compare(f.area.height,0)
    setIds(f,["fixture.one"]);settle(f);compare(f.area.presentedWidgetCount,1);verify(f.area.height>0)
    setIds(f,[]);compare(f.area.height,0)
  }
  function test_hidden_herdr_reserves_no_widget_space_but_keeps_lease() {
    var f=build(0,["herdr.agents"]);wait(50)
    compare(f.area.presentedWidgetCount,0);compare(f.area.height,0)
    compare(f.controller.widgetIds.length,1);compare(f.provider.acquisitions,1);compare(f.provider.releases,0)
  }
  function test_herdr_registry_refresh_keeps_matched_lease() {
    var provider=createTemporaryObject(herdrServiceFactory,testCase)
    var terminal=createTemporaryObject(windowFactory,testCase)
    var handle={wayland:terminal,address:"0x40",
      lastIpcObject:{workspace:{id:1},monitor:0,pid:40}}
    activeHerdrService=provider
    activeHerdrWindows=[terminal]
    activeHerdrHandles=[handle]
    var bridge=createTemporaryObject(herdrBridgeFactory,testCase)
    var host=SplitHarness.makeHostRegistry(testCase,bridge,provider)
    var acquire=host.sidebarWidgetRegistry["herdr.agents"].acquire
    var c=createTemporaryObject(controllerFactory,testCase,{
      host:host,
      settings:{presentationMode:"sidebar",sidebarWidgets:["herdr.agents"],pinned:[],interfaceAnimationsEnabled:false},
      screens:[{name:"TEST",width:1920,height:1080}],
      monitors:[{id:0,name:"TEST",activeWorkspace:{id:1}}],workspaces:[{id:1,monitorID:0}],
      toplevels:[terminal],hyprToplevels:[handle]
    })
    c.widgetRegistry=Qt.binding(function(){return host.sidebarWidgetRegistry})
    c.refresh()
    var panel=createTemporaryObject(panelFactory,testCase,{controller:c})
    var area=SplitHarness.makeArea(panel,{width:panel.width})
    areas.push(area)
    panel.widgetArea=area
    area.height=Qt.binding(function(){return panel.split.widgetHeight})
    wait(40)
    function snapshot(revision,matched) {
      var ancestorPid=matched?40:99
      return {schemaVersion:1,providerEpoch:"epoch-1",revision:revision,
        servers:[{id:"srv",health:"live",capabilities:{focusAgent:true},clients:[{
          pid:41,startTime:41,ancestors:[{pid:ancestorPid,startTime:ancestorPid}]}]}],
        agents:[{id:"agent-1",serverId:"srv",workspaceId:"w1",workspaceLabel:"Main",
          tabId:"t1",tabTitle:"Agent",status:"working",connectionGeneration:1,
          paneId:"pane-a",terminalId:"term-a"}],
        windowProcesses:{revision:bridge.windowProcessRevision,
          identities:[{pid:40,startTime:40}]}}
    }
    var value=snapshot(1,true)
    provider.publishSnapshot(value)
    tryCompare(bridge,"snapshotReady",true)
    c.refresh();wait(30)
    compare(c.widgetManager.diagnostics().counters.acquisitions,1)
    compare(c.widgetManager.diagnostics().counters.releases,0)
    compare(provider.starts,1)
    compare(provider.acquireCount,1)
    compare(provider.releaseCount,0)
    compare(provider.activeCount,1)
    compare(provider.windowWrites.length,1)
    compare(provider.windowWrites[0].pids[0],40)
    compare(c.widgetView("herdr.agents").status,"ready")
    compare(c.widgetView("herdr.agents").active,true)
    compare(area.presentedWidgetCount,0)
    compare(area.height,0)
    verify(c.projection.rows.some(function(row){return row.kind==="herdr-agent"&&row.agentId==="agent-1"}),
      "the matched agent remains nested under its terminal window")
    for(var transition=0;transition<3;transition++) {
      value=snapshot(value.revision+1,false)
      provider.publishSnapshot(value);c.refresh();wait(25)
      compare(area.presentedWidgetCount,1,"an unmatched server exposes the fallback card")
      verify(!c.projection.rows.some(function(row){return row.kind==="herdr-agent"}))
      value=snapshot(value.revision+1,true)
      provider.publishSnapshot(value);c.refresh();wait(25)
      compare(area.presentedWidgetCount,0,"matching hides the fallback card again")
      verify(c.projection.rows.some(function(row){return row.kind==="herdr-agent"&&row.agentId==="agent-1"}))
      compare(c.widgetManager.diagnostics().counters.acquisitions,1)
      compare(c.widgetManager.diagnostics().counters.releases,0)
      compare(provider.starts,1)
      compare(provider.stops,0)
      compare(provider.activeCount,1)
      compare(provider.suspensions,0)
    }
    for(var i=0;i<4;i++) {
      host.externalDescriptors=({})
      wait(20)
      verify(host.sidebarWidgetRegistry["herdr.agents"].acquire===acquire,
        "host registry refresh must retain the Herdr acquisition function")
      compare(c.widgetManager.diagnostics().counters.acquisitions,1)
      compare(c.widgetManager.diagnostics().counters.releases,0)
      compare(provider.starts,1)
      compare(provider.stops,0)
    }
    var refreshTimer=createTemporaryObject(registryRefreshFactory,testCase,{
      registryHost:host,manager:c.widgetManager,backend:provider,acquireFunction:acquire
    })
    refreshTimer.start()
    tryCompare(refreshTimer,"refreshes",5,6000)
    host.externalDescriptors=({"fixture.unrelated":{
      id:"fixture.unrelated",label:"Unrelated",manageable:true,
      available:true,status:"ready",revision:1,
      expandedView:null,compactView:null,popupView:null,
      acquire:function(owner){return {setActive:function(){},release:function(){}}}
    }})
    wait(20)
    verify(host.sidebarWidgetRegistry["herdr.agents"].acquire===acquire)
    compare(c.widgetManager.diagnostics().counters.acquisitions,1)
    compare(c.widgetManager.diagnostics().counters.releases,0)
    host.externalDescriptors=({})
    wait(20)
    verify(host.sidebarWidgetRegistry["herdr.agents"].acquire===acquire)
    compare(c.widgetManager.diagnostics().counters.acquisitions,1)
    compare(c.widgetManager.diagnostics().counters.releases,0)

    panel.visible=false; panel.visible=true
    panel.panelCollapsed=true; panel.panelCollapsed=false
    compare(c.widgetManager.diagnostics().counters.acquisitions,1)
    compare(c.widgetManager.diagnostics().counters.releases,0)
    c.screens=[]; c.refresh()
    compare(provider.stops,1)
    compare(provider.suspensions,1)
    compare(provider.releaseCount,0)
    compare(c.widgetManager.diagnostics().counters.releases,0)
    c.screens=[{name:"TEST",width:1920,height:1080}]; c.refresh()
    compare(provider.starts,2)
    compare(provider.suspensions,1)
    compare(c.widgetManager.diagnostics().counters.acquisitions,1)
    compare(c.widgetManager.diagnostics().counters.releases,0)
    bridge.dockConsumerActive=true
    c.settings=Object.assign({},c.settings,{sidebarWidgets:[]}); c.refresh()
    compare(c.widgetManager.diagnostics().counters.releases,1)
    compare(provider.activeCount,1,"the classic Herdr consumer keeps the shared provider active")
    compare(provider.stops,1)
    compare(provider.suspensions,1)
    compare(provider.releaseCount,0)
    bridge.dockConsumerActive=false
    compare(provider.activeCount,0)
    compare(provider.stops,2)
    compare(provider.suspensions,2)
    compare(provider.acquireCount,1)
    compare(provider.releaseCount,0,"the bridge retains its inactive service lease until destruction")
    activeHerdrService=null;activeHerdrWindows=[];activeHerdrHandles=[]
  }
  function test_mirrors_have_independent_anchors_and_no_new_leases() {
    var f=build(),g=build(340,null,f.controller,f.provider);settle(f);settle(g)
    f.area.scrollView.contentY=f.area.cards.itemAt(1).y+24;settle(f)
    g.area.scrollView.contentY=60;settle(g)
    f.panel.width=220;settle(f);settle(g)
    fuzzyCompare(f.area.scrollView.contentY,f.area.cards.itemAt(1).y+24,0.1)
    fuzzyCompare(g.area.scrollView.contentY,60,0.1)
    compare(f.provider.acquisitions,3);compare(f.provider.subscriptions,1)
  }
  function test_popup_moves_on_split_without_widget_scroll_then_closes_hidden_anchor() {
    var f=build();settle(f)
    var anchor=named(f.area.cards.itemAt(0),"widget-card-header")
    verify(f.controller.openWidgetPopup("fixture.one",anchor));wait(50)
    var revision=f.area.layoutRevision,updates=f.area.popupWindow.anchor.updates,y=f.area.scrollView.contentY
    f.panel.viewport.contentHeight=100;settle(f)
    verify(f.area.layoutRevision>revision);verify(f.area.popupWindow.anchor.updates>updates)
    compare(f.area.scrollView.contentY,y);compare(f.controller.widgetPopupId,"fixture.one")
    anchor.parent.visible=false;f.area.requestLayout();wait(40)
    compare(f.controller.widgetPopupId,"")
  }
  function test_invalid_reorder_releases_and_edge_scroll() {
    var f=build();settle(f)
    var card=f.area.cards.itemAt(0),point=f.area.scrollView.mapToItem(null,100,15)
    for(var y of [-20,0,100,f.area.y+10,500,620]) {
      verify(f.area.beginDrag(card.widgetId,point.x,point.y))
      var invalid=f.panel.mapToItem(null,100,y)
      f.area.finishDrag(invalid.x,invalid.y,false)
      compare(writer.writes,0);compare(f.controller.widgetDragId,"")
    }
    var h=f.panel.viewport.contentY
    verify(f.area.beginDrag(card.widgetId,point.x,point.y))
    var edge=f.area.scrollView.mapToItem(null,100,f.area.scrollView.height-2)
    f.area.updateDrag(edge.x,edge.y)
    tryVerify(function(){return f.area.scrollView.contentY>0})
    compare(f.panel.viewport.contentY,h)
    f.area.finishDrag(0,0,true);compare(writer.writes,0);compare(f.area.dragWidgetId,"")
  }
  function test_external_order_change_cancels_drag_without_writes() {
    var f=build();settle(f)
    var p=f.area.scrollView.mapToItem(null,100,15)
    verify(f.area.beginDrag("fixture.one",p.x,p.y))
    setIds(f,["fixture.two","fixture.one","fixture.three"]);settle(f)
    compare(f.area.dragWidgetId,"");compare(f.controller.widgetDragId,"");compare(writer.writes,0)
  }
  function test_keyboard_traversal_reveals_last_input_then_next_card_and_back() {
    var f=build();settle(f)
    var first=f.area.cards.itemAt(0),second=f.area.cards.itemAt(1)
    f.area.manageControl.forceActiveFocus();keyClick(Qt.Key_Tab)
    verify(first.activeFocus,"Tab from section enters first card")
    keyClick(Qt.Key_Tab);verify(named(first,"widget-card-collapse").activeFocus)
    keyClick(Qt.Key_Tab);verify(named(first,"split-input-first").activeFocus)
    keyClick(Qt.Key_Tab);var last=named(first,"split-input-last");verify(last.activeFocus)
    settle(f);var point=f.area.scrollView.mapFromItem(last,0,0)
    verify(point.y>=-0.1&&point.y+last.height<=f.area.scrollView.height+0.1,"focused descendant must be visible")
    keyClick(Qt.Key_X);verify(last.text.indexOf("x")>=0)
    keyClick(Qt.Key_Tab);verify(second.activeFocus)
    keyClick(Qt.Key_Backtab);verify(last.activeFocus)
    compare(writer.writes,0)
  }
  function test_removing_focused_card_recovers_only_own_panel() {
    var f=build(),g=build(340,null,f.controller,f.provider);settle(f);settle(g)
    named(f.area.cards.itemAt(1),"split-input-last").forceActiveFocus();settle(f)
    setIds(f,["fixture.one","fixture.three"]);settle(f);settle(g)
    verify(f.area.cards.itemAt(1).activeFocus,"next old neighbor receives focus")
    verify(!g.area.cards.itemAt(1).activeFocus,"mirror must not steal focus")
    setIds(f,[]);wait(50);verify(f.panel.widgetManageControl.activeFocus,"main manager fallback")
    compare(writer.writes,0)
  }
  function test_external_collapse_returns_body_focus_to_collapse_control() {
    var f=build();settle(f)
    var card=f.area.cards.itemAt(0)
    named(card,"split-input-first").forceActiveFocus();settle(f)
    f.controller.settings=Object.assign({},f.controller.settings,{sidebarWidgetCollapsed:{"fixture.one":true}})
    f.controller.refresh();settle(f)
    verify(named(card,"widget-card-collapse").activeFocus);compare(writer.writes,0)
  }
  function test_hidden_grip_reorder_escape_and_title_double_click() {
    var f=build();settle(f)
    var card=f.area.cards.itemAt(0),grip=named(card,"widget-card-drag-handle")
    mouseMove(testCase,740,750);wait(30)
    compare(named(card,"widget-card-grip-icon").opacity,0)
    mousePress(grip,10,10);mouseMove(grip,10,24,20)
    tryCompare(f.area,"dragWidgetId","fixture.one")
    card.forceActiveFocus();keyClick(Qt.Key_Escape);mouseRelease(grip,10,24)
    compare(f.area.dragWidgetId,"");compare(f.controller.widgetDragId,"");compare(writer.writes,0)
    mouseDoubleClickSequence(named(card,"widget-card-header-toggle"),40,14)
    compare(writer.writes,1)
  }
  function test_provider_refresh_does_not_recreate_cards_or_steal_input_focus() {
    var f=build();settle(f)
    var card=f.area.cards.itemAt(0),input=named(card,"split-input-first")
    input.forceActiveFocus();settle(f);f.provider.publish("ready");settle(f)
    compare(f.area.cards.itemAt(0),card);verify(input.activeFocus)
    compare(f.provider.acquisitions,3);compare(f.provider.releases,0)
  }
  function test_fixed_manager_follows_split_and_main_manager_survives_zero_cards() {
    var f=build();settle(f)
    var manager=SplitHarness.makeManager(f.panel);areas.push(manager);f.panel.widgetManager=manager
    verify(manager.openFor(f.area.manageControl));wait(30)
    var updates=manager.popupWindow.anchor.updates,y=f.area.scrollView.contentY
    f.panel.viewport.contentHeight=100;settle(f)
    verify(manager.popupWindow.anchor.updates>updates,"section anchor follows hierarchy demand")
    compare(f.area.scrollView.contentY,y)
    setIds(f,[]);wait(30);verify(!manager.managerOpen)
    verify(manager.openFor(f.panel.widgetManageControl));wait(30);verify(manager.managerOpen)
    f.panel.width=220;wait(30);verify(manager.managerOpen)
    f.panel.visible=false;wait(20);verify(!manager.managerOpen)
  }
  function test_tab_section_boundaries_and_zero_body_skip() {
    var f=build();settle(f)
    f.area.manageControl.forceActiveFocus();keyClick(Qt.Key_Backtab)
    verify(f.panel.viewport.activeFocus,"Backtab returns to hierarchy")
    f.panel.availableHeight=f.area.naturalWidgetHeaderHeight;wait(40)
    f.area.manageControl.forceActiveFocus();keyClick(Qt.Key_Tab)
    verify(f.panel.footerControl.activeFocus,"header-only skips card/body controls")
  }
  function test_native_nested_scrollview_contains_wheel_at_both_bounds() {
    innerEnabled=true
    var f=build();settle(f);f.panel.availableHeight=600;settle(f)
    var nested=named(f.area.cards.itemAt(0),"nested-scroll"),inner=nested.contentItem
    var outer=f.area.scrollView.contentY,hierarchy=f.panel.viewport.contentY
    mouseWheel(nested,100,30,0,-120)
    tryVerify(function(){return inner.contentY>0});tryCompare(inner,"moving",false);settle(f)
    compare(f.area.scrollView.contentY,outer);compare(f.panel.viewport.contentY,hierarchy)
    for(var bottom of [false,true]) {
      inner.contentY=bottom?inner.contentHeight-inner.height:0
      var initial=inner.contentY
      mouseWheel(nested,100,30,0,bottom?-120:120);tryCompare(inner,"moving",false);settle(f)
      fuzzyCompare(inner.contentY,initial,0.01)
      compare(f.area.scrollView.contentY,outer);compare(f.panel.viewport.contentY,hierarchy)
    }
  }
  function test_title_vertical_drag_scrolls_without_reordering() {
    var f=build();settle(f)
    var title=named(f.area.cards.itemAt(0),"widget-card-header-toggle")
    mousePress(title,40,16);mouseMove(title,40,2,40);mouseMove(title,40,-30,40);mouseMove(title,40,-65,40)
    mouseRelease(title,40,-65);settle(f)
    verify(f.area.scrollView.contentY>0,"title drag can be stolen by Widget Flickable")
    compare(f.area.dragWidgetId,"");compare(f.panel.viewport.contentY,0);compare(writer.writes,0)
  }
  function test_grip_valid_release_writes_once_and_preserves_filtered_order() {
    var f=build(0,["fixture.one","herdr.agents","fixture.two","fixture.three"]);settle(f)
    f.controller.settings=Object.assign({},f.controller.settings,{sidebarWidgetCollapsed:{"fixture.one":true,"fixture.two":true,"fixture.three":true}})
    f.controller.refresh();settle(f)
    var card=f.area.cards.itemAt(0),grip=named(card,"widget-card-drag-handle")
    var end=f.area.scrollView.mapToItem(grip,120,f.area.scrollView.height-5)
    mousePress(grip,10,10);mouseMove(grip,10,24,20);mouseMove(grip,end.x,end.y,20)
    mouseRelease(grip,end.x,end.y);settle(f)
    compare(writer.writes,1)
    compare(JSON.stringify(writer.lastValue),JSON.stringify(["herdr.agents","fixture.two","fixture.three","fixture.one"]))
    compare(f.area.dragWidgetId,"");compare(f.controller.widgetDragId,"")
  }
  function test_reflow_during_wheel_does_not_snap_back() {
    var f=build();settle(f);f.area.scrollView.contentY=100;settle(f)
    mouseWheel(f.area.scrollView,120,120,0,-120);f.panel.availableHeight=420
    tryVerify(function(){return f.area.scrollView.contentY>100})
    settle(f);verify(f.area.scrollView.contentY>100);compare(f.panel.viewport.contentY,0)
  }

  function test_presentation_visibility_updates_after_scroll() {
    var f=build();settle(f)
    var first=f.area.cards.itemAt(0),second=f.area.cards.itemAt(1)
    verify(first.presentationVisible);verify(!second.presentationVisible)
    f.area.scrollView.contentY=second.y;settle(f)
    verify(!first.presentationVisible,"fully clipped card must suspend presentation")
    verify(second.presentationVisible,"newly visible card must resume presentation")
    compare(f.provider.acquisitions,3);compare(f.provider.releases,0)
  }

  function test_header_font_reflow_updates_geometry_without_scroll() {
    var f=build();settle(f)
    var anchor=named(f.area.cards.itemAt(0),"widget-card-header")
    verify(f.controller.openWidgetPopup("fixture.one",anchor));wait(30)
    var revision=f.area.layoutRevision,updates=f.area.popupWindow.anchor.updates,y=f.area.scrollView.contentY
    named(f.area,"widget-section-label").font.pixelSize=40
    tryVerify(function(){return f.area.layoutRevision>revision})
    verify(f.area.popupWindow.anchor.updates>updates)
    compare(f.area.scrollView.contentY,y)
  }
}
