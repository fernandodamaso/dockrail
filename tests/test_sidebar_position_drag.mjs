import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { hostHarness, loadModel } from './host_harness.mjs';
import { qmlMethods } from './sidebar_interaction_fixture.mjs';

// The background drag switches each output's presentation independently:
// dragging the bottom dock's empty background left gives that monitor a
// sidebar override, dragging empty sidebar background down gives it back a
// classic override. Both renderers route their completed gesture through the
// one host-owned writer, guarded by a press-time token, so these tests
// exercise that behavior directly instead of matching source text: accepted
// writes happen exactly once and touch only the source connector, rejected
// intents (stale, busy, disconnected) never write, and feedback stays keyed to
// the connector the gesture started on.

const rootPath = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const read = name => fs.readFileSync(path.join(rootPath, name), 'utf8');
const ScreenPresentationModel = loadModel('DockScreenPresentationModel');

const harness = hostHarness({});
const { host, writes } = harness;
host.connectedScreens = [{ name: 'DP-1', width: 1920, height: 1080 },
  { name: 'DP-2', width: 1920, height: 1080 }];
host.hyprMonitors = [{ name: 'DP-1', x: 0 }, { name: 'DP-2', x: 1920 }];
host.sidebarState = { mappedScreens: host.connectedScreens, interactionBusy: false };
// A disconnected connector's entry must survive unrelated gestures untouched.
host.settings = { ...host.settings,
  presentationModeByMonitor: { 'HDMI-A-1': 'classic' } };
const modeWrites = () => writes.filter(text => /"presentationModeByMonitor"/.test(text));
const tokenFor = connector =>
  ScreenPresentationModel.modeGestureToken(host.currentPresentation(), connector);

// Accepted gesture: one presentationModeByMonitor write, empty feedback.
const token1 = tokenFor('DP-1');
assert.equal(host.handlePositionRequest('DP-1', 'left', 'bottom', token1), '',
  'an accepted mode gesture reports no failure');
assert.equal(modeWrites().length, 1, 'exactly one write per accepted gesture');
assert.match(modeWrites()[0],
  /"presentationModeByMonitor":\s*\{[^}]*"DP-1":\s*"sidebar"/,
  'a leftward dock drag gives this monitor a sidebar override');
assert.match(modeWrites()[0], /"HDMI-A-1":\s*"classic"/,
  'a gesture never drops disconnected or foreign entries');
assert.ok(!/"DP-2":/.test(modeWrites()[0]),
  'a gesture never touches another connected monitor');
assert.equal(host.modeGestureFeedbackFor('DP-1'), '',
  'an accepted write clears that connector feedback');

// A stale gesture (the mode changed after the press) is rejected without a write.
assert.match(host.handlePositionRequest('DP-1', 'left', 'bottom', token1),
  /Preferences were not saved/, 'a stale expected value is surfaced');
assert.equal(modeWrites().length, 1, 'a stale gesture never writes');
assert.notEqual(host.modeGestureFeedbackFor('DP-1'), '',
  'a rejected gesture leaves feedback for its own connector');
assert.equal(host.modeGestureFeedbackFor('DP-2'), '',
  'the rejection never displays on another monitor');
assert.equal(host.modeGestureDisplayFor('DP-2'), '',
  'another monitor displays nothing for the rejected gesture');

// A second stale gesture still adds no write: one intent per gesture, never a retry.
assert.match(host.handlePositionRequest('DP-1', 'left', 'bottom', token1),
  /Preferences were not saved/);
assert.equal(modeWrites().length, 1, 'repeated rejected gestures never write');

// Busy preflight (a save already in flight) is rejected without a write.
host.settingsWriteState = 'saving';
assert.match(host.handlePositionRequest('DP-1', 'left', 'bottom', tokenFor('DP-1')),
  /Preferences were not saved/, 'a busy writer is surfaced');
assert.equal(modeWrites().length, 1, 'a busy gesture never writes');
host.settingsWriteState = 'idle';

// A settings reload clears every connector's gesture failure and restores the
// configured overrides for the next gesture.
host.settingsFileLoaded(JSON.stringify(harness.defaults));
assert.equal(host.modeGestureFeedbackFor('DP-1'), '',
  'a settings reload clears gesture feedback');

// --- sidebar renderer: commitModeSwitch ----------------------------------
const sidebar = qmlMethods('DockSidebar.qml', {
  host, screen: { name: 'DP-1' }, DockModel: loadModel('DockModel') });

// A non-down position is ignored: no write and no feedback change.
sidebar.commitModeSwitch('left', tokenFor('DP-1'));
assert.equal(modeWrites().length, 1, 'a non-bottom position never commits a mode');
assert.equal(host.modeGestureFeedbackFor('DP-1'), '',
  'an ignored position leaves connector feedback untouched');

// A downward sidebar drag on this panel's connector switches it back.
sidebar.commitModeSwitch('bottom', tokenFor('DP-1'));
assert.equal(modeWrites().length, 2, 'a rejected or ignored switch never writes');
assert.equal(host.modeGestureFeedbackFor('DP-1'), '',
  'an accepted switch clears local error');
assert.match(modeWrites()[1], /"presentationModeByMonitor":\s*\{[^}]*"DP-1":\s*"classic"/,
  'a downward sidebar drag restores a classic override on that connector');

// The reverse host gesture flips the same connector again, nothing else.
assert.equal(host.handlePositionRequest('DP-1', 'left', 'bottom', tokenFor('DP-1')), '',
  'the mode flips to the sidebar for the reverse gesture');
assert.equal(modeWrites().length, 3);
assert.match(modeWrites()[2], /"presentationModeByMonitor":\s*\{[^}]*"DP-1":\s*"sidebar"/);

// An unsupported destination never writes (intent result, legacy shape).
const badDestination = host.handlePositionRequest('DP-1', 'top', 'bottom', tokenFor('DP-1'));
assert.equal(typeof badDestination, 'object',
  'an unsupported destination answers with an intent result');
assert.equal(badDestination.accepted, false);
assert.equal(modeWrites().length, 3, 'an unsupported destination never writes');

// A disconnected source connector can never commit, even with a fresh token.
const goneToken = tokenFor('DP-2');
host.connectedScreens = [host.connectedScreens[0]];
host.sidebarState = { mappedScreens: host.connectedScreens, interactionBusy: false };
assert.match(host.handlePositionRequest('DP-2', 'left', 'bottom', goneToken),
  /no longer connected/, 'a disconnected source connector is surfaced');
assert.equal(modeWrites().length, 3, 'a disconnected gesture never writes');
assert.notEqual(host.modeGestureFeedbackFor('DP-2'), '',
  'the disconnection report is keyed to the disconnected connector');
assert.equal(host.modeGestureFeedbackFor('DP-1'), '',
  'unrelated connectors keep their own (cleared) feedback');

// Persistence failures are host-wide: every connector reports them, with any
// connector-local rejection still leading its own message.
host.settingsSaveFailed(3);
assert.match(host.modeGestureDisplayFor('DP-1'),
  /^Unsaved preferences: Settings changed for this session, but could not be saved\./,
  'a connector with no local failure still reports the host-wide persistence error');
assert.match(host.modeGestureDisplayFor('DP-2'),
  /^Preferences were not saved:[\s\S]* · Unsaved preferences: /,
  'a local rejection leads, the host-wide persistence error follows');

// --- structural wiring that cannot be instantiated headless ---------------
const dockSource = read('components/Dock.qml');
const sidebarSource = read('components/DockSidebar.qml');
const surfaceSource = read('components/DockPositionDragSurface.qml');
const hostSource = read('DockHost.qml');

// The classic dock owns the panel-level surface and forwards its request with
// the press-time token for stale protection.
assert.match(dockSource, /DockPositionDragSurface\s*\{\s*id:\s*positionDragSurface/,
  'classic dock owns a position drag surface');
assert.match(dockSource,
  /root\.positionRequested\(position, expectedPosition, gestureToken\)/,
  'classic dock forwards position requests with the captured token');
assert.match(dockSource, /property string presentationMode:/,
  'classic dock accepts its owner-injected presentation mode');
assert.match(dockSource, /property var modeGestureToken: null/,
  'classic dock accepts its owner-injected press-time token');

// The surface captures connector state at press and emits the token on commit.
assert.match(surfaceSource,
  /signal positionRequested\(string position, var expectedPosition, var gestureToken\)/,
  'the surface emits the captured token as its third argument');
assert.match(surfaceSource, /capturedGestureToken = gestureToken/,
  'the surface captures the token when the pointer goes down');
assert.match(surfaceSource, /expectedPresentation/,
  'the surface still captures the presentation seen at press time');
assert.match(surfaceSource, /gestureCancelled/,
  'the surface can cancel without writing');

// The sidebar owns the reverse gesture plus the blank-tail surface, and both
// yield to menus, popups, resize and row drags.
assert.match(sidebarSource, /DockPositionDragSurface\s*\{\s*id:\s*positionDragSurface/,
  'sidebar owns a position drag surface');
assert.match(sidebarSource, /DockPositionDragSurface\s*\{\s*id:\s*viewportDragSurface/,
  'sidebar owns a blank-tail drag surface');
assert.match(sidebarSource, /dockPosition:\s*root\.sidebarEdge/,
  'sidebar drag surface starts from its configured gesture edge');
assert.match(sidebarSource, /interactionAllowed:\s*!root\.controller\.interactionBusy/,
  'sidebar gesture yields to menus, popups, resize and row drags');
assert.match(sidebarSource, /host\.commitMonitorModeGesture\(root\.screen\.name/,
  'the sidebar commits through its own connector');
assert.match(sidebarSource, /host\.modeGestureDisplayFor\(screen\.name\)/,
  'the sidebar reads per-connector feedback from the host');

// The host owns the single write and its connector-keyed feedback.
assert.match(hostSource,
  /function commitMonitorModeGesture\(connector, destination, capturedState, menuOrigin\)/,
  'host owns the monitor-scoped mode gesture writer');
assert.equal(
  (hostSource.match(/saveSettingIntent\("presentationModeByMonitor"/g) || []).length, 1,
  'there is exactly one presentationModeByMonitor writer in the host');
assert.doesNotMatch(hostSource, /saveSettingIntent\("presentationMode"|saveSettingIntent\("position"|function commitModeGesture\(/,
  'gestures never write the global mode or the position setting anymore');

console.log('sidebar position drag wiring tests passed');
