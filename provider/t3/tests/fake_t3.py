# SPDX-License-Identifier: Apache-2.0
"""In-process fake T3 orchestration server for provider tests.

Serves the fixed HTTP routes plus a minimal WebSocket endpoint on a
dynamically allocated loopback port. Default WS behavior replays the
sanitized ``ws-session.jsonl`` fixture; unit tests select scripted modes
(echo/fragment/ping/close/binary/big/drip) or hook requests directly.
"""
from __future__ import annotations

import base64
import hashlib
import json
import socket
import struct
import threading
import time
from pathlib import Path
from typing import Any, Callable
from urllib.parse import urlsplit

HERE = Path(__file__).resolve().parent
FIXTURES = HERE / "fixtures"

GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"


def _ws_accept(key: str) -> str:
    return base64.b64encode(hashlib.sha1((key + GUID).encode("ascii")).digest()).decode(
        "ascii"
    )


class WsConnection:
    """Server side of one WebSocket connection (unmasked server frames)."""

    def __init__(self, sock: socket.socket) -> None:
        self.sock = sock
        self.sock.settimeout(10.0)
        self.buffer = bytearray()
        self.closed = False

    def _fill(self, need: int) -> None:
        while len(self.buffer) < need:
            chunk = self.sock.recv(65536)
            if not chunk:
                raise ConnectionError("peer closed")
            self.buffer += chunk

    def recv_frame(self) -> tuple[int, bytes]:
        """Read one client frame, returning ``(opcode, payload)``."""
        self._fill(2)
        first, second = self.buffer[0], self.buffer[1]
        opcode = first & 0x0F
        masked = bool(second & 0x80)
        length = second & 0x7F
        offset = 2
        if length == 126:
            self._fill(4)
            (length,) = struct.unpack(">H", self.buffer[2:4])
            offset = 4
        elif length == 127:
            self._fill(10)
            (length,) = struct.unpack(">Q", self.buffer[2:10])
            offset = 10
        mask = b""
        if masked:
            self._fill(offset + 4)
            mask = bytes(self.buffer[offset:offset + 4])
            offset += 4
        self._fill(offset + length)
        payload = bytes(self.buffer[offset:offset + length])
        del self.buffer[:offset + length]
        if mask:
            payload = bytes(b ^ mask[i % 4] for i, b in enumerate(payload))
        if opcode == 0x8:
            self.closed = True
        return opcode, payload

    def recv_text(self) -> str:
        opcode, payload = self.recv_frame()
        if opcode == 0x8:
            raise ConnectionError("peer closed")
        assert opcode == 0x1, f"expected text, got opcode {opcode}"
        return payload.decode("utf-8")

    def send_frame(self, opcode: int, payload: bytes, fin: bool = True) -> None:
        header = bytes([(0x80 if fin else 0x00) | opcode])
        length = len(payload)
        if length < 126:
            header += bytes([length])
        elif length <= 65535:
            header += bytes([126]) + struct.pack(">H", length)
        else:
            header += bytes([127]) + struct.pack(">Q", length)
        self.sock.sendall(header + payload)

    def send_text(self, text: str) -> None:
        self.send_frame(0x1, text.encode("utf-8"))

    def close(self) -> None:
        try:
            self.sock.close()
        except OSError:
            pass


def _read_http(sock: socket.socket) -> tuple[str, str, dict[str, str], bytes] | None:
    sock.settimeout(10.0)
    data = bytearray()
    while b"\r\n\r\n" not in data:
        chunk = sock.recv(65536)
        if not chunk:
            return None
        data += chunk
        if len(data) > 65536:
            return None
    head, _, rest = bytes(data).partition(b"\r\n\r\n")
    lines = head.split(b"\r\n")
    try:
        method, target, _version = lines[0].decode("latin-1").split(" ", 2)
    except ValueError:
        return None
    headers: dict[str, str] = {}
    for line in lines[1:]:
        name, _, value = line.decode("latin-1").partition(":")
        headers[name.strip().lower()] = value.strip()
    length = int(headers.get("content-length") or 0)
    body = bytes(rest)
    while len(body) < length:
        chunk = sock.recv(65536)
        if not chunk:
            break
        body += chunk
    return method, target, headers, body[:length]


def _http_response(
    sock: socket.socket, status: int, payload: bytes, content_type: str = "application/json"
) -> None:
    reason = {101: "Switching Protocols", 200: "OK", 401: "Unauthorized",
              404: "Not Found", 426: "Upgrade Required"}.get(status, "Error")
    sock.sendall(
        f"HTTP/1.1 {status} {reason}\r\nContent-Type: {content_type}\r\n"
        f"Content-Length: {len(payload)}\r\nConnection: close\r\n\r\n".encode()
        + payload
    )


class FakeT3:
    """Fake T3 server; call :meth:`start`, use :attr:`port`, call :meth:`stop`."""

    def __init__(
        self,
        *,
        token: str = "fake-token-123",
        environment_id: str = "00000000-0000-4000-8000-000000000001",
        shell: dict[str, Any] | None = None,
        session_chunks: list[dict[str, Any]] | None = None,
        ws_mode: str = "replay",
        handshake_status: int = 101,
        bad_accept: bool = False,
        ws_exit_after_chunks: dict[str, Any] | None = None,
        ack_gated: bool = False,
        ws_on_request: Callable[[dict[str, Any]], tuple[list[Any], Any]] | None = None,
        ws_raw: list[dict[str, Any]] | None = None,
        port: int = 0,
        tokens: set[str] | None = None,
    ) -> None:
        self.token = token
        self.environment_id = environment_id
        self.shell = shell if shell is not None else json.loads(
            (FIXTURES / "shell-snapshot.json").read_text()
        )
        if session_chunks is not None:
            self.session_chunks: list[Any] = session_chunks
        else:
            chunks = []
            for line in (FIXTURES / "ws-session.jsonl").read_text().splitlines():
                message = json.loads(line)
                if message.get("_tag") == "Chunk":
                    chunks.append(message)
            self.session_chunks = chunks
        self.ws_mode = ws_mode
        self.handshake_status = handshake_status
        self.bad_accept = bad_accept
        self.ws_exit_after_chunks = ws_exit_after_chunks
        self.ack_gated = ack_gated
        self.ws_on_request = ws_on_request
        self.ws_raw = ws_raw
        self.fixed_port = port
        self.tokens = set(tokens) if tokens else {token}
        self.descriptor = json.loads((FIXTURES / "descriptor.json").read_text())
        self.descriptor["environmentId"] = environment_id
        self.http_requests: list[tuple[str, str, dict[str, str], bytes]] = []
        self.ws_client_messages: list[str] = []
        self.acks: list[str] = []
        self.subscribe_payloads: list[dict[str, Any]] = []
        self.ack_arrived = threading.Event()
        self.pong_received: list[bytes] = []
        self.close_replied = threading.Event()
        self.lock = threading.Lock()
        self._listener: socket.socket | None = None
        self._conns: list[socket.socket] = []
        self._thread: threading.Thread | None = None
        self.port = 0
        self._stopping = False

    @property
    def url(self) -> str:
        return f"http://127.0.0.1:{self.port}"

    def start(self) -> FakeT3:
        last: OSError | None = None
        for _ in range(10):
            listener = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
            listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
            try:
                listener.bind(("127.0.0.1", self.fixed_port or self.port))
            except OSError as exc:
                last = exc
                listener.close()
                time.sleep(0.2)
                continue
            break
        else:
            assert last is not None
            raise last
        listener.listen(16)
        self.port = listener.getsockname()[1]
        self._stopping = False
        self._listener = listener
        self._thread = threading.Thread(target=self._serve, daemon=True)
        self._thread.start()
        return self

    def stop(self) -> None:
        self._stopping = True
        with self.lock:
            conns = list(self._conns)
        for conn in conns:
            try:
                conn.shutdown(socket.SHUT_RDWR)
            except OSError:
                pass
            try:
                conn.close()
            except OSError:
                pass
        if self._listener is not None:
            try:
                self._listener.shutdown(socket.SHUT_RDWR)
            except OSError:
                pass
            try:
                self._listener.close()
            except OSError:
                pass
            self._listener = None

    def _serve(self) -> None:
        assert self._listener is not None
        self._listener.settimeout(0.2)
        while not self._stopping:
            try:
                conn, _ = self._listener.accept()
            except (socket.timeout, OSError):
                continue
            worker = threading.Thread(target=self._handle, args=(conn,), daemon=True)
            worker.start()

    def _authed(self, headers: dict[str, str]) -> bool:
        return headers.get("authorization") in {f"Bearer {token}" for token in self.tokens}

    def _handle(self, conn: socket.socket) -> None:
        with self.lock:
            self._conns.append(conn)
        try:
            parsed = _read_http(conn)
            if parsed is None:
                conn.close()
                return
            method, target, headers, body = parsed
            with self.lock:
                self.http_requests.append((method, target, dict(headers), body))
            path = urlsplit(target).path
            if path == "/ws":
                self._handle_ws(conn, target, headers)
                return
            if method == "GET" and path == "/.well-known/t3/environment":
                _http_response(conn, 200, json.dumps(self.descriptor).encode())
            elif method == "POST" and path == "/oauth/token":
                _http_response(conn, 200, json.dumps({
                    "access_token": self.token,
                    "token_type": "Bearer",
                    "expires_in": 2592000,
                    "scope": "orchestration:read",
                    "issued_token_type": "urn:ietf:params:oauth:token-type:access_token",
                }).encode())
            elif method == "GET" and path == "/api/auth/session":
                if not self._authed(headers):
                    _http_response(conn, 401, b"{}")
                else:
                    _http_response(conn, 200, json.dumps({
                        "authenticated": True,
                        "scopes": ["orchestration:read"],
                        "sessionMethod": "bearer-access-token",
                        "expiresAt": "2030-01-01T00:00:00.000Z",
                    }).encode())
            elif method == "GET" and path == "/api/orchestration/shell":
                if not self._authed(headers):
                    _http_response(conn, 401, b"{}")
                else:
                    _http_response(conn, 200, json.dumps(self.shell).encode())
            elif method == "POST" and path == "/api/auth/websocket-ticket":
                if not self._authed(headers):
                    _http_response(conn, 401, b"{}")
                else:
                    _http_response(conn, 200, json.dumps({
                        "ticket": "fake-ticket",
                        "expiresAt": "2030-01-01T00:00:00.000Z",
                    }).encode())
            else:
                _http_response(conn, 404, b"{}")
        except (OSError, ConnectionError, ValueError):
            pass
        finally:
            with self.lock:
                if conn in self._conns:
                    self._conns.remove(conn)
            try:
                conn.close()
            except OSError:
                pass

    def _handle_ws(
        self, conn: socket.socket, target: str, headers: dict[str, str]
    ) -> None:
        if self.handshake_status != 101:
            _http_response(conn, self.handshake_status, b"{}")
            conn.close()
            return
        key = headers.get("sec-websocket-key", "")
        accept = "bogus-accept" if self.bad_accept else _ws_accept(key)
        try:
            conn.sendall(
                "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\n"
                f"Connection: Upgrade\r\nSec-WebSocket-Accept: {accept}\r\n\r\n"
                .encode()
            )
        except OSError:
            conn.close()
            return
        link = WsConnection(conn)
        try:
            if self.ws_mode == "echo":
                self._ws_echo(link)
            elif self.ws_mode == "fragment":
                self._ws_fragment(link)
            elif self.ws_mode == "ping":
                self._ws_ping(link)
            elif self.ws_mode == "close":
                self._ws_close(link)
            elif self.ws_mode == "binary":
                link.recv_text()
                link.send_frame(0x2, b"binary-payload")
                link.recv_frame()
            elif self.ws_mode == "big":
                link.recv_text()
                link.send_text("x" * (17 * 1024 * 1024))
            elif self.ws_mode == "drip":
                text = link.recv_text()
                raw = json.dumps({"echo": text}).encode()
                header = bytes([0x81, len(raw)])
                for byte in header + raw:
                    try:
                        conn.sendall(bytes([byte]))
                    except OSError:
                        return
                    time.sleep(0.001)
                link.recv_frame()
            else:
                self._ws_replay(link)
        except (OSError, ConnectionError, AssertionError, ValueError):
            pass
        finally:
            link.close()

    def _record_client(self, text: str) -> None:
        with self.lock:
            self.ws_client_messages.append(text)
        try:
            message = json.loads(text)
        except ValueError:
            return
        if isinstance(message, dict) and message.get("_tag") == "Ack":
            request_id = message.get("requestId")
            if isinstance(request_id, str):
                with self.lock:
                    self.acks.append(request_id)
                self.ack_arrived.set()

    def _ws_echo(self, link: WsConnection) -> None:
        while True:
            text = link.recv_text()
            self._record_client(text)
            link.send_text(text)

    def _ws_fragment(self, link: WsConnection) -> None:
        text = link.recv_text()
        self._record_client(text)
        payload = f"fragmented:{text}".encode()
        part = len(payload) // 3
        link.send_frame(0x1, payload[:part], fin=False)
        link.send_frame(0x0, payload[part:2 * part], fin=False)
        link.send_frame(0x0, payload[2 * part:], fin=True)
        link.recv_frame()

    def _ws_ping(self, link: WsConnection) -> None:
        link.send_frame(0x9, b"ping-me")
        opcode, payload = link.recv_frame()
        assert opcode == 0xA, f"expected pong, got {opcode}"
        with self.lock:
            self.pong_received.append(payload)
        link.recv_frame()

    def _ws_close(self, link: WsConnection) -> None:
        link.send_frame(0x8, struct.pack(">H", 1000))
        opcode, payload = link.recv_frame()
        assert opcode == 0x8, f"expected close echo, got {opcode}"
        self.close_replied.set()

    def _ws_replay(self, link: WsConnection) -> None:
        while True:
            try:
                text = link.recv_text()
            except ConnectionError:
                return
            self._record_client(text)
            try:
                message = json.loads(text)
            except ValueError:
                continue
            if not isinstance(message, dict):
                continue
            if message.get("_tag") == "Ping":
                link.send_frame(0xA, b"")
                continue
            if message.get("_tag") == "Interrupt":
                link.send_frame(
                    0x1, json.dumps({"_tag": "Exit", "requestId": message.get("requestId"),
                                     "exit": {}}).encode()
                )
                return
            if message.get("_tag") != "Request":
                continue
            request_id = str(message.get("id"))
            if self.ws_raw is not None:
                for raw in self.ws_raw:
                    link.send_text(json.dumps(raw))
                return
            if message.get("tag") == "orchestration.subscribeShell":
                payload = message.get("payload")
                if isinstance(payload, dict):
                    with self.lock:
                        self.subscribe_payloads.append(dict(payload))
                if self.ws_on_request is not None:
                    chunks, exit_payload = self.ws_on_request(message)
                    for chunk in chunks:
                        link.send_text(json.dumps(chunk))
                    if exit_payload is not None:
                        link.send_text(json.dumps({
                            "_tag": "Exit", "requestId": request_id, "exit": exit_payload,
                        }))
                        return
                    continue
                chunks = list(self.session_chunks)
                if self.ack_gated and chunks:
                    link.send_text(json.dumps(chunks[0]))
                    if not self.ack_arrived.wait(timeout=5.0):
                        return
                    self.ack_arrived.clear()
                    for chunk in chunks[1:]:
                        link.send_text(json.dumps(chunk))
                else:
                    for chunk in chunks:
                        link.send_text(json.dumps(chunk))
                if self.ws_exit_after_chunks is not None:
                    link.send_text(json.dumps({
                        "_tag": "Exit", "requestId": request_id,
                        "exit": self.ws_exit_after_chunks,
                    }))
                    return
