.pragma library
.import "DockModel.js" as DockModel
.import "DockWindowModel.js" as DockWindowModel

function activationTarget(identity) {
  return DockModel.normalizeWorkspaceTarget(
    identity.indexOf("id:") === 0 ? identity.slice(3) : identity)
}

function workspaceCompare(a, b) {
  var left = typeof a === "string" ? a : (a._monitorDragSortIdentity || a.identity)
  var right = typeof b === "string" ? b : (b._monitorDragSortIdentity || b.identity)
  var leftNumeric = left.indexOf("id:") === 0
  var rightNumeric = right.indexOf("id:") === 0
  if (leftNumeric && rightNumeric)
    return Number(left.slice(3)) - Number(right.slice(3))
  if (leftNumeric !== rightNumeric) return leftNumeric ? -1 : 1
  return left < right ? -1 : left > right ? 1 : 0
}

function monitorCompare(left, right) {
  var leftNumeric = /^id:[0-9]+$/.test(left)
  var rightNumeric = /^id:[0-9]+$/.test(right)
  if (leftNumeric && rightNumeric)
    return Number(left.slice(3)) - Number(right.slice(3))
  if (leftNumeric !== rightNumeric) return leftNumeric ? -1 : 1
  return left < right ? -1 : left > right ? 1 : 0
}

function finiteCoordinate(primary, fallback) {
  var raw = primary !== undefined ? primary : fallback
  if (raw === undefined || raw === null || raw === "" || typeof raw === "boolean")
    return null
  var value = Number(raw)
  return isFinite(value) ? value : null
}

function lexicalCompare(left, right) {
  return left < right ? -1 : left > right ? 1 : 0
}

function monitorMetadataCompare(left, right, monitorOrder) {
  var leftConfigured = monitorOrder.indexOf(left.connector)
  var rightConfigured = monitorOrder.indexOf(right.connector)
  if (leftConfigured >= 0 || rightConfigured >= 0) {
    if (leftConfigured < 0) return 1
    if (rightConfigured < 0) return -1
    if (leftConfigured !== rightConfigured) return leftConfigured - rightConfigured
  }
  var leftPositioned = left.x !== null && left.y !== null
  var rightPositioned = right.x !== null && right.y !== null
  if (leftPositioned !== rightPositioned) return leftPositioned ? -1 : 1
  if (leftPositioned && rightPositioned) {
    if (left.x !== right.x) return left.x - right.x
    if (left.y !== right.y) return left.y - right.y
  }
  var connectorOrder = lexicalCompare(left.connector, right.connector)
  return connectorOrder || monitorCompare(left.identity, right.identity)
}

function ownerEvidence(map, workspace) {
  if (!map[workspace]) map[workspace] = { seen: false, unresolved: false, owners: Object.create(null) }
  return map[workspace]
}

function addOwnerEvidence(map, workspace, owner, unresolved) {
  if (!workspace || !activationTarget(workspace)) return
  var evidence = ownerEvidence(map, workspace)
  evidence.seen = true
  if (unresolved === true || !owner) evidence.unresolved = true
  else evidence.owners[owner] = true
}

function resolvedOwner(evidence) {
  if (!evidence || !evidence.seen) return { seen: false, owner: "" }
  var owners = Object.keys(evidence.owners)
  if (evidence.unresolved || owners.length !== 1) return { seen: true, owner: "" }
  return { seen: true, owner: owners[0] }
}

function monitorProperty(name, descriptor, ipc) {
  return String(
    ipc && ipc[name] !== undefined ? ipc[name]
      : descriptor && descriptor[name] !== undefined ? descriptor[name] : ""
  ).trim()
}

function monitorLabel(identity, connector, descriptor, ipc) {
  var model = monitorProperty("model", descriptor, ipc)
  if (model) return model
  var description = monitorProperty("description", descriptor, ipc)
  if (description) return description
  if (connector) return connector
  if (identity.indexOf("name:") === 0) return identity.slice(5)
  if (identity.indexOf("id:") === 0) return "Monitor " + identity.slice(3)
  return "Monitor"
}

function monitorDescription(identity, connector, descriptor, ipc) {
  return monitorProperty("description", descriptor, ipc)
    || monitorLabel(identity, connector, descriptor, ipc)
}

function monitorGroupForWorkspace(monitorGroups, workspaceIdentity, present) {
  if (present !== true) return null
  var identity = String(workspaceIdentity || "")
  if (!identity) return null
  var values = monitorGroups || []
  for (var i = 0; i < values.length; ++i) {
    var group = values[i]
    if (group && group.firstWorkspaceIdentity === identity) return group
  }
  return null
}

function monitorGroupIndexForMonitor(monitorGroups, monitorIdentity) {
  var identity = String(monitorIdentity || "")
  if (!identity) return -1
  var values = monitorGroups || []
  for (var i = 0; i < values.length; ++i) {
    var group = values[i]
    if (group && String(group.identity || "") === identity) return i
  }
  return -1
}

function monitorGroupForMonitor(monitorGroups, monitorIdentity) {
  var position = monitorGroupIndexForMonitor(monitorGroups, monitorIdentity)
  if (position < 0) return null
  return (monitorGroups || [])[position]
}

function projectMonitorDrag(presentation, drag, visibleMonitorIdentity) {
  if (!presentation || !drag || !drag.workspaceIdentity
      || !drag.sourceMonitor || !drag.targetMonitor
      || drag.sourceMonitor === drag.targetMonitor)
    return presentation

  var sourceIdentity = String(drag.workspaceIdentity)
  var sourceMonitor = String(drag.sourceMonitor)
  var targetMonitor = String(drag.targetMonitor)
  var groups = presentation.groups || []
  var sourceIndex = -1
  for (var sourcePosition = 0; sourcePosition < groups.length; ++sourcePosition) {
    var sourceGroup = groups[sourcePosition]
    if (sourceGroup && sourceGroup.identity === sourceIdentity
        && String(sourceGroup.monitorIdentity || "") === sourceMonitor) {
      sourceIndex = sourcePosition
      break
    }
  }

  var monitorGroups = presentation.monitorGroups || []
  var targetVisible = false
  for (var monitorIndex = 0; monitorIndex < monitorGroups.length; ++monitorIndex) {
    if (String(monitorGroups[monitorIndex].identity || "") === targetMonitor) {
      targetVisible = true
      break
    }
  }
  if (!targetVisible) {
    targetVisible = String(visibleMonitorIdentity || "") === targetMonitor
      && groups.some(function(group) {
        return group && String(group.monitorIdentity || "") === targetMonitor
      })
  }
  if (sourceIndex < 0 && !targetVisible) return presentation

  var nextGroups = groups
  if (sourceIndex >= 0) {
    var derivedSource = Object.assign({}, groups[sourceIndex], {
      _monitorDragSource: true,
      _monitorDragOccupied: false
    })
    nextGroups = groups.slice()
    nextGroups[sourceIndex] = derivedSource
  }

  if (!targetVisible) {
    return Object.assign({}, presentation, { groups: nextGroups })
  }

  var placeholderIdentity = "workspace-monitor-placeholder:" + sourceIdentity
  var placeholder = {
    identity: placeholderIdentity,
    monitorIdentity: targetMonitor,
    label: String(drag.label || sourceIdentity),
    showFullLabel: sourceIdentity.indexOf("id:") === 0,
    activationTarget: activationTarget(sourceIdentity),
    active: false,
    items: [],
    count: Math.max(0, Number(drag.count) || 0),
    urgent: false,
    _monitorDragPlaceholder: true,
    _monitorDragOccupied: true,
    _monitorDragSortIdentity: sourceIdentity
  }

  var insertion = -1
  var lastTarget = -1
  for (var groupIndex = 0; groupIndex < nextGroups.length; ++groupIndex) {
    var group = nextGroups[groupIndex]
    if (!group || String(group.monitorIdentity || "") !== targetMonitor) continue
    lastTarget = groupIndex
    if (workspaceCompare(placeholder, group) < 0 && insertion < 0)
      insertion = groupIndex
  }
  if (insertion < 0 && lastTarget >= 0) insertion = lastTarget + 1
  if (insertion < 0) insertion = nextGroups.length
  nextGroups = nextGroups.slice()
  nextGroups.splice(insertion, 0, placeholder)

  var nextMonitorGroups = monitorGroups
  var targetSection = -1
  for (var sectionIndex = 0; sectionIndex < monitorGroups.length; ++sectionIndex) {
    if (String(monitorGroups[sectionIndex].identity || "") === targetMonitor) {
      targetSection = sectionIndex
      break
    }
  }
  if (targetSection >= 0) {
    var firstTarget = nextGroups.find(function(group) {
      return group && String(group.monitorIdentity || "") === targetMonitor
    })
    if (firstTarget) {
      var derivedSection = Object.assign({}, monitorGroups[targetSection], {
        firstWorkspaceIdentity: firstTarget.identity
      })
      nextMonitorGroups = monitorGroups.slice()
      nextMonitorGroups[targetSection] = derivedSection
    }
  }

  return Object.assign({}, presentation, {
    groups: nextGroups,
    monitorGroups: nextMonitorGroups
  })
}

function buildWorkspacePresentation(appItems, records, workspaces, context) {
  context = context || ({})
  var groups = []
  var globalLaunchers = []
  var fallbackItems = []
  var byWorkspace = Object.create(null)
  var allMonitors = context.monitorScope !== "current-monitor"
  var primaryWorkspaceIdentity = DockWindowModel.workspaceIdentity(context.activeWorkspace)
  var monitor = DockWindowModel.canonicalMonitorIdentity(context.monitor, context.monitors)
  var monitorOrder = DockModel.normalizeSetting("workspaceMonitorOrder", context.monitorOrder)
  var descriptorOwners = Object.create(null)
  var activeOwners = Object.create(null)
  var liveOwners = Object.create(null)
  var originOwners = Object.create(null)
  var monitorActiveEvidence = Object.create(null)
  var monitorWorkspaces = Object.create(null)
  var monitorMetadata = Object.create(null)
  var focusedMonitorEvidence = Object.create(null)

  function addWorkspace(identity, displayName) {
    var target = activationTarget(identity)
    if (!target) return
    var fallbackLabel = identity.replace(/^(id:|name:)/, "")
    var explicitLabel = String(displayName || "").trim()
    var label = explicitLabel || fallbackLabel
    var showFullLabel = identity.indexOf("id:") === 0
      && explicitLabel !== "" && explicitLabel !== fallbackLabel
    if (byWorkspace[identity]) {
      if (explicitLabel) {
        byWorkspace[identity].label = label
        byWorkspace[identity].showFullLabel = showFullLabel
      }
      return
    }
    var group = {
      identity: identity,
      monitorIdentity: "",
      label: label,
      showFullLabel: showFullLabel,
      activationTarget: target,
      active: false,
      items: [],
      count: 0,
      urgent: false
    }
    byWorkspace[identity] = group
    groups.push(group)
  }

  function addMonitorActiveEvidence(owner, workspace) {
    if (!owner) return
    if (!monitorActiveEvidence[owner])
      monitorActiveEvidence[owner] = { seen: false, values: Object.create(null) }
    var evidence = monitorActiveEvidence[owner]
    evidence.seen = true
    if (workspace) evidence.values[workspace] = true
  }

  function monitorOrderCompare(leftIdentity, rightIdentity) {
    if (leftIdentity === rightIdentity) return 0
    return monitorMetadataCompare(
      monitorMetadata[leftIdentity] || { identity: leftIdentity, connector: "", x: null, y: null },
      monitorMetadata[rightIdentity] || { identity: rightIdentity, connector: "", x: null, y: null },
      monitorOrder)
  }

  var monitors = context.monitors || []
  for (var m = 0; m < monitors.length; ++m) {
    var monitorDescriptor = monitors[m]
    if (!monitorDescriptor) continue
    var monitorIpc = monitorDescriptor.lastIpcObject || monitorDescriptor
    var owner = DockWindowModel.canonicalMonitorIdentity(monitorDescriptor, context.monitors)
    if (!owner) continue
    var connector = String(
      monitorIpc.name !== undefined ? monitorIpc.name : monitorDescriptor.name || ""
    ).trim()
    var activeDescriptor = DockWindowModel.monitorActiveWorkspace(monitorDescriptor)
    var activeWorkspace = DockWindowModel.workspaceIdentity(activeDescriptor)
    addMonitorActiveEvidence(owner, activeWorkspace)
    if (activeWorkspace) addOwnerEvidence(activeOwners, activeWorkspace, owner, false)
    if (allMonitors) addWorkspace(activeWorkspace,
      activeDescriptor ? activeDescriptor.name : "")
    var focused = DockWindowModel.monitorFocused(monitorDescriptor)
    if (focused) focusedMonitorEvidence[owner] = true
    monitorMetadata[owner] = {
      identity: owner,
      connector: connector,
      label: monitorLabel(owner, connector, monitorDescriptor, monitorIpc),
      description: monitorDescription(owner, connector, monitorDescriptor, monitorIpc),
      x: finiteCoordinate(monitorIpc.x, monitorDescriptor.x),
      y: finiteCoordinate(monitorIpc.y, monitorDescriptor.y)
    }
  }

  var monitorOwnerKeys = Object.keys(monitorActiveEvidence)
  for (var mo = 0; mo < monitorOwnerKeys.length; ++mo) {
    var monitorOwner = monitorOwnerKeys[mo]
    var activeValues = Object.keys(monitorActiveEvidence[monitorOwner].values)
    monitorWorkspaces[monitorOwner] = activeValues.length === 1 ? activeValues[0] : ""
  }

  workspaces = workspaces || []
  for (var w = 0; w < workspaces.length; ++w) {
    var workspaceDescriptor = workspaces[w]
    if (!workspaceDescriptor) continue
    var workspaceIpc = workspaceDescriptor.lastIpcObject || workspaceDescriptor
    // Late client replies can recreate deleted workspaces as empty placeholders.
    // Live records below still keep real windows reachable during initialization.
    // Numbered placeholders alias the real workspace with that number, so drop them.
    if (workspaceDescriptor.id === -1 && workspaceDescriptor.lastIpcObject
        && Object.keys(workspaceIpc).length === 0
        && (!workspaceDescriptor.monitor
          || /^[1-9][0-9]*$/.test(String(workspaceDescriptor.name || "")))) continue
    var rawOwner = workspaceIpc.monitorID !== undefined ? workspaceIpc.monitorID
      : workspaceIpc.monitor !== undefined ? workspaceIpc.monitor : workspaceDescriptor.monitor
    var descriptorOwner = DockWindowModel.canonicalMonitorIdentity(rawOwner, context.monitors)
    var identity = DockWindowModel.workspaceIdentity(workspaceDescriptor)
    if (!activationTarget(identity)) continue
    addOwnerEvidence(descriptorOwners, identity, descriptorOwner, !descriptorOwner)
    if (allMonitors || descriptorOwner && descriptorOwner === monitor)
      addWorkspace(identity, workspaceDescriptor.name !== undefined
        ? workspaceDescriptor.name : workspaceIpc.name)
  }

  addWorkspace(primaryWorkspaceIdentity)

  // Resolve record locations without mutating the caller's snapshots. A live
  // workspace descriptor, even an unresolved one, outranks a minimized origin.
  records = (records || []).map(function(record) {
    var descriptorEvidence = resolvedOwner(descriptorOwners[record.workspace])
    var owner = record.minimized && descriptorEvidence.seen
      ? descriptorEvidence.owner
      : DockWindowModel.canonicalMonitorIdentity(record.monitor, context.monitors)
    var workspace = record.sticky && !record.minimized
      ? (allMonitors ? monitorWorkspaces[owner] || ""
        : owner && owner === monitor ? primaryWorkspaceIdentity : record.workspace)
      : record.minimized && record.originValid === false ? "" : record.workspace
    var resolved = Object.assign({}, record, {
      monitor: owner,
      monitorKnown: !!owner,
      workspace: workspace,
      workspaceKnown: workspace !== "",
      sticky: record.sticky === true && !record.minimized
    })
    if (activationTarget(workspace)) {
      if (record.minimized) addOwnerEvidence(originOwners, workspace, owner, !owner)
      else addOwnerEvidence(liveOwners, workspace, owner, !owner)
      if (allMonitors || owner && owner === monitor) addWorkspace(workspace)
    }
    return resolved
  })

  function ownerForWorkspace(identity) {
    var evidence = resolvedOwner(descriptorOwners[identity])
    if (evidence.seen) return evidence.owner
    evidence = resolvedOwner(activeOwners[identity])
    if (evidence.seen) return evidence.owner
    evidence = resolvedOwner(liveOwners[identity])
    if (evidence.seen) return evidence.owner
    evidence = resolvedOwner(originOwners[identity])
    return evidence.seen ? evidence.owner : ""
  }

  for (var g = 0; g < groups.length; ++g)
    groups[g].monitorIdentity = ownerForWorkspace(groups[g].identity)

  if (!allMonitors) {
    groups = groups.filter(function(group) {
      return group.identity === primaryWorkspaceIdentity
        || group.monitorIdentity && group.monitorIdentity === monitor
    })
  }

  groups.sort(function(left, right) {
    if (!allMonitors) return workspaceCompare(left, right)
    if (left.monitorIdentity === right.monitorIdentity)
      return workspaceCompare(left, right)
    if (!left.monitorIdentity) return 1
    if (!right.monitorIdentity) return -1
    return monitorOrderCompare(left.monitorIdentity, right.monitorIdentity)
  })

  var visibleByWorkspace = Object.create(null)
  for (var vg = 0; vg < groups.length; ++vg) {
    var visibleGroup = groups[vg]
    visibleByWorkspace[visibleGroup.identity] = visibleGroup
    if (!allMonitors) {
      visibleGroup.active = visibleGroup.identity === primaryWorkspaceIdentity
      continue
    }
    var ownerActive = visibleGroup.monitorIdentity
      ? monitorWorkspaces[visibleGroup.monitorIdentity] || "" : ""
    visibleGroup.active = ownerActive
      ? ownerActive === visibleGroup.identity
      : visibleGroup.identity === primaryWorkspaceIdentity
  }

  var pinnedIds = (appItems || []).filter(function(item) { return item.pinned })
    .map(function(item) { return DockModel.normalizedId(item.desktopId) })
  var orderedItems = (appItems || []).slice().sort(function(a, b) {
    var aPin = pinnedIds.indexOf(DockModel.normalizedId(a.desktopId))
    var bPin = pinnedIds.indexOf(DockModel.normalizedId(b.desktopId))
    return (aPin < 0 ? pinnedIds.length : aPin)
      - (bPin < 0 ? pinnedIds.length : bPin)
  })
  for (var i = 0; i < orderedItems.length; ++i) {
    var item = orderedItems[i]
    var partitions = Object.create(null)
    if (item.pinned && item.toplevels.length === 0)
      partitions.global = []
    for (var t = 0; t < item.toplevels.length; ++t) {
      var toplevel = item.toplevels[t]
      var record = records.find(function(value) { return value.toplevel === toplevel })
      if (!allMonitors && record && record.monitorKnown && record.monitor !== monitor) continue
      var key = record && record.workspaceKnown && (allMonitors || record.monitorKnown)
        && visibleByWorkspace[record.workspace] ? record.workspace : "other"
      if (!partitions[key]) partitions[key] = []
      partitions[key].push(toplevel)
    }
    for (var key in partitions) {
      var members = partitions[key]
      var presentationIdentity = key + "/" + item.desktopId
      if (context.groupWindows === false && members.length) {
        var firstRecord = records.find(function(value) { return value.toplevel === members[0] })
        // Object identity remains available to preview lookup while a handle is pending.
        presentationIdentity += "/" + (firstRecord && firstRecord.address || "pending")
      }
      var scoped = Object.assign({}, item, {
        pinned: pinnedIds.indexOf(DockModel.normalizedId(item.desktopId)) >= 0,
        toplevels: members,
        presentationId: presentationIdentity,
        identityToplevel: context.groupWindows === false ? members[0] : null,
        localUrgent: false,
        sticky: false,
        urgentAddresses: []
      })
      for (var memberIndex = 0; memberIndex < members.length; ++memberIndex) {
        var member = records.find(function(value) {
          return value.toplevel === members[memberIndex]
        })
        if (!member) continue
        scoped.sticky = scoped.sticky || member.sticky === true
        if (member.urgent === true) {
          scoped.localUrgent = true
          scoped.urgentAddresses.push(member.address || "pending:" + memberIndex)
        }
      }
      if (key === "global") globalLaunchers.push(scoped)
      else if (key === "other") fallbackItems.push(scoped)
      else {
        visibleByWorkspace[key].items.push(scoped)
        visibleByWorkspace[key].count += members.length
        visibleByWorkspace[key].urgent = visibleByWorkspace[key].urgent || scoped.localUrgent
      }
    }
  }

  var monitorGroups = []
  if (allMonitors) {
    var sectionOwners = []
    for (var sectionIndex = 0; sectionIndex < groups.length; ++sectionIndex) {
      var sectionOwner = groups[sectionIndex].monitorIdentity
      if (sectionOwner && sectionOwners.indexOf(sectionOwner) < 0)
        sectionOwners.push(sectionOwner)
    }
    sectionOwners.sort(monitorOrderCompare)

    var focusedOwners = Object.keys(focusedMonitorEvidence)
    var focusedOwner = focusedOwners.length === 1 ? focusedOwners[0] : ""
    if (!focusedOwner && focusedOwners.length === 0) {
      var primaryGroup = visibleByWorkspace[primaryWorkspaceIdentity]
      focusedOwner = primaryGroup ? primaryGroup.monitorIdentity : ""
    }

    for (var section = 0; section < sectionOwners.length; ++section) {
      var sectionIdentity = sectionOwners[section]
      var metadata = monitorMetadata[sectionIdentity] || ({
        identity: sectionIdentity,
        connector: sectionIdentity.indexOf("name:") === 0 ? sectionIdentity.slice(5) : "",
        label: monitorLabel(sectionIdentity, "", null, null),
        description: monitorDescription(sectionIdentity, "", null, null)
      })
      var firstWorkspaceIdentity = ""
      for (var firstIndex = 0; firstIndex < groups.length; ++firstIndex) {
        if (groups[firstIndex].monitorIdentity === sectionIdentity) {
          firstWorkspaceIdentity = groups[firstIndex].identity
          break
        }
      }
      monitorGroups.push({
        identity: sectionIdentity,
        connector: metadata.connector,
        label: metadata.label,
        description: metadata.description,
        focused: focusedOwner === sectionIdentity,
        activeWorkspace: monitorWorkspaces[sectionIdentity] || "",
        firstWorkspaceIdentity: firstWorkspaceIdentity
      })
    }

    var firstUnknown = ""
    for (var unknownIndex = 0; unknownIndex < groups.length; ++unknownIndex) {
      if (!groups[unknownIndex].monitorIdentity) {
        firstUnknown = groups[unknownIndex].identity
        break
      }
    }
    if (firstUnknown) {
      monitorGroups.push({
        identity: "",
        connector: "",
        label: "Unknown monitor",
        description: "Unknown monitor",
        focused: false,
        activeWorkspace: "",
        firstWorkspaceIdentity: firstUnknown
      })
    }
  }

  // Badge/preview traversal remains globally primary-first, independent of the
  // per-monitor visual ordering and the number of cards with active styling.
  var badgeGroups = groups.slice().sort(workspaceCompare)
  var renderedItems = []
  var primaryGroupIndex = -1
  for (var badgeIndex = 0; badgeIndex < badgeGroups.length; ++badgeIndex) {
    if (badgeGroups[badgeIndex].identity === primaryWorkspaceIdentity) {
      primaryGroupIndex = badgeIndex
      break
    }
  }
  if (primaryGroupIndex >= 0)
    renderedItems = renderedItems.concat(badgeGroups[primaryGroupIndex].items)
  for (var remainingIndex = 0; remainingIndex < badgeGroups.length; ++remainingIndex) {
    if (remainingIndex === primaryGroupIndex) continue
    renderedItems = renderedItems.concat(badgeGroups[remainingIndex].items)
  }

  return {
    primaryWorkspaceIdentity: primaryWorkspaceIdentity,
    monitorGroups: monitorGroups,
    globalLaunchers: globalLaunchers,
    fallbackItems: fallbackItems,
    groups: groups,
    renderedItems: renderedItems.concat(globalLaunchers, fallbackItems)
  }
}

function scopedItemsEqual(a, b) {
  if (!DockModel.visibleItemsEqual(a, b)) return false
  for (var i = 0; i < a.length; ++i) {
    if (a[i].localUrgent !== b[i].localUrgent || a[i].sticky !== b[i].sticky
        || JSON.stringify(a[i].urgentAddresses) !== JSON.stringify(b[i].urgentAddresses))
      return false
  }
  return true
}

function monitorGroupsEqual(a, b) {
  var leftGroups = a || []
  var rightGroups = b || []
  if (leftGroups.length !== rightGroups.length) return false
  for (var i = 0; i < leftGroups.length; ++i) {
    var left = leftGroups[i]
    var right = rightGroups[i]
    if (left.identity !== right.identity || left.connector !== right.connector
        || left.label !== right.label || left.description !== right.description
        || left.focused !== right.focused
        || left.activeWorkspace !== right.activeWorkspace
        || left.firstWorkspaceIdentity !== right.firstWorkspaceIdentity)
      return false
  }
  return true
}

function presentationsEqual(a, b) {
  if (String(a.primaryWorkspaceIdentity || "") !== String(b.primaryWorkspaceIdentity || "")
      || !monitorGroupsEqual(a.monitorGroups, b.monitorGroups)
      || !scopedItemsEqual(a.globalLaunchers, b.globalLaunchers)
      || !scopedItemsEqual(a.fallbackItems, b.fallbackItems)
      || a.groups.length !== b.groups.length) return false
  for (var i = 0; i < a.groups.length; ++i) {
    var left = a.groups[i]
    var right = b.groups[i]
    if (left.identity !== right.identity
        || String(left.monitorIdentity || "") !== String(right.monitorIdentity || "")
        || left.label !== right.label
        || left.showFullLabel !== right.showFullLabel || left.active !== right.active
        || left.count !== right.count || left.urgent !== right.urgent
        || !scopedItemsEqual(left.items, right.items))
      return false
  }
  return true
}
