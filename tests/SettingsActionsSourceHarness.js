.pragma library
.import "SettingsSourceHarness.js" as Source

// Only the process endpoint is replaced; execute the shipping broker methods.
function createBroker(parent) {
  var code='import QtQuick\nimport "'+Qt.resolvedUrl('../components/DockSettingsActionModel.js')+'" as Actions\n'+`Item {
    id:root
    property bool inFlight:false
    property string action:""
    property string status:"idle"
    property string errorCode:""
    property string errorText:""
    property var result:null
    property var installConfirmation:null
    property bool installReviewCancelled:false
    property string scriptPath:"/fixture/actions.py"
    property var executor:process
    QtObject {
      id:process
      property var command:[]
      property bool running:false
      property var calls:[]
      onRunningChanged: if(running) calls=calls.concat([command.slice()])
    }
`+Source.methods('../components/DockSettingsActions.qml')+'\n}'
  return Qt.createQmlObject(code,parent,Qt.resolvedUrl('SettingsBrokerFixture.qml'))
}
