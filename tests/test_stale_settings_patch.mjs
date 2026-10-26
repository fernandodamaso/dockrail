import assert from 'node:assert/strict';
import { hostHarness, plain } from './host_harness.mjs';

// Run DockHost.qml's *production* method bodies through the existing writer
// harness. Only FileView is substituted; patch validation/commit are real.
const host = hostHarness({ extensionData: {opaque:['keep', 17]} });
const before = plain(host.host.settings);
const first = host.host.saveSettingsIntent(
  {backgroundColorEnabled:true, backgroundColor:'#112233'},
  {backgroundColorEnabled:before.backgroundColorEnabled,
   backgroundColor:before.backgroundColor});
assert.equal(first.accepted, true);
assert.equal(first.pending, false);
assert.equal(first.reply.ok, true);
assert.equal(host.host.settingsPersisted, true);
assert.equal(host.host.settings.backgroundColor, '#112233');
assert.deepEqual(plain(host.host.settings.extensionData), {opaque:['keep', 17]});
assert.equal(host.request('config.get',{key:'backgroundColor'}).data.settings.backgroundColor,'#112233');

const changes = host.writes.length;
const old = plain(host.host.settings);
const cli = host.request('config.apply',{patch:{backgroundColor:'#334455'},dryRun:false});
assert.equal(cli.ok,true);
const stale = host.host.saveSettingsIntent(
  {backgroundColorEnabled:false,backgroundColor:'#556677'},
  {backgroundColorEnabled:old.backgroundColorEnabled,backgroundColor:old.backgroundColor});
assert.equal(stale.accepted,false);
assert.equal(stale.pending,false);
assert.equal(stale.reply.error.code,'E_STALE');
assert.equal(stale.reply.data.key,'backgroundColor');
assert.equal(host.writes.length,changes+1, 'stale patch cannot schedule another writer call');
assert.equal(host.host.settings.backgroundColor,'#334455');
assert.equal(host.host.settings.backgroundColorEnabled,true);

const missingExpected = host.host.saveSettingsIntent(
  {borderWidth:2,borderWidthEnabled:true},{borderWidth:old.borderWidth});
assert.equal(missingExpected.accepted,false);
assert.equal(missingExpected.reply.error.code,'E_VALIDATION');
assert.equal(host.host.settings.borderWidth,old.borderWidth);

const invalid = host.host.saveSettingsIntent(
  {iconSize:-5},{iconSize:host.host.settings.iconSize});
assert.equal(invalid.accepted,false);
assert.equal(invalid.reply.error.code,'E_VALIDATION');

host.fault.defer = true;
const pending = host.host.saveSettingsIntent(
  {borderWidth:3,borderWidthEnabled:true},
  {borderWidth:host.host.settings.borderWidth,
   borderWidthEnabled:host.host.settings.borderWidthEnabled});
assert.equal(pending.accepted,true,'applied values count as accepted even if FileView is saving');
assert.equal(pending.pending,true,'E_BUSY from the accepted write is a pending save');
assert.equal(pending.reply.error.code,'E_BUSY');
assert.equal(host.host.settings.borderWidth,3);
assert.equal(host.host.settingsWriteState,'saving');
const blocked = host.host.saveSettingsIntent({iconSize:64},{iconSize:host.host.settings.iconSize});
assert.equal(blocked.accepted,false,'new mutation is blocked while one accepted write is pending');
assert.equal(blocked.pending,false);
assert.equal(blocked.reply.error.code,'E_BUSY');
host.fault.defer = false;
host.host.settingsSaved();
assert.equal(host.host.settingsWriteState,'saved');
assert.equal(host.host.settingsPersisted,true);
assert.equal(host.request('config.get',{key:'borderWidth'}).data.settings.borderWidth,3);

const structuralExpected = plain(host.host.settings);
const opaque = host.host.saveSettingsIntent(
  {presentationModeByMonitor:{'DP-1':'sidebar'}},
  {presentationModeByMonitor:plain(structuralExpected.presentationModeByMonitor)});
assert.equal(opaque.accepted,true,'equal but different object instances are not stale');
assert.equal(opaque.reply.ok,true);
assert.deepEqual(plain(host.host.settings.presentationModeByMonitor),{'DP-1':'sidebar'});
console.log('Stale-safe multi-key host writes, CLI races, busy saves and durable readback passed');
