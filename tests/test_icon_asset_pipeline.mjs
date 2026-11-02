import assert from 'node:assert/strict'
import { hostHarness, loadModel, plain, read } from './host_harness.mjs'
import { qmlMethods } from './sidebar_interaction_fixture.mjs'

const icons = loadModel('DockIconModel')
const managed = 'file:///home/test/.local/share/dockrail/icons/' + 'a'.repeat(64) + '.png'
function dialogFixture() {
  const calls = []
  const mutationController = {
    saveIconChange(args) { calls.push(plain(args)); return {ok: true, data: {applied: true}} },
    releaseIconDialog() {},
  }
  const process = {running: false}
  const dialog = qmlMethods('DockIconDialog.qml', {
    mutationController, DockIconModel: icons, iconAssetIngest: process,
    iconAssetOutput: {text: JSON.stringify({source: managed})}, Qt: {callLater() {}},
    picking: false, ingesting: false, ingestSerial: 0, openAnchor: {},
    windows: [], chooserSerial: 0, selectedSource: '', inlineError: '',
    ingestExitCode: -1, ingestOutputDone: false,
  })
  return {dialog, calls, process}
}

// File ingestion is a required pre-commit gate, not a second settings writer.
const a = dialogFixture()
const set = {remove: null, set: {kind:'app',key:'editor',
  source:'file:///tmp/user-art.png',expected:''}}
assert.equal(a.dialog.commit(set), false)
assert.equal(a.dialog.ingesting, true)
assert.equal(a.process.running, true)
assert.equal(a.calls.length, 0, 'no host mapping before copy')
a.dialog.ingestExitCode = 0
a.dialog.ingestOutputDone = true
a.dialog.settleIconIngest()
assert.equal(a.calls.length, 1)
assert.equal(a.calls[0].set.source, managed)
assert.equal(a.dialog.ingesting, false)
assert.equal(a.dialog.openAnchor, null, 'successful save closes the session')

const failed = dialogFixture()
assert.equal(failed.dialog.commit(set), false)
failed.dialog.ingestExitCode = 2
failed.dialog.settleIconIngest()
assert.equal(failed.calls.length, 0, 'copy failure never saves a mapping')
assert.match(failed.dialog.inlineError, /could not copy/i)

const cancelled = dialogFixture()
assert.equal(cancelled.dialog.commit(set), false)
cancelled.dialog.closeDialog()
cancelled.dialog.ingestExitCode = 0
cancelled.dialog.ingestOutputDone = true
cancelled.dialog.settleIconIngest()
assert.equal(cancelled.calls.length, 0, 'closed editor ignores late copy result')

const reset = dialogFixture()
assert.equal(reset.dialog.commit({remove:{kind:'app',key:'editor',source:managed},set:null}),true)
assert.equal(reset.calls.length, 1, 'reset bypasses copy and uses host intent')

// Missing artwork is still removable: no file-existence check in the model.
const config = hostHarness({iconOverrides:{editor:'file:///missing/old-icon.png'}})
const before = config.host.settings.iconOverrides.editor
const removed = config.host.saveIconChange({
  remove:{kind:'app',key:'editor',source:before},set:null
})
assert.equal(removed.ok,true)
assert.deepEqual(plain(config.host.settings.iconOverrides),{})

const host = read('DockHost.qml'), dialog = read('components/DockIconDialog.qml')
const installer = read('install.sh'), cli = read('scripts/smartdock_cli.py')
assert.match(dialog,/Process \{\s*id: iconAssetIngest/)
assert.match(dialog,/root\.commitResult\(args\)/)
assert.match(dialog,/root\.ingesting = true[\s\S]*iconAssetIngest\.running = true/)
assert.match(host,/function startIconMigration\(/)
assert.match(host,/JSON\.stringify\(plan\.expected\.iconOverrides\)/)
assert.match(host,/saveSettings\(plan\.patch, false\)/)
assert.match(host,/function startIconCollect\(/)
assert.match(installer,/dockrail_icon_assets\.py/)
assert.match(cli,/module\.ingest\(source\)/)
console.log('FDM-1068 managed icon entrypoint and stale removal checks passed')
