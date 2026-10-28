.pragma library
// Execute production writer/controller methods in the QML engine. Only the
// FileView/compositor endpoints are replaced; no source-text assertions.
function read(path) {
  var xhr=new XMLHttpRequest()
  xhr.open("GET",Qt.resolvedUrl(path),false); xhr.send()
  if(!xhr.responseText) throw new Error("Cannot read "+path)
  return xhr.responseText
}
function methods(path) {
  var blocks=read(path).match(/^  function [\s\S]*?^  }/gm)
  if(!blocks) throw new Error("No production methods in "+path)
  return blocks.join("\n")
}
function createHost(parent) {
  var components=Qt.resolvedUrl("../components/")
  var imports='import QtQuick\nimport "'+components+'"\n'
  var models={DockModel:"DockModel",DockWindowModel:"DockWindowModel",TrashModel:"DockTrashModel",ConfigModel:"DockConfigModel",DockIconModel:"DockIconModel",ScreenPresentationModel:"DockScreenPresentationModel",SidebarModel:"DockSidebarModel",SidebarWidgetModel:"DockSidebarWidgetModel",WorkspaceGroupModel:"DockWorkspaceGroupModel"}
  Object.keys(models).forEach(function(alias){imports+='import "'+components+models[alias]+'.js" as '+alias+'\n'})
  imports+='import "'+Qt.resolvedUrl("SettingsRuntimeFixture.js")+'" as FileViewError\n'
  imports+='import "'+Qt.resolvedUrl("SettingsRuntimeFixture.js")+'" as Quickshell\n'
  var code=imports+`Item {
    id:root
    property var settings: ({})
    property string runtimeMode: "plugin"
    property string configPath: "/fixture/dock.json"
    property bool settingsLoaded:true
    property bool settingsPersisted:true
    property bool settingsReloadPending:false
    property bool settingsDefaultsInUse:false
    property string settingsLoadState:"loaded"
    property string settingsLoadError:""
    property string settingsWriteState:"idle"
    property string settingsWriteError:""
    property string settingsLoadedText:""
    property string settingsWriteText:""
    property string settingsWriteBaseText:""
    property int settingsRevision:0
    property int iconReloadRevision:0
    property bool showTrash:false
    property bool showTrashSetting:false
    property var applications:[]
    property var connectedScreens:[]
    property var hyprMonitors:[]
    property var sidebarWidgetRegistry: ({})
    property var modeGestureFeedbackByMonitor: ({})
    property string modeMenuWriteConnector:""
    property var settingsAnchors:[]
    property var settingsAnchor:null
    property string settingsConnector:""
    property var activeIconDialog:null
    property bool iconDialogActive:activeIconDialog!==null && activeIconDialog.dialogActive
    property QtObject featureReadinessBridge: QtObject {
      property var lastGoodFeatures: ({})
      property bool lastGoodHerdrLimited:false
      property bool panelVisible:false
      function focused() {}
    }
    property QtObject settingsActions: QtObject {
      property bool inFlight:false
      property var installConfirmation:null
      property string status:"idle"
      function cancelInstall() { installConfirmation=null }
    }
    property alias settingsPanel:settingsSurface
    property alias control:dockControl
    property alias file:configFile
    property alias sidebarController:sidebarState
    QtObject {id:sidebarState; property var mappedScreens:[]; property bool interactionBusy:false}
    QtObject {
      id:configFile
      property bool fail:false
      property bool defer:false
      property string cachedText:""
      property var writes:[]
      function setText(text) {
        cachedText=text; writes=writes.concat([text])
        if(defer)return
        if(fail)root.settingsSaveFailed(3)
        else root.settingsSaved()
      }
      function reload() {root.settingsFileLoaded(cachedText)}
    }
    DockSettingsPanel {id:settingsSurface; host:root; metadata:dockControl.metadata}
    QtObject {
      id:dockControl
      property var host:root
      property var defaults:`+read("../config/dock.json")+`
      property var metadata:`+read("../config/settings-schema.json")+`
`+methods("../components/DockControl.qml").replace(/root\./g,"dockControl.")+`\n}
`+methods("../DockHost.qml")+`\n}`
  var host=Qt.createQmlObject(code,parent,Qt.resolvedUrl("SettingsProductionHost.qml"))
  host.settingsFileLoaded(JSON.stringify(host.control.defaults))
  return host
}
