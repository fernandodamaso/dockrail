"""FDM-1068: Dockrail-managed custom icon storage (ingest/migrate/prune)."""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts"))
import dockrail_icons as icons  # noqa: E402


class StoreTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="dockrail icons ")
        self.addCleanup(self.temp.cleanup)
        self.tmp = Path(self.temp.name)
        self.data = self.tmp / "data"
        self.root = self.data / "dockrail"
        self.env = dict(os.environ, HOME=str(self.tmp / "home"),
                        XDG_DATA_HOME=str(self.data))

    def source(self, name="art.svg", content=b"<svg/>"):
        target = self.tmp / "user files" / name
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(content)
        return target

    def managed_dir(self):
        return self.root / "icons"

    def test_source_normalization_matches_qml_validators(self):
        encoded = "file:///tmp/My%20Icons/%C3%8Dcone%20%231%25.svg"
        self.assertEqual(icons.normalize_source("/tmp/My Icons/Ícone #1%.svg"), encoded)
        self.assertEqual(icons.normalize_source(encoded), encoded)
        self.assertEqual(icons.normalize_source("/tmp/What?%23.PNG"),
                         "file:///tmp/What%3F%2523.PNG")
        self.assertEqual(icons.local_file_url("file://localhost/tmp/a.svg"),
                         "file:///tmp/a.svg")
        self.assertEqual(icons.local_file_url("/tmp/a.xpm"), "file:///tmp/a.xpm")
        self.assertEqual(icons.local_file_url("/tmp/a/../b.svg"), "file:///tmp/b.svg")
        for value in ("", "relative.svg", "~/a.svg", "https://a/a.svg",
                      "qrc:/a.svg", "file://server/a.svg", "file:relative.svg",
                      "file:///tmp/a%ZZ.svg", "file:///tmp/a.svg?query",
                      "/tmp/a.gif", "/tmp/a.svg\0", None, 12, {}):
            self.assertEqual(icons.normalize_source(value), "", repr(value))

    def test_ingest_copies_and_never_touches_the_original(self):
        original = self.source("My Sun.svg", b"<svg>sun</svg>")
        url = icons.ingest_source(str(original), key="com.example.Sun",
                                  data_root=self.root)
        name = url.rsplit("/", 1)[-1]
        self.assertRegex(name, r"^com\.example\.Sun-[0-9a-f]{12}\.svg$")
        managed = self.managed_dir() / name
        self.assertEqual(managed.read_bytes(), b"<svg>sun</svg>")
        self.assertTrue(original.exists())
        self.assertEqual(original.read_bytes(), b"<svg>sun</svg>")
        self.assertEqual(url, icons.local_file_url(str(managed)))
        self.assertTrue(icons.is_managed_source(url, self.root))

    def test_ingest_is_idempotent_per_key(self):
        first = self.source("a.png", b"same bytes")
        second = self.tmp / "user files" / "b.png"
        second.write_bytes(b"same bytes")
        first_url = icons.ingest_source(str(first), key="one", data_root=self.root)
        second_url = icons.ingest_source(str(second), key="two", data_root=self.root)
        # Distinct keys own distinct assets even for identical content; each
        # override's cleanup stays independent.
        self.assertNotEqual(first_url, second_url)
        self.assertEqual(len(list(self.managed_dir().iterdir())), 2)
        again = icons.ingest_source(str(first), key="one", data_root=self.root)
        self.assertEqual(again, first_url)
        self.assertEqual(len(list(self.managed_dir().iterdir())), 2)
        # A source already in managed storage passes through unchanged.
        managed = icons.ingest_source(first_url, key="one", data_root=self.root)
        self.assertEqual(managed, first_url)

    def test_ingest_rejects_invalid_input_without_side_effects(self):
        bad = self.tmp / "user files" / "note.txt"
        bad.parent.mkdir(parents=True, exist_ok=True)
        bad.write_text("hi", encoding="utf-8")
        for value in ("https://example.com/a.svg", str(bad),
                      str(self.tmp / "missing.svg"), str(bad.parent)):
            with self.assertRaises(icons.IconStoreError, msg=value):
                icons.ingest_source(value, data_root=self.root)
        self.assertFalse(self.managed_dir().exists())

    def test_migrate_copies_existing_and_keeps_missing_sources(self):
        present = self.source("present.png", b"png bytes")
        settings = {
            "iconOverrides": {
                "org.present": str(present),
                "org.missing": "/nonexistent/art.svg",
            },
            "windowIconOverrides": [
                {"appId": "org.ghostty", "titlePattern": "*solar*",
                 "source": str(present)},
                {"appId": "org.ghostty", "titlePattern": "*gone*",
                 "source": "/nonexistent/gone.png"},
            ],
            "unrelated": {"keep": True},
        }
        migrated, changed = icons.migrate_settings(settings, data_root=self.root)
        managed = icons.ingest_source(str(present), key="org.present",
                                      data_root=self.root)
        self.assertEqual(migrated["iconOverrides"]["org.present"], managed)
        self.assertEqual(migrated["iconOverrides"]["org.missing"],
                         "/nonexistent/art.svg")
        self.assertEqual(migrated["windowIconOverrides"][0]["source"], managed)
        self.assertEqual(migrated["windowIconOverrides"][1]["source"],
                         "/nonexistent/gone.png")
        self.assertEqual(migrated["unrelated"], {"keep": True})
        self.assertEqual(len(changed), 2)
        # The source files are never deleted by migration.
        self.assertTrue(present.exists())
        # Re-migration is a no-op once everything managed exists.
        again, changed_again = icons.migrate_settings(migrated, data_root=self.root)
        self.assertEqual(changed_again, [])
        self.assertEqual(again, migrated)

    def test_migrate_skips_malformed_and_managed_entries(self):
        managed = self.source("m.svg", b"managed")
        managed_url = icons.ingest_source(str(managed), key="m", data_root=self.root)
        settings = {"iconOverrides": {
            "ok": managed_url,
            "bad": "not-a-path",
            "null": None,
        }}
        migrated, changed = icons.migrate_settings(settings, data_root=self.root)
        self.assertEqual(migrated, settings)
        self.assertEqual(changed, [])

    def test_prune_removes_only_unreferenced_owned_assets(self):
        keep_source = self.source("keep.svg", b"keep")
        drop_source = self.source("drop.png", b"drop")
        keep_url = icons.ingest_source(str(keep_source), key="keep",
                                       data_root=self.root)
        drop_url = icons.ingest_source(str(drop_source), key="drop",
                                       data_root=self.root)
        foreign = self.managed_dir() / "user-placed-art.png"
        foreign.write_bytes(b"not ours")
        outside = self.tmp / "outside.svg"
        outside.write_bytes(b"outside")
        settings = {"iconOverrides": {"app": keep_url}}
        removed = icons.prune_orphans(settings, data_root=self.root)
        self.assertEqual(removed, [drop_url.rsplit("/", 1)[-1]])
        self.assertTrue((self.managed_dir() / keep_url.rsplit("/", 1)[-1]).exists())
        self.assertTrue(foreign.exists())
        self.assertTrue(outside.exists())
        self.assertTrue(keep_source.exists())

    def test_prune_keeps_assets_shared_across_overrides(self):
        shared_source = self.source("shared.png", b"shared")
        shared = icons.ingest_source(str(shared_source), key="shared",
                                     data_root=self.root)
        settings = {"iconOverrides": {"one": shared, "two": shared}}
        self.assertEqual(icons.prune_orphans(settings, data_root=self.root), [])
        lone = settings["iconOverrides"].pop("one")
        self.assertEqual(icons.prune_orphans(settings, data_root=self.root), [])
        settings["iconOverrides"].pop("two")
        self.assertEqual(icons.prune_orphans(settings, data_root=self.root),
                         [lone.rsplit("/", 1)[-1]])

    def test_prune_never_follows_symlinks(self):
        target = self.source("real.png", b"real")
        self.managed_dir().mkdir(parents=True, exist_ok=True)
        link = self.managed_dir() / "rogue-0123456789ab.png"
        link.symlink_to(target)
        removed = icons.prune_orphans({"iconOverrides": {}}, data_root=self.root)
        self.assertEqual(removed, [])
        self.assertTrue(link.is_symlink())

    def test_ownership_predicate(self):
        self.assertTrue(icons.is_managed_file_name("ghostty-0123456789ab.svg"))
        self.assertFalse(icons.is_managed_file_name("ghostty-0123456789ab.svg.bak"))
        self.assertFalse(icons.is_managed_file_name("0123456789ab.svg"))
        self.assertFalse(icons.is_managed_file_name("a-0123456789ab.jpeg"))
        self.assertFalse(icons.is_managed_file_name(None))

    def test_cli_json_lines_and_exit_codes(self):
        original = self.source("cli.svg", b"<svg>cli</svg>")
        helper = ROOT / "scripts" / "dockrail_icons.py"
        base = [sys.executable, "-B", str(helper)]

        def run(*args):
            return subprocess.run(base + list(args), env=self.env,
                                  capture_output=True, text=True, timeout=10)

        result = run("ingest", "--source", str(original), "--key", "cli")
        self.assertEqual(result.returncode, 0, result.stderr)
        reply = json.loads(result.stdout.strip().splitlines()[-1])
        self.assertTrue(reply["ok"])
        self.assertTrue(icons.is_managed_source(reply["data"]["source"], self.root))
        ingest_name = reply["data"]["source"].rsplit("/", 1)[-1]

        result = run("ingest", "--source", "https://example.com/a.svg")
        self.assertEqual(result.returncode, 2)
        self.assertFalse(json.loads(result.stdout.strip())["ok"])

        config = self.tmp / "dock.json"
        config.write_text(json.dumps({"iconOverrides": {"a": str(original)}}),
                          encoding="utf-8")
        result = run("migrate", "--config", str(config))
        self.assertEqual(result.returncode, 0, result.stderr)
        reply = json.loads(result.stdout.strip())
        self.assertEqual(len(reply["data"]["changed"]), 1)

        migrate_name = reply["data"]["changed"][0]["to"].rsplit("/", 1)[-1]
        # The early ingest left one unreferenced asset; the migrate copy is kept.
        result = run("prune", "--keep", migrate_name)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout.strip())["data"]["removed"],
                         [ingest_name])

        result = run("prune", "--keep")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout.strip())["data"]["removed"],
                         [migrate_name])


if __name__ == "__main__":
    unittest.main()
