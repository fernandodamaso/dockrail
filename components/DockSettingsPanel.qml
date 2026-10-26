pragma ComponentBehavior: Bound
import QtQuick
import qs.Ui as Ui
import qs.Commons
import "DockSettingsRegistry.js" as Registry

// One host-owned KeyboardPanel, never a delegate-owned preferences editor.
// Only the host writer mutates requested state; this panel never touches disk.
Item {
  id: root
  required property var host
  required property var metadata
  property Item anchorItem: null
  property string anchorPosition: "bottom"
  property bool panelOpen: false
  property string selectedSection: ""
  property string lastSection: ""
  property bool showHelp: false
  property string rowFeedback: ""
  readonly property var sections: Registry.registry(metadata)
  readonly property string saveLabel: Registry.status(
    host.settingsWriteState, host.settingsPersisted, host.settingsLoadState)
  readonly property bool readOnly: host.settingsLoadState === "invalid"
  readonly property bool uiVisible: panelOpen
  readonly property bool needsAnchor: !anchorItem
  property int savedRevision: 0
  property string focusPane: "sections"
  readonly property alias layoutView: layoutSection
  readonly property var activeSectionView: selectedSection === "layout" ? layoutSection
    : selectedSection === "appearance" ? appearanceSection
    : selectedSection === "behavior" ? behaviorSection : null
  readonly property alias keyCatcher: keyboard
  TextEdit { id: clipboard; visible: false }

  width: 0
  height: 0
  visible: true // The child KeyboardPanel owns its own window visibility.

  QtObject {
    id: popupBar
    property string position: root.anchorPosition
    property int barSize: Style.space(36)
    property var activePopout: null
    function requestPopout(owner) { activePopout = owner }
    function releasePopout(owner) {
      if (activePopout === owner) activePopout = null
    }
  }

  function openFor(anchor, position, section) {
    if (!anchor) return false
    var wasOpen = panelOpen
    anchorItem = anchor
    anchorPosition = position || "bottom"
    if (!panelOpen)
      selectedSection = Registry.openingSection(host.currentPresentation(),lastSection)
    if (section) selectSection(section)
    panelOpen = true
    if (!wasOpen) {
      focusPane = "sections"
      rowFeedback = ""
    }
    return true
  }
  function close() {
    if (!panelOpen) return
    if (layoutSection) layoutSection.cancelPending()
    if (appearanceSection) appearanceSection.cancelPending()
    if (behaviorSection) behaviorSection.cancelPending()
    panelOpen = false
    showHelp = false
    if (root.host && root.host.releaseSettingsPanel)
      root.host.releaseSettingsPanel(root)
  }
  function selectSection(id) {
    if (Registry.order.indexOf(id) < 0) return false
    selectedSection = id
    focusPane = "sections"
    lastSection = id
    return true
  }
  function reportWrite(outcome) {
    var result = Registry.writeOutcome(outcome)
    if (!result.accepted && result.reply && result.reply.error)
      rowFeedback = result.reply.error.code + ": " + result.reply.error.message
    else rowFeedback = ""
    return result.accepted
  }

  onSaveLabelChanged: {
    if (saveLabel === "Saved") {
      savedRevision++
      savedFade.restart()
    } else savedFade.stop()
  }
  onPanelOpenChanged: {
    if (host.featureReadinessBridge) {
      host.featureReadinessBridge.panelVisible = panelOpen
      if (panelOpen) host.featureReadinessBridge.focused()
    }
  }

  Timer {
    id: savedFade
    interval: 2000
    onTriggered: root.savedRevision = 0
  }

  Ui.KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    bar: popupBar
    owner: root
    open: root.panelOpen && !!root.anchorItem
    contentWidth: Style.space(680)
    contentHeight: panel.fittedContentHeight(Math.max(navigation.implicitHeight,
      statusRow.implicitHeight + (root.showHelp ? helpText.implicitHeight : 0)
      + (root.readOnly ? invalidText.implicitHeight : 0)
      + (root.rowFeedback ? feedbackText.implicitHeight : 0)
      + layoutHost.implicitHeight + Style.space(48)))
    focusTarget: keyboard
    Ui.PanelKeyCatcher {
      id: keyboard
      Shortcut { sequence: "Alt+Up"; enabled: root.panelOpen && !!root.activeSectionView && root.focusPane === "settings"; onActivated: root.activeSectionView.reorderSelected(-1) }
      Shortcut { sequence: "Alt+Down"; enabled: root.panelOpen && !!root.activeSectionView && root.focusPane === "settings"; onActivated: root.activeSectionView.reorderSelected(1) }
      width: panel.contentWidth
      height: panel.contentHeight
      blocked: !!root.activeSectionView && (root.activeSectionView.popupOpen || root.activeSectionView.editorFocused)
      onCloseRequested: {
        if (root.activeSectionView && root.activeSectionView.dismissEditor()) return
        if (root.showHelp) {root.showHelp=false;return}
        root.close()
      }
      onMoveRequested: function(dx,dy) {
        if (root.focusPane === "sections") {
          if (dy) {
            var next = Registry.order.indexOf(root.selectedSection) + dy
            root.selectSection(Registry.order[Math.max(0,Math.min(Registry.order.length-1,next))])
          }
        } else if (root.activeSectionView) {
          if (dy) root.activeSectionView.moveCursor(dy)
          else root.activeSectionView.adjust(dx)
        }
      }
      onActivateRequested: if (root.focusPane === "settings" && root.activeSectionView) root.activeSectionView.activate()
      onTabRequested: function(direction) {
        root.focusPane = root.focusPane === "sections" ? "settings" : "sections"
        if(root.focusPane === "settings" && root.activeSectionView)
          root.activeSectionView.focusTarget(root.activeSectionView.cursor)
      }
      onTextKey: function(key) {
        if (key === "?") root.showHelp = !root.showHelp
        else if (key === "c" && root.focusPane === "settings" && root.activeSectionView) {
          clipboard.text = root.activeSectionView.copyCommand()
          clipboard.selectAll(); clipboard.copy()
        } else if (key === "/") root.rowFeedback = "Search will be available in SET-08."
      }
      Row {
        anchors.fill: parent
        spacing: Style.space(10)
        Column {
          id: navigation
          width: Style.space(176)
          height: parent.height
          spacing: Style.space(6)
          Text {
            text: "Dockrail Settings"
            font.family: Style.font.family
            font.pixelSize: Style.font.title
            font.bold: true
            color: Color.foreground
            width: navigation.width
            wrapMode: Text.WordWrap
          }
          Ui.PanelSeparator { width: navigation.width }
          Repeater {
            model: root.sections
            delegate: Ui.Button {
              required property var modelData
              width: navigation.width
              text: modelData.label
              selected: root.selectedSection === modelData.id
              focusable: true
              tooltipText: "Go to " + modelData.label
              onClicked: root.selectSection(modelData.id)
            }
          }
          Ui.PanelSeparator { width: navigation.width }
          Ui.Button {
            text: "?"
            tooltipText: "Settings help"
            onClicked: root.showHelp = !root.showHelp
          }
        }
        Column {
          id: sectionColumn
          width: parent.width - navigation.width - parent.spacing
          height: parent.height
          spacing: Style.space(8)
          Row {
            id: statusRow
            width: parent.width
            spacing: Style.space(12)
            Text {
              text: root.saveLabel === "Saved" && root.savedRevision === 0 ? "" : root.saveLabel
              color: Color.foreground
              font.family: Style.font.family
              font.pixelSize: Style.font.caption
            }
            Ui.Button {
              visible: root.host.settingsWriteState === "error"
              text: "Retry"
              onClicked: root.reportWrite(root.host.retrySettings())
            }
            Ui.Button {
              text: "Close"
              onClicked: root.close()
            }
          }
          Text {
            id: invalidText
            visible: root.readOnly
            width: parent.width
            text: "Configuration is invalid. Repair it outside Settings before editing."
            wrapMode: Text.WordWrap
            color: Color.foreground
          }
          Text {
            id: feedbackText
            visible: root.rowFeedback !== ""
            text: root.rowFeedback
            wrapMode: Text.WordWrap
            width: parent.width
            color: Color.foreground
          }
          Text {
            id: helpText
            visible: root.showHelp
            text: "Host: " + root.host.runtimeMode + " · Settings: " + root.host.configPath
              + "\nCLI and Settings use the same writer."
              + "\nKeyboard: j/k navigate, h/l change, Tab sections/settings, / search (SET-08), c copy CLI command, Alt+↑/↓ reorder, Esc close."
            textFormat: Text.PlainText
            wrapMode: Text.WordWrap
            width: parent.width
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
            color: Color.foreground
          }
          Flickable {
            id: settingsScroll
            width: parent.width
            height: Math.max(0, sectionColumn.height - y - Style.space(24))
            clip: true
            contentWidth: width
            contentHeight: layoutHost.implicitHeight
            Column {
              id: layoutHost
              width: settingsScroll.width
              spacing: Style.space(10)
              DockSettingsLayout {
                id: layoutSection
                panelActive: root.panelOpen
                width: parent.width
                visible: root.selectedSection === "layout"
                host: root.host
                metadata: root.metadata
                onFocusSettings: root.focusPane="settings"
                onFocusSections: {root.focusPane="sections";keyboard.forceActiveFocus()}
                onChanged: root.rowFeedback = ""
                onReveal: function(item) {
                  var point = item.mapToItem(layoutHost,0,0)
                  if(point.y < settingsScroll.contentY) settingsScroll.contentY=point.y
                  else if(point.y+item.height > settingsScroll.contentY+settingsScroll.height)
                    settingsScroll.contentY=Math.max(0,point.y+item.height-settingsScroll.height)
                }
              }
              DockSettingsGeneralSection {
                id: appearanceSection
                section: "appearance"
                panelActive: root.panelOpen
                width: parent.width
                visible: root.selectedSection === "appearance"
                host: root.host
                metadata: root.metadata
                onFocusSettings: root.focusPane = "settings"
                onFocusSections: { root.focusPane = "sections"; keyboard.forceActiveFocus() }
                onChanged: root.rowFeedback = ""
                onReveal: function(item) {
                  var point = item.mapToItem(layoutHost,0,0)
                  if (point.y < settingsScroll.contentY) settingsScroll.contentY = point.y
                  else if (point.y + item.height > settingsScroll.contentY + settingsScroll.height)
                    settingsScroll.contentY = Math.max(0, point.y + item.height - settingsScroll.height)
                }
              }
              DockSettingsGeneralSection {
                id: behaviorSection
                section: "behavior"
                panelActive: root.panelOpen
                width: parent.width
                visible: root.selectedSection === "behavior"
                host: root.host
                metadata: root.metadata
                onFocusSettings: root.focusPane = "settings"
                onFocusSections: { root.focusPane = "sections"; keyboard.forceActiveFocus() }
                onChanged: root.rowFeedback = ""
                onReveal: function(item) {
                  var point = item.mapToItem(layoutHost,0,0)
                  if (point.y < settingsScroll.contentY) settingsScroll.contentY = point.y
                  else if (point.y + item.height > settingsScroll.contentY + settingsScroll.height)
                    settingsScroll.contentY = Math.max(0, point.y + item.height - settingsScroll.height)
                }
              }
              Text {
                visible: root.selectedSection !== "layout" && root.selectedSection !== "appearance"
                  && root.selectedSection !== "behavior"
                width: parent.width
                text: root.selectedSection === "sidebar-widgets"
                  ? "Sidebar & Widgets controls will be added in SET-05. Layout is available now."
                  : "This section is reserved for the next Settings implementation ticket."
                wrapMode: Text.WordWrap
                font.family: Style.font.family
                color: Color.foreground
              }
              Ui.Button {
                visible: root.selectedSection !== "layout" && root.selectedSection !== "appearance"
                  && root.selectedSection !== "behavior"
                text: "Open Layout"
                onClicked: root.selectSection("layout")
              }
            }
          }
        }
      }
    }
  }
}
