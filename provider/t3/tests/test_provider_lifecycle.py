# SPDX-License-Identifier: Apache-2.0
"""Provider lifecycle tests: unpair/replace/expiry under live connections."""
from __future__ import annotations

import json
import os
import shutil
import sys
import tempfile
import time
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
TESTS = Path(__file__).resolve().parent
sys.path.insert(0, str(ROOT))
sys.path.insert(0, str(TESTS))

from fake_t3 import FakeT3
from test_provider_protocol import (
    ProviderProc,
    live_predicate,
    make_proc_tree,
    working_chunks,
    working_shell,
    write_connection,
)

TOKEN_A = "lifecycle-token-AAA"
TOKEN_B = "lifecycle-token-BBB"
ENV = "00000000-0000-4000-8000-000000000001"


def atomic_replace(path: Path, record: dict[str, object], mode: int = 0o600) -> None:
    tmp = path.parent / f".connection-{os.getpid():x}"
    fd = os.open(tmp, os.O_CREAT | os.O_WRONLY | os.O_TRUNC, mode)
    try:
        os.write(fd, json.dumps(record).encode())
    finally:
        os.close(fd)
    os.chmod(tmp, mode)
    os.replace(tmp, path)


def record_for(url: str, token: str, expires_at: int = 2000000000) -> dict[str, object]:
    return {
        "version": 1,
        "environmentId": ENV,
        "label": "omarchy",
        "url": url,
        "token": token,
        "expiresAt": expires_at,
        "pairedAt": 1800000000,
    }


class LifecycleTests(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.tmp, True)
        self.conn = self.tmp / "data" / "t3" / "connection.json"
        self.proc_root = self.tmp / "proc"
        self.fake: FakeT3 | None = None
        self.provider: ProviderProc | None = None

    def tearDown(self) -> None:
        if self.provider is not None:
            try:
                self.provider.stop()
            except Exception:
                pass
            self.provider = None
        if self.fake is not None:
            self.fake.stop()
            self.fake = None

    def start_live(self, token: str = TOKEN_A, **fake_kwargs) -> None:
        fake_kwargs.setdefault("session_chunks", working_chunks())
        if "shell" not in fake_kwargs:
            fake_kwargs["shell"] = working_shell()
        if "tokens" not in fake_kwargs and "token" not in fake_kwargs:
            fake_kwargs["tokens"] = {TOKEN_A, TOKEN_B}
        self.fake = FakeT3(**fake_kwargs).start()
        make_proc_tree(self.proc_root, self.fake.port)
        write_connection(self.conn, self.fake.url, token=token)
        self.provider = ProviderProc(self.conn, self.proc_root)

    def assert_output_has_no_token(self, *tokens: str) -> None:
        assert self.provider is not None
        combined = b"".join(self.provider.raw_out + self.provider.raw_err)
        for token in tokens:
            self.assertNotIn(token.encode(), combined)

    def wait_error(self, code: str, timeout: float = 15.0):
        assert self.provider is not None
        snapshot, _ = self.provider.wait_snapshot(
            lambda s: isinstance(s.get("servers"), list)
            and s["servers"]
            and s["servers"][0].get("errorCode") == code,
            timeout=timeout,
        )
        return snapshot

    def test_live_unpair_withdraws_inventory(self) -> None:
        self.start_live()
        assert self.provider is not None and self.fake is not None
        live, _ = self.provider.wait_snapshot(live_predicate())
        self.assertIsNotNone(live)
        os.unlink(self.conn)
        missing = self.wait_error("pairing_required", timeout=10.0)
        self.assertIsNotNone(missing, "unpair must publish within seconds")
        assert missing is not None
        self.assertEqual(missing["agents"], [])
        self.assertEqual(missing["attention"], [])
        # Window-process echoes keep working while unpaired.
        self.provider.send({"kind": "window-processes", "revision": 11,
                            "pids": [os.getpid()]})
        echoed, _ = self.provider.wait_snapshot(
            lambda s: isinstance(s.get("windowProcesses"), dict)
            and s["windowProcesses"].get("revision") == 11
        )
        self.assertIsNotNone(echoed)
        assert echoed is not None
        self.assertEqual(echoed["agents"], [])
        self.assert_output_has_no_token(TOKEN_A)

    def test_live_connection_replacement(self) -> None:
        self.start_live()
        assert self.provider is not None and self.fake is not None
        first, _ = self.provider.wait_snapshot(live_predicate())
        self.assertIsNotNone(first)
        subscribes_before = len(self.fake.subscribe_payloads)
        self.assertGreater(subscribes_before, 0)
        atomic_replace(self.conn, record_for(self.fake.url, TOKEN_B))
        second, _ = self.provider.wait_snapshot(live_predicate(), timeout=20.0)
        self.assertIsNotNone(second, "replacement must reconnect and go live")
        deadline = time.monotonic() + 10.0
        while (
            time.monotonic() < deadline
            and len(self.fake.subscribe_payloads) <= subscribes_before
        ):
            time.sleep(0.1)
        self.assertGreater(len(self.fake.subscribe_payloads), subscribes_before)
        newest = self.fake.subscribe_payloads[-1]
        self.assertNotIn("afterSequence", newest)
        auth_headers = [
            headers.get("authorization", "")
            for method, _path, headers, _body in self.fake.http_requests
            if "authorization" in headers
        ]
        self.assertIn(f"Bearer {TOKEN_B}", auth_headers)
        self.assert_output_has_no_token(TOKEN_A, TOKEN_B)

    def test_unchanged_record_does_not_reconnect(self) -> None:
        self.start_live()
        assert self.provider is not None and self.fake is not None
        first, _ = self.provider.wait_snapshot(live_predicate())
        self.assertIsNotNone(first)
        assert first is not None
        generation = first["servers"][0]["connectionGeneration"]
        subscribes = len(self.fake.subscribe_payloads)
        atomic_replace(self.conn, record_for(self.fake.url, TOKEN_A))
        time.sleep(3.0)
        latest = self.provider.latest_snapshot()
        assert latest is not None
        servers = latest["servers"]
        assert isinstance(servers, list)
        self.assertEqual(servers[0]["connectionGeneration"], generation)
        self.assertEqual(len(self.fake.subscribe_payloads), subscribes)
        self.assert_output_has_no_token(TOKEN_A)

    def test_unpair_during_http_fallback(self) -> None:
        self.start_live(handshake_status=426)
        assert self.provider is not None and self.fake is not None
        live, _ = self.provider.wait_snapshot(live_predicate(), timeout=25.0)
        self.assertIsNotNone(live, "fallback must go live via HTTP polling")
        os.unlink(self.conn)
        missing = self.wait_error("pairing_required", timeout=10.0)
        self.assertIsNotNone(missing)
        assert missing is not None
        self.assertEqual(missing["agents"], [])
        self.assert_output_has_no_token(TOKEN_A)

    def test_replace_during_retry_wait(self) -> None:
        self.start_live()
        assert self.provider is not None and self.fake is not None
        live, _ = self.provider.wait_snapshot(live_predicate())
        self.assertIsNotNone(live)
        self.fake.stop()
        down, _ = self.provider.wait_snapshot(
            lambda s: isinstance(s.get("agents"), list) and s["agents"] == [],
            timeout=15.0,
        )
        self.assertIsNotNone(down)
        atomic_replace(self.conn, record_for(self.fake.url, TOKEN_B))
        withdrawn, _ = self.provider.wait_snapshot(
            lambda s: isinstance(s.get("agents"), list) and s["agents"] == [],
            timeout=10.0,
        )
        self.assertIsNotNone(withdrawn)
        self.fake.start()
        recovered, _ = self.provider.wait_snapshot(live_predicate(), timeout=25.0)
        self.assertIsNotNone(recovered, "must recover with the replacement token")
        auth_headers = [
            headers.get("authorization", "")
            for method, _path, headers, _body in self.fake.http_requests
            if "authorization" in headers
        ]
        self.assertIn(f"Bearer {TOKEN_B}", auth_headers)
        self.assert_output_has_no_token(TOKEN_A, TOKEN_B)

    def test_expiry_invalid_untrusted(self) -> None:
        self.start_live()
        assert self.provider is not None and self.fake is not None
        live, _ = self.provider.wait_snapshot(live_predicate())
        self.assertIsNotNone(live)
        atomic_replace(self.conn, record_for(self.fake.url, TOKEN_A, expires_at=1000))
        expired = self.wait_error("pairing_expired", timeout=10.0)
        self.assertIsNotNone(expired)
        assert expired is not None
        self.assertEqual(expired["agents"], [])
        with open(self.conn, "wb") as handle:
            handle.write(b"{broken json")
        os.chmod(self.conn, 0o600)
        invalid = self.wait_error("store_invalid", timeout=10.0)
        self.assertIsNotNone(invalid)
        atomic_replace(self.conn, record_for(self.fake.url, TOKEN_B))
        os.chmod(self.conn, 0o644)
        untrusted = self.wait_error("store_untrusted", timeout=10.0)
        self.assertIsNotNone(untrusted)
        self.assert_output_has_no_token(TOKEN_A, TOKEN_B)


if __name__ == "__main__":
    unittest.main()
