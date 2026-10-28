import assert from 'node:assert/strict'
import { loadModel, plain, read } from './host_harness.mjs'

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

console.log('sidebar pinned strip layout: PASS')
