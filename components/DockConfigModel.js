.pragma library
.import "DockSidebarWidgetModel.js" as SidebarWidgetModel
.import "DockIconModel.js" as DockIconModel
.import "DockWorkspaceGroupModel.js" as DockWorkspaceGroupModel

// Strict validation applies only to new intents. Untouched legacy values and
// extension keys stay byte-for-value equivalent in the requested snapshot.
function own(object, key) {
  return Object.prototype.hasOwnProperty.call(object, key)
}

function isObject(value) {
  return value !== null && typeof value === "object" && !Array.isArray(value)
}

function canonicalApplicationId(value) {
  if (typeof value !== "string" || /[\x00-\x1f\x7f/\\]/.test(value)) return ""
  return DockIconModel.normalizeKey(value)
}

function valueError(value, spec, retainedIds) {
  if (spec.type === "boolean" && typeof value !== "boolean") return "Expected a boolean"
  if (spec.type === "string") {
    if (typeof value !== "string") return "Expected a string"
    if (spec.minLength && value.trim().length < spec.minLength) return "String must not be empty"
  }
  if (spec.type === "integer" || spec.type === "number") {
    if (typeof value !== "number" || !isFinite(value)) return "Expected a finite number"
    if (spec.type === "integer" && Math.floor(value) !== value) return "Expected an integer"
    if (spec.minimum !== undefined && value < spec.minimum) return "Value is below " + spec.minimum
    if (spec.maximum !== undefined && value > spec.maximum) return "Value is above " + spec.maximum
  }
  if (spec.format === "monitor-connector" && /[\x00-\x1f\x7f-\x9f]/.test(value))
    return "Monitor connector must not contain control characters"
  if (spec.enum && spec.enum.indexOf(value) < 0) return "Expected one of: " + spec.enum.join(", ")
  if (spec.format === "color" && value !== ""
      && !/^#[0-9a-fA-F]{6}([0-9a-fA-F]{2})?$/.test(value)
      && !/^@[a-z][a-z0-9_.-]*$/.test(value))
    return "Expected empty, #RRGGBB, Qt #AARRGGBB or @theme.token"
  if (spec.type === "array") {
    if (!Array.isArray(value)) return "Expected an array"
    if (spec.format === "sidebar-widget-ids")
      return SidebarWidgetModel.idsError(value, spec.registeredIds, retainedIds)
    if (spec.format === "workspace-groups")
      return DockWorkspaceGroupModel.workspaceGroupsError(value)
    if (spec.format === "application-ids") {
      var seen = Object.create(null)
      for (var i = 0; i < value.length; ++i) {
        var id = canonicalApplicationId(value[i])
        if (!id) return "Invalid application ID at index " + i
        // Bulk patches retain spelling; padded pins would not resolve in DockModel.
        // Reject new padding rather than silently rewriting legacy collections.
        if (value[i] !== value[i].trim())
          return "Application ID must not have surrounding whitespace at index " + i
        if (own(seen, id)) return "Duplicate application ID: " + value[i]
        seen[id] = true
      }
    }
    if (spec.format === "browser-activity-service-ids") {
      var seenServices = Object.create(null)
      for (var s = 0; s < value.length; ++s) {
        if (typeof value[s] !== "string")
          return "Expected a string service ID at index " + s
        var serviceId = value[s].trim().toLowerCase()
        if (!serviceId || serviceId.length > 64
            || !/^[a-z0-9][a-z0-9_-]*$/.test(serviceId))
          return "Invalid browser activity service ID at index " + s
        if (value[s] !== serviceId)
          return "Service ID must be trimmed lowercase at index " + s
        if (own(seenServices, serviceId))
          return "Duplicate browser activity service ID: " + value[s]
        seenServices[serviceId] = true
      }
    }
    if (spec.format === "monitor-connectors") {
      var seenConnectors = Object.create(null)
      for (var c = 0; c < value.length; ++c) {
        if (typeof value[c] !== "string")
          return "Expected a string monitor connector at index " + c
        if (!value[c] || value[c] !== value[c].trim()
            || /[\x00-\x1f\x7f]/.test(value[c]))
          return "Invalid monitor connector at index " + c
        if (own(seenConnectors, value[c]))
          return "Duplicate monitor connector: " + value[c]
        seenConnectors[value[c]] = true
      }
    }
  }
  if (spec.type === "object" && !isObject(value)) return "Expected an object"
  if (spec.format === "sidebar-widget-collapsed")
    return SidebarWidgetModel.collapsedError(value)
  if (spec.format === "window-icon-overrides")
    return DockIconModel.windowRulesError(value)
  if (spec.format === "icon-overrides") {
    var keys = Object.keys(value)
    var seenIcons = Object.create(null)
    for (var k = 0; k < keys.length; ++k) {
      var key = canonicalApplicationId(keys[k])
      if (!key || own(seenIcons, key)) return "Invalid or duplicate icon application ID: " + keys[k]
      if (!DockIconModel.normalizeSource(value[keys[k]])) return "Expected a local PNG or SVG source: " + keys[k]
      seenIcons[key] = true
    }
  }
  if (spec.format === "presentation-mode-by-monitor") {
    var modeConnectors = Object.keys(value)
    for (var p = 0; p < modeConnectors.length; ++p) {
      var modeConnector = modeConnectors[p]
      if (typeof modeConnector !== "string" || !modeConnector
          || /[\x00-\x1f\x7f-\x9f]/.test(modeConnector))
        return "Invalid monitor connector: " + modeConnector
      if (value[modeConnector] !== "classic" && value[modeConnector] !== "sidebar")
        return "Expected classic or sidebar for " + modeConnector
    }
  }
  if (spec.format === "sidebar-collapsed-by-monitor") {
    var connectors = Object.keys(value)
    for (var m = 0; m < connectors.length; ++m) {
      var connector = connectors[m]
      if (typeof connector !== "string" || !connector
          || /[\x00-\x1f\x7f-\x9f]/.test(connector))
        return "Invalid monitor connector: " + connector
      if (typeof value[connector] !== "boolean")
        return "Expected a boolean collapse flag for " + connector
    }
  }
  return ""
}

function validatePatch(patch, schema, current) {
  var errors = []
  if (!isObject(patch)) return { ok: false, errors: [{ key: "", message: "Patch must be a JSON object" }] }
  var keys = Object.keys(patch)
  for (var i = 0; i < keys.length; ++i) {
    var key = keys[i]
    var error = ""
    if (key === "__proto__" || key === "constructor" || key === "prototype"
        || !own(schema.settings, key)) error = "Unknown or reserved setting"
    else if (key === "groupWindows" && patch[key] === true)
      error = "Global grouping is deprecated and inactive; use workspaceGroups or the local Group Windows action"
    else error = valueError(patch[key], schema.settings[key],
      key === "sidebarWidgets" && current ? current.sidebarWidgets : undefined)
    if (error) errors.push({ key: key, message: error })
  }
  return { ok: errors.length === 0, errors: errors }
}

// Internal merge for already-validated intents, not an IPC validation bypass.
function withPatch(current, patch) {
  var result = { ok: true, errors: [], changedKeys: [], settings: Object.create(null) }
  Object.keys(current).forEach(function(key) { result.settings[key] = current[key] })
  Object.keys(patch).forEach(function(key) {
    if (!own(current, key) || JSON.stringify(current[key]) !== JSON.stringify(patch[key]))
      result.changedKeys.push(key)
    result.settings[key] = patch[key]
  })
  return result
}

function applyPatch(current, patch, schema) {
  var result = validatePatch(patch, schema, current)
  if (result.ok) return withPatch(current, patch)
  result.changedKeys = []
  return result
}

function preferenceResetPatch(defaults, schema) {
  var patch = Object.create(null)
  Object.keys(defaults).forEach(function(key) {
    if (own(schema.settings, key) && schema.settings[key].resetWithPreferences !== false)
      patch[key] = defaults[key]
  })
  return patch
}

function identityIndex(ids, key) {
  for (var i = 0; i < ids.length; ++i)
    if (canonicalApplicationId(ids[i]) === key) return i
  return -1
}

function exactEntry(entries, key) {
  // DesktopEntries exposes an array-like QObject list, not necessarily an Array.
  for (var i = 0; i < entries.length; ++i)
    if (entries[i] && canonicalApplicationId(entries[i].id) === key) return entries[i]
  return null
}

function storedIdentity(current, entries, id) {
  var key = canonicalApplicationId(id)
  var pins = Array.isArray(current.pinned) ? current.pinned : []
  var hidden = Array.isArray(current.hiddenApplications) ? current.hiddenApplications : []
  var index = identityIndex(pins, key)
  if (index >= 0) return pins[index]
  index = identityIndex(hidden, key)
  if (index >= 0) return hidden[index]
  var entry = exactEntry(entries, key)
  return String(entry ? entry.id : id).trim().replace(/\.desktop$/i, "")
}

function applicationRows(current, entries, args) {
  var pins = Array.isArray(current.pinned) ? current.pinned : []
  var hidden = Array.isArray(current.hiddenApplications) ? current.hiddenApplications : []
  var ids = args.pinned ? pins.slice() : args.hidden ? hidden.slice() : []
  if (!args.pinned && !args.hidden) {
    for (var e = 0; e < entries.length; ++e)
      if (entries[e] && canonicalApplicationId(entries[e].id))
        ids.push(storedIdentity(current, entries, entries[e].id))
    ids = ids.concat(pins, hidden)
  }
  var rows = []
  var seen = Object.create(null)
  var query = args.query === undefined ? "" : args.query.toLowerCase()
  for (var i = 0; i < ids.length; ++i) {
    var id = ids[i]
    var key = canonicalApplicationId(id)
    if (!key || own(seen, key)) continue
    seen[key] = true
    var entry = exactEntry(entries, key)
    var name = entry && entry.name ? String(entry.name) : id
    if (query && key.indexOf(query) < 0 && name.toLowerCase().indexOf(query) < 0) continue
    var pin = identityIndex(pins, key)
    rows.push({ id: id, name: name, available: entry !== null, pinned: pin >= 0,
      hidden: identityIndex(hidden, key) >= 0, pinnedIndex: pin >= 0 ? pin : null })
  }
  return rows
}

function rejectedIntent(key, message) {
  return { ok: false, errors: [{ key: key, message: message }], changedKeys: [] }
}

function applicationIntent(current, entries, action, args) {
  if (action === "show" && args.all === true) return withPatch(current, { hiddenApplications: [] })
  var key = canonicalApplicationId(args.id)
  if (!key) return rejectedIntent("id", "Invalid application ID")
  var field = action === "hide" || action === "show" ? "hiddenApplications" : "pinned"
  var value = current[field]
  if (!Array.isArray(value)) return rejectedIntent(field, "Repair the existing non-array setting first")
  var list = value.slice()
  var index = identityIndex(list, key)
  if (action === "move") {
    var targetKey = canonicalApplicationId(args.before === undefined ? args.after : args.before)
    var target = identityIndex(list, targetKey)
    if (!targetKey || key === targetKey || index < 0 || target < 0)
      return rejectedIntent("id", "Move requires two different pinned application IDs")
    var moved = list.splice(index, 1)[0]
    target = identityIndex(list, targetKey)
    list.splice(target + (args.after === undefined ? 0 : 1), 0, moved)
  } else if (action === "pin" || action === "hide") {
    if (index < 0) list.push(storedIdentity(current, entries, args.id))
  } else if (action === "unpin" || action === "show") {
    list = list.filter(function(id) { return canonicalApplicationId(id) !== key })
  } else return rejectedIntent("action", "Unsupported application intent")
  var patch = Object.create(null)
  patch[field] = list
  return withPatch(current, patch)
}

function workspaceGroupIntent(current, entries, action, args) {
  var desktopKey = canonicalApplicationId(args && args.desktopId)
  var workspace = DockWorkspaceGroupModel.canonicalWorkspaceTarget(args && args.workspace)
  if (!desktopKey) return rejectedIntent("desktopId", "Invalid application ID")
  if (!workspace) return rejectedIntent("workspace", "Invalid canonical workspace identity")
  var existing = own(current, "workspaceGroups") ? current.workspaceGroups : []
  var existingError = DockWorkspaceGroupModel.workspaceGroupsError(existing)
  if (existingError) return rejectedIntent("workspaceGroups", "Repair workspaceGroups first: " + existingError)
  var list = existing.map(function(entry) {
    return { desktopId: entry.desktopId, workspace: entry.workspace }
  })
  var index = -1
  for (var i = 0; i < list.length; ++i) {
    if (canonicalApplicationId(list[i].desktopId) === desktopKey
        && list[i].workspace === workspace) {
      index = i
      break
    }
  }
  if (action === "group") {
    if (index < 0) {
      var entry = exactEntry(entries || [], desktopKey)
      var desktopId = entry && entry.id ? String(entry.id) : String(args.desktopId || "")
      if (!DockWorkspaceGroupModel.persistedApplicationId(desktopId))
        return rejectedIntent("desktopId", "Application identity cannot be persisted canonically")
      list.push({ desktopId: desktopId, workspace: workspace })
    }
  } else if (action === "ungroup") {
    if (index >= 0) list.splice(index, 1)
  } else return rejectedIntent("action", "Unsupported workspace group intent")
  return withPatch(current, { workspaceGroups: list })
}

function effectiveIcons(value) {
  return DockIconModel.normalizeOverrides(value)
}

function iconsChanged(before, after) {
  var previous = effectiveIcons(before)
  var next = effectiveIcons(after)
  var keys = Object.keys(next)
  return keys.length !== Object.keys(previous).length
    || keys.some(function(key) { return next[key] !== previous[key] })
}

function iconKey(value) {
  if (typeof value !== "string" || /[\x7f/\\]/.test(value)) return ""
  for (var i = 0; i < value.length; ++i) {
    if (value.charCodeAt(i) < 32) return ""
  }
  return DockIconModel.normalizeOverrideKey(value)
}



function normalizedWindowRule(value) {
  var rules = DockIconModel.normalizeWindowRules([value])
  return rules.length === 1 ? rules[0] : null
}

function windowRulesEqual(left, right) {
  var a = normalizedWindowRule(left)
  var b = normalizedWindowRule(right)
  return !!a && !!b
    && DockIconModel.windowRuleKey(a.appId, a.titlePattern) === DockIconModel.windowRuleKey(b.appId, b.titlePattern)
    && a.source === b.source
}

function windowRuleConflict(message) {
  var result = rejectedIntent("windowIconOverrides", message)
  result.errorCode = "E_CONFLICT"
  return result
}

function windowIconsChanged(before, after) {
  var previous = DockIconModel.normalizeWindowRules(before)
  var next = DockIconModel.normalizeWindowRules(after)
  return JSON.stringify(previous) !== JSON.stringify(next)
}

function windowIconIntent(current, action, args) {
  args = args || {}
  var original = own(current, "windowIconOverrides") ? current.windowIconOverrides : []
  var existingError = DockIconModel.windowRulesError(original)
  if (existingError)
    return rejectedIntent("windowIconOverrides", "Repair windowIconOverrides first: " + existingError)

  var list = original.map(function(rule) {
    return { appId: rule.appId, titlePattern: rule.titlePattern, source: rule.source }
  })
  var appId = DockIconModel.normalizeWindowAppId(args.appId)
  var titlePattern = DockIconModel.normalizeTitlePattern(args.titlePattern)
  var key = DockIconModel.windowRuleKey(appId, titlePattern)
  if (!appId) return rejectedIntent("appId", "Invalid raw Wayland application ID")
  if (!titlePattern) return rejectedIntent("titlePattern",
    "Title pattern must be 1-200 characters and contain no control characters")
  if (!key) return rejectedIntent("titlePattern", "Invalid title pattern")

  var source = action === "reset" ? null : DockIconModel.normalizeSource(args.source)
  if (action !== "set" && action !== "reset")
    return rejectedIntent("action", "Unsupported window icon intent")
  if (action === "set" && !source)
    return rejectedIntent("source", "Expected a local PNG or SVG source")

  var mode = args.mode === "dialog" ? "dialog" : "cli"
  var originalKey = String(args.originalKey || "")
  var index = -1
  for (var i = 0; i < list.length; ++i) {
    if (DockIconModel.windowRuleKey(list[i].appId, list[i].titlePattern)
        === (mode === "dialog" && originalKey ? originalKey : key)) {
      index = i
      break
    }
  }

  if (mode === "dialog") {
    if (originalKey) {
      if (index < 0) return windowRuleConflict("The icon rule changed or was deleted while the dialog was open.")
      if (!windowRulesEqual(list[index], args.expected))
        return windowRuleConflict("The icon rule changed while the dialog was open.")
      for (var d = 0; d < list.length; ++d) {
        if (d !== index && DockIconModel.windowRuleKey(list[d].appId, list[d].titlePattern) === key)
          return rejectedIntent("titlePattern", "Another rule already uses this application ID and title pattern.")
      }
      if (action === "reset") list.splice(index, 1)
      else list[index] = { appId: appId, titlePattern: titlePattern, source: source }
    } else {
      for (var n = 0; n < list.length; ++n) {
        if (DockIconModel.windowRuleKey(list[n].appId, list[n].titlePattern) === key)
          return windowRuleConflict("A matching icon rule was created while the dialog was open.")
      }
      if (action === "reset") return withPatch(current, {})
      list.push({ appId: appId, titlePattern: titlePattern, source: source })
    }
  } else {
    if (action === "reset") {
      if (index < 0) return withPatch(current, {})
      list.splice(index, 1)
    } else {
      var nextRule = { appId: appId, titlePattern: titlePattern, source: source }
      if (index < 0) list.push(nextRule)
      else list[index] = nextRule
    }
  }

  var error = DockIconModel.windowRulesError(list)
  if (error) return rejectedIntent("windowIconOverrides", error)
  if (JSON.stringify(original) === JSON.stringify(list)) return withPatch(current, {})
  return withPatch(current, { windowIconOverrides: list })
}

function iconIntent(current, id, sourceOrNull) {
  var key = iconKey(id)
  if (!key) return rejectedIntent("id", "Invalid application ID")
  // Reuse the retained validator for the single intent. Do not normalize or
  // prune unrelated legacy entries in the user's requested map on a one-app edit.
  var intent = DockIconModel.applyOverride({}, key, sourceOrNull)
  if (!intent.ok) return rejectedIntent("source", intent.error)
  var original = isObject(current.iconOverrides) ? current.iconOverrides : {}
  var aliases = Object.keys(original).filter(function(name) { return iconKey(name) === key })
  if (sourceOrNull === null && aliases.length === 0) return withPatch(current, {})
  if (sourceOrNull !== null && aliases.length === 1
      && DockIconModel.normalizeSource(original[aliases[0]]) === intent.overrides[key])
    return withPatch(current, {})
  var updated = Object.create(null)
  Object.keys(original).forEach(function(name) {
    if (iconKey(name) !== key) updated[name] = original[name]
  })
  if (sourceOrNull !== null) updated[key] = intent.overrides[key]
  return withPatch(current, { iconOverrides: updated })
}

function iconTargetConflict(message) {
  var result = rejectedIntent("iconOverrides", message)
  result.errorCode = "E_CONFLICT"
  return result
}

function windowTargetArguments(target, originalKey, expected) {
  return {
    mode: "dialog",
    originalKey: originalKey || "",
    expected: expected ? { appId: expected.appId, titlePattern: expected.titlePattern,
      source: expected.source } : null,
    appId: target.appId,
    titlePattern: target.titlePattern,
    source: target.source
  }
}

// Removes the override the dialog captured, if any. App and profile entries
// carry the source seen when the dialog opened so a concurrent edit is refused.
function removeIconTarget(current, target) {
  if (!target) return withPatch(current, {})
  if (target.kind === "window")
    return windowIconIntent(current, "reset", windowTargetArguments(target, target.key, {
      appId: target.appId, titlePattern: target.titlePattern, source: target.source
    }))
  if (target.kind !== "app" && target.kind !== "profile")
    return rejectedIntent("kind", "Unsupported icon target")
  var key = iconKey(target.key)
  if (!key) return rejectedIntent("id", "Invalid application ID")
  var present = DockIconModel.normalizeOverrides(current.iconOverrides)[key] || ""
  if (present !== DockIconModel.normalizeSource(target.source))
    return iconTargetConflict("The icon changed while the dialog was open.")
  return iconIntent(current, key, null)
}

function setIconTarget(current, target) {
  if (!isObject(target) || !own(target, "expected"))
    return rejectedIntent("expected", "An opening destination snapshot is required.")
  if (target.kind === "window") {
    var expected = target.expected
    if (expected !== null && (!isObject(expected)
        || expected.key !== DockIconModel.windowRuleKey(target.appId, target.titlePattern)
        || expected.key !== DockIconModel.windowRuleKey(expected.appId, expected.titlePattern)
        || !DockIconModel.normalizeSource(expected.source)))
      return rejectedIntent("expected", "Invalid opening title-rule snapshot.")
    return windowIconIntent(current, "set",
      windowTargetArguments(target, expected ? expected.key : "", expected))
  }
  if (target.kind !== "app" && target.kind !== "profile")
    return rejectedIntent("kind", "Unsupported icon target")
  var key = iconKey(target.key)
  if (!key) return rejectedIntent("id", "Invalid application ID")
  if (typeof target.expected !== "string"
      || (target.expected !== "" && DockIconModel.normalizeSource(target.expected) !== target.expected))
    return rejectedIntent("expected", "Invalid opening icon snapshot.")
  var present = DockIconModel.normalizeOverrides(current.iconOverrides)[key] || ""
  if (present !== target.expected)
    return iconTargetConflict("The destination icon changed while the dialog was open.")
  if (!DockIconModel.normalizeSource(target.source))
    return rejectedIntent("source", "Expected a local PNG or SVG source")
  return iconIntent(current, key, target.source)
}

// Validate both sides against the same live snapshot BEFORE composing a result.
// These pure intents never write; the host commits their final patch once.
function iconChangeIntent(current, args) {
  args = args || {}
  var remove = args.remove || null
  var set = args.set || null
  var first = removeIconTarget(current, remove)
  if (!first.ok || !set) return first
  var second = setIconTarget(current, set)
  if (!second.ok) return second

  if (remove && remove.kind === "window" && set.kind === "window") {
    if (set.expected && set.expected.key !== remove.key)
      return rejectedIntent("titlePattern", "Another title rule already uses “" + set.titlePattern
        + "”. Change that rule's icon from one of its windows instead.")
    // Renaming to an absent destination must replace the captured rule in place,
    // not remove it and append a new rule at the end of the precedence list.
    return windowIconIntent(current, "set", windowTargetArguments(set, remove.key,
      set.expected || remove))
  }

  var patch = {}
  first.changedKeys.forEach(function(key) { patch[key] = first.settings[key] })
  second.changedKeys.forEach(function(key) { patch[key] = second.settings[key] })
  if (remove && remove.kind !== "window" && set.kind !== "window") {
    // The set subsumes a same-key removal. Reuse its result so an unchanged
    // source preserves legacy spelling/order and remains a no-write operation.
    if (iconKey(remove.key) === iconKey(set.key)) return second
    // Different keys in the same map: compose only after both snapshots passed.
    var combined = iconIntent(first.settings, set.key, set.source)
    patch.iconOverrides = combined.settings.iconOverrides
  }
  return withPatch(current, patch)
}
