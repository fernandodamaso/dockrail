import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
MODULE = ROOT / "scripts/smartdock_widget.py"
QMLFORMAT = shutil.which("qmlformat") or ("/usr/lib/qt6/bin/qmlformat" if Path("/usr/lib/qt6/bin/qmlformat").is_file() else None)
QMLLINT = shutil.which("qmllint") or ("/usr/lib/qt6/bin/qmllint" if Path("/usr/lib/qt6/bin/qmllint").is_file() else None)
QMLTESTRUNNER = shutil.which("qmltestrunner") or ("/usr/lib/qt6/bin/qmltestrunner" if Path("/usr/lib/qt6/bin/qmltestrunner").is_file() else None)
SPEC = importlib.util.spec_from_file_location("smartdock_widget", MODULE)
widget = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(widget)


def make_package(root, widget_id="io.example.weather", version="0.1.0", name="Weather"):
    root.mkdir(parents=True, exist_ok=True)
    (root / "widget.json").write_text(json.dumps({
        "apiVersion": 1,
        "id": widget_id,
        "name": name,
        "version": version,
        "entry": "Widget.qml",
        "icon": "cloud",
    }) + "\n", encoding="utf-8")
    (root / "Widget.qml").write_text("import QtQuick\nItem { property var widgetContext: ({}) }\n", encoding="utf-8")
    return root


class WidgetPackagesTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.base = Path(self.temp.name)
        self.home = self.base / "home"
        self.data = self.base / "data"
        self.config = self.base / "config"
        self.bundle = ROOT
        for path in (self.home, self.data, self.config):
            path.mkdir(parents=True, exist_ok=True)
        self.store = widget.Store(
            bundle=self.bundle,
            home=self.home,
            data_home=self.data,
            config_home=self.config,
            qml_import_paths=[ROOT / "tests/qml-imports"],
        )

    def tearDown(self):
        self.temp.cleanup()

    def test_new_packages_use_canonical_root_even_with_legacy_state(self):
        legacy = self.data / "smartdock/widgets"
        legacy.mkdir(parents=True)
        (legacy / ".package.lock").touch()
        store = widget.Store(bundle=ROOT, home=self.home, data_home=self.data,
                             config_home=self.config)
        self.assertEqual(store.root, self.data / "dockrail/widgets")
        self.assertTrue((legacy / ".package.lock").exists())

    def test_manifest_validation(self):
        source = make_package(self.base / "source")
        manifest = widget.validate_manifest(source)
        self.assertEqual(manifest["id"], "io.example.weather")
        self.assertEqual(manifest["apiVersion"], 1)
        bad = make_package(self.base / "bad", "Bad ID")
        with self.assertRaises(widget.WidgetError) as caught:
            widget.validate_manifest(bad)
        self.assertEqual(caught.exception.code, "E_VALIDATION")
        incompatible = make_package(self.base / "incompatible", "io.example.future")
        value = json.loads((incompatible / "widget.json").read_text())
        value["apiVersion"] = 2
        (incompatible / "widget.json").write_text(json.dumps(value))
        with self.assertRaises(widget.WidgetError) as caught:
            widget.validate_manifest(incompatible)
        self.assertEqual(caught.exception.code, "E_INCOMPATIBLE")
        missing = make_package(self.base / "missing", "io.example.missing")
        (missing / "Widget.qml").unlink()
        with self.assertRaises(widget.WidgetError):
            widget.validate_manifest(missing)

    def test_entry_cannot_escape_package(self):
        source = make_package(self.base / "source")
        outside = self.base / "Outside.qml"
        outside.write_text("import QtQuick\nItem {}\n")
        value = json.loads((source / "widget.json").read_text())
        value["entry"] = "../Outside.qml"
        (source / "widget.json").write_text(json.dumps(value))
        with self.assertRaises(widget.WidgetError):
            widget.validate_manifest(source)

    def test_forbidden_source_locations_direct_nested_and_symlink(self):
        plugin = self.home / ".config/omarchy/plugins" / widget.PLUGIN_ID
        plugin.mkdir(parents=True)
        with self.assertRaises(widget.WidgetError) as caught:
            self.store.source_preflight(plugin)
        self.assertEqual(caught.exception.code, "E_SOURCE_FORBIDDEN")
        with self.assertRaises(widget.WidgetError):
            self.store.source_preflight(plugin / "nested/widget")
        link = self.base / "plugin-link"
        link.symlink_to(plugin, target_is_directory=True)
        with self.assertRaises(widget.WidgetError):
            self.store.source_preflight(link / "nested")
        valid = self.base / "external/widget"
        self.assertEqual(self.store.source_preflight(valid), valid.parent.resolve() / valid.name)

    def test_source_in_core_or_standalone_bundle_is_forbidden(self):
        with self.assertRaises(widget.WidgetError):
            self.store.source_preflight(self.bundle / "custom")
        for root_name in ("dockrail", "smartdock"):
            with self.subTest(root_name=root_name):
                standalone = self.data / root_name / "custom-source"
                with self.assertRaises(widget.WidgetError):
                    self.store.source_preflight(standalone)

    def test_create_scaffold_is_external_and_uses_widgetkit(self):
        result = self.store.create("io.example.scaffold", "My Widget")
        source = Path(result["sourcePath"])
        self.assertTrue(source.is_dir())
        self.assertFalse(source.is_relative_to(self.bundle))
        self.assertFalse(source.is_relative_to(self.home / ".config/omarchy/plugins" / widget.PLUGIN_ID))
        self.assertEqual(widget.validate_manifest(source)["id"], "io.example.scaffold")
        qml = (source / "Widget.qml").read_text()
        self.assertIn("import Dockrail.WidgetKit 1.0", qml)
        readme = (source / "README.md").read_text()
        self.assertIn("WIDGET_COMPONENTS.md", readme)
        self.assertIn("WIDGET_PACKAGES.md", readme)

    def test_install_list_registry_and_remove(self):
        source = make_package(self.base / "source")
        installed = self.store.install(str(source))
        self.assertEqual(installed["id"], "io.example.weather")
        target = self.store.root / "io.example.weather"
        self.assertTrue(target.is_dir())
        self.assertFalse(target.is_symlink())
        registry = json.loads(self.store.registry_path.read_text())
        self.assertEqual([row["id"] for row in registry["packages"]], ["io.example.weather"])
        self.assertTrue(registry["packages"][0]["entryPath"].endswith("/Widget.qml"))
        rows, errors, _ = self.store.list_rows()
        external = next(row for row in rows if row["id"] == "io.example.weather")
        self.assertEqual(external["ownership"], "external")
        self.assertFalse(external["enabled"])
        self.assertEqual(errors, [])
        result = self.store.remove("io.example.weather")
        self.assertTrue(result["removed"])
        self.assertTrue(source.is_dir(), "remove must preserve developer source")
        registry = json.loads(self.store.registry_path.read_text())
        self.assertEqual(registry["packages"], [])

    def test_install_rejects_duplicate_and_protected(self):
        source = make_package(self.base / "source")
        self.store.install(str(source))
        with self.assertRaises(widget.WidgetError) as caught:
            self.store.install(str(source))
        self.assertEqual(caught.exception.code, "E_CONFLICT")
        protected = make_package(self.base / "protected", "herdr.agents")
        with self.assertRaises(widget.WidgetError) as caught:
            self.store.install(str(protected))
        self.assertEqual(caught.exception.code, "E_PROTECTED")

    def test_invalid_install_never_creates_target(self):
        source = make_package(self.base / "source", "io.example.invalid")
        (source / "Widget.qml").unlink()
        with self.assertRaises(widget.WidgetError):
            self.store.install(str(source))
        self.assertFalse((self.store.root / "io.example.invalid").exists())

    def test_update_is_atomic_and_preserves_previous_on_invalid_candidate(self):
        source = make_package(self.base / "source", version="0.1.0")
        self.store.install(str(source))
        before = (self.store.root / "io.example.weather/widget.json").read_text()
        value = json.loads((source / "widget.json").read_text())
        value["version"] = "0.2.0"
        value["entry"] = "Missing.qml"
        (source / "widget.json").write_text(json.dumps(value))
        with self.assertRaises(widget.WidgetError):
            self.store.update("io.example.weather")
        self.assertEqual((self.store.root / "io.example.weather/widget.json").read_text(), before)
        registry = json.loads(self.store.registry_path.read_text())
        self.assertEqual(registry["packages"][0]["version"], "0.1.0")

    def test_update_all_continues_after_one_broken_source(self):
        a = make_package(self.base / "a", "io.example.a", "0.1.0", "A")
        b = make_package(self.base / "b", "io.example.b", "0.1.0", "B")
        self.store.install(str(a))
        self.store.install(str(b))
        av = json.loads((a / "widget.json").read_text())
        av["entry"] = "Missing.qml"
        (a / "widget.json").write_text(json.dumps(av))
        bv = json.loads((b / "widget.json").read_text())
        bv["version"] = "0.2.0"
        (b / "widget.json").write_text(json.dumps(bv))
        result = self.store.update()
        self.assertEqual(result["failed"], 1)
        installed_b = json.loads((self.store.root / "io.example.b/widget.json").read_text())
        self.assertEqual(installed_b["version"], "0.2.0")
        installed_a = json.loads((self.store.root / "io.example.a/widget.json").read_text())
        self.assertEqual(installed_a["version"], "0.1.0")

    def test_invalid_package_isolated_from_valid_registry_package(self):
        valid = make_package(self.base / "valid", "io.example.valid")
        self.store.install(str(valid))
        broken_dir = self.store.root / "io.example.broken"
        make_package(broken_dir, "io.example.broken")
        (broken_dir / "Widget.qml").unlink()
        registry = self.store.rebuild_registry()
        self.assertEqual([row["id"] for row in registry["packages"]], ["io.example.valid"])
        self.assertTrue(any(row.get("id") == "io.example.broken" for row in registry["errors"]))

    def test_registry_is_bounded_without_disabling_earlier_valid_packages(self):
        for index in range(widget.MAX_REGISTRY_PACKAGES + 1):
            widget_id = f"io.example.bound{index}"
            make_package(self.store.root / widget_id, widget_id)
        registry = self.store.rebuild_registry()
        self.assertEqual(len(registry["packages"]), widget.MAX_REGISTRY_PACKAGES)
        self.assertEqual(registry["packages"][0]["id"], "io.example.bound0")
        self.assertTrue(any("registry limit" in row.get("error", "") for row in registry["errors"]))

    def test_enabled_remove_is_refused_without_rewriting_config(self):
        source = make_package(self.base / "source")
        self.store.install(str(source))
        self.store.config_path.parent.mkdir(parents=True, exist_ok=True)
        original = json.dumps({"sidebarWidgets": ["io.example.weather"], "unknown": {"keep": True}}, indent=2) + "\n"
        self.store.config_path.write_text(original)
        with self.assertRaises(widget.WidgetError) as caught:
            self.store.remove("io.example.weather")
        self.assertEqual(caught.exception.code, "E_ENABLED")
        self.assertEqual(self.store.config_path.read_text(), original)
        self.assertTrue((self.store.root / "io.example.weather").is_dir())

    def test_dev_use_reload_and_reset_preserve_source_and_installed_package(self):
        installed_source = make_package(self.base / "installed-source", "io.example.dev", "1.0.0", "Dev")
        dev_source = make_package(self.base / "dev-source", "io.example.dev", "1.1.0", "Dev")
        self.store.install(str(installed_source))
        use = self.store.dev_use(str(dev_source))
        self.assertTrue(use["development"])
        registry = json.loads(self.store.registry_path.read_text())
        self.assertTrue(registry["packages"][0]["development"])
        first_url = registry["packages"][0]["entryRevision"]
        (dev_source / "Widget.qml").write_text("import QtQuick\nItem { property var widgetContext: ({}) ; property string marker: 'two' }\n")
        reload_result = self.store.dev_reload()
        self.assertTrue(reload_result["reloaded"])
        registry = json.loads(self.store.registry_path.read_text())
        self.assertNotEqual(registry["packages"][0]["entryRevision"], first_url)
        reset = self.store.dev_reset()
        self.assertTrue(reset["reset"])
        self.assertTrue(dev_source.is_dir(), "dev reset must never delete developer source")
        registry = json.loads(self.store.registry_path.read_text())
        self.assertFalse(registry["packages"][0]["development"])
        self.assertEqual(registry["packages"][0]["version"], "1.0.0")

    def test_invalid_dev_reload_keeps_last_working_snapshot(self):
        installed_source = make_package(self.base / "installed-source", "io.example.dev", "1.0.0", "Dev")
        dev_source = make_package(self.base / "dev-source", "io.example.dev", "1.1.0", "Dev")
        self.store.install(str(installed_source))
        self.store.dev_use(str(dev_source))
        before_state = json.loads(self.store.dev_state_path.read_text())
        before_registry = self.store.registry_path.read_text()
        (dev_source / "Widget.qml").unlink()
        with self.assertRaises(widget.WidgetError):
            self.store.dev_reload()
        self.assertEqual(json.loads(self.store.dev_state_path.read_text()), before_state)
        self.assertEqual(self.store.registry_path.read_text(), before_registry)
        self.assertTrue(Path(before_state["snapshot"]).is_dir())


    def test_source_cannot_supply_reserved_runtime_widgetkit_directories(self):
        for module_root, module_name in (("Dockrail", "Dockrail.WidgetKit"), ("SmartDock", "SmartDock.WidgetKit")):
            with self.subTest(module_root=module_root):
                source = make_package(self.base / ("source-" + module_root.lower()))
                (source / module_root / "WidgetKit").mkdir(parents=True)
                (source / module_root / "WidgetKit/qmldir").write_text(
                    "module " + module_name + "\n", encoding="utf-8")
                with self.assertRaises(widget.WidgetError) as caught:
                    widget.validate_manifest(source)
                self.assertEqual(caught.exception.code, "E_VALIDATION")

    @unittest.skipUnless(QMLFORMAT and QMLLINT and QMLTESTRUNNER, "Qt QML tools unavailable")
    def test_installed_scaffold_materializes_widgetkit_and_loads_without_global_smartdock_import_path(self):
        created = self.store.create("io.example.scaffold-runtime", "Runtime Scaffold")
        installed = self.store.install(created["sourcePath"])
        package_root = self.store.root / installed["id"]
        qmldir = package_root / "Dockrail/WidgetKit/qmldir"
        self.assertTrue(qmldir.is_file())
        qmldir_text = qmldir.read_text(encoding="utf-8")
        self.assertNotIn("module Dockrail.WidgetKit", qmldir_text)
        self.assertNotIn("../../components/widgets", qmldir_text)
        installed_qml = (package_root / "Widget.qml").read_text(encoding="utf-8")
        self.assertIn('import "./Dockrail/WidgetKit"', installed_qml)
        source_qml = (Path(created["sourcePath"]) / "Widget.qml").read_text(encoding="utf-8")
        self.assertIn("import Dockrail.WidgetKit 1.0", source_qml)

        test_root = self.base / "qml-runtime-test"
        test_root.mkdir()
        entry_url = (package_root / "Widget.qml").as_uri() + "?smartdockRev=deadbeefdeadbeef"
        (test_root / "tst_external_widget_runtime.qml").write_text(
            "import QtQuick\n"
            "import QtTest\n\n"
            "TestCase {\n"
            "  name: \"ExternalWidgetRuntime\"\n"
            "  function test_loadInstalledWidget() {\n"
            f"    var component = Qt.createComponent({json.dumps(entry_url)})\n"
            "    compare(component.status, Component.Ready, component.errorString())\n"
            "    var object = component.createObject(null)\n"
            "    verify(object !== null, component.errorString())\n"
            "    object.destroy()\n"
            "  }\n"
            "}\n",
            encoding="utf-8",
        )
        environment = dict(os.environ)
        environment["QT_QPA_PLATFORM"] = "offscreen"
        result = subprocess.run(
            [
                QMLTESTRUNNER,
                "-input", str(test_root),
                "-import", str(ROOT / "tests/qml-imports"),
            ],
            capture_output=True,
            text=True,
            timeout=30,
            env=environment,
        )
        self.assertEqual(result.returncode, 0, result.stdout + "\n" + result.stderr)

    def test_nested_widgetkit_import_is_rewritten_relative_to_each_qml_file(self):
        source = make_package(self.base / "source", "io.example.nested")
        nested = source / "parts"
        nested.mkdir()
        (nested / "Panel.qml").write_text(
            "import QtQuick\nimport SmartDock.WidgetKit 1.0 as LegacyKit // legacy alias\n"
            "import Dockrail.WidgetKit 1.0 as Kit // canonical alias\nItem {}\n",
            encoding="utf-8",
        )
        runtime = self.base / "runtime"
        widget.copy_package(source, runtime)
        self.store._materialize_widgetkit(runtime)
        self.store._rewrite_widgetkit_imports(runtime)
        runtime_qml = (runtime / "parts/Panel.qml").read_text(encoding="utf-8")
        self.assertIn(
            'import "../Dockrail/WidgetKit" as LegacyKit // legacy alias',
            runtime_qml,
        )
        self.assertIn(
            'import "../Dockrail/WidgetKit" as Kit // canonical alias',
            runtime_qml,
        )
        source_qml = (nested / "Panel.qml").read_text(encoding="utf-8")
        self.assertIn("import SmartDock.WidgetKit 1.0 as LegacyKit // legacy alias", source_qml)
        self.assertIn("import Dockrail.WidgetKit 1.0 as Kit // canonical alias", source_qml)


    def test_legacy_installed_snapshot_remains_valid_without_rewrite(self):
        package = make_package(self.store.root / "io.example.legacy", "io.example.legacy")
        runtime = package / "SmartDock/WidgetKit"
        runtime.mkdir(parents=True)
        (runtime / "qmldir").write_text("WidgetText 1.0 WidgetText.qml\n", encoding="utf-8")
        (runtime / "WidgetText.qml").write_text("import QtQuick\nText {}\n", encoding="utf-8")
        (package / "Widget.qml").write_text(
            'import QtQuick\nimport "./SmartDock/WidgetKit"\n'
            'Item { property var widgetContext: ({}) }\n',
            encoding="utf-8",
        )
        metadata = {
            "schemaVersion": widget.STATE_SCHEMA_VERSION,
            "type": "local",
            "location": str(self.base / "legacy-source"),
        }
        (package / ".smartdock-source.json").write_text(json.dumps(metadata) + "\n", encoding="utf-8")
        manifest = widget.validate_manifest(package, allow_runtime_widgetkit=True)
        self.assertEqual(manifest["id"], "io.example.legacy")
        before = (package / "Widget.qml").read_bytes()
        registry = self.store.rebuild_registry()
        self.assertEqual([row["id"] for row in registry["packages"]], ["io.example.legacy"])
        self.assertEqual((package / "Widget.qml").read_bytes(), before)
        self.assertTrue((package / "SmartDock/WidgetKit/qmldir").is_file())
        self.assertFalse((package / "Dockrail").exists())

    @unittest.skipUnless(QMLTESTRUNNER, "qmltestrunner unavailable")
    def test_both_named_widgetkit_modules_load_from_source_bundle(self):
        test_root = self.base / "named-module-test"
        test_root.mkdir()
        (test_root / "tst_widgetkit_names.qml").write_text(
            "import QtQuick\n"
            "import QtTest\n"
            "import SmartDock.WidgetKit 1.0 as LegacyKit\n"
            "import Dockrail.WidgetKit 1.0 as DockrailKit\n\n"
            "TestCase {\n"
            "  name: \"WidgetKitNames\"\n"
            "  function test_bothModulesInstantiate() {\n"
            "    var a = Qt.createQmlObject('import QtQuick; import SmartDock.WidgetKit 1.0; WidgetText { text: \"legacy\" }', this)\n"
            "    var b = Qt.createQmlObject('import QtQuick; import Dockrail.WidgetKit 1.0; WidgetText { text: \"canonical\" }', this)\n"
            "    verify(a !== null)\n"
            "    verify(b !== null)\n"
            "    a.destroy()\n"
            "    b.destroy()\n"
            "  }\n"
            "}\n",
            encoding="utf-8",
        )
        environment = dict(os.environ)
        environment["QT_QPA_PLATFORM"] = "offscreen"
        result = subprocess.run(
            [QMLTESTRUNNER, "-input", str(test_root), "-import", str(ROOT),
             "-import", str(ROOT / "tests/qml-imports")],
            capture_output=True, text=True, timeout=30, env=environment,
        )
        self.assertEqual(result.returncode, 0, result.stdout + "\n" + result.stderr)

    @unittest.skipUnless(QMLFORMAT, "qmlformat unavailable")
    def test_invalid_dev_reload_qml_syntax_keeps_last_working_snapshot(self):
        installed_source = make_package(self.base / "installed-source", "io.example.syntax", "1.0.0", "Syntax")
        dev_source = make_package(self.base / "dev-source", "io.example.syntax", "1.1.0", "Syntax")
        self.store.install(str(installed_source))
        self.store.dev_use(str(dev_source))
        before_state = json.loads(self.store.dev_state_path.read_text())
        before_registry = self.store.registry_path.read_text()
        (dev_source / "Widget.qml").write_text("import QtQuick\nItem {\n", encoding="utf-8")
        with self.assertRaises(widget.WidgetError) as caught:
            self.store.dev_reload()
        self.assertEqual(caught.exception.code, "E_VALIDATION")
        self.assertEqual(json.loads(self.store.dev_state_path.read_text()), before_state)
        self.assertEqual(self.store.registry_path.read_text(), before_registry)
        self.assertTrue(Path(before_state["snapshot"]).is_dir())

    @unittest.skipUnless(QMLLINT, "qmllint unavailable")
    def test_invalid_dev_reload_unresolved_import_keeps_last_working_snapshot(self):
        installed_source = make_package(self.base / "installed-source", "io.example.imports", "1.0.0", "Imports")
        dev_source = make_package(self.base / "dev-source", "io.example.imports", "1.1.0", "Imports")
        self.store.install(str(installed_source))
        self.store.dev_use(str(dev_source))
        before_state = json.loads(self.store.dev_state_path.read_text())
        before_registry = self.store.registry_path.read_text()
        (dev_source / "Widget.qml").write_text(
            "import QtQuick\nimport DefinitelyMissing.Module 1.0\nItem { property var widgetContext: ({}) }\n",
            encoding="utf-8",
        )
        with self.assertRaises(widget.WidgetError) as caught:
            self.store.dev_reload()
        self.assertEqual(caught.exception.code, "E_VALIDATION")
        self.assertEqual(json.loads(self.store.dev_state_path.read_text()), before_state)
        self.assertEqual(self.store.registry_path.read_text(), before_registry)
        self.assertTrue(Path(before_state["snapshot"]).is_dir())

    def test_symlinked_installed_package_is_isolated_from_registry_and_bulk_update(self):
        valid = make_package(self.base / "valid", "io.example.valid")
        self.store.install(str(valid))
        outside = make_package(self.base / "outside", "io.example.link")
        link = self.store.root / "io.example.link"
        link.symlink_to(outside, target_is_directory=True)

        registry = self.store.rebuild_registry()
        self.assertEqual([row["id"] for row in registry["packages"]], ["io.example.valid"])
        self.assertTrue(any(row.get("id") == "io.example.link" and "symlink" in row.get("error", "")
                            for row in registry["errors"]))

        result = self.store.update()
        self.assertEqual(result["failed"], 1)
        self.assertTrue(any(row["id"] == "io.example.valid" and row["ok"] for row in result["results"]))
        self.assertTrue(any(row["id"] == "io.example.link" and not row["ok"] for row in result["results"]))

    def test_herdr_list_row_is_source_owned_and_not_manageable(self):
        rows, _, _ = self.store.list_rows()
        herdr = next(row for row in rows if row["id"] == "herdr.agents")
        self.assertEqual(herdr["ownership"], "integration")
        self.assertFalse(herdr["manageable"])

    def test_package_manager_never_writes_qml_paths_to_dock_config(self):
        source = make_package(self.base / "source")
        self.store.config_path.parent.mkdir(parents=True, exist_ok=True)
        original = '{"sidebarWidgets":["io.example.weather"],"keep":7}\n'
        self.store.config_path.write_text(original)
        self.store.install(str(source))
        self.assertEqual(self.store.config_path.read_text(), original)
        registry = json.loads(self.store.registry_path.read_text())
        self.assertIn("entryPath", registry["packages"][0])
        self.assertNotIn("entryPath", json.loads(original))


if __name__ == "__main__":
    unittest.main()
