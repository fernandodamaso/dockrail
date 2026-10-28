import QtQuick
import "components"

// Omarchy owns one headless plugin service. Migration settles before any
// provider that consumes Dockrail/SmartDock shared state can become active.
Item {
  id: root

  property alias migration: migration
  readonly property bool migrationReady: migration.ready
  readonly property bool migrationFailed: migration.failed
  readonly property string migrationError: migration.errorText

  readonly property var launcherBadgeService: launcherLoader.item
  readonly property var browserProfileService: browserLoader.item
  readonly property var herdrService: herdrLoader.item
  readonly property var t3Service: t3Loader.item
  readonly property var claudeService: claudeLoader.item

  DockMigrationBootstrap {
    id: migration
    runtimeMode: "plugin"
  }

  Loader {
    id: launcherLoader
    active: migration.ready
    sourceComponent: Component {
      DockLauncherBadgeService {
        dataRoot: migration.dataRoot
      }
    }
  }

  Loader {
    id: browserLoader
    active: migration.ready
    sourceComponent: Component {
      DockBrowserProfileService {
        dataRoot: migration.dataRoot
      }
    }
  }

  Loader {
    id: herdrLoader
    active: migration.ready
    sourceComponent: Component {
      DockHerdrService {}
    }
  }

  Loader {
    id: t3Loader
    active: migration.ready
    sourceComponent: Component {
      DockHerdrService {
        providerRelativePath: "../provider/t3/bin/dockrail-t3-provider"
      }
    }
  }

  Loader {
    id: claudeLoader
    active: migration.ready
    sourceComponent: Component {
      DockHerdrService {
        providerRelativePath: "../provider/claude/bin/dockrail-claude-provider"
      }
    }
  }
}
