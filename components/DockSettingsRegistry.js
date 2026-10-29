.pragma library

// One schema registry shared by navigation, row rendering, future Search and
// Settings › links. Sections own canonical settings; Features owns shortcuts.
var order = ["appearance", "layout", "behavior", "sidebar-widgets", "features", "apps"]
var labels = {
  appearance:"Appearance", layout:"Layout", behavior:"Behavior",
  "sidebar-widgets":"Sidebar & Widgets", features:"Features", apps:"Apps"
}
function registry(metadata) {
  var keys = metadata && metadata.settings ? Object.keys(metadata.settings) : []
  var bySection = Object.create(null)
  order.forEach(function(key) { bySection[key] = [] })
  keys.forEach(function(key) {
    var spec = metadata.settings[key]
    var ui = spec && spec.ui
    if (!ui || !Object.prototype.hasOwnProperty.call(bySection, ui.section)) return
    bySection[ui.section].push({ key:key, ui:ui, spec:spec })
  })
  order.forEach(function(section) {
    bySection[section].sort(function(a,b) {
      return a.ui.order - b.ui.order || a.key.localeCompare(b.key)
    })
  })
  return order.map(function(id) {
    return {id:id, label:labels[id], rows:bySection[id]}
  })
}
function sectionRows(metadata, name) {
  var sections = registry(metadata)
  for (var i=0;i<sections.length;i++)
    if (sections[i].id === name) return sections[i].rows
  return []
}
function openingSection(presentation, lastSection) {
  if (lastSection && order.indexOf(lastSection) >= 0) return lastSection
  if (presentation && presentation.classicScreens && presentation.classicScreens.length)
    return "appearance"
  return "sidebar-widgets"
}
function layoutInventory(metadata) {
  var rows = sectionRows(metadata, "layout").filter(function(row) {
    return row.ui.visibility !== "hidden" && row.ui.visibility !== "in-place"
  })
  return ["displays","sidebar","classic-size-position","classic-hiding","classic-arrange-apps"].map(function(name) {
    return {id:name, rows:rows.filter(function(row) {return row.ui.group === name})}
  })
}
function layoutCards(metadata) {
  var groups = layoutInventory(metadata)
  return groups.slice(0,2).concat([{id:"classic",rows:groups.slice(2).reduce(function(rows,group) {
    return rows.concat(group.rows)
  },[])}])
}
function groupLabel(group) {
  return {"classic-size-position":"Size and position", "classic-hiding":"Hiding", "classic-arrange-apps":"Apps on the dock"}[group] || ""
}
function layoutRowVisible(row, monitorCount, arrangement) {
  if (monitorCount < 2 && ["presentationMode","sidebarCollapsed","workspaceMonitorOrder","workspaceMonitorScope"].indexOf(row.key) >= 0) return false
  if (row.key === "workspaceMonitorScope" && arrangement !== "grouped") return false
  if (["windowScope","showUrgentOutsideScope","sortByWorkspace"].indexOf(row.key) >= 0 && arrangement !== "flat") return false
  return true
}
function layoutGroups(metadata, monitorCount, arrangement) {
  return layoutInventory(metadata).map(function(group) {
    return {id:group.id,rows:group.rows.filter(function(row) {return layoutRowVisible(row,monitorCount,arrangement)})}
  })
}
function monitorChoice(settings,connector) {
  var entries=settings && settings.presentationModeByMonitor || ({})
  return Object.prototype.hasOwnProperty.call(entries,connector) ? entries[connector]:"default"
}
function copyWithMode(settings,connector,mode) {
  var entries=Object.assign({},settings && settings.presentationModeByMonitor || {})
  if (mode==="default") delete entries[connector]
  else entries[connector]=mode
  return entries
}
function status(writeState, persisted, loadState) {
  if (loadState==="invalid") return "Read-only"
  if (writeState==="error") return "Not saved"
  if (writeState==="saving") return "Saving"
  return writeState==="saved" && persisted ? "Saved":""
}

// Schema dependencies affect editability, not the stored requested value.
function editability(ui, settings, monitorCount) {
  var needs = ui && ui.requires || {}
  var keys = Object.keys(needs)
  for (var i = 0; i < keys.length; ++i) {
    if (JSON.stringify(settings[keys[i]]) !== JSON.stringify(needs[keys[i]]))
      return {enabled:false, reason:"Needs " + keys[i] + " = " + String(needs[keys[i]])}
  }
  if (ui && ui.minMonitors && monitorCount < ui.minMonitors)
    return {enabled:false, reason:"Needs " + ui.minMonitors + " monitors"}
  return {enabled:true, reason:""}
}
function writeOutcome(result) {
  var reply = result && result.reply ? result.reply : result
  var applied = !!(reply && reply.data && reply.data.applied)
  var accepted = !!(reply && (reply.ok || applied))
  return {accepted:accepted, pending:accepted && !reply.ok && !!reply.error && reply.error.code === "E_BUSY", reply:reply}
}
function manualMonitorOrder(saved, connectors) {
  var result = (saved || []).slice()
  ;(connectors || []).forEach(function(name) { if (result.indexOf(name) < 0) result.push(name) })
  return result
}
function moveMonitor(order, connector, delta) {
  var result = order.slice(), index = result.indexOf(connector)
  var next = Math.max(0, Math.min(result.length - 1, index + delta))
  if (index >= 0 && next !== index) { result.splice(index, 1); result.splice(next, 0, connector) }
  return result
}
function shellQuote(value) { return "'" + String(value).replace(/'/g, "'\\''") + "'" }
function cliCommand(key, value) {
  return "dockrail config set " + key + " " + shellQuote(JSON.stringify(value))
}

function displayValue(ui, value) {
  if (typeof value !== "number" || !isFinite(value))
    return String(value === undefined ? "" : value) + ((ui && ui.unit) || "")
  var scale = ui && typeof ui.displayScale === "number" ? ui.displayScale : 1
  var scaled = Math.round(value * scale * 1000) / 1000
  return (ui && ui.unit === "×" ? scaled.toFixed(2) : String(scaled))
    + ((ui && ui.unit) || "")
}


// SET-08: Search uses the canonical registry; hidden/in-place rows are not
// manufactured as independent editors. Results keep the originating row.
function search(metadata, term, shownKeys) {
  var needle=String(term || "").trim().toLocaleLowerCase()
  if (!needle) return []
  var visible=shownKeys || null
  var found=[]
  registry(metadata).forEach(function(section) {
    section.rows.forEach(function(row) {
      if (row.ui.visibility !== "normal") return
      if (visible && visible.indexOf(row.key) < 0) return
      var label=String(row.ui.label || "")
      var help=String(row.ui.help || "")
      var key=row.key
      var rank=label.toLocaleLowerCase()===needle ? 0 :
        label.toLocaleLowerCase().indexOf(needle)>=0 ? 1 :
        key.toLocaleLowerCase().indexOf(needle)>=0 ? 2 :
        help.toLocaleLowerCase().indexOf(needle)>=0 ? 3 : -1
      if (rank >= 0) found.push({section:section.id, sectionLabel:section.label,
        key:key, row:row, rank:rank, label:label, help:help})
    })
  })
  return found.sort(function(a,b) {return a.rank-b.rank || order.indexOf(a.section)-order.indexOf(b.section)
    || a.row.ui.order-b.row.ui.order || a.key.localeCompare(b.key)})
}
function searchCounts(results) {
  var counts={}
  ;(results || []).forEach(function(row) {counts[row.section]=(counts[row.section] || 0)+1})
  return counts
}
function firstRun(defaultsInUse, loaded, loadState) {
  return loaded === true && defaultsInUse === true && loadState !== "invalid"
}
// Preserve the connected screens' actual effective modes while migrating
// legacy monitor selection to explicit per-monitor settings, without deleting
// the legacy compatibility key or overwriting unknown/disconnected overrides.
function legacyConversion(settings, presentation) {
  if (!settings || !settings.sidebarMonitor || !presentation || !presentation.entries
      || !presentation.entries.length) return null
  var existing=settings.presentationModeByMonitor || {}
  var next=Object.assign({},existing)
  presentation.entries.forEach(function(entry) {
    if (entry && entry.connector && (entry.mode==="classic" || entry.mode==="sidebar"))
      next[entry.connector]=entry.mode
  })
  return {patch:{presentationModeByMonitor:next,sidebarMonitor:""},
    expected:{presentationModeByMonitor:Object.assign({},existing),sidebarMonitor:settings.sidebarMonitor}}
}
