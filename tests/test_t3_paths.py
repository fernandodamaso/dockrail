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


class T3PathsTests(unittest.TestCase):
    VARIANTS = [
        ({"HOME": "/home/someone"}, "/home/someone/.local/share"),
        ({"HOME": "/home/someone", "XDG_DATA_HOME": "/data/xdg"}, "/data/xdg"),
        ({"HOME": "/home/someone", "XDG_DATA_HOME": ""}, "/home/someone/.local/share"),
    ]

    def test_cli_and_provider_resolve_same_path(self) -> None:
        for env, base in self.VARIANTS:
            with self.subTest(env=env):
                with patch.dict(os.environ, env, clear=True):
                    expected = Path(base) / "dockrail" / "t3" / "connection.json"
                    self.assertEqual(dockrail_t3.connection_path(), expected)
                    self.assertEqual(t3paths.connection_path(), expected)


if __name__ == "__main__":
    unittest.main()
