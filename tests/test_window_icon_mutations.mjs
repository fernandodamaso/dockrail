import assert from "node:assert/strict"
import fs from "node:fs"
import { hostHarness, loadModel, plain, read } from "./host_harness.mjs"

const ConfigModel = loadModel("DockConfigModel")
const DockIconModel = loadModel("DockIconModel")
const defaults = JSON.parse(read("config/dock.json"))

assert.equal(typeof ConfigModel.windowIconIntent, "function",
  "Task 2 requires a latest-state window icon intent")
assert.equal(typeof ConfigModel.windowIconsChanged, "function",
  "Task 2 requires window-rule changes to participate in artwork reload revisions")

const a = { appId: "org.ghostty", titlePattern: "*solar*", source: "file:///tmp/a.svg" }
const b = { appId: "org.ghostty", titlePattern: "*lunar*", source: "file:///tmp/b.svg" }
const aKey = DockIconModel.windowRuleKey(a.appId, a.titlePattern)
const bKey = DockIconModel.windowRuleKey(b.appId, b.titlePattern)

function settings(rules) {
  return { ...plain(defaults), windowIconOverrides: plain(rules) }
}
function expectConflict(result, label) {
  assert.equal(result.ok, false, label)
  assert.equal(result.errorCode, "E_CONFLICT", label + " exposes a conflict, not validation")
  assert.deepEqual(Array.from(result.changedKeys || []), [], label + " never applies a stale edit")
}

let result = ConfigModel.windowIconIntent(settings([a, b]), "set", {
  mode: "cli", appId: " ORG.GHOSTTY ", titlePattern: " *SOLAR* ", source: "/tmp/c.svg"
})
assert.equal(result.ok, true)
assert.deepEqual(plain(result.settings.windowIconOverrides), [
  { appId: "org.ghostty", titlePattern: "*SOLAR*", source: "file:///tmp/c.svg" },
  b
], "CLI set edits the latest matching rule in place without rebuilding unrelated rules")
assert.deepEqual(Array.from(result.changedKeys), ["windowIconOverrides"])

result = ConfigModel.windowIconIntent(result.settings, "reset", {
  mode: "cli", appId: "org.ghostty", titlePattern: "*solar*"
})
assert.equal(result.ok, true)
assert.deepEqual(plain(result.settings.windowIconOverrides), [b],
  "CLI reset removes only the exact stable rule key")

const capturedA = { key: aKey, expected: a }
const unrelatedLatest = settings([b, a])
result = ConfigModel.windowIconIntent(unrelatedLatest, "set", {
  mode: "dialog", originalKey: capturedA.key, expected: capturedA.expected,
  appId: "org.ghostty", titlePattern: "*solar*", source: "/tmp/c.svg"
})
assert.equal(result.ok, true)
assert.deepEqual(plain(result.settings.windowIconOverrides), [
  b,
  { appId: "org.ghostty", titlePattern: "*solar*", source: "file:///tmp/c.svg" }
], "unrelated reorder/edit does not false-conflict and latest order is preserved")

expectConflict(ConfigModel.windowIconIntent(settings([
  { ...a, source: "file:///tmp/concurrent.svg" }, b
]), "set", {
  mode: "dialog", originalKey: aKey, expected: a,
  appId: a.appId, titlePattern: a.titlePattern, source: "/tmp/c.svg"
}), "same-rule source change")

expectConflict(ConfigModel.windowIconIntent(settings([b]), "set", {
  mode: "dialog", originalKey: aKey, expected: a,
  appId: a.appId, titlePattern: a.titlePattern, source: "/tmp/c.svg"
}), "same-rule deletion")

const collision = ConfigModel.windowIconIntent(settings([a, b]), "set", {
  mode: "dialog", originalKey: aKey, expected: a,
  appId: b.appId, titlePattern: b.titlePattern, source: "/tmp/c.svg"
})
assert.equal(collision.ok, false, "editing onto another stable key is refused")
assert.notEqual(collision.errorCode, "E_CONFLICT", "reopening cannot fix a duplicate key")
assert.match(collision.errors[0].message, /Another rule already uses/)

expectConflict(ConfigModel.windowIconIntent(settings([a]), "set", {
  mode: "dialog", originalKey: "", expected: null,
  appId: "ORG.GHOSTTY", titlePattern: "*SOLAR*", source: "/tmp/c.svg"
}), "same-key concurrent create")

result = ConfigModel.windowIconIntent(settings([b]), "set", {
  mode: "dialog", originalKey: "", expected: null,
  appId: a.appId, titlePattern: a.titlePattern, source: "/tmp/a.svg"
})
assert.equal(result.ok, true)
assert.deepEqual(plain(result.settings.windowIconOverrides), [b, a],
  "new dialog rules append after the latest collection")

result = ConfigModel.windowIconIntent(settings([a, b]), "reset", {
  mode: "dialog", originalKey: aKey, expected: a,
  appId: a.appId, titlePattern: a.titlePattern
})
assert.equal(result.ok, true)
assert.deepEqual(plain(result.settings.windowIconOverrides), [b],
  "dialog reset removes only the originally captured exact rule")

result = ConfigModel.windowIconIntent(settings([a]), "set", {
  mode: "cli", appId: a.appId, titlePattern: a.titlePattern, source: a.source
})
assert.equal(result.ok, true)
assert.deepEqual(Array.from(result.changedKeys), [],
  "same-path set is a config no-op so reload can be revision-only")

assert.equal(ConfigModel.windowIconIntent(
  { ...settings([]), windowIconOverrides: [{ appId: "bad", source: "/tmp/a.svg" }] },
  "set", { mode: "cli", appId: a.appId, titlePattern: a.titlePattern, source: a.source }
).ok, false, "malformed existing rule collections block mutation atomically")

const harness = hostHarness({ windowIconOverrides: [] })
let reply = harness.request("icons.set", {
  id: "org.ghostty", titlePattern: "*solar*", source: "/tmp/a.svg"
})
assert.equal(reply.ok, true)
assert.equal(reply.data.applied, true)
assert.equal(reply.data.persisted, true)
assert.equal(reply.data.renderVerified, false)
assert.equal(harness.writes.length, 1)
const firstRevision = reply.data.iconReloadRevision

reply = harness.request("icons.set", {
  id: "org.ghostty", titlePattern: "*solar*", source: "/tmp/a.svg"
})
assert.equal(reply.ok, true)
assert.equal(harness.writes.length, 1,
  "same-path apply never creates a redundant settings write")
assert.equal(reply.data.iconReloadRevision, firstRevision + 1,
  "same-path apply still refreshes artwork bytes")

reply = harness.request("icons.set", {
  id: "org.ghostty", titlePattern: "*solar*", source: "/tmp/b.svg"
})
assert.equal(reply.ok, true)
assert.equal(harness.writes.length, 2)
assert.equal(reply.data.iconReloadRevision, firstRevision + 2,
  "source A -> B is both a persisted rule change and an artwork refresh")

reply = harness.request("icons.list")
assert.deepEqual(reply.data.windowOverrides, [
  { appId: "org.ghostty", titlePattern: "*solar*", source: "file:///tmp/b.svg" }
])
assert.deepEqual(reply.data.effectiveWindowOverrides, reply.data.windowOverrides)

reply = harness.request("icons.reset", {
  id: "org.ghostty", titlePattern: "*solar*"
})
assert.equal(reply.ok, true)
assert.deepEqual(plain(harness.host.settings.windowIconOverrides), [])

assert.ok(!fs.existsSync(new URL("../components/DockWindowIconDialog.qml", import.meta.url)),
  "the window-only dialog is replaced by the shared Change Icon dialog")
const dialog = read("components/DockIconDialog.qml")
assert.doesNotMatch(dialog, /QtQuick\.Dialogs|FileDialog/,
  "no in-process native file dialog runs inside the shell")
assert.match(dialog, /"omarchy-file-select", "--title", "Choose an icon image", "--extensions", "png svg"/,
  "Choose file uses Omarchy's out-of-process portal chooser")
assert.match(dialog, /chosenFileSource\(chooserOutput\.text\)/,
  "chooser output is parsed by the tested model helper")
assert.match(dialog, /The file chooser could not be opened\./)
assert.match(dialog, /chooserLaunchSerial !== root\.chooserSerial/,
  "a chooser result that outlives its dialog is ignored")
assert.match(dialog, /saveIconChange\(/, "one host call removes and sets overrides together")
assert.match(dialog, /iconChangeArguments\(/, "save arguments come from the tested model helper")
assert.match(dialog, /currentIconTarget\(/, "the dialog preselects the override that applies")
assert.match(dialog, /reply\.ok === true \|\| \(reply\.data && reply\.data\.applied === true\)/,
  "dialog dismissal follows applied truth, including persistence-pending replies")
assert.match(dialog, /E_CONFLICT/, "a concurrent edit is reported inline")
assert.doesNotMatch(dialog, /FDM-927/, "the narrow window-only exception comment is gone")

const context = read("components/DockContextMenu.qml")
assert.match(context, /"Change Icon\\u2026"/)
assert.doesNotMatch(context, /"Reset Icon"|"Copy Icon Command"/)
assert.match(context, /DockIconDialog/)

const agents = read("AGENTS.md")
assert.doesNotMatch(agents, /selected live window|FDM-927/i,
  "AGENTS no longer carries the narrow window-only dialog exception")
assert.match(agents, /CLI remains the complete configuration\s+interface for AI coding agents and automation/,
  "AGENTS keeps the CLI complete for agent configuration")
assert.match(agents, /Settings-panel design for people/,
  "AGENTS records the accepted human Settings audience")
assert.match(agents, /does not ship that UI/,
  "AGENTS does not claim the Settings UI is already shipped")
assert.match(agents, /shares the host-wide single active editing slot with Change Icon/,
  "AGENTS requires one host-wide editing slot shared with Change Icon")
assert.match(agents, /DockHost\.saveIconChange` and the existing\s+FileView\s+writer/,
  "Change Icon continues to save through the existing host writer")
assert.match(agents, /second config writer/,
  "AGENTS still forbids a second config writer")
for (const doc of ["README.md", "docs/CONFIGURATION.md", "docs/CLI_REFERENCE.md",
  "docs/AGENT_CONFIGURATION.md", "docs/CLI_RUNTIME_CHECKS.md"]) {
  const text = read(doc)
  assert.doesNotMatch(text, /Copy Icon Command|selected-window dialog|selected-live-window/i,
    `${doc} drops the removed icon menu entries`)
  assert.doesNotMatch(text, /no continuous (artwork-file )?watch/i,
    `${doc} documents the automatic artwork file watch`)
}
for (const doc of ["README.md", "docs/CONFIGURATION.md", "docs/CLI_REFERENCE.md"])
  assert.match(read(doc), /Change Icon\u2026/, `${doc} describes the Change Icon dialog`)
assert.doesNotMatch(read(".github/workflows/ci.yml"), /qml6-module-qtquick-dialogs/,
  "CI no longer needs QtQuick.Dialogs")

console.log("window icon mutation and Change Icon dialog policy contracts: PASS")
