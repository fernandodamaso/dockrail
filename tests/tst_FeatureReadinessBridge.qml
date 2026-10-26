import QtQuick
import QtTest
import "../components" as Dock

TestCase {
  name: "FeatureReadinessBridge"
  width: 500
  height: 200

  QtObject {
    id: fakeExecutor
    property bool running: false
    property var command: []
  }
  Dock.DockFeatureReadinessBridge {
    id: bridge
    executor: fakeExecutor
  }

  readonly property string readyJson: JSON.stringify({
    ok: true, data: { features: {
      herdrAgents: { configuration:"on", installation:"installed", runtime:"ready", nextAction:{kind:"learn-more",text:"OK"} },
      chromeProfilesTabs: { configuration:"off", installation:"installed", runtime:"ready", nextAction:{kind:"enable",text:"Enable"} },
      launcherCounts: { configuration:"on", installation:"installed", runtime:"ready", nextAction:{kind:"learn-more",text:"OK"} },
      agentLaunchers: { configuration:"on", installation:"installed", runtime:"ready", nextAction:{kind:"learn-more",text:"OK"} }
    }}
  })
  function init() {
    bridge.panelVisible = false
    bridge.inFlight = false
    bridge.lastGoodFeatures = null
    fakeExecutor.running = false
  }
  function test_single_flight_and_close_stops_polling() {
    bridge.panelVisible = true
    verify(bridge.inFlight)
    verify(fakeExecutor.running)
    compare(fakeExecutor.command.join(" "), "dockrail doctor --json")
    verify(!bridge.refresh(), "no second doctor while busy")
    var reply = JSON.parse(readyJson)
    reply.data.features.herdrAgents.runtime = "limited"
    fakeExecutor.running = false // simulate Process.onExited before delivering stdout
    verify(bridge.acceptDoctorText(JSON.stringify(reply), 0))
    compare(bridge.lastGoodFeatures.herdrAgents.runtime, "limited")
    verify(bridge.needsPolling)
    verify(bridge.polling)
    bridge.panelVisible = false
    verify(!bridge.needsPolling)
    verify(!bridge.polling)
    verify(!fakeExecutor.running)
  }
  function test_timeout_keeps_last_good_result() {
    bridge.panelVisible = true
    verify(bridge.acceptDoctorText(readyJson, 0))
    var cached = bridge.lastGoodFeatures
    compare(cached.herdrAgents.runtime, "ready")
    verify(!bridge.needsPolling)
    verify(bridge.refresh())
    bridge.timedOut()
    verify(!bridge.inFlight)
    compare(bridge.lastGoodFeatures, cached)
    compare(bridge.lastGoodFeatures.chromeProfilesTabs.installation, "installed")
    verify(!fakeExecutor.running)
  }
  function test_failed_reply_retains_cache() {
    bridge.panelVisible = true
    verify(bridge.acceptDoctorText(readyJson, 0))
    verify(bridge.refresh())
    verify(!bridge.acceptDoctorText("{bad JSON", 0))
    compare(bridge.lastGoodFeatures.herdrAgents.runtime, "ready")
    verify(bridge.lastError !== "")
  }
}
