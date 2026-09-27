"""FDM-948 documentation contract for inline monitor sections."""
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]


class MonitorSectionDocsTests(unittest.TestCase):
    def test_readme_and_inventory_describe_rendered_monitor_sections(self):
        readme = (ROOT / "README.md").read_text(encoding="utf-8")
        inventory = (ROOT / "docs" / "CONFIGURATION.md").read_text(encoding="utf-8")
        combined = readme + "\n" + inventory

        for phrase in [
            "Monitor N",
            "current-monitor",
            "globally focused monitor",
            "Other windows",
            "workspace-monitor pin enforcement hooks",
            "current workspace header has no pin menu",
            "Plain app-icon activation already focuses in place",
        ]:
            self.assertIn(phrase, combined)

        self.assertIn("not a workspace-drop target", readme)
        self.assertIn("actual `DockWorkspaceGroup` card", inventory)
        self.assertIn("single horizontal workspace viewport", inventory)
        self.assertIn("first present workspace card", inventory)
        self.assertIn("unique primary workspace", inventory)
        self.assertIn("pulls it onto the clicked dock monitor", inventory)
        self.assertIn("moves just that window", inventory)

    def test_internal_tracking_stays_in_the_developer_reference(self):
        reference = (ROOT / "docs" / "SIDEBAR.md").read_text(encoding="utf-8")
        for issue in ("FDM-942", "FDM-943", "FDM-949"):
            self.assertIn(issue, reference)


if __name__ == "__main__":
    unittest.main()
