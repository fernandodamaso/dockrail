.pragma library

// Internal source-registered providers only. This module never loads a URL,
// executes a command, owns a timer or emits desktop notifications.
function own(object, key) { return Object.prototype.hasOwnProperty.call(object, key) }
function validId(id) {
  return typeof id === "string" && id.length <= 64
    && /^[a-z][a-z0-9]*(?:[._-][a-z0-9]+)*$/.test(id)
    && ["constructor", "prototype", "__proto__"].indexOf(id) < 0
}
function listLike(value) {
  // Qt/QML often exposes JSON/settings arrays as array-like objects that fail
  // Array.isArray. Accept those without treating plain objects as lists.
  if (Array.isArray(value)) return value
  if (!value || typeof value !== "object" || typeof value.length !== "number") return null
  var length = Number(value.length)
  if (!isFinite(length) || length < 0 || Math.floor(length) !== length) return null
  var out = []
  for (var i = 0; i < length; ++i) out.push(value[i])
  return out
}
function requestedIds(value) {
  var list = listLike(value)
  if (!list) return []
  var seen = Object.create(null)
  return list.filter(function(id) {
    if (!validId(id) || own(seen, id)) return false
    seen[id] = true
    return true
  })
}
function idsError(value, registered) {
  var list = listLike(value)
  if (!list) return "Expected an array of registered widget IDs"
  var seen = Object.create(null)
  for (var i = 0; i < list.length; ++i) {
    var id = list[i]
    if (!validId(id)) return "Invalid widget ID at index " + i
    if (own(seen, id)) return "Duplicate widget ID at index " + i
    seen[id] = true
    if (!Array.isArray(registered) || registered.indexOf(id) < 0)
      return "Unregistered widget ID at index " + i
  }
  return ""
}
function collapsedMap(value) {
  var result = Object.create(null)
  if (!value || typeof value !== "object" || Array.isArray(value)) return result
  Object.keys(value).forEach(function(id) {
    if (validId(id) && typeof value[id] === "boolean") result[id] = value[id]
  })
  return result
}
function collapsedError(value) {
  if (!value || typeof value !== "object" || Array.isArray(value))
    return "Expected an object"
  var ids = Object.keys(value)
  for (var i = 0; i < ids.length; ++i) {
    var id = ids[i]
    if (!validId(id)) return "Invalid widget ID: " + id
    if (typeof value[id] !== "boolean")
      return "Expected a boolean collapse flag for " + id
  }
  return ""
}
function descriptorFor(registry, id) {
  if (!registry || !own(registry, id) || !validId(id)) return null
  var descriptor = registry[id]
  return descriptor && descriptor.id === id && typeof descriptor.acquire === "function"
    ? descriptor : null
}
function registeredIds(registry) {
  if (!registry || typeof registry !== "object") return []
  return Object.keys(registry).filter(function(id) {
    return descriptorFor(registry, id) !== null
  }).sort()
}
function registeredRows(registry) {
  return registeredIds(registry).map(function(id) {
    var descriptor = registry[id]
    return {
      id: id,
      label: descriptor && descriptor.label ? String(descriptor.label) : id,
      iconName: descriptor && descriptor.iconName ? String(descriptor.iconName) : "layout-grid",
      available: descriptor && descriptor.available !== false,
      manageable: !descriptor || descriptor.manageable !== false
    }
  })
}
function manageableRows(registry, enabledIds) {
  var enabled = requestedIds(enabledIds)
  return registeredRows(registry).filter(function(row) {
    return row.manageable || enabled.indexOf(row.id) >= 0
  })
}
function effectiveIds(value, registry) {
  return requestedIds(value).filter(function(id) { return descriptorFor(registry, id) !== null })
}
function validStatus(status) {
  return ["loading", "ready", "unavailable", "error"].indexOf(status) >= 0
}
function revision(value) {
  return typeof value === "number" && isFinite(value) && value >= 0
    && Math.floor(value) === value && value <= 9007199254740991
}
function finite(value, fallback) {
  return typeof value === "number" && isFinite(value) ? value : fallback
}
// Coordinates are logical pixels relative to a full-height edge panel. The
// compositor performs the final slide adjustment for other exclusive surfaces.
function popupGeometry(screenWidth, screenHeight, panelWidth, edge, anchorY, wantedWidth, wantedHeight) {
  var sw = Math.max(1, finite(screenWidth, 1))
  var sh = Math.max(1, finite(screenHeight, 1))
  var panel = Math.max(0, Math.min(sw, finite(panelWidth, 0)))
  var gap = Math.min(8, Math.max(0, sw - panel - 1))
  var remaining = Math.max(1, sw - panel - gap)
  var width = Math.max(1, Math.min(sw, remaining, finite(wantedWidth, 320)))
  var height = Math.max(1, Math.min(sh, finite(wantedHeight, 400)))
  var origin = edge === "right" ? sw - panel : 0
  var proposed = edge === "right" ? origin - gap - width : panel + gap
  var screenX = Math.max(0, Math.min(sw - width, proposed))
  var y = Math.max(0, Math.min(sh - height, finite(anchorY, 0) - height / 2))
  return {x:screenX - origin, y:y, width:width, height:height, screenX:screenX}
}
function emptyCounters() {
  return {acquisitions:0, releases:0, activations:0, suspensions:0,
    acceptedUpdates:0, ignoredUpdates:0, failures:0}
}
// Pure requested/effective readback, including dry runs. Never acquire a lease
// merely to answer a config/status request; do not expose view payloads here.
function describe(value, registry, runtime) {
  var ids = requestedIds(value)
  var current = Object.create(null)
  if (runtime && Array.isArray(runtime.rows)) runtime.rows.forEach(function(row) { current[row.id] = row })
  return {total:ids.length, truncated:Math.max(0, ids.length - 32),
    counters:runtime ? runtime.counters : emptyCounters(),
    rows:ids.slice(0, 32).map(function(id) {
      var descriptor = descriptorFor(registry, id)
      var live = current[id]
      return {id:id, registered:descriptor !== null,
        available:descriptor !== null && descriptor.available !== false,
        status:live ? live.status : descriptor && descriptor.available !== false ? "loading" : "unavailable",
        revision:live ? live.revision : 0, active:live ? live.active : false,
        errorCode:live ? live.errorCode : descriptor ? "" : "unregistered"}
    })}
}

// One manager per host-owned sidebar controller, never one per view. A provider
// lends a lease; only that lease decides how to reference-count shared backends.
// setActive(true, publish) gets a NEW generation callback on each activation.
function createManager(onChanged) {
  var entries = Object.create(null)
  var ordered = []
  var counters = emptyCounters()
  var disposed = false
  var batching = false
  var dirty = false
  function bump(key) { counters[key] = Math.min(1000000000, counters[key] + 1) }
  function changed() {
    if (disposed) return
    if (batching) { dirty = true; return }
    onChanged()
  }
  function failed(entry, code) {
    entry.status = "error"
    entry.errorCode = code
    entry.data = null
    bump("failures")
    changed()
  }
  function publishFor(entry, generation) {
    return function(value) {
      if (disposed || entries[entry.id] !== entry || !entry.active || entry.generation !== generation) {
        bump("ignoredUpdates")
        return
      }
      if (!value || !validStatus(value.status) || !revision(value.revision)) {
        failed(entry, "invalid-update")
        return
      }
      if (entry.received && value.revision <= entry.revision) {
        bump("ignoredUpdates")
        return
      }
      entry.received = true
      entry.status = value.status
      entry.revision = value.revision
      entry.data = value.status === "ready" ? value.data : null
      entry.errorCode = value.status === "error" ? "provider-error" : ""
      bump("acceptedUpdates")
      changed()
    }
  }
  function deactivate(entry) {
    ++entry.generation // Revoke callbacks BEFORE invoking any provider code.
    entry.data = null
    if (!entry.active) return
    entry.active = false
    bump("suspensions")
    try { entry.lease.setActive(false, null) }
    catch (error) { failed(entry, "suspend-failed") }
  }
  function release(entry) {
    deactivate(entry)
    var lease = entry.lease
    entry.lease = null
    if (!lease) return
    bump("releases")
    try { lease.release() }
    catch (error) { failed(entry, "release-failed") }
  }
  function activate(entry, active) {
    if (!entry.lease || entry.active === active) return
    if (!active) { deactivate(entry); changed(); return }
    entry.active = true
    entry.received = false
    entry.revision = 0
    entry.status = "loading"
    entry.errorCode = ""
    ++entry.generation
    bump("activations")
    try { entry.lease.setActive(true, publishFor(entry, entry.generation)) }
    catch (error) {
      release(entry)
      failed(entry, "activate-failed")
    }
    changed()
  }
  function acquire(entry, owner) {
    if (!entry.descriptor || entry.descriptor.available === false) return
    bump("acquisitions")
    try {
      var lease = entry.descriptor.acquire(owner)
      if (!lease || typeof lease.setActive !== "function" || typeof lease.release !== "function") {
        if (lease && typeof lease.release === "function") {
          bump("releases")
          try { lease.release() } catch (error) { bump("failures") }
        }
        failed(entry, "invalid-lease")
        return
      }
      entry.lease = lease
    } catch (error) { failed(entry, "acquire-failed") }
  }
  function newEntry(id, descriptor, owner) {
    var entry = {id:id, descriptor:descriptor, lease:null, active:false, generation:0, token:{},
      acquireFactory:descriptor ? descriptor.acquire : null,
      registeredAvailable:descriptor !== null && descriptor.available !== false,
      status:descriptor && descriptor.available !== false ? "loading" : "unavailable",
      revision:0, received:false, data:null, errorCode:descriptor ? "" : "unregistered"}
    entries[id] = entry
    acquire(entry, owner)
    return entry
  }
  return {
    reconcile:function(value, registry, active, owner) {
      if (disposed) return
      batching = true
      var next = requestedIds(value)
      if (JSON.stringify(next) !== JSON.stringify(ordered)) dirty = true
      Object.keys(entries).forEach(function(id) {
        if (next.indexOf(id) < 0) { release(entries[id]); delete entries[id]; dirty = true }
      })
      ordered = next
      ordered.forEach(function(id) {
        var descriptor = descriptorFor(registry, id)
        var entry = entries[id]
        // Metadata, snapshot revisions and view factories never restart a lease.
        // Only registry removal/replacement of its acquisition boundary does.
        if (entry && (Boolean(entry.descriptor) !== Boolean(descriptor)
            || entry.descriptor && descriptor && (entry.acquireFactory !== descriptor.acquire
              || entry.registeredAvailable !== (descriptor.available !== false)))) {
          release(entry)
          delete entries[id]
          entry = null
        }
        if (!entry) { entry = newEntry(id, descriptor, owner); dirty = true }
        else if (entry.descriptor !== descriptor) { entry.descriptor = descriptor; dirty = true }
        activate(entry, active === true)
      })
      batching = false
      if (dirty) { dirty = false; changed() }
    },
    ids:function() { return ordered.slice() },
    view:function(id) {
      var entry = entries[id]
      if (!entry) return null
      return {id:id, descriptor:entry.descriptor, token:entry.token, generation:entry.generation,
        registered:entry.descriptor !== null,
        available:entry.descriptor !== null && entry.descriptor.available !== false,
        status:entry.status, revision:entry.revision, active:entry.active, data:entry.data,
        provider:entry.lease ? entry.lease.provider : null, errorCode:entry.errorCode}
    },
    viewFailed:function(id, expected) {
      var entry = entries[id]
      if (disposed || !entry || !expected || expected.token !== entry.token
          || expected.generation !== entry.generation || expected.revision !== entry.revision) return
      if (entry.errorCode !== "view-error") failed(entry, "view-error")
    },
    diagnostics:function() {
      return {total:ordered.length, truncated:Math.max(0, ordered.length - 32),
        counters:Object.assign({}, counters), rows:ordered.slice(0, 32).map(function(id) {
          var entry = entries[id]
          return {id:id, registered:entry.descriptor !== null,
            available:entry.descriptor !== null && entry.descriptor.available !== false,
            status:entry.status, revision:entry.revision, active:entry.active, errorCode:entry.errorCode}
        })}
    },
    dispose:function() {
      if (disposed) return
      disposed = true
      Object.keys(entries).forEach(function(id) { release(entries[id]) })
      entries = Object.create(null)
      ordered = []
    }
  }
}

// Natural demands and allocations are logical pixels. Never allocate from a
// virtualized ListView estimate or persist a runtime clamp as a preference.
function sidebarSplitLayout(input) {
  input = input || {}
  var A = Math.max(0, finite(input.availableHeight, 0))
  var H = Math.max(0, finite(input.hierarchyContentHeight, 0))
  var Wh = Math.max(0, finite(input.widgetHeaderHeight, 0))
  var W = Math.max(0, finite(input.widgetContentHeight, 0))
  var count = Math.max(0, Math.floor(finite(input.presentedWidgetCount, 0)))
  var h = 0, w = 0
  if (input.rail === true || count === 0 || A < Wh) {
    h = Math.min(H, A)
  } else {
    var wanted = Math.min(Number.MAX_VALUE, Wh + W)
    var hmin = Math.min(H, Math.max(0, finite(input.minHierarchyHeight, 0)))
    var wmin = Math.min(wanted, Math.max(Wh, finite(input.minWidgetHeight, Wh)))
    if (A < hmin + wmin) {
      h = Math.min(hmin, Math.max(0, A - Wh))
    } else {
      var request = finite(input.requestedSplitPx, 0.55 * A)
      var cap = Math.max(hmin, Math.min(A - wmin, request))
      h = Math.min(H, Math.max(cap, A - wanted))
    }
    w = Math.min(wanted, Math.max(0, A - h))
  }
  return {hierarchyHeight:h, widgetHeight:w, blankHeight:Math.max(0, A - h - w)}
}

// Panel-local stable-ID scroll anchors. These helpers never write settings.
function widgetScrollAnchor(cards, contentY) {
  cards = cards || []
  var y = Math.max(0, finite(contentY, 0))
  var ids = cards.map(function(card) { return card.id })
  if (!cards.length) return {id:"", offset:0, ids:ids}
  var index = cards.length - 1
  for (var i = 0; i < cards.length; ++i) {
    if (cards[i].y + cards[i].height > y) { index = i; break }
  }
  return {id:cards[index].id, offset:y - cards[index].y, ids:ids}
}
function widgetScrollPosition(anchor, cards, maximum) {
  anchor = anchor || {}; cards = cards || []
  var ids = cards.map(function(card) { return card.id })
  var index = ids.indexOf(anchor.id), offset = finite(anchor.offset, 0)
  if (index < 0) {
    var old = anchor.ids || [], at = old.indexOf(anchor.id)
    offset = 0
    for (var i = at + 1; i < old.length && index < 0; ++i) index = ids.indexOf(old[i])
    for (var j = at - 1; j >= 0 && index < 0; --j) index = ids.indexOf(old[j])
  }
  var y = index < 0 ? 0 : cards[index].y + offset
  return Math.max(0, Math.min(Math.max(0, finite(maximum, 0)), y))
}
function widgetFocusScroll(y, height, contentY, viewportHeight, maximum) {
  y = finite(y, 0); height = Math.max(0, finite(height, 0))
  var top = finite(contentY, 0), size = Math.max(0, finite(viewportHeight, 0))
  var next = height > size || y < top ? y : y + height > top + size ? y + height - size : top
  return Math.max(0, Math.min(Math.max(0, finite(maximum, 0)), next))
}
