import assert from 'node:assert/strict'
import { hostHarness, loadModel } from './host_harness.mjs'
import { qmlMethods } from './sidebar_interaction_fixture.mjs'

const DockMenuModel = loadModel('DockMenuModel')
const DockModel = loadModel('DockModel')
const ScreenPresentationModel = loadModel('DockScreenPresentationModel')
const { host, writes } = hostHarness({})
host.connectedScreens = [{ name: 'DP-1' }, { name: 'DP-2' }]
host.hyprMonitors = [{ name: 'DP-1', x: 0 }, { name: 'DP-2', x: 1920 }]
host.sidebarState = { mappedScreens: host.connectedScreens, interactionBusy: false }
host.settings = { ...host.settings,
  presentationModeByMonitor: { 'DP-2': 'sidebar', 'HDMI-A-1': 'classic' } }

const tokenFor = connector => ScreenPresentationModel.modeGestureToken(
  host.currentPresentation(), connector)
const modeWrites = () => writes.filter(text => /"presentationModeByMonitor"/.test(text))
const classicPopup = { modeSwitchToken: null, opened: 0,
  open() { this.opened++ } }
const classicControl = qmlMethods('DockControlItem.qml', {
  contextMenu: classicPopup, modeGestureToken: tokenFor('DP-1')
})
classicControl.openControlsMenu()
assert.equal(classicPopup.opened, 1)
assert.equal(classicPopup.modeSwitchToken.connector, 'DP-1',
  'the dock menu captures its own connector token when opened')

const sidebarPopup = { modeSwitchToken: null, opened: 0,
  open() { this.opened++ } }
const headerButton = { visible: true }
const sidebarPanel = qmlMethods('DockSidebar.qml', {
  host, screen: { name: 'DP-1' }, controller: { interactionBusy: false },
  headerMenuButton: headerButton, sidebarContext: sidebarPopup,
  modeGestureToken: tokenFor('DP-1')
})
assert.equal(sidebarPanel.openHeaderMenu(), true)
assert.equal(sidebarPopup.opened, 1)
assert.equal(sidebarPanel.menuAnchor, headerButton)
assert.equal(sidebarPopup.modeSwitchToken.connector, 'DP-1',
  'the sidebar header menu captures its own connector token when opened')

let switchObservedDismissed = false
const menu = qmlMethods('DockContextMenu.qml', {
  DockMenuModel, DockModel, controlItem: true, sidebarHeaderMenu: false,
  autoHide: false, sidebarMode: false, page: 'controls',
  pageStack: [], herdrMenuRecords: [], activeMenuIndex: -1,
  setActiveMenuIndex() {}, dismiss() {},
  switchPresentationRequested(destination, token) {
    switchObservedDismissed = menu.visible === false
    host.commitMonitorModeMenu('DP-1', destination, token)
  }
})
Object.defineProperty(menu, 'pageActions', {
  get() { return menu.baselinePageActions() }
})

function selectSwitch(expectedText, expectedIcon, expectedDestination) {
  menu.visible = true
  const records = menu.baselinePageActions()
  const action = records.find(record => record.command === 'switch-presentation')
  assert.ok(action, 'the active presentation menu exposes a switch action')
  assert.equal(action.text, expectedText)
  assert.equal(action.iconName, expectedIcon)
  assert.equal(action.destination, expectedDestination)
  assert.equal(DockMenuModel.isFocusable(action), true,
    'the switch action participates in the existing keyboard cursor')
  assert.equal(menu.dispatchAction(action, records.indexOf(action)), true)
  assert.equal(switchObservedDismissed, true,
    'the originating popup closes before its surface can be replaced')
}

menu.modeSwitchToken = tokenFor('DP-1')
selectSwitch('Switch to sidebar', 'panel-left-open', 'sidebar')
assert.equal(modeWrites().length, 1, 'one menu activation writes once')
assert.deepEqual(JSON.parse(modeWrites()[0]).presentationModeByMonitor,
  { 'DP-1': 'sidebar', 'DP-2': 'sidebar', 'HDMI-A-1': 'classic' },
  'the menu retains other connected and disconnected connector overrides')

menu.controlItem = false
menu.sidebarHeaderMenu = true
menu.sidebarMode = true
menu.modeSwitchToken = tokenFor('DP-1')
selectSwitch('Switch to dock', 'panel-bottom', 'classic')
assert.equal(modeWrites().length, 2, 'the reverse menu activation writes once')
assert.deepEqual(JSON.parse(modeWrites()[1]).presentationModeByMonitor,
  { 'DP-1': 'classic', 'DP-2': 'sidebar', 'HDMI-A-1': 'classic' })

const staleToken = menu.modeSwitchToken
selectSwitch('Switch to dock', 'panel-bottom', 'classic')
assert.equal(modeWrites().length, 2, 'a stale menu action does not write')
assert.match(host.modeGestureFeedbackFor('DP-1'), /Preferences were not saved/)
assert.equal(host.modeGestureDisplayFor('DP-2'), '',
  'the existing feedback for a rejected action stays on its source monitor')

const single = hostHarness({})
single.host.connectedScreens = [{ name: 'DP-1' }, { name: 'DP-2' }]
single.host.hyprMonitors = [{ name: 'DP-1', x: 0 }, { name: 'DP-2', x: 1920 }]
single.host.sidebarState = { mappedScreens: single.host.connectedScreens,
  interactionBusy: false }
single.host.commitMonitorModeMenu('DP-1', 'sidebar',
  ScreenPresentationModel.modeGestureToken(single.host.currentPresentation(), 'DP-1'))
assert.deepEqual(JSON.parse(single.writes[0]).presentationModeByMonitor,
  { 'DP-1': 'sidebar' }, 'an empty override map gains only the source connector')

const failed = hostHarness({})
failed.host.connectedScreens = [{ name: 'DP-1' }, { name: 'DP-2' }]
failed.host.hyprMonitors = [{ name: 'DP-1', x: 0 }, { name: 'DP-2', x: 1920 }]
failed.host.sidebarState = { mappedScreens: failed.host.connectedScreens,
  interactionBusy: false }
failed.fault.save = true
const failedToken = ScreenPresentationModel.modeGestureToken(
  failed.host.currentPresentation(), 'DP-1')
failed.host.commitMonitorModeMenu('DP-1', 'sidebar', failedToken)
assert.equal(failed.writes.length, 1)
assert.match(failed.host.modeGestureDisplayFor('DP-1'), /Unsaved preferences/)
assert.equal(failed.host.modeGestureDisplayFor('DP-2'), '',
  'a failed menu persistence write is displayed on its origin only')
const dragToken = ScreenPresentationModel.modeGestureToken(
  failed.host.currentPresentation(), 'DP-2')
failed.host.handlePositionRequest('DP-2', 'left', 'bottom', dragToken)
assert.match(failed.host.modeGestureDisplayFor('DP-2'), /Unsaved preferences/,
  'a later drag retains the existing host-wide persistence feedback')

console.log('presentation menu model and monitor-scoped writes: PASS')
