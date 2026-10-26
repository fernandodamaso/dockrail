import QtQuick
import qs.Commons
import "DockSidebarModel.js" as SidebarModel
import "DockHerdrModel.js" as HerdrModel

// Snapshot-only presentation. It never acquires a provider, starts a process,
// subscribes to Herdr or emits desktop notifications. Matched sessions (live or
// preserved parent associations) are filtered out of this fallback; they appear
// as nested tree rows instead. Folding never changes which sessions are matched.
Item {
  id: root
  property var widgetContext: ({})

  readonly property var snapshot: widgetContext && widgetContext.data
    ? widgetContext.data : ({})
  readonly property string presentation: widgetContext && widgetContext.presentation
    ? String(widgetContext.presentation) : "expanded"
  readonly property bool compact: presentation === "compact"
  readonly property bool interfaceAnimationsEnabled: widgetContext
    && widgetContext.interfaceAnimationsEnabled !== false
  readonly property bool presentationVisible: widgetContext
    && widgetContext.presentationVisible !== false
  readonly property var presentationClipItem: widgetContext
    ? widgetContext.presentationClipItem : null
  readonly property real presentationRevision: widgetContext
    ? Number(widgetContext.presentationRevision || 0) : 0
  readonly property var associations: widgetContext && widgetContext.herdrAssociations
    ? widgetContext.herdrAssociations : ({ byWindowKey: ({}), unmatchedServerIds: [] })
  readonly property var matchedIdSet: {
    var set = Object.create(null)
    var byWindow = associations && associations.byWindowKey
    if (byWindow && typeof byWindow === "object") {
      Object.keys(byWindow).forEach(function(windowKey) {
        var serverId = byWindow[windowKey]
        if (typeof serverId === "string" && serverId)
          set[serverId] = true
      })
    }
    return set
  }
  readonly property var servers: {
    var all = snapshot && Array.isArray(snapshot.servers) ? snapshot.servers : []
    return all.filter(function(server) {
      return server && typeof server === "object"
        && root.matchedIdSet[String(server.id || "")] !== true
    })
  }
  readonly property var agents: {
    var all = snapshot && Array.isArray(snapshot.agents) ? snapshot.agents : []
    return all.filter(function(agent) {
      return agent && typeof agent === "object"
        && root.matchedIdSet[String(agent.serverId || "")] !== true
    })
  }
  readonly property int unmatchedBlocked: {
    var count = 0
    root.agents.forEach(function(agent) {
      if (String(agent.status || "") === "blocked") count += 1
    })
    return count
  }
  readonly property var rows: buildRows()
  readonly property bool hasFallbackContent: rows.length > 0

  implicitHeight: !hasFallbackContent ? 0
    : compact ? 44
    : Math.min(240, Math.max(44, 34 + rows.length * 38))
  clip: true
  visible: hasFallbackContent

  function buildRows() {
    var output = []
    var byServer = Object.create(null)
    root.agents.forEach(function(agent) {
      var id = String(agent.serverId || "")
      if (!byServer[id]) byServer[id] = []
      byServer[id].push(agent)
    })
    root.servers.forEach(function(server) {
      var id = String(server.id || "")
      var transport = HerdrModel.serverTransport(server)
      var items = HerdrModel.sortAgentsForDisplay(byServer[id] || [])
      var detail = String(server.health || "unavailable")
      if (transport === "remote") {
        detail = String(server.health || "") === "live" && items.length > 0
          ? "Live" : SidebarModel.herdrStateTitle(server, root.snapshot)
      }
      output.push({
        kind: "session",
        key: "server:" + id,
        title: HerdrModel.serverDisplayLabel(server),
        detail: detail,
        status: String(server.health || "unavailable"),
        transport: transport,
        host: String(server.host || ""),
        session: String(server.session || ""),
        focusAgentSupported: HerdrModel.serverFocusAgentSupported(server)
      })
      var focusUpgradeMessage = HerdrModel.serverFocusUpgradeMessage(server)
      if (focusUpgradeMessage) {
        output.push({
          kind: "notice",
          key: "focus-upgrade:" + id,
          title: focusUpgradeMessage,
          detail: "",
          status: "warning"
        })
      }
      items.forEach(function(agent) {
        var secondary = HerdrModel.displayAgentSecondary(agent)
        output.push({
          kind: "agent",
          key: String(agent.id || id + ":agent"),
          title: HerdrModel.displayAgentTitle(agent),
          detail: secondary || (String(agent.agent || "agent") + " · " + String(agent.status || "unknown")),
          status: String(agent.status || "unknown")
        })
      })
      if (!items.length) {
        var emptyChild = transport === "remote"
          ? SidebarModel.herdrFallbackStateChild(server, root.snapshot)
          : SidebarModel.herdrFallbackEmptyChild(server, root.snapshot)
        if (emptyChild)
          output.push(emptyChild)
      }
    })
    return output
  }

  function summary() {
    if (!root.hasFallbackContent) return ""
    var total = root.agents.length
    var text = "Unmatched / unattached Herdr sessions"
    if (total > 0)
      text += " · " + String(total) + (total === 1 ? " agent" : " agents")
    if (root.unmatchedBlocked > 0)
      text += " · " + root.unmatchedBlocked + " blocked"
    if (SidebarModel.herdrInventoryPartial(root.snapshot))
      text += " · partial"
    return text
  }

  function dotOpacity(status) {
    return status === "working" || status === "blocked" || status === "live"
      ? 1.0 : status === "done" ? 0.75 : 0.45
  }

  function itemIntersectsClip(item, clipItem) {
    if (!item || !clipItem || item.height <= 0 || item.width <= 0
        || clipItem.height <= 0 || clipItem.width <= 0)
      return false
    // presentationRevision is presentation-only scroll metadata; reading it
    // forces outer shared-scroll/popup clipping to re-evaluate.
    var revision = root.presentationRevision
    var point = clipItem.mapFromItem(item, 0, 0)
    return point.x + item.width > 0 && point.x < clipItem.width
      && point.y + item.height > 0 && point.y < clipItem.height
  }

  function workingAnimationActive(item, row) {
    if (root.compact || !root.interfaceAnimationsEnabled || !root.presentationVisible
        || !root.visible || !row || row.kind !== "agent"
        || HerdrModel.normalizeStatus(row.status) !== "working")
      return false
    // mapFromItem() does not itself expose the Flickable scroll offset as a
    // binding dependency, so read contentY explicitly for inner-list updates.
    var innerScrollRevision = detailFlick.contentY
    if (!root.itemIntersectsClip(item, detailFlick)) return false
    return !root.presentationClipItem
      || root.itemIntersectsClip(item, root.presentationClipItem)
  }

  Item {
    anchors.fill: parent
    visible: root.compact && root.hasFallbackContent

    Rectangle {
      x: 12
      anchors.verticalCenter: parent.verticalCenter
      width: 8
      height: 8
      radius: 4
      color: Color.foreground
      opacity: root.unmatchedBlocked > 0 ? 1.0 : 0.55
    }

    Text {
      x: 30
      anchors.verticalCenter: parent.verticalCenter
      width: Math.max(0, parent.width - 42)
      text: root.summary()
      textFormat: Text.PlainText
      color: Color.foreground
      font.family: Style.font.family
      font.pixelSize: Style.font.body
      elide: Text.ElideRight
    }
  }

  Flickable {
    id: detailFlick
    anchors.fill: parent
    visible: !root.compact && root.hasFallbackContent
    clip: true
    boundsBehavior: Flickable.StopAtBounds
    flickableDirection: Flickable.VerticalFlick
    contentWidth: width
    contentHeight: detailColumn.implicitHeight

    Column {
      id: detailColumn
      width: parent.width

      Item {
        width: parent.width
        height: 34

        Text {
          x: 10
          anchors.verticalCenter: parent.verticalCenter
          width: Math.max(0, parent.width - 20)
          text: root.summary()
          textFormat: Text.PlainText
          color: Color.foreground
          font.family: Style.font.family
          font.pixelSize: Style.font.body
          font.weight: Font.DemiBold
          elide: Text.ElideRight
        }
      }

      Repeater {
        model: root.rows

        delegate: Item {
          id: detailRow
          required property var modelData
          readonly property string normalizedStatus: HerdrModel.normalizeStatus(modelData.status)
          readonly property bool animatedWorking: root.workingAnimationActive(detailRow, modelData)
          width: detailColumn.width
          height: 38

          // Preserve every existing static marker except the working agent,
          // which receives the 10px trail slot. With animation disabled or
          // clipped, the legacy 7px working dot is centered in that slot.
          Rectangle {
            visible: !(modelData.kind === "agent" && detailRow.normalizedStatus === "working")
            x: modelData.kind === "agent" ? 20 : 10
            anchors.verticalCenter: parent.verticalCenter
            width: 7
            height: 7
            radius: 4
            color: Color.foreground
            opacity: root.dotOpacity(modelData.status)
          }

          Item {
            visible: modelData.kind === "agent" && detailRow.normalizedStatus === "working"
            x: 18.5
            anchors.verticalCenter: parent.verticalCenter
            width: 10
            height: 10

            DockHerdrWorkingIndicator {
              objectName: "herdr-unmatched-working-indicator"
              anchors.fill: parent
              visible: detailRow.animatedWorking
              active: visible
              tint: Color.accent
            }

            Rectangle {
              visible: !detailRow.animatedWorking
              anchors.centerIn: parent
              width: 7
              height: 7
              radius: 4
              color: Color.foreground
              opacity: root.dotOpacity(modelData.status)
            }
          }

          Column {
            x: modelData.kind === "agent" ? 38 : 28
            anchors.verticalCenter: parent.verticalCenter
            width: Math.max(0, parent.width - x - 10)
            spacing: 1

            Text {
              width: parent.width
              text: modelData.title
              textFormat: Text.PlainText
              color: Color.foreground
              font.family: Style.font.family
              font.pixelSize: Style.font.body
              font.weight: modelData.kind === "session"
                ? Font.DemiBold : Font.Normal
              elide: Text.ElideRight
            }

            Text {
              visible: modelData.detail.length > 0
              width: parent.width
              text: modelData.detail
              textFormat: Text.PlainText
              color: Color.foreground
              opacity: 0.6
              font.family: Style.font.family
              font.pixelSize: Math.max(10, Style.font.body - 2)
              elide: Text.ElideRight
            }
          }
        }
      }
    }
  }
}
