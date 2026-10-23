import QtQuick
import Quickshell
import "components"

ShellRoot {
  DockMigrationBootstrap {
    id: migration
    runtimeMode: "standalone"
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
    id: dockLoader
    active: migration.ready
    sourceComponent: Component {
      DockHost {
        runtimeMode: "standalone"
        configPath: migration.configPath
        dataRoot: migration.dataRoot
        herdrService: herdrLoader.item
        t3Service: t3Loader.item
      }
    }
  }
}
