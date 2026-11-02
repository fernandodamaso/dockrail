import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import vm from 'node:vm';
import { fileURLToPath } from 'node:url';
import { hostHarness, loadModel, plain } from './host_harness.mjs';

const base = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const read = name => fs.readFileSync(path.join(base, name), 'utf8');
const removed = ['DockSettings', 'DockSettingSlider', 'DockSettingsSection',
  'DockSettingsToggleRow', 'DockColorTokenDropdown', 'DockColorSwatch',
  'DockActionDropdown', 'DockHiddenApplicationRow'];
// Preserve the FDM-918 removal guard, while allowing the explicitly approved
// 3.1 Settings route and new typed-action components (FDM-1022).
const obsolete = /settingPreviews|previewSetting|clearSettingPreview|settingsPatchRequested|resetSettingsRequested|smartdock-settings|openIconEditor|DockSettingSlider|DockSettingsToggleRow|DockSettingsSection|DockColorTokenDropdown|DockColorSwatch|DockActionDropdown|DockHiddenApplicationRow/;
function files(directory) {
  if (!fs.existsSync(path.join(base, directory))) return [];
  return fs.readdirSync(path.join(base, directory), { withFileTypes: true }).flatMap(entry => {
    const name = path.posix.join(directory, entry.name);
    return entry.isDirectory() ? files(name) : [name];
  });
}
// Audit executable sources, including mixed tests and runtime fixtures. The two
// removal audits name forbidden components as test data, not executable imports.
const active = ['DockHost.qml', 'shell.qml', 'Overlay.qml', ...files('components'),
  ...files('scripts'), ...files('tests'), ...files('local-tests')].filter(name =>
  /\.(qml|js|mjs|py|sh)$/.test(name) && !/\/test_settings_(cutover|helpers)\.mjs$/.test(name));
const references = active.flatMap(name => read(name).split('\n').flatMap((line, index) =>
  obsolete.test(line) ? [`${name}:${index + 1}: ${line.trim()}`] : []));
if (references.length) console.log('Settings cutover reference audit:\n' + references.join('\n'));
assert.deepEqual(references, [], 'No active Settings routes, dependencies, or removed-component imports remain');
for (const name of removed)
  assert.equal(fs.existsSync(path.join(base, 'components', name + '.qml')), false, name);
assert.equal(fs.existsSync(path.join(base, 'tests/run_action_dropdown_settings.sh')), false);

const dock = read('components/Dock.qml');
const host = read('DockHost.qml');
const menu = read('components/DockContextMenu.qml');
const controlItem = read('components/DockControlItem.qml');
assert.doesNotMatch(dock, /previewSetting|clearSettingPreview|signal settingChanged|signal settingsPatchRequested|signal resetSettingsRequested/);
assert.doesNotMatch(host, /onSettingChanged|onSettingsPatchRequested|onResetSettingsRequested|function resetSettings\(/);
// Execute the production reload callback: cancel before refreshing presentation.
const settingsChanged = dock.match(/^  onSettingsChanged: \{(.*)\}$/m)?.[1];
assert.ok(settingsChanged);
const reloadCalls = [];
vm.runInNewContext(settingsChanged, { root: {
  cancelGroupedPinReorder() { reloadCalls.push(['cancel-pin-drag']); },
  cancelWorkspaceGesture(reason) { reloadCalls.push(['cancel', reason]); },
  scheduleVisibleItemsRefresh() { reloadCalls.push(['refresh']); },
} });
assert.deepEqual(reloadCalls, [['cancel-pin-drag'], ['cancel', 'settings changed'], ['refresh']]);
assert.match(dock, /onApplicationSelected: desktopId => root\.pinRequested\(desktopId\)/);
for (const component of ['DockWindowPreview', 'DockAppPicker', 'DockTrashItem', 'DockWorkspaceStrip'])
  assert.match(dock, new RegExp('\\b' + component + '\\s*\\{'));
for (const token of ['"accent": Color.accent', '"menu.background": Color.menu.background',
  '"menu.border": Color.menu.border']) assert.ok(dock.includes(token), token);
for (const action of ['launcher', 'add', 'auto-hide'])
  assert.ok(menu.includes('"' + action + '"'), action);
assert.match(controlItem, /onAddApplication: root\.addApplicationRequested\(\)/);
assert.match(controlItem, /onToggleAutoHide: root\.autoHideToggled\(!root\.autoHide\)/);
assert.match(dock, /onAddApplicationRequested: root\.openAppPicker\(controlItem\)/);
assert.doesNotMatch(dock, /DockAddPinItem/);
assert.match(dock, /onAutoHideToggled: enabled => root\.autoHideRequested\(enabled\)/);
assert.match(host, /onAutoHideRequested: enabled => root\.saveSetting\("autoHide", enabled\)/);
assert.equal((host.match(/configFile\.setText\(/g) || []).length, 1, 'Keep the single host writer');

// Execute the actual auto-hide expression and method without a Settings object.
// This is a model/signal-routing check, not real compositor scheduling evidence.
const expression = dock.match(/readonly property bool keepAutoHideOpen: ([\s\S]*?)(?=\n  readonly property)/)?.[1];
const update = dock.match(/^  function updateAutoHideState\(\) \{[\s\S]*?^  }/m)?.[0];
assert.ok(expression && update);
let stops = 0, restarts = 0;
const scope = vm.createContext({
  windowPointer: { hovered: false }, appPicker: { visible: false },
  windowPreview: { interactionActive: false }, positionDragSurface: { pressed: false },
  openMenuCount: 0, dragSource: -1, groupedPinSourceId: "",
  autoHide: true, autoHideRevealed: false, workspaceDragActive: false,
  workspaceMonitorDragSourceActive: false, dragRevealed: false,
  hideTimer: { stop() { stops++; }, restart() { restarts++; } },
});
scope.root = scope;
Object.defineProperty(scope, 'keepAutoHideOpen', { get: () => vm.runInContext('(' + expression + ')', scope) });
vm.runInContext(update, scope);
assert.equal(scope.keepAutoHideOpen, false);
for (const [object, key, value] of [[scope.windowPointer, 'hovered', true],
  [scope.appPicker, 'visible', true], [scope.windowPreview, 'interactionActive', true],
  [scope, 'openMenuCount', 1], [scope, 'dragSource', 0],
  [scope, 'groupedPinSourceId', 'org.A'],
  [scope, 'workspaceDragActive', true], [scope.positionDragSurface, 'pressed', true],
  [scope, 'workspaceMonitorDragSourceActive', true], [scope, 'dragRevealed', true]]) {
  const old = object[key];
  object[key] = value;
  scope.updateAutoHideState();
  assert.equal(scope.keepAutoHideOpen, true, key);
  assert.equal(scope.autoHideRevealed, true, key);
  object[key] = old;
  scope.updateAutoHideState();
  assert.equal(scope.keepAutoHideOpen, false, key);
}
assert.equal(stops, 10);
assert.equal(restarts, 10);
scope.autoHide = false;
scope.updateAutoHideState();
assert.equal(scope.autoHideRevealed, false);
assert.equal(stops, 11);

// Requested values still reach the actual dock normalizers after preview state
// is removed. Evaluate production binding expressions, not a copied normalizer.
const bindings = vm.createContext({ settings: { iconSize: 48, hoverGlowOpacity: .72,
  autoHide: true, reserveSpace: true }, DockModel: loadModel('DockModel') });
for (const name of ['iconSize', 'hoverGlowOpacity', 'autoHide', 'reserveSpace']) {
  const expression = dock.match(new RegExp('readonly property \\w+ ' + name + ': ([\\s\\S]*?)(?=\\n  (?:readonly|property|//))'))?.[1];
  assert.ok(expression, name);
  bindings[name] = vm.runInContext('(' + expression + ')', bindings);
}
assert.equal(bindings.iconSize, 48);
assert.equal(bindings.hoverGlowOpacity, .70);
assert.equal(bindings.reserveSpace, false);

const h = hostHarness({ pinned: ['Code', 'Unavailable.App'], hiddenApplications: ['Code'],
  iconOverrides: { code: 'file:///tmp/kept.svg' }, extension: { keep: true } });
assert.equal(h.request('apps.show', { id: 'code.desktop' }).ok, true);
assert.deepEqual(plain(h.host.settings.pinned), ['Code', 'Unavailable.App']);
assert.deepEqual(plain(h.host.settings.iconOverrides), { code: 'file:///tmp/kept.svg' });
assert.deepEqual(plain(h.host.settings.extension), { keep: true });
assert.deepEqual(plain(h.host.settings.hiddenApplications), []);
for (const command of ['config.apply', 'config.reset', 'apps.show', 'apps.move', 'icons.set', 'icons.reload'])
  assert.ok(h.metadata.commands.includes(command), command);
console.log('Settings cutover, live theme bindings, retained actions and auto-hide behavior: PASS');
