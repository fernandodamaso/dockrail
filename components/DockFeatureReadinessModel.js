.pragma library

// Readiness decisions and lifecycle state are pure: Python doctor owns all
// OS/installation probes, while this model only controls presentation and IO.
function parseReply(raw) {
  try {
    var reply = JSON.parse(raw)
    if (!reply || reply.ok !== true || !reply.data || !reply.data.features
        || typeof reply.data.features !== "object" || Array.isArray(reply.data.features))
      return null
    var features = reply.data.features
    var names = ["herdrAgents", "chromeProfilesTabs", "launcherCounts", "agentLaunchers"]
    for (var i = 0; i < names.length; i++) {
      var entry = features[names[i]]
      if (!entry || ["ready","limited","unavailable"].indexOf(entry.runtime) < 0
          || ["off","partly-on","on"].indexOf(entry.configuration) < 0
          || ["missing","installed"].indexOf(entry.installation) < 0
          || !entry.nextAction || typeof entry.nextAction.text !== "string")
        return null
    }
    return features
  } catch (error) { return null }
}
function shouldPoll(visible, features) {
  if (!visible || !features) return false
  var names = ["herdrAgents", "chromeProfilesTabs", "launcherCounts", "agentLaunchers"]
  return names.some(function(name) {
    return !features[name] || features[name].runtime !== "ready"
  })
}
function canRefresh(visible, inFlight) { return visible === true && inFlight !== true }
