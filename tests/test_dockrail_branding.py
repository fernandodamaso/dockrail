#!/usr/bin/env python3
import json
from pathlib import Path
import re
import unittest

ROOT = Path(__file__).resolve().parents[1]

class DockrailBrandingTests(unittest.TestCase):
    def read(self, path):
        return (ROOT / path).read_text(encoding="utf-8")

    def test_manifest_uses_dockrail_identity(self):
        manifest = json.loads(self.read("manifest.json"))
        self.assertEqual(manifest["id"], "io.github.fernandodamaso.dockrail")
        self.assertEqual(manifest["name"], "Dockrail")
        self.assertEqual(manifest["author"], "Dockrail contributors")
        self.assertIn("developer-focused workspace rail", manifest["description"])

    def test_canonical_cli_is_dockrail_while_ipc_target_stays_smartdock(self):
        cli = self.read("scripts/smartdock_cli.py")
        launcher = self.read("scripts/dockrail")
        compat = self.read("scripts/smartdock")
        self.assertIn("Usage: dockrail [OPTIONS] COMMAND", cli)
        self.assertIn("prog='dockrail'", cli)
        self.assertIn("'smartdock', 'request'", cli)
        self.assertIn("Name=Dockrail", launcher)
        self.assertIn("Comment=Developer workspace rail for Hyprland", launcher)
        self.assertIn('exec bash "$script_dir/dockrail" "$@"', compat)

    def test_installer_and_uninstaller_are_product_branded(self):
        install = self.read("install.sh")
        uninstall = self.read("uninstall.sh")
        self.assertIn("Dockrail installed successfully.", install)
        self.assertIn("Name=Dockrail", install)
        self.assertIn("Comment=Developer workspace rail for Hyprland", install)
        self.assertNotIn("SmartDock for Omarchy installed successfully.", install)
        self.assertIn("Remove standalone Dockrail", uninstall)

    def test_sidebar_uses_dockrail_brand(self):
        sidebar = self.read("components/DockSidebar.qml")
        self.assertIn('Accessible.name: "Dockrail"', sidebar)
        self.assertNotIn('Accessible.name: "SmartDock"', sidebar)

    def test_current_docs_use_canonical_product_and_cli(self):
        current_docs = [
            "README.md", "AGENTS.md",
            "docs/AGENT_CONFIGURATION.md", "docs/CLI_REFERENCE.md",
            "docs/CONFIGURATION.md", "docs/DEV_SWITCH.md",
            "docs/HERDR_DATA_ACCESS.md", "docs/SIDEBAR_WIDGETS.md",
            "docs/WIDGET_COMPONENTS.md", "docs/WIDGET_PACKAGES.md",
            "docs/CLI_RUNTIME_CHECKS.md", "docs/DELIVERY.md",
            "docs/DEV_SESSIONS.md", "docs/launcher-badge-counts.md",
            "docs/browser-activity.md", "docs/browser-tabs.md",
        ]
        for path in current_docs:
            text = self.read(path)
            with self.subTest(path=path):
                current = text.replace("formerly SmartDock for Omarchy", "")
                self.assertNotIn("SmartDock for Omarchy", current)
        self.assertTrue(self.read("README.md").startswith("# Dockrail\n"))
        self.assertIn("dockrail status --json", self.read("README.md"))
        self.assertIn("import Dockrail.WidgetKit 1.0", self.read("docs/WIDGET_PACKAGES.md"))
        cli_reference = self.read("docs/CLI_REFERENCE.md")
        self.assertIn("/dockrail/dock.json", cli_reference)
        self.assertIn("/dockrail-cli", cli_reference)
        self.assertIn("${XDG_BIN_HOME:-$HOME/.local/bin}/dockrail", cli_reference)
        self.assertIn("scripts/dockrail", self.read("docs/CLI_RUNTIME_CHECKS.md"))
        self.assertIn("/dockrail/dev-worktrees/", self.read("docs/DEV_SWITCH.md"))

    def test_retained_compatibility_contracts_remain_literal(self):
        migration = self.read("docs/DOCKRAIL_MIGRATION.md")
        install = self.read("install.sh")
        window_actions = self.read("components/DockWindowActions.qml")
        legacy_qmldir = self.read("SmartDock/WidgetKit/qmldir")
        self.assertIn("io.github.fernandodamaso.smartdock", migration)
        self.assertIn("io.github.fernandodamaso.dockrail", migration)
        self.assertIn("smartdock-herdr-helper", install)
        self.assertIn("smartdock-herdr-provider", install)
        self.assertIn("special:smartdock-minimized", window_actions)
        self.assertIn("module SmartDock.WidgetKit", legacy_qmldir)
        readme = self.read("README.md")
        self.assertIn("omarchy plugin update io.github.fernandodamaso.dockrail --yes", readme)
        self.assertIn("omarchy plugin remove io.github.fernandodamaso.smartdock --yes", readme)
        self.assertIn("qs ipc --pid PID call -- smartdock request PAYLOAD", self.read("docs/CLI_REFERENCE.md"))
        self.assertNotIn("call -- dockrail request", self.read("docs/CLI_REFERENCE.md"))

    def test_optional_provider_installers_match_canonical_consumers(self):
        launcher = self.read("scripts/build-launcher-badge-provider")
        browser = self.read("scripts/install-browser-profile-provider")
        self.assertIn('install_dir="$data_home/dockrail/providers"', launcher)
        self.assertIn('install_dir="$data_home/dockrail/providers"', browser)
        self.assertIn("smartdock-launcher-badge-provider", launcher)
        self.assertIn("smartdock-browser-profile-provider", browser)

if __name__ == "__main__":
    unittest.main()
