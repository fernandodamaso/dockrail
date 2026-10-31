import assert from 'node:assert/strict'
import { read } from './host_harness.mjs'
import { qmlMethods } from './sidebar_interaction_fixture.mjs'

// Exercise actual Dock.qml methods with the grouped global-launcher geometry.
const emitted = []
const h = qmlMethods('Dock.qml', {
  grouped:true, workspaceDragActive:false, dragSource:-1, dragTarget:-1,
  groupedPinSourceId:'', groupedPinTargetId:'', groupedPinOrder:[],
  itemSize:48, iconSize:32, pinnedIconGap:24,
  workspacePresentation:{globalLaunchers:[
    {desktopId:'org.A'}, {desktopId:'org.B'}, {desktopId:'org.C'}
  ]},
  groupedPinRepeater:{
    itemAt(index) { return [{x:0,width:48},{x:56,width:48},{x:112,width:48}][index] }
  },
  windowPreview:{dismissImmediately(){}},
  reorderRequested(source,target) { emitted.push([source,target]) }
})
assert.equal(h.groupedPinIndex('org.B'), 1)
assert.equal(h.beginGroupedPinReorder('missing'), false)
assert.equal(h.beginGroupedPinReorder('org.A'), true)
assert.equal(h.beginGroupedPinReorder('org.B'), false, 'one drag at a time')
assert.equal(emitted.length, 0, 'press/move do not persist')
h.updateGroupedPinTarget(140)
assert.equal(h.groupedPinTargetId, 'org.C')
assert.equal(h.groupedPinOffset(1), -56)
assert.equal(h.groupedPinOffset(2), -56)
h.finishGroupedPinReorder()
assert.deepEqual(emitted, [['org.A','org.C']])
assert.equal(h.groupedPinSourceId, '')
assert.equal(h.groupedPinOffset(1), 0)
assert.equal(h.beginGroupedPinReorder('org.B'), true)
h.cancelGroupedPinReorder()
assert.equal(emitted.length, 1, 'cancelled drag writes nothing')
assert.equal(h.beginGroupedPinReorder('org.B'), true)
h.finishGroupedPinReorder()
assert.equal(emitted.length, 1, 'same-target drop is a no-op')
h.workspaceDragActive = true
assert.equal(h.beginGroupedPinReorder('org.A'), false, 'workspace drag has priority')
h.workspaceDragActive = false
assert.equal(h.beginGroupedPinReorder('org.A'), true)
h.workspacePresentation.globalLaunchers = [{desktopId:'org.B'}, {desktopId:'org.C'}]
h.finishGroupedPinReorder()
assert.equal(emitted.length, 1, 'removed source cannot commit')

const itemQml = read('components/DockItem.qml')
const dockQml = read('components/Dock.qml')
assert.match(itemQml, /!root\.originOnly \|\| root\.pinReorderEnabled/,
  'global grouped pins are reorderable despite originOnly')
assert.match(itemQml, /PointerDevice\.UngrabExclusive\) root\.dragFinished\(\)/,
  'only a released exclusive grab commits')
assert.match(itemQml, /PointerDevice\.CancelGrabExclusive[\s\S]*?root\.dragCancelled\(\)/,
  'cancelled dock drags cannot commit')
assert.match(dockQml, /indexOf\("global\/"\) === 0/,
  'running pinned app cards retain existing workspace dragging')
assert.match(dockQml, /onDragCancelled:[\s\S]*?root\.cancelGroupedPinReorder\(\)/,
  'grouped drag cancellation clears transient state')
console.log('grouped classic pin reorder: PASS')
