import assert from "node:assert/strict"
import vm from "node:vm"
import test from "node:test"
import { hostHarness, loadModel, plain, read } from "./host_harness.mjs"

const DockIconModel = loadModel("DockIconModel")
const ConfigModel = loadModel("DockConfigModel")
const defaults = JSON.parse(read("config/dock.json"))

// "Title contains" round-trips through the saved *TEXT* pattern.
assert.deepEqual(plain(DockIconModel.containsToPattern("  solar ")),
  { ok: true, pattern: "*solar*", error: "" })
for (const bad of ["", "   ", "a*b", "tab\there", "x".repeat(199), null])
  assert.equal(DockIconModel.containsToPattern(bad).ok, false, "rejects " + JSON.stringify(bad))
assert.equal(DockIconModel.containsToPattern("x".repeat(198)).pattern.length, 200)

assert.equal(DockIconModel.patternToContains("*solar*"), "solar")
assert.equal(DockIconModel.patternToContains(" *Solar API* "), "Solar API")
for (const exact of ["solar", "*solar", "solar*", "*a*b*", "**", "*", "* x*", ""])
  assert.equal(DockIconModel.patternToContains(exact), null,
    JSON.stringify(exact) + " stays an exact pattern")
for (const text of ["solar", "Solar API", "~/Projects"])
  assert.equal(DockIconModel.patternToContains(DockIconModel.containsToPattern(text).pattern), text)

// Current override follows the renderer precedence: window -> profile -> app.
const settings = {
  iconOverrides: {
    "google-chrome": "/icons/chrome.svg",
    "google-chrome@profile:Profile 1": "/icons/work.svg",
    "com.mitchellh.ghostty": "/icons/ghostty.png"
  },
  windowIconOverrides: [
    { appId: "com.mitchellh.ghostty", titlePattern: "*solar*", source: "/icons/sun.svg" },
    { appId: "google-chrome", titlePattern: "*mail*", source: "/icons/mail.svg" }
  ]
}

assert.deepEqual(plain(DockIconModel.currentIconTarget({
  settings, desktopId: "com.mitchellh.ghostty", appId: "com.mitchellh.ghostty",
  title: "solar — nvim"
})), {
  kind: "window",
  key: DockIconModel.windowRuleKey("com.mitchellh.ghostty", "*solar*"),
  appId: "com.mitchellh.ghostty", titlePattern: "*solar*", source: "file:///icons/sun.svg"
})
assert.deepEqual(plain(DockIconModel.currentIconTarget({
  settings, desktopId: "com.mitchellh.ghostty", appId: "com.mitchellh.ghostty", title: "htop"
})), { kind: "app", key: "com.mitchellh.ghostty", source: "file:///icons/ghostty.png" })
assert.deepEqual(plain(DockIconModel.currentIconTarget({
  settings, desktopId: "google-chrome.desktop", profileKey: "Profile 1",
  appId: "google-chrome", title: "News"
})), { kind: "profile", key: "google-chrome@profile:Profile 1", source: "file:///icons/work.svg" })
assert.equal(DockIconModel.currentIconTarget({
  settings, desktopId: "google-chrome", profileKey: "Profile 1",
  appId: "google-chrome", title: "Inbox (3) - mail"
}).kind, "window", "a title rule beats the profile icon")
assert.equal(DockIconModel.currentIconTarget({
  settings, desktopId: "google-chrome", profileKey: "Profile 9", appId: "", title: ""
}).kind, "app", "a pinned app without a window falls back to the app icon")
assert.deepEqual(plain(DockIconModel.currentIconTarget({ settings, desktopId: "code" })),
  { kind: "none", key: "", source: "" })
assert.equal(DockIconModel.currentIconTarget({}).kind, "none")

// Recent images: distinct, window rules then app icons, latest additions first.
assert.deepEqual(plain(DockIconModel.recentIconSources(settings)), [
  "file:///icons/mail.svg", "file:///icons/sun.svg", "file:///icons/ghostty.png",
  "file:///icons/work.svg", "file:///icons/chrome.svg"
])
assert.deepEqual(plain(DockIconModel.recentIconSources(settings, 2)),
  ["file:///icons/mail.svg", "file:///icons/sun.svg"])
assert.deepEqual(plain(DockIconModel.recentIconSources({
  iconOverrides: { a: "/x.svg", b: "/x.svg", c: "https://remote/x.svg" },
  windowIconOverrides: "invalid"
})), ["file:///x.svg"], "duplicates and invalid sources are skipped")
assert.deepEqual(plain(DockIconModel.recentIconSources(null)), [])

// Preview flags which open windows a choice would change.
const windows = [
  { appId: "com.mitchellh.ghostty", title: "solar — nvim" },
  { appId: "com.mitchellh.ghostty", title: "~/Projects/smart-omarchy-dock", profileKey: "Profile 1" },
  { appId: "com.mitchellh.ghostty", title: "SOLAR-api · logs", profileKey: "Profile 1" },
  { appId: "com.mitchellh.ghostty", title: "htop" }
]
assert.deepEqual(plain(DockIconModel.previewMatches(windows, { kind: "app" })),
  { flags: [true, true, true, true], count: 4 })
assert.deepEqual(plain(DockIconModel.previewMatches(windows,
  { kind: "window", appId: "com.mitchellh.ghostty", titlePattern: "*solar*" })),
  { flags: [true, false, true, false], count: 2 })
assert.deepEqual(plain(DockIconModel.previewMatches(windows,
  { kind: "profile", profileKey: "Profile 1" })),
  { flags: [false, true, true, false], count: 2 })
assert.equal(DockIconModel.previewMatches(windows, { kind: "window", appId: "com.mitchellh.ghostty", titlePattern: "" }).count, 0)
assert.equal(DockIconModel.previewMatches(null, { kind: "app" }).count, 0)

// One save covers a scope change: remove what applied, set the new choice.
const base = {
  ...plain(defaults),
  iconOverrides: { "com.mitchellh.ghostty": "file:///icons/ghostty.png", legacy: "/keep.svg" },
  windowIconOverrides: [
    { appId: "com.mitchellh.ghostty", titlePattern: "*solar*", source: "file:///icons/sun.svg" },
    { appId: "com.mitchellh.ghostty", titlePattern: "*lunar*", source: "file:///icons/moon.svg" }
  ]
}
const solarRule = { kind: "window", ...DockIconModel.currentIconTarget({
  settings: base, desktopId: "com.mitchellh.ghostty",
  appId: "com.mitchellh.ghostty", title: "solar — nvim"
}) }
const appIcon = { kind: "app", key: "com.mitchellh.ghostty", source: "file:///icons/ghostty.png" }

let change = ConfigModel.iconChangeIntent(base, {
  remove: solarRule,
  set: { kind: "app", key: "com.mitchellh.ghostty", source: "/icons/new.svg", expected: appIcon.source }
})
assert.equal(change.ok, true)
assert.deepEqual(Array.from(change.changedKeys).sort(), ["iconOverrides", "windowIconOverrides"])
assert.deepEqual(plain(change.settings.windowIconOverrides), [base.windowIconOverrides[1]],
  "title rule to whole app removes the rule")
assert.deepEqual(plain(change.settings.iconOverrides),
  { legacy: "/keep.svg", "com.mitchellh.ghostty": "file:///icons/new.svg" },
  "unrelated legacy entries are untouched")

change = ConfigModel.iconChangeIntent(base, {
  remove: solarRule,
  set: { kind: "window", appId: "com.mitchellh.ghostty", titlePattern: "*sol*",
    source: "/icons/sun.svg", expected: null }
})
assert.equal(change.ok, true)
assert.deepEqual(plain(change.settings.windowIconOverrides)[0],
  { appId: "com.mitchellh.ghostty", titlePattern: "*sol*", source: "file:///icons/sun.svg" },
  "editing a title rule keeps its place in the ordered list")
assert.deepEqual(Array.from(change.changedKeys), ["windowIconOverrides"])

change = ConfigModel.iconChangeIntent(base, {
  set: { kind: "profile", key: "google-chrome@profile:Profile 1", source: "/icons/work.svg", expected: "" }
})
assert.equal(change.ok, true)
assert.equal(change.settings.iconOverrides["google-chrome@profile:Profile 1"], "file:///icons/work.svg")

change = ConfigModel.iconChangeIntent(base, { remove: appIcon })
assert.equal(change.ok, true, "Reset to default removes exactly the applied override")
assert.deepEqual(plain(change.settings.iconOverrides), { legacy: "/keep.svg" })

const stale = ConfigModel.iconChangeIntent(base, {
  remove: { ...appIcon, source: "file:///icons/other.png" },
  set: { kind: "app", key: "com.mitchellh.ghostty", source: "/icons/new.svg", expected: appIcon.source }
})
assert.equal(stale.ok, false)
assert.equal(stale.errorCode, "E_CONFLICT", "a concurrent app icon edit is refused")
assert.equal(ConfigModel.iconChangeIntent(base, {
  remove: { ...solarRule, source: "file:///icons/other.svg" }
}).errorCode, "E_CONFLICT", "a concurrent title rule edit is refused")

const failedSet = ConfigModel.iconChangeIntent(base, {
  remove: appIcon, set: { kind: "app", key: "com.mitchellh.ghostty", source: "https://x/y.svg", expected: appIcon.source }
})
assert.equal(failedSet.ok, false, "an invalid new image rejects the whole save")
assert.deepEqual(Array.from(failedSet.changedKeys), [])

assert.deepEqual(Array.from(ConfigModel.iconChangeIntent(base, {
  remove: appIcon, set: { kind: "app", key: "com.mitchellh.ghostty", source: "/icons/ghostty.png", expected: appIcon.source }
}).changedKeys), [], "saving the same image and scope writes nothing")
assert.deepEqual(Array.from(ConfigModel.iconChangeIntent(base, {}).changedKeys), [])
assert.equal(ConfigModel.iconChangeIntent(base, { set: { kind: "bogus" } }).ok, false)

// Dialog helpers: labels, notice, save arguments and the preview sentence.
assert.equal(DockIconModel.sourceFileName("file:///icons/My%20Sun.svg"), "My Sun.svg")
assert.equal(DockIconModel.sourceFileName(""), "")

const sunRule = DockIconModel.currentIconTarget({
  settings, desktopId: "com.mitchellh.ghostty", appId: "com.mitchellh.ghostty", title: "solar"
})
assert.equal(DockIconModel.currentIconNotice(sunRule, "Ghostty"),
  "This window uses sun.svg because its title contains \u201csolar\u201d. Editing this updates that setting.")
assert.equal(DockIconModel.currentIconNotice({ kind: "window", titlePattern: "solar*",
  source: "file:///x/a.png" }, "Ghostty"),
  "This window uses a.png because its title matches \u201csolar*\u201d. Editing this updates that setting.")
assert.equal(DockIconModel.currentIconNotice({ kind: "app", source: "file:///icons/ghostty.png" },
  "Ghostty"), "Ghostty uses a custom icon (ghostty.png) for all its windows.")
assert.equal(DockIconModel.currentIconNotice({ kind: "profile", source: "file:///w/work.svg" },
  "Chrome", "Work"), "The Work profile uses a custom icon (work.svg).")
assert.equal(DockIconModel.currentIconNotice({ kind: "none" }, "Ghostty"), "")

const ids = { desktopId: "com.mitchellh.ghostty", appId: "com.mitchellh.ghostty" }
const ghosttyApp = { kind: "app", key: "com.mitchellh.ghostty", source: "file:///icons/ghostty.png" }
const none = { kind: "none", key: "", source: "" }
let save = DockIconModel.iconChangeArguments(none, { ...ids, kind: "app", source: "/i/new.svg" })
assert.deepEqual(plain(save), { ok: true, error: "", unchanged: false, args: {
  remove: null, set: { kind: "app", key: "com.mitchellh.ghostty", source: "/i/new.svg", expected: "" } } })
save = DockIconModel.iconChangeArguments(sunRule, { ...ids, kind: "app", source: "/i/new.svg" }, settings)
assert.deepEqual(plain(save.args.remove), plain(sunRule), "a wider scope replaces the title rule")
save = DockIconModel.iconChangeArguments(ghosttyApp, { ...ids, kind: "window",
  titleMode: "contains", titleText: " solar ", source: "/i/sun.svg" }, settings)
assert.equal(save.args.remove, null, "a narrower title rule keeps the whole-app icon")
assert.deepEqual(plain(save.args.set), { kind: "window", appId: "com.mitchellh.ghostty",
  titlePattern: "*solar*", source: "/i/sun.svg",
  expected: plain(DockIconModel.windowIconTarget(settings, ids.appId, "*solar*")) })
save = DockIconModel.iconChangeArguments(sunRule, { ...ids, kind: "window",
  titleMode: "contains", titleText: "SOLAR", source: "file:///icons/sun.svg" }, settings)
assert.equal(save.unchanged, true, "same scope, pattern and image is unchanged")
save = DockIconModel.iconChangeArguments(sunRule, { ...ids, kind: "window",
  titleMode: "exact", titleText: " solar* ", source: "file:///icons/sun.svg" }, settings)
assert.equal(save.unchanged, false)
assert.equal(save.args.set.titlePattern, "solar*", "exact patterns are saved verbatim")
assert.deepEqual(plain(save.args.remove), plain(sunRule))
assert.equal(DockIconModel.iconChangeArguments(none, { ...ids, kind: "window",
  titleMode: "contains", titleText: "", source: "/i/sun.svg" }).error, "Type part of the window title.")
assert.equal(DockIconModel.iconChangeArguments(none, { kind: "window", titleText: "x",
  source: "/i/sun.svg" }).ok, false, "title rules need the raw Wayland app ID")
assert.equal(DockIconModel.iconChangeArguments(none, { ...ids, kind: "app",
  source: "https://x/y.svg" }).ok, false)
save = DockIconModel.iconChangeArguments(none, { desktopId: "google-chrome", profileKey: "Profile 1",
  kind: "profile", source: "/w.svg" })
assert.deepEqual(plain(save.args.set), { kind: "profile", key: "google-chrome@profile:Profile 1",
  source: "/w.svg", expected: "" })
assert.equal(DockIconModel.iconChangeArguments(none, { desktopId: "google-chrome",
  kind: "profile", source: "/w.svg" }).ok, false)
save = DockIconModel.iconChangeArguments(ghosttyApp, { ...ids, kind: "app", source: "" }, settings)
assert.deepEqual(plain(save.args), { remove: ghosttyApp, set: null }, "Default removes the override")
assert.equal(DockIconModel.iconChangeArguments(none, { ...ids, kind: "app", source: "" }).unchanged, true)
// The produced arguments save through the host intent in one step.
save = DockIconModel.iconChangeArguments(solarRule, { ...ids, kind: "app", source: "/icons/new.svg" }, base)
assert.equal(ConfigModel.iconChangeIntent(base, save.args).ok, true)

assert.equal(DockIconModel.previewSummary({ kind: "window", hasPattern: true, changed: 2, total: 4,
  appName: "Ghostty" }), "Preview: 2 of 4 open Ghostty windows change. New matching windows use this setting too.")
assert.equal(DockIconModel.previewSummary({ kind: "app", changed: 4, total: 4, appName: "Ghostty" }),
  "Preview: 4 of 4 open Ghostty windows change. New matching windows use this setting too.")
assert.equal(DockIconModel.previewSummary({ kind: "app", changed: 1, total: 1, appName: "Ghostty" }),
  "Preview: 1 of 1 open Ghostty window changes. New matching windows use this setting too.")
assert.equal(DockIconModel.previewSummary({ kind: "window", hasPattern: false, total: 3 }),
  "Type part of a window title to choose which windows change.")
assert.equal(DockIconModel.previewSummary({ kind: "profile", changed: 1, total: 2, appName: "Chrome" }),
  "Preview: 1 of 2 open Chrome windows changes. New matching windows use this setting too.")
assert.equal(DockIconModel.previewSummary({ kind: "app", total: 0 }), "")
assert.equal(DockIconModel.previewSummary({ kind: "app", resetting: true, changed: 3, total: 3,
  appName: "Ghostty", afterKind: "none" }), "Preview: 3 of 3 open Ghostty windows go back to the app's own icon.")
assert.equal(DockIconModel.previewSummary({ kind: "none", resetting: true, changed: 0, total: 2,
  appName: "Ghostty" }), "Preview: no open Ghostty windows change.")

// omarchy-file-select output: first non-empty line, path or file URI.
assert.equal(DockIconModel.chosenFileSource("/home/u/icons/app.png\n"), "file:///home/u/icons/app.png")
assert.equal(DockIconModel.chosenFileSource("/home/u/My Icons/app.SVG"),
  "file:///home/u/My%20Icons/app.SVG")
assert.equal(DockIconModel.chosenFileSource("file:///home/u/My%20Icons/app.svg\n"),
  "file:///home/u/My%20Icons/app.svg")
assert.equal(DockIconModel.chosenFileSource("\n/a/first.png\r\n/a/second.svg\n"), "file:///a/first.png")
assert.equal(DockIconModel.chosenFileSource("/a/first.jpg\n/a/second.svg\n"), "",
  "only the first chosen file is considered")
for (const empty of ["", "\n", "\n\n", null, undefined])
  assert.equal(DockIconModel.chosenFileSource(empty), "", "empty output " + JSON.stringify(empty))
assert.equal(DockIconModel.chosenFileSource("relative/app.png\n"), "", "relative paths are rejected")
assert.equal(DockIconModel.chosenFileSource("/a/app.gif\n"), "", "only PNG and SVG are accepted")

// Choose file lifecycle: hide while the out-of-process chooser runs, restore
// with the outcome, and ignore a result that outlives its dialog.
function dialogHarness() {
  const state = {
    DockIconModel, picking: false, visible: true, openAnchor: {}, inlineError: "old",
    chooserSerial: 0, chooserLaunchSerial: -1, chooserExitCode: -1, chooserOutputDone: false,
    imageSources: ["file:///a/recent.svg"], selectedSource: "file:///a/recent.svg", windows: [],
    fileChooser: { running: false }, chooserOutput: { text: "" },
    iconAssetIngest: { running: false }, iconAssetOutput: { text: "" },
    ingestSerial: 0, ingesting: false, pendingIconChange: null,
    settings: {}, mutationController: null,
    titleInput: { text: "", forceActiveFocus() {} }, keyScope: { forceActiveFocus() {} },
    Qt: { callLater() {} }
  }
  const context = vm.createContext(state)
  context.root = context
  vm.runInContext(read("components/DockIconDialog.qml").match(/^  function [\s\S]*?^  }/gm).join("\n"),
    context)
  return context
}
function runChooser(dialog, exitCode, text = "") {
  dialog.chooseFile()
  assert.equal(dialog.picking, true)
  assert.equal(dialog.visible, false, "the dialog hides while the chooser is open")
  assert.equal(dialog.fileChooser.running, true)
  dialog.chooseFile()
  assert.equal(dialog.chooserLaunchSerial, dialog.chooserSerial, "a second launch is ignored")
  dialog.chooserOutput.text = text
  dialog.chooserExitCode = exitCode
  dialog.fileChooser.running = false
  dialog.settleChooser()
  if (exitCode === 0) {
    dialog.chooserOutputDone = true
    dialog.settleChooser()
  }
}
let dialog = dialogHarness()
runChooser(dialog, 0, "/home/u/new icon.png\n")
assert.equal(dialog.visible, true)
assert.equal(dialog.picking, false)
assert.equal(dialog.inlineError, "")
assert.equal(dialog.selectedSource, "file:///home/u/new%20icon.png")
assert.deepEqual([...dialog.imageSources], ["file:///home/u/new%20icon.png", "file:///a/recent.svg"])
runChooser(dialog, 0, "/a/recent.svg\n")
assert.deepEqual([...dialog.imageSources], ["file:///a/recent.svg", "file:///home/u/new%20icon.png"],
  "re-choosing a known file moves it to the front without duplicating it")

dialog = dialogHarness()
runChooser(dialog, 0, "/a/photo.jpg\n")
assert.equal(dialog.visible, true)
assert.equal(dialog.inlineError, "Choose a PNG or SVG file.")
assert.equal(dialog.selectedSource, "file:///a/recent.svg")

dialog = dialogHarness()
runChooser(dialog, 1)
assert.equal(dialog.visible, true)
assert.equal(dialog.inlineError, "", "nothing picked just restores the dialog")

for (const code of [2, 127, 6]) {
  dialog = dialogHarness()
  runChooser(dialog, code)
  assert.equal(dialog.visible, true)
  assert.equal(dialog.inlineError, "The file chooser could not be opened.", `exit ${code}`)
}

dialog = dialogHarness()
dialog.chooseFile()
dialog.closeDialog()
dialog.chooserOutput.text = "/a/late.png\n"
dialog.chooserExitCode = 0
dialog.chooserOutputDone = true
dialog.settleChooser()
assert.equal(dialog.visible, false, "a late chooser result does not reopen a closed dialog")
assert.equal(dialog.selectedSource, "file:///a/recent.svg")

console.log("icon dialog model tests passed")

// PR117 review: every destination is compared with the opening snapshot.
const reviewApp = 'com.mitchellh.ghostty'
const reviewChrome = 'google-chrome'
const reviewRule = (text, source = '/icons/rule.svg', appId = reviewApp) =>
  ({ appId, titlePattern: `*${text}*`, source })
const reviewConfig = (icons = {}, rules = []) =>
  ({ ...plain(defaults), iconOverrides: icons, windowIconOverrides: rules })
const reviewChoice = (extra = {}) => ({ desktopId: reviewApp, appId: reviewApp,
  kind: 'app', source: '/icons/new.svg', titleMode: 'contains', titleText: '', ...extra })
function reviewBuild(opened, choice, target = {}) {
  const current = DockIconModel.currentIconTarget({ settings: opened,
    desktopId: choice.desktopId, profileKey: choice.profileKey, ...target })
  return DockIconModel.iconChangeArguments(current, choice, opened)
}
function expectConflict(opened, live, choice, target = {}) {
  const built = reviewBuild(opened, choice, target)
  assert.equal(built.ok, true)
  const before = JSON.stringify(live)
  const result = ConfigModel.iconChangeIntent(live, built.args)
  assert.equal(result.ok, false)
  assert.equal(result.errorCode, 'E_CONFLICT')
  assert.deepEqual(Array.from(result.changedKeys), [])
  assert.equal(JSON.stringify(live), before, 'a conflict mutates neither collection')
}

for (const kind of ['app', 'profile']) {
  test(`review: absent ${kind} destination created before save is a conflict`, () => {
    const key = kind === 'app' ? reviewApp : reviewApp + '@profile:Profile 1'
    expectConflict(reviewConfig(), reviewConfig({ [key]: '/icons/concurrent.svg' }),
      reviewChoice({ kind, profileKey: 'Profile 1' }))
  })
}
test('review: widening a title rule checks a newly created app destination', () => {
  const opened = reviewConfig({}, [reviewRule('solar')])
  expectConflict(opened, reviewConfig({ [reviewApp]: '/icons/concurrent.svg' }, opened.windowIconOverrides),
    reviewChoice(), { appId: reviewApp, title: 'solar editor' })
})
test('review: widening an unchanged profile to its existing app destination succeeds', () => {
  const profile = reviewChrome + '@profile:Profile 1'
  const opened = reviewConfig({ [reviewChrome]: '/icons/app.svg', [profile]: '/icons/profile.svg' })
  const built = reviewBuild(opened, reviewChoice({ desktopId: reviewChrome,
    appId: reviewChrome, profileKey: 'Profile 1' }))
  assert.equal(built.args.set.expected, 'file:///icons/app.svg')
  const saved = ConfigModel.iconChangeIntent(opened, built.args)
  assert.equal(saved.ok, true)
  assert.equal(saved.settings.iconOverrides[profile], undefined)
  assert.equal(saved.settings.iconOverrides[reviewChrome], 'file:///icons/new.svg')
})
for (const entry of ['app-page', 'unmatched-window']) {
  test(`review: ${entry} edits the existing destination rule in place`, () => {
    const opened = reviewConfig({ [reviewApp]: '/icons/app.svg' },
      [reviewRule('first'), reviewRule('solar'), reviewRule('last')])
    const built = reviewBuild(opened, reviewChoice({ kind: 'window', titleText: 'solar' }),
      entry === 'app-page' ? {} : { appId: reviewApp, title: 'htop' })
    assert.equal(built.ok, true)
    const saved = ConfigModel.iconChangeIntent(opened, built.args)
    assert.equal(saved.ok, true)
    assert.deepEqual(Array.from(saved.settings.windowIconOverrides, r => r.titlePattern),
      ['*first*', '*solar*', '*last*'])
    assert.equal(saved.settings.windowIconOverrides[1].source, 'file:///icons/new.svg')
    assert.equal(saved.settings.iconOverrides[reviewApp], '/icons/app.svg')
  })
}
for (const change of ['deleted', 'changed']) {
  test(`review: destination title rule ${change} after opening is a conflict`, () => {
    const opened = reviewConfig({}, [reviewRule('solar')])
    const live = reviewConfig({}, change === 'deleted' ? [] : [reviewRule('solar', '/icons/concurrent.svg')])
    expectConflict(opened, live, reviewChoice({ kind: 'window', titleText: 'solar' }))
  })
}
test('review: renaming A to existing B refuses a collision rather than merging', () => {
  const opened = reviewConfig({}, [reviewRule('solar'), reviewRule('lunar')])
  const current = DockIconModel.currentIconTarget({ settings: opened, desktopId: reviewApp,
    appId: reviewApp, title: 'solar' })
  const built = DockIconModel.iconChangeArguments(current,
    reviewChoice({ kind: 'window', titleText: 'lunar' }), opened)
  assert.equal(built.ok, false)
  assert.match(built.error, /Another title rule already uses/)
  const destination = DockIconModel.currentIconTarget({ settings: opened,
    desktopId: reviewApp, appId: reviewApp, title: 'lunar' })
  const forced = ConfigModel.iconChangeIntent(opened, { remove: current,
    set: { kind: 'window', ...reviewRule('lunar', '/icons/new.svg'), expected: destination } })
  assert.equal(forced.ok, false)
  assert.notEqual(forced.errorCode, 'E_CONFLICT')
  assert.match(forced.errors[0].message, /Another title rule already uses|Another rule already uses/)
})
test('review: missing destination expectation is rejected for all target kinds', () => {
  for (const target of [
    { kind: 'app', key: reviewApp, source: '/icons/new.svg' },
    { kind: 'profile', key: reviewApp + '@profile:Profile 1', source: '/icons/new.svg' },
    { kind: 'window', ...reviewRule('solar') }
  ]) {
    const result = ConfigModel.iconChangeIntent(reviewConfig(), { set: target })
    assert.equal(result.ok, false, target.kind)
    assert.match(result.errors[0].message, /expected|snapshot/i)
  }
})
test('review: same-key removal and set validate against the same live snapshot', () => {
  const opened = reviewConfig({ [reviewApp]: '/icons/app.svg', legacy: '/keep.svg' })
  const built = reviewBuild(opened, reviewChoice())
  const saved = ConfigModel.iconChangeIntent(opened, built.args)
  assert.equal(saved.ok, true)
  assert.equal(saved.settings.iconOverrides[reviewApp], 'file:///icons/new.svg')
  assert.equal(saved.settings.iconOverrides.legacy, '/keep.svg')
  const noChange = reviewBuild(opened, reviewChoice({ source: '/icons/app.svg' }))
  assert.equal(ConfigModel.iconChangeIntent(opened, noChange.args).changedKeys.length, 0)
})
test('review: title rename to an absent destination preserves order', () => {
  const opened = reviewConfig({}, [reviewRule('solar'), reviewRule('lunar')])
  const built = reviewBuild(opened, reviewChoice({ kind: 'window', titleText: 'sol' }),
    { appId: reviewApp, title: 'solar' })
  const saved = ConfigModel.iconChangeIntent(opened, built.args)
  assert.equal(saved.ok, true)
  assert.deepEqual(Array.from(saved.settings.windowIconOverrides, r => r.titlePattern), ['*sol*', '*lunar*'])
  expectConflict(opened, reviewConfig({}, [...opened.windowIconOverrides, reviewRule('sol')]),
    reviewChoice({ kind: 'window', titleText: 'sol' }), { appId: reviewApp, title: 'solar' })
})

function savedPreview(opened, choice, list, target = {}) {
  const built = reviewBuild(opened, choice, target)
  assert.equal(built.ok, true)
  const saved = ConfigModel.iconChangeIntent(opened, built.args)
  assert.equal(saved.ok, true)
  const current = DockIconModel.currentIconTarget({ settings: opened,
    desktopId: choice.desktopId, profileKey: choice.profileKey, ...target })
  const selection = choice.source ? choice : { ...current, profileKey: choice.profileKey, source: '' }
  assert.equal(typeof DockIconModel.previewIconChanges, 'function', 'production preview resolver exists')
  const preview = DockIconModel.previewIconChanges(opened, saved.settings, list, choice.desktopId, selection)
  const actual = list.map(window => DockIconModel.currentIconTarget({
    settings: saved.settings, desktopId: choice.desktopId, ...window }))
  assert.deepEqual(plain(preview.rows.map(row => row.after)), plain(actual),
    'every preview row resolves from the actual saved settings')
  assert.equal(preview.changed, preview.rows.filter(row => row.before.source !== row.after.source).length)
  return preview
}
test('review: Default reveals the underlying app icon in preview and wording', () => {
  const opened = reviewConfig({ [reviewApp]: '/icons/app.svg' }, [reviewRule('solar')])
  const preview = savedPreview(opened, reviewChoice({ source: '' }),
    [{ appId: reviewApp, title: 'solar' }, { appId: reviewApp, title: 'htop' }],
    { appId: reviewApp, title: 'solar' })
  assert.equal(preview.changed, 1)
  assert.equal(preview.rows[0].after.kind, 'app')
  assert.equal(preview.rows[0].after.source, 'file:///icons/app.svg')
  const text = DockIconModel.previewSummary({ ...preview, total: 2, resetting: true, appName: 'Ghostty' })
  assert.match(text, /Ghostty's custom icon/)
  assert.doesNotMatch(text, /app's own icon/)
})
test('review: Default reveals an underlying browser-profile override', () => {
  const opened = reviewConfig({ [reviewChrome + '@profile:Profile 1']: '/icons/profile.svg' },
    [reviewRule('mail', '/icons/mail.svg', reviewChrome)])
  const list = [{ appId: reviewChrome, profileKey: 'Profile 1', title: 'mail' }]
  const preview = savedPreview(opened, reviewChoice({ source: '', desktopId: reviewChrome,
    appId: reviewChrome, profileKey: 'Profile 1' }), list, list[0])
  assert.equal(preview.rows[0].after.kind, 'profile')
  assert.equal(preview.changed, 1)
})
test('review: app-wide selection preserves title and profile overrides', () => {
  const opened = reviewConfig({ [reviewChrome + '@profile:Profile 1']: '/icons/profile.svg' },
    [reviewRule('mail', '/icons/mail.svg', reviewChrome)])
  const preview = savedPreview(opened, reviewChoice({ desktopId: reviewChrome, appId: reviewChrome }), [
    { appId: reviewChrome, title: 'mail' },
    { appId: reviewChrome, title: 'news', profileKey: 'Profile 1' },
    { appId: reviewChrome, title: 'search' }
  ])
  assert.equal(preview.changed, 1)
  assert.equal(preview.shadowed, 2)
  assert.deepEqual(Array.from(preview.rows, row => row.changed), [false, false, true])
  assert.match(DockIconModel.previewSummary({ ...preview, total: 3, appName: 'Chrome' }),
    /2 keep their own title-rule\/profile icon/)
})
test('review: profile-wide selection remains shadowed by a title rule', () => {
  const opened = reviewConfig({}, [reviewRule('mail', '/icons/mail.svg', reviewChrome)])
  const preview = savedPreview(opened, reviewChoice({ kind: 'profile', desktopId: reviewChrome,
    appId: reviewChrome, profileKey: 'Profile 1' }), [
    { appId: reviewChrome, title: 'mail', profileKey: 'Profile 1' },
    { appId: reviewChrome, title: 'news', profileKey: 'Profile 1' },
    { appId: reviewChrome, title: 'news', profileKey: 'Profile 2' }
  ])
  assert.equal(preview.changed, 1)
  assert.equal(preview.shadowed, 1)
})
test('review: mixed raw app IDs count only the actual title-rule matches', () => {
  const list = [{ appId: reviewApp, title: 'solar' }, { appId: 'foot', title: 'solar' }]
  const choice = reviewChoice({ kind: 'window', titleText: 'solar', titlePattern: '*solar*' })
  assert.equal(DockIconModel.previewMatches(list, choice).count, 1)
  const preview = savedPreview(reviewConfig(), choice, list)
  assert.equal(preview.changed, 1)
  assert.deepEqual(Array.from(preview.rows, row => row.inScope), [true, false])
  const wide = savedPreview(reviewConfig(), reviewChoice(), list)
  assert.equal(wide.changed, 2, 'app scope is not narrowed to a raw Wayland app ID')
})
test('review: a retained earlier title rule is represented rather than overwritten in preview', () => {
  const opened = reviewConfig({}, [reviewRule('s', '/icons/first.svg')])
  const preview = savedPreview(opened, reviewChoice({ kind: 'window', titleText: 'solar',
    titlePattern: '*solar*' }), [{ appId: reviewApp, title: 'solar' }])
  assert.equal(preview.changed, 0)
  assert.equal(preview.rows[0].after.source, 'file:///icons/first.svg')
})
test('review: structured validation errors reach the dialog instead of a generic patch error', () => {
  const d = dialogHarness()
  d.mutationController = { saveIconChange: () => ({ ok: false,
    error: { code: 'E_VALIDATION', message: 'Patch rejected; no values were changed.' },
    data: { validationErrors: [{ message: 'Another title rule already uses “lunar”.' }] } }) }
  assert.equal(d.commit({}), false)
  assert.equal(d.inlineError, 'Another title rule already uses “lunar”.')
})


test('review lifecycle: reopening ignores a previous chooser without killing its process', () => {
  const d = dialogHarness()
  const options = { anchorItem: {}, desktopId: reviewApp, appId: reviewApp }
  d.settings = reviewConfig({ [reviewApp]: '/icons/original.svg' })
  assert.equal(d.openFor(options), true)
  d.chooseFile()
  const previousSerial = d.chooserLaunchSerial
  d.settings = reviewConfig({ [reviewApp]: '/icons/second.svg' })
  assert.equal(d.openFor(options), true)
  assert.notEqual(d.chooserSerial, previousSerial)
  assert.equal(d.picking, false)
  assert.equal(d.fileChooser.running, true, 'portal process is deliberately not killed')
  const selected = d.selectedSource
  const sources = [...d.imageSources]
  d.chooseFile()
  assert.equal(d.picking, false, 'cannot start another pick before old process exits')
  d.chooserOutput.text = '/icons/late.svg\n'
  d.chooserExitCode = 0
  d.chooserOutputDone = true
  d.fileChooser.running = false
  d.settleChooser()
  assert.equal(d.selectedSource, selected)
  assert.deepEqual([...d.imageSources], sources)
  assert.equal(d.visible, true)
  d.chooseFile()
  assert.equal(d.picking, true, 'new session can pick after old process exits')
})

test('review lifecycle: opening snapshot stays detached from mutable live settings', () => {
  const d = dialogHarness()
  d.settings = reviewConfig({ [reviewApp]: '/icons/a.svg' }, [reviewRule('solar')])
  d.openFor({ anchorItem: {}, desktopId: reviewApp, appId: reviewApp })
  d.settings.iconOverrides[reviewApp] = '/icons/new.svg'
  d.settings.windowIconOverrides[0].source = '/icons/new.svg'
  assert.equal(d.openedSettings.iconOverrides[reviewApp], '/icons/a.svg')
  assert.equal(d.openedSettings.windowIconOverrides[0].source, '/icons/rule.svg')
})


function ownedDialog(host) {
  const d = dialogHarness()
  d.mutationController = host
  Object.defineProperty(d, 'dialogActive', { get: () => d.visible || d.picking })
  return d
}
const ownershipOptions = () => ({ anchorItem: {}, desktopId: reviewApp, appId: reviewApp })

test('review ownership: a second item closes the previous editor and invalidates its chooser', () => {
  const { host } = hostHarness(reviewConfig())
  const a = ownedDialog(host), b = ownedDialog(host)
  a.openFor(ownershipOptions())
  assert.equal(host.activeIconDialog, vm.runInContext("root", a))
  a.chooseFile()
  const serial = a.chooserLaunchSerial
  const oldSource = a.selectedSource
  b.openFor(ownershipOptions())
  assert.equal(host.activeIconDialog, vm.runInContext("root", b))
  assert.equal(a.dialogActive, false)
  assert.notEqual(a.chooserSerial, serial)
  assert.equal(a.fileChooser.running, true, 'leave the old portal process to finish normally')
  a.chooserOutput.text = '/icons/late.svg\n'
  a.chooserExitCode = 0
  a.chooserOutputDone = true
  a.settleChooser()
  assert.equal(a.selectedSource, oldSource)
  assert.equal(a.visible, false)
  assert.equal(b.visible, true)
  a.closeDialog()
  assert.equal(host.activeIconDialog, vm.runInContext("root", b), 'late cleanup must not release the new session')
  b.closeDialog()
  assert.equal(host.activeIconDialog, null)
})

test('review ownership: reopening the same editor does not close its new session', () => {
  const { host } = hostHarness(reviewConfig())
  const d = ownedDialog(host)
  const options = ownershipOptions()
  d.openFor(options)
  d.chooseFile()
  d.openFor(options)
  assert.equal(d.visible, true)
  assert.equal(d.picking, false)
  assert.equal(host.activeIconDialog, vm.runInContext("root", d))
})

test('review ownership: native popup dismissal releases the editor and its anchor', () => {
  const { host } = hostHarness(reviewConfig())
  const d = ownedDialog(host)
  d.openFor(ownershipOptions())
  d.visible = false
  d.handleVisibilityChange()
  assert.equal(host.activeIconDialog, null)
  assert.equal(d.openAnchor, null)
  assert.equal(d.dialogActive, false)
})

test('review ownership: hiding for the portal preserves the editing session', () => {
  const { host } = hostHarness(reviewConfig())
  const d = ownedDialog(host)
  d.openFor(ownershipOptions())
  d.chooseFile()
  d.handleVisibilityChange()
  assert.equal(host.activeIconDialog, vm.runInContext("root", d))
  assert.equal(d.dialogActive, true)
  d.finishChoosing('')
  assert.equal(host.activeIconDialog, vm.runInContext("root", d))
  assert.equal(d.visible, true)
  assert.equal(d.picking, false)
})
