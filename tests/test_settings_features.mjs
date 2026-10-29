import assert from 'node:assert/strict'
import { loadModel, read, plain, hostHarness } from './host_harness.mjs'

const model = loadModel('DockSettingsFeaturesModel')
const schema = JSON.parse(read('config/settings-schema.json'))
const chrome = model.aggregate(schema, 'chrome')
const herdr = model.aggregate(schema, 'coding-agents')
const counts = model.aggregate(schema, 'launcher-counts')
assert.deepEqual(plain(chrome.keys), ['browserProfileBadgesEnabled','sidebarBrowserTabsEnabled'])
assert.deepEqual(plain(herdr.keys), ['sidebarWidgets','dockHerdrIndicators'])
assert.deepEqual(plain(counts.keys), ['launcherBadgeMode'])
assert.equal(model.aggregate(schema,'agent-launchers'), null)

const settings = {
  browserProfileBadgesEnabled:false, sidebarBrowserTabsEnabled:false,
  sidebarWidgets:['unknown.widget','test.one'], dockHerdrIndicators:false,
  launcherBadgeMode:'dots-only', extension:{keep:true}
}
assert.equal(model.shortcutState(settings,chrome),'off')
const chromeOn=plain(model.change(settings,chrome))
assert.deepEqual(chromeOn.patch,{browserProfileBadgesEnabled:true,sidebarBrowserTabsEnabled:true})
assert.deepEqual(chromeOn.expected,{browserProfileBadgesEnabled:false,sidebarBrowserTabsEnabled:false})
assert.equal(model.shortcutState({...settings,browserProfileBadgesEnabled:true},chrome),'partly-on')
const mixedChrome=plain(model.change({...settings,browserProfileBadgesEnabled:true},chrome))
assert.deepEqual(mixedChrome.patch,chromeOn.patch,'Partly on must turn both on')
assert.equal(model.shortcutState({...settings,...chromeOn.patch},chrome),'on')
assert.deepEqual(plain(model.change({...settings,...chromeOn.patch},chrome).patch),
  {browserProfileBadgesEnabled:false,sidebarBrowserTabsEnabled:false})

assert.equal(model.shortcutState(settings,herdr),'off')
const herdrOn=plain(model.change(settings,herdr))
assert.deepEqual(herdrOn.patch,{
  sidebarWidgets:['unknown.widget','test.one','herdr.agents'],
  dockHerdrIndicators:true
})
assert.deepEqual(herdrOn.expected.sidebarWidgets,settings.sidebarWidgets)
assert.notEqual(herdrOn.expected.sidebarWidgets,settings.sidebarWidgets)
settings.sidebarWidgets.push('test.two')
assert.deepEqual(herdrOn.expected.sidebarWidgets,['unknown.widget','test.one'],
  'expected snapshot must not be a mutable reference')
const active={...settings,sidebarWidgets:['unknown.widget','test.one','herdr.agents','test.two'],dockHerdrIndicators:true}
assert.equal(model.shortcutState(active,herdr),'on')
assert.deepEqual(plain(model.change(active,herdr).patch.sidebarWidgets),
  ['unknown.widget','test.one','test.two'])
assert.equal(model.shortcutState({...settings,dockHerdrIndicators:true},herdr),'partly-on')
assert.equal(model.shortcutState(settings,counts),'off')
assert.deepEqual(plain(model.change(settings,counts).patch),{launcherBadgeMode:'automatic'})
assert.equal(model.shortcutState({...settings,launcherBadgeMode:'automatic'},counts),'on')
assert.deepEqual(plain(model.change({...settings,launcherBadgeMode:'automatic'},counts).patch),
  {launcherBadgeMode:'dots-only'})

const fake={chromeProfilesTabs:{runtime:'ready',installation:'installed'},
  herdrAgents:{runtime:'limited',installation:'installed'},
  launcherCounts:{runtime:'unavailable',installation:'missing'},
  agentLaunchers:{runtime:'unavailable',installation:'missing',
    agents:[{command:'claude',found:true},{command:'pi',found:false}]}}
assert.deepEqual(plain(model.counts(fake)),{ready:1,limited:1,missing:2,checking:0})
assert.equal(model.summary(fake),'1 ready · 1 limited · 2 not set up')
assert.equal(model.agentSummary(fake.agentLaunchers),'1 of 2 found on this computer')
assert.equal(model.badge({runtime:'ready',installation:'missing'}),'Not set up')
assert.equal(model.summary(null),'Checking integrations…')
assert.deepEqual(plain(model.cards.slice(0,3).map(card=>card.setup)),[
  'dockrail setup --feature chrome','dockrail setup --feature herdr',
  'dockrail setup --feature launcher-counts'
])

// Exercise the production expected-value writer, not an independent JS fake.
const h=hostHarness({browserProfileBadgesEnabled:false,sidebarBrowserTabsEnabled:false,
  sidebarWidgets:['unknown.widget'],dockHerdrIndicators:false,launcherBadgeMode:'dots-only'})
const first=plain(model.change(h.host.settings,chrome))
const accepted=h.host.saveSettingsIntent(first.patch,first.expected)
assert.equal(accepted.accepted,true)
assert.equal(h.host.settings.browserProfileBadgesEnabled,true)
assert.equal(h.host.settings.sidebarBrowserTabsEnabled,true)
const stale=h.host.saveSettingsIntent({browserProfileBadgesEnabled:false,sidebarBrowserTabsEnabled:false},
 {browserProfileBadgesEnabled:false,sidebarBrowserTabsEnabled:true})
assert.equal(stale.accepted,false)
assert.equal(stale.reply.error.code,'E_STALE')
assert.equal(h.host.settings.browserProfileBadgesEnabled,true)
console.log('Features metadata shortcuts, partial state, copy commands and stale-safe writer passed')
