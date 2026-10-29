// Pure multi-source snapshot merge behind one DockHerdrService-shaped view.
//
// Herdr, T3 and Claude Desktop providers each produce their own epoch and revision. This
// module merges enabled, ready sources after that point so the bridge, the
// actions, the dock, the preview, the menu and the sidebar keep consuming
// one service. Top-level inventory copy (liveCounts, completeness,
// sourceErrorCode) always comes from the primary source (Herdr when present)
// so a truncated or erroring T3 list can never rewrite Herdr-only strings;
// per-source values travel stamped on each server row.

.pragma library

function compositeEpoch(sources) {
  var parts = []
  for (var i = 0; i < (sources || []).length; i++) {
    var source = sources[i]
    if (!source || source.enabled !== true) continue
    if (!source.running) continue
    var epoch = typeof source.epoch === "string" ? source.epoch : ""
    if (!epoch) continue
    parts.push(String(source.id) + "=" + epoch)
  }
  return parts.join("|")
}

function sourceIdForServerId(serverId) {
  var id = String(serverId || "")
  if (id.indexOf("t3:") === 0) return "t3"
  if (id.indexOf("claude:") === 0) return "claude"
  return "herdr"
}

function mergedWindowProcesses(entries) {
  var revision = null
  var identities = []
  var seen = Object.create(null)
  for (var i = 0; i < (entries || []).length; i++) {
    var snapshot = entries[i] && entries[i].snapshot
    var windowProcesses = snapshot && snapshot.windowProcesses
    var entryRevision = windowProcesses && windowProcesses.revision
    if (typeof entryRevision !== "number" || !isFinite(entryRevision)
        || Math.floor(entryRevision) !== entryRevision) return { revision: -1, identities: [] }
    if (revision === null) revision = entryRevision
    else if (revision !== entryRevision) return { revision: -1, identities: [] }
    var rows = windowProcesses.identities
    if (!Array.isArray(rows)) continue
    for (var j = 0; j < rows.length; j++) {
      var row = rows[j]
      if (!row || typeof row !== "object") continue
      var pid = row.pid
      if (typeof pid !== "number" || !isFinite(pid)
          || Math.floor(pid) !== pid || pid <= 0) continue
      var key = String(pid)
      if (seen[key]) continue
      seen[key] = true
      identities.push({ pid: pid, startTime: row.startTime })
    }
  }
  if (revision === null) return { revision: -1, identities: [] }
  return { revision: revision, identities: identities }
}

function mergeStatus(statuses) {
  var list = statuses || []
  if (list.indexOf("ready") >= 0) return "ready"
  if (list.indexOf("loading") >= 0) return "loading"
  if (list.indexOf("unavailable") >= 0) return "unavailable"
  return "error"
}

function stampedServers(entry) {
  var snapshot = entry.snapshot || {}
  var rows = Array.isArray(snapshot.servers) ? snapshot.servers : []
  var output = []
  for (var i = 0; i < rows.length; i++) {
    var server = rows[i]
    if (!server || typeof server !== "object") continue
    var stamped = Object.assign({}, server, {
      source: server.source || entry.id,
      providerEpoch: typeof snapshot.providerEpoch === "string"
        ? snapshot.providerEpoch : "",
      sourceCompleteness: snapshot.completeness || null,
      sourceLiveCountsKnown: snapshot.liveCounts !== null
        && snapshot.liveCounts !== undefined
    })
    output.push(stamped)
  }
  return output
}

function mergeSnapshots(entries, epoch, revision) {
  var list = entries || []
  var primary = null
  for (var i = 0; i < list.length; i++) {
    if (list[i] && list[i].id === "herdr") {
      primary = list[i]
      break
    }
  }
  if (!primary) primary = list[0] || null
  var primarySnapshot = (primary && primary.snapshot) || {}
  var servers = []
  var agents = []
  var attention = []
  for (var j = 0; j < list.length; j++) {
    if (!list[j] || !list[j].snapshot) continue
    servers = servers.concat(stampedServers(list[j]))
    var snapshotAgents = list[j].snapshot.agents
    if (Array.isArray(snapshotAgents)) agents = agents.concat(snapshotAgents)
    var snapshotAttention = list[j].snapshot.attention
    if (Array.isArray(snapshotAttention)) attention = attention.concat(snapshotAttention)
  }
  var merged = {
    schemaVersion: 1,
    providerEpoch: epoch,
    revision: revision,
    capabilities: primarySnapshot.capabilities,
    servers: servers,
    agents: agents,
    attention: attention,
    liveCounts: primarySnapshot.liveCounts,
    completeness: primarySnapshot.completeness,
    windowProcesses: mergedWindowProcesses(list)
  }
  if (primarySnapshot.sourceErrorCode !== undefined
      && primarySnapshot.sourceErrorCode !== null)
    merged.sourceErrorCode = primarySnapshot.sourceErrorCode
  return merged
}
