# SPDX-License-Identifier: Apache-2.0
"""Tests for provider/t3/t3store.py connection-file reading."""
from __future__ import annotations

import json
import os
import stat
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))

import t3store
from t3store import StoreError


def valid_record() -> dict[str, object]:
    return {
        "version": 1,
        "environmentId": "env-123",
        "label": "omarchy",
        "url": "http://127.0.0.1:3773",
        "token": "secret-token",
        "expiresAt": 1900000000,
        "pairedAt": 1800000000,
    }


class StoreTests(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = Path(tempfile.mkdtemp())
        self.addCleanup(lambda: os.system(f"rm -rf {self.tmp}"))
        self.dir = self.tmp / "t3"
        self.dir.mkdir(mode=0o700)
        os.chmod(self.dir, 0o700)
        self.path = self.dir / "connection.json"

    def write(self, raw: bytes, mode: int = 0o600) -> None:
        fd = os.open(self.path, os.O_CREAT | os.O_WRONLY | os.O_TRUNC, mode)
        try:
            os.write(fd, raw)
        finally:
            os.close(fd)
        os.chmod(self.path, mode)

    def test_missing_file_returns_none(self) -> None:
        self.assertIsNone(t3store.load(self.path))

    def test_missing_directory_returns_none(self) -> None:
        self.assertIsNone(t3store.load(self.tmp / "nope" / "connection.json"))

    def test_valid_record(self) -> None:
        self.write(json.dumps(valid_record()).encode())
        record = t3store.load(self.path)
        self.assertIsNotNone(record)
        assert record is not None
        self.assertEqual(record["environmentId"], "env-123")
        self.assertEqual(record["token"], "secret-token")

    def test_group_readable_rejected(self) -> None:
        self.write(json.dumps(valid_record()).encode(), mode=0o640)
        with self.assertRaises(StoreError) as ctx:
            t3store.load(self.path)
        self.assertEqual(ctx.exception.code, "store_untrusted")

    def test_repeated_untrusted_reads_close_descriptors(self) -> None:
        fd_root = Path("/proc/self/fd")
        if not fd_root.is_dir():
            self.skipTest("requires Linux procfs")
        self.write(json.dumps(valid_record()).encode(), mode=0o644)
        before = len(list(fd_root.iterdir()))
        for _ in range(32):
            with self.assertRaises(StoreError):
                t3store.load(self.path)
        after = len(list(fd_root.iterdir()))
        self.assertLessEqual(after, before + 2)

    def test_world_readable_rejected(self) -> None:
        self.write(json.dumps(valid_record()).encode(), mode=0o644)
        with self.assertRaises(StoreError) as ctx:
            t3store.load(self.path)
        self.assertEqual(ctx.exception.code, "store_untrusted")

    def test_group_writable_directory_rejected(self) -> None:
        os.chmod(self.dir, 0o770)
        self.write(json.dumps(valid_record()).encode())
        with self.assertRaises(StoreError) as ctx:
            t3store.load(self.path)
        self.assertEqual(ctx.exception.code, "store_untrusted")
        os.chmod(self.dir, 0o700)

    def test_symlinked_file_rejected(self) -> None:
        real = self.tmp / "real.json"
        real.write_bytes(json.dumps(valid_record()).encode())
        os.chmod(real, 0o600)
        self.path.symlink_to(real)
        with self.assertRaises(StoreError) as ctx:
            t3store.load(self.path)
        self.assertEqual(ctx.exception.code, "store_untrusted")

    def test_symlinked_directory_rejected(self) -> None:
        real_dir = self.tmp / "realdir"
        real_dir.mkdir(mode=0o700)
        target = real_dir / "connection.json"
        target.write_bytes(json.dumps(valid_record()).encode())
        os.chmod(target, 0o600)
        link = self.tmp / "linkdir"
        link.symlink_to(real_dir)
        with self.assertRaises(StoreError) as ctx:
            t3store.load(link / "connection.json")
        self.assertEqual(ctx.exception.code, "store_untrusted")

    def test_oversize_rejected(self) -> None:
        record = valid_record()
        record["token"] = "x" * (70 * 1024)
        self.write(json.dumps(record).encode())
        with self.assertRaises(StoreError) as ctx:
            t3store.load(self.path)
        self.assertEqual(ctx.exception.code, "store_untrusted")

    def test_invalid_json_rejected(self) -> None:
        self.write(b"{not json")
        with self.assertRaises(StoreError) as ctx:
            t3store.load(self.path)
        self.assertEqual(ctx.exception.code, "store_invalid")

    def test_duplicate_keys_rejected(self) -> None:
        self.write(b'{"version":1,"version":1,"environmentId":"e","label":"l",'
                   b'"url":"http://127.0.0.1:3773","token":"t",'
                   b'"expiresAt":1900000000,"pairedAt":1800000000}')
        with self.assertRaises(StoreError) as ctx:
            t3store.load(self.path)
        self.assertEqual(ctx.exception.code, "store_invalid")

    def test_missing_keys_rejected(self) -> None:
        record = valid_record()
        del record["token"]
        self.write(json.dumps(record).encode())
        with self.assertRaises(StoreError) as ctx:
            t3store.load(self.path)
        self.assertEqual(ctx.exception.code, "store_invalid")

    def test_wrong_version_rejected(self) -> None:
        record = valid_record()
        record["version"] = 2
        self.write(json.dumps(record).encode())
        with self.assertRaises(StoreError) as ctx:
            t3store.load(self.path)
        self.assertEqual(ctx.exception.code, "store_invalid")

    def test_bool_version_rejected(self) -> None:
        record = valid_record()
        record["version"] = True
        self.write(json.dumps(record).encode())
        with self.assertRaises(StoreError) as ctx:
            t3store.load(self.path)
        self.assertEqual(ctx.exception.code, "store_invalid")

    def test_bad_url_rejected(self) -> None:
        record = valid_record()
        record["url"] = "https://example.com:3773"
        self.write(json.dumps(record).encode())
        with self.assertRaises(StoreError) as ctx:
            t3store.load(self.path)
        self.assertEqual(ctx.exception.code, "store_invalid")

    def test_bool_timestamps_rejected(self) -> None:
        record = valid_record()
        record["expiresAt"] = True
        self.write(json.dumps(record).encode())
        with self.assertRaises(StoreError) as ctx:
            t3store.load(self.path)
        self.assertEqual(ctx.exception.code, "store_invalid")

    def test_zero_expiry_rejected(self) -> None:
        record = valid_record()
        record["expiresAt"] = 0
        self.write(json.dumps(record).encode())
        with self.assertRaises(StoreError) as ctx:
            t3store.load(self.path)
        self.assertEqual(ctx.exception.code, "store_invalid")

    def test_empty_token_rejected(self) -> None:
        record = valid_record()
        record["token"] = ""
        self.write(json.dumps(record).encode())
        with self.assertRaises(StoreError) as ctx:
            t3store.load(self.path)
        self.assertEqual(ctx.exception.code, "store_invalid")

    def test_file_mode_bits(self) -> None:
        self.write(json.dumps(valid_record()).encode())
        info = os.stat(self.path)
        self.assertEqual(stat.S_IMODE(info.st_mode), 0o600)
        self.assertEqual(info.st_uid, os.getuid())


if __name__ == "__main__":
    unittest.main()
