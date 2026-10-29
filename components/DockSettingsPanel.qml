pragma ComponentBehavior: Bound
import QtQuick
import qs.Ui as Ui
import qs.Commons
import qs.Commons as Commons
import "DockSettingsRegistry.js" as Registry
import "DockSettingsFeaturesModel.js" as Features
import "DockScreenPresentationModel.js" as ScreenModel

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
  property string searchTerm: ""
  readonly property var searchVisibleKeys: {
    var groups=Registry.layoutGroups(metadata,(host.connectedScreens || []).length,host.settings.workspaceLayout || "flat")
    var keys=[]
    groups.forEach(function(group){group.rows.forEach(function(row){keys.push(row.key)})})
    if ((host.settings.sidebarWidgets || []).length) keys.push("sidebarWidgetCollapsed")
    return keys
  }
  readonly property var searchResults: Registry.search(metadata,searchTerm,searchVisibleKeys)
  readonly property var searchMatchCounts: Registry.searchCounts(searchResults)
  readonly property bool searching: searchTerm.trim().length > 0
  readonly property bool welcomeVisible: !searching && Registry.firstRun(host.settingsDefaultsInUse,host.settingsLoaded,host.settingsLoadState)
  readonly property var sections: Registry.registry(metadata)
  readonly property string saveLabel: Registry.status(
    host.settingsWriteState, host.settingsPersisted, host.settingsLoadState)
  readonly property bool readOnly: host.settingsLoadState === "invalid"
  readonly property bool uiVisible: panelOpen
  readonly property bool needsAnchor: !anchorItem
  property int savedRevision: 0
  property string focusPane: "sections"
  readonly property alias layoutView: layoutSection
  readonly property var activeSectionView: searching ? null : selectedSection === "layout" ? layoutSection
    : selectedSection === "appearance" ? appearanceSection
    : selectedSection === "behavior" ? behaviorSection
    : selectedSection === "sidebar-widgets" ? widgetsSection
    : selectedSection === "features" ? featuresSection
    : selectedSection === "apps" ? appsLoader.item : null
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
      searchTerm = ""
      focusPane = "sections"
      rowFeedback = ""
    }
    return true
  }
  function close() {
    if (!panelOpen) return
    dismissAppsPopups()
    if (layoutSection) layoutSection.cancelPending()
    if (appearanceSection) appearanceSection.cancelPending()
    if (behaviorSection) behaviorSection.cancelPending()
    if (widgetsSection) widgetsSection.cancelPending()
    if (featuresSection) featuresSection.cancelPending()
    if (appsLoader.item) appsLoader.item.cancelPending()
    panelOpen = false
    showHelp = false
    if (root.host && root.host.releaseSettingsPanel)
      root.host.releaseSettingsPanel(root)
  }
  function dismissAppsPopups() {
    // The confirmation belongs to the persistent KeyboardPanel, not
    // the Apps Loader. Close both owners before changing sections.
    showAllConfirm.opened = false
    if (appsLoader.item) appsLoader.item.awaitingShowAll = false
    if (host.closeAppPickerFromSettings) host.closeAppPickerFromSettings()
  }
  function selectSection(id) {
    if (Registry.order.indexOf(id) < 0) return false
    searchTerm = ""
    if (selectedSection === "apps" && id !== selectedSection) dismissAppsPopups()
    if (selectedSection === "sidebar-widgets" && id !== selectedSection) widgetsSection.cancelPending()
    if (selectedSection === "apps" && id !== selectedSection && appsLoader.item) appsLoader.item.cancelPending()
    selectedSection = id
    focusPane = "sections"
    lastSection = id
    return true
  }
  function sectionImplemented(id) {
    return ["appearance","layout","behavior","sidebar-widgets","features","apps"].indexOf(id) >= 0
  }
  function openFeature(id) {
    if (!selectSection("features")) return false
    Qt.callLater(function(){featuresSection.focusFeature(id)})
    return true
  }
  function openSearchResult(result) {
    if (!result || !selectSection(result.section)) return false
    Qt.callLater(function(){
      var section=activeSectionView
      if (!section || !section.targets) return
      for(var i=0;i<section.targets.length;i++) {
        var target=section.targets[i]
        if(target && target.key===result.key) {
          section.focusTarget(i)
          focusPane="settings"
          return
        }
      }
    })
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
      onActiveFocusChanged: if (activeFocus && root.panelOpen && root.host.featureReadinessBridge)
        root.host.featureReadinessBridge.focused()
      id: keyboard
      Shortcut { sequence: "Alt+Up"; enabled: root.panelOpen && !!root.activeSectionView && root.focusPane === "settings"; onActivated: root.activeSectionView.reorderSelected(-1) }
      Shortcut { sequence: "Alt+Down"; enabled: root.panelOpen && !!root.activeSectionView && root.focusPane === "settings"; onActivated: root.activeSectionView.reorderSelected(1) }
      anchors.fill: parent
      blocked: searchField.activeFocus || (!!root.activeSectionView && (root.activeSectionView.popupOpen || root.activeSectionView.editorFocused))
      onCloseRequested: {
        if (root.activeSectionView && root.activeSectionView.dismissEditor()) return
        if (root.showHelp) {root.showHelp=false;return}
        if (root.searchTerm !== "") {root.searchTerm="";keyboard.forceActiveFocus();return}
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
        } else if (key === "/") {root.focusPane="sections";searchField.forceActiveFocus()}
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
            color: Commons.Color.foreground
            width: navigation.width
            wrapMode: Text.WordWrap
          }
          Ui.PanelSeparator { width: navigation.width }
          TextInput {
            id:searchField
            objectName:"settings-search"
            width:navigation.width
            height:Style.space(30)
            text:root.searchTerm
            color:Commons.Color.foreground
            font.family:Style.font.family
            font.pixelSize:Style.font.body
            clip:true
            onTextChanged:root.searchTerm=text
            Keys.onEscapePressed:function(event) {
              root.searchTerm=""
              keyboard.forceActiveFocus()
              event.accepted=true
            }
            Text {
              visible:searchField.text.length===0
              text:"Search settings  /"
              color:Commons.Color.foreground
              opacity:0.6
              anchors.verticalCenter:parent.verticalCenter
              font.family:Style.font.family
              font.pixelSize:Style.font.caption
            }
          }
          Repeater {
            model: root.sections
            delegate: Ui.Button {
              required property var modelData
              width: navigation.width
              text: root.searching ? modelData.label + " · " + (root.searchMatchCounts[modelData.id] || 0)
                : modelData.id === "features" && root.host.featureReadinessBridge.lastGoodFeatures
                ? modelData.label + " · " + (Features.counts(root.host.featureReadinessBridge.lastGoodFeatures).limited
                    + Features.counts(root.host.featureReadinessBridge.lastGoodFeatures).missing)
                : modelData.label
              selected: root.selectedSection === modelData.id
              focusable: true
              tooltipText: "Go to " + modelData.label
              onClicked: {root.searchTerm="";root.selectSection(modelData.id)}
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
              color: Commons.Color.foreground
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
            color: Commons.Color.foreground
          }
          Text {
            id: feedbackText
            visible: root.rowFeedback !== ""
            text: root.rowFeedback
            wrapMode: Text.WordWrap
            width: parent.width
            color: Commons.Color.foreground
          }
          Text {
            id: helpText
            visible: root.showHelp
            text: "Host: " + root.host.runtimeMode + " · Settings: " + root.host.configPath
              + "\nCLI and Settings use the same writer."
              + "\nKeyboard: j/k navigate, h/l change, Tab sections/settings, / search, c copy CLI command, Alt+↑/↓ reorder, Esc close."
            textFormat: Text.PlainText
            wrapMode: Text.WordWrap
            width: parent.width
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
            color: Commons.Color.foreground
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
              Column {
                id:welcome
                width:parent.width
                visible:root.welcomeVisible
                spacing:Style.space(10)
                Text {text:"Welcome to Dockrail";color:Commons.Color.foreground;font.family:Style.font.family;font.pixelSize:Style.font.title;font.bold:true}
                Text {
                  width:parent.width;wrapMode:Text.WordWrap;color:Commons.Color.foreground
                  text:"You're using the "+((root.host.currentPresentation().classicScreens || []).length ? "classic dock" : "sidebar")+
                    ". Every change here saves right away; agents can use dockrail config."
                }
                Ui.Button {
                  text:"Try the sidebar"
                  enabled:root.host.settingsLoadState!=="invalid" && root.host.settingsWriteState!=="saving"
                  onClicked:{
                    var entries=root.host.currentPresentation().entries || []
                    var preferred=root.host.focusedSettingsConnector ? root.host.focusedSettingsConnector() : ""
                    var target=entries.filter(function(entry){return entry.connector===preferred})[0] || entries[0]
                    if(target)root.reportWrite(root.host.monitorModeIntent(target.connector,"sidebar",
                      ScreenModel.modeGestureToken(root.host.currentPresentation(),target.connector)))
                  }
                }
                Text {text:"Integrations · "+Features.summary(root.host.featureReadinessBridge.lastGoodFeatures)
                  font.bold:true;color:Commons.Color.foreground;font.family:Style.font.family}
                Ui.Button {text:"Set up Chrome";onClicked:root.openFeature("chrome")}
                Ui.Button {text:"Set up Coding agents (Herdr)";onClicked:root.openFeature("coding-agents")}
                Ui.Button {text:"Set up Launcher badge counts";onClicked:root.openFeature("launcher-counts")}
                Ui.Button {text:"Set up Terminal agent launchers";onClicked:root.openFeature("agent-launchers")}
                Ui.Button {text:"Then make it yours · Appearance";onClicked:root.selectSection("appearance")}
              }
              Column {
                width:parent.width
                visible:!root.searching && !!root.host.settings.sidebarMonitor
                spacing:Style.space(8)
                Text {
                  text:"Legacy setting found · sidebarMonitor"
                  color:Commons.Color.foreground;font.family:Style.font.family;font.bold:true
                }
                Text {width:parent.width;wrapMode:Text.WordWrap;color:Commons.Color.foreground
                  text:"Convert the currently connected monitors into explicit per-monitor choices. Disconnected entries are preserved."}
                Ui.Button {
                  text:"Convert to per-monitor settings"
                  enabled:root.host.settingsLoadState!=="invalid" && root.host.settingsWriteState!=="saving"
                    && !root.host.settingsReloadPending && root.host.settingsLoaded
                  onClicked:{
                    var intent=Registry.legacyConversion(root.host.settings,root.host.currentPresentation())
                    if(intent)root.reportWrite(root.host.saveSettingsIntent(intent.patch,intent.expected))
                  }
                }
              }
              Column {
                width:parent.width
                visible:root.searching
                spacing:Style.space(12)
                Row {
                  width:parent.width;spacing:Style.space(5)
                  Text {
                    text:root.searchResults.length+" settings match"
                    color:Commons.Color.foreground;font.family:Style.font.family;font.pixelSize:Style.font.title
                  }
                  Text {
                    text:"“"+root.searchTerm+"”"
                    font.bold:true;color:Commons.Color.accent
                    font.family:Style.font.family;font.pixelSize:Style.font.title
                  }
                }
                Repeater {
                  model:root.searchResults
                  delegate:Column {
                    id:searchEntry
                    required property var modelData
                    width:parent.width
                    spacing:Style.space(5)
                    Text {
                      text:searchEntry.modelData.sectionLabel+" › "+
                        (searchEntry.modelData.featureId ? "Integrations" : searchEntry.modelData.row.ui.group)
                      color:Commons.Color.foreground;font.family:Style.font.family;font.pixelSize:Style.font.caption
                    }
                    DockSettingsRow {
                      visible:searchEntry.modelData.section!=="layout" && !searchEntry.modelData.featureId
                        && !searchEntry.modelData.row.ui.pairedWith
                        && ["toggle","slider","dropdown","number","segmented"].indexOf(searchEntry.modelData.row.ui.control)>=0
                      width:parent.width;host:root.host;row:searchEntry.modelData.row
                      monitorCount:(root.host.connectedScreens || []).length
                      feedbackActive:root.panelOpen
                      onEdited:root.rowFeedback=""
                    }
                    Ui.Button {
                      visible:searchEntry.modelData.section==="layout" || !!searchEntry.modelData.featureId
                        || !!searchEntry.modelData.row.ui.pairedWith
                        || ["toggle","slider","dropdown","number","segmented"].indexOf(searchEntry.modelData.row.ui.control)<0
                      text:"Open "+searchEntry.modelData.label
                      onClicked:searchEntry.modelData.featureId
                        ? root.openFeature(searchEntry.modelData.featureId)
                        : root.openSearchResult(searchEntry.modelData)
                    }
                  }
                }
              }
              DockSettingsLayout {
                id: layoutSection
                panelActive: root.panelOpen
                width: parent.width
                visible: !root.searching && root.selectedSection === "layout"
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
                visible: !root.searching && root.selectedSection === "appearance"
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
                visible: !root.searching && root.selectedSection === "behavior"
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
              DockSettingsWidgetsSection {
                id:widgetsSection
                width:parent.width
                panelActive:root.panelOpen
                visible:!root.searching && root.selectedSection === "sidebar-widgets"
                host:root.host
                metadata:root.metadata
                onFocusSettings:root.focusPane="settings"
                onFocusSections:{root.focusPane="sections";keyboard.forceActiveFocus()}
                onChanged:root.rowFeedback=""
                onOpenFeatures:root.selectSection("features")
                onReveal:function(item) {
                  var point=item.mapToItem(layoutHost,0,0)
                  if(point.y<settingsScroll.contentY) settingsScroll.contentY=point.y
                  else if(point.y+item.height>settingsScroll.contentY+settingsScroll.height)
                    settingsScroll.contentY=Math.max(0,point.y+item.height-settingsScroll.height)
                }
              }
              DockSettingsFeaturesSection {
                id:featuresSection
                width:parent.width
                panelActive:root.panelOpen
                visible:!root.searching && root.selectedSection==="features"
                host:root.host
                metadata:root.metadata
                onFocusSettings:root.focusPane="settings"
                onFocusSections:{root.focusPane="sections";keyboard.forceActiveFocus()}
                onChanged:root.rowFeedback=""
                onReveal:function(item){
                  var point=item.mapToItem(layoutHost,0,0)
                  if(point.y<settingsScroll.contentY)settingsScroll.contentY=point.y
                  else if(point.y+item.height>settingsScroll.contentY+settingsScroll.height)
                    settingsScroll.contentY=Math.max(0,point.y+item.height-settingsScroll.height)
                }
              }
              // A URL-based Loader creates the Apps file in its own component
              // context. A nested Component under a Bound panel cannot be
              // instantiated by Loader on Qt 6.4 (the headless runner).
              Loader {
                id:appsLoader
                width:parent.width
                height:item ? item.implicitHeight : 0
                active:!root.searching && root.selectedSection==="apps"
                visible:active
                onActiveChanged: {
                  if(active) setSource(Qt.resolvedUrl("DockSettingsAppsSection.qml"), {
                    host:root.host,metadata:root.metadata,panelActive:root.panelOpen
                  })
                }
                onLoaded: if(item) item.panelActive=Qt.binding(function(){return root.panelOpen})
              }
              Connections {
                target:appsLoader.item
                ignoreUnknownSignals:true
                function onFocusSettings(){root.focusPane="settings"}
                function onFocusSections(){root.focusPane="sections";keyboard.forceActiveFocus()}
                function onChanged(){root.rowFeedback=""}
                function onOpenAppPicker(){
                  if(!root.host.openAppPickerFromSettings())
                    root.rowFeedback="The existing app picker is unavailable."
                }
                function onRequestIconChange(item){
                  if(!root.host.openIconFromSettings(item))
                    root.rowFeedback="The Change Icon dialog is unavailable."
                }
                function onRequestShowAll(){showAllConfirm.opened=true}
                function onReveal(item){
                  var point=item.mapToItem(layoutHost,0,0)
                  if(point.y<settingsScroll.contentY)settingsScroll.contentY=point.y
                  else if(point.y+item.height>settingsScroll.contentY+settingsScroll.height)
                    settingsScroll.contentY=Math.max(0,point.y+item.height-settingsScroll.height)
                }
              }
              Text {
                visible: root.selectedSection !== "layout" && root.selectedSection !== "appearance"
                  && root.selectedSection !== "behavior"
                  && root.selectedSection !== "sidebar-widgets" && root.selectedSection !== "features" && root.selectedSection !== "apps"
                width: parent.width
                text: "This section is reserved for the next Settings implementation ticket."
                wrapMode: Text.WordWrap
                font.family: Style.font.family
                color: Commons.Color.foreground
              }
              Ui.Button {
                visible: root.selectedSection !== "layout" && root.selectedSection !== "appearance"
                  && root.selectedSection !== "behavior"
                  && root.selectedSection !== "sidebar-widgets" && root.selectedSection !== "features" && root.selectedSection !== "apps"
                text: "Open Layout"
                onClicked: root.selectSection("layout")
              }
            }
          }
          // Native Omarchy confirmation covers the section column while the
          // selected host's list snapshot is held; no broad mutation on cancel.
          Ui.ConfirmDialog {
            id:showAllConfirm
            objectName:"apps-show-all-confirm"
            parent:keyboard
            anchors.fill:parent
            z:100
            opened:false
            focus:opened
            message:"Show all hidden applications? This will make every hidden app visible without changing pinned apps."
            confirmText:"Show all"
            Keys.onPressed:function(event){if(handleKey(event))event.accepted=true}
            onCanceled:{root.dismissAppsPopups();keyboard.forceActiveFocus()}
            onConfirmed:{opened=false;if(appsLoader.item)appsLoader.item.confirmShowAll();keyboard.forceActiveFocus()}
          }
        }
      }
    }
  }
}
