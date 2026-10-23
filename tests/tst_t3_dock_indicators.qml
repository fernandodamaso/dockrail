import QtQuick
import QtTest
import "../components"
import "../components/DockHerdrModel.js" as HerdrModel

// Exercises the real Dock.qml indicator functions (guards, per-source gates,
// preview product/hint) against stub bridges, following the existing dock
// indicator test's fixture pattern.
TestCase {
  id: testCase
  name: "T3DockIndicators"
  when: windowShown
  width: 320
  height: 240

  function dockSource() {
    var request = new XMLHttpRequest()
    request.open("GET", Qt.resolvedUrl("../components/Dock.qml"), false)
    request.send()
    if (!request.responseText) throw new Error("QML_XHR_ALLOW_FILE_READ=1 is required")
    return request.responseText
  }

  function extractBlock(sourceText, name) {
    var start = sourceText.indexOf("  function " + name + "(")
    if (start < 0) throw new Error("Dock.qml function not found: " + name)
    var open = sourceText.indexOf("{", start)
    var depth = 0
    for (var i = open; i < sourceText.length; i++) {
      if (sourceText[i] === "{") depth++
      else if (sourceText[i] === "}" && --depth === 0)
        return sourceText.slice(start, i + 1)
    }
    throw new Error("Unclosed Dock.qml function: " + name)
  }

  function facade(herdrOn, t3On, bridge) {
    var names = ["emptyHerdrSummary", "sourceIndicatorsEnabled", "herdrSummaryFor",
      "herdrServerLabel", "herdrServerForPreview", "herdrPreviewProductFor",
      "herdrPreviewFocusHintFor", "herdrPreviewAgentsFor", "herdrPreviewLabelFor",
      "allItemWindowsHerdrAssociated"]
    var source = dockSource()
    var functions = names.map(function(name) { return extractBlock(source, name) })
    var code = 'import QtQuick\nimport "../components/DockHerdrModel.js" as HerdrModel\n'
      + 'QtObject { id: root\n'
      + 'property bool dockHerdrIndicators: ' + (herdrOn ? "true" : "false") + '\n'
      + 'property bool dockT3Indicators: ' + (t3On ? "true" : "false") + '\n'
      + 'property var herdrWindowAgents\n'
      + functions.join("\n") + '\n}'
    var item = Qt.createQmlObject(code, testCase, Qt.resolvedUrl("DockFacade.qml"))
    if (!item) throw new Error("Failed to instantiate Dock.qml facade")
    item.herdrWindowAgents = bridge
    return item
  }

  Component {
    id: toplevelFactory
    QtObject { property string key: "" }
  }

  Component {
    id: bridgeFactory
    QtObject {
      property var snapshot: ({ servers: [] })
      property var herdrAssociations: ({ byWindowKey: ({}) })
      property int indicatorRevision: 0
      property bool snapshotReady: true
      property var summaryArgs: []
      function windowKeyFor(toplevel) { return toplevel ? String(toplevel.key || "") : "" }
      function summaryForToplevels(toplevels) {
        var owner = this
        owner.summaryArgs = owner.summaryArgs.concat([toplevels.slice()])
        return { count: toplevels.length, indicatorStatus: "", counters: [], rows: [],
          herdrWindowCount: toplevels.length, blockedTransitionRevision: 0, blockedAddresses: [] }
      }
      function liveServerById(serverId) {
        var servers = snapshot && Array.isArray(snapshot.servers) ? snapshot.servers : []
        for (var i = 0; i < servers.length; i++)
          if (servers[i] && servers[i].id === serverId) return servers[i]
        return null
      }
    }
  }

  function servers() {
    return [
      { id: "t3:env-1", source: "t3", product: "T3 Code", label: "T3 Code" },
      { id: "local-h", label: "Local Herdr" }
    ]
  }

  function scene() {
    var winT3 = createTemporaryObject(toplevelFactory, testCase, { key: "win:t3" })
    var winHerdr = createTemporaryObject(toplevelFactory, testCase, { key: "win:h" })
    var bridge = createTemporaryObject(bridgeFactory, testCase)
    bridge.snapshot = { servers: servers() }
    bridge.herdrAssociations = { byWindowKey: { "win:t3": "t3:env-1", "win:h": "local-h" } }
    return { winT3: winT3, winHerdr: winHerdr, bridge: bridge }
  }

  function test_t3BadgeGatedByT3Setting() {
    var value = scene()
    var item = { toplevels: [value.winT3, value.winHerdr] }
    var off = facade(true, false, value.bridge)
    off.herdrSummaryFor(item)
    compare(value.bridge.summaryArgs.length, 1)
    compare(value.bridge.summaryArgs[0].length, 1)
    compare(value.bridge.summaryArgs[0][0], value.winHerdr)
    value.bridge.summaryArgs = []
    var bothOn = facade(true, true, value.bridge)
    bothOn.herdrSummaryFor(item)
    compare(value.bridge.summaryArgs.length, 1)
    compare(value.bridge.summaryArgs[0].length, 2)
  }

  function test_herdrBadgeUnaffectedByT3Setting() {
    var value = scene()
    var item = { toplevels: [value.winHerdr] }
    var without = facade(true, false, value.bridge)
    without.herdrSummaryFor(item)
    var bothWith = facade(true, true, value.bridge)
    value.bridge.summaryArgs = []
    bothWith.herdrSummaryFor(item)
    compare(value.bridge.summaryArgs.length, 1)
    compare(value.bridge.summaryArgs[0].length, 1)
    var herdrOff = facade(false, true, value.bridge)
    value.bridge.summaryArgs = []
    var summary = herdrOff.herdrSummaryFor(item)
    compare(value.bridge.summaryArgs.length, 1)
    compare(value.bridge.summaryArgs[0].length, 0)
    compare(summary.count, 0)
  }

  function test_sourceIndicatorsEnabledMapping() {
    var value = scene()
    var both = facade(true, true, value.bridge)
    verify(both.sourceIndicatorsEnabled(value.winT3))
    verify(both.sourceIndicatorsEnabled(value.winHerdr))
    var t3Only = facade(false, true, value.bridge)
    verify(t3Only.sourceIndicatorsEnabled(value.winT3))
    verify(!t3Only.sourceIndicatorsEnabled(value.winHerdr))
    var herdrOnly = facade(true, false, value.bridge)
    verify(!herdrOnly.sourceIndicatorsEnabled(value.winT3))
    verify(herdrOnly.sourceIndicatorsEnabled(value.winHerdr))
    var unknown = createTemporaryObject(toplevelFactory, testCase, { key: "win:?" })
    verify(herdrOnly.sourceIndicatorsEnabled(unknown))
  }

  function test_previewProductAndHint() {
    var value = scene()
    var dock = facade(true, true, value.bridge)
    compare(dock.herdrPreviewProductFor([{ serverId: "t3:env-1" }]), "T3 Code")
    compare(dock.herdrPreviewFocusHintFor([{ serverId: "t3:env-1" }]),
      "Click a row to open T3 Code.")
    compare(dock.herdrPreviewProductFor([{ serverId: "local-h" }]), "Herdr")
    compare(dock.herdrPreviewFocusHintFor([{ serverId: "local-h" }]),
      "Click a row to focus its pane.")
    compare(dock.herdrPreviewProductFor([]), "Herdr")
    compare(dock.herdrServerLabel("t3:env-1"), "T3 Code")
    compare(dock.herdrServerLabel("local-h"), "Local Herdr")
    compare(dock.herdrPreviewLabelFor([
      { serverLabel: "T3 Code" }, { serverLabel: "Herdr" }, { serverLabel: "Work" }
    ]), "Work")
  }
}
