.pragma library

// Features are shortcuts over schema-owned canonical settings, never another
// source of state. Installation/runtime status comes only from doctor.
var cards = [
  {id:"chrome", key:"chromeProfilesTabs", title:"Chrome",
   subtitle:"Profile badges, unread counts and tabs in the sidebar", icon:"app-window",
   setup:"dockrail setup --feature chrome", home:"apps", homeLabel:"Apps › Chrome"},
  {id:"coding-agents", key:"herdrAgents", title:"Coding agents (Herdr)",
   subtitle:"Agent status in the sidebar and on terminal icons", icon:"bot",
   setup:"dockrail setup --feature herdr", home:"sidebar-widgets", homeLabel:"Sidebar & Widgets"},
  {id:"launcher-counts", key:"launcherCounts", title:"Launcher badge counts",
   subtitle:"Unread numbers from apps; dots remain the fallback", icon:"circle-alert",
   setup:"dockrail setup --feature launcher-counts", home:"behavior", homeLabel:"Behavior › Attention"},
  {id:"agent-launchers", key:"agentLaunchers", title:"Terminal agent launchers",
   subtitle:"Desktop launchers for installed coding agents", icon:"terminal",
   setup:"dockrail setup --feature agent-launchers", home:"", homeLabel:""}
]
var fallbackCountCommand = "bash ~/.config/omarchy/plugins/io.github.fernandodamaso.dockrail/scripts/build-launcher-badge-provider"

function aggregate(metadata, id) {
  var settings = metadata && metadata.settings || {}
  var names = Object.keys(settings)
  for (var i=0;i<names.length;i++) {
    var spec = settings[names[i]], feature = spec && spec.ui && spec.ui.feature
    if (feature && feature.id === id) return feature
  }
  return null
}
function equal(left, right) { return JSON.stringify(left) === JSON.stringify(right) }
// Qt 6.12 exposes arrays that crossed a QML property boundary as V4 sequence
// objects: indexed access works, but Array.isArray() is false. Copy them into
// real arrays so membership edits keep plain JavaScript arrays.
function list(value) {
  if (Array.isArray(value)) return value
  if (!value || typeof value !== "object" || typeof value.length !== "number"
      || !isFinite(value.length) || value.length < 0) return null
  var copy = []
  for (var i = 0; i < value.length; ++i) copy.push(value[i])
  return copy
}
function desired(settings, feature, enabled) {
  var keys = feature ? list(feature.keys) : null
  if (!keys || !keys.length) return null
  var values = enabled ? feature.on : feature.off
  if (!values || typeof values !== "object") return null
  var patch = {}, expected = {}, current = settings || {}
  for (var i=0;i<keys.length;i++) {
    var key = keys[i], existing = current[key], existingList = list(existing)
    expected[key] = existingList ? existingList.slice() : existing
    if (feature.membership === "append-or-remove-id" && key === "sidebarWidgets") {
      if (!existingList || !feature.widgetId) return null
      var members = existingList.filter(function(id) { return id !== feature.widgetId })
      patch[key] = enabled && existingList.indexOf(feature.widgetId) < 0
        ? existingList.concat([feature.widgetId])
        : enabled ? existingList.slice() : members
    } else if (Object.prototype.hasOwnProperty.call(values,key)) {
      patch[key] = values[key]
    } else return null
  }
  return {patch:patch, expected:expected}
}
function shortcutState(settings, feature) {
  var on = desired(settings,feature,true), off = desired(settings,feature,false)
  if (!on || !off) return "unavailable"
  var keys = list(feature.keys)
  var matches = function(candidate) {
    return keys.every(function(key) {return equal(settings[key],candidate.patch[key])})
  }
  return matches(on) ? "on" : matches(off) ? "off" : "partly-on"
}
function change(settings, feature) {
  var state = shortcutState(settings,feature)
  if (state === "unavailable") return null
  return desired(settings, feature, state !== "on")
}
function badge(feature) {
  if (!feature) return "Checking"
  if (feature.installation === "missing" || feature.runtime === "unavailable") return "Not set up"
  return feature.runtime === "ready" ? "Ready" : "Limited"
}
function counts(features) {
  var result={ready:0,limited:0,missing:0,checking:0}
  cards.forEach(function(card) {
    var status=badge(features && features[card.key])
    if(status==="Ready") result.ready++
    else if(status==="Limited") result.limited++
    else if(status==="Not set up") result.missing++
    else result.checking++
  })
  return result
}
function summary(features) {
  var c=counts(features)
  if (c.checking === cards.length) return "Checking integrations…"
  var parts=[]
  if(c.ready) parts.push(c.ready+" ready")
  if(c.limited) parts.push(c.limited+" limited")
  if(c.missing) parts.push(c.missing+" not set up")
  if(c.checking) parts.push(c.checking+" checking")
  return parts.join(" · ")
}
function agentSummary(feature) {
  var agents=list(feature && feature.agents) || []
  return agents.filter(function(agent){return agent.found === true}).length+" of "+agents.length+" found on this computer"
}
