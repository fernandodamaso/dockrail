# SPDX-License-Identifier: Apache-2.0
"""Tests for provider/t3/t3rpc.py Effect-RPC framing."""
from __future__ import annotations

import json
import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
sys.path.insert(0, str(ROOT / "tests"))

import t3rpc
from fake_t3 import FakeT3
from t3rpc import Failure, RpcSession, StreamEnded
from t3ws import WebSocket


class OrderWs:
    """Scripted socket asserting Ack precedes the next read."""

    def __init__(self, first: str, second: str) -> None:
        self.script = [first, second]
        self.sent: list[dict[str, object]] = []
        self.calls = 0

    def recv(self, timeout: float) -> str | None:
        self.calls += 1
        if self.calls == 2:
            assert self.sent == [{"_tag": "Ack", "requestId": "9"}], self.sent
            return self.script[1]
        if self.calls <= len(self.script):
            return self.script[0]
        return None

    def send_text(self, text: str) -> None:
        self.sent.append(json.loads(text))

    def close(self, code: int = 1000) -> None:
        pass


class RpcTests(unittest.TestCase):
    def session(self, fake: FakeT3) -> RpcSession:
        ws = WebSocket()
        ws.connect("127.0.0.1", fake.port, "/ws")
        rpc = RpcSession(ws)
        self.addCleanup(rpc.close)
        return rpc

    def test_request_ids_increment_from_one(self) -> None:
        fake = FakeT3().start()
        self.addCleanup(fake.stop)
        rpc = self.session(fake)
        # Non-subscribe tags draw no chunk replies, so close() cannot race
        # chunk delivery with a RST on unread bytes.
        first = rpc.stream("other.method", {})
        second = rpc.stream("third.method", {})
        self.assertEqual((first, second), ("1", "2"))
        rpc.close()
        import time

        deadline = time.monotonic() + 5.0
        kinds: list[str | None] = []
        while time.monotonic() < deadline:
            kinds = [json.loads(m).get("_tag") for m in fake.ws_client_messages]
            if "Interrupt" in kinds:
                break
            time.sleep(0.05)
        self.assertIn("Request", kinds)
        self.assertIn("Interrupt", kinds)

    def test_subscribe_receives_values(self) -> None:
        fake = FakeT3().start()
        self.addCleanup(fake.stop)
        rpc = self.session(fake)
        request_id = rpc.stream("orchestration.subscribeShell", {"requestCompletionMarker": True})
        collected: list[tuple[str, object]] = []
        import time

        deadline = time.monotonic() + 5.0
        while time.monotonic() < deadline and not collected:
            collected.extend(rpc.poll(0.5))
        self.assertTrue(collected)
        self.assertTrue(all(rid == request_id for rid, _value in collected))
        kinds = {
            value.get("kind")
            for _rid, value in collected
            if isinstance(value, dict)
        }
        self.assertIn("snapshot", kinds)
        self.assertTrue(fake.subscribe_payloads)
        self.assertEqual(
            fake.subscribe_payloads[0].get("requestCompletionMarker"), True
        )

    def test_ack_sent_before_next_read(self) -> None:
        chunk = lambda n: json.dumps({"_tag": "Chunk", "requestId": "9", "values": [n]})
        ws = OrderWs(chunk(1), chunk(2))
        rpc = RpcSession(ws)  # type: ignore[arg-type]
        pairs = rpc.poll(1.0)
        self.assertEqual(pairs, [("9", 1), ("9", 2)])
        self.assertEqual(
            ws.sent,
            [{"_tag": "Ack", "requestId": "9"}, {"_tag": "Ack", "requestId": "9"}],
        )

    def test_pipelined_chunks_all_acked(self) -> None:
        fake = FakeT3().start()
        self.addCleanup(fake.stop)
        rpc = self.session(fake)
        rpc.stream("orchestration.subscribeShell", {})
        rpc.poll(3.0)
        self.assertTrue(fake.acks)
        self.assertTrue(all(ack == "1" for ack in fake.acks))

    def test_exit_forbidden_maps_auth(self) -> None:
        fake = FakeT3(
            ws_raw=[{"_tag": "Exit", "requestId": "1", "exit": {"error": "Forbidden"}}]
        ).start()
        self.addCleanup(fake.stop)
        rpc = self.session(fake)
        rpc.stream("orchestration.subscribeShell", {})
        with self.assertRaises(StreamEnded) as ctx:
            rpc.poll(3.0)
        self.assertEqual(ctx.exception.code, "authentication_required")

    def test_exit_plain_maps_offline(self) -> None:
        fake = FakeT3(
            ws_raw=[{"_tag": "Exit", "requestId": "1", "exit": {}}]
        ).start()
        self.addCleanup(fake.stop)
        rpc = self.session(fake)
        rpc.stream("orchestration.subscribeShell", {})
        with self.assertRaises(StreamEnded) as ctx:
            rpc.poll(3.0)
        self.assertEqual(ctx.exception.code, "offline")

    def test_defect_maps_failed(self) -> None:
        fake = FakeT3(ws_raw=[{"_tag": "Defect", "reason": "boom"}]).start()
        self.addCleanup(fake.stop)
        rpc = self.session(fake)
        rpc.stream("orchestration.subscribeShell", {})
        with self.assertRaises(Failure) as ctx:
            rpc.poll(3.0)
        self.assertEqual(ctx.exception.code, "failed")

    def test_ping_timeout_maps_offline(self) -> None:
        old_every, old_within = t3rpc.PING_EVERY, t3rpc.PONG_WITHIN
        t3rpc.PING_EVERY, t3rpc.PONG_WITHIN = 0.2, 0.3
        self.addCleanup(setattr, t3rpc, "PING_EVERY", old_every)
        self.addCleanup(setattr, t3rpc, "PONG_WITHIN", old_within)
        # Echo mode never answers Pong: the Request echo is not a Pong.
        fake = FakeT3(ws_mode="echo").start()
        self.addCleanup(fake.stop)
        rpc = self.session(fake)
        rpc.stream("orchestration.subscribeShell", {})
        with self.assertRaises(Failure) as ctx:
            rpc.poll(5.0)
        self.assertEqual(ctx.exception.code, "offline")

    def test_pong_keeps_session_alive(self) -> None:
        old_every, old_within = t3rpc.PING_EVERY, t3rpc.PONG_WITHIN
        t3rpc.PING_EVERY, t3rpc.PONG_WITHIN = 0.2, 30.0
        self.addCleanup(setattr, t3rpc, "PING_EVERY", old_every)
        self.addCleanup(setattr, t3rpc, "PONG_WITHIN", old_within)
        fake = FakeT3().start()
        self.addCleanup(fake.stop)
        rpc = self.session(fake)
        rpc.stream("orchestration.subscribeShell", {})
        pairs = rpc.poll(1.5)
        self.assertTrue(pairs)


if __name__ == "__main__":
    unittest.main()
