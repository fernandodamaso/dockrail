import QtQuick
import QtTest

// Execute the *actual* DockHost.qml function bodies in a Qt/QML engine.
// Unlike the Node VM harness, this suite runs under qmltestrunner.
// Only external FileView completion and DockControl's envelope/metadata
// transport are replaced; patch validation, commits and write state are
// the production DockHost + DockConfigModel implementation.
TestCase {
  id: testCase
  name: "SettingsHostWriter"
  when: windowShown
  width: 320
  height: 200

  Component {
    id: ioFactory
    QtObject {
      property var host: null
      property bool autoComplete: true
      property bool fail: false
      property int writeCount: 0
      property string cachedText: ""
      property string lastText: ""
      function setText(text) {
        writeCount++
        cachedText = text
        lastText = text
        if (!autoComplete) return
        if (fail) host.settingsSaveFailed(3)
        else host.settingsSaved()
      }
      function reload() { throw new Error("Unexpected settings reload") }
    }
  }

  function sourceFile(relative) {
    var xhr = new XMLHttpRequest()
    xhr.open("GET", Qt.resolvedUrl(relative), false)
    xhr.send()
    compare(xhr.status, 200, "Production source must be readable during the test")
    return xhr.responseText
  }

  function productionMethod(source, name) {
    // Match only a complete, top-level DockHost method; do not reimplement
    // any writer method in the test or silently accept its disappearance.
    var pattern = new RegExp("^  function " + name
      + "\\([^\\n]*\\) \\{[\\s\\S]*?^  \\}", "m")
    var match = source.match(pattern)
    verify(match !== null, "DockHost.qml method missing: " + name)
    return match[0]
  }

  function makeWriter() {
    var content = sourceFile("../DockHost.qml")
    var names = [
      "mutationBlocked", "saveSettingsIntent", "saveSettings",
      "commitSettings", "mutationOutcome", "writeSettings",
      "settingsSaved", "settingsSaveFailed", "reloadSettingsIfPending"
    ]
    var methods = names.map(function(name) {
      return productionMethod(content, name)
    }).join("\n")
    var code = [
      "import QtQuick",
      'import "../components/DockModel.js" as DockModel',
      'import "../components/DockConfigModel.js" as ConfigModel',
      'import "../components/DockIconModel.js" as DockIconModel',
      'import "../components/DockTrashModel.js" as TrashModel',
      'import "./SettingsFileViewError.js" as FileViewError',
      "Item {",
      "  id: root",
      "  property var dockControl: null",
      "  property var configFile: null",
      "  property var settings: ({})",
      "  property bool settingsLoaded: true",
      "  property bool settingsReloadPending: false",
      '  property string settingsLoadState: "loaded"',
      '  property string settingsLoadError: ""',
      '  property string settingsWriteState: "idle"',
      '  property string settingsWriteError: ""',
      "  property bool settingsPersisted: true",
      "  property bool settingsDefaultsInUse: false",
      "  property int settingsRevision: 0",
      "  property int iconReloadRevision: 0",
      "  property bool showTrashSetting: true",
      "  property var modeGestureFeedbackByMonitor: ({})",
      '  property string modeMenuWriteConnector: ""',
      '  property string settingsLoadedText: ""',
      '  property string settingsWriteBaseText: ""',
      '  property string settingsWriteText: ""',
      '  property string configPath: "/tmp/dockrail-test.json"',

      methods,
      "}"
    ].join("\n")
    var host = Qt.createQmlObject(code, testCase, Qt.resolvedUrl("tst_SettingsHostWriter.qml"))
    verify(host !== null, "Production writer must compile in Qt")
    var io = createTemporaryObject(ioFactory, testCase)
    verify(io !== null)
    io.host = host
    host.configFile = io
    var defaults = JSON.parse(sourceFile("../config/dock.json"))
    var metadata = JSON.parse(sourceFile("../config/settings-schema.json"))
    defaults.extensionData = { untouched: ["foreign", 7] }
    host.settings = defaults
    host.dockControl = {
      validationMetadata: function() { return metadata },
      mutationData: function(before, requested, changed, dry, applied) {
        return { applied: applied, persisted: host.settingsPersisted,
          changedKeys: changed, requested: requested }
      },
      failure: function(code, message, data) {
        return { apiVersion: 1, ok: false,
          error: { code: code, message: message }, data: data || {} }
      },
      success: function(data, warnings) {
        return { apiVersion: 1, ok: true, data: data, warnings: warnings || [] }
      }
    }
    return { host: host, io: io }
  }

  function test_atomic_patch_persists_and_preserves_unknown_data() {
    var writer = makeWriter()
    var h = writer.host
    var reply = h.saveSettingsIntent(
      { backgroundColor: "#112233", backgroundColorEnabled: true },
      { backgroundColor: h.settings.backgroundColor,
        backgroundColorEnabled: h.settings.backgroundColorEnabled })
    verify(reply.accepted)
    verify(!reply.pending)
    verify(reply.reply.ok)
    compare(writer.io.writeCount, 1)
    compare(h.settingsWriteState, "saved")
    verify(h.settingsPersisted)
    var stored = JSON.parse(writer.io.lastText)
    compare(stored.backgroundColor, "#112233")
    compare(stored.backgroundColorEnabled, true)
    compare(stored.extensionData.untouched[0], "foreign")
    compare(stored.extensionData.untouched[1], 7)
  }

  function test_stale_pair_after_cli_equivalent_write_is_rejected_before_file_change() {
    var writer = makeWriter()
    var h = writer.host
    var expected = {
      backgroundColor: h.settings.backgroundColor,
      backgroundColorEnabled: h.settings.backgroundColorEnabled
    }
    // The CLI ultimately calls this same production saveSettings method.
    var external = h.saveSettings({ backgroundColor: "#445566" }, false)
    verify(external.ok)
    var writes = writer.io.writeCount
    var stale = h.saveSettingsIntent(
      { backgroundColor: "#778899", backgroundColorEnabled: true },
      expected)
    verify(!stale.accepted)
    compare(stale.reply.error.code, "E_STALE")
    compare(stale.reply.data.key, "backgroundColor")
    compare(writer.io.writeCount, writes)
    compare(h.settings.backgroundColor, "#445566")
  }

  function test_missing_expected_and_invalid_value_do_not_write() {
    var writer = makeWriter()
    var h = writer.host
    var incomplete = h.saveSettingsIntent(
      { borderWidth: 3, borderWidthEnabled: true },
      { borderWidth: h.settings.borderWidth })
    verify(!incomplete.accepted)
    compare(incomplete.reply.error.code, "E_VALIDATION")
    var invalid = h.saveSettingsIntent(
      { iconSize: -5 }, { iconSize: h.settings.iconSize })
    verify(!invalid.accepted)
    compare(invalid.reply.error.code, "E_VALIDATION")
    compare(writer.io.writeCount, 0)
  }

  function test_pending_save_busy_then_durable_readback() {
    var writer = makeWriter()
    var h = writer.host
    writer.io.autoComplete = false
    var accepted = h.saveSettingsIntent(
      { borderWidth: 3, borderWidthEnabled: true },
      { borderWidth: h.settings.borderWidth,
        borderWidthEnabled: h.settings.borderWidthEnabled })
    verify(accepted.accepted)
    verify(accepted.pending)
    compare(accepted.reply.error.code, "E_BUSY")
    compare(h.settingsWriteState, "saving")
    var busy = h.saveSettingsIntent(
      { iconSize: 48 }, { iconSize: h.settings.iconSize })
    verify(!busy.accepted)
    compare(busy.reply.error.code, "E_BUSY")
    compare(writer.io.writeCount, 1)
    h.settingsSaved()
    compare(h.settingsWriteState, "saved")
    verify(h.settingsPersisted)
    compare(JSON.parse(writer.io.lastText).borderWidth, 3)
  }

  function test_persistence_failure_reports_unsaved_accepted_intent() {
    var writer = makeWriter()
    var h = writer.host
    writer.io.fail = true
    var reply = h.saveSettingsIntent(
      { iconSize: 48 }, { iconSize: h.settings.iconSize })
    verify(reply.accepted)
    verify(!reply.pending)
    compare(reply.reply.error.code, "E_PERSISTENCE")
    compare(h.settingsWriteState, "error")
    verify(!h.settingsPersisted)
    compare(writer.io.writeCount, 1)
  }

  function test_structurally_equal_expected_object_is_not_stale() {
    var writer = makeWriter()
    var h = writer.host
    var existing = JSON.parse(JSON.stringify(h.settings.presentationModeByMonitor))
    var patch = h.saveSettingsIntent(
      { presentationModeByMonitor: { "DP-1": "sidebar" } },
      { presentationModeByMonitor: existing })
    verify(patch.accepted)
    compare(patch.reply.ok, true)
    compare(JSON.parse(writer.io.lastText).presentationModeByMonitor["DP-1"], "sidebar")
  }
}
