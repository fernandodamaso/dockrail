pragma ComponentBehavior: Bound
import QtQuick
import qs.Ui as Ui
import qs.Commons
import qs.Commons as Commons
import "DockSettingsFeaturesModel.js" as Features
import "DockSettingsRegistry.js" as Registry

// Read-only doctor projection + schema shortcuts. Only the host writer persists
// preferences; the typed broker alone may add/remove owned agent launchers.
Item {
  id: root
  required property var host
  required property var metadata
  property bool panelActive: false
  property int cursor: 0
  property bool cursorActive: false
  property bool launcherPending: false
  property string feedback: ""
  readonly property var readiness: host.featureReadinessBridge.lastGoodFeatures
  readonly property var broker: host.settingsActions
  readonly property bool busy: host.settingsWriteState === "saving"
    || host.settingsReloadPending === true || host.settingsLoaded === false
    || host.settingsLoadState === "invalid" || broker.inFlight
  readonly property var targets: {
    var result=[]
    for (var i=0;i<featureCards.count;i++) {
      var card=featureCards.itemAt(i)
      if (card) result.push(card)
    }
    return result
  }
  readonly property var selectedTarget: targets.length ? targets[Math.max(0,Math.min(cursor,targets.length-1))] : null
  readonly property bool editorFocused: false
  readonly property bool popupOpen: false
  signal changed()
  signal focusSettings()
  signal focusSections()
  signal reveal(var item)
  implicitHeight: stack.implicitHeight
  width: parent ? parent.width : 470

  function focusTarget(index) {
    cursor=Math.max(0,Math.min(targets.length-1,index))
    cursorActive=true
    if(selectedTarget) reveal(selectedTarget)
  }
  function focusFeature(id) {
    for(var i=0;i<targets.length;i++)
      if(targets[i].modelData.id===id){focusTarget(i);return true}
    return false
  }
  function moveCursor(delta){focusTarget(cursor+delta)}
  function adjust(delta){
    if(selectedTarget && selectedTarget.modelData.id!=="agent-launchers")
      toggleFeature(selectedTarget.modelData.id)
  }
  function activate(){if(selectedTarget)selectedTarget.activate()}
  function reorderSelected(delta){}
  function dismissEditor(){return false}
  function cancelPending(){} // Never cancel a host-owned launcher transaction on close.
  function copyCommand(){return selectedTarget ? selectedTarget.command() : ""}
  function copyText(value) {
    clipboard.text=value
    clipboard.selectAll()
    clipboard.copy()
    feedback="Command copied."
  }
  function toggleFeature(id) {
    if(busy || !panelActive) return false
    var spec=Features.aggregate(metadata,id)
    var intent=Features.change(host.settings,spec)
    if(!intent) {feedback="Feature shortcut is unavailable.";return false}
    var result=Registry.writeOutcome(host.saveSettingsIntent(intent.patch,intent.expected))
    if(result.accepted){feedback="";changed();return true}
    var error=result.reply && result.reply.error
    feedback=error ? error.code+": "+error.message : "Change rejected."
    return false
  }
  function manageLaunchers(add) {
    if(busy || !panelActive) return false
    var result=broker.manageLaunchers(add)
    if(result.accepted) {
      launcherPending=true
      feedback=add ? "Adding launchers for agents found on this computer…" : "Removing Dockrail-owned launchers…"
      return true
    }
    feedback=result.error ? result.error.code+": "+result.error.message : "Action rejected."
    return false
  }
  Connections {
    target:root.broker
    function onStatusChanged(){
      if(!root.launcherPending)return
      if(root.broker.status==="error") {
        root.launcherPending=false
        root.feedback=root.broker.errorCode+": "+root.broker.errorText
      } else if(root.broker.status==="success") {
        root.launcherPending=false
        var data=root.broker.result && root.broker.result.data && root.broker.result.data.launchers
        root.feedback=data && data.preserved && data.preserved.length
          ? "Finished; modified or foreign launchers were preserved ("+data.preserved.length+")."
          : "Launcher action finished."
        if(root.panelActive)root.host.featureReadinessBridge.refresh()
      }
    }
  }
  TextEdit {id:clipboard;visible:false}
  Column {
    id:stack
    width:parent.width
    spacing:Style.space(12)
    Row {
      width:parent.width
      spacing:Style.space(12)
      Text {
        text:"Features"
        font.family:Style.font.family
        font.pixelSize:Style.font.title
        font.bold:true
        color:Commons.Color.foreground
      }
      Text {
        text:Features.summary(root.readiness)
        textFormat:Text.PlainText
        font.family:Style.font.family
        font.pixelSize:Style.font.caption
        color:Commons.Color.foreground
        opacity:0.85
        wrapMode:Text.WordWrap
        width:parent.width-Style.space(95)
      }
    }
    Text {
      visible:root.host.featureReadinessBridge.lastError!==""
      width:parent.width
      text:root.host.featureReadinessBridge.lastError
      textFormat:Text.PlainText
      wrapMode:Text.WordWrap
      font.family:Style.font.family
      font.pixelSize:Style.font.caption
      color:Commons.Color.foreground
    }
    Text {
      visible:root.feedback!==""
      width:parent.width
      text:root.feedback
      textFormat:Text.PlainText
      wrapMode:Text.WordWrap
      font.family:Style.font.family
      font.pixelSize:Style.font.caption
      color:Commons.Color.foreground
    }
    Repeater {
      id:featureCards
      model:Features.cards
      delegate:Ui.BorderSurface {
        id:card
        required property var modelData
        required property int index
        objectName:"feature-card-"+modelData.id
        readonly property var probe:root.readiness ? root.readiness[modelData.key] : null
        readonly property var feature:Features.aggregate(root.metadata,modelData.id)
        readonly property string state:feature ? Features.shortcutState(root.host.settings,feature) : "unavailable"
        readonly property string status:Features.badge(probe)
        readonly property bool canToggle:!!feature && status!=="Not set up" && status!=="Checking"
        property bool detailsOpen:false
        property bool agentsOpen:false
        width:stack.width
        height:cardBody.implicitHeight+Style.space(24)
        color:Qt.tint(Commons.Color.background,Util.alpha(Commons.Color.foreground,0.035))
        borderSpec:Border.surfaceSpec("popups","border",Util.alpha(Commons.Color.foreground,0.15),1)
        radius:Style.cornerRadius
        Accessible.role:Accessible.Grouping
        Accessible.name:modelData.title+", "+status+(feature ? ", "+state : "")
        function command(){return modelData.setup}
        function activate(){
          if(modelData.id==="agent-launchers") agentsOpen=!agentsOpen
          else if(canToggle)root.toggleFeature(modelData.id)
          else root.copyText(command())
        }
        HoverHandler {
          onHoveredChanged:if(hovered){root.focusTarget(card.index);root.focusSettings()}
        }
        Column {
          id:cardBody
          x:Style.space(12)
          y:Style.space(12)
          width:parent.width-Style.space(24)
          spacing:Style.space(8)
          Row {
            width:parent.width
            spacing:Style.space(8)
            DockLucideIcon {
              width:Style.space(18)
              height:width
              iconSize:width
              iconName:card.modelData.icon
              tint:Commons.Color.foreground
            }
            Column {
              width:parent.width-Style.space(110)-Style.space(18)-parent.spacing*2
              spacing:Style.space(3)
              Text {
                width:parent.width
                text:card.modelData.title
                textFormat:Text.PlainText
                wrapMode:Text.WordWrap
                font.family:Style.font.family
                font.pixelSize:Style.font.body
                font.bold:true
                color:Commons.Color.foreground
              }
              Text {
                width:parent.width
                text:card.modelData.subtitle
                textFormat:Text.PlainText
                wrapMode:Text.WordWrap
                font.family:Style.font.family
                font.pixelSize:Style.font.caption
                color:Commons.Color.foreground
                opacity:0.85
              }
            }
            Text {
              width:Style.space(110)
              horizontalAlignment:Text.AlignRight
              text:card.status
              font.bold:true
              font.family:Style.font.family
              font.pixelSize:Style.font.caption
              color:Commons.Color.foreground
            }
          }
          Row {
            visible:!!card.feature && card.modelData.id!=="agent-launchers" && card.canToggle
            width:parent.width
            spacing:Style.space(8)
            Text {
              width:parent.width-switchControl.width-parent.spacing
              text:card.state==="partly-on" ? "Partly on" : card.state==="on" ? "On" : "Off"
              color:Commons.Color.foreground
              font.family:Style.font.family
              font.pixelSize:Style.font.caption
              anchors.verticalCenter:parent.verticalCenter
            }
            Ui.ToggleSwitch {
              id:switchControl
              objectName:"feature-toggle-"+card.modelData.id
              checked:card.state==="on"
              interactive:false
              busy:root.busy
              foreground:Commons.Color.foreground
              accent:Commons.Color.accent
              Accessible.name:"Turn "+(card.state==="on"?"off ":"on ")+card.modelData.title
              MouseArea {
                anchors.fill:parent
                enabled:root.panelActive&&!root.busy
                cursorShape:enabled?Qt.PointingHandCursor:Qt.ArrowCursor
                onClicked:root.toggleFeature(card.modelData.id)
              }
            }
          }
          Text {
            visible:!!card.probe && card.status!=="Ready" && card.modelData.id!=="agent-launchers"
            width:parent.width
            text:card.probe ? card.probe.nextAction.text : ""
            textFormat:Text.PlainText
            wrapMode:Text.WordWrap
            color:Commons.Color.foreground
            font.family:Style.font.family
            font.pixelSize:Style.font.caption
            opacity:0.9
          }
          Row {
            visible:card.modelData.id==="chrome"
            spacing:Style.space(8)
            Text {
              text:"Security trade-off: local programs can control the debug profile."
              width:cardBody.width-Style.space(83)
              wrapMode:Text.WordWrap
              color:Commons.Color.foreground
              font.family:Style.font.family
              font.pixelSize:Style.font.caption
            }
            Ui.Button {
              text:card.detailsOpen ? "Hide" : "Details"
              onClicked:card.detailsOpen=!card.detailsOpen
            }
          }
          Text {
            visible:card.modelData.id==="chrome" && card.detailsOpen
            text:"While the Chrome debugging port is open, any local program can read and control that Chrome profile. Use a separate --user-data-dir. Omarchy does not enable remote debugging."
            textFormat:Text.PlainText
            width:parent.width
            wrapMode:Text.WordWrap
            color:Commons.Color.foreground
            font.family:Style.font.family
            font.pixelSize:Style.font.caption
          }
          Row {
            visible:card.modelData.id==="coding-agents" && card.status==="Limited"
            spacing:Style.space(8)
            Text {
              text:"Herdr 0.9.1+ is needed to jump to panes."
              width:cardBody.width-Style.space(83)
              wrapMode:Text.WordWrap
              color:Commons.Color.foreground
              font.family:Style.font.family
              font.pixelSize:Style.font.caption
            }
            Ui.Button {
              text:card.detailsOpen ? "Hide" : "Details"
              onClicked:card.detailsOpen=!card.detailsOpen
            }
          }
          Text {
            visible:card.modelData.id==="coding-agents" && card.detailsOpen
            width:parent.width
            text:card.probe ? card.probe.reason : ""
            textFormat:Text.PlainText
            wrapMode:Text.WordWrap
            color:Commons.Color.foreground
            font.family:Style.font.family
            font.pixelSize:Style.font.caption
          }
          Text {
            visible:card.modelData.id!=="agent-launchers" && card.status!=="Ready"
            text:card.modelData.setup
            textFormat:Text.PlainText
            width:parent.width
            wrapMode:Text.WrapAnywhere
            color:Commons.Color.foreground
            font.family:Style.font.family
            font.pixelSize:Style.font.caption
          }
          Ui.Button {
            visible:card.modelData.id!=="agent-launchers" && card.status!=="Ready"
            objectName:"feature-copy-"+card.modelData.id
            text:"Copy setup command"
            onClicked:root.copyText(card.command())
          }
          Text {
            visible:card.modelData.id==="launcher-counts" && card.status!=="Ready"
            text:"Without the CLI, run from the installed plugin folder:"
            textFormat:Text.PlainText
            width:parent.width
            wrapMode:Text.WordWrap
            color:Commons.Color.foreground
            font.family:Style.font.family
            font.pixelSize:Style.font.caption
          }
          Ui.Button {
            visible:card.modelData.id==="launcher-counts" && card.status!=="Ready"
            text:"Copy plugin-folder command"
            onClicked:root.copyText(Features.fallbackCountCommand)
          }
          Ui.Button {
            visible:card.modelData.id==="chrome" && card.status!=="Ready"
            text:"Copy plugin-folder command"
            onClicked:root.copyText("bash ~/.config/omarchy/plugins/io.github.fernandodamaso.dockrail/scripts/install-browser-profile-provider")
          }
          Ui.Button {
            visible:!!card.modelData.home && (card.status==="Ready" || card.status==="Limited")
            text:"Settings › "+card.modelData.homeLabel
            onClicked:root.host.settingsPanel.selectSection(card.modelData.home)
          }
          Ui.Button {
            visible:card.modelData.id==="agent-launchers"
            text:(card.agentsOpen?"Hide agents · ":"Agents · ")+Features.agentSummary(card.probe)
            onClicked:card.agentsOpen=!card.agentsOpen
          }
          Column {
            width:parent.width
            visible:card.modelData.id==="agent-launchers" && card.agentsOpen
            spacing:Style.space(5)
            Repeater {
              model:card.probe && Array.isArray(card.probe.agents) ? card.probe.agents : []
              delegate:Row {
                required property var modelData
                width:cardBody.width
                spacing:Style.space(8)
                Text {
                  width:parent.width-Style.space(92)
                  text:modelData.label+" ("+modelData.command+")"
                  textFormat:Text.PlainText
                  color:Commons.Color.foreground
                  font.family:Style.font.family
                  font.pixelSize:Style.font.caption
                }
                Text {
                  text:modelData.found ? "Found" : "Not installed"
                  color:Commons.Color.foreground
                  font.family:Style.font.family
                  font.pixelSize:Style.font.caption
                }
              }
            }
            Text {
              visible:!card.probe || !Array.isArray(card.probe.agents)
              text:"Agent inventory unavailable. Reopen Features when doctor is ready."
              width:parent.width
              wrapMode:Text.WordWrap
              color:Commons.Color.foreground
            }
            Text {
              text:"Only agents found now receive launchers. Newly installed agents are not added automatically."
              width:parent.width
              wrapMode:Text.WordWrap
              color:Commons.Color.foreground
              font.family:Style.font.family
              font.pixelSize:Style.font.caption
            }
          }
          Row {
            visible:card.modelData.id==="agent-launchers"
            spacing:Style.space(8)
            Ui.Button {
              objectName:"feature-launchers-add"
              text:"Add launchers"
              enabled:root.panelActive&&!root.busy
              onClicked:root.manageLaunchers(true)
            }
            Ui.Button {
              objectName:"feature-launchers-remove"
              text:"Remove launchers"
              enabled:root.panelActive&&!root.busy
              onClicked:root.manageLaunchers(false)
            }
          }
        }
      }
    }
  }
}
