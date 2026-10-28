pragma ComponentBehavior: Bound
import QtQuick
import qs.Ui as Ui
import qs.Commons
import qs.Commons as Commons
import "DockSettingsRegistry.js" as Registry
import "DockSettingsAppsModel.js" as Apps
import "DockIconModel.js" as IconModel

// The Apps section is a view over the canonical schema homes and host intents.
// No QML file writes, direct executable invocation or replacement settings array.
Item {
  id: root
  required property var host
  required property var metadata
  property bool panelActive: false
  property int cursor: 0
  property bool cursorActive: false
  property int navigationRevision: 0
  property string feedback: ""
  property string selectedAppId: ""
  property string dragId: ""
  property var dragExpected: null
  property var dragGrip: null
  property bool reordering: false
  property var confirmSnapshot: []
  property bool awaitingShowAll: false
  property bool commandEditing: false
  property string commandDraft: ""
  property string commandExpected: ""
  property bool commandConflict: false
  property string commandFeedback: ""
  property bool committingCommand: false
  readonly property bool busy: host.settingsLoadState === "invalid"
    || host.settingsWriteState === "saving" || !host.settingsLoaded
    || host.settingsReloadPending
  readonly property var rows: Registry.sectionRows(metadata, "apps")
  readonly property var pins: Apps.applicationRows(host.settings.pinned, host.applications)
  readonly property var hidden: Apps.applicationRows(host.settings.hiddenApplications, host.applications)
  readonly property var icons: Apps.iconRows(host.settings, host.applications)
  readonly property var chromeReadiness: host.featureReadinessBridge.lastGoodFeatures
    && host.featureReadinessBridge.lastGoodFeatures.chromeProfilesTabs || ({})
  readonly property bool chromeReady: chromeReadiness.installation === "installed"
    && chromeReadiness.runtime === "ready"
  readonly property var targets: {
    navigationRevision
    var result = []
    for (var i=0;i<pinnedList.count;i++) {
      var pin=pinnedList.itemAt(i)
      if(pin) result.push(pin)
    }
    for (var h=0;h<hiddenList.count;h++) {
      var hiddenRow=hiddenList.itemAt(h)
      if(hiddenRow) result.push(hiddenRow)
    }
    for (var n=0;n<iconList.count;n++) {
      var iconRow=iconList.itemAt(n)
      if(iconRow) result.push(iconRow)
    }
    ;[pinButton,showAllButton,badgeToggle,tabsToggle,mutedSelect,
      trashToggle,commandField,commandSave,commandReset].forEach(function(item) {
      if(item && item.visible) result.push(item)
    })
    return result
  }
  readonly property var selectedTarget: targets.length
    ? targets[Math.max(0,Math.min(cursor,targets.length-1))] : null
  readonly property bool editorFocused: commandField.activeFocus
  readonly property bool popupOpen: mutedSelect.popupOpen || awaitingShowAll
  signal changed()
  signal focusSettings()
  signal focusSections()
  signal reveal(var item)
  signal openAppPicker()
  signal requestIconChange(var item)
  signal requestShowAll()
  implicitHeight: stack.implicitHeight
  width: parent ? parent.width : 470

  function rowFor(key) {
    for(var i=0;i<rows.length;++i) if(rows[i].key===key) return rows[i]
    return null
  }
  function notify(result) {
    var outcome=Registry.writeOutcome(result)
    var error=outcome.reply && outcome.reply.error
    feedback=outcome.accepted ? "" : (error ? error.code+": "+error.message : "Could not save.")
    if(outcome.accepted) changed()
    return outcome.accepted
  }
  function write(key,value) {
    if(busy) return false
    return notify(host.saveSettingIntent(key,value,host.settings[key]))
  }
  function movePinned(id,delta,expected) {
    if(busy) return false
    if(expected && JSON.stringify(expected)!==JSON.stringify(host.settings.pinned)) {
      feedback="Pinned apps changed while dragging. Try again."
      return false
    }
    var args=Apps.moveArguments(host.settings.pinned,id,delta)
    if(!args) return false
    selectedAppId=id
    reordering=true
    var accepted=notify(host.changeApplication("move",args))
    Qt.callLater(function(){root.selectedAppId=id;root.syncCursor();root.reordering=false})
    return accepted
  }
  function dropPinned(id,target,expected) {
    if(busy || JSON.stringify(expected)!==JSON.stringify(host.settings.pinned)) {
      feedback="Pinned apps changed while dragging. Try again.";return false
    }
    var args=Apps.dragArguments(host.settings.pinned,id,target)
    if(!args)return false
    selectedAppId=id
    return notify(host.changeApplication("move",args))
  }
  function cancelDrag() {
    if(dragGrip)dragGrip.y=0
    dragGrip=null;dragId="";dragExpected=null
  }
  function focusTarget(index) {
    cursor=Math.max(0,Math.min(targets.length-1,index))
    selectedAppId=targets[cursor] && targets[cursor].appId || ""
    cursorActive=true
    if(selectedTarget)reveal(selectedTarget)
  }
  function syncCursor() {
    for(var i=0;i<targets.length;i++)
      if(targets[i].appId && targets[i].appId===selectedAppId){cursor=i;return}
  }
  function moveCursor(delta){focusTarget(Math.max(0,targets.indexOf(selectedTarget))+delta)}
  function adjust(delta) {if(selectedTarget && selectedTarget.adjust)selectedTarget.adjust(delta)}
  function activate() {
    if(selectedTarget && selectedTarget.activate)selectedTarget.activate()
    else if(selectedTarget && selectedTarget.clicked)selectedTarget.clicked()
    else if(selectedTarget && selectedTarget.open)selectedTarget.open()
    else if(selectedTarget)selectedTarget.forceActiveFocus()
  }
  function reorderSelected(delta) {
    if(selectedTarget && selectedTarget.pinnedId)movePinned(selectedTarget.pinnedId,delta)
  }
  function copyCommand() {
    if(selectedTarget && selectedTarget.command)return selectedTarget.command()
    return Registry.cliCommand("pinned",host.settings.pinned)
  }
  function dismissEditor() {
    if(awaitingShowAll){awaitingShowAll=false;return true}
    if(dragId){cancelDrag();return true}
    if(mutedSelect.popupOpen){mutedSelect.close();return true}
    if(commandEditing){reloadCommand();return true}
    return false
  }
  function cancelPending(){
    cancelDrag()
    awaitingShowAll=false
    reloadCommand()
    mutedSelect.close()
  }
  function hovered(item) {
    if(reordering)return
    var index=targets.indexOf(item)
    if(index>=0){focusTarget(index);focusSettings()}
  }
  function confirmShowAll() {
    if(!awaitingShowAll)return false
    awaitingShowAll=false
    if(JSON.stringify(confirmSnapshot)!==JSON.stringify(host.settings.hiddenApplications)) {
      feedback="Hidden apps changed. Review the list before showing all."
      return false
    }
    if(!confirmSnapshot.length)return false
    return notify(host.changeApplication("show",{all:true}))
  }
  function askShowAll() {
    if(busy || !host.settings.hiddenApplications.length)return
    confirmSnapshot=host.settings.hiddenApplications.slice()
    awaitingShowAll=true
    requestShowAll()
  }
  function resetIcon(item) {
    if(busy)return false
    // The current snapshot is validated by saveIconChange, exactly like the
    // existing Change Icon dialog. Never mutate the whole overrides collection.
    var target=item.kind==="window"
      ? {kind:"window",key:host.windowIconTargetKey(item.appId,item.titlePattern),
        appId:item.appId,titlePattern:item.titlePattern,source:IconModel.normalizeSource(item.source)}
      : {kind:item.kind,key:item.key,source:IconModel.normalizeSource(item.source)}
    return notify(host.saveIconChange({remove:target,set:null}))
  }
  function reloadCommand() {
    commandEditing=false;commandConflict=false;commandFeedback=""
    commandExpected=String(host.settings.controlCommand || "")
    commandDraft=commandExpected
  }
  function beginCommand() {
    if(commandEditing)return
    commandExpected=String(host.settings.controlCommand || "")
    commandDraft=commandExpected
    commandEditing=true
  }
  function saveCommand() {
    if(busy)return false
    if(commandConflict){
      commandFeedback="Changed elsewhere. Reload or keep editing."
      return false
    }
    var result=Registry.writeOutcome(host.saveSettingIntent("controlCommand",
      commandDraft,commandExpected))
    var error=result.reply && result.reply.error
    if(!result.accepted) {
      commandFeedback=error?error.code+": "+error.message:"Could not save."
      if(error && error.code==="E_STALE")commandConflict=true
      return false
    }
    committingCommand=true
    reloadCommand()
    committingCommand=false
    changed()
    return true
  }
  function resetCommand() {
    if(busy)return false
    var expected=String(host.settings.controlCommand || "")
    return notify(host.resetSettingIntent("controlCommand",expected))
  }
  onPinsChanged: {
    if(dragId)cancelDrag()
    Qt.callLater(function(){root.syncCursor()})
  }
  onPanelActiveChanged: if(!panelActive)cancelPending()
  Component.onCompleted: {reloadCommand();navigationRevision++}
  Connections {
    target:root.host
    function onSettingsChanged() {
      if(root.committingCommand)return
      if(root.commandEditing) {
        if(String(root.host.settings.controlCommand)!==root.commandExpected)
          root.commandConflict=true
      } else root.reloadCommand()
    }
  }

  Column {
    id:stack
    width:parent.width
    spacing:Style.space(14)
    Text {
      text:"Apps";font.bold:true;font.family:Style.font.family
      font.pixelSize:Style.font.title;color:Commons.Color.foreground
    }
    Text {
      width:parent.width;wrapMode:Text.WordWrap;textFormat:Text.PlainText
      text:"Right-click or drag apps on the dock for everyday changes. Come here to find hidden apps and custom icons."
      color:Commons.Color.foreground;opacity:0.9;font.family:Style.font.family
      font.pixelSize:Style.font.caption
    }
    Ui.BorderSurface {
      width:stack.width;height:pinnedBody.implicitHeight+Style.space(24)
      color:Qt.tint(Commons.Color.background,Util.alpha(Commons.Color.foreground,0.035))
      borderSpec:Border.surfaceSpec("popups","border",Util.alpha(Commons.Color.foreground,0.15),1)
      radius:Style.cornerRadius
      Column {
        id:pinnedBody
        x:Style.space(12);y:Style.space(12);width:parent.width-Style.space(24)
        spacing:Style.space(9)
        Row {
          spacing:Style.space(8)
          DockLucideIcon {iconName:"pin";iconSize:16;width:16;height:16;tint:Commons.Color.foreground}
          Text {text:"Pinned";font.bold:true;color:Commons.Color.foreground;font.family:Style.font.family}
        }
        Text {
          width:parent.width;text:"Drag the grip or press Alt+↑/↓ to reorder. Unavailable saved apps stay listed."
          wrapMode:Text.WordWrap;color:Commons.Color.foreground;opacity:0.85;font.pixelSize:Style.font.caption
        }
        Text {visible:root.pins.length===0;text:"No pinned apps.";color:Commons.Color.foreground}
        Repeater {
          id:pinnedList
          onItemAdded:root.navigationRevision++
          onItemRemoved:root.navigationRevision++
          model:root.pins
          delegate:Row {
            id:pinRow
            required property var modelData
            required property int index
            readonly property string pinnedId:modelData.id
            readonly property string appId:modelData.id
            width:pinnedBody.width
            spacing:Style.space(7)
            Accessible.role:Accessible.ListItem
            Accessible.name:modelData.name+", position "+(index+1)+". Alt Up or Alt Down to reorder."
            function command(){return "dockrail apps move "+appId}
            function activate(){root.hovered(pinRow)}
            function adjust(delta){root.movePinned(pinnedId,delta)}
            HoverHandler{onHoveredChanged:if(hovered)root.hovered(pinRow)}
            Item {
              id:grip
              width:Style.space(24);height:Style.space(34)
              Text {anchors.centerIn:parent;text:"↕";color:Commons.Color.foreground}
              MouseArea {
                anchors.fill:parent;enabled:!root.busy
                cursorShape:enabled?Qt.SizeVerCursor:Qt.ArrowCursor
                drag.target:grip;drag.axis:Drag.YAxis
                onPressed:{
                  root.dragId=pinRow.pinnedId;root.dragGrip=grip
                  root.dragExpected=(root.host.settings.pinned||[]).slice()
                  root.hovered(pinRow)
                }
                onReleased:{
                  var active=root.dragId===pinRow.pinnedId
                  var delta=Math.round(grip.y/Math.max(1,pinRow.height))
                  var expected=root.dragExpected
                  root.cancelDrag()
                  if(active && delta)root.movePinned(pinRow.pinnedId,delta,expected)
                }
                onCanceled:root.cancelDrag()
              }
            }
            Column {
              width:Math.max(0,parent.width-grip.width-unpinButton.width-parent.spacing*2)
              Text {
                text:pinRow.modelData.name;textFormat:Text.PlainText
                font.bold:true;wrapMode:Text.WordWrap;width:parent.width
                color:root.cursorActive&&root.selectedTarget===pinRow?Commons.Color.accent:Commons.Color.foreground
              }
              Text {text:pinRow.pinnedId;textFormat:Text.PlainText;width:parent.width;wrapMode:Text.WrapAnywhere;color:Commons.Color.foreground;opacity:0.8;font.pixelSize:Style.font.caption}
            }
            Ui.Button {
              id:unpinButton;text:"Unpin";focusable:true;enabled:!root.busy
              onHovered:function(value){if(value)root.hovered(pinRow)}
              onClicked:root.notify(root.host.unpinApplication(pinRow.pinnedId))
            }
          }
        }
        Ui.Button {
          id:pinButton;text:"Add pinned application";width:parent.width
          focusable:true;enabled:!root.busy
          onHovered:function(value){if(value)root.hovered(pinButton)}
          onClicked:root.openAppPicker()
        }
      }
    }
    Ui.BorderSurface {
      width:stack.width;height:hiddenBody.implicitHeight+Style.space(24)
      color:Qt.tint(Commons.Color.background,Util.alpha(Commons.Color.foreground,0.035))
      borderSpec:Border.surfaceSpec("popups","border",Util.alpha(Commons.Color.foreground,0.15),1)
      radius:Style.cornerRadius
      Column {
        id:hiddenBody;x:Style.space(12);y:Style.space(12)
        width:parent.width-Style.space(24);spacing:Style.space(9)
        Row {
          spacing:Style.space(8)
          DockLucideIcon {iconName:"eye-off";iconSize:16;width:16;height:16;tint:Commons.Color.foreground}
          Text {text:"Hidden";font.bold:true;color:Commons.Color.foreground}
        }
        Text {visible:root.hidden.length===0;text:"No hidden apps.";color:Commons.Color.foreground}
        Repeater {
          id:hiddenList
          onItemAdded:root.navigationRevision++
          onItemRemoved:root.navigationRevision++
          model:root.hidden
          delegate:Row {
            id:hiddenRow
            required property var modelData
            readonly property string appId:modelData.id
            width:hiddenBody.width;spacing:Style.space(8)
            function command(){return "dockrail apps show "+appId}
            function activate(){root.notify(root.host.changeApplication("show",{id:appId}))}
            HoverHandler{onHoveredChanged:if(hovered)root.hovered(hiddenRow)}
            Column {
              width:Math.max(0,parent.width-showButton.width-parent.spacing)
              Text {text:hiddenRow.modelData.name;width:parent.width;textFormat:Text.PlainText;wrapMode:Text.WordWrap;font.bold:true;color:Commons.Color.foreground}
              Text {text:hiddenRow.appId;width:parent.width;textFormat:Text.PlainText;wrapMode:Text.WrapAnywhere;color:Commons.Color.foreground;opacity:0.8}
            }
            Ui.Button {id:showButton;text:"Show";enabled:!root.busy;onClicked:hiddenRow.activate()}
          }
        }
        Ui.Button {
          id:showAllButton;text:"Show all hidden apps"
          visible:root.hidden.length>0;enabled:!root.busy
          onClicked:root.askShowAll()
        }
      }
    }
    Ui.BorderSurface {
      width:stack.width;height:iconBody.implicitHeight+Style.space(24)
      color:Qt.tint(Commons.Color.background,Util.alpha(Commons.Color.foreground,0.035))
      borderSpec:Border.surfaceSpec("popups","border",Util.alpha(Commons.Color.foreground,0.15),1)
      radius:Style.cornerRadius
      Column {
        id:iconBody;x:Style.space(12);y:Style.space(12)
        width:parent.width-Style.space(24);spacing:Style.space(10)
        Row {
          spacing:Style.space(8)
          DockLucideIcon {iconName:"image";iconSize:16;width:16;height:16;tint:Commons.Color.foreground}
          Text {text:"Custom icons";font.bold:true;color:Commons.Color.foreground}
        }
        Text {
          width:parent.width;wrapMode:Text.WordWrap
          text:"Use Change… to edit existing artwork. Change Icon is the only icon editor."
          color:Commons.Color.foreground;opacity:0.85
        }
        Text {visible:root.icons.length===0;text:"No custom icons saved.";color:Commons.Color.foreground}
        Repeater {
          id:iconList
          onItemAdded:root.navigationRevision++
          onItemRemoved:root.navigationRevision++
          model:root.icons
          delegate:Column {
            id:iconRow
            required property var modelData
            readonly property string appId:modelData.desktopId
            width:iconBody.width;spacing:Style.space(5)
            function command(){return "dockrail icons reset "+appId}
            function activate(){root.requestIconChange(modelData)}
            HoverHandler{onHoveredChanged:if(hovered)root.hovered(iconRow)}
            Text {
              text:iconRow.modelData.name;textFormat:Text.PlainText
              width:parent.width;wrapMode:Text.WordWrap;font.bold:true
              color:Commons.Color.foreground
            }
            Text {
              text:String(iconRow.modelData.source||"");textFormat:Text.PlainText
              width:parent.width;wrapMode:Text.WrapAnywhere;color:Commons.Color.foreground
              opacity:0.8;font.pixelSize:Style.font.caption
            }
            Row {
              spacing:Style.space(8)
              Ui.Button {text:"Change…";enabled:!root.busy;onClicked:iconRow.activate()}
              Ui.Button {
                text:"×";tooltipText:"Remove custom icon"
                Accessible.name:"Remove custom icon for "+iconRow.modelData.name
                enabled:!root.busy
                onClicked:root.resetIcon(iconRow.modelData)
              }
            }
          }
        }
      }
    }
    Ui.BorderSurface {
      width:stack.width;height:chromeBody.implicitHeight+Style.space(24)
      color:Qt.tint(Commons.Color.background,Util.alpha(Commons.Color.foreground,0.035))
      borderSpec:Border.surfaceSpec("popups","border",Util.alpha(Commons.Color.foreground,0.15),1)
      radius:Style.cornerRadius
      Column {
        id:chromeBody;x:Style.space(12);y:Style.space(12)
        width:parent.width-Style.space(24);spacing:Style.space(10)
        Row {
          width:parent.width;spacing:Style.space(8)
          DockLucideIcon {iconName:"globe";iconSize:16;width:16;height:16;tint:Commons.Color.foreground}
          Text {text:"Chrome";font.bold:true;color:Commons.Color.foreground}
          Text {
            text:root.chromeReady?"Ready":"Not ready"
            color:Commons.Color.foreground;opacity:0.9
          }
        }
        Text {
          visible:!root.chromeReady;width:parent.width;wrapMode:Text.WordWrap
          text:"Chrome integration readiness is reported in Features. Settings never starts DevTools or the provider."
          color:Commons.Color.foreground;opacity:0.9;font.pixelSize:Style.font.caption
        }
        DockSettingsRow {
          id:badgeToggle
          width:parent.width;row:root.rowFor("browserProfileBadgesEnabled")
          host:root.host;hasCursor:root.selectedTarget===this&&root.cursorActive
          enabled:root.chromeReady || root.host.settings.browserProfileBadgesEnabled === true
          onHovered:root.hovered(badgeToggle)
          onEdited:root.changed()
        }
        DockSettingsRow {
          id:tabsToggle
          width:parent.width;row:root.rowFor("sidebarBrowserTabsEnabled")
          host:root.host;hasCursor:root.selectedTarget===this&&root.cursorActive
          enabled:root.chromeReady || root.host.settings.sidebarBrowserTabsEnabled === true
          onHovered:root.hovered(tabsToggle)
          onEdited:root.changed()
        }
        Column {
          width:parent.width;spacing:Style.space(4)
          Text {text:root.rowFor("browserActivityMutedServices").ui.label;color:Commons.Color.foreground;font.bold:true}
          Text {
            width:parent.width;wrapMode:Text.WordWrap
            text:root.rowFor("browserActivityMutedServices").ui.help
            color:Commons.Color.foreground;opacity:0.9
          }
          Ui.MultiSelect {
            id:mutedSelect
            width:parent.width;showLabel:false
            options:Apps.muteOptions(root.host.settings.browserActivityMutedServices)
            values:root.host.settings.browserActivityMutedServices || []
            enabled:!root.busy && root.chromeReady
            onChanged:function(values) {
              root.write("browserActivityMutedServices",values)
              mutedSelect.values=Qt.binding(function(){return root.host.settings.browserActivityMutedServices||[]})
            }
          }
        }
      }
    }
    Ui.BorderSurface {
      width:stack.width;height:dockBody.implicitHeight+Style.space(24)
      color:Qt.tint(Commons.Color.background,Util.alpha(Commons.Color.foreground,0.035))
      borderSpec:Border.surfaceSpec("popups","border",Util.alpha(Commons.Color.foreground,0.15),1)
      radius:Style.cornerRadius
      Column {
        id:dockBody;x:Style.space(12);y:Style.space(12);width:parent.width-Style.space(24)
        spacing:Style.space(8)
        Row {
          spacing:Style.space(8)
          DockLucideIcon {iconName:"trash-2";iconSize:16;width:16;height:16;tint:Commons.Color.foreground}
          Text {text:"Dock items";font.bold:true;color:Commons.Color.foreground}
        }
        DockSettingsRow {
          id:trashToggle;width:parent.width
          host:root.host;row:root.rowFor("showTrash")
          hasCursor:root.cursorActive&&root.selectedTarget===this
          onHovered:root.hovered(trashToggle)
          onEdited:root.changed()
        }
      }
    }
    Ui.BorderSurface {
      width:stack.width;height:advancedBody.implicitHeight+Style.space(24)
      color:Qt.tint(Commons.Color.background,Util.alpha(Commons.Color.foreground,0.035))
      borderSpec:Border.surfaceSpec("popups","border",Util.alpha(Commons.Color.foreground,0.15),1)
      radius:Style.cornerRadius
      Column {
        id:advancedBody;x:Style.space(12);y:Style.space(12);width:parent.width-Style.space(24)
        spacing:Style.space(8)
        Row {
          spacing:Style.space(8)
          DockLucideIcon {iconName:"terminal";iconSize:16;width:16;height:16;tint:Commons.Color.foreground}
          Text {text:"Advanced";font.bold:true;color:Commons.Color.foreground}
        }
        Text {
          text:root.rowFor("controlCommand").ui.label;font.bold:true;color:Commons.Color.foreground
        }
        Text {
          text:root.rowFor("controlCommand").ui.help
            + " Settings never executes this command."
          width:parent.width;wrapMode:Text.WordWrap;color:Commons.Color.foreground;opacity:0.9
        }
        Ui.TextField {
          id:commandField;width:parent.width
          text:root.commandEditing ? root.commandDraft : String(root.host.settings.controlCommand||"")
          enabled:!root.busy
          Accessible.name:"App launcher command"
          onActiveFocusChanged:if(activeFocus){root.beginCommand();root.hovered(commandField)}
          onTextEdited:root.commandDraft=text
          onAccepted:root.saveCommand()
        }
        Text {
          visible:root.commandConflict || root.commandFeedback!==""
          text:root.commandFeedback || "Changed elsewhere · Reload or keep editing"
          width:parent.width;wrapMode:Text.WordWrap;color:Commons.Color.foreground
        }
        Row {
          spacing:Style.space(8)
          Ui.Button {
            id:commandSave;text:"Save"
            enabled:!root.busy&&!root.commandConflict&&root.commandDraft.trim()!==""
              &&root.commandDraft!==root.host.settings.controlCommand
            onClicked:root.saveCommand()
          }
          Ui.Button {
            text:"Reload";visible:root.commandConflict
            onClicked:root.reloadCommand()
          }
          Ui.Button {
            text:"Keep editing";visible:root.commandConflict
            onClicked:{
              root.commandExpected=String(root.host.settings.controlCommand||"")
              root.commandConflict=false;root.commandFeedback=""
            }
          }
          Ui.Button {id:commandReset;text:"Reset";enabled:!root.busy;onClicked:root.resetCommand()}
        }
        Text {
          text:"Default: "+String(root.host.defaultSetting("controlCommand"))
          width:parent.width;wrapMode:Text.WordWrap;color:Commons.Color.foreground
          opacity:0.8;font.pixelSize:Style.font.caption
        }
      }
    }
    Text {
      visible:root.feedback!=="";text:root.feedback;width:parent.width
      textFormat:Text.PlainText;wrapMode:Text.WordWrap;color:Commons.Color.foreground
    }
  }
}
