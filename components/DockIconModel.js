.pragma library

function normalizeKey(value) {
  if (typeof value !== "string") return ""
  var key = value.trim().toLowerCase().replace(/\.desktop$/, "")
  var reserved = Object.getOwnPropertyNames(Object.prototype).map(function(name) {
    return name.toLowerCase()
  })
  return !key || key === "unknown-application" || key === "prototype"
    || reserved.indexOf(key) >= 0 ? "" : key
}

function normalizeProfileSegment(value) {
  if (typeof value !== "string") return ""
  var segment = value.trim().replace(/\s+/g, " ")
  return !segment || /[\x00-\x1f\x7f/\\@]/.test(segment) ? "" : segment
}

// Profile-aware keys read "id@profile:Dir" (e.g. google-chrome@profile:Profile 1).
function profileOverrideKey(desktopId, profileKey) {
  var id = normalizeKey(desktopId)
  var profile = normalizeProfileSegment(profileKey)
  return id && profile ? id + "@profile:" + profile : ""
}

function splitProfileKey(value) {
  if (typeof value !== "string") return null
  var marker = value.indexOf("@profile:")
  if (marker < 0) return null
  var id = normalizeKey(value.slice(0, marker))
  var profile = normalizeProfileSegment(value.slice(marker + 9))
  return id && profile ? { id: id, profile: profile } : null
}

function localFileUrl(value) {
  if (typeof value !== "string" || !value) return ""
  var path = value
  if (/^file:/i.test(value)) {
    var match = /^file:\/\/(?:localhost)?(\/[^?#]*)$/i.exec(value)
    if (!match) return ""
    try {
      path = decodeURIComponent(match[1])
    } catch (error) {
      return ""
    }
  }
  if (path[0] !== "/" || /[\u0000-\u001f\u007f]/.test(path)) return ""
  var parts = []
  var segments = path.split("/")
  for (var i = 0; i < segments.length; i++) {
    if (segments[i] === "..") parts.pop()
    else if (segments[i] && segments[i] !== ".") parts.push(segments[i])
  }
  try {
    return "file:///" + parts.map(function(part) {
      return encodeURIComponent(part)
    }).join("/") + (path.endsWith("/") && parts.length ? "/" : "")
  } catch (error) {
    return ""
  }
}

function faviconFileUrl(value) {
  var url = localFileUrl(value)
  return /\.(png|svg|ico|jpe?g|webp|gif)$/i.test(url) ? url : ""
}

function normalizeSource(value) {
  var url = localFileUrl(value)
  return /\.(png|svg)$/i.test(url) ? url : ""
}

// omarchy-file-select prints one local path (or URI) per line; the dialog
// asks for a single file, so only the first non-empty line counts.
function chosenFileSource(output) {
  var lines = String(output || "").split(/\r?\n/)
  for (var i = 0; i < lines.length; i++)
    if (lines[i] !== "") return normalizeSource(lines[i])
  return ""
}

function normalizeOverrides(value) {
  var result = {}
  if (!value || typeof value !== "object" || Array.isArray(value)) return result
  Object.keys(value).forEach(function(rawKey) {
    var key = normalizeOverrideKey(rawKey)
    var source = normalizeSource(value[rawKey])
    if (key && source) result[key] = source
  })
  return result
}

// Override map keys are either plain desktop IDs or profile-aware keys.
function normalizeOverrideKey(value) {
  var profileKey = splitProfileKey(value)
  return profileKey ? profileKey.id + "@profile:" + profileKey.profile
    : normalizeKey(value)
}

function applyOverride(overrides, desktopId, sourceOrNull) {
  var updated = normalizeOverrides(overrides)
  var key = normalizeOverrideKey(desktopId)
  var source = sourceOrNull === null ? null : normalizeSource(sourceOrNull)
  if (!key || source === "")
    return { ok: false, changed: false, overrides: updated,
      error: !key ? "Invalid application ID" : "Select a local PNG or SVG file" }
  var changed = source === null ? Object.prototype.hasOwnProperty.call(updated, key)
    : updated[key] !== source
  if (source === null) delete updated[key]
  else updated[key] = source
  return { ok: true, changed: changed, overrides: updated, error: "" }
}

function normalizeWindowAppId(value) {
  if (typeof value !== "string") return ""
  var id = value.trim().toLowerCase()
  return !id || /[\x00-\x1f\x7f]/.test(id) ? "" : id
}

function normalizeTitlePattern(value) {
  if (typeof value !== "string") return ""
  var pattern = value.trim()
  return !pattern || pattern.length > 200 || /[\x00-\x1f\x7f]/.test(pattern)
    ? "" : pattern
}

function windowRuleKey(appId, titlePattern) {
  var app = normalizeWindowAppId(appId)
  var pattern = normalizeTitlePattern(titlePattern)
  if (!app || !pattern) return ""
  pattern = pattern.toLowerCase()
  return app.length + ":" + app + "|" + pattern.length + ":" + pattern
}

function windowRulesError(value) {
  if (!Array.isArray(value)) return "Expected an array of window icon override rules"
  var seen = Object.create(null)
  for (var i = 0; i < value.length; ++i) {
    var rule = value[i]
    if (!rule || typeof rule !== "object" || Array.isArray(rule))
      return "Expected a window icon override object at index " + i
    var keys = Object.keys(rule).sort()
    if (keys.length !== 3 || keys[0] !== "appId" || keys[1] !== "source"
        || keys[2] !== "titlePattern")
      return "Window icon override entries require only appId, titlePattern and source at index " + i
    var appId = normalizeWindowAppId(rule.appId)
    if (!appId) return "Invalid raw Wayland appId at index " + i
    if (typeof rule.titlePattern !== "string" || !rule.titlePattern.trim())
      return "Title pattern must not be empty at index " + i
    if (rule.titlePattern.trim().length > 200)
      return "Title pattern must be at most 200 characters at index " + i
    if (/[\x00-\x1f\x7f]/.test(rule.titlePattern))
      return "Title pattern must not contain control characters at index " + i
    var pattern = normalizeTitlePattern(rule.titlePattern)
    if (!pattern) return "Invalid title pattern at index " + i
    if (!normalizeSource(rule.source))
      return "Expected a local PNG or SVG source at index " + i
    var key = windowRuleKey(appId, pattern)
    if (Object.prototype.hasOwnProperty.call(seen, key))
      return "Duplicate window icon override rule at index " + i
    seen[key] = true
  }
  return ""
}

function normalizeWindowRules(value) {
  if (windowRulesError(value)) return []
  return value.map(function(rule) {
    return {
      appId: normalizeWindowAppId(rule.appId),
      titlePattern: normalizeTitlePattern(rule.titlePattern),
      source: normalizeSource(rule.source)
    }
  })
}

// Only '*' is special. Matching is case-insensitive and anchored to the full
// title unless the pattern explicitly begins/ends with '*'. No regex is built,
// so adversarial wildcard input cannot trigger regex backtracking.
function titlePatternMatches(titlePattern, title) {
  var pattern = String(titlePattern || "").toLowerCase()
  var text = String(title === undefined || title === null ? "" : title).toLowerCase()
  if (!pattern) return false
  if (pattern === "*") return true
  if (pattern.indexOf("*") < 0) return text === pattern

  var leadingWildcard = pattern.charAt(0) === "*"
  var trailingWildcard = pattern.charAt(pattern.length - 1) === "*"
  var parts = pattern.split("*").filter(function(part) { return part !== "" })
  if (parts.length === 0) return true

  var cursor = 0
  var limit = text.length
  if (!leadingWildcard) {
    var first = parts.shift()
    if (text.slice(0, first.length) !== first) return false
    cursor = first.length
  }
  if (!trailingWildcard) {
    var last = parts.pop()
    if (text.slice(text.length - last.length) !== last) return false
    limit = text.length - last.length
  }
  for (var i = 0; i < parts.length; ++i) {
    var position = text.indexOf(parts[i], cursor)
    if (position < 0 || position + parts[i].length > limit) return false
    cursor = position + parts[i].length
  }
  return cursor <= limit
}

function matchWindowRule(rules, appId, title) {
  var wanted = normalizeWindowAppId(appId)
  if (!wanted || !Array.isArray(rules)) return null
  for (var i = 0; i < rules.length; ++i) {
    var rule = rules[i]
    if (!rule || rule.appId !== wanted
        || !titlePatternMatches(rule.titlePattern, title)) continue
    return {
      appId: rule.appId,
      titlePattern: rule.titlePattern,
      source: rule.source,
      key: windowRuleKey(rule.appId, rule.titlePattern)
    }
  }
  return null
}

// The Change Icon dialog offers "title contains TEXT", saved as *TEXT*. A
// literal '*' stays out of contains mode so the saved rule means what it says.
function containsToPattern(text) {
  var value = typeof text === "string" ? text.trim() : ""
  if (!value) return { ok: false, pattern: "", error: "Type part of the window title." }
  if (value.indexOf("*") >= 0)
    return { ok: false, pattern: "", error: "The title text cannot contain *." }
  if (/[\x00-\x1f\x7f]/.test(value))
    return { ok: false, pattern: "", error: "The title text must not contain control characters." }
  if (value.length > 198)
    return { ok: false, pattern: "", error: "The title text must be at most 198 characters." }
  return { ok: true, pattern: "*" + value + "*", error: "" }
}

// Returns TEXT for a *TEXT* rule, or null when the rule has another shape and
// must be shown as an exact pattern instead of being rewritten.
function patternToContains(pattern) {
  var value = normalizeTitlePattern(pattern)
  if (value.length < 3 || value.charAt(0) !== "*" || value.charAt(value.length - 1) !== "*")
    return null
  var inner = value.slice(1, -1)
  return inner && inner.indexOf("*") < 0 && inner.trim() === inner ? inner : null
}

// Capture requested values, not live bindings or normalized/pruned collections.
function iconSettingsSnapshot(settings) {
  var value = settings || {}
  return JSON.parse(JSON.stringify({
    iconOverrides: value.iconOverrides || {},
    windowIconOverrides: value.windowIconOverrides || []
  }))
}

// Exact destination lookup: a title-pattern key is not a window-title match.
function windowIconTarget(settings, appId, titlePattern) {
  var key = windowRuleKey(appId, titlePattern)
  var rules = normalizeWindowRules((settings || {}).windowIconOverrides)
  for (var i = 0; i < rules.length; ++i) {
    var rule = rules[i]
    if (windowRuleKey(rule.appId, rule.titlePattern) === key)
      return { key: key, appId: rule.appId, titlePattern: rule.titlePattern, source: rule.source }
  }
  return null
}

// The override currently deciding this item's artwork, using the renderer's
// precedence: window rule -> browser profile -> whole app.
function currentIconTarget(options) {
  var value = options || {}
  var settings = value.settings || {}
  var rule = value.appId ? matchWindowRule(
    normalizeWindowRules(settings.windowIconOverrides), value.appId, value.title) : null
  if (rule)
    return { kind: "window", key: rule.key, appId: rule.appId,
      titlePattern: rule.titlePattern, source: rule.source }
  var overrides = normalizeOverrides(settings.iconOverrides)
  var profileKey = profileOverrideKey(value.desktopId, value.profileKey)
  if (profileKey && overrides[profileKey])
    return { kind: "profile", key: profileKey, source: overrides[profileKey] }
  var appKey = normalizeKey(value.desktopId)
  if (appKey && overrides[appKey])
    return { kind: "app", key: appKey, source: overrides[appKey] }
  return { kind: "none", key: "", source: "" }
}

// Images already used by any override, latest additions first, so the dialog
// can offer them again without storing a separate history.
function recentIconSources(settings, limit) {
  var value = settings || {}
  var max = typeof limit === "number" && limit > 0 ? limit : 6
  var rules = normalizeWindowRules(value.windowIconOverrides).map(function(rule) {
    return rule.source
  })
  var overrides = normalizeOverrides(value.iconOverrides)
  var mapped = Object.keys(overrides).map(function(key) { return overrides[key] })
  var result = []
  rules.reverse().concat(mapped.reverse()).forEach(function(source) {
    if (source && result.indexOf(source) < 0 && result.length < max) result.push(source)
  })
  return result
}

// selection: { kind: "app" | "profile" | "window", profileKey, titlePattern }.
// windows: [{ title, profileKey, appId }]. Window rules require the raw app ID;
// app/profile choices deliberately span all raw IDs of the represented app.
function previewMatches(windows, selection) {
  var list = Array.isArray(windows) ? windows : []
  var choice = selection || {}
  var wantedProfile = normalizeProfileSegment(choice.profileKey)
  var wantedApp = normalizeWindowAppId(choice.appId)
  var flags = list.map(function(window) {
    var item = window || {}
    if (choice.kind === "app") return true
    if (choice.kind === "profile")
      return !!wantedProfile && normalizeProfileSegment(item.profileKey) === wantedProfile
    if (choice.kind === "window")
      return !!wantedApp && normalizeWindowAppId(item.appId) === wantedApp
        && !!normalizeTitlePattern(choice.titlePattern)
        && titlePatternMatches(normalizeTitlePattern(choice.titlePattern), item.title)
    return false
  })
  return {
    flags: flags,
    count: flags.filter(function(flag) { return flag }).length
  }
}

// Short file name for dialog labels, e.g. file:///icons/My%20Sun.svg -> My Sun.svg.
function sourceFileName(source) {
  var url = String(source || "")
  var name = url.slice(url.lastIndexOf("/") + 1)
  try {
    return decodeURIComponent(name)
  } catch (error) {
    return name
  }
}

// Wider scopes rank lower; a narrower choice leaves a wider override in place.
function scopeRank(kind) {
  return kind === "window" ? 2 : kind === "profile" ? 1 : kind === "app" ? 0 : -1
}

// Explains the override that currently applies, or "" when none does.
function currentIconNotice(current, appName, profileName) {
  var value = current || {}
  var file = sourceFileName(value.source)
  var app = String(appName || "This app")
  if (value.kind === "window") {
    var contains = patternToContains(value.titlePattern)
    return "This window uses " + file + " because its title "
      + (contains !== null ? "contains \u201c" + contains + "\u201d"
        : "matches \u201c" + value.titlePattern + "\u201d")
      + ". Editing this updates that setting."
  }
  if (value.kind === "profile")
    return "The " + String(profileName || "browser") + " profile uses a custom icon (" + file + ")."
  if (value.kind === "app")
    return app + " uses a custom icon (" + file + ") for all its windows."
  return ""
}

// choice: { kind, source, desktopId, profileKey, appId, titleMode: "contains" |
// "exact", titleText }. source "" means the app's own icon (Reset).
// Returns { ok, error, unchanged, args: { remove, set } } for saveIconChange.
function iconChangeArguments(current, choice, openedSettings) {
  var captured = current && current.kind && current.kind !== "none" ? current : null
  var value = choice || {}
  var source = String(value.source || "")
  var result = { ok: true, error: "", unchanged: false, args: { remove: null, set: null } }
  if (!source) {
    result.unchanged = !captured
    result.args.remove = captured
    return result
  }
  if (!normalizeSource(source))
    return { ok: false, error: "Choose a local PNG or SVG file.", unchanged: false, args: null }

  var set = null
  if (value.kind === "app") {
    var appKey = normalizeKey(value.desktopId)
    if (!appKey) return { ok: false, error: "This app has no desktop ID.", unchanged: false, args: null }
    set = { kind: "app", key: appKey, source: source }
  } else if (value.kind === "profile") {
    var profileKey = profileOverrideKey(value.desktopId, value.profileKey)
    if (!profileKey)
      return { ok: false, error: "This window has no browser profile.", unchanged: false, args: null }
    set = { kind: "profile", key: profileKey, source: source }
  } else if (value.kind === "window") {
    var appId = normalizeWindowAppId(value.appId)
    if (!appId)
      return { ok: false, error: "This window has no Wayland app ID.", unchanged: false, args: null }
    var pattern = ""
    if (value.titleMode === "exact") {
      pattern = normalizeTitlePattern(value.titleText)
      if (!pattern)
        return { ok: false, error: "Enter a title pattern of at most 200 characters.",
          unchanged: false, args: null }
    } else {
      var contains = containsToPattern(value.titleText)
      if (!contains.ok) return { ok: false, error: contains.error, unchanged: false, args: null }
      pattern = contains.pattern
    }
    set = { kind: "window", appId: appId, titlePattern: pattern, source: source }
  } else {
    return { ok: false, error: "Choose which windows use the image.", unchanged: false, args: null }
  }

  // Every destination expectation comes from the opening snapshot, including
  // absence. Never obtain it from the live settings at Save time.
  set.expected = set.kind === "window"
    ? windowIconTarget(openedSettings, set.appId, set.titlePattern)
    : normalizeOverrides((openedSettings || {}).iconOverrides)[set.key] || ""
  if (captured && captured.kind === "window" && set.kind === "window"
      && set.expected && set.expected.key !== captured.key)
    return { ok: false, error: "Another title rule already uses “" + set.titlePattern
      + "”. Change that rule's icon from one of its windows instead.", unchanged: false, args: null }

  var setKey = set.kind === "window" ? windowRuleKey(set.appId, set.titlePattern) : set.key
  if (captured && captured.kind === set.kind && captured.key === setKey
      && captured.source === normalizeSource(source))
    result.unchanged = true
  // Replace the captured override when the new scope is as wide or wider, so it
  // no longer shadows the new choice; a narrower choice keeps the wider one.
  if (captured && scopeRank(set.kind) <= scopeRank(captured.kind)) result.args.remove = captured
  result.args.set = set
  return result
}

// Resolve configuration precedence from the same draft used by Save. Image
// decoding remains the renderer's job; a source change is not render proof.
function previewIconChanges(beforeSettings, afterSettings, windows, desktopId, selection) {
  var list = Array.isArray(windows) ? windows : []
  var choice = selection || {}
  var scope = previewMatches(list, choice)
  var source = normalizeSource(choice.source)
  var changed = 0
  var shadowed = 0
  var afterKinds = []
  var rows = list.map(function(window, index) {
    var item = window || {}
    var options = { desktopId: desktopId, profileKey: item.profileKey,
      appId: item.appId, title: item.title }
    options.settings = beforeSettings
    var before = currentIconTarget(options)
    options.settings = afterSettings
    var after = currentIconTarget(options)
    var differs = before.source !== after.source
    if (differs) {
      changed++
      if (afterKinds.indexOf(after.kind) < 0) afterKinds.push(after.kind)
    }
    if (source && scope.flags[index] && after.source !== source
        && scopeRank(after.kind) >= scopeRank(choice.kind)) shadowed++
    return { before: before, after: after, changed: differs, inScope: scope.flags[index] }
  })
  return { rows: rows, changed: changed, shadowed: shadowed,
    afterKind: afterKinds.length === 1 ? afterKinds[0] : afterKinds.length ? "mixed" : "none" }
}

// Counts describe resolved source changes, not just scope membership.
function previewSummary(options) {
  var value = options || {}
  var total = Number(value.total) || 0
  var changed = Number(value.changed) || 0
  var shadowed = Number(value.shadowed) || 0
  var app = String(value.appName || "app")
  if (total <= 0) return ""
  if (!value.resetting && value.kind === "window" && value.hasPattern === false)
    return "Type part of a window title to choose which windows change."
  var noun = "open " + app + " window" + (total === 1 ? "" : "s")
  var text = "Preview: "
  if (changed <= 0) {
    text += "no " + noun + " change."
  } else if (value.resetting) {
    var destination = value.afterKind === "app" || value.afterKind === "profile"
      ? app + "'s custom icon"
      : value.afterKind === "window" ? "another title-rule icon"
        : value.afterKind === "mixed" ? "their remaining icon settings" : "the app's own icon"
    text += changed + " of " + total + " " + noun
      + (changed === 1 ? " goes" : " go") + " back to " + destination + "."
  } else {
    text += changed + " of " + total + " " + noun + (changed === 1 ? " changes." : " change.")
    text += " New matching windows use this setting too."
  }
  if (shadowed > 0)
    text += " " + shadowed + (shadowed === 1 ? " keeps" : " keep")
      + " their own title-rule/profile icon."
  return text
}

function candidates(windowUrl, profileUrl, overrideUrl, desktopUrl, genericUrl) {
  var result = []
  // Four arguments retain the historic profile -> app -> desktop -> generic
  // order. Five arguments opt into window -> profile -> app -> desktop -> generic.
  var sources = arguments.length >= 5
    ? [windowUrl, profileUrl, overrideUrl, desktopUrl, genericUrl]
    : [windowUrl, profileUrl, overrideUrl, desktopUrl]
  sources.forEach(function(source) {
    if (typeof source === "string" && source && result.indexOf(source) < 0)
      result.push(source)
  })
  return result
}

// --- Dockrail-managed icon storage (FDM-1068) -------------------------
// Python twin: scripts/dockrail_icons.py. Successful custom-icon selections
// persist a Dockrail-owned copy under <dataRoot>/icons, never the user's
// source path. Helpers below only classify references; copying, migration
// and pruning run through the bundled helper.

// file:// prefix of the managed icons directory. dataRoot must already be
// resolved (the startup migration helper provides it that way).
function managedIconPrefix(dataRoot) {
  var root = String(dataRoot || "").trim()
  if (!root || root.charAt(0) !== "/") return ""
  var parts = []
  root.split("/").forEach(function(segment) {
    if (segment === "..") parts.pop()
    else if (segment && segment !== ".") parts.push(segment)
  })
  return "file:///" + parts.map(function(part) { return encodeURIComponent(part) }).join("/")
    + "/icons/"
}

function isManagedIconSource(source, dataRoot) {
  var prefix = managedIconPrefix(dataRoot)
  var url = normalizeSource(source)
  return !!prefix && !!url && url.indexOf(prefix) === 0
}

// Ownership predicate: only names minted by dockrail_icons.py
// ("<sanitized-key>-<sha1[:12]>.<ext>") are ever deletion candidates.
function isManagedIconFileName(name) {
  return /^[A-Za-z0-9._-]+-[0-9a-f]{12}\.png$/.test(String(name || ""))
    || /^[A-Za-z0-9._-]+-[0-9a-f]{12}\.svg$/.test(String(name || ""))
}

// Managed asset file names still referenced by any override mapping. The
// prune step deletes managed files outside this set, so shared assets used
// by two overrides naturally survive until the last reference disappears.
function referencedManagedIconFiles(settings, dataRoot) {
  var value = settings || {}
  var referenced = []
  function consider(source) {
    if (!isManagedIconSource(source, dataRoot)) return
    var name = String(source).replace(/\/+$/, "").split("/").pop()
    if (isManagedIconFileName(name) && referenced.indexOf(name) < 0)
      referenced.push(name)
  }
  var overrides = value.iconOverrides
  if (overrides && typeof overrides === "object" && !Array.isArray(overrides))
    Object.keys(overrides).forEach(function(key) { consider(overrides[key]) })
  var rules = Array.isArray(value.windowIconOverrides) ? value.windowIconOverrides : []
  rules.forEach(function(rule) { consider(rule && rule.source) })
  return referenced
}

// True when any valid custom icon reference points outside managed storage;
// the host runs the migration helper only while this holds.
function hasUnmanagedIconSources(settings, dataRoot) {
  var value = settings || {}
  var unmanaged = false
  function check(source) {
    var url = normalizeSource(source)
    if (url && !isManagedIconSource(url, dataRoot)) unmanaged = true
  }
  var overrides = value.iconOverrides
  if (overrides && typeof overrides === "object" && !Array.isArray(overrides))
    Object.keys(overrides).forEach(function(key) { check(overrides[key]) })
  var rules = Array.isArray(value.windowIconOverrides) ? value.windowIconOverrides : []
  rules.forEach(function(rule) { check(rule && rule.source) })
  return unmanaged
}

// Deterministic badge color for profiles without a photo.
function badgeColor(name) {
  var text = String(name || "").trim()
  var hash = 0
  for (var i = 0; i < text.length; i++)
    hash = (hash * 31 + text.charCodeAt(i)) >>> 0
  return "hsl(" + (hash % 360) + ", 55%, 50%)"
}
