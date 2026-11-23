.pragma library
.import "DockWindowModel.js" as DockWindowModel
.import "DockWorkspaceModel.js" as WorkspaceModel

function groupedPreviewMembers(candidates, liveToplevels) {
  var members = DockWindowModel.liveGroupMembers(candidates, liveToplevels)

  return members.length >= 2 ? members : []
}

function livePreviewMembers(candidates, liveToplevels) {
  return DockWindowModel.liveGroupMembers(candidates, liveToplevels)
}

function hasPreviewContent(memberCount, activityCount, agentCount) {
  return Number(memberCount) >= 2
    || (Number(memberCount) >= 1
      && (Number(activityCount) > 0 || Number(agentCount) > 0))
}

function activityViewportHeight(rowCount, rowHeight, separatorHeight,
                                maxVisibleRows) {
  var visibleRows = Math.min(
    Math.max(0, Number(rowCount) || 0),
    Math.max(0, Number(maxVisibleRows) || 0))
  return visibleRows * Math.max(0, Number(rowHeight) || 0)
    + Math.max(0, visibleRows - 1)
      * Math.max(0, Number(separatorHeight) || 0)
}

function windowSectionLabel(windowCount) {
  return "OPEN WINDOWS · " + Math.max(0, Number(windowCount) || 0)
}

function previewViewport(screenWidth, screenHeight,
                         desiredWidth, desiredHeight, margin) {
  var width = Math.max(1, Number(screenWidth) || 1)
  var height = Math.max(1, Number(screenHeight) || 1)
  var inset = Math.max(0, Number(margin) || 0)
  var requestedWidth = Math.max(1, Number(desiredWidth) || 1)
  var requestedHeight = Math.max(1, Number(desiredHeight) || 1)

  return {
    width: Math.min(requestedWidth, Math.max(1, width - inset * 2)),
    height: Math.min(requestedHeight, Math.max(1, height - inset * 2))
  }
}

function previewAnchorOffset(position, anchorWidth, anchorHeight,
                             popupWidth, popupHeight, gap) {
  var side = String(position || "bottom")
  var anchorW = Math.max(0, Number(anchorWidth) || 0)
  var anchorH = Math.max(0, Number(anchorHeight) || 0)
  var popupW = Math.max(1, Number(popupWidth) || 1)
  var popupH = Math.max(1, Number(popupHeight) || 1)
  var spacing = Math.max(0, Number(gap) || 0)

  if (side === "top") {
    return { x: (anchorW - popupW) / 2, y: anchorH + spacing }
  }
  if (side === "left") {
    return { x: anchorW + spacing, y: (anchorH - popupH) / 2 }
  }
  if (side === "right") {
    return { x: -popupW - spacing, y: (anchorH - popupH) / 2 }
  }
  return { x: (anchorW - popupW) / 2, y: -popupH - spacing }
}

function orientationHorizontal(position) {
  return position === "top" || position === "bottom"
}

function previewStatus(state) {
  var value = state || ({})
  if (value.minimized === true) return "Minimized"

  var workspace = String(value.workspace || "").trim()
  if (!workspace) return "Workspace unknown"
  var label = WorkspaceModel.workspaceBadgeLabel(workspace, "")
  return "Workspace " + (label || workspace)
}

function visiblePreviewTarget(items, presentationId, identityToplevel) {
  var values = items || []
  for (var i = 0; i < values.length; ++i) {
    var item = values[i]
    if (item && String(item.presentationId || item.desktopId || "") === presentationId
        && (item.identityToplevel || null) === (identityToplevel || null)) return item
  }
  return null
}

function memberForAddress(members, address, addressForMember) {
  var wanted = String(address || "").trim().toLowerCase()
  if (!wanted || typeof addressForMember !== "function") return null
  var values = members || []
  for (var i = 0; i < values.length; ++i) {
    if (String(addressForMember(values[i]) || "").trim().toLowerCase() === wanted)
      return values[i]
  }
  return null
}
