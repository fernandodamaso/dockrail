pragma ComponentBehavior: Bound
import QtQuick
import qs.Ui as Ui
import qs.Commons
import "DockSettingsRegistry.js" as Registry
import "DockScreenPresentationModel.js" as ScreenModel

Item {
  id: root
  required property var host
  required property var metadata
  readonly property var presentation: host.currentPresentation()
  readonly property var screens: presentation.entries || []
  readonly property int monitorCount: screens.length
  readonly property string arrangement: host.settings.workspaceLayout || "flat"
  readonly property string defaultMode: host.settings.presentationMode || "classic"
  readonly property bool disconnectedSaved: Object.keys(host.settings.presentationModeByMonitor || {}).some(function(name) {
    return !root.screens.some(function(screen) { return screen.connector === name })
  })
  readonly property var layoutCards: Registry.layoutCards(metadata)
  readonly property bool classicUsed: (presentation.classicScreens || []).length > 0
  property bool panelActive: false
  property int cursor: 0
  property bool cursorActive: false
  property string feedback: ""
  property var previousMonitorOrder: []
  property int navigationRevision: 0
  readonly property var targets: { navigationRevision; return navigationTargets() }
  readonly property var selectedTarget: targets.length ? targets[Math.min(cursor,targets.length-1)] : null
  readonly property bool editorFocused: !!(selectedTarget && selectedTarget.textFocused)
  readonly property bool popupOpen: !!(selectedTarget && selectedTarget.popupOpen)
  signal changed()
  signal focusSections()
  signal focusSettings()
  signal reveal(var item)
  implicitHeight: stack.implicitHeight
  width: parent ? parent.width : 470

  function report(result) {
    var outcome = Registry.writeOutcome(result)
    feedback = !outcome.accepted && outcome.reply && outcome.reply.error
      ? outcome.reply.error.code + ": " + outcome.reply.error.message : ""
    if (outcome.accepted) changed()
    return outcome.accepted
  }
  function chooseMonitor(connector, mode, token) {
    return report(host.monitorModeIntent(connector,mode,token))
  }
  function toggleIconRail(connector) {
    var screen = host.connectedScreens.filter(function(screen) {return screen.name === connector})[0]
    return report(host.sidebarController.requestCollapse(screen))
  }
  function chooseAutomaticOrder() {
    var current = host.settings.workspaceMonitorOrder || []
    if (current.length) previousMonitorOrder = current.slice()
    var next = current.length ? [] : Registry.manualMonitorOrder(previousMonitorOrder, screens.map(function(entry) {return entry.connector}))
    return report(host.saveSettingIntent("workspaceMonitorOrder",next,current))
  }
  function reorder(connector, delta, expected) {
    var next = Registry.moveMonitor(expected,connector,delta)
    return report(host.saveSettingIntent("workspaceMonitorOrder",next,expected))
  }
  function navigationTargets() {
    var result=[]
    for (var i=0;i<cards.count;i++) {
      var card=cards.itemAt(i)
      if (!card) continue
      if (card.isDisplays) {
        for (var j=0;j<card.monitors.count;j++) {
          var monitor=card.monitors.itemAt(j)
          if (monitor) { result.push(monitor); if (monitor.rail.visible) result.push(monitor.rail) }
        }
      }
      for (var k=0;k<card.rows.count;k++) {
        var row=card.rows.itemAt(k)
        if (row && row.visible) result.push(row)
      }
      if (card.isDisplays && monitorCount>=2) {
        result.push(card.orderToggle)
        for (var n=0;n<card.orderRows.count;n++) {
          var orderRow=card.orderRows.itemAt(n)
          if (orderRow && orderRow.visible) result.push(orderRow)
        }
      }
      if (card.isSidebar && monitorCount===1 && screens[0].mode==="sidebar") result.push(card.singleRail)
    }
    return result
  }
  function focusTarget(index) {
    cursor=Math.max(0,Math.min(targets.length-1,index)); cursorActive=true
    if (selectedTarget) reveal(selectedTarget)
  }
  function moveCursor(delta) {focusTarget(cursor+delta)}
  function adjust(delta) {if(selectedTarget && selectedTarget.adjust) selectedTarget.adjust(delta)}
  function activate() {if(selectedTarget && selectedTarget.activate) selectedTarget.activate()}
  function dismissEditor() {return !!(selectedTarget && selectedTarget.dismissEditor && selectedTarget.dismissEditor())}
  function copyCommand() {
    return selectedTarget && selectedTarget.command ? selectedTarget.command() : ""
  }
  function reorderSelected(delta) {
    if (selectedTarget && selectedTarget.reorderBy) selectedTarget.reorderBy(delta)
  }
  function hovered(item) {var index=targets.indexOf(item); if(index>=0) {focusTarget(index); focusSettings()}}
  Column {
    id: stack
    width: parent.width
    spacing: Style.space(14)
    Text { text:"Layout"; font.family:Style.font.family; font.pixelSize:Style.font.title; font.bold:true; color:Color.foreground }
    Repeater {
      id: cards
      onItemAdded: root.navigationRevision++
      onItemRemoved: root.navigationRevision++
      model: root.layoutCards
      delegate: Ui.BorderSurface {
        id: card
        required property var modelData
        readonly property bool isDisplays: modelData.id === "displays"
        readonly property bool isSidebar: modelData.id === "sidebar"
        readonly property bool isClassic: modelData.id === "classic"
        property alias monitors: monitors
        property alias rows: rows
        property alias orderToggle: orderToggle
        property alias orderRows: orderRows
        property alias singleRail: singleRail
        width: stack.width
        height: cardBody.implicitHeight + Style.space(24)
        color: Qt.tint(Color.background, Util.alpha(Color.foreground,0.035))
        borderSpec: Border.surfaceSpec("popups","border",Util.alpha(Color.foreground,0.15),1)
        radius: Style.cornerRadius
        Column {
          id: cardBody
          x:Style.space(12); y:Style.space(12)
          width:parent.width-Style.space(24)
          spacing:Style.space(12)
          Row {
            width:parent.width
            spacing:Style.space(8)
            DockLucideIcon { width:18; height:18; iconSize:18; tint:Color.foreground; iconName:card.isDisplays?"monitor":card.isSidebar?"panel-left-open":"panel-bottom" }
            Text {
              width:parent.width-Style.space(112)
              text: card.isDisplays?"Displays":card.isSidebar?"Sidebar":"Classic dock"
              wrapMode:Text.WordWrap; color:Color.foreground; font.family:Style.font.family; font.pixelSize:Style.font.body; font.bold:true
            }
            Text {text:card.isClassic&&!root.classicUsed?"Not in use":""; width:Style.space(70); horizontalAlignment:Text.AlignRight; color:Color.foreground; font.family:Style.font.family; font.pixelSize:Style.font.caption}
          }
          Repeater {
            id: monitors
            onItemAdded: root.navigationRevision++
            onItemRemoved: root.navigationRevision++
            model: card.isDisplays ? root.host.connectedScreens : []
            delegate: Column {
              id: monitor
              required property var modelData
              readonly property var entry: ScreenModel.entryFor(root.presentation,modelData.name) || ({connector:modelData.name,mode:"classic"})
              property var editToken: null
              property bool popupOpen:false
              property bool textFocused:false
              property alias rail: rail
              width:cardBody.width
              spacing:Style.space(6)
              function beginEdit() {if(!editToken) editToken=ScreenModel.modeGestureToken(root.presentation,entry.connector)}
              function choose(mode) {beginEdit(); root.chooseMonitor(entry.connector,mode,editToken); editToken=null}
              function adjust(delta) {
                beginEdit()
                var choices=root.monitorCount===1?["classic","sidebar"]:["default","classic","sidebar"]
                var current=root.monitorCount===1?entry.mode:Registry.monitorChoice(root.host.settings,entry.connector)
                choose(choices[Math.max(0,Math.min(choices.length-1,choices.indexOf(current)+delta))])
              }
              function activate() {adjust(1)}
              function command() {return Registry.cliCommand("presentationModeByMonitor",root.host.settings.presentationModeByMonitor)}
              Text { text:monitor.entry.connector; color:root.selectedTarget===monitor&&root.cursorActive?Color.accent:Color.foreground; font.family:Style.font.family; font.pixelSize:Style.font.body }
              Ui.ButtonGroup {
                value:root.monitorCount===1?monitor.entry.mode:Registry.monitorChoice(root.host.settings,monitor.entry.connector)
                options:root.monitorCount===1?[{value:"classic",label:"Classic dock"},{value:"sidebar",label:"Sidebar"}]:[{value:"default",label:"Default"},{value:"classic",label:"Classic dock"},{value:"sidebar",label:"Sidebar"}]
                enabled:root.host.settingsLoadState!=="invalid"
                onHovered: (index,on) => {if(on){monitor.beginEdit();root.hovered(monitor)}else monitor.editToken=null}
                onActiveFocusChanged: if(activeFocus) monitor.beginEdit()
                onChanged: mode => monitor.choose(mode)
              }
              Text {visible:root.monitorCount>=2&&Registry.monitorChoice(root.host.settings,monitor.entry.connector)==="default"; text:"Default → "+monitor.entry.mode; color:Color.foreground; font.family:Style.font.family; font.pixelSize:Style.font.caption}
              Ui.Toggle {
                id:rail
                width:parent.width
                visible:root.monitorCount>=2&&monitor.entry.mode==="sidebar"
                label:"Icon rail"
                checked:(root.host.settings.sidebarCollapsedByMonitor || {})[monitor.entry.connector]===undefined?root.host.settings.sidebarCollapsed:(root.host.settings.sidebarCollapsedByMonitor || {})[monitor.entry.connector]
                enabled:root.host.settingsLoadState!=="invalid"
                function activate(){root.toggleIconRail(monitor.entry.connector)}
                function adjust(delta){activate()}
                function command(){return Registry.cliCommand("sidebarCollapsedByMonitor",root.host.settings.sidebarCollapsedByMonitor)}
                onClicked:activate()
                onHovered: on => {if(on)root.hovered(rail)}
              }
            }
          }
          Repeater {
            id:rows
            onItemAdded: root.navigationRevision++
            onItemRemoved: root.navigationRevision++
            model:card.modelData.rows.filter(function(row){return ["presentationModeByMonitor","sidebarCollapsedByMonitor","workspaceMonitorOrder"].indexOf(row.key)<0})
            delegate:DockSettingsRow {
              required property var modelData
              required property int index
              groupHeading: card.isClassic && (index === 0 || card.modelData.rows[index-1].ui.group !== modelData.ui.group)
                ? Registry.groupLabel(modelData.ui.group) : ""
              width:cardBody.width
              row:modelData
              feedbackActive: root.panelActive && visible
              visible: (Registry.layoutRowVisible(modelData,root.monitorCount,root.arrangement)
                || (key === "presentationMode" && root.disconnectedSaved))
                && !(key === "sidebarCollapsed" && root.defaultMode !== "sidebar")
              onVisibleChanged: root.navigationRevision++
              host:root.host
              monitorCount:root.monitorCount
              hasCursor:root.cursorActive&&root.selectedTarget===this
              function command(){return Registry.cliCommand(key,current)}
              onHovered:root.hovered(this)
              onEdited:root.changed()
              onFocusSections:root.focusSections()
            }
          }
          Ui.Toggle {
            id:singleRail
            width:parent.width
            visible:card.isSidebar&&root.monitorCount===1&&root.screens[0].mode==="sidebar"
            label:"Icon rail"
            checked:visible&&((root.host.settings.sidebarCollapsedByMonitor || {})[root.screens[0].connector]===undefined?root.host.settings.sidebarCollapsed:(root.host.settings.sidebarCollapsedByMonitor || {})[root.screens[0].connector])
            enabled:root.host.settingsLoadState!=="invalid"
            function activate(){if(visible)root.toggleIconRail(root.screens[0].connector)}
            function adjust(delta){activate()}
            function command(){return Registry.cliCommand("sidebarCollapsedByMonitor",root.host.settings.sidebarCollapsedByMonitor)}
            onClicked:activate()
            onHovered:on=>{if(on)root.hovered(singleRail)}
          }
          Ui.Toggle {
            id:orderToggle
            width:parent.width
            visible:card.isDisplays&&root.monitorCount>=2
            label:"Automatic monitor order"
            description:"Turn off to drag your own order. Alt+↑/↓ also reorders."
            checked:(root.host.settings.workspaceMonitorOrder || []).length===0
            enabled:root.host.settingsLoadState!=="invalid"
            function activate(){root.chooseAutomaticOrder()}
            function adjust(delta){activate()}
            function command(){return Registry.cliCommand("workspaceMonitorOrder",root.host.settings.workspaceMonitorOrder)}
            onClicked:activate()
            onHovered:on=>{if(on)root.hovered(orderToggle)}
          }
          Repeater {
            id:orderRows
            onItemAdded: root.navigationRevision++
            onItemRemoved: root.navigationRevision++
            model:card.isDisplays&&root.monitorCount>=2?root.host.settings.workspaceMonitorOrder:[]
            delegate:Ui.Button {
              id:orderRow
              required property string modelData
              required property int index
              property var expectedOrder: null
              width:cardBody.width
              height:Style.space(36)
              text:modelData + (root.screens.some(function(s){return s.connector===orderRow.modelData})?"":" · disconnected")
              focusable:true
              enabled:root.host.settingsLoadState!=="invalid"
              Accessible.name:text+", position "+(index+1)+". Alt Up or Down to reorder."
              function reorderBy(delta){root.reorder(modelData,delta,root.host.settings.workspaceMonitorOrder.slice())}
              function activate(){root.hovered(orderRow)}
              function command(){return Registry.cliCommand("workspaceMonitorOrder",root.host.settings.workspaceMonitorOrder)}
              onHovered:on=>{if(on)root.hovered(orderRow)}
              onClicked:root.hovered(orderRow)
              Item {
                id:grip
                width:Style.space(30); height:parent.height
                Text {anchors.centerIn:parent; text:"↕"; color:Color.foreground}
                MouseArea {
                  anchors.fill:parent
                  cursorShape:Qt.SizeVerCursor
                  drag.target:grip
                  drag.axis:Drag.YAxis
                  onPressed:{orderRow.expectedOrder=root.host.settings.workspaceMonitorOrder.slice();root.hovered(orderRow)}
                  onReleased:{var delta=Math.round(grip.y/orderRow.height);grip.y=0;if(delta)root.reorder(orderRow.modelData,delta,orderRow.expectedOrder)}
                  onCanceled:grip.y=0
                }
              }
            }
          }
        }
      }
    }
    Text {visible:root.feedback!==""; width:parent.width; text:root.feedback; wrapMode:Text.WordWrap; color:Color.foreground; font.family:Style.font.family; font.pixelSize:Style.font.caption}
  }
}
