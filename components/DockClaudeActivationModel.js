// Pure Claude Desktop session URL validation/construction. No provider, window
// or Qt dependencies. Claude Desktop builds this route itself and accepts only
// "last" or a local_ session id, so only the local_ form is ever emitted.

.pragma library

var CLAUDE_SERVER_PREFIX = "claude:"
var MAX_ID_LENGTH = 512
var SESSION_ID_PATTERN = /^local_[A-Za-z0-9-]{1,64}$/

// sessionUrl(serverId, desktopSessionId) returns the Claude Desktop continue
// URL or "". serverId is the canonical "claude:<id>"; desktopSessionId is the
// session id Claude Desktop reports for the agent, or "" when unknown.
function sessionUrl(serverId, desktopSessionId) {
  if (typeof serverId !== "string" || typeof desktopSessionId !== "string") return ""
  if (serverId.length > MAX_ID_LENGTH) return ""
  if (serverId.indexOf(CLAUDE_SERVER_PREFIX) !== 0) return ""
  if (!SESSION_ID_PATTERN.test(desktopSessionId)) return ""
  return "claude://code/continue?session=" + desktopSessionId
}
