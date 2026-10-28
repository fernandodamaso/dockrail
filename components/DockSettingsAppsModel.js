.pragma library

// Read-only Settings projection. IDs remain stored verbatim; host app intents
// validate canonical identities and apply each latest-state edit.
function entryFor(id, applications) {
  var wanted = String(id || "").toLowerCase().replace(/\.desktop$/, "")
  var entries = applications || []
  for (var i = 0; i < entries.length; ++i) {
    var entry = entries[i]
    if (entry && String(entry.id || "").toLowerCase().replace(/\.desktop$/, "") === wanted)
      return entry
  }
  return null
}

function applicationRows(ids, applications) {
  return (Array.isArray(ids) ? ids : []).map(function(id, index) {
    var entry = entryFor(id, applications)
    return {id:id, index:index, name:entry && entry.name || String(id),
      available:!!entry, icon:entry && entry.icon || ""}
  })
}

function moveArguments(pinned, id, delta) {
  var values = Array.isArray(pinned) ? pinned : []
  var from = values.indexOf(id)
  var to = Math.max(0, Math.min(values.length - 1, from + delta))
  if (from < 0 || from === to) return null
  var args = {id:id}
  // Host apps.move uses a primitive relative intent; never send a new array.
  args[from < to ? "after" : "before"] = values[to]
  return args
}

function dragArguments(pinned, id, target) {
  var values = Array.isArray(pinned) ? pinned : []
  var from = values.indexOf(id)
  var to = values.indexOf(target)
  if (from < 0 || to < 0 || from === to) return null
  var args = {id:id}
  args[from < to ? "after" : "before"] = target
  return args
}

function iconRows(settings, applications) {
  settings = settings || {}
  var icons = settings.iconOverrides || {}
  var rows = []
  Object.keys(icons).forEach(function(key) {
    var split = key.indexOf("@profile:")
    var desktopId = split < 0 ? key : key.slice(0,split)
    var profileKey = split < 0 ? "" : key.slice(split + 9)
    var entry = entryFor(desktopId, applications)
    rows.push({kind:split < 0 ? "app":"profile", key:key, desktopId:desktopId,
      name:(entry && entry.name || desktopId) + (profileKey ? " · " + profileKey : ""),
      profileKey:profileKey, source:icons[key]})
  })
  ;(Array.isArray(settings.windowIconOverrides) ? settings.windowIconOverrides : []).forEach(function(rule) {
    if (!rule || !rule.appId || !rule.titlePattern) return
    rows.push({kind:"window", key:"", desktopId:String(rule.appId),
      appId:rule.appId, titlePattern:rule.titlePattern,
      name:String(rule.appId)+" · title matches “"+rule.titlePattern+"”",
      source:rule.source, profileKey:""})
  })
  return rows
}

function muteOptions(selected) {
  var options = [
    {value:"gmail",label:"Gmail"},
    {value:"whatsapp",label:"WhatsApp"},
    {value:"instagram",label:"Instagram"}
  ]
  ;(Array.isArray(selected) ? selected : []).forEach(function(id) {
    if (!options.some(function(option) { return option.value === id }))
      options.push({value:id,label:id+" (saved)"})
  })
  return options
}
