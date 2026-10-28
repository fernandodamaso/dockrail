// Pure T3 thread URL validation/construction. No provider, window or Qt
// dependencies. The raw paneId is the opaque T3 thread identity and is never
// split, trimmed or decoded before encoding.

.pragma library

var T3_SERVER_PREFIX = "t3:"
// Delegated subagent paneIds are composite keys
// ("thread:delegated-task:<command>:delegate-task:<uuid>") and reach ~130
// characters; the bound must clear those with headroom while staying small.
var MAX_ID_LENGTH = 512

function hasUnpairedSurrogate(value) {
  for (var i = 0; i < value.length; i++) {
    var code = value.charCodeAt(i)
    if (code >= 0xD800 && code <= 0xDBFF) {
      if (i + 1 >= value.length) return true
      var next = value.charCodeAt(i + 1)
      if (next < 0xDC00 || next > 0xDFFF) return true
      i++
    } else if (code >= 0xDC00 && code <= 0xDFFF) {
      return true
    }
  }
  return false
}

function hasControlCharacter(value) {
  for (var i = 0; i < value.length; i++) {
    var code = value.charCodeAt(i)
    if ((code >= 0x00 && code <= 0x1F) || code === 0x7F) return true
  }
  return false
}

function validSegment(value) {
  if (typeof value !== "string" || value === "") return false
  if (value === "." || value === "..") return false
  if (hasControlCharacter(value)) return false
  if (hasUnpairedSurrogate(value)) return false
  return true
}

// threadUrl(serverId, threadId) returns the fully encoded native URL or "".
// serverId is the canonical "t3:<environmentId>"; threadId is the raw paneId.
function threadUrl(serverId, threadId) {
  if (typeof serverId !== "string" || typeof threadId !== "string") return ""
  if (serverId.length > MAX_ID_LENGTH || threadId.length > MAX_ID_LENGTH) return ""
  if (serverId.indexOf(T3_SERVER_PREFIX) !== 0) return ""
  var environmentId = serverId.slice(T3_SERVER_PREFIX.length)
  if (!validSegment(environmentId)) return ""
  if (!validSegment(threadId)) return ""
  return "t3code://threads/" + encodeURIComponent(environmentId)
    + "/" + encodeURIComponent(threadId)
}
