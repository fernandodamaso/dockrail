pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Shapes
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "DockIconModel.js" as DockIconModel
import "DockConfigModel.js" as ConfigModel
import "DockSidebarInteractionModel.js" as InteractionModel

// Change Icon: one image for the whole app, one browser profile, or windows
// whose title contains some text. The host's single settings writer applies
// the whole change (remove the old override, set the new one) in one save.
// Everything except live settings is captured when the dialog opens, so it
// stays valid after the context menu closes or its windows change.
PopupWindow {
  id: root

  required property var mutationController

  property Item openAnchor: null
  property string position: "bottom"
  property string desktopId: ""
  property string appName: ""
  property string desktopIcon: ""
  property string profileKey: ""
  property string profileName: ""
  property string profileAvatarPath: ""
  property string windowAppId: ""
  property var windows: []
  property var current: ({ kind: "none", key: "", source: "" })
  property var openedSettings: ({ iconOverrides: {}, windowIconOverrides: [] })
  property var imageSources: []
  property string selectedSource: ""
  property string scope: "app"
  property string titleMode: "contains"
  property string titleText: ""
  property string inlineError: ""
  // The file picker is a separate window; the popup steps aside while it is
  // open so the picker gets focus and is not covered, then comes back.
  property bool picking: false
  // Bumped on every launch and close so a late chooser result is ignored.
  property int chooserSerial: 0
  property int chooserLaunchSerial: -1
  property int chooserExitCode: -1
  property bool chooserOutputDone: false
  readonly property bool dialogActive: root.visible || root.picking

  readonly property var settings: root.mutationController && root.mutationController.settings
    ? root.mutationController.settings : ({})
  readonly property var iconOverrides: root.settings.iconOverrides || ({})
  readonly property int reloadRevision: root.mutationController
    ? Number(root.mutationController.iconReloadRevision || 0) : 0
  readonly property bool hasCustomIcon: root.current.kind !== "none"
  readonly property bool usesDefault: root.selectedSource === ""
  readonly property string profileLabel: root.profileName || root.profileKey
  readonly property string titlePattern: root.titleMode === "exact"
    ? DockIconModel.normalizeTitlePattern(root.titleText)
    : DockIconModel.containsToPattern(root.titleText).pattern
  readonly property var builtChange: root.changeArguments()
  readonly property var previewDraft: {
    if (!root.builtChange.ok) return root.openedSettings
    var draft = ConfigModel.iconChangeIntent(root.openedSettings, root.builtChange.args)
    return draft.ok ? draft.settings : root.openedSettings
  }
  readonly property var previewSelection: root.usesDefault
    ? { kind: root.current.kind, profileKey: root.profileKey,
      appId: root.current.appId || root.windowAppId,
      titlePattern: root.current.titlePattern || "", source: "" }
    : { kind: root.scope, profileKey: root.profileKey, appId: root.windowAppId,
      titlePattern: root.titlePattern, source: root.selectedSource }
  readonly property var preview: DockIconModel.previewIconChanges(root.openedSettings,
    root.previewDraft, root.windows, root.desktopId, root.previewSelection)
  readonly property string previewText: DockIconModel.previewSummary({
    kind: root.previewSelection.kind, resetting: root.usesDefault,
    hasPattern: root.previewSelection.titlePattern !== "", changed: root.preview.changed,
    shadowed: root.preview.shadowed, afterKind: root.preview.afterKind,
    total: root.windows.length, appName: root.appName
  })
  readonly property var scopeOptions: {
    var options = [{
      value: "app", title: "All " + root.appName + " windows",
      subtitle: "Every " + root.appName + " window, including new ones"
    }]
    if (root.profileKey) options.push({
      value: "profile", title: "Only the “" + root.profileLabel + "” profile",
      subtitle: "Replaces the small " + root.profileLabel + " badge with this image"
    })
    if (root.windowAppId) options.push({
      value: "window",
      title: root.titleMode === "exact" ? "Only windows whose title matches"
        : "Only windows whose title contains…",
      subtitle: "Handy for telling projects apart"
    })
    return options
  }
  readonly property real screenWidth: root.anchor.window && root.anchor.window.screen
    ? root.anchor.window.screen.width : Style.space(600)
  readonly property real screenHeight: root.anchor.window && root.anchor.window.screen
    ? root.anchor.window.screen.height : Style.space(700)

  // options: { anchorItem, position, desktopId, appName, desktopIcon, profileKey,
  // profileName, profileAvatarPath, appId, title, specificWindow, windows }.
  function openFor(options) {
    var value = options || {}
    if (!value.anchorItem || !String(value.desktopId || "")) return false
    // A new editing session never accepts the previous portal's result. Leave
    // its process alone; Choose file stays disabled until that process exits.
    root.chooserSerial++
    root.picking = false
    if (root.mutationController && typeof root.mutationController.claimIconDialog === "function")
      root.mutationController.claimIconDialog(root)
    root.openAnchor = value.anchorItem
    root.position = String(value.position || "bottom")
    root.desktopId = String(value.desktopId)
    root.appName = String(value.appName || value.desktopId)
    root.desktopIcon = String(value.desktopIcon || "")
    root.profileKey = String(value.profileKey || "")
    root.profileName = String(value.profileName || "")
    root.profileAvatarPath = String(value.profileAvatarPath || "")
    root.windowAppId = DockIconModel.normalizeWindowAppId(String(value.appId || ""))
    root.windows = Array.isArray(value.windows) ? value.windows : []
    root.openedSettings = DockIconModel.iconSettingsSnapshot(root.settings)
    // Title rules only describe a specific window; the app page never adopts one.
    // Settings' Custom icons list selects an exact persisted title rule,
    // not an arbitrary live window that might match a different earlier rule.
    var exactRule = value.existingTitlePattern
      ? DockIconModel.windowIconTarget(root.openedSettings, root.windowAppId,
        String(value.existingTitlePattern)) : null
    root.current = exactRule
      ? {kind:"window",key:exactRule.key,appId:exactRule.appId,
         titlePattern:exactRule.titlePattern,source:exactRule.source}
      : DockIconModel.currentIconTarget({
          settings: root.openedSettings, desktopId: root.desktopId, profileKey: root.profileKey,
          appId: value.specificWindow === true ? root.windowAppId : "",
          title: String(value.title || "")
        })
    root.selectedSource = root.current.source
    var sources = root.current.source ? [root.current.source] : []
    DockIconModel.recentIconSources(root.settings, 7).forEach(function(source) {
      if (sources.indexOf(source) < 0 && sources.length < 6) sources.push(source)
    })
    root.imageSources = sources
    root.titleMode = "contains"
    root.titleText = ""
    root.scope = "app"
    if (root.current.kind === "window") {
      var contains = DockIconModel.patternToContains(root.current.titlePattern)
      root.scope = "window"
      root.titleMode = contains === null ? "exact" : "contains"
      root.titleText = contains === null ? root.current.titlePattern : contains
    } else if (root.current.kind === "profile" && root.profileKey) {
      root.scope = "profile"
    }
    titleInput.text = root.titleText
    root.inlineError = ""
    root.visible = true
    Qt.callLater(function() {
      if (!root.visible) return
      if (root.scope === "window" && !root.titleText) titleInput.forceActiveFocus()
      else keyScope.forceActiveFocus()
    })
    return true
  }

  function closeDialog() {
    root.chooserSerial++
    root.picking = false
    root.inlineError = ""
    root.openAnchor = null
    root.windows = []
    root.visible = false
    root.releaseIconSession()
  }

  function releaseIconSession() {
    if (root.mutationController && typeof root.mutationController.releaseIconDialog === "function")
      root.mutationController.releaseIconDialog(root)
  }

  function handleVisibilityChange() {
    if (root.visible) return
    root.inlineError = ""
    // Native outside-click dismissal ends a session; hiding for the picker does not.
    // closeDialog clears the anchor before hiding, so this cannot recurse.
    if (!root.picking && root.openAnchor) root.closeDialog()
  }

  function selectScope(value) {
    root.scope = value
    root.inlineError = ""
    if (value === "window" && !root.titleText) Qt.callLater(function() { titleInput.forceActiveFocus() })
  }

  function commit(args) {
    if (!root.mutationController || typeof root.mutationController.saveIconChange !== "function") {
      root.inlineError = "Icon changes are not available right now."
      return false
    }
    var reply = root.mutationController.saveIconChange(args)
    if (reply && (reply.ok === true || (reply.data && reply.data.applied === true))) {
      root.closeDialog()
      return true
    }
    var error = reply && reply.error ? reply.error : {}
    var validationErrors = reply && reply.data && reply.data.validationErrors
    var detail = Array.isArray(validationErrors) && validationErrors.length
      ? String(validationErrors[0].message || "") : ""
    root.inlineError = error.code === "E_CONFLICT"
      ? "This icon was changed somewhere else while the dialog was open. Close the dialog and try again."
      : String(detail || error.message || "The icon change was not saved.")
    return false
  }

  function changeArguments() {
    return DockIconModel.iconChangeArguments(root.current, {
      kind: root.scope, source: root.selectedSource, desktopId: root.desktopId,
      profileKey: root.profileKey, appId: root.windowAppId,
      titleMode: root.titleMode, titleText: root.titleText
    }, root.openedSettings)
  }

  function save() {
    var built = root.changeArguments()
    if (!built.ok) {
      root.inlineError = built.error
      return false
    }
    if (built.unchanged) {
      root.closeDialog()
      return true
    }
    return root.commit(built.args)
  }

  function resetToDefault() {
    return root.hasCustomIcon ? root.commit({ remove: root.current, set: null }) : false
  }

  function chooseFile() {
    if (root.picking || fileChooser.running) return
    root.chooserSerial++
    root.chooserLaunchSerial = root.chooserSerial
    root.chooserExitCode = -1
    root.chooserOutputDone = false
    root.inlineError = ""
    root.picking = true
    root.visible = false
    fileChooser.running = true
  }

  function finishChoosing(error) {
    if (!root.picking) return
    if (!root.openAnchor) { root.closeDialog(); return }
    root.visible = true
    root.picking = false
    root.inlineError = error || ""
  }

  // Runs once both the exit code and the collected stdout are known.
  function settleChooser() {
    if (root.chooserExitCode < 0 || root.chooserLaunchSerial !== root.chooserSerial) return
    var code = root.chooserExitCode
    if (code === 0 && !root.chooserOutputDone) return
    root.chooserLaunchSerial = -1
    if (code === 1) return root.finishChoosing("")
    if (code !== 0) return root.finishChoosing("The file chooser could not be opened.")
    var source = DockIconModel.chosenFileSource(chooserOutput.text)
    if (!source) return root.finishChoosing("Choose a PNG or SVG file.")
    root.addChosenFile(source)
    root.finishChoosing("")
  }

  function addChosenFile(source) {
    var sources = root.imageSources.filter(function(existing) {
      return DockIconModel.normalizeSource(existing) !== source
    })
    root.imageSources = [source].concat(sources)
    root.selectedSource = source
    root.inlineError = ""
  }

  implicitWidth: Math.round(Math.min(Style.space(540), root.screenWidth - Style.space(32)))
  implicitHeight: Math.round(Math.min(
    content.implicitHeight + surface.contentTopInset + surface.contentBottomInset,
    root.screenHeight - Style.space(64)))
  color: "transparent"
  grabFocus: true
  visible: false

  onImplicitHeightChanged: if (root.visible) root.anchor.updateAnchor()
  onVisibleChanged: root.handleVisibilityChange()
  Component.onDestruction: root.releaseIconSession()

  anchor {
    window: root.openAnchor ? root.openAnchor.QsWindow.window : null
    adjustment: PopupAdjustment.Slide
    edges: Edges.Top | Edges.Left
    gravity: Edges.Bottom | Edges.Right
    rect.width: 1
    rect.height: 1

    onAnchoring: {
      var item = root.openAnchor
      if (!item || !root.anchor.window) return
      var x = item.width / 2 - root.implicitWidth / 2
      var y = item.height + 8
      if (root.position === "bottom")
        y = -root.implicitHeight - 8
      else if (root.position === "left") {
        x = item.width + 8
        y = item.height / 2 - root.implicitHeight / 2
      } else if (root.position === "right") {
        x = -root.implicitWidth - 8
        y = item.height / 2 - root.implicitHeight / 2
      }
      var point = root.anchor.window.contentItem.mapFromItem(item, x, y)
      var clamped = InteractionModel.clampPopupAnchor(root.position, point, {
        width: root.anchor.window.width, height: root.anchor.window.height
      }, { width: root.implicitWidth, height: root.implicitHeight })
      root.anchor.rect.x = Math.round(clamped.x)
      root.anchor.rect.y = Math.round(clamped.y)
    }
  }

  component SectionLabel: Text {
    textFormat: Text.PlainText
    color: Util.alpha(Color.menu.text, 0.72)
    font.family: Style.font.family
    font.pixelSize: Style.font.caption
    font.bold: true
  }

  component HintText: Text {
    textFormat: Text.PlainText
    wrapMode: Text.Wrap
    color: Util.alpha(Color.menu.text, 0.64)
    font.family: Style.font.family
    font.pixelSize: Style.font.caption
  }

  BorderSurface {
    id: surface
    anchors.fill: parent
    radius: Style.cornerRadius
    color: Color.menu.background
    borderSpec: Border.surfaceSpec("menu", "border", Color.menu.border, Math.max(1, Style.space(1)))
    padding: Style.spacing.popupPadding

    FocusScope {
      id: keyScope
      anchors.fill: parent
      anchors.topMargin: surface.contentTopInset
      anchors.rightMargin: surface.contentRightInset
      anchors.bottomMargin: surface.contentBottomInset
      anchors.leftMargin: surface.contentLeftInset
      focus: true

      Keys.onEscapePressed: root.closeDialog()
      Keys.onReturnPressed: root.save()
      Keys.onEnterPressed: root.save()

      Flickable {
        anchors.fill: parent
        contentWidth: width
        contentHeight: content.implicitHeight
        boundsBehavior: Flickable.StopAtBounds
        clip: true

        Column {
          id: content
          width: parent.width
          spacing: Style.spacing.xxl

          // Header: current artwork, title, app name, profile badge, close.
          Item {
            width: parent.width
            height: Math.max(headerIcon.height, headerText.implicitHeight)

            DockAppIcon {
              id: headerIcon
              width: Style.space(40)
              height: width
              anchors.verticalCenter: parent.verticalCenter
              desktopId: root.desktopId
              desktopIcon: root.desktopIcon
              iconOverrides: root.iconOverrides
              windowOverrideSource: root.current.kind === "window" ? root.current.source : ""
              reloadRevision: root.reloadRevision
              profileKey: root.profileKey
              profileName: root.profileName
              profileAvatarPath: root.profileAvatarPath
              badgeRingColor: Color.menu.background
            }

            Column {
              id: headerText
              anchors.left: headerIcon.right
              anchors.leftMargin: Style.spacing.xxl
              anchors.right: closeButton.left
              anchors.rightMargin: Style.spacing.lg
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.spacing.xxs

              Text {
                textFormat: Text.PlainText
                text: "Change icon"
                color: Color.menu.text
                font.family: Style.font.family
                font.pixelSize: Style.font.title
                font.bold: true
              }
              Row {
                width: parent.width
                spacing: Style.spacing.md
                Text {
                  id: appNameText
                  textFormat: Text.PlainText
                  width: Math.min(implicitWidth, parent.width - (profileBadge.visible ? profileBadge.width + parent.spacing : 0))
                  elide: Text.ElideRight
                  anchors.verticalCenter: parent.verticalCenter
                  text: root.appName
                  color: Util.alpha(Color.menu.text, 0.72)
                  font.family: Style.font.family
                  font.pixelSize: Style.font.body
                }
                BorderSurface {
                  id: profileBadge
                  visible: root.profileKey !== ""
                  anchors.verticalCenter: parent.verticalCenter
                  width: profileBadgeText.implicitWidth + Style.spacing.lg * 2
                  height: profileBadgeText.implicitHeight + Style.spacing.xs * 2
                  radius: Style.cornerRadius
                  color: Style.selectedAccentFill
                  borderSpec: Border.none()
                  Text {
                    id: profileBadgeText
                    anchors.centerIn: parent
                    textFormat: Text.PlainText
                    text: root.profileLabel
                    color: Color.menu.text
                    font.family: Style.font.family
                    font.pixelSize: Style.font.caption
                  }
                }
              }
            }

            Button {
              id: closeButton
              anchors.right: parent.right
              anchors.top: parent.top
              width: Style.space(28)
              height: width
              focusable: true
              foreground: Color.menu.text
              tooltipText: "Close"
              onClicked: root.closeDialog()
              DockLucideIcon {
                anchors.centerIn: parent
                iconName: "x"
                iconSize: Style.space(14)
                tint: Color.menu.text
              }
            }
          }

          // What applies today, so editing an existing override is explicit.
          BorderSurface {
            visible: root.hasCustomIcon
            width: parent.width
            height: noticeText.implicitHeight + Style.spacing.lg * 2
            radius: Style.cornerRadius
            color: Style.normalFillFor(Color.menu.text, Color.accent)
            borderSpec: Border.flat(Util.alpha(Color.accent, 0.5), Math.max(1, Style.normalBorderWidth))
            Text {
              id: noticeText
              anchors.fill: parent
              anchors.margins: Style.spacing.lg
              textFormat: Text.PlainText
              wrapMode: Text.Wrap
              verticalAlignment: Text.AlignVCenter
              text: DockIconModel.currentIconNotice(root.current, root.appName, root.profileLabel)
              color: Color.menu.text
              font.family: Style.font.family
              font.pixelSize: Style.font.bodySmall
            }
          }

          // Image choice: Default, current and recent images, then a file picker.
          Column {
            width: parent.width
            spacing: Style.spacing.md

            SectionLabel { text: "Image" }

            Flow {
              width: parent.width
              spacing: Style.spacing.lg

              Repeater {
                model: [""].concat(root.imageSources)

                delegate: Item {
                  id: tile
                  required property var modelData
                  readonly property string source: String(modelData || "")
                  readonly property bool selected: root.selectedSource === tile.source
                  readonly property bool missing: tile.source !== "" && tileImage.status === Image.Error
                  width: Style.space(64)
                  height: tileFrame.height + Style.spacing.xs + tileLabel.implicitHeight

                  BorderSurface {
                    id: tileFrame
                    anchors.horizontalCenter: parent.horizontalCenter
                    width: Style.space(56)
                    height: width
                    radius: Style.cornerRadius
                    color: tile.selected ? Style.selectedAccentFill
                      : tileMouse.containsMouse ? Style.hoverFillFor(Color.menu.text, Color.accent)
                        : Style.normalFillFor(Color.menu.text, Color.accent)
                    borderSpec: tile.selected
                      ? Border.flat(Color.accent, Math.max(2, Style.normalBorderWidth))
                      : Border.controlSpec(tileMouse.containsMouse ? "hover-cursor" : "normal",
                        Color.menu.text, Color.accent)

                    DockAppIcon {
                      visible: tile.source === ""
                      anchors.centerIn: parent
                      width: Style.space(44)
                      height: width
                      desktopId: root.desktopId
                      desktopIcon: root.desktopIcon
                      reloadRevision: root.reloadRevision
                      profileBadgesEnabled: false
                    }
                    Image {
                      id: tileImage
                      // Custom files are edited and deleted in place: never
                      // reuse cached bytes, and reload when a watched file changes.
                      readonly property int revision: root.reloadRevision
                      onRevisionChanged: {
                        tileImage.source = ""
                        tileImage.source = Qt.binding(function() { return tile.source })
                      }
                      cache: false
                      visible: tile.source !== "" && status === Image.Ready
                      anchors.centerIn: parent
                      width: Style.space(44)
                      height: width
                      source: tile.source
                      sourceSize: Qt.size(width * 2, height * 2)
                      fillMode: Image.PreserveAspectFit
                      asynchronous: true
                    }
                    Column {
                      visible: tile.missing
                      anchors.centerIn: parent
                      spacing: Style.spacing.xxs
                      DockLucideIcon {
                        anchors.horizontalCenter: parent.horizontalCenter
                        iconName: "circle-alert"
                        iconSize: Style.space(16)
                        tint: Color.urgent
                      }
                      Text {
                        anchors.horizontalCenter: parent.horizontalCenter
                        width: tileFrame.width - Style.spacing.sm * 2
                        horizontalAlignment: Text.AlignHCenter
                        wrapMode: Text.Wrap
                        textFormat: Text.PlainText
                        text: "Image missing"
                        color: Color.menu.text
                        font.family: Style.font.family
                        font.pixelSize: Style.font.caption
                      }
                    }
                  }
                  Text {
                    id: tileLabel
                    anchors.top: tileFrame.bottom
                    anchors.topMargin: Style.spacing.xs
                    width: parent.width
                    horizontalAlignment: Text.AlignHCenter
                    elide: Text.ElideMiddle
                    textFormat: Text.PlainText
                    text: tile.source === "" ? "Default" : DockIconModel.sourceFileName(tile.source)
                    color: tile.selected ? Color.menu.text : Util.alpha(Color.menu.text, 0.72)
                    font.family: Style.font.family
                    font.pixelSize: Style.font.caption
                  }
                  MouseArea {
                    id: tileMouse
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: {
                      root.selectedSource = tile.source
                      root.inlineError = ""
                    }
                  }
                }
              }

              Item {
                id: chooseTile
                enabled: !root.picking && !fileChooser.running
                opacity: enabled ? 1 : 0.45
                width: Math.max(Style.space(64), Math.ceil(chooseLabel.implicitWidth))
                height: Style.space(56) + Style.spacing.xs + chooseLabel.implicitHeight

                Item {
                  id: chooseFrame
                  anchors.horizontalCenter: parent.horizontalCenter
                  width: Style.space(56)
                  height: width
                  Rectangle {
                    anchors.fill: parent
                    radius: Style.cornerRadius
                    color: chooseMouse.containsMouse ? Style.hoverFillFor(Color.menu.text, Color.accent)
                      : "transparent"
                  }
                  Shape {
                    anchors.fill: parent
                    enabled: false
                    ShapePath {
                      strokeColor: Util.alpha(Color.menu.text, chooseMouse.containsMouse ? 0.6 : 0.32)
                      strokeWidth: 1
                      strokeStyle: ShapePath.DashLine
                      dashPattern: [4, 3]
                      fillColor: "transparent"
                      startX: 0.5
                      startY: 0.5
                      PathLine { x: chooseFrame.width - 0.5; y: 0.5 }
                      PathLine { x: chooseFrame.width - 0.5; y: chooseFrame.height - 0.5 }
                      PathLine { x: 0.5; y: chooseFrame.height - 0.5 }
                      PathLine { x: 0.5; y: 0.5 }
                    }
                  }
                  DockLucideIcon {
                    anchors.centerIn: parent
                    iconName: "folder-open"
                    iconSize: Style.space(18)
                    tint: Color.menu.text
                  }
                }
                Text {
                  id: chooseLabel
                  anchors.top: chooseFrame.bottom
                  anchors.topMargin: Style.spacing.xs
                  width: parent.width
                  horizontalAlignment: Text.AlignHCenter
                  elide: Text.ElideRight
                  textFormat: Text.PlainText
                  text: "Choose file…"
                  color: Util.alpha(Color.menu.text, 0.72)
                  font.family: Style.font.family
                  font.pixelSize: Style.font.caption
                }
                MouseArea {
                  id: chooseMouse
                  anchors.fill: parent
                  hoverEnabled: true
                  cursorShape: Qt.PointingHandCursor
                  onClicked: root.chooseFile()
                }
              }
            }

            HintText {
              width: parent.width
              text: "Pick an image you've used before, or choose a PNG or SVG file."
            }
          }

          PanelSeparator { foreground: Color.menu.text }

          // Scope: which windows use the chosen image.
          Column {
            width: parent.width
            spacing: Style.spacing.md
            enabled: !root.usesDefault
            opacity: enabled ? 1 : 0.5

            SectionLabel { text: "Use it for" }

            Repeater {
              model: root.scopeOptions

              delegate: BorderSurface {
                id: option
                required property var modelData
                readonly property bool selected: root.scope === option.modelData.value
                width: parent.width
                height: optionText.implicitHeight + Style.spacing.xl * 2
                radius: Style.cornerRadius
                color: option.selected ? Style.selectedAccentFill
                  : optionMouse.containsMouse ? Style.hoverFillFor(Color.menu.text, Color.accent)
                    : "transparent"
                borderSpec: option.selected
                  ? Border.flat(Color.accent, Math.max(2, Style.normalBorderWidth))
                  : Border.controlSpec(optionMouse.containsMouse ? "hover-cursor" : "normal",
                    Color.menu.text, Color.accent)

                Rectangle {
                  id: radio
                  anchors.left: parent.left
                  anchors.leftMargin: Style.spacing.xxl
                  anchors.verticalCenter: parent.verticalCenter
                  width: Style.space(14)
                  height: width
                  radius: width / 2
                  color: "transparent"
                  border.width: Math.max(1, Style.normalBorderWidth)
                  border.color: option.selected ? Color.accent : Util.alpha(Color.menu.text, 0.5)
                  Rectangle {
                    visible: option.selected
                    anchors.centerIn: parent
                    width: parent.width / 2
                    height: width
                    radius: width / 2
                    color: Color.accent
                  }
                }
                Column {
                  id: optionText
                  anchors.left: radio.right
                  anchors.leftMargin: Style.spacing.xl
                  anchors.right: parent.right
                  anchors.rightMargin: Style.spacing.xxl
                  anchors.verticalCenter: parent.verticalCenter
                  spacing: Style.spacing.xxs
                  Text {
                    width: parent.width
                    elide: Text.ElideRight
                    textFormat: Text.PlainText
                    text: option.modelData.title
                    color: Color.menu.text
                    font.family: Style.font.family
                    font.pixelSize: Style.font.body
                    font.bold: option.selected
                  }
                  Text {
                    width: parent.width
                    elide: Text.ElideRight
                    textFormat: Text.PlainText
                    text: option.modelData.subtitle
                    color: Util.alpha(Color.menu.text, 0.64)
                    font.family: Style.font.family
                    font.pixelSize: Style.font.caption
                  }
                }
                MouseArea {
                  id: optionMouse
                  anchors.fill: parent
                  hoverEnabled: true
                  cursorShape: Qt.PointingHandCursor
                  onClicked: root.selectScope(option.modelData.value)
                }
              }
            }

            TextField {
              id: titleInput
              visible: root.scope === "window"
              width: parent.width
              foreground: Color.menu.text
              placeholderText: root.titleMode === "exact" ? "Title pattern, * matches anything"
                : "Part of the window title, e.g. solar"
              text: root.titleText
              onTextEdited: {
                root.titleText = text
                root.inlineError = ""
              }
              onAccepted: root.save()
            }
          }

          // Preview: which of this app's open windows the choice changes.
          BorderSurface {
            visible: root.windows.length > 0
            width: parent.width
            height: previewColumn.implicitHeight + Style.spacing.xxl * 2
            radius: Style.cornerRadius
            color: Style.normalFillFor(Color.menu.text, Color.accent)
            borderSpec: Border.none()

            Column {
              id: previewColumn
              anchors.fill: parent
              anchors.margins: Style.spacing.xxl
              spacing: Style.spacing.lg

              HintText {
                width: parent.width
                text: root.previewText
                color: Color.menu.text
              }

              Grid {
                id: previewGrid
                width: parent.width
                columns: 2
                columnSpacing: Style.spacing.xxl
                rowSpacing: Style.spacing.md

                Repeater {
                  model: root.windows.slice(0, 8)

                  delegate: Row {
                    id: previewRow
                    required property var modelData
                    required property int index
                    readonly property var result: root.preview.rows[previewRow.index]
                    readonly property bool changed: !!previewRow.result && previewRow.result.changed
                    width: (previewGrid.width - previewGrid.columnSpacing) / 2
                    spacing: Style.spacing.md
                    opacity: previewRow.changed ? 1 : 0.45

                    DockAppIcon {
                      width: Style.space(16)
                      height: width
                      anchors.verticalCenter: parent.verticalCenter
                      desktopId: root.desktopId
                      desktopIcon: root.desktopIcon
                      iconOverrides: root.previewDraft.iconOverrides || ({})
                      windowOverrideSource: previewRow.result && previewRow.result.after.kind === "window"
                        ? previewRow.result.after.source : ""
                      reloadRevision: root.reloadRevision
                      profileKey: String(previewRow.modelData.profileKey || "")
                      profileBadgesEnabled: false
                    }
                    Text {
                      width: parent.width - Style.space(16) - parent.spacing
                      anchors.verticalCenter: parent.verticalCenter
                      elide: Text.ElideRight
                      textFormat: Text.PlainText
                      text: String(previewRow.modelData.title || "") || "Untitled window"
                      color: Color.menu.text
                      font.family: Style.font.family
                      font.pixelSize: Style.font.caption
                    }
                  }
                }
              }

              HintText {
                visible: root.windows.length > 8
                width: parent.width
                text: "and " + (root.windows.length - 8) + " more"
              }
            }
          }

          Text {
            visible: root.inlineError !== ""
            width: parent.width
            wrapMode: Text.Wrap
            textFormat: Text.PlainText
            text: root.inlineError
            color: Color.urgent
            font.family: Style.font.family
            font.pixelSize: Style.font.bodySmall
          }

          Item {
            width: parent.width
            height: saveButton.implicitHeight

            Button {
              anchors.left: parent.left
              text: "Reset to default"
              bordered: true
              focusable: root.hasCustomIcon
              enabled: root.hasCustomIcon
              opacity: enabled ? 1 : 0.45
              foreground: Color.menu.text
              tooltipText: root.hasCustomIcon ? "Remove this custom icon" : ""
              onClicked: root.resetToDefault()
            }
            Row {
              anchors.right: parent.right
              spacing: Style.spacing.lg
              Button {
                text: "Cancel"
                bordered: true
                focusable: true
                foreground: Color.menu.text
                onClicked: root.closeDialog()
              }
              Button {
                id: saveButton
                text: "Save"
                bordered: true
                focusable: true
                active: true
                foreground: Color.menu.text
                onClicked: root.save()
              }
            }
          }
        }
      }
    }
  }

  // Omarchy's out-of-process portal chooser: an in-process native (GTK) file
  // dialog can abort and take the whole shell down, so Process is justified here.
  Process {
    id: fileChooser
    command: ["sh", "-c",
      "cmd=$(command -v omarchy-file-select) || cmd=\"${OMARCHY_PATH:-/nonexistent}/bin/omarchy-file-select\"; "
      + "[ -x \"$cmd\" ] || exit 127; exec \"$cmd\" \"$@\"",
      "omarchy-file-select", "--title", "Choose an icon image", "--extensions", "png svg"]
    stdout: StdioCollector {
      id: chooserOutput
      onStreamFinished: {
        root.chooserOutputDone = true
        root.settleChooser()
      }
    }
    // Qt reports a signal death as the signal number, so a crash lands on the error path.
    onExited: function(exitCode) {
      root.chooserExitCode = exitCode
      root.settleChooser()
    }
  }
}
