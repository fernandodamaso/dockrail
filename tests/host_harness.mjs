// Run production JS and QML method bodies, substituting unavailable host services only.
import assert from 'node:assert/strict';
import fs from 'node:fs';
import vm from 'node:vm';
export const read = name => fs.readFileSync(new URL('../' + name, import.meta.url), 'utf8');
export const plain = value => JSON.parse(JSON.stringify(value));
export function loadModel(name) {
  const source = read('components/' + name + '.js');
  const context = vm.createContext({ console });
  for (const match of source.matchAll(/^\.import "([^"]+)\.js" as (\w+)$/gm))
    context[match[2]] = loadModel(match[1]);
  vm.runInContext(source.replace(/^\.(?:pragma|import).*$/gm, ''), context, { filename: name });
  return context;
}
function functions(name, state) {
  const context = vm.createContext(state);
  context.root = context;
  const blocks = read(name).match(/^  function [\s\S]*?^  }/gm);
  assert.ok(blocks?.length, name);
  vm.runInContext(blocks.join('\n'), context, { filename: name });
  return context;
}
export function hostHarness(settings, applications = []) {
  const defaults = JSON.parse(read('config/dock.json'));
  const metadata = JSON.parse(read('config/settings-schema.json'));
  const shared = { console: { warn() {} }, ConfigModel: loadModel('DockConfigModel'),
    DockIconModel: loadModel('DockIconModel'),
    DockModel: loadModel('DockModel'), DockWindowModel: loadModel('DockWindowModel'),
    WorkspaceGroupModel: loadModel('DockWorkspaceGroupModel'),
    SidebarModel: loadModel('DockSidebarModel'),
    SidebarWidgetModel: loadModel('DockSidebarWidgetModel'),
    ScreenPresentationModel: loadModel('DockScreenPresentationModel'),
    TrashModel: loadModel('DockTrashModel') };
  const writes = [];
  let cached = '', host;
  const fault = { save: false, defer: false };
  const configFile = {
    get cachedText() { return cached; },
    setText(text) {
      cached = text;
      writes.push(text);
      if (fault.defer) return;
      if (fault.save) host.settingsSaveFailed(3);
      else host.settingsSaved();
    },
    reload() { throw new Error('Unexpected fixture reload'); },
  };
  const sidebarWidgetRegistry = {
    'herdr.agents': {
      id: 'herdr.agents', label: 'Coding agents', available: true,
      acquire() { return { setActive() {}, release() {} }; },
    },
    't3.threads': {
      id: 't3.threads', label: 'T3 Code threads', available: true,
      acquire() { return { setActive() {}, release() {} }; },
    },
  };
  host = functions('DockHost.qml', { ...shared, configFile, applications, sidebarWidgetRegistry,
    Qt: { callLater() {} }, FileViewError: { FileNotFound: 2, toString: String },
    runtimeMode: 'plugin', configPath: '/fixture/dock.json',
    settings: plain(defaults), settingsLoaded: true, settingsRevision: 0, iconReloadRevision: 0,
    settingsLoadState: 'loaded', settingsLoadError: '', settingsReloadPending: false,
    settingsWriteState: 'idle', settingsWriteError: '', settingsPersisted: true,
    settingsDefaultsInUse: false, showTrash: false, showTrashSetting: false,
    settingsLoadedText: '', settingsWriteBaseText: '', settingsWriteText: '',
    // Presentation inputs read by currentPresentation()/gesture functions.
    connectedScreens: [], hyprMonitors: [],
    sidebarState: { mappedScreens: [], interactionBusy: false },
    modeGestureFeedbackByMonitor: ({}) });
  const control = functions('components/DockControl.qml', {
    ...shared, host, defaults, metadata, Quickshell: { processId: 123 } });
  host.dockControl = control;
  host.settingsFileLoaded(JSON.stringify({ ...defaults, ...settings }));
  const request = (command, args = {}) => plain(control.handle(JSON.stringify({
    apiVersion: 1, command, arguments: args })));
  return { host, control, request, writes, fault, defaults, metadata };
}
