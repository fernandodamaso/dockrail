pragma ComponentBehavior: Bound
import QtQuick
import qs.Ui as Ui
import qs.Commons
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
  readonly property var targets: {
    navigationRevision
    var values=[]
    for(var i=0;i<widgetList.count;i++) {
      var item=widgetList.itemAt(i)
      if(item && item.visible) values.push(item)
    }
    return values
  }
  readonly property var selectedTarget: targets.length
    ? targets[Math.max(0,Math.min(cursor,targets.length-1))] : null
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
    return showResult(controller.reorderWidget(id,slot))
  }
  function focusTarget(index) {
    cursor=Math.max(0,Math.min(targets.length-1,index))
    cursorActive=true
    if(selectedTarget) reveal(selectedTarget)
  }
  function moveCursor(delta){focusTarget(cursor+delta)}
  function adjust(delta) {
    if(selectedTarget) toggle(selectedTarget.widgetId,!selectedTarget.isEnabled)
  }
  function activate() {
    if(selectedTarget) toggle(selectedTarget.widgetId,!selectedTarget.isEnabled)
  }
  function reorderSelected(delta) {
    // Keyboard reorder is a synchronous read-modify-write: no CLI change can
    // land mid-call, so no drag-window snapshot is needed here. The pointer
    // path passes the snapshot taken when the drag started.
    if(selectedTarget && selectedTarget.isEnabled)
      move(selectedTarget.widgetId,delta)
  }
  function dismissEditor() {
    if(installOpen && broker.installConfirmation) {installOpen=false;return true}
    if(createOpen || installOpen) {createOpen=false;installOpen=false;return true}
    return false
  }
  function copyCommand() {
    return Registry.cliCommand("sidebarWidgets",host.settings.sidebarWidgets || [])
  }
  function cancelPending() {
    // In-flight broker operations remain host-owned; closing the panel cannot
    // cancel a Widget filesystem transaction or a host writer.
    createOpen=false
    installOpen=false
  }
  function hovered(item) {
    var at=targets.indexOf(item)
    if(at>=0){focusTarget(at);focusSettings()}
  }
  function startCreate() {
    if(busy) return
    createdPath=""
    createdStatus=""
    var result=broker.createWidget(idField.text.trim(),nameField.text.trim())
    if(result.accepted) {
      createPending=true
      createdStatus="Creating Widget…"
      actionFeedback=""
    } else actionFeedback=result.error.message
  }
  function startPrepare() {
    if(busy) return
    var result=broker.prepareInstall(sourceField.text.trim())
    if(result.accepted) {preparePending=true;actionFeedback=""}
    else actionFeedback=result.error.message
  }
  function commitInstall() {
    var confirmation=broker.installConfirmation
    if(busy || !confirmation || !confirmation.canInstall) return
    var result=broker.confirmInstall(confirmation.source,true)
    if(result.accepted){confirmPending=true;actionFeedback=""}
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
        }
      } else if(service.status==="awaiting-confirmation" && root.preparePending) {
        root.preparePending=false
      } else if(service.status==="success" && root.createPending && service.result
          && service.result.data && service.result.data.created) {
        var created=service.result.data.created
        root.createPending=false
        root.createdPath=created.sourcePath
        root.createdStatus="Created " + created.id + " from " + created.sourcePath
          + ". Installing the Widget package…"
        root.createdInstallPending=true
        Qt.callLater(function() {
          var next=root.broker.start("install",{source:root.createdPath})
          if(!next.accepted) {
            root.actionFeedback=next.error.message
            root.createdInstallPending=false
          }
        })
      } else if(service.status==="success" && root.createdInstallPending) {
        root.createdInstallPending=false
        root.createOpen=false
        root.createdStatus="Widget installed and left Off. You can open its folder or turn it on."
      } else if(service.status==="success" && root.confirmPending) {
        root.confirmPending=false
        root.installOpen=false
        root.actionFeedback="Widget installed and left Off."
      }
    }
  }

  Column {
    id: stack
    width:parent.width
    spacing:Style.space(14)
    Text {text:"Sidebar & Widgets";font.family:Style.font.family;font.pixelSize:Style.font.title;font.bold:true;color:Color.foreground}
    Ui.BorderSurface {
      width:stack.width
      height:cardBody.implicitHeight+Style.space(24)
      color:Qt.tint(Color.background,Util.alpha(Color.foreground,0.035))
      borderSpec:Border.surfaceSpec("popups","border",Util.alpha(Color.foreground,0.15),1)
      radius:Style.cornerRadius
      Column {
        id:cardBody
        x:Style.space(12);y:Style.space(12)
        width:parent.width-Style.space(24)
        spacing:Style.space(8)
        Text {text:"Widgets";font.bold:true;font.family:Style.font.family;font.pixelSize:Style.font.body;color:Color.foreground}
        Text {
          text:"Drag the grip or press Alt+↑/↓ to reorder."
          color:Color.foreground;opacity:0.8;font.family:Style.font.family;font.pixelSize:Style.font.caption
        }
        Text {
          visible:root.widgetRows.filter(function(row){return row.enabled}).length===0
          text:"No widgets on the sidebar yet."
          color:Color.foreground;opacity:0.8;font.family:Style.font.family;font.pixelSize:Style.font.caption
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
            property var orderExpected:null
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
              color:Color.foreground;opacity:0.7;font.family:Style.font.family;font.pixelSize:Style.font.body;font.bold:true
            }
            Row {
              width:parent.width
              spacing:Style.space(8)
              Item {
                id:grip
                width:Style.space(24)
                height:Style.space(34)
                Text {anchors.centerIn:parent;text:entry.isEnabled?"↕":"–";opacity:entry.isEnabled?1:0.4;color:Color.foreground}
                MouseArea {
                  anchors.fill:parent
                  enabled:entry.isEnabled&&!root.busy
                  cursorShape:enabled?Qt.SizeVerCursor:Qt.ArrowCursor
                  drag.target:grip
                  drag.axis:Drag.YAxis
                  onPressed:{entry.orderExpected=(root.host.settings.sidebarWidgets||[]).slice();root.hovered(entry)}
                  onReleased: {
                    var delta=Math.round(grip.y/Math.max(1,entry.height))
                    grip.y=0
                    if(delta)root.move(entry.widgetId,delta,entry.orderExpected)
                  }
                  onCanceled:grip.y=0
                }
              }
              Column {
                width:parent.width-grip.width-switchControl.width-parent.spacing*2
                spacing:Style.space(3)
                Text {
                  text:entry.modelData.label
                  font.family:Style.font.family;font.pixelSize:Style.font.body
                  font.bold:true;color:root.selectedTarget===entry&&root.cursorActive?Color.accent:Color.foreground
                }
                Text {
                  width:parent.width
                  text:entry.modelData.description || entry.widgetId
                  wrapMode:Text.WordWrap
                  color:Color.foreground;opacity:0.9
                  font.family:Style.font.family;font.pixelSize:Style.font.caption
                }
                Text {
                  visible:entry.modelData.unavailable||entry.widgetId==="herdr.agents"&&root.herdrLimited
                  text:entry.modelData.unavailable?"Unavailable":"Limited · Herdr 0.9.1+ required for focus"
                  color:Color.foreground;opacity:0.8
                  font.family:Style.font.family;font.pixelSize:Style.font.caption
                }
                Ui.Button {
                  // The Features section arrives in SET-06; until then there is
                  // nowhere to navigate, so the button stays hidden.
                  visible:entry.widgetId==="herdr.agents"&&root.herdrLimited
                    && Registry.order.indexOf("features") >= 0
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
                foreground:Color.foreground
                accent:Color.accent
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
      color:Qt.tint(Color.background,Util.alpha(Color.foreground,0.035))
      borderSpec:Border.surfaceSpec("popups","border",Util.alpha(Color.foreground,0.15),1)
      radius:Style.cornerRadius
      Column {
        id:actionsBody
        x:Style.space(12);y:Style.space(12)
        width:parent.width-Style.space(24)
        spacing:Style.space(8)
        Ui.Button {
          text:root.createOpen?"Cancel new widget":"Add new widget"
          width:parent.width
          onClicked:root.createOpen=!root.createOpen
        }
        Column {
          visible:root.createOpen
          width:parent.width
          spacing:Style.space(7)
          Text {text:"Widget name";color:Color.foreground;font.family:Style.font.family}
          Ui.TextField {
            id:nameField
            width:parent.width
            text:"My widget"
            enabled:!root.busy
          }
          Text {text:"ID";color:Color.foreground;font.family:Style.font.family}
          Ui.TextField {
            id:idField
            width:parent.width
            text:"io.local.my-widget"
            enabled:!root.busy
          }
          Text {
            width:parent.width
            text:"Folder: ~/Projects/dockrail-widgets/"+idField.text.trim()
            wrapMode:Text.WrapAnywhere;color:Color.foreground;opacity:0.9;font.family:Style.font.family;font.pixelSize:Style.font.caption
          }
          Ui.Button {
            text:"Create"
            enabled:!root.busy&&nameField.text.trim()!==""&&idField.text.trim()!==""
            onClicked:root.startCreate()
          }
        }
        Text {
          visible:root.createdStatus!==""
          text:root.createdStatus
          width:parent.width;wrapMode:Text.WordWrap;color:Color.foreground;font.family:Style.font.family;font.pixelSize:Style.font.caption
        }
        Ui.Button {
          visible:root.createdPath!==""&&!root.createdInstallPending&&!root.createPending
          text:"Open folder"
          onClicked:Qt.openUrlExternally("file://"+root.createdPath)
        }
        Ui.Button {
          text:root.installOpen?"Cancel install":"Install from folder or git…"
          width:parent.width
          onClicked: {root.installOpen=!root.installOpen;if(!root.installOpen)root.preparePending=false}
        }
        Column {
          visible:root.installOpen
          width:parent.width
          spacing:Style.space(8)
          Text {
            text:"Enter an absolute folder path or git URL. Packages contain executable QML."
            width:parent.width;wrapMode:Text.WordWrap
            color:Color.foreground;font.family:Style.font.family;font.pixelSize:Style.font.caption
          }
          Ui.TextField {
            id:sourceField
            width:parent.width
            placeholderText:"Absolute folder path or repository URL"
            enabled:!root.busy
          }
          Ui.Button {
            text:"Review install"
            enabled:!root.busy&&sourceField.text.trim()!==""
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
                : ""
              wrapMode:Text.WrapAnywhere
              color:Color.foreground;font.family:Style.font.family;font.pixelSize:Style.font.caption
            }
            Ui.Button {
              text:"Confirm install"
              enabled:!root.busy&&!!parent.confirmation&&parent.confirmation.canInstall
                && sourceField.text.trim()===parent.confirmation.source
              onClicked:root.commitInstall()
            }
          }
        }
        Text {
          width:parent.width
          visible:root.actionFeedback!==""
          text:root.actionFeedback
          wrapMode:Text.WordWrap;color:Color.foreground;font.family:Style.font.family;font.pixelSize:Style.font.caption
        }
      }
    }
  }
}
