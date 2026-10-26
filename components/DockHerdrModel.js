// Pure Herdr↔window association from process identity only.
// No title, focus, or row-index heuristics.
//
// Each client resolves to its closest ancestor identity that matches a
// compositor window. If that nearest identity is shared by multiple windows,
// the client stays unmatched (no farther fallback). Independently proven
// clients aggregate; conflicting servers for one window leave it unmatched.

.pragma library

function identityKey(pid, startTime) {
  if (typeof pid !== "number" || typeof startTime !== "number") return ""
  if (!isFinite(pid) || !isFinite(startTime)) return ""
  if (pid <= 0) return ""
  return String(pid) + ":" + String(startTime)
}

function clientChain(client) {
  var chain = []
  if (!client || typeof client !== "object") return chain
  if (identityKey(client.pid, client.startTime))
    chain.push({ pid: client.pid, startTime: client.startTime, depth: 0 })
  var ancestors = client.ancestors
  if (!ancestors || typeof ancestors.length !== "number") return chain
  for (var i = 0; i < ancestors.length; i++) {
    var ancestor = ancestors[i]
    if (!ancestor || typeof ancestor !== "object") continue
    if (!identityKey(ancestor.pid, ancestor.startTime)) continue
    chain.push({
      pid: ancestor.pid,
      startTime: ancestor.startTime,
      depth: chain.length
    })
  }
  return chain
}

function associateWindows(servers, windows) {
  var byWindowKey = ({})
  var unmatched = []
  var serverList = Array.isArray(servers) ? servers : []
  var windowList = Array.isArray(windows) ? windows : []

  var windowsByIdentity = ({})
  for (var w = 0; w < windowList.length; w++) {
    var win = windowList[w]
    if (!win || typeof win !== "object") continue
    var windowKey = typeof win.key === "string" ? win.key : ""
    if (!windowKey) continue
    var wKey = identityKey(win.pid, win.startTime)
    if (!wKey) continue
    if (!windowsByIdentity[wKey]) windowsByIdentity[wKey] = []
    windowsByIdentity[wKey].push(windowKey)
  }

  // Per client: closest matching identity only; aggregate proven window→server.
  var proven = []
  for (var s = 0; s < serverList.length; s++) {
    var server = serverList[s]
    if (!server || typeof server !== "object") continue
    var serverId = typeof server.id === "string" ? server.id : ""
    if (!serverId) continue
    var clients = Array.isArray(server.clients) ? server.clients : []
    if (clients.length === 0) {
      unmatched.push(serverId)
      continue
    }
    for (var c = 0; c < clients.length; c++) {
      var chain = clientChain(clients[c])
      var matchedIdentity = ""
      for (var a = 0; a < chain.length; a++) {
        var nodeKey = identityKey(chain[a].pid, chain[a].startTime)
        if (!nodeKey || !windowsByIdentity[nodeKey]) continue
        matchedIdentity = nodeKey
        break
      }
      if (!matchedIdentity) continue
      var matches = windowsByIdentity[matchedIdentity]
      // Shared nearest identity → unmatched client; do not fall back farther.
      if (!matches || matches.length !== 1) continue
      proven.push({ windowKey: matches[0], serverId: serverId })
    }
  }

  var claimsByWindow = ({})
  for (var p = 0; p < proven.length; p++) {
    var claim = proven[p]
    var existing = claimsByWindow[claim.windowKey]
    if (!existing) {
      claimsByWindow[claim.windowKey] = {
        serverId: claim.serverId,
        ambiguous: false
      }
      continue
    }
    if (existing.serverId !== claim.serverId)
      existing.ambiguous = true
  }

  var matchedServers = ({})
  for (var windowKey in claimsByWindow) {
    if (!Object.prototype.hasOwnProperty.call(claimsByWindow, windowKey)) continue
    var choice = claimsByWindow[windowKey]
    if (choice.ambiguous) continue
    byWindowKey[windowKey] = choice.serverId
    matchedServers[choice.serverId] = true
  }

  for (var si = 0; si < serverList.length; si++) {
    var row = serverList[si]
    if (!row || typeof row !== "object") continue
    var id = typeof row.id === "string" ? row.id : ""
    if (!id) continue
    if (matchedServers[id]) continue
    if (unmatched.indexOf(id) >= 0) continue
    unmatched.push(id)
  }

  return { byWindowKey: byWindowKey, unmatchedServerIds: unmatched }
}

function normalizeWindowProcessPids(pids) {
  if (!Array.isArray(pids)) return []
  var out = []
  var seen = Object.create(null)
  for (var i = 0; i < pids.length; i++) {
    var pid = pids[i]
    if (typeof pid !== "number" || !isFinite(pid) || Math.floor(pid) !== pid || pid <= 0)
      continue
    var key = String(pid)
    if (seen[key]) continue
    seen[key] = true
    out.push(pid)
    if (out.length >= 256) break
  }
  return out
}

function windowProcessFingerprint(targets) {
  var rows = Array.isArray(targets) ? targets.slice() : []
  rows.sort(function(a, b) {
    var ak = a && typeof a.key === "string" ? a.key : ""
    var bk = b && typeof b.key === "string" ? b.key : ""
    if (ak < bk) return -1
    if (ak > bk) return 1
    return 0
  })
  var parts = []
  for (var i = 0; i < rows.length; i++) {
    var row = rows[i]
    if (!row || typeof row !== "object") continue
    var key = typeof row.key === "string" ? row.key : ""
    var pid = row.pid
    if (!key) continue
    if (typeof pid !== "number" || !isFinite(pid) || Math.floor(pid) !== pid || pid <= 0)
      continue
    parts.push(key + ":" + String(pid))
  }
  return parts.join("|")
}

function buildAssociationWindows(targets, identities) {
  var byPid = Object.create(null)
  var idList = Array.isArray(identities) ? identities : []
  for (var i = 0; i < idList.length; i++) {
    var id = idList[i]
    if (!id || typeof id !== "object") continue
    if (typeof id.pid !== "number" || typeof id.startTime !== "number") continue
    if (!isFinite(id.pid) || !isFinite(id.startTime)) continue
    if (Math.floor(id.pid) !== id.pid || id.pid <= 0) continue
    if (Math.floor(id.startTime) !== id.startTime || id.startTime < 0) continue
    byPid[String(id.pid)] = id.startTime
  }
  var windows = []
  var targetList = Array.isArray(targets) ? targets : []
  for (var t = 0; t < targetList.length; t++) {
    var target = targetList[t]
    if (!target || typeof target !== "object") continue
    var key = typeof target.key === "string" ? target.key : ""
    var pid = target.pid
    if (!key) continue
    if (typeof pid !== "number" || !isFinite(pid) || Math.floor(pid) !== pid || pid <= 0)
      continue
    if (!Object.prototype.hasOwnProperty.call(byPid, String(pid))) continue
    windows.push({ key: key, pid: pid, startTime: byPid[String(pid)] })
  }
  return windows
}

function resolveAssociations(request, snapshot) {
  if (!request || typeof request !== "object") return null
  if (!snapshot || typeof snapshot !== "object") return null
  if (typeof request.revision !== "number" || !isFinite(request.revision)) return null
  if (typeof request.epoch !== "string") return null
  if (typeof snapshot.providerEpoch !== "string") return null
  if (snapshot.providerEpoch !== request.epoch) return null
  var windowProcesses = snapshot.windowProcesses
  if (!windowProcesses || typeof windowProcesses !== "object") return null
  if (windowProcesses.revision !== request.revision) return null
  var windows = buildAssociationWindows(request.targets, windowProcesses.identities)
  return associateWindows(snapshot.servers, windows)
}

// Focus action deadlines are per request. Returning -1 means no pending request;
// malformed timestamps fail closed as immediately due instead of lingering.
function nextFocusDeadlineDelay(pending, now, deadlineMs) {
  var source = pending && typeof pending === "object" ? pending : ({})
  var ids = Object.keys(source)
  if (!ids.length) return -1
  var current = Number(now)
  var timeout = Number(deadlineMs)
  if (!isFinite(current) || !isFinite(timeout) || timeout <= 0) return 0
  var earliest = Infinity
  for (var i = 0; i < ids.length; i++) {
    var entry = source[ids[i]]
    var started = entry && Number(entry.startedAt)
    if (!isFinite(started) || started < 0) return 0
    earliest = Math.min(earliest, started + timeout)
  }
  return Math.max(0, Math.ceil(earliest - current))
}

function expiredFocusRequestIds(pending, now, deadlineMs) {
  var source = pending && typeof pending === "object" ? pending : ({})
  var current = Number(now)
  var timeout = Number(deadlineMs)
  if (!isFinite(current) || !isFinite(timeout) || timeout <= 0)
    return Object.keys(source)
  return Object.keys(source).filter(function(id) {
    var entry = source[id]
    var started = entry && Number(entry.startedAt)
    if (!isFinite(started) || started < 0) return true
    return current - started >= timeout
  })
}

// Compact appearance: shared status normalization, unique-ID counts, color roles.
// Display order for nonzero status counters and agent lists:
// blocked → working → done → idle → unknown.
var STATUS_ORDER = ["blocked", "working", "done", "idle", "unknown"]
var AGENT_STATUS_SORT = STATUS_ORDER

function normalizeStatus(value) {
  if (typeof value !== "string") return "unknown"
  var status = value.replace(/^\s+|\s+$/g, "").toLowerCase()
  if (status === "working" || status === "idle" || status === "done"
      || status === "blocked" || status === "unknown")
    return status
  return "unknown"
}

function emptyStatusCounts() {
  return {
    working: 0,
    idle: 0,
    done: 0,
    blocked: 0,
    unknown: 0,
    agents: 0
  }
}

// Count unique live agent IDs. Duplicate IDs contribute once (first wins).
function countAgentStatuses(agents) {
  var counts = emptyStatusCounts()
  var seen = Object.create(null)
  var list = Array.isArray(agents) ? agents : []
  for (var i = 0; i < list.length; i++) {
    var agent = list[i]
    if (!agent || typeof agent !== "object") continue
    var id = typeof agent.id === "string" ? agent.id : String(agent.id || "")
    if (!id || seen[id]) continue
    seen[id] = true
    var status = normalizeStatus(agent.status)
    counts[status] += 1
    counts.agents += 1
  }
  return counts
}

function statusCounters(counts) {
  var source = counts && typeof counts === "object" ? counts : emptyStatusCounts()
  var out = []
  for (var i = 0; i < STATUS_ORDER.length; i++) {
    var status = STATUS_ORDER[i]
    var count = Number(source[status] || 0)
    if (!isFinite(count) || count <= 0) continue
    out.push({ status: status, count: count })
  }
  return out
}

// One status→paint role map. QML resolves roles to Omarchy Color tokens:
// accent (working), idle (brighter than muted for counter contrast), done/blocked
// via flatColor theme fallbacks, hollow/muted outline (unknown). "done" is Herdr
// state, not proven success.
function statusColorRole(status) {
  switch (normalizeStatus(status)) {
  case "working":
    return "accent"
  case "idle":
    return "idle"
  case "done":
    return "done"
  case "blocked":
    return "blocked"
  default:
    return "hollow"
  }
}

function statusLabel(status) {
  switch (normalizeStatus(status)) {
  case "working":
    return "Working"
  case "idle":
    return "Idle"
  case "done":
    return "Done"
  case "blocked":
    return "Blocked"
  default:
    return "Unknown"
  }
}

// Server metadata is already bounded/sanitized by the provider. Presentation
// deliberately derives focus support only from the per-server capability.
function cleanDisplayText(value) {
  if (typeof value !== "string") return ""
  return value.replace(/^\s+|\s+$/g, "")
}

function serverTransport(server) {
  if (!server || typeof server !== "object") return ""
  var value = String(server.transport || "")
  return value === "remote" || value === "local" ? value : ""
}

function serverVersionParts(server) {
  if (!server || typeof server !== "object" || typeof server.version !== "string")
    return null
  var value = cleanDisplayText(server.version)
  var match = /^v?([0-9]+)\.([0-9]+)\.([0-9]+)(?:-([0-9A-Za-z.-]+))?(?:\+[0-9A-Za-z.-]+)?$/.exec(value)
  if (!match) return null
  var major = Number(match[1])
  var minor = Number(match[2])
  var patch = Number(match[3])
  if (!isFinite(major) || !isFinite(minor) || !isFinite(patch))
    return null
  return { major: major, minor: minor, patch: patch, prerelease: match[4] || "" }
}

function serverNeedsFocusUpgrade(server) {
  if (!server || typeof server !== "object" || server.connected !== true)
    return false
  var version = serverVersionParts(server)
  if (!version) return false
  var current = [version.major, version.minor, version.patch]
  var minimum = [0, 9, 1]
  for (var i = 0; i < minimum.length; ++i) {
    if (current[i] < minimum[i]) return true
    if (current[i] > minimum[i]) return false
  }
  return version.prerelease !== ""
}

function serverFocusUpgradeMessage(server) {
  return serverNeedsFocusUpgrade(server)
    ? "Update Herdr to 0.9.1+ to jump to agents" : ""
}

function serverFocusAgentSupported(server) {
  return !!(server && typeof server === "object"
    && server.capabilities && typeof server.capabilities === "object"
    && server.capabilities.focusAgent === true
    && !serverNeedsFocusUpgrade(server))
}

function serverDisplayLabel(server) {
  var source = server && typeof server === "object" ? server : ({})
  if (serverTransport(source) !== "remote") {
    // Preserve the legacy local fallback byte-for-byte.
    if (typeof source.label === "string" && source.label) return source.label
    if (typeof source.session === "string" && source.session) return source.session
    return "Herdr"
  }
  var hostLabel = cleanDisplayText(source.label) || cleanDisplayText(source.host)
    || "Remote Herdr"
  var session = cleanDisplayText(source.session)
  if (!session || session === "default") return hostLabel
  return hostLabel + " · " + session
}

function displayAgentKind(kind) {
  if (typeof kind !== "string") return ""
  var raw = kind.replace(/^\s+|\s+$/g, "")
  if (!raw) return ""
  var lower = raw.toLowerCase()
  if (lower === "codex") return "Codex"
  if (lower === "claude") return "Claude"
  if (lower === "cursor") return "Cursor"
  if (lower === "opencode") return "OpenCode"
  return raw.charAt(0).toUpperCase() + raw.slice(1)
}

// Primary agent line: Herdr pane/panel title, then name / label / tab title.
function displayAgentTitle(agent) {
  if (!agent || typeof agent !== "object") return "Coding agent"
  var candidates = [agent.title, agent.name, agent.label, agent.tabTitle]
  for (var i = 0; i < candidates.length; i++) {
    if (typeof candidates[i] !== "string") continue
    var text = candidates[i].replace(/^\s+|\s+$/g, "")
    if (text) return text
  }
  return "Coding agent"
}

// Secondary line: "workspace - Kind" with missing parts omitted cleanly.
function displayAgentSecondary(agent) {
  if (!agent || typeof agent !== "object") return ""
  var workspace = typeof agent.workspaceLabel === "string"
    ? agent.workspaceLabel.replace(/^\s+|\s+$/g, "") : ""
  var kind = displayAgentKind(agent.agent || agent.agentKind || "")
  if (workspace && kind) return workspace + " - " + kind
  if (workspace) return workspace
  if (kind) return kind
  return ""
}

// Dock preview secondary line: "tab · Kind" with missing parts omitted.
function displayAgentTabSecondary(agent) {
  if (!agent || typeof agent !== "object") return ""
  var tab = typeof agent.tabTitle === "string"
    ? agent.tabTitle.replace(/^\s+|\s+$/g, "") : ""
  var kind = displayAgentKind(agent.agent || agent.agentKind || "")
  if (tab && kind) return tab + " · " + kind
  if (tab) return tab
  if (kind) return kind
  return ""
}

// Display sort: blocked → working → done → idle → unknown (stable within rank).
function agentStatusSortRank(status) {
  var normalized = normalizeStatus(status)
  for (var i = 0; i < AGENT_STATUS_SORT.length; i++) {
    if (AGENT_STATUS_SORT[i] === normalized) return i
  }
  return AGENT_STATUS_SORT.length
}

function compareAgentsForDisplay(a, b) {
  var rankA = agentStatusSortRank(a && a.status)
  var rankB = agentStatusSortRank(b && b.status)
  if (rankA !== rankB) return rankA - rankB
  return 0
}

function sortAgentsForDisplay(agents) {
  var list = Array.isArray(agents) ? agents.slice() : []
  list.sort(compareAgentsForDisplay)
  return list
}

function acknowledgedAgentDone(acknowledgedDone, agent) {
  if (!acknowledgedDone || !agent) return false
  var id = typeof agent.indicatorKey === "string" && agent.indicatorKey
    ? agent.indicatorKey
    : typeof agent.id === "string" ? agent.id : String(agent.id || "")
  if (!id) return false
  if (Array.isArray(acknowledgedDone)) return acknowledgedDone.indexOf(id) >= 0
  if (typeof acknowledgedDone.has === "function") return acknowledgedDone.has(id)
  return acknowledgedDone[id] === true
}

// One window's dock-facing summary. Counters and rows preserve raw status;
// acknowledgment suppresses only the done indicator.
function windowAgentSummary(agents, acknowledgedDone) {
  var ordered = sortAgentsForDisplay(agents)
  var seen = Object.create(null)
  var rows = []
  for (var i = 0; i < ordered.length; i++) {
    var agent = ordered[i]
    if (!agent || typeof agent !== "object") continue
    var id = typeof agent.id === "string" ? agent.id : String(agent.id || "")
    var identity = String(agent.serverId || "") + "\0" + id
    if (!id || seen[identity]) continue
    seen[identity] = true
    rows.push(Object.assign({}, agent, {
      title: displayAgentTitle(agent),
      focusAgentSupported: agent.focusAgentSupported === true
    }))
  }
  var counters = statusCounters(countAgentStatuses(rows))
  var indicatorStatus = ""
  if (rows.some(function(agent) { return normalizeStatus(agent.status) === "blocked" }))
    indicatorStatus = "blocked"
  else if (rows.some(function(agent) { return normalizeStatus(agent.status) === "working" }))
    indicatorStatus = "working"
  else if (rows.some(function(agent) {
    return normalizeStatus(agent.status) === "done"
      && !acknowledgedAgentDone(acknowledgedDone, agent)
  })) indicatorStatus = "done"
  return {
    count: rows.length,
    indicatorStatus: indicatorStatus,
    counters: counters,
    rows: rows
  }
}

// Stable workspace → tab buckets from a status-sorted agent list.
// Missing ids fall back to label:… or "unknown"; labels fall back to Workspace/Tab.
function herdrGroupId(rawId, rawLabel, fallback) {
  if (typeof rawId === "string") {
    var id = rawId.replace(/^\s+|\s+$/g, "")
    if (id) return id
  }
  if (typeof rawLabel === "string") {
    var label = rawLabel.replace(/^\s+|\s+$/g, "")
    if (label) return "label:" + label
  }
  return fallback
}

function herdrGroupLabel(rawLabel, fallback) {
  if (typeof rawLabel === "string") {
    var label = rawLabel.replace(/^\s+|\s+$/g, "")
    if (label) return label
  }
  return fallback
}

function groupAgentsForTree(agents) {
  var ordered = sortAgentsForDisplay(agents)
  var workspaces = []
  var wsIndex = Object.create(null)
  var tabIndex = Object.create(null)
  var seenAgents = Object.create(null)
  for (var i = 0; i < ordered.length; i++) {
    var agent = ordered[i]
    if (!agent || typeof agent !== "object") continue
    var agentId = typeof agent.id === "string" ? agent.id : String(agent.id || "")
    if (!agentId || seenAgents[agentId]) continue
    seenAgents[agentId] = true
    var workspaceId = herdrGroupId(agent.workspaceId, agent.workspaceLabel, "unknown")
    var tabId = herdrGroupId(agent.tabId, agent.tabTitle, "unknown")
    var ws = wsIndex[workspaceId]
    if (!ws) {
      ws = {
        id: workspaceId,
        label: herdrGroupLabel(agent.workspaceLabel, "Workspace"),
        tabs: []
      }
      wsIndex[workspaceId] = ws
      workspaces.push(ws)
    }
    var tabKey = workspaceId + "\0" + tabId
    var tab = tabIndex[tabKey]
    if (!tab) {
      tab = {
        id: tabId,
        title: herdrGroupLabel(agent.tabTitle, ""),
        agents: []
      }
      tabIndex[tabKey] = tab
      ws.tabs.push(tab)
    } else if (!tab.title) {
      tab.title = herdrGroupLabel(agent.tabTitle, "")
    }
    tab.agents.push(agent)
  }
  return workspaces
}

function herdrFoldKeyForWindow(windowKey) {
  if (typeof windowKey !== "string" || !windowKey) return ""
  return "herdr:" + windowKey
}
