# SPDX-License-Identifier: Apache-2.0
"""Tests for provider/t3/t3paths.py connection-file path resolution."""
from __future__ import annotations

import os
import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))

import t3paths


class ConnectionPathTests(unittest.TestCase):
    def test_default_home(self) -> None:
        path = t3paths.connection_path({"HOME": "/home/someone"})
        self.assertEqual(
            path, Path("/home/someone/.local/share/dockrail/t3/connection.json")
        )

    def test_custom_xdg_data_home(self) -> None:
        path = t3paths.connection_path(
            {"HOME": "/home/someone", "XDG_DATA_HOME": "/data/xdg"}
        )
        self.assertEqual(path, Path("/data/xdg/dockrail/t3/connection.json"))

    def test_empty_xdg_data_home_falls_back(self) -> None:
        path = t3paths.connection_path({"HOME": "/home/someone", "XDG_DATA_HOME": ""})
        self.assertEqual(
            path, Path("/home/someone/.local/share/dockrail/t3/connection.json")
        )

    def test_default_environment(self) -> None:
        path = t3paths.connection_path()
        self.assertTrue(str(path).endswith("dockrail/t3/connection.json"))
        home = Path(os.environ.get("HOME") or str(Path.home()))
        xdg = os.environ.get("XDG_DATA_HOME", "")
        base = Path(xdg).expanduser() if xdg else home / ".local" / "share"
        self.assertEqual(path, base / "dockrail" / "t3" / "connection.json")


if __name__ == "__main__":
    unittest.main()
