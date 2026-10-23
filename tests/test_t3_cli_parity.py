import os
import sys
import unittest
from pathlib import Path
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts"))
sys.path.insert(0, str(ROOT / "provider" / "t3"))

import dockrail_t3
import t3paths
from dockrail_t3 import (
    check_endpoint as cli_check_endpoint,
    iso_to_epoch,
    listener_records as cli_listener_records,
    validated_expires_in,
)
from t3http import Failure, check_endpoint
from t3procfs import ProcfsError, listener_records


class PathParityTests(unittest.TestCase):
    VARIANTS = [
        {"HOME": "/home/someone"},
        {"HOME": "/home/someone", "XDG_DATA_HOME": "/data/xdg"},
        {"HOME": "/home/someone", "XDG_DATA_HOME": ""},
    ]

    def test_cli_and_provider_resolve_same_path(self) -> None:
        for env in self.VARIANTS:
            with self.subTest(env=env):
                with patch.dict(os.environ, env, clear=True):
                    self.assertEqual(dockrail_t3.connection_path(), t3paths.connection_path())


class EndpointParityTests(unittest.TestCase):
    URLS = [
        "http://127.0.0.1:3773",
        "http://127.0.0.1:3773/",
        "http://127.0.0.1:1",
        "http://127.0.0.1:65535",
        "http://[::1]:3773",
        "http://127.0.0.1",
        "http://127.0.0.1:0",
        "https://127.0.0.1:3773",
        "http://localhost:3773",
        "http://127.0.0.1:3773/extra",
    ]

    def test_endpoint_checks_agree(self) -> None:
        self.assertEqual(len(self.URLS), 10)
        for url in self.URLS:
            with self.subTest(url=url):
                try:
                    provider_result: object = check_endpoint(url)
                    provider_ok = True
                except Failure:
                    provider_ok = False
                    provider_result = None
                try:
                    cli_result: object = dockrail_t3.check_endpoint(url)
                    cli_ok = True
                except dockrail_t3.CliError:
                    cli_ok = False
                    cli_result = None
                self.assertEqual(provider_ok, cli_ok)
                if provider_ok:
                    self.assertEqual(provider_result, cli_result)


class ListenerParityTests(unittest.TestCase):
    def setUp(self) -> None:
        import tempfile

        self.root = Path(tempfile.mkdtemp())
        self.addCleanup(
            lambda: __import__("shutil").rmtree(self.root, ignore_errors=True)
        )
        net = self.root / "net"
        net.mkdir()
        header = ("  sl  local_address rem_address   st tx_queue rx_queue tr tm->when"
                  " retrnsmt   uid  timeout inode\n")
        uid = os.getuid()
        rows = [
            f"   0: 0100007F:0EC9 00000000:0000 0A 00000000:00000000 00:00000000"
            f" 00000000 {uid:>5d}        0 11 1 0000000000000000 100 0 0 10 0\n",
            "   1: 00000000000000000000000001000000:0ECA 00000000000000000000000000000000:0000"
            f" 0A 00000000:00000000 00:00000000 00000000 {uid:>5d}        0 12 1"
            " 0000000000000000 100 0 0 10 0\n",
            f"   2: 0100007F:0EC9 00000000:0000 01 00000000:00000000 00:00000000"
            f" 00000000 {uid:>5d}        0 13 1 0000000000000000 100 0 0 10 0\n",
        ]
        (net / "tcp").write_text(header + rows[0] + rows[2])
        (net / "tcp6").write_text(header + rows[1])

    def test_listener_checks_agree(self) -> None:
        provider_rows = listener_records(3785, self.root)
        cli_rows = cli_listener_records(3785, self.root)
        self.assertEqual(provider_rows, cli_rows)
        provider_rows6 = listener_records(3786, self.root)
        cli_rows6 = cli_listener_records(3786, self.root)
        self.assertEqual(provider_rows6, cli_rows6)
        self.assertEqual(provider_rows, [("socket:[11]", os.getuid())])
        for bad_root in (self.root / "missing",):
            with self.assertRaises(ProcfsError):
                listener_records(3785, bad_root)
            with self.assertRaises(dockrail_t3.CliError):
                cli_listener_records(3785, bad_root)


class ExpiryTests(unittest.TestCase):
    def test_validated_expires_in(self) -> None:
        self.assertEqual(validated_expires_in(2592000), 2592000)
        for bad in (0, -5, True, False, 1.5, "60", None, 2**100):
            with self.subTest(bad=bad):
                with self.assertRaises(dockrail_t3.CliError):
                    validated_expires_in(bad)

    def test_iso_to_epoch(self) -> None:
        self.assertEqual(iso_to_epoch("2026-11-22T17:10:03.963Z"), 1795367403)
        self.assertIsNone(iso_to_epoch("not-a-date"))
        self.assertIsNone(iso_to_epoch(""))
        self.assertIsNone(iso_to_epoch(None))
        self.assertIsNone(iso_to_epoch("1970-01-01T00:00:00Z"))
        self.assertIsNone(iso_to_epoch(12345))


if __name__ == "__main__":
    unittest.main()
