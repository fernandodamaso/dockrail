import assert from 'node:assert/strict'
import {hostHarness, plain} from './host_harness.mjs'

const {host, request, writes} = hostHarness({})
host.connectedScreens = [{name: 'DP-1'}, {name: 'DP-2'}]
host.hyprMonitors = [{name: 'DP-1', x: 0}, {name: 'DP-2', x: 1920}]
host.sidebarState = {mappedScreens: host.connectedScreens, interactionBusy: false}
host.settings = {...host.settings,
  presentationModeByMonitor: {'DP-1': 'sidebar', 'HDMI-A-1': 'classic'}}
host.focusedHyprlandMonitor = {name: 'DP-2'}
let reply = request('mode.toggle')
assert.equal(reply.ok, true)
assert.deepEqual(reply.data.modeSwitch, {connector: 'DP-2', from: 'classic', to: 'sidebar'})
assert.deepEqual(plain(host.settings.presentationModeByMonitor), {
  'DP-1': 'sidebar', 'DP-2': 'sidebar', 'HDMI-A-1': 'classic'
})
assert.equal(writes.length, 1)
assert.equal(reply.data.persisted, true)

reply = request('mode.toggle')
assert.equal(reply.ok, true)
assert.equal(reply.data.modeSwitch.to, 'classic')
assert.equal(host.settings.presentationModeByMonitor['DP-1'], 'sidebar')
assert.equal(host.settings.presentationModeByMonitor['DP-2'], 'classic')
assert.equal(writes.length, 2)

host.focusedHyprlandMonitor = {name: 'DP-1'}
reply = request('mode.toggle')
assert.equal(reply.ok, true)
assert.equal(host.settings.presentationModeByMonitor['DP-1'], 'classic')
assert.equal(host.settings.presentationModeByMonitor['DP-2'], 'classic')
assert.equal(host.settings.presentationModeByMonitor['HDMI-A-1'], 'classic')
assert.equal(writes.length, 3)

host.focusedHyprlandMonitor = null
reply = request('mode.toggle')
assert.equal(reply.ok, false)
assert.equal(reply.error.code, 'E_RUNTIME_NOT_FOUND')
assert.equal(writes.length, 3, 'missing focus must never select a fallback screen')

host.focusedHyprlandMonitor = {name: 'DP-404'}
reply = request('mode.toggle')
assert.equal(reply.ok, false)
assert.equal(reply.error.code, 'E_STALE')
assert.equal(writes.length, 3, 'disconnected output must not mutate state')

reply = request('mode.toggle', {connector: 'DP-1'})
assert.equal(reply.ok, false)
assert.equal(reply.error.code, 'E_USAGE')
assert.equal(writes.length, 3, 'IPC cannot inject the monitor target')

const pending = hostHarness({})
pending.host.connectedScreens = [{name: 'DP-1'}]
pending.host.hyprMonitors = [{name: 'DP-1', x: 0}]
pending.host.sidebarState = {mappedScreens: pending.host.connectedScreens, interactionBusy: false}
pending.host.focusedHyprlandMonitor = {name: 'DP-1'}
pending.fault.defer = true
reply = pending.request('mode.toggle')
assert.equal(reply.ok, false)
assert.equal(reply.error.code, 'E_BUSY')
assert.equal(reply.data.applied, true)
assert.equal(reply.data.persisted, false)
assert.equal(pending.writes.length, 1)
reply = pending.request('mode.toggle')
assert.equal(reply.error.code, 'E_BUSY')
assert.equal(reply.data.modeSwitch, undefined, 'rejected intent must not claim a switch')
assert.equal(pending.writes.length, 1, 'repeated shortcut is rejected while saving')

const failed = hostHarness({})
failed.host.connectedScreens = [{name: 'DP-1'}, {name: 'DP-2'}]
failed.host.hyprMonitors = [{name: 'DP-1', x: 0}, {name: 'DP-2', x: 1920}]
failed.host.sidebarState = {mappedScreens: failed.host.connectedScreens, interactionBusy: false}
failed.host.focusedHyprlandMonitor = {name: 'DP-1'}
failed.fault.save = true
reply = failed.request('mode.toggle')
assert.equal(reply.ok, false)
assert.equal(reply.error.code, 'E_PERSISTENCE')
assert.equal(reply.data.persisted, false)
assert.match(failed.host.modeGestureDisplayFor('DP-1'), /Unsaved preferences/)
assert.equal(failed.host.modeGestureDisplayFor('DP-2'), '',
  'shortcut save failure must not show on other monitors')
console.log('focused monitor mode toggle: PASS')
