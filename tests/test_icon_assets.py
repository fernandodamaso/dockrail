"""FDM-1068: file-backed, restart-safe icon assets and migration/cleanup."""
import importlib.util
import json
import os
from pathlib import Path
import tempfile
import time
import unittest

MODULE = Path(__file__).resolve().parents[1] / "scripts/dockrail_icon_assets.py"
spec = importlib.util.spec_from_file_location("dockrail_icon_assets", MODULE)
assets = importlib.util.module_from_spec(spec)
spec.loader.exec_module(assets)
SVG = b'<svg xmlns="http://www.w3.org/2000/svg"><rect width="1" height="1"/></svg>'
PNG = b"\x89PNG\r\n\x1a\n" + b"sample-image"


class ManagedIconTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.env = {"HOME": str(self.root / "home"),
                    "XDG_DATA_HOME": str(self.root / "different data root")}
        self.original = self.root / "User artwork.png"
        self.original.write_bytes(PNG)
        self.config = self.root / "dock.json"

    def settings(self, **overrides):
        config = {"pinned": [], "iconOverrides": {}, "windowIconOverrides": []}
        config.update(overrides)
        self.config.write_text(json.dumps(config), encoding="utf-8")
        return config

    def test_ingest_is_persistent_deduplicated_and_non_destructive(self):
        first = assets.ingest(str(self.original), self.env)
        second = assets.ingest(self.original.as_uri(), self.env)
        self.assertEqual(first, second)
        managed = assets.source_path(first)
        self.assertEqual(managed.read_bytes(), PNG)
        self.assertEqual(managed.parent, assets.icon_directory(self.env))
        self.original.unlink()
        self.assertEqual(managed.read_bytes(), PNG)
        self.assertEqual(assets.ingest(first, self.env), first)

    def test_reject_unsupported_missing_and_invalid_without_broken_output(self):
        for source in ("https://server/icon.png", "file://evilhost/tmp/a.svg",
                       "file:///missing/icon.svg", "not-absolute.png",
                       "file:///tmp/a.png?bad"):
            with self.subTest(source=source):
                with self.assertRaises(assets.IconAssetError):
                    assets.ingest(source, self.env)
        invalid = self.root / "bad.png"
        invalid.write_bytes(b"not a PNG")
        with self.assertRaises(assets.IconAssetError):
            assets.ingest(str(invalid), self.env)
        too_big = self.root / "big.svg"
        too_big.write_bytes(SVG + b" " * (assets.MAX_BYTES + 1))
        with self.assertRaises(assets.IconAssetError):
            assets.ingest(str(too_big), self.env)
        entity = self.root / "entity.svg"
        entity.write_bytes(b'<!DOCTYPE svg [<!ENTITY x SYSTEM "file:///etc/passwd">]><svg/>')
        with self.assertRaises(assets.IconAssetError):
            assets.ingest(str(entity), self.env)
        self.assertEqual(list(assets.icon_directory(self.env).glob("*.png")), [])

    def test_migrate_preserves_order_unknown_keys_and_missing_sources(self):
        existing = self.root / "legacy.svg"
        existing.write_bytes(SVG)
        old = self.settings(iconOverrides={"a": str(existing),
                                           "lost": "/missing/file.svg"},
            windowIconOverrides=[
                {"appId": "term", "titlePattern": "*a*", "source": existing.as_uri()},
                {"appId": "term", "titlePattern": "*b*", "source": "/missing/a.png"},
            ], unknownExtension={"keep": 7})
        plan = assets.migration(self.config, self.env)
        self.assertEqual(plan["expected"]["iconOverrides"], old["iconOverrides"])
        self.assertEqual(list(plan["patch"]["iconOverrides"]), ["a", "lost"])
        new = plan["patch"]
        self.assertEqual(new["iconOverrides"]["lost"], "/missing/file.svg")
        self.assertEqual(new["windowIconOverrides"][1], old["windowIconOverrides"][1])
        self.assertEqual(new["iconOverrides"]["a"], new["windowIconOverrides"][0]["source"])
        self.assertEqual(json.loads(self.config.read_text()), old,
                         "Migration never writes live configuration")
        existing.unlink()
        self.assertEqual(assets.source_path(new["iconOverrides"]["a"]).read_bytes(), SVG)

    def test_collect_only_unreferenced_owned_aged_assets(self):
        original = assets.ingest(str(self.original), self.env)
        owned = assets.source_path(original)
        second = self.root / "another.png"
        second.write_bytes(PNG + b"other")
        unrelated = assets.source_path(assets.ingest(str(second), self.env))
        self.settings(iconOverrides={"one": original},
                      windowIconOverrides=[{"appId": "w", "titlePattern": "*",
                                            "source": original}])
        then = time.time() + 130
        self.assertEqual(assets.collect(self.config, self.env, now=then),
                         [unrelated.name])
        self.assertTrue(owned.exists(), "Shared asset remains referenced")
        self.settings(iconOverrides={}, windowIconOverrides=[])
        self.assertEqual(assets.collect(self.config, self.env, now=then), [owned.name])
        self.assertTrue(self.original.exists(), "Original user files are never deleted")
        # No config is not permission to delete.
        self.config.unlink()
        with self.assertRaises(FileNotFoundError):
            assets.collect(self.config, self.env)
        self.assertTrue(self.original.exists())

    def test_fresh_assets_are_not_collected_between_copy_and_host_save(self):
        source = assets.ingest(str(self.original), self.env)
        self.settings()
        self.assertEqual(assets.collect(self.config, self.env), [])
        self.assertTrue(assets.source_path(source).exists())

    def test_cli_set_uses_managed_copy_before_host_request(self):
        from types import SimpleNamespace
        from unittest.mock import patch
        script = MODULE.parent / "smartdock_cli.py"
        cli_spec = importlib.util.spec_from_file_location("dockrail_cli_for_icons", script)
        cli = importlib.util.module_from_spec(cli_spec)
        cli_spec.loader.exec_module(cli)
        calls = []

        class Transport:
            def request(self, instance, command, arguments):
                calls.append((command, arguments))
                # A failed host reply still proves the ingester ran before IPC.
                return {"apiVersion": 1, "ok": False,
                        "error": {"code": "E_BUSY", "message": "fixture"}, "data": {},
                        "warnings": []}

        args = SimpleNamespace(group="icons", action="set", id="editor",
                               source=str(self.original), profile=None,
                               title_pattern=None)
        with patch.dict(os.environ, self.env, clear=False):
            reply = cli.app_icon_request(Transport(), object(), args)
        self.assertFalse(reply["ok"])
        self.assertEqual(calls[0][0], "icons.set")
        managed = assets.source_path(calls[0][1]["source"])
        self.assertEqual(managed.read_bytes(), PNG)
        self.assertEqual(managed.parent, assets.icon_directory(self.env))
        calls.clear()
        args.source = str(self.root / "missing.png")
        with patch.dict(os.environ, self.env, clear=False):
            with self.assertRaises(cli.CliError):
                cli.app_icon_request(Transport(), object(), args)
        self.assertFalse(calls, "Failed copy must not reach the host")

    def test_name_traversal_and_symlink_destination_not_deleted(self):
        source = assets.ingest(str(self.original), self.env)
        managed = assets.source_path(source)
        self.settings()
        link = managed.parent / ("f" * 64 + ".png")
        link.symlink_to(self.original)
        self.assertEqual(assets.collect(self.config, self.env, now=time.time() + 1000),
                         [managed.name])
        self.assertTrue(link.is_symlink())
        self.assertTrue(self.original.exists())


if __name__ == "__main__":
    unittest.main()
