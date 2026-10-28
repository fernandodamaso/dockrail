import QtQuick
import QtTest
import "../components"
import "SidebarSplitSourceHarness.js" as SplitHarness

// Pairing guidance surfaces in the real T3 fallback view and the real
// Widget-area presentation filter: matched auth-error servers stay out of
// the fallback card (their hint lives in the tree state row), while
// unmatched ones present the card with the hint in the session detail.
TestCase {
  id: testCase
  name: "T3PairingHints"
  when: windowShown
  width: 420
  height: 320

  Component {
    id: viewFactory
    DockHerdrAgentsView {}
  }

  function t3Server(errorCode) {
    return {
      id: "t3:env-1", source: "t3", product: "T3 Code", transport: "local",
      host: "local", sessions: [], session: "", label: "T3 Code",
      capabilities: { focusAgent: true }, connectionGeneration: 1,
      health: "unavailable", connected: false, clients: [],
      errorCode: errorCode
    }
  }

  function herdrServer() {
    return {
      id: "local-h", transport: "local", host: "local", session: "default",
      label: "Local Herdr", capabilities: { focusAgent: true },
      connectionGeneration: 1, health: "unavailable", connected: false, clients: []
    }
  }

  function snapshotWith(server) {
    return {
      schemaVersion: 1, providerEpoch: "mux", revision: 1,
      capabilities: { focusAgent: true }, servers: [server], agents: [],
      attention: [], liveCounts: null,
      completeness: { state: "unknown" },
      windowProcesses: { revision: 0, identities: [] }
    }
  }

  function viewFor(server, matched) {
    var view = createTemporaryObject(viewFactory, testCase, { sourceFilter: "t3" })
    verify(view !== null)
    var associations = matched
      ? { byWindowKey: { "win:t3": "t3:env-1" }, unmatchedServerIds: [] }
      : { byWindowKey: ({}), unmatchedServerIds: ["t3:env-1"] }
    view.widgetContext = { data: snapshotWith(server), herdrAssociations: associations }
    return view
  }

  function hintFor(errorCode) {
    return errorCode === "pairing_required"
      ? "Pair T3 Code: run `dockrail t3 pair`"
      : "T3 Code pairing expired: run `dockrail t3 pair`"
  }

  function test_matchedAuthErrorHasNoFallbackCard() {
    for (var code of ["pairing_required", "pairing_expired", "authentication_required"]) {
      var view = viewFor(t3Server(code), true)
      compare(view.hasFallbackContent, false)
      compare(view.rows.length, 0)
    }
  }

  function test_unmatchedAuthErrorPresentsHintCard() {
    for (var code of ["pairing_required", "pairing_expired", "authentication_required"]) {
      var view = viewFor(t3Server(code), false)
      verify(view.hasFallbackContent)
      var sessions = view.rows.filter(function(row) { return row.kind === "session" })
      compare(sessions.length, 1)
      compare(sessions[0].detail, hintFor(code))
      var agents = view.rows.filter(function(row) { return row.kind === "agent" })
      compare(agents.length, 0)
      var texts = view.rows.map(function(row) {
        return String(row.title || "") + " " + String(row.detail || "")
      }).join(" ")
      verify(texts.indexOf("Herdr") < 0)
    }
  }

  function test_t3FallbackUsesSourceSpecificCompleteness() {
    var partialServer = t3Server("")
    partialServer.health = "live"
    partialServer.connected = true
    partialServer.sourceCompleteness = {
      state: "partial", truncated: true, agentTruncated: true
    }
    partialServer.sourceLiveCountsKnown = true
    var partialView = viewFor(partialServer, false)
    var partialData = snapshotWith(partialServer)
    partialData.completeness = { state: "complete", truncated: false }
    partialView.widgetContext = {
      data: partialData,
      herdrAssociations: { byWindowKey: ({}), unmatchedServerIds: ["t3:env-1"] }
    }
    verify(partialView.summary().indexOf("partial") >= 0,
      "T3 truncated inventory must be shown even when Herdr is complete")

    var completeServer = t3Server("")
    completeServer.health = "live"
    completeServer.connected = true
    completeServer.sourceCompleteness = { state: "complete", truncated: false }
    completeServer.sourceLiveCountsKnown = true
    var completeView = viewFor(completeServer, false)
    var completeData = snapshotWith(completeServer)
    completeData.completeness = { state: "partial", truncated: true }
    completeView.widgetContext = {
      data: completeData,
      herdrAssociations: { byWindowKey: ({}), unmatchedServerIds: ["t3:env-1"] }
    }
    verify(completeView.summary().indexOf("partial") < 0,
      "Herdr truncation must not mark a complete T3 inventory partial")
  }

  function test_herdrCopyUnchanged() {
    var view = createTemporaryObject(viewFactory, testCase, { sourceFilter: "herdr" })
    verify(view !== null)
    view.widgetContext = {
      data: snapshotWith(herdrServer()),
      herdrAssociations: { byWindowKey: ({}), unmatchedServerIds: ["local-h"] }
    }
    verify(view.hasFallbackContent)
    var sessions = view.rows.filter(function(row) { return row.kind === "session" })
    compare(sessions.length, 1)
    compare(sessions[0].title, "Local Herdr")
    compare(sessions[0].detail, "unavailable")
  }

  Component {
    id: panelFactory
    Item {
      id: panel
      property var controller: null
      property var viewport: QtObject {
        property int workspaceCardInset: 0
      }
      property bool panelCollapsed: false
      property var widgetManager: null
      property var contentItem: Item {}
      width: 300
      height: 600
      visible: true
    }
  }

  function areaFor(snapshot, matched) {
    var associations = matched
      ? { byWindowKey: { "win:t3": "t3:env-1" }, unmatchedServerIds: [] }
      : { byWindowKey: ({}), unmatchedServerIds: ["t3:env-1"] }
    var controller = {
      widgetRevision: 0,
      widgetIds: ["t3.threads"],
      widgetView: function(id) {
        if (id !== "t3.threads") return null
        return { status: "ready", data: snapshot, active: true }
      },
      herdrAssociations: associations
    }
    var panel = createTemporaryObject(panelFactory, testCase, { controller: controller })
    verify(panel !== null)
    var area = SplitHarness.makeArea(panel, { width: panel.width })
    verify(area !== null)
    return area
  }

  function test_areaPresentsUnmatchedHintCard() {
    var area = areaFor(snapshotWith(t3Server("pairing_required")), false)
    var ids = area.presentationWidgetIds
    verify(ids.indexOf("t3.threads") >= 0)
  }

  function test_areaHidesMatchedAuthErrorCard() {
    var area = areaFor(snapshotWith(t3Server("authentication_required")), true)
    var ids = area.presentationWidgetIds
    verify(ids.indexOf("t3.threads") < 0)
  }
}
