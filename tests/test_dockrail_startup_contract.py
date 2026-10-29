#!/usr/bin/env python3
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]


def read(path):
    return (ROOT / path).read_text(encoding="utf-8")


class StartupContractTests(unittest.TestCase):
    def test_plugin_service_owns_one_bootstrap_and_gates_providers(self):
        service = read("Service.qml")
        self.assertEqual(service.count("DockMigrationBootstrap"), 1)
        self.assertIn('runtimeMode: "plugin"', service)
        self.assertGreaterEqual(service.count("active: migration.ready"), 3)
        self.assertIn("dataRoot: migration.dataRoot", service)

    def test_overlay_consumes_service_result_instead_of_resolving_paths(self):
        overlay = read("Overlay.qml")
        self.assertIn("pluginService.migration.configPath", overlay)
        self.assertIn("pluginService.migration.dataRoot", overlay)
        self.assertNotIn('Quickshell.env("XDG_CONFIG_HOME")', overlay)
        self.assertIn("active: root.migrationReady", overlay)

    def test_standalone_host_and_herdr_are_migration_gated(self):
        shell = read("shell.qml")
        self.assertEqual(shell.count("DockMigrationBootstrap"), 1)
        self.assertIn('runtimeMode: "standalone"', shell)
        self.assertEqual(shell.count("active: migration.ready"), 4)
        self.assertIn("configPath: migration.configPath", shell)
        self.assertIn("dataRoot: migration.dataRoot", shell)

    def test_registry_and_optional_providers_accept_resolved_data_root(self):
        registry = read("components/DockExternalWidgetRegistry.qml")
        launcher = read("components/DockLauncherBadgeService.qml")
        browser = read("components/DockBrowserProfileService.qml")
        self.assertIn('property string dataRoot: ""', registry)
        self.assertIn('property string dataRoot: ""', launcher)
        self.assertIn('property string dataRoot: ""', browser)
        self.assertIn('root.dataRoot !== ""', registry)
        self.assertIn('root.dataRoot !== ""', launcher)
        self.assertIn('root.dataRoot !== ""', browser)

    def test_retained_runtime_identities_are_unchanged(self):
        manifest = read("manifest.json")
        control = read("components/DockControl.qml")
        actions = read("components/DockWindowActions.qml")
        herdr = read("components/DockHerdrService.qml")
        self.assertIn('"id": "io.github.fernandodamaso.dockrail"', manifest)
        self.assertIn('target: "smartdock"', control)
        self.assertIn("special:smartdock-minimized", actions)
        self.assertIn("smartdock-herdr-provider", herdr)

    def test_cli_only_and_agent_assets_only_exit_before_migration(self):
        install = read("install.sh")
        migration = install.index("dockrail_migrate.py")
        cli_exit = install.index("if $cli_only; then")
        agent_exit = install.index("if $agent_assets_only; then")
        # The helper is copied into bundles earlier, but invocation must occur
        # after both non-migrating modes have returned.
        invocation = install.index('migration_json="$(python3 -B "$source_dir/scripts/dockrail_migrate.py"')
        self.assertLess(cli_exit, invocation)
        self.assertLess(agent_exit, invocation)
        self.assertLess(migration, invocation)

    def test_uninstall_preserves_shared_widget_provider_roots(self):
        uninstall = read("uninstall.sh")
        self.assertNotIn('rm -rf -- "$app_dir"', uninstall)
        self.assertIn("Shared Widget/provider state was preserved", uninstall)


if __name__ == "__main__":
    unittest.main()
