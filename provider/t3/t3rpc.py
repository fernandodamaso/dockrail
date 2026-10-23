# SPDX-License-Identifier: Apache-2.0
"""Effect-RPC framing over the T3 WebSocket client.

One JSON object per text message. The provider opens a single stream
(``orchestration.subscribeShell``) and polls it; every ``Chunk`` is acked
before its values are processed.
"""
from __future__ import annotations

import json
import time

from t3ws import Closed, Failure, WebSocket

PING_EVERY = 20.0
PONG_WITHIN = 10.0


class StreamEnded(Exception):
    """A stream finished with ``Exit``; carries a provider error code."""

    def __init__(self, request_id: str, code: str) -> None:
        super().__init__(f"{request_id}:{code}")
        self.request_id = request_id
        self.code = code


def _exit_code(exit_payload: object) -> str:
    try:
        text = json.dumps(exit_payload, separators=(",", ":"))
    except (ValueError, TypeError):
        return "offline"
    if "Forbidden" in text or "scope" in text:
        return "authentication_required"
    return "offline"


class RpcSession:
    """Single-threaded Effect-RPC session over one :class:`WebSocket`."""

    def __init__(self, ws: WebSocket) -> None:
        self.ws = ws
        self.counter = 0
        self.open_streams: set[str] = set()
        self.last_ping_at: float | None = time.monotonic()
        self.ping_sent_at: float | None = None
        self.pong_seen_at: float | None = None

    def stream(self, tag: str, payload: dict[str, object]) -> str:
        """Open a stream, returning its decimal-string request id."""
        self.counter += 1
        request_id = str(self.counter)
        message = {
            "_tag": "Request",
            "id": request_id,
            "tag": tag,
            "payload": payload,
            "headers": [],
        }
        try:
            self.ws.send_text(json.dumps(message, separators=(",", ":")))
        except Failure:
            raise
        self.open_streams.add(request_id)
        return request_id

    def _send(self, message: dict[str, object]) -> None:
        self.ws.send_text(json.dumps(message, separators=(",", ":")))

    def _check_ping(self, now: float) -> None:
        if self.last_ping_at is None or now - self.last_ping_at >= PING_EVERY:
            self._send({"_tag": "Ping"})
            self.last_ping_at = now
            # Each ping starts a new acknowledgement deadline.
            self.ping_sent_at = now
        if (
            self.ping_sent_at is not None
            and (self.pong_seen_at is None or self.pong_seen_at < self.ping_sent_at)
            and now - self.ping_sent_at > PONG_WITHIN
        ):
            try:
                self.ws.close()
            finally:
                raise Failure("offline")

    def poll(self, timeout: float) -> list[tuple[str, object]]:
        """Read until ``timeout``; return ``(request_id, value)`` pairs."""
        deadline = time.monotonic() + timeout
        collected: list[tuple[str, object]] = []
        while True:
            self._check_ping(time.monotonic())
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                return collected
            try:
                raw = self.ws.recv(min(remaining, 1.0))
            except Closed as exc:
                if exc.code == 1008:
                    raise Failure("authentication_required")
                raise Failure("offline")
            if raw is None:
                continue
            try:
                message = json.loads(raw)
            except (ValueError, UnicodeError):
                continue
            if not isinstance(message, dict):
                continue
            tag = message.get("_tag")
            if tag == "Pong":
                self.pong_seen_at = time.monotonic()
                continue
            if tag == "Chunk":
                request_id = message.get("requestId")
                if not isinstance(request_id, str):
                    continue
                try:
                    self._send({"_tag": "Ack", "requestId": request_id})
                except Failure:
                    raise Failure("offline")
                values = message.get("values")
                if isinstance(values, list):
                    collected.extend((request_id, value) for value in values)
                continue
            if tag == "Exit":
                request_id = message.get("requestId")
                code = _exit_code(message.get("exit"))
                self.open_streams.discard(
                    request_id if isinstance(request_id, str) else ""
                )
                raise StreamEnded(
                    request_id if isinstance(request_id, str) else "", code
                )
            if tag in ("ClientProtocolError", "Defect"):
                try:
                    self.ws.close()
                finally:
                    raise Failure("failed")

    def close(self) -> None:
        """Interrupt open streams, then close the socket quietly."""
        for request_id in sorted(self.open_streams):
            try:
                self._send(
                    {
                        "_tag": "Interrupt",
                        "requestId": request_id,
                        "interruptors": [],
                    }
                )
            except Failure:
                break
        self.open_streams.clear()
        try:
            self.ws.close()
        except Failure:
            pass
