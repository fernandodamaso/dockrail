import QtQuick
import "components"

Item {
  id: root

  // Properties injected by the Omarchy shell plugin host stay on the plugin
  // entry object even while DockHost activation is migration-gated.
  property var shell: null
  property var manifest: null

  readonly property var pluginService: shell && typeof shell.serviceFor === "function"
    ? shell.serviceFor("io.github.fernandodamaso.dockrail") : null
  readonly property bool migrationReady: !!pluginService && pluginService.migrationReady === true

  Loader {
    id: dockLoader
    active: root.migrationReady
    sourceComponent: Component {
      DockHost {
        runtimeMode: "plugin"
        configPath: root.pluginService.migration.configPath
        dataRoot: root.pluginService.migration.dataRoot

        notificationService: root.shell && typeof root.shell.firstPartyServiceFor === "function"
          ? root.shell.firstPartyServiceFor("omarchy.notifications")
          : root.shell && typeof root.shell.serviceFor === "function"
            ? root.shell.serviceFor("omarchy.notifications") : null

        launcherBadgeService: root.pluginService.launcherBadgeService
        browserProfileService: root.pluginService.browserProfileService
        herdrService: root.pluginService.herdrService
        t3Service: root.pluginService.t3Service
        claudeService: root.pluginService.claudeService
      }
    }
  }
}
