pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Hyprland
import Quickshell.Wayland
import qs.Commons
import qs.Ui
import "DockModel.js" as DockModel
import "DockMenuModel.js" as DockMenuModel
import "DockHerdrModel.js" as HerdrModel
import "DockIconModel.js" as DockIconModel
import "DockFullscreenModel.js" as FullscreenModel
import "DockWorkspaceGroupModel.js" as WorkspaceGroupModel

PopupWindow {
  id: root

  required property Item anchorItem
  required property string position
  required property bool autoHide
  required property bool pinnedItem
  required property var runningToplevels
  required property var windowActions
  property bool interfaceAnimationsEnabled: true
  property bool originOnly: false
  property bool controlItem: false
  property bool sidebarHeaderMenu: false
  property var modeSwitchToken: null
  // Optional sidebar adapters; classic menus retain their saved grouping and
  // numeric move page. The owning controller supplies exact-target validation.
  property bool sidebarMode: false
  property var workspaceContext: null
  property var externalTargetValidator: null
  property var herdrAgentActions: null
  signal keyboardDismissed()

  signal openLauncher()
  signal openNewWindow()
  signal addApplication()
  signal removeFromDock()
  signal hideFromDock()
  signal toggleAutoHide()
  signal switchPresentationRequested(string destination, var token)

  property string page: "app"
  property var pageStack: []
  property var targetContexts: []
  property var pageTarget: null
  property var selectedToplevel: pageTarget ? pageTarget.toplevel : null
  property int openGeneration: 0
  property int activeMenuIndex: -1
  // Identity of the highlighted row, so rebuilding the same page (a window
  // title update, a live icon refresh) keeps the pointer/keyboard position.
  property string activeMenuId: ""
  property string activeMenuPage: ""
  property real entranceOpacity: 0
  property real entranceOffset: 0
  property string feedbackTitle: ""
  property string feedbackText: ""
  property string pendingMutationAction: ""
  property string pendingMutationLabel: ""
  property var groupCandidateSnapshot: []
  property string openedWorkspaceGroupsSignature: ""
  property var herdrMenuRecords: []

  readonly property string desktopId: !root.controlItem && root.anchorItem
    ? String(root.anchorItem.desktopId || "") : ""
  readonly property string applicationName: {
    if (root.controlItem) return "Dock Controls"
    var entry = root.anchorItem ? root.anchorItem.entry : null
    return entry && entry.name ? String(entry.name) : root.desktopId
  }
  readonly property var applicationMutationController:
    contextActions.applicationMutationController
  readonly property var workspaceGroups: WorkspaceGroupModel.normalizeWorkspaceGroups(
    root.applicationMutationController && root.applicationMutationController.settings
      ? root.applicationMutationController.settings.workspaceGroups || [] : [])
  readonly property var selectedHandle:
    root.windowActions.handleFor(selectedToplevel)
  readonly property var selectedInfo: selectedHandle
    ? selectedHandle.lastIpcObject || ({})
    : ({})
  readonly property bool selectedMinimized: {
    var originsRevision = root.windowActions.minimizedOriginsSnapshot
    return root.windowActions.isMinimized(selectedToplevel)
  }
  readonly property bool selectedFakeFullscreen:
    FullscreenModel.mode(selectedInfo) === "keep-bars"
  readonly property int selectedWorkspaceId: {
    var workspace = selectedInfo.workspace
      || (selectedHandle ? selectedHandle.workspace : null)
    var id = Number(workspace ? workspace.id : -1)
    return Number.isInteger(id) ? id : -1
  }
  readonly property var runningWindowStates: buildWindowStates()
  readonly property var runningWindowCounts:
    DockModel.windowStateCounts(runningWindowStates)
  readonly property int minimizedCount: runningWindowCounts.minimized
  readonly property int visibleWindowCount: runningWindowCounts.visible
  readonly property var pageActions: decorateWithFeedback(buildPageActions())

  DockContextActionController {
    id: contextActions
    windowActions: root.windowActions
  }

  // Created on first use. It outlives the menu: opening it closes the menu,
  // and it captures everything it needs when it opens.
  LazyLoader {
    id: iconDialogLoader
    active: false
    DockIconDialog {
      mutationController: root.applicationMutationController
    }
  }
  readonly property bool iconDialogOpen: !!iconDialogLoader.item && iconDialogLoader.item.dialogActive

  onRunningToplevelsChanged: {
    // Captured exact identities are invalid after any membership change.
    if (visible) root.dismiss()
  }

  function open() {
    root.openGeneration += 1
    root.targetContexts = root.buildTargetContexts()
    root.herdrMenuRecords = root.captureHerdrMenuRecords()
    root.pageStack = []
    root.pageTarget = root.targetContexts.length === 1
      ? root.targetContexts[0] : null
    root.groupCandidateSnapshot = root.captureGroupCandidateSnapshot()
    root.openedWorkspaceGroupsSignature = root.workspaceGroupsSignature()
    root.page = root.sidebarHeaderMenu ? "controls"
      : root.sidebarMode && root.workspaceContext ? "sidebar-workspace" : DockMenuModel.initialPage(
      root.controlItem, root.targetContexts.length, root.pageTarget !== null,
      root.representedWorkspaceGrouped())
    root.feedbackTitle = ""
    root.feedbackText = ""
    root.pendingMutationAction = ""
    root.pendingMutationLabel = ""
    root.entranceOpacity = root.interfaceAnimationsEnabled ? 0 : 1
    root.entranceOffset = root.interfaceAnimationsEnabled ? 6 : 0
    visible = true
    if (root.interfaceAnimationsEnabled) Qt.callLater(function() {
      if (root.visible) {
        root.entranceOpacity = 1
        root.entranceOffset = 0
      }
    })
    Qt.callLater(function() { root.resetActiveMenuIndex() })
    if (menuSurface) menuSurface.forceActiveFocus()
  }

  function dismiss() {
    visible = false
    root.entranceOpacity = 0
    root.entranceOffset = 0
    root.page = "app"
    root.pageStack = []
    root.targetContexts = []
    root.pageTarget = null
    root.activeMenuIndex = -1
    root.feedbackTitle = ""
    root.feedbackText = ""
    root.pendingMutationAction = ""
    root.pendingMutationLabel = ""
    root.groupCandidateSnapshot = []
    root.openedWorkspaceGroupsSignature = ""
    root.herdrMenuRecords = []
  }

  // Menu-to-editor handoff uses dismiss(); invalidation closes both surfaces.
  function closeAll() {
    root.dismiss()
    if (typeof iconDialogLoader !== "undefined" && iconDialogLoader && iconDialogLoader.item)
      iconDialogLoader.item.closeDialog()
  }

  function updatePopupAnchors() {
    if (root.visible) root.anchor.updateAnchor()
    if (typeof iconDialogLoader !== "undefined" && iconDialogLoader
        && iconDialogLoader.item && iconDialogLoader.item.visible)
      iconDialogLoader.item.anchor.updateAnchor()
  }

  function captureHerdrMenuRecords() {
    var anchor = root.anchorItem
    var actions = root.herdrAgentActions
    var agents = anchor && Array.isArray(anchor["previewAgents"])
      ? anchor["previewAgents"] : []
    if (!actions || agents.length === 0) return []

    var ordered = HerdrModel.sortAgentsForDisplay(agents)
    var label = String(anchor["previewHerdrLabel"] || "").trim()
      || root.applicationName
    var header = DockMenuModel.headerRecord(
      "herdr:header", "Herdr · " + label, "")
    header.muted = true
    var records = [header]
    for (var i = 0; i < ordered.length; ++i) {
      var agent = ordered[i]
      var target = actions.captureAgentTarget(agent.toplevel, agent)
      var enabled = agent.focusAgentSupported === true && target !== null
      records.push(DockMenuModel.agentRecord(
        "herdr:" + String(agent.serverId || "") + ":"
          + String(agent.id || i),
        HerdrModel.displayAgentTitle(agent),
        HerdrModel.displayAgentKind(agent.agent || agent.agentKind || ""),
        agent.status, enabled, target))
    }
    records.push(DockMenuModel.separatorRecord("herdr:separator"))
    return records
  }

  function targetContextFor(toplevel, index) {
    if (!toplevel) return null
    var address = root.windowActions.addressFor(toplevel)
    return {
      key: address !== ""
        ? "address:" + address
        : "snapshot:" + root.openGeneration + ":" + index,
      toplevel: toplevel,
      address: address
    }
  }

  function buildTargetContexts() {
    var targets = []
    for (var i = 0; i < root.runningToplevels.length; ++i) {
      var target = root.targetContextFor(root.runningToplevels[i], i)
      if (target) targets.push(target)
    }
    return targets
  }

  function targetIsValid(targetContext) {
    if (root.sidebarMode && typeof root.externalTargetValidator === "function"
        && !root.externalTargetValidator()) return false
    return DockMenuModel.targetIsCurrent(
      targetContext,
      root.runningToplevels,
      function(toplevel) { return root.windowActions.addressFor(toplevel) })
  }

  function allTargetsAreValid() {
    if (root.targetContexts.length === 0) return false
    for (var i = 0; i < root.targetContexts.length; ++i) {
      if (!root.targetIsValid(root.targetContexts[i])) return false
    }
    return true
  }

  function targetHandle(targetContext) {
    if (!targetContext || !root.targetIsValid(targetContext)) return null
    return root.windowActions.handleFor(targetContext.toplevel)
  }

  function targetInfo(targetContext) {
    var handle = root.targetHandle(targetContext)
    return handle ? handle.lastIpcObject || ({}) : ({})
  }

  function targetFullscreenMode(targetContext) {
    return FullscreenModel.mode(root.targetInfo(targetContext))
  }

  function targetTitle(targetContext, fallbackIndex) {
    if (!targetContext || !targetContext.toplevel)
      return "Window " + (fallbackIndex + 1)
    return String(targetContext.toplevel.title || "").trim()
      || "Window " + (fallbackIndex + 1)
  }

  function windowState(toplevel) {
    return root.windowActions.windowState(toplevel)
  }

  function buildWindowStates() {
    var originsRevision = root.windowActions.minimizedOriginsSnapshot
    var states = []
    for (var i = 0; i < root.runningToplevels.length; ++i)
      states.push(root.windowState(root.runningToplevels[i]))
    return states
  }

  function windowStatusLabel(toplevel) {
    return DockModel.windowStatusLabel(root.windowState(toplevel))
  }

  function targetMinimized(targetContext) {
    if (!targetContext || !root.targetIsValid(targetContext)) return false
    var originsRevision = root.windowActions.minimizedOriginsSnapshot
    return root.windowActions.isMinimized(targetContext.toplevel)
  }

  function workspaceLabel(targetContext) {
    if (!targetContext || !root.targetIsValid(targetContext)) return ""
    var state = root.windowState(targetContext.toplevel)
    var workspace = String(state.workspace || "")
    if (workspace.indexOf("name:") === 0) workspace = workspace.slice(5)
    return workspace ? "Workspace " + workspace : ""
  }

  function representedWorkspaceLabel() {
    var label = ""
    for (var i = 0; i < root.targetContexts.length; ++i) {
      var current = root.workspaceLabel(root.targetContexts[i])
      if (!current) continue
      if (!label) label = current
      else if (current !== label) return "Multiple workspaces"
    }
    return label
  }

  function workspaceIdentityForToplevel(toplevel) {
    if (!toplevel || !root.windowActions || !root.windowActions.isAlive(toplevel)) return ""
    var state = root.windowState(toplevel)
    return WorkspaceGroupModel.canonicalWorkspaceTarget(state ? state.workspace : "")
  }

  function candidateMatchesApplication(toplevel) {
    if (!toplevel || !root.desktopId) return false
    var entries = DesktopEntries.applications.values || []
    var appId = DockModel.toplevelAppId(toplevel, entries)
    var entry = DockModel.entryForDesktopId(root.desktopId, entries)
    return DockModel.entryMatchesAppId(root.desktopId, entry, appId)
  }

  function workspaceGroupCandidates(targetContext) {
    if (!targetContext || !root.targetIsValid(targetContext)) return []
    var workspace = root.workspaceIdentityForToplevel(targetContext.toplevel)
    if (!workspace) return []
    var live = root.windowActions.currentToplevels()
    var candidates = []
    for (var i = 0; i < live.length; ++i) {
      var toplevel = live[i]
      if (!root.windowActions.isAlive(toplevel)
          || !root.candidateMatchesApplication(toplevel)
          || root.workspaceIdentityForToplevel(toplevel) !== workspace) continue
      var address = String(root.windowActions.addressFor(toplevel) || "")
      if (!address) return []
      candidates.push({ toplevel: toplevel, address: address, key: "address:" + address })
    }
    candidates.sort(function(left, right) {
      return left.key < right.key ? -1 : left.key > right.key ? 1 : 0
    })
    return candidates
  }

  function candidateSnapshotsEqual(left, right) {
    return DockMenuModel.targetSnapshotsEqual(left, right)
  }

  function captureGroupCandidateSnapshot() {
    if (root.sidebarMode) return []
    if (root.controlItem || root.targetContexts.length !== 1 || !root.pageTarget) return []
    return root.workspaceGroupCandidates(root.pageTarget)
  }

  function representedWorkspaceIdentity() {
    if (!root.allTargetsAreValid()) return ""
    var identity = ""
    for (var i = 0; i < root.targetContexts.length; ++i) {
      var current = root.workspaceIdentityForToplevel(root.targetContexts[i].toplevel)
      if (!current) return ""
      if (!identity) identity = current
      else if (identity !== current) return ""
    }
    return identity
  }

  function workspaceGroupsSignature() {
    return JSON.stringify(root.workspaceGroups)
  }

  function representedWorkspaceGrouped() {
    if (root.sidebarMode) return false
    var workspace = root.representedWorkspaceIdentity()
    return workspace !== "" && WorkspaceGroupModel.workspaceGroupEnabled(
      root.workspaceGroups, root.desktopId, workspace)
  }

  function canGroupTarget(targetContext) {
    if (root.sidebarMode) return false
    if (!targetContext || root.targetContexts.length !== 1
        || targetContext !== root.pageTarget || !root.targetIsValid(targetContext)) return false
    var workspace = root.workspaceIdentityForToplevel(targetContext.toplevel)
    if (!workspace || WorkspaceGroupModel.workspaceGroupEnabled(
        root.workspaceGroups, root.desktopId, workspace)) return false
    var current = root.workspaceGroupCandidates(targetContext)
    return root.groupCandidateSnapshot.length >= 2
      && root.candidateSnapshotsEqual(root.groupCandidateSnapshot, current)
  }

  function windowPinWorkspaceLabel(identity) {
    var value = String(identity || "")
    if (value.indexOf("id:") === 0) value = value.slice(3)
    else if (value.indexOf("name:") === 0) value = value.slice(5)
    return value ? "Workspace " + value : "Workspace"
  }

  function runWindowWorkspacePinMutation(action, targetContext) {
    if (!targetContext || !root.targetIsValid(targetContext)) {
      root.dismiss()
      return false
    }
    var changed = action === "pin"
      ? root.windowActions.pinWindowToWorkspace(targetContext.toplevel)
      : root.windowActions.unpinWindowFromWorkspace(targetContext.toplevel)
    if (!changed) {
      root.feedbackTitle = action === "pin" ? "Pin Window" : "Unpin Window"
      root.feedbackText = "The exact window or its workspace is no longer available."
      return false
    }
    root.dismiss()
    return true
  }

  function profileDirectoryForTarget(targetContext) {
    if (root.controlItem || !root.anchorItem) return ""
    var service = root.anchorItem.browserProfileService
    if (targetContext && targetContext.address && service
        && typeof service.profileKeyForAddress === "function") {
      var exact = String(service.profileKeyForAddress(targetContext.address) || "")
      if (exact) return exact
    }
    return String(root.anchorItem.browserProfileKey || "")
  }

  function pushPage(nextPage, targetContext) {
    root.pageStack = root.pageStack.concat([{
      page: root.page,
      targetContext: root.pageTarget
    }])
    root.pageTarget = targetContext || null
    root.page = nextPage
    root.feedbackTitle = ""
    root.feedbackText = ""
    Qt.callLater(function() { root.resetActiveMenuIndex() })
  }

  function goBack() {
    if (root.pageStack.length === 0) {
      root.dismiss()
      return false
    }
    var previous = root.pageStack[root.pageStack.length - 1]
    root.pageStack = root.pageStack.slice(0, root.pageStack.length - 1)
    root.pageTarget = previous.targetContext || null
    root.page = previous.page
    root.feedbackTitle = ""
    root.feedbackText = ""
    Qt.callLater(function() { root.resetActiveMenuIndex() })
    return true
  }

  function minimizeRestoreSelected() {
    // Compatibility entry point used by the grouped-action regression harness.
    var changed = root.selectedMinimized
      ? root.windowActions.restoreToplevel(root.selectedToplevel, root.originOnly)
      : root.windowActions.minimizeToplevel(root.selectedToplevel, root.originOnly)
    root.dismiss()
    return changed
  }

  function minimizeRestoreTarget(targetContext) {
    if (!root.targetIsValid(targetContext)) {
      root.dismiss()
      return false
    }
    var changed = root.targetMinimized(targetContext)
      ? root.windowActions.restoreToplevel(targetContext.toplevel, root.originOnly)
      : root.windowActions.minimizeToplevel(targetContext.toplevel, root.originOnly)
    if (!changed) {
      root.feedbackTitle = "Window action failed"
      root.feedbackText = "The selected window could not be minimized or restored."
      return false
    }
    root.dismiss()
    return true
  }

  function selectedAddress() {
    return root.windowActions.addressFor(root.selectedToplevel)
  }

  function dispatchRequest(request) {
    if (!request) return false
    Hyprland.dispatch(request)
    return true
  }

  function moveTargetToWorkspace(targetContext, workspace) {
    if ((root.sidebarMode && !root.windowActions.resolveWorkspaceDropTarget(workspace))
        || !root.targetIsValid(targetContext)) {
      root.dismiss()
      return false
    }
    if (!root.windowActions.moveToplevelToWorkspace(
        targetContext.toplevel, targetContext.address, workspace)) {
      root.feedbackTitle = "Move blocked"
      root.feedbackText = root.windowActions.windowWorkspacePin(targetContext.toplevel)
        ? "This window is pinned to its workspace for this SmartDock session."
        : "The workspace target is no longer valid."
      return false
    }
    root.dismiss()
    return true
  }

  function setTargetFullscreenMode(targetContext, mode) {
    if (!root.targetIsValid(targetContext)) {
      root.dismiss()
      return false
    }
    if (!contextActions.setFullscreenMode(targetContext, mode)) {
      root.feedbackTitle = "Fullscreen failed"
      root.feedbackText = "The compositor rejected the exact-window fullscreen request."
      return false
    }
    root.dismiss()
    return true
  }

  function toggleSelectedFakeFullscreen() {
    if (!root.pageTarget && root.selectedToplevel) {
      root.pageTarget = root.targetContextFor(root.selectedToplevel, 0)
    }
    return root.setTargetFullscreenMode(root.pageTarget, "keep-bars")
  }

  function representedAction(command) {
    if (!root.allTargetsAreValid()) {
      root.dismiss()
      return false
    }
    var changed = false
    if (command === "minimize-visible")
      changed = contextActions.minimizeVisible(root.targetContexts, root.originOnly)
    else if (command === "restore-minimized")
      changed = contextActions.restoreMinimized(root.targetContexts, root.originOnly)
    else if (command === "close-represented")
      changed = contextActions.closeRepresented(root.targetContexts)
    if (!changed) {
      root.feedbackTitle = "Group action failed"
      root.feedbackText = "No represented window accepted the requested action."
      return false
    }
    root.dismiss()
    return true
  }

  function mutationLabel(action) {
    if (action === "pin") return "Pin to Dock"
    if (action === "unpin") return "Unpin from Dock"
    return "Hide App from Dock"
  }

  function runApplicationMutation(action) {
    var reply = contextActions.mutateApplication(action, root.desktopId)
    var presentation = DockMenuModel.mutationPresentation(reply)
    var label = root.mutationLabel(action)
    root.feedbackTitle = label
    if (presentation.state === "saved") {
      root.feedbackText = label + " saved."
      root.pendingMutationAction = ""
      root.pendingMutationLabel = ""
      // Membership changes remove/replace the anchor; close instead of leaving
      // a stale feedback page on the pin shelf or hierarchy row.
      root.dismiss()
      return true
    }
    if (presentation.state === "pending") {
      root.feedbackText = label + " applied for this session; saving…"
      root.pendingMutationAction = action
      root.pendingMutationLabel = label
      root.dismiss()
      return true
    }
    root.feedbackText = presentation.message
    root.pendingMutationAction = ""
    root.pendingMutationLabel = ""
    return false
  }

  function workspaceGroupMutationLabel(action) {
    return action === "group" ? "Group Windows" : "Ungroup"
  }

  function runWorkspaceGroupMutation(action, targetContext) {
    var workspace = action === "group"
      ? root.workspaceIdentityForToplevel(targetContext ? targetContext.toplevel : null)
      : root.representedWorkspaceIdentity()
    if (action === "group" && !root.canGroupTarget(targetContext)) {
      root.dismiss()
      return false
    }
    if (action === "ungroup" && !root.representedWorkspaceGrouped()) {
      root.dismiss()
      return false
    }
    if (!workspace) {
      root.dismiss()
      return false
    }
    var reply = contextActions.mutateWorkspaceGroup(action, root.desktopId, workspace)
    var presentation = DockMenuModel.mutationPresentation(reply)
    var label = root.workspaceGroupMutationLabel(action)
    root.feedbackTitle = label
    if (presentation.state === "saved") {
      root.feedbackText = label + " saved."
      root.pendingMutationAction = ""
      root.pendingMutationLabel = ""
      return true
    }
    if (presentation.state === "pending") {
      root.feedbackText = label + " applied for this session; saving…"
      root.pendingMutationAction = action
      root.pendingMutationLabel = label
      return true
    }
    root.feedbackText = presentation.message
    root.pendingMutationAction = ""
    root.pendingMutationLabel = ""
    return false
  }

  function refreshPendingMutationFeedback() {
    if (!root.pendingMutationAction || !root.applicationMutationController) return
    var controller = root.applicationMutationController
    var state = String(controller.settingsWriteState || "")
    if (state === "saved" && controller.settingsPersisted === true) {
      root.feedbackTitle = root.pendingMutationLabel
      root.feedbackText = root.pendingMutationLabel + " saved."
      root.pendingMutationAction = ""
      root.pendingMutationLabel = ""
    } else if (state === "error") {
      root.feedbackTitle = root.pendingMutationLabel + " failed"
      root.feedbackText = String(controller.settingsWriteError || "The change could not be saved.")
      root.pendingMutationAction = ""
      root.pendingMutationLabel = ""
    }
  }

  function applicationActionRecords(prefix, targetContext) {
    var controllerAvailable = root.applicationMutationController !== null
      && root.applicationMutationController !== undefined
    // Pin shelf icons are already dock membership; hide belongs on hierarchy
    // window/app menus only, not on the pinned strip.
    var pinStripContext = !!(root.anchorItem && root.anchorItem.pinStripOwned === true)
    var records = [
      DockMenuModel.actionRecord(
        prefix + ":pin", root.pinnedItem ? "Unpin from Dock" : "Pin to Dock",
        root.pinnedItem ? "pin-off" : "pin",
        controllerAvailable && root.desktopId !== "",
        root.pinnedItem ? "unpin-app" : "pin-app", targetContext)
    ]
    if (!pinStripContext) {
      records.push(DockMenuModel.actionRecord(
        prefix + ":hide", "Hide App from Dock", "eye-off",
        controllerAvailable && root.desktopId !== "",
        "hide-app", targetContext))
    }
    records.push(
      DockMenuModel.actionRecord(
        prefix + ":change-icon", "Change Icon\u2026", "image",
        controllerAvailable && root.desktopId !== "",
        "change-icon", targetContext),
      DockMenuModel.actionRecord(
        prefix + ":open-new", "Open New Window", "plus", true,
        "open-new", targetContext))
    return records
  }

  function appPageActions() {
    var total = root.targetContexts.length
    var subtitle = total === 0 ? "No open windows" : root.representedWorkspaceLabel()
    if (total > 0) {
      if (subtitle) subtitle += " · "
      subtitle += total + (total === 1 ? " window" : " windows")
    }
    var records = [
      DockMenuModel.headerRecord("app:header", root.applicationName, subtitle)
    ]

    if (root.representedWorkspaceGrouped()) {
      records.push(DockMenuModel.actionRecord(
        "app:ungroup", "Ungroup", "", true,
        "ungroup-windows", null))
      records.push(DockMenuModel.separatorRecord("app:ungroup-separator"))
    }

    // Saved groups keep this page even when only one window remains.
    if (total > 0) {
      records.push(DockMenuModel.actionRecord(
        "app:choose", "Choose Window…", "app-window", true,
        "open-chooser-page", null, { submenu: true }))
      records.push(DockMenuModel.separatorRecord("app:window-actions"))
    }
    if (total > 1) {
      records.push(DockMenuModel.actionRecord(
        "app:minimize-visible",
        "Minimize " + root.visibleWindowCount + " Visible",
        "minus", root.visibleWindowCount > 0,
        "minimize-visible", null))
      records.push(DockMenuModel.actionRecord(
        "app:restore-minimized",
        "Restore " + root.minimizedCount + " Minimized",
        "maximize-2", root.minimizedCount > 0,
        "restore-minimized", null))
      records.push(DockMenuModel.separatorRecord("app:application-actions"))
    }

    records = records.concat(root.applicationActionRecords("app", null))
    if (total > 1) {
      records.push(DockMenuModel.separatorRecord("app:close-separator"))
      records.push(DockMenuModel.actionRecord(
        "app:close-represented",
        "Close " + total + " Windows", "x", true,
        "close-represented", null))
    }
    return records
  }

  function chooserPageActions() {
    var records = [
      DockMenuModel.actionRecord(
        "chooser:back", "Back", "chevron-left", true, "back", null),
      DockMenuModel.headerRecord(
        "chooser:header", root.applicationName, "Choose Window")
    ]
    for (var i = 0; i < root.targetContexts.length; ++i) {
      var target = root.targetContexts[i]
      var status = root.windowStatusLabel(target.toplevel)
      var title = (target.toplevel && target.toplevel.activated ? "● " : "")
        + (status ? status + " " : "") + root.targetTitle(target, i)
      records.push(DockMenuModel.actionRecord(
        "chooser:" + target.key, title, "app-window",
        root.targetIsValid(target), "open-window-page", target,
        { submenu: true }))
    }
    return records
  }

  function toplevelAppId(toplevel) {
    return DockIconModel.normalizeWindowAppId(
      String(toplevel && (toplevel.appId || toplevel.app_id) || ""))
  }

  // Captures the identities the Change Icon dialog needs: the desktop ID for
  // app/profile icons and the raw Wayland app ID for title rules.
  function iconDialogOptions(targetContext) {
    var anchor = root.anchorItem
    var service = anchor ? anchor.browserProfileService : null
    var profileKey = root.profileDirectoryForTarget(targetContext)
    var profile = profileKey && service && typeof service.profileFor === "function"
      ? service.profileFor(profileKey) : null
    var windows = []
    var included = []
    var appId = targetContext ? root.toplevelAppId(targetContext.toplevel) : ""
    for (var i = 0; i < root.targetContexts.length; ++i) {
      var target = root.targetContexts[i]
      if (!root.targetIsValid(target)) continue
      if (!appId) appId = root.toplevelAppId(target.toplevel)
      included.push(target.toplevel)
      windows.push({
        appId: root.toplevelAppId(target.toplevel),
        title: String(target.toplevel.title || ""),
        profileKey: root.profileDirectoryForTarget(target)
      })
    }
    // The preview covers every open window of the app, not only the ones this
    // dock item represents (ungrouped items, other workspaces or monitors).
    var all = appId ? root.windowActions.currentToplevels() : []
    for (var j = 0; j < all.length; ++j) {
      var toplevel = all[j]
      if (!toplevel || included.indexOf(toplevel) >= 0 || root.toplevelAppId(toplevel) !== appId)
        continue
      var address = root.windowActions.addressFor(toplevel)
      windows.push({
        appId: root.toplevelAppId(toplevel),
        title: String(toplevel.title || ""),
        profileKey: address && service && typeof service.profileKeyForAddress === "function"
          ? String(service.profileKeyForAddress(address) || "") : ""
      })
    }
    return {
      anchorItem: anchor,
      position: root.position,
      desktopId: root.desktopId,
      appName: root.applicationName,
      desktopIcon: anchor && anchor.entry ? String(anchor.entry.icon || "") : "",
      profileKey: profileKey,
      profileName: profile ? String(profile.name || "") : "",
      profileAvatarPath: profile ? String(profile.avatarPath || "") : "",
      appId: appId,
      title: targetContext && targetContext.toplevel ? String(targetContext.toplevel.title || "") : "",
      specificWindow: !!targetContext,
      windows: windows
    }
  }

  function openIconDialog(targetContext) {
    var options = root.iconDialogOptions(targetContext)
    root.dismiss()
    if (typeof iconDialogLoader === "undefined" || !iconDialogLoader) return false
    iconDialogLoader.active = true
    return !!iconDialogLoader.item && iconDialogLoader.item.openFor(options)
  }

  function windowPageActions() {
    var target = root.pageTarget
    var valid = root.targetIsValid(target)
    var addressValid = valid && String(target ? target.address : "") !== ""
    var locationValid = !root.sidebarMode || (valid
      && root.windowActions.reliableWorkspaceForToplevel(target.toplevel) !== "")
    var index = Math.max(0, root.targetContexts.indexOf(target))
    var subtitle = root.targetTitle(target, index)
    var workspace = root.workspaceLabel(target)
    if (workspace) subtitle += " · " + workspace
    var fullscreenMode = root.targetFullscreenMode(target)
    var records = []

    if (root.pageStack.length > 0) {
      records.push(DockMenuModel.actionRecord(
        "window:back", "Back", "chevron-left", true, "back", null))
    }
    records.push(DockMenuModel.headerRecord(
      "window:header", root.applicationName, subtitle))
    records.push(DockMenuModel.actionRecord(
      "window:minimize",
      root.targetMinimized(target) ? "Restore" : "Minimize",
      root.targetMinimized(target) ? "maximize-2" : "minus",
      addressValid && locationValid, "minimize-restore", target))
    records.push(DockMenuModel.actionRecord(
      "window:workspace", "Move to Workspace…", "arrow-right-left",
      addressValid && locationValid, "open-workspaces-page", target, { submenu: true }))
    var windowPin = valid ? root.windowActions.windowWorkspacePin(target.toplevel) : null
    var reliableWorkspace = windowPin ? windowPin.workspace
      : root.workspaceIdentityForToplevel(target ? target.toplevel : null)
    records.push(DockMenuModel.actionRecord(
      "window:workspace-pin",
      (windowPin ? "Unpin Window from " : "Pin Window to ")
        + root.windowPinWorkspaceLabel(reliableWorkspace),
      windowPin ? "pin-off" : "pin",
      valid && reliableWorkspace !== "",
      windowPin ? "unpin-window-workspace" : "pin-window-workspace", target))
    if (root.representedWorkspaceGrouped()) {
      records.push(DockMenuModel.actionRecord(
        "window:ungroup", "Ungroup", "", valid,
        "ungroup-windows", target))
    } else if (root.canGroupTarget(target)) {
      records.push(DockMenuModel.actionRecord(
        "window:group", "Group Windows", "", true,
        "group-windows", target))
    }
    records.push(DockMenuModel.actionRecord(
      "window:fullscreen-keep-bars", "Fullscreen — Keep Bars", "maximize-2",
      addressValid, "fullscreen-keep-bars", target,
      { checked: fullscreenMode === "keep-bars" }))
    records.push(DockMenuModel.actionRecord(
      "window:fullscreen-hide-bars", "Fullscreen — Hide Bars", "maximize-2",
      addressValid, "fullscreen-hide-bars", target,
      { checked: fullscreenMode === "hide-bars" }))
    records.push(DockMenuModel.separatorRecord("window:application-actions"))
    records = records.concat(root.applicationActionRecords("window", target))
    records.push(DockMenuModel.separatorRecord("window:close-separator"))
    records.push(DockMenuModel.actionRecord(
      "window:close", "Close Window", "x", valid,
      "close-window", target))
    return records
  }

  function workspacePageActions() {
    if (root.sidebarMode) return root.sidebarWindowWorkspaceActions()
    var target = root.pageTarget
    var valid = root.targetIsValid(target)
    var currentWorkspace = root.selectedWorkspaceId
    var index = Math.max(0, root.targetContexts.indexOf(target))
    var records = [
      DockMenuModel.actionRecord(
        "workspace:back", "Back", "chevron-left", true, "back", null),
      DockMenuModel.headerRecord(
        "workspace:header", "Move to Workspace", root.targetTitle(target, index))
    ]
    for (var workspace = 1; workspace <= 10; ++workspace) {
      records.push(DockMenuModel.actionRecord(
        "workspace:" + workspace, "Workspace " + workspace, "",
        valid && String(target ? target.address : "") !== ""
          && workspace !== currentWorkspace
          && root.windowActions.canMoveToplevelToWorkspace(
            target.toplevel, workspace),
        "move-workspace", target,
        {
          checked: workspace === currentWorkspace,
          workspace: workspace,
          iconText: workspace === currentWorkspace ? "✓" : String(workspace)
        }))
    }
    return records
  }

  function controlPageActions() {
    if (root.sidebarHeaderMenu) return [
      DockMenuModel.headerRecord("sidebar-controls:header", "Sidebar", ""),
      DockMenuModel.actionRecord("sidebar-controls:switch", "Switch to dock",
        "panel-bottom", true, "switch-presentation", null,
        { destination: "classic" })
    ]
    return [
      DockMenuModel.headerRecord("controls:header", "Dock Controls", ""),
      DockMenuModel.actionRecord(
        "controls:launcher", "Open App Launcher",
        DockModel.dockControlIcon("launcher", root.autoHide),
        true, "open-launcher", null),
      DockMenuModel.actionRecord(
        "controls:add", "Add Pinned Application",
        DockModel.dockControlIcon("add", root.autoHide),
        true, "add-application", null),
      DockMenuModel.actionRecord(
        "controls:switch", "Switch to sidebar", "panel-left-open",
        true, "switch-presentation", null, { destination: "sidebar" }),
      DockMenuModel.actionRecord(
        "controls:auto-hide",
        root.autoHide ? "Disable Auto-Hide" : "Enable Auto-Hide",
        DockModel.dockControlIcon("auto-hide", root.autoHide),
        true, "toggle-auto-hide", null)
    ]
  }

  function workspaceContextIsCurrent() {
    var target = root.workspaceContext
    if (!root.sidebarMode || !target || !root.windowActions) return false
    if (typeof root.externalTargetValidator === "function" && !root.externalTargetValidator()) return false
    var current = root.windowActions.resolveWorkspaceDropTarget(target.workspaceIdentity)
    return !!current && current.monitor === target.monitorIdentity
  }

  function sidebarWorkspaceActions() {
    var valid = root.workspaceContextIsCurrent()
    var workspace = root.workspaceContext ? root.workspaceContext.workspaceIdentity : ""
    var pin = valid ? root.windowActions.workspaceMonitorPin(workspace) : null
    return [
      DockMenuModel.headerRecord("sidebar-workspace:header", "Workspace "
        + workspace.replace(/^id:|^name:/, ""), ""),
      DockMenuModel.actionRecord("sidebar-workspace:pin", pin ? "Unpin Workspace from Monitor"
        : "Pin Workspace to Monitor", pin ? "pin-off" : "pin", valid,
        pin ? "sidebar-unpin-workspace" : "sidebar-pin-workspace", null),
      DockMenuModel.actionRecord("sidebar-workspace:move", "Move to Monitor", "arrow-right-left",
        valid && !pin, "sidebar-open-monitors", null, {submenu:true})
    ]
  }

  function sidebarMonitorActions() {
    var valid = root.workspaceContextIsCurrent()
    var workspace = root.workspaceContext ? root.workspaceContext.workspaceIdentity : ""
    var records = [DockMenuModel.actionRecord("sidebar-monitors:back", "Back", "chevron-left", true, "back", null),
      DockMenuModel.headerRecord("sidebar-monitors:header", "Move Workspace to Monitor", "")]
    root.windowActions.currentMonitors().forEach(function(monitor) {
      var identity = root.windowActions.canonicalMonitorIdentity(monitor)
      if (!identity) return
      records.push(DockMenuModel.actionRecord("sidebar-monitor:" + identity,
        root.windowActions.monitorNameForIdentity(identity) || identity, "", valid
          && root.windowActions.canMoveWorkspaceToMonitor(workspace, identity),
        "sidebar-move-workspace-monitor", null, {monitor:identity}))
    })
    return records
  }

  function dispatchSidebarWorkspaceAction(record) {
    if (!root.workspaceContextIsCurrent()) { root.dismiss(); return false }
    var workspace = root.workspaceContext.workspaceIdentity
    var changed = false
    if (record.command === "sidebar-open-monitors") {
      root.pushPage("sidebar-monitors", null)
      return true
    }
    if (record.command === "sidebar-pin-workspace")
      changed = root.windowActions.pinWorkspaceToMonitor(workspace)
    else if (record.command === "sidebar-unpin-workspace")
      changed = root.windowActions.unpinWorkspaceFromMonitor(workspace)
    else if (record.command === "sidebar-move-workspace-monitor")
      changed = root.windowActions.moveWorkspaceToMonitor(workspace, record.monitor)
    if (changed) root.dismiss()
    return changed
  }

  function sidebarWindowWorkspaceActions() {
    var target = root.pageTarget
    var valid = root.targetIsValid(target)
    var current = valid ? root.windowActions.reliableWorkspaceForToplevel(target.toplevel) : ""
    var records = [DockMenuModel.actionRecord("workspace:back", "Back", "chevron-left", true, "back", null),
      DockMenuModel.headerRecord("workspace:header", "Move to Workspace", "")]
    var seen = ({})
    root.windowActions.currentWorkspaces().forEach(function(workspace) {
      var identity = root.windowActions.canonicalWorkspaceIdentity(workspace)
      if (!identity || seen[identity] || !root.windowActions.resolveWorkspaceDropTarget(identity)) return
      seen[identity] = true
      records.push(DockMenuModel.actionRecord("workspace:" + identity,
        "Workspace " + identity.replace(/^id:|^name:/, ""), "",
        valid && current !== "" && current !== identity && target.address !== ""
          && root.windowActions.canMoveToplevelToWorkspace(target.toplevel, identity),
        "move-workspace", target, {workspace:identity, checked:identity === current}))
    })
    return records
  }

  function baselinePageActions() {
    if (root.sidebarMode && root.workspaceContext)
      return root.page === "sidebar-monitors" ? root.sidebarMonitorActions() : root.sidebarWorkspaceActions()
    if (root.controlItem || root.sidebarHeaderMenu || root.page === "controls")
      return root.controlPageActions()
    if (root.page === "window") return root.windowPageActions()
    if (root.page === "chooser") return root.chooserPageActions()
    if (root.page === "workspaces") return root.workspacePageActions()
    return root.appPageActions()
  }

  function buildPageActions() {
    var records = root.baselinePageActions()
    return root.pageStack.length === 0 && (root.herdrMenuRecords || []).length > 0
      ? root.herdrMenuRecords.concat(records) : records
  }

  function decorateWithFeedback(records) {
    if (!root.feedbackText) return records
    return [
      DockMenuModel.headerRecord(
        "feedback:status", root.feedbackTitle || "Status", root.feedbackText),
      DockMenuModel.separatorRecord("feedback:separator")
    ].concat(records)
  }

  function setActiveMenuIndex(index) {
    if (index < 0 || index >= root.pageActions.length) return
    if (!DockMenuModel.isFocusable(root.pageActions[index])) return
    root.activeMenuIndex = index
  }

  function resetActiveMenuIndex() {
    root.activeMenuIndex = DockMenuModel.firstEnabledIndex(root.pageActions)
    Qt.callLater(function() { root.ensureActiveVisible() })
  }

  function restoreActiveMenuIndex() {
    var index = root.page === root.activeMenuPage
      ? DockMenuModel.focusableIndexForId(root.pageActions, root.activeMenuId) : -1
    if (index < 0) {
      root.resetActiveMenuIndex()
      return
    }
    root.activeMenuIndex = index
    // Keep the id when the row merely moved within a rebuilt list.
    root.activeMenuId = String(root.pageActions[index].id || "")
  }

  function moveActiveMenuIndex(delta) {
    var step = DockMenuModel.cursorStep(
      root.pageActions, root.activeMenuIndex, delta, root.pageTarget)
    if (step.targetContext !== root.pageTarget) {
      root.dismiss()
      return
    }
    root.activeMenuIndex = step.index
    Qt.callLater(function() { root.ensureActiveVisible() })
  }

  function ensureActiveVisible() {
    if (!menuList || root.activeMenuIndex < 0) return
    var item = actionRepeater.itemAt(root.activeMenuIndex)
    if (!item) return
    menuList.contentY = DockMenuModel.contentYForRow(
      menuList.contentY, menuList.height, item.y, item.height, actionColumn.height)
  }

  function activateCurrentMenuItem() {
    var index = root.activeMenuIndex
    if (index < 0 || index >= root.pageActions.length) return
    root.dispatchAction(root.pageActions[index], index)
  }

  function dispatchAction(record, index) {
    if (root.sidebarMode && root.externalTargetValidator
        && !root.externalTargetValidator()) {
      root.dismiss()
      return false
    }
    if (!record || record.enabled === false)
      return false
    if (record.kind === "agent") {
      var actions = root.herdrAgentActions
      root.dismiss()
      return !!(actions && record.target
        && actions.activateHerdrTarget(record.target))
    }
    if (record.kind !== "action") return false
    root.setActiveMenuIndex(index)
    var targetContext = record.targetContext || null
    if (targetContext && !root.targetIsValid(targetContext)) {
      root.dismiss()
      return false
    }

    if (root.sidebarMode && String(record.command || "").indexOf("sidebar-") === 0)
      return root.dispatchSidebarWorkspaceAction(record)
    switch (record.command) {
    case "back": return root.goBack()
    case "open-window-page":
      root.pushPage("window", targetContext); return true
    case "open-chooser-page":
      root.pushPage("chooser", null); return true
    case "open-workspaces-page":
      root.pushPage("workspaces", targetContext); return true
    case "minimize-restore": return root.minimizeRestoreTarget(targetContext)
    case "move-workspace":
      return root.moveTargetToWorkspace(targetContext, record.workspace)
    case "pin-window-workspace":
      return root.runWindowWorkspacePinMutation("pin", targetContext)
    case "unpin-window-workspace":
      return root.runWindowWorkspacePinMutation("unpin", targetContext)
    case "fullscreen-keep-bars":
      return root.setTargetFullscreenMode(targetContext, "keep-bars")
    case "fullscreen-hide-bars":
      return root.setTargetFullscreenMode(targetContext, "hide-bars")
    case "minimize-visible": return root.representedAction("minimize-visible")
    case "restore-minimized": return root.representedAction("restore-minimized")
    case "close-represented": return root.representedAction("close-represented")
    case "group-windows": return root.runWorkspaceGroupMutation("group", targetContext)
    case "ungroup-windows": return root.runWorkspaceGroupMutation("ungroup", targetContext)
    case "close-window":
      if (!root.windowActions.closeToplevel(targetContext.toplevel)) {
        root.feedbackTitle = "Close failed"
        root.feedbackText = "The selected window could not be closed."
        return false
      }
      root.dismiss(); return true
    case "pin-app": return root.runApplicationMutation("pin")
    case "unpin-app": return root.runApplicationMutation("unpin")
    case "hide-app": return root.runApplicationMutation("hide")
    case "change-icon": return root.openIconDialog(targetContext)
    case "open-new":
      root.dismiss(); root.openNewWindow(); return true
    case "open-launcher":
      root.dismiss(); Qt.callLater(function() { root.openLauncher() }); return true
    case "add-application":
      root.dismiss(); root.addApplication(); return true
    case "toggle-auto-hide":
      root.toggleAutoHide(); root.dismiss(); return true
    case "switch-presentation":
      var token = root.modeSwitchToken
      var destination = record.destination
      root.dismiss()
      root.switchPresentationRequested(destination, token)
      return true
    default: return false
    }
  }

  onPageChanged: Qt.callLater(resetActiveMenuIndex)
  onPageActionsChanged: Qt.callLater(restoreActiveMenuIndex)
  onActiveMenuIndexChanged: {
    var record = root.activeMenuIndex >= 0 ? root.pageActions[root.activeMenuIndex] : null
    root.activeMenuId = record ? String(record.id || "") : ""
    root.activeMenuPage = root.page
  }
  onInterfaceAnimationsEnabledChanged: {
    if (!root.interfaceAnimationsEnabled) {
      root.entranceOpacity = 1
      root.entranceOffset = 0
    }
  }

  readonly property real sidebarAvailableWidth: root.anchor.window && root.anchor.window.screen
    ? Math.max(1, root.anchor.window.screen.width - 16) : Style.space(320)
  readonly property real sidebarAvailableHeight: root.anchor.window
    ? Math.max(1, root.anchor.window.height - 16) : 520
  implicitWidth: root.sidebarMode ? Math.min(Style.space(320), root.sidebarAvailableWidth)
    : root.controlItem ? Style.space(210)
      : Style.space((root.herdrMenuRecords || []).length > 0 ? 340 : 320)
  implicitHeight: Math.min(root.sidebarMode ? root.sidebarAvailableHeight : 520, 520, actionColumn.implicitHeight + 12)
  color: "transparent"
  grabFocus: true

  anchor {
    window: root.anchorItem ? root.anchorItem.QsWindow.window : null
    adjustment: PopupAdjustment.Slide
    edges: Edges.Top | Edges.Left
    gravity: Edges.Bottom | Edges.Right
    rect.width: 1
    rect.height: 1

    onAnchoring: {
      if (!root.anchorItem || !root.anchor.window) return
      var x = root.anchorItem.width / 2 - root.implicitWidth / 2
      var y = root.anchorItem.height + 8
      if (root.position === "bottom")
        y = -root.implicitHeight - 8
      else if (root.position === "left") {
        x = root.anchorItem.width + 8
        y = root.anchorItem.height / 2 - root.implicitHeight / 2
      } else if (root.position === "right") {
        x = -root.implicitWidth - 8
        y = root.anchorItem.height / 2 - root.implicitHeight / 2
      }
      var point = root.anchor.window.contentItem.mapFromItem(root.anchorItem, x, y)
      if (root.position === "top" || root.position === "bottom")
        point.x = Math.max(8, Math.min(
          point.x, root.anchor.window.width - root.implicitWidth - 8))
      else
        point.y = Math.max(8, Math.min(
          point.y, root.anchor.window.height - root.implicitHeight - 8))
      root.anchor.rect.x = Math.round(point.x)
      root.anchor.rect.y = Math.round(point.y)
    }
  }

  BorderSurface {
    id: menuSurface
    anchors.fill: parent
    opacity: root.entranceOpacity
    transform: Translate {
      x: root.position === "left" ? -root.entranceOffset
        : root.position === "right" ? root.entranceOffset : 0
      y: root.position === "top" ? -root.entranceOffset
        : root.position === "bottom" ? root.entranceOffset : 0
      Behavior on x {
        enabled: root.interfaceAnimationsEnabled
        NumberAnimation { duration: 140; easing.type: Easing.OutCubic }
      }
      Behavior on y {
        enabled: root.interfaceAnimationsEnabled
        NumberAnimation { duration: 140; easing.type: Easing.OutCubic }
      }
    }
    Behavior on opacity {
      enabled: root.interfaceAnimationsEnabled
      NumberAnimation { duration: 140; easing.type: Easing.OutCubic }
    }
    focus: true
    radius: Style.cornerRadius
    color: Color.menu.background
    borderSpec: Border.surfaceSpec(
      "menu", "border", Color.menu.border, Math.max(1, Style.space(2)))

    Keys.onPressed: function(event) {
      if (event.key === Qt.Key_Down) {
        root.moveActiveMenuIndex(1); event.accepted = true
      } else if (event.key === Qt.Key_Up) {
        root.moveActiveMenuIndex(-1); event.accepted = true
      } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter
                 || event.key === Qt.Key_Space) {
        root.activateCurrentMenuItem(); event.accepted = true
      } else if (event.key === Qt.Key_Escape
                 || event.key === Qt.Key_Backspace
                 || event.key === Qt.Key_Left) {
        if (root.pageStack.length > 0) root.goBack()
        else { root.dismiss(); if (root.sidebarMode) root.keyboardDismissed() }
        event.accepted = true
      }
    }

    Flickable {
      id: menuList
      anchors.fill: parent
      anchors.margins: 6
      contentWidth: width
      contentHeight: actionColumn.height
      clip: true
      boundsBehavior: Flickable.StopAtBounds

      Column {
        id: actionColumn
        width: menuList.width

        Repeater {
          id: actionRepeater
          model: root.pageActions

          Item {
            required property var modelData
            required property int index
            width: actionColumn.width
            height: modelData.kind === "separator"
              ? Style.space(10)
              : modelData.kind === "header"
                ? (modelData.subtitle ? Style.space(52) : Style.space(34))
                : modelData.kind === "agent"
                  ? Style.space(32)
                  : Style.spacing.popupRowHeight

            PanelSeparator {
              visible: parent.modelData.kind === "separator"
              anchors.left: parent.left
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              foreground: Color.menu.text
            }

            Column {
              visible: parent.modelData.kind === "header"
              anchors.left: parent.left
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              anchors.leftMargin: Style.spacing.controlPaddingX
              anchors.rightMargin: Style.spacing.controlPaddingX
              spacing: Style.spacing.labelGap

              Text {
                width: parent.width
                text: String(parent.parent.modelData.text || "")
                textFormat: Text.PlainText
                color: parent.parent.modelData.muted === true
                  ? Util.alpha(Color.menu.text, 0.62) : Color.menu.text
                font.family: Style.font.family
                font.pixelSize: Style.font.bodySmall
                font.bold: parent.parent.modelData.muted !== true
                elide: Text.ElideRight
                maximumLineCount: 1
              }
              Text {
                visible: String(parent.parent.modelData.subtitle || "") !== ""
                width: parent.width
                text: String(parent.parent.modelData.subtitle || "")
                textFormat: Text.PlainText
                color: Util.alpha(Color.menu.text, 0.68)
                font.family: Style.font.family
                font.pixelSize: Style.font.caption
                elide: Text.ElideRight
                maximumLineCount: 1
              }
            }

            DockMenuAction {
              visible: parent.modelData.kind === "action"
              anchors.fill: parent
              text: String(parent.modelData.text || "")
              iconName: String(parent.modelData.iconName || "")
              iconText: String(parent.modelData.iconText || "")
              enabled: parent.modelData.enabled !== false
              checked: parent.modelData.checked === true
              submenu: parent.modelData.submenu === true
              hasCursor: root.activeMenuIndex === parent.index
              onCursorRequested: root.setActiveMenuIndex(parent.index)
              onTriggered: root.dispatchAction(parent.modelData, parent.index)
            }

            Item {
              id: agentRecordRow
              visible: parent.modelData.kind === "agent"
              anchors.fill: parent
              opacity: parent.modelData.enabled !== false ? 1 : 0.62

              Accessible.role: parent.modelData.enabled !== false
                ? Accessible.Button : Accessible.StaticText
              Accessible.name: String(parent.modelData.title || "")
              Accessible.description: parent.modelData.enabled !== false
                ? "Focus this Herdr agent pane" : "Remote Herdr agent"
              Accessible.onPressAction: if (parent.modelData.enabled !== false)
                root.dispatchAction(parent.modelData, parent.index)

              Rectangle {
                anchors.fill: parent
                radius: Style.space(8)
                color: root.activeMenuIndex === agentRecordRow.parent.index
                  ? Style.focusFillFor(Color.menu.text, Color.accent)
                  : agentHover.hovered && agentRecordRow.parent.modelData.enabled !== false
                    ? Style.hoverFillFor(Color.menu.text, Color.accent)
                    : "transparent"
              }

              DockHerdrStatusColors { id: agentStatusColors }

              Item {
                id: agentStatusGlyph
                anchors.left: parent.left
                anchors.leftMargin: Style.space(10)
                anchors.verticalCenter: parent.verticalCenter
                width: Style.space(16)
                height: width

                DockHerdrStatusMark {
                  anchors.fill: parent
                  status: agentRecordRow.parent.modelData.status
                  size: parent.width
                  ringColor: Color.menu.background
                  animationsEnabled: root.interfaceAnimationsEnabled
                }

                Rectangle {
                  anchors.centerIn: parent
                  visible: {
                    var status = HerdrModel.normalizeStatus(
                      agentRecordRow.parent.modelData.status)
                    return status === "idle" || status === "unknown"
                  }
                  width: Style.space(8)
                  height: width
                  radius: width / 2
                  color: agentStatusColors.hollow(
                    agentRecordRow.parent.modelData.status)
                    ? "transparent" : agentStatusColors.color(
                      agentRecordRow.parent.modelData.status)
                  border.width: Style.spacing.hairline
                  border.color: agentStatusColors.color(
                    agentRecordRow.parent.modelData.status)
                }
              }

              Item {
                id: agentTrailing
                anchors.right: parent.right
                anchors.rightMargin: Style.space(10)
                anchors.verticalCenter: parent.verticalCenter
                width: agentRecordRow.parent.modelData.enabled !== false
                  ? agentKindText.implicitWidth : remoteTag.width
                height: Math.max(agentKindText.implicitHeight, remoteTag.height)

                Text {
                  id: agentKindText
                  visible: agentRecordRow.parent.modelData.enabled !== false
                  anchors.centerIn: parent
                  text: String(agentRecordRow.parent.modelData.agentKind || "")
                  textFormat: Text.PlainText
                  color: Util.alpha(Color.menu.text, 0.62)
                  font.family: Style.font.menuFamily
                  font.pixelSize: Style.font.caption
                }

                Rectangle {
                  id: remoteTag
                  visible: agentRecordRow.parent.modelData.enabled === false
                  anchors.centerIn: parent
                  width: remoteTagText.implicitWidth + Style.space(12)
                  height: remoteTagText.implicitHeight + Style.space(4)
                  radius: Style.space(5)
                  color: "transparent"
                  border.width: Style.spacing.hairline
                  border.color: Util.alpha(Color.menu.text, 0.30)

                  Text {
                    id: remoteTagText
                    anchors.centerIn: parent
                    text: "remote"
                    textFormat: Text.PlainText
                    color: Util.alpha(Color.menu.text, 0.62)
                    font.family: Style.font.menuFamily
                    font.pixelSize: Style.font.caption
                  }
                }
              }

              Text {
                anchors.left: agentStatusGlyph.right
                anchors.leftMargin: Style.space(10)
                anchors.right: agentTrailing.left
                anchors.rightMargin: Style.space(10)
                anchors.verticalCenter: parent.verticalCenter
                text: String(agentRecordRow.parent.modelData.title || "")
                textFormat: Text.PlainText
                color: Color.menu.text
                font.family: Style.font.menuFamily
                font.pixelSize: Style.font.body
                elide: Text.ElideRight
                maximumLineCount: 1
              }

              HoverHandler {
                id: agentHover
                enabled: agentRecordRow.parent.modelData.enabled !== false
                cursorShape: Qt.PointingHandCursor
                onHoveredChanged: if (hovered)
                  root.setActiveMenuIndex(agentRecordRow.parent.index)
              }

              TapHandler {
                enabled: agentRecordRow.parent.modelData.enabled !== false
                acceptedButtons: Qt.LeftButton
                onTapped: root.dispatchAction(
                  agentRecordRow.parent.modelData, agentRecordRow.parent.index)
              }
            }
          }
        }
      }
    }
  }

  Connections {
    target: root.applicationMutationController
    function onSettingsWriteStateChanged() { root.refreshPendingMutationFeedback() }
    function onSettingsPersistedChanged() { root.refreshPendingMutationFeedback() }
    function onSettingsWriteErrorChanged() { root.refreshPendingMutationFeedback() }
    function onSettingsChanged() {
      if (root.visible && root.workspaceGroupsSignature()
          !== root.openedWorkspaceGroupsSignature) root.dismiss()
    }
  }

  Connections {
    target: ToplevelManager.toplevels
    function onValuesChanged() {
      if (!root.visible || root.targetContexts.length !== 1 || !root.pageTarget) return
      if (!root.candidateSnapshotsEqual(
          root.groupCandidateSnapshot, root.workspaceGroupCandidates(root.pageTarget))) root.dismiss()
    }
  }

  Connections {
    target: Hyprland
    function onRawEvent(event) {
      if (!root.visible || !event) return
      var name = String(event.name || "")
      if (["openwindow", "closewindow", "movewindow", "movewindowv2"].indexOf(name) >= 0)
        root.dismiss()
    }
  }
}
