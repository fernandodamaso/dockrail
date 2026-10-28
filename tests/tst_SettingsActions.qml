import QtQuick
import QtTest
import "../components" as Dock
import "../components/DockSettingsActionModel.js" as Actions

TestCase {
  name: "SettingsActions"
  QtObject {
    id: fakeExecutor
    property bool running: false
    property var command: []
  }
  Dock.DockSettingsActions {
    id: broker
    executor: fakeExecutor
  }
  function init() {
    broker.inFlight = false
    broker.installConfirmation = null
    broker.status = "idle"
    fakeExecutor.running = false
  }
  function test_create_validated_argv_and_no_parallel_call() {
    var rejected = broker.createWidget("bad;id", "Sample")
    verify(!rejected.accepted)
    compare(rejected.error.code, "E_VALIDATION")
    var accepted = broker.createWidget("sample.widget", "Sample Widget")
    verify(accepted.accepted)
    verify(fakeExecutor.running)
    compare(fakeExecutor.command.slice(-5).join("|"),
            "create|--id|sample.widget|--name|Sample Widget")
    compare(broker.manageLaunchers(true).error.code, "E_BUSY")
    verify(broker.finish(JSON.stringify({apiVersion:1,ok:true,data:{created:{id:"sample.widget"},enabled:false}}), 0))
    compare(broker.status, "success")
    verify(!broker.inFlight)
  }
  function test_install_requires_same_confirmed_source() {
    compare(broker.confirmInstall("/tmp/example",true).error.code,"E_CONFIRMATION")
    verify(broker.prepareInstall("/tmp/example").accepted)
    var ready = {apiVersion:1,ok:true,data:{confirmation:{
      manifest:{id:"example.widget",name:"Example"},source:"/tmp/example",id:"example.widget",name:"Example",replacesExisting:false,canInstall:true
    }}}
    verify(broker.finish(JSON.stringify(ready),0))
    compare(broker.status,"awaiting-confirmation")
    compare(broker.confirmInstall("/tmp/other",true).error.code,"E_CONFIRMATION")
    compare(broker.confirmInstall("/tmp/example",false).error.code,"E_CONFIRMATION")
    verify(broker.confirmInstall("/tmp/example",true).accepted)
    compare(fakeExecutor.command.slice(-5,-1).join("|"),"install|--source|/tmp/example|--expected-manifest")
    compare(JSON.parse(fakeExecutor.command.slice(-1)[0]),ready.data.confirmation.manifest)
    verify(broker.finish('{"apiVersion":1,"ok":false,"error":{"code":"E_CONFLICT","message":"Already installed"}}',1) === false)
    compare(broker.errorCode,"E_CONFLICT")
  }
  function test_valid_names_and_sources_reject_real_control_characters() {
    verify(Actions.validName("Browser Runner"))
    verify(Actions.validSource("/tmp/browser-runner"))
    verify(Actions.validSource("https://example.com/repo.git"))
    verify(!Actions.validName("bad\nname"))
    verify(!Actions.validName("bad\rname"))
    verify(!Actions.validName("bad\u0000name"))
    verify(!Actions.validSource("/tmp/bad\npath"))
    verify(!Actions.validSource("/tmp/bad\rpath"))
    verify(!Actions.validSource("/tmp/bad\u0000path"))
  }
  function test_launcher_argv_fixed() {
    verify(broker.manageLaunchers(false).accepted)
    compare(fakeExecutor.command.slice(-1)[0],"launchers-remove")
    verify(broker.finish('{"apiVersion":1,"ok":false,"error":{"code":"E_UNAVAILABLE","message":"INF-4 required"}}',1) === false)
    compare(broker.errorCode,"E_UNAVAILABLE")
  }
}
