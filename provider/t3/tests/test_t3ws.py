# SPDX-License-Identifier: Apache-2.0
"""Tests for provider/t3/t3ws.py against the fake T3 WebSocket side."""
from __future__ import annotations

import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
sys.path.insert(0, str(ROOT / "tests"))

import t3ws
from fake_t3 import FakeT3
from t3ws import Closed, Failure, WebSocket


class WsTests(unittest.TestCase):
    def connect(self, fake: FakeT3, **kwargs: object) -> WebSocket:
        ws = WebSocket()
        ws.connect("127.0.0.1", fake.port, "/ws?t=1", **kwargs)  # type: ignore[arg-type]
        self.addCleanup(ws.close)
        return ws

    def test_echo_small(self) -> None:
        fake = FakeT3(ws_mode="echo").start()
        self.addCleanup(fake.stop)
        ws = self.connect(fake)
        ws.send_text("hello")
        self.assertEqual(ws.recv(5.0), "hello")

    def test_payload_boundaries(self) -> None:
        fake = FakeT3(ws_mode="echo").start()
        self.addCleanup(fake.stop)
        ws = self.connect(fake)
        for size in (0, 125, 126, 65535, 65536):
            with self.subTest(size=size):
                ws.send_text("a" * size)
                self.assertEqual(ws.recv(10.0), "a" * size)

    def test_one_mibibyte_echo(self) -> None:
        fake = FakeT3(ws_mode="echo").start()
        self.addCleanup(fake.stop)
        ws = self.connect(fake)
        ws.send_text("b" * (1024 * 1024))
        self.assertEqual(ws.recv(15.0), "b" * (1024 * 1024))

    def test_fragmented_text(self) -> None:
        fake = FakeT3(ws_mode="fragment").start()
        self.addCleanup(fake.stop)
        ws = self.connect(fake)
        ws.send_text("split-me")
        self.assertEqual(ws.recv(5.0), "fragmented:split-me")

    def test_ping_gets_pong(self) -> None:
        fake = FakeT3(ws_mode="ping").start()
        self.addCleanup(fake.stop)
        ws = self.connect(fake)
        self.assertTrue(fake.pong_received or ws.recv(5.0) is None)
        deadline = 5.0
        import time

        end = time.monotonic() + deadline
        while time.monotonic() < end and not fake.pong_received:
            time.sleep(0.05)
        self.assertEqual(fake.pong_received, [b"ping-me"])

    def test_close_handshake(self) -> None:
        fake = FakeT3(ws_mode="close").start()
        self.addCleanup(fake.stop)
        ws = WebSocket()
        ws.connect("127.0.0.1", fake.port, "/ws")
        with self.assertRaises(Closed) as ctx:
            ws.recv(5.0)
        self.assertEqual(ctx.exception.code, 1000)
        self.assertTrue(fake.close_replied.wait(timeout=5.0))

    def test_binary_rejected(self) -> None:
        fake = FakeT3(ws_mode="binary").start()
        self.addCleanup(fake.stop)
        ws = self.connect(fake)
        ws.send_text("go")
        with self.assertRaises(Failure) as ctx:
            ws.recv(5.0)
        self.assertEqual(ctx.exception.code, "unsupported")

    def test_oversize_rejected(self) -> None:
        fake = FakeT3(ws_mode="big").start()
        self.addCleanup(fake.stop)
        ws = self.connect(fake)
        ws.send_text("go")
        with self.assertRaises(Failure) as ctx:
            ws.recv(20.0)
        self.assertEqual(ctx.exception.code, "too_large")

    def test_partial_reads(self) -> None:
        fake = FakeT3(ws_mode="drip").start()
        self.addCleanup(fake.stop)
        ws = self.connect(fake)
        ws.send_text("drip")
        self.assertEqual(ws.recv(10.0), '{"echo": "drip"}')

    def test_bad_accept_fails(self) -> None:
        fake = FakeT3(ws_mode="echo", bad_accept=True).start()
        self.addCleanup(fake.stop)
        ws = WebSocket()
        with self.assertRaises(Failure) as ctx:
            ws.connect("127.0.0.1", fake.port, "/ws")
        self.assertEqual(ctx.exception.code, "failed")

    def test_401_handshake(self) -> None:
        fake = FakeT3(ws_mode="echo", handshake_status=401).start()
        self.addCleanup(fake.stop)
        ws = WebSocket()
        with self.assertRaises(Failure) as ctx:
            ws.connect("127.0.0.1", fake.port, "/ws")
        self.assertEqual(ctx.exception.code, "authentication_required")

    def test_426_handshake(self) -> None:
        fake = FakeT3(ws_mode="echo", handshake_status=426).start()
        self.addCleanup(fake.stop)
        ws = WebSocket()
        with self.assertRaises(Failure) as ctx:
            ws.connect("127.0.0.1", fake.port, "/ws")
        self.assertEqual(ctx.exception.code, "unsupported")

    def test_refused_is_offline(self) -> None:
        ws = WebSocket()
        with self.assertRaises(Failure) as ctx:
            ws.connect("127.0.0.1", 1, "/ws", timeout=2.0)
        self.assertEqual(ctx.exception.code, "offline")

    def test_pre_handshake_failure_sends_nothing(self) -> None:
        fake = FakeT3(ws_mode="echo").start()
        self.addCleanup(fake.stop)

        def nope() -> None:
            raise Failure("listener_untrusted")

        ws = WebSocket()
        with self.assertRaises(Failure):
            ws.connect("127.0.0.1", fake.port, "/ws", pre_handshake=nope)
        self.assertEqual(fake.http_requests, [])


if __name__ == "__main__":
    unittest.main()
