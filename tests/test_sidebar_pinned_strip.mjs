import assert from 'node:assert/strict'
import { loadModel, plain, read } from './host_harness.mjs'
import { qmlMethods } from './sidebar_interaction_fixture.mjs'

const model = loadModel('DockSidebarInteractionModel')
const layout = width => plain(model.pinnedStripLayout(width - 28, 7, 32, 32, 7))

assert.deepEqual(layout(240), { slots:4, visible:3, hidden:4 })
assert.deepEqual(layout(256), { slots:5, visible:4, hidden:3 })
assert.deepEqual(layout(320), { slots:6, visible:5, hidden:2 })
assert.deepEqual(layout(220), { slots:4, visible:3, hidden:4 },
  'illustrative 220 px strip layout still fits')
assert.deepEqual(plain(model.pinnedStripLayout(228, 3, 32, 32, 7)),
  { slots:5, visible:3, hidden:0 }, 'no overflow when every pin fits')
assert.deepEqual(plain(model.pinnedStripLayout(228, 0, 32, 32, 7)),
  { slots:5, visible:0, hidden:0 })
assert.deepEqual(plain(model.pinnedStripLayout(71, 7, 32, 32, 7)),
  { slots:1, visible:0, hidden:7 }, 'last icon slot is reserved for overflow')

// Nearest-center target selection never includes overflow/+ or add controls.
const target = (x, count=4) => model.pinnedStripDragTargetIndex(x, count, 32, 7)
assert.equal(target(16), 0)
assert.equal(target(35), 0)
assert.equal(target(36), 1)
assert.equal(target(55), 1)
assert.equal(target(94), 2)
assert.equal(target(-100), 0)
assert.equal(target(1000), 3)
assert.equal(target(55, 0), -1)
assert.equal(target(NaN), -1)

const stripQml = read('components/DockSidebarPinnedStrip.qml')
const sidebarQml = read('components/DockSidebar.qml')
assert.doesNotMatch(stripQml, /hiddenRunning|id:\s*runningDot/,
  'pinned tiles, overflow and popup rows have no running dots')
assert.match(stripQml, /grabFocus:\s*true/,
  'overflow uses a focus-grabbing PopupWindow so sidebar clicks dismiss it')
assert.match(stripQml, /borderSpec:\s*Border\.none\(\)/,
  'overflow popup has no border')
assert.match(stripQml, /radius:\s*Style\.cornerRadius/,
  'overflow popup uses rounded native corners')
assert.match(stripQml, /overflowButton\.focus = false/,
  'the overflow action clears mouse-retained focus')
assert.match(stripQml, /overflowOpenedByKeyboard[\s\S]*hiddenRepeater\.itemAt\(0\)[\s\S]*forceActiveFocus/,
  'keyboard activation focuses the first overflow item')
assert.match(stripQml, /overflowFlickable\.forceActiveFocus\(Qt\.MouseFocusReason\)/,
  'pointer activation focuses the popup without selecting an item')
assert.match(stripQml, /pinCell\.activeFocus && !pinCell\.mouseFocused/,
  'mouse-focused pinned tiles do not keep a stale focus fill')
assert.match(stripQml, /pinCell\.mouseFocused = true[\s\S]*forceActiveFocus\(Qt\.MouseFocusReason\)/,
  'pointer activation records mouse focus before focusing the pinned tile')
assert.match(stripQml, /Style\.hoverFillFor\(Commons\.Color\.foreground, Commons\.Color\.accent\)/,
  'pinned tile hover uses the native hover fill')
assert.match(stripQml, /scale: pinHover\.hovered \? 1\.08 : 1/,
  'pinned icon hover scales only the icon')
assert.match(stripQml, /addPin\.focus = false/,
  'the add action clears mouse-retained focus')
assert.match(sidebarQml, /pinnedStrip\.overflowOpen/,
  'overflow participates in the panel interactionBusy lifecycle')
assert.match(sidebarQml, /root\.controller\.pinReorderActive/,
  'drag owns shared interactionBusy so mode switching and row drags cannot compete')
assert.match(stripQml, /acceptedModifiers: Qt\.NoModifier[\s\S]*?onGrabChanged:[\s\S]*?PointerDevice\.UngrabExclusive[\s\S]*?root\.finishPinDrag\(\)/,
  'left-button unmodified drag commits only on exclusive release')
assert.match(stripQml, /PointerDevice\.CancelGrabExclusive[\s\S]*?root\.cancelPinDrag\(\)/,
  'grab loss cancels without committing a reorder')
assert.match(stripQml, /root\.controller\.finishPinReorder\(key, !key\)/,
  'sidebar uses the shared host reorder path rather than writing config')
assert.match(stripQml, /root\.hiddenCount > 0[\s\S]*?point\.x >= root\.visibleCount \* \(root\.cell \+ root\.pinGap\)/,
  'overflow control is outside the active pin drop region')

// Hidden (+N) pins keep the visible tiles' context menu, including Unpin.
assert.match(stripQml, /acceptedButtons: Qt\.RightButton\s*\n\s*onTapped: root\.openOverflowContext\(hiddenPin\.modelData\)/,
  'right-click on an overflowed pin opens its context menu')
assert.match(stripQml, /event\.key !== Qt\.Key_Menu\) return\s*\n\s*root\.openOverflowContext\(hiddenPin\.modelData\)/,
  'Menu key on an overflowed pin opens its context menu')
assert.match(stripQml, /root\.panel\.openContext\(root\.overflowMenuPin, overflowButton\)/,
  'overflow context menu anchors to the +N button')
assert.match(stripQml, /id: overflowButton[\s\S]{0,200}?pinStripOwned: true[\s\S]{0,200}?rowKey: root\.overflowMenuKey/,
  '+N anchor carries strip ownership and the hidden pin rowKey for menu refresh')
assert.match(stripQml, /hiddenPins\.some\(function\(pin\) \{ return String\(pin\.key \|\| ""\) === key \}\)/,
  'anchor identity clears once the pin is no longer hidden, so refresh dismisses the menu')

// Exercise the production controller's mutation methods without an Omarchy host.
const calls = []
const controller = qmlMethods('DockSidebarController.qml', {
  interactionBusy:false, resizeActive:false, rowDragActive:false,
  widgetReorderActive:false, widgetPopupId:'', pinDragKey:'', mutationFeedback:'',
  projection:{launchers:[
    {key:'a',desktopId:'org.A'}, {key:'b',desktopId:'org.B'},
    {key:'c',desktopId:'org.C'}
  ]},
  host:{reorderPinned(source,target) {
    calls.push([source,target])
    return {ok:true,data:{applied:true,persisted:true}}
  }}
})
assert.equal(controller.beginPinReorder('missing'), false)
assert.equal(controller.beginPinReorder('a'), true)
assert.equal(controller.interactionBusy, true)
assert.equal(controller.beginPinReorder('b'), false, 'a second gesture cannot take over')
assert.equal(calls.length, 0, 'dragging does not write until release')
assert.equal(controller.finishPinReorder('b', true).noop, true)
assert.equal(controller.interactionBusy, false)
assert.equal(calls.length, 0, 'cancelled grab writes nothing')
assert.equal(controller.beginPinReorder('a'), true)
assert.equal(controller.finishPinReorder('a', false).noop, true)
assert.equal(calls.length, 0, 'same-target drop is a no-op')
assert.equal(controller.beginPinReorder('c'), true)
assert.equal(controller.finishPinReorder('a', false).accepted, true)
assert.deepEqual(calls, [['org.C','org.A']], 'source and target resolve by stable pin key')
assert.equal(controller.interactionBusy, false)
assert.equal(controller.beginPinReorder('a'), true)
controller.projection.launchers = controller.projection.launchers.filter(p => p.key !== 'b')
assert.equal(controller.finishPinReorder('b', false).noop, true)
assert.equal(calls.length, 1, 'vanished target does not save')
assert.equal(controller.beginPinReorder('a'), true)
controller.host.reorderPinned = () => ({ok:false,error:{code:'E_PERSISTENCE',message:'disk full'},data:{applied:false}})
const failure = controller.finishPinReorder('c', false)
assert.equal(failure.accepted, false)
assert.equal(controller.mutationFeedback, 'disk full')
assert.equal(controller.interactionBusy, false)
assert.equal(controller.beginPinReorder('a'), true)
controller.host.reorderPinned = () => ({ok:false,error:{code:'E_BUSY'},data:{applied:true}})
const pending = controller.finishPinReorder('c', false)
assert.equal(pending.accepted, true)
assert.equal(pending.pending, true)
assert.equal(controller.mutationFeedback, '')

const controllerQml = read('components/DockSidebarController.qml')
assert.match(controllerQml, /onMonitorsChanged: \{\s*root\.cancelPinReorder\(\)/,
  'compositor monitor changes cancel sidebar pin drag')
assert.match(stripQml, /if \(active && root\.beginPinDrag\(pinCell\.rowKey\)\) \{\s*pinCell\.forceActiveFocus\(Qt\.MouseFocusReason\)/,
  'drag moves keyboard focus to the source cell for Escape')
assert.match(stripQml, /if \(event\.key === Qt\.Key_Escape && root\.dragSourceKey === pinCell\.rowKey\) \{\s*root\.cancelPinDrag\(\)/,
  'Escape explicitly cancels the active cell drag')

console.log('sidebar pinned strip layout and reorder: PASS')
