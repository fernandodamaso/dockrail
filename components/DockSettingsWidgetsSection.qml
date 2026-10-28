pragma ComponentBehavior: Bound
import QtQuick
import qs.Ui as Ui
import qs.Commons
import qs.Commons as Commons
import "DockSettingsRegistry.js" as Registry
import "DockSettingsWidgetsModel.js" as Widgets

// Canonical editor for sidebarWidgets. The controller owns mutations and the
// host owns persistence; this view never starts Widget provider leases.
Item {
  id: root
  required property var host
  required property var metadata
  property bool panelActive: false
  property int cursor: 0
  property bool cursorActive: false
  property int navigationRevision: 0
  property bool createOpen: false
  property bool installOpen: false
  property bool createPending: false
  property bool createdInstallPending: false
  property bool preparePending: false
  property bool confirmPending: false
  property bool createSequenceActive: false
  property string confirmedSource: ""
  property string selectedWidgetId: ""
  property bool reordering:false
  property string dragId: ""
  property var dragExpected: null
  property var dragGrip: null
  property string createdPath: ""
  property string createdStatus: ""
  property string actionFeedback: ""
  readonly property var controller: host.sidebarController
  readonly property var broker: host.settingsActions
  readonly property bool busy: host.settingsWriteState === "saving"
    || host.settingsReloadPending === true || host.settingsLoaded === false
    || host.settingsLoadState === "invalid" || broker.inFlight
  readonly property var widgetRows: Widgets.rows(host.sidebarWidgetRegistry,
    host.settings.sidebarWidgets || [], host.settingsDeveloperBuild === true)
  readonly property var readiness: host.featureReadinessBridge.lastGoodFeatures
  readonly property bool herdrLimited: Widgets.limited(readiness)
  readonly property bool featuresAvailable: !!host.settingsPanel
    && typeof host.settingsPanel.sectionImplemented === "function"
    && host.settingsPanel.sectionImplemented("features")
  readonly property var targets: {
    navigationRevision
    var values=[]
    for(var i=0;i<widgetList.count;i++) {
      var item=widgetList.itemAt(i)
      if(item && item.visible) values.push(item)
    }
    var actions=[createToggle,nameField,idField,createButton,openFolder,installToggle,
      sourceField,reviewButton,confirmButton]
    actions.forEach(function(item) {if(item && item.visible) values.push(item)})
    return values
  }
  readonly property var selectedTarget: {
    var selected=targets.filter(function(item){return item.widgetId===selectedWidgetId})[0]
    return selected || (targets.length ? targets[Math.max(0,Math.min(cursor,targets.length-1))] : null)
  }
  Component.onCompleted: navigationRevision++
  onWidgetRowsChanged: {
    if(dragId && JSON.stringify(dragExpected)!==JSON.stringify(host.settings.sidebarWidgets))
      cancelDrag("Widgets changed while dragging. Review the list and try again.")
    Qt.callLater(function(){root.syncCursor()})
  }
  readonly property bool editorFocused: nameField.activeFocus || idField.activeFocus
    || sourceField.activeFocus
  readonly property bool popupOpen: false
  signal changed()
  signal focusSettings()
  signal focusSections()
  signal reveal(var item)
  signal openFeatures()
  implicitHeight: stack.implicitHeight
  width: parent ? parent.width : 470

  function showResult(result) {
    var reply=Registry.writeOutcome(result)
    var error=reply.reply && reply.reply.error
    actionFeedback=reply.accepted ? "" : error ? error.code+": "+error.message : "Change rejected"
    if(reply.accepted) changed()
    return reply.accepted
  }
  function toggle(id,enabled) {
    if(busy) return false
    return showResult(controller.setWidgetEnabled(id,enabled))
  }
  function move(id,delta,expected) {
    if(busy) return false
    if(expected && JSON.stringify(expected)!==JSON.stringify(host.settings.sidebarWidgets)) {
      actionFeedback="Widgets changed while dragging. Review the list and try again."
      return false
    }
    var slot=Widgets.moveSlot(host.settings.sidebarWidgets,id,delta)
    if(slot<0) return false
    selectedWidgetId=id
    reordering=true
    var accepted=showResult(controller.reorderWidget(id,slot))
    // Repeater rebuilds can put another row under a stationary pointer. Keep
    // keyboard selection on the moved ID until those enter events settle.
    Qt.callLater(function(){root.selectedWidgetId=id;root.syncCursor();root.reordering=false})
    return accepted
  }
  function focusTarget(index) {
    cursor=Math.max(0,Math.min(targets.length-1,index))
    selectedWidgetId=targets[cursor] && targets[cursor].widgetId || ""
    cursorActive=true
    if(selectedTarget) reveal(selectedTarget)
  }
  function syncCursor() {
    for(var i=0;i<targets.length;i++)
      if(targets[i].widgetId===selectedWidgetId) {cursor=i;return}
  }
  function moveCursor(delta){focusTarget(Math.max(0,targets.indexOf(selectedTarget))+delta)}
  function adjust(delta) {
    if(selectedTarget && selectedTarget.widgetId) toggle(selectedTarget.widgetId,delta>0)
  }
  function activate() {
    if(!selectedTarget || !selectedTarget.enabled) return
    if(selectedTarget.widgetId) {
      if(selectedTarget.canToggle) toggle(selectedTarget.widgetId,!selectedTarget.isEnabled)
    } else if(typeof selectedTarget.clicked === "function") selectedTarget.clicked()
    else selectedTarget.forceActiveFocus()
  }
  function reorderSelected(delta) {
    // Keyboard reorder is a synchronous read-modify-write: no CLI change can
    // land mid-call, so no drag-window snapshot is needed here. The pointer
    // path passes the snapshot taken when the drag started.
    if(!dragId && selectedTarget && selectedTarget.isEnabled)
      move(selectedTarget.widgetId,delta)
  }
  function cancelDrag(message) {
    if(dragGrip) dragGrip.y=0
    dragId="";dragExpected=null;dragGrip=null
    if(message) actionFeedback=message
  }
  function dismissEditor() {
    if(dragId) {cancelDrag();return true}
    if(createOpen || installOpen) {cancelPending();return true}
    return false
  }
  function copyCommand() {
    return Registry.cliCommand("sidebarWidgets",host.settings.sidebarWidgets || [])
  }
  function cancelPending() {
    // In-flight broker operations remain host-owned; closing the panel cannot
    // cancel a Widget filesystem transaction or a host writer.
    cancelDrag()
    cancelCreate()
    cancelInstall()
  }
  function cancelCreate() {
    createSequenceActive=false
    createOpen=false
    if(createPending) createdStatus="Creation is finishing; it will not be installed."
    if(createdInstallPending && !confirmPending) {
      createdInstallPending=false
      cancelInstall()
    }
  }
  function cancelInstall() {
    installOpen=false
    preparePending=false
    if(!confirmPending) {createdInstallPending=false;createSequenceActive=false}
    broker.cancelInstall()
  }
  function hovered(item) {
    if(reordering) return
    var at=targets.indexOf(item)
    if(at>=0){focusTarget(at);focusSettings()}
  }
  function startCreate() {
    if(busy || createPending || createdInstallPending) return
    broker.cancelInstall()
    installOpen=false
    createSequenceActive=true
    createdPath=""
    createdStatus=""
    var result=broker.createWidget(idField.text.trim(),nameField.text.trim())
    if(result.accepted) {
      createPending=true
      createdStatus="Creating Widget…"
      actionFeedback=""
    } else {createSequenceActive=false;actionFeedback=result.error.message}
  }
  function startPrepare() {
    if(busy) return
    createSequenceActive=false
    createdInstallPending=false
    var result=broker.prepareInstall(sourceField.text.trim())
    if(result.accepted) {preparePending=true;actionFeedback=""}
    else actionFeedback=result.error.message
  }
  function commitInstall() {
    var confirmation=broker.installConfirmation
    if(busy || !confirmation || !confirmation.canInstall) return
    if(sourceField.text.trim()!==confirmation.source) {
      actionFeedback="The source changed. Review it again before installing."
      return
    }
    if((host.settings.sidebarWidgets||[]).indexOf(confirmation.id)>=0) {
      actionFeedback="This Widget ID is already on the sidebar. Turn it off before installing so it stays Off."
      return
    }
    var result=broker.confirmInstall(confirmation.source,true)
    if(result.accepted){confirmedSource=confirmation.source;confirmPending=true;actionFeedback=""}
    else actionFeedback=result.error.message
  }
  Connections {
    target:root.broker
    function onStatusChanged() {
      var service=root.broker
      if(service.status==="error") {
        if(root.createPending || root.createdInstallPending || root.preparePending || root.confirmPending) {
          root.actionFeedback=service.errorCode+": "+service.errorText
          root.createdStatus=""
          root.createPending=false
          root.createdInstallPending=false
          root.preparePending=false
          root.confirmPending=false
          root.createSequenceActive=false
        }
      } else if(service.status==="awaiting-confirmation" && root.preparePending) {
        root.preparePending=false
      } else if(service.status==="success" && root.createPending) {
        var created=service.result && service.result.data && service.result.data.created
        root.createPending=false
        if(!created || typeof created.sourcePath!=="string" || created.sourcePath.charAt(0)!=="/") {
          root.actionFeedback="E_PROTOCOL: Widget creation did not return a folder."
          root.createSequenceActive=false
          root.createdStatus=""
          return
        }
        root.createdPath=created.sourcePath
        root.createdStatus="Created " + created.id + " from " + created.sourcePath
        if(root.createSequenceActive && root.panelActive) {
          root.createdStatus+=". Review installation below."
          root.createdInstallPending=true
          root.installOpen=true
          sourceField.text=root.createdPath
          Qt.callLater(function() {
            if(!root.createSequenceActive || !root.panelActive) return
            var next=root.broker.prepareInstall(root.createdPath)
            if(next.accepted) root.preparePending=true
            else {root.actionFeedback=next.error.message;root.createdInstallPending=false}
          })
        }
      } else if(service.status==="success" && root.confirmPending) {
        root.confirmPending=false
        root.createdInstallPending=false
        root.createSequenceActive=false
        root.installOpen=false
        root.actionFeedback="Widget installed and left Off."
        if(root.confirmedSource===root.createdPath) {
          root.createOpen=false
          root.createdStatus="Widget installed and left Off. You can open its folder or turn it on."
        }
      }
    }
  }

  Column {
    id: stack
    width:parent.width
    spacing:Style.space(14)
    Text {text:"Sidebar & Widgets";font.family:Style.font.family;font.pixelSize:Style.font.title;font.bold:true;color:Commons.Color.foreground}
    Ui.BorderSurface {
      width:stack.width
      height:cardBody.implicitHeight+Style.space(24)
      color:Qt.tint(Commons.Color.background,Util.alpha(Commons.Color.foreground,0.035))
      borderSpec:Border.surfaceSpec("popups","border",Util.alpha(Commons.Color.foreground,0.15),1)
      radius:Style.cornerRadius
      Column {
        id:cardBody
        x:Style.space(12);y:Style.space(12)
        width:parent.width-Style.space(24)
        spacing:Style.space(8)
        Text {text:"Widgets";font.bold:true;font.family:Style.font.family;font.pixelSize:Style.font.body;color:Commons.Color.foreground}
        Text {
          text:"Drag the grip or press Alt+↑/↓ to reorder."
          color:Commons.Color.foreground;opacity:0.8;font.family:Style.font.family;font.pixelSize:Style.font.caption
        }
        Text {
          visible:root.widgetRows.filter(function(row){return row.enabled}).length===0
          text:"No widgets on the sidebar yet."
          color:Commons.Color.foreground;opacity:0.8;font.family:Style.font.family;font.pixelSize:Style.font.caption
        }
        Repeater {
          id:widgetList
          onItemAdded:root.navigationRevision++
          onItemRemoved:root.navigationRevision++
          model:root.widgetRows
          delegate:Column {
            id:entry
            required property var modelData
            required property int index
            readonly property string widgetId:modelData.id
            readonly property bool isEnabled:modelData.enabled
            // Disabling is always allowed so a stuck unknown ID can be removed;
            // enabling stays gated on registration and availability.
            readonly property bool canToggle:isEnabled || (modelData.registered && modelData.available)
            property bool popupOpen:false
            property bool textFocused:false
            Accessible.role: Accessible.Grouping
            Accessible.name: entry.modelData.label + (entry.isEnabled
              ? ", position " + entry.modelData.position + ". Alt Up or Alt Down to reorder."
              : ", off")
            width:cardBody.width
            spacing:Style.space(5)
            function command(){return root.copyCommand()}
            function activate(){if(canToggle) root.toggle(widgetId,!isEnabled)}
            function adjust(delta){activate()}
            function reorderBy(delta){if(isEnabled)root.move(widgetId,delta)}
            HoverHandler {onHoveredChanged:if(hovered)root.hovered(entry)}
            Text {
              visible:entry.modelData.group==="off"
                && (entry.index===0||root.widgetRows[entry.index-1].group!=="off")
              text:"Off"
              color:Commons.Color.foreground;opacity:0.7;font.family:Style.font.family;font.pixelSize:Style.font.body;font.bold:true
            }
            Row {
              width:parent.width
              spacing:Style.space(8)
              Item {
                id:grip
                width:Style.space(24)
                height:Style.space(34)
                Text {anchors.centerIn:parent;text:entry.isEnabled?"↕":"–";opacity:entry.isEnabled?1:0.4;color:Commons.Color.foreground}
                MouseArea {
                  objectName: "widget-drag-" + entry.widgetId
                  anchors.fill:parent
                  enabled:entry.isEnabled&&!root.busy
                  cursorShape:enabled?Qt.SizeVerCursor:Qt.ArrowCursor
                  drag.target:grip
                  drag.axis:Drag.YAxis
                  onPressed:{
                    root.dragId=entry.widgetId
                    root.dragExpected=(root.host.settings.sidebarWidgets||[]).slice()
                    root.dragGrip=grip
                    root.hovered(entry)
                  }
                  onReleased: {
                    var active=root.dragId===entry.widgetId
                    var delta=Math.round(grip.y/Math.max(1,entry.height))
                    var expected=root.dragExpected
                    root.cancelDrag()
                    if(active && delta)root.move(entry.widgetId,delta,expected)
                  }
                  onCanceled:root.cancelDrag()
                }
              }
              Column {
                width:parent.width-grip.width-switchControl.width-parent.spacing*2
                spacing:Style.space(3)
                Text {
                  text:entry.modelData.label
                  textFormat:Text.PlainText
                  font.family:Style.font.family;font.pixelSize:Style.font.body
                  font.bold:true;color:root.selectedTarget===entry&&root.cursorActive?Commons.Color.accent:Commons.Color.foreground
                }
                Text {
                  width:parent.width
                  text:entry.modelData.description || entry.widgetId
                  textFormat:Text.PlainText
                  wrapMode:Text.WordWrap
                  color:Commons.Color.foreground;opacity:0.9
                  font.family:Style.font.family;font.pixelSize:Style.font.caption
                }
                Text {
                  visible:entry.modelData.unavailable||entry.widgetId==="herdr.agents"&&root.herdrLimited
                  text:entry.modelData.unavailable?"Unavailable":"Limited · Herdr 0.9.1+ required for focus"
                  color:Commons.Color.foreground;opacity:0.8
                  font.family:Style.font.family;font.pixelSize:Style.font.caption
                }
                Ui.Button {
                  visible:entry.widgetId==="herdr.agents"&&root.herdrLimited
                    && root.featuresAvailable
                  text:"Herdr setup in Features…"
                  onClicked:root.openFeatures()
                }
              }
              Ui.ToggleSwitch {
                id:switchControl
                anchors.verticalCenter:parent.verticalCenter
                checked:entry.isEnabled
                interactive:false
                busy:root.busy
                hasCursor:root.cursorActive && root.selectedTarget === entry
                foreground:Commons.Color.foreground
                accent:Commons.Color.accent
                opacity:entry.canToggle?1:0.45
                Accessible.name:(entry.isEnabled?"Turn off ":"Turn on ")+entry.modelData.label
                MouseArea {
                  anchors.fill:parent
                  enabled:entry.canToggle&&!root.busy
                  cursorShape:enabled?Qt.PointingHandCursor:Qt.ArrowCursor
                  onClicked:entry.activate()
                }
              }
            }
          }
        }
      }
    }
    Ui.BorderSurface {
      width:stack.width
      height:actionsBody.implicitHeight+Style.space(24)
      color:Qt.tint(Commons.Color.background,Util.alpha(Commons.Color.foreground,0.035))
      borderSpec:Border.surfaceSpec("popups","border",Util.alpha(Commons.Color.foreground,0.15),1)
      radius:Style.cornerRadius
      Column {
        id:actionsBody
        x:Style.space(12);y:Style.space(12)
        width:parent.width-Style.space(24)
        spacing:Style.space(8)
        Ui.Button {
          id:createToggle
          text:root.createOpen?"Cancel new widget":"Add new widget"
          width:parent.width
          focusable:true
          hasCursor:root.cursorActive && root.selectedTarget===this
          onHovered: function(value){if(value)root.hovered(createToggle)}
          onActiveFocusChanged:if(activeFocus)root.hovered(createToggle)
          onClicked:if(root.createOpen)root.cancelCreate();else root.createOpen=true
        }
        Column {
          visible:root.createOpen
          width:parent.width
          spacing:Style.space(7)
          Text {text:"Widget name";color:Commons.Color.foreground;font.family:Style.font.family}
          Ui.TextField {
            id:nameField
            Accessible.name:"Widget name"
            width:parent.width
            text:"My widget"
            enabled:!root.busy
            onActiveFocusChanged:if(activeFocus)root.hovered(nameField)
            onAccepted:idField.forceActiveFocus()
            Keys.onEscapePressed:{root.cancelPending();root.focusSections()}
          }
          Text {text:"ID";color:Commons.Color.foreground;font.family:Style.font.family}
          Ui.TextField {
            id:idField
            Accessible.name:"Widget ID"
            width:parent.width
            text:"io.local.my-widget"
            enabled:!root.busy
            onActiveFocusChanged:if(activeFocus)root.hovered(idField)
            onAccepted:root.startCreate()
            Keys.onEscapePressed:{root.cancelPending();root.focusSections()}
          }
          Text {
            width:parent.width
            text:"Folder: ~/Projects/dockrail-widgets/"+idField.text.trim()
            textFormat:Text.PlainText
            wrapMode:Text.WrapAnywhere;color:Commons.Color.foreground;opacity:0.9;font.family:Style.font.family;font.pixelSize:Style.font.caption
          }
          Ui.Button {
            id:createButton
            text:"Create"
            enabled:!root.busy&&!root.createPending&&!root.createdInstallPending
              &&nameField.text.trim()!==""&&idField.text.trim()!==""
            focusable:true
            hasCursor:root.cursorActive && root.selectedTarget===this
            onHovered:function(value){if(value)root.hovered(createButton)}
            onActiveFocusChanged:if(activeFocus)root.hovered(createButton)
            onClicked:root.startCreate()
          }
        }
        Text {
          visible:root.createdStatus!==""
          text:root.createdStatus
          textFormat:Text.PlainText
          width:parent.width;wrapMode:Text.WordWrap;color:Commons.Color.foreground;font.family:Style.font.family;font.pixelSize:Style.font.caption
        }
        Ui.Button {
          id:openFolder
          visible:root.createdPath!==""&&!root.createPending
          text:"Open folder"
          enabled:!root.busy
          focusable:true
          hasCursor:root.cursorActive && root.selectedTarget===this
          onHovered:function(value){if(value)root.hovered(openFolder)}
          onActiveFocusChanged:if(activeFocus)root.hovered(openFolder)
          onClicked:Qt.openUrlExternally("file://"+root.createdPath)
        }
        Ui.Button {
          id:installToggle
          text:root.installOpen?"Cancel install":"Install from folder or git…"
          width:parent.width
          focusable:true
          hasCursor:root.cursorActive && root.selectedTarget===this
          onHovered:function(value){if(value)root.hovered(installToggle)}
          onActiveFocusChanged:if(activeFocus)root.hovered(installToggle)
          onClicked:if(root.installOpen)root.cancelInstall();else {root.cancelCreate();root.installOpen=true}
        }
        Column {
          visible:root.installOpen
          width:parent.width
          spacing:Style.space(8)
          Text {
            text:"Enter an absolute folder path or git URL. Packages contain executable QML."
            width:parent.width;wrapMode:Text.WordWrap
            color:Commons.Color.foreground;font.family:Style.font.family;font.pixelSize:Style.font.caption
          }
          Ui.TextField {
            id:sourceField
            objectName: "widget-source"
            Accessible.name:"Widget source folder or git URL"
            width:parent.width
            placeholderText:"Absolute folder path or repository URL"
            enabled:!root.busy
            onActiveFocusChanged:if(activeFocus)root.hovered(sourceField)
            onAccepted:root.startPrepare()
            onTextEdited:if(root.broker.installConfirmation && text.trim()!==root.broker.installConfirmation.source) {
              root.broker.cancelInstall()
              root.createSequenceActive=false
              root.createdInstallPending=false
              root.actionFeedback="Source changed. Review it before installing."
            }
            Keys.onEscapePressed:{root.cancelPending();root.focusSections()}
          }
          Ui.Button {
            id:reviewButton
            text:"Review install"
            enabled:!root.busy&&sourceField.text.trim()!==""
            focusable:true
            hasCursor:root.cursorActive && root.selectedTarget===this
            onHovered:function(value){if(value)root.hovered(reviewButton)}
            onActiveFocusChanged:if(activeFocus)root.hovered(reviewButton)
            onClicked:root.startPrepare()
          }
          Column {
            readonly property var confirmation:root.broker.installConfirmation
            visible:!!confirmation
            width:parent.width;spacing:Style.space(6)
            Text {
              width:parent.width
              text:parent.confirmation
                ? "Package: "+parent.confirmation.name+" ("+parent.confirmation.id+")"
                  +"\nSource: "+parent.confirmation.source
                  +"\nReplaces existing: "+(parent.confirmation.replacesExisting?"Yes (blocked)":"No")
                  +"\nInstalling runs code from this source. It will remain Off until enabled."
                  +((root.host.settings.sidebarWidgets||[]).indexOf(parent.confirmation.id)>=0
                    ? "\nTurn this ID off on the sidebar before installing." : "")
                : ""
              textFormat:Text.PlainText
              wrapMode:Text.WrapAnywhere
              color:Commons.Color.foreground;font.family:Style.font.family;font.pixelSize:Style.font.caption
            }
            Ui.Button {
              id:confirmButton
              text:"Confirm install"
              enabled:!root.busy&&!!parent.confirmation&&parent.confirmation.canInstall
                && sourceField.text.trim()===parent.confirmation.source
                && (root.host.settings.sidebarWidgets||[]).indexOf(parent.confirmation.id)<0
              focusable:true
              hasCursor:root.cursorActive && root.selectedTarget===this
              onHovered:function(value){if(value)root.hovered(confirmButton)}
              onActiveFocusChanged:if(activeFocus)root.hovered(confirmButton)
              onClicked:root.commitInstall()
            }
          }
        }
        Text {
          width:parent.width
          visible:root.actionFeedback!==""
          text:root.actionFeedback
          textFormat:Text.PlainText
          wrapMode:Text.WordWrap;color:Commons.Color.foreground;font.family:Style.font.family;font.pixelSize:Style.font.caption
        }
      }
    }
  }
}
