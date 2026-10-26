"""T3 widget package protection: t3.threads reuses the existing fixtures."""
import importlib.util
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tests"))

MODULE = ROOT / "scripts/smartdock_widget.py"
SPEC = importlib.util.spec_from_file_location("smartdock_widget_t3", MODULE)
widget = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(widget)

from test_widget_packages import make_package


class T3WidgetPackagesTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.base = Path(self.temp.name)
        self.home = self.base / "home"
        self.data = self.base / "data"
        self.config = self.base / "config"
        for path in (self.home, self.data, self.config):
            path.mkdir(parents=True, exist_ok=True)
        self.store = widget.Store(
            bundle=ROOT,
            home=self.home,
            data_home=self.data,
            config_home=self.config,
            qml_import_paths=[ROOT / "tests/qml-imports"],
        )

    def tearDown(self):
        self.temp.cleanup()

    def test_install_rejects_t3_threads_as_protected(self):
        protected = make_package(self.base / "protected", "t3.threads")
        with self.assertRaises(widget.WidgetError) as caught:
            self.store.install(str(protected))
        self.assertEqual(caught.exception.code, "E_PROTECTED")

    def test_herdr_agents_stays_protected(self):
        protected = make_package(self.base / "protected-herdr", "herdr.agents")
        with self.assertRaises(widget.WidgetError) as caught:
            self.store.install(str(protected))
        self.assertEqual(caught.exception.code, "E_PROTECTED")


if __name__ == "__main__":
    unittest.main()
