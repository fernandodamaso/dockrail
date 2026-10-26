# SPDX-License-Identifier: Apache-2.0
"""Minimal RFC 6455 WebSocket client for the local T3 server (stdlib only).

Plain TCP, no TLS. Client frames are masked; server ping frames are answered
with pong; close frames are echoed and surface as :class:`Closed`.
"""
from __future__ import annotations

import base64
import hashlib
import os
import socket
import struct
import time
from typing import Callable

GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
MAX_HANDSHAKE_BYTES = 16 * 1024
MAX_MESSAGE_BYTES = 16 * 1024 * 1024

_OP_CONT = 0x0
_OP_TEXT = 0x1
_OP_BINARY = 0x2
_OP_CLOSE = 0x8
_OP_PING = 0x9
_OP_PONG = 0xA


class Failure(Exception):
    """WebSocket failure carrying a short machine-readable code."""

    def __init__(self, code: str) -> None:
        super().__init__(code)
        self.code = code


class Closed(Exception):
    """The peer completed the close handshake."""

    def __init__(self, code: int = 1005) -> None:
        super().__init__(f"closed:{code}")
        self.code = code


class WebSocket:
    """One client WebSocket connection."""

    def __init__(self) -> None:
        self.sock: socket.socket | None = None
        self.buffer = bytearray()
        self.fragment = bytearray()
        self.fragment_opcode: int | None = None

    def connect(
        self,
        host: str,
        port: int,
        path_and_query: str,
        timeout: float = 10.0,
        pre_handshake: Callable[[], None] | None = None,
    ) -> None:
        """Open the TCP connection and perform the Upgrade handshake.

        ``pre_handshake``, when given, runs after the TCP connection is open
        and before the first handshake byte is written; if it raises, the
        socket is closed without sending.
        """
        if self.sock is not None:
            raise Failure("failed")
        try:
            sock = socket.create_connection((host, port), timeout)
        except (OSError, socket.timeout, socket.gaierror):
            raise Failure("offline")
        except (ValueError, TypeError):
            raise Failure("failed")
        key = base64.b64encode(os.urandom(16)).decode("ascii")
        handshake = (
            f"GET {path_and_query} HTTP/1.1\r\n"
            f"Host: {host}:{port}\r\n"
            "Upgrade: websocket\r\n"
            "Connection: Upgrade\r\n"
            f"Sec-WebSocket-Key: {key}\r\n"
            "Sec-WebSocket-Version: 13\r\n\r\n"
        ).encode("ascii")
        sock.settimeout(timeout)
        if pre_handshake is not None:
            try:
                pre_handshake()
            except Exception:
                sock.close()
                raise
        try:
            sock.sendall(handshake)
            raw = self._read_until(sock, b"\r\n\r\n", MAX_HANDSHAKE_BYTES, timeout)
        except (OSError, socket.timeout):
            sock.close()
            raise Failure("offline")
        except Failure:
            sock.close()
            raise
        head, _, rest = raw.partition(b"\r\n\r\n")
        lines = head.split(b"\r\n")
        status = _status_code(lines[0] if lines else b"")
        headers = _parse_headers(lines[1:])
        if status == 101:
            expected = base64.b64encode(
                hashlib.sha1((key + GUID).encode("ascii")).digest()
            ).decode("ascii")
            if headers.get("sec-websocket-accept") != expected:
                sock.close()
                raise Failure("failed")
            self.sock = sock
            self.buffer = bytearray(rest)
            return
        sock.close()
        if status == 401:
            raise Failure("authentication_required")
        if status in (404, 426):
            raise Failure("unsupported")
        raise Failure("failed")

    def _read_until(
        self, sock: socket.socket, marker: bytes, cap: int, timeout: float
    ) -> bytes:
        deadline = time.monotonic() + timeout
        data = bytearray()
        while True:
            if marker in data:
                return bytes(data)
            if len(data) > cap:
                raise Failure("failed")
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise Failure("offline")
            sock.settimeout(remaining)
            try:
                chunk = sock.recv(65536)
            except socket.timeout:
                raise Failure("offline")
            if not chunk:
                raise Failure("offline")
            data += chunk

    def _send_frame(self, opcode: int, payload: bytes) -> None:
        sock = self.sock
        if sock is None:
            raise Failure("offline")
        mask = os.urandom(4)
        length = len(payload)
        if length < 126:
            header = struct.pack(">BB", 0x80 | opcode, 0x80 | length)
        elif length <= 65535:
            header = struct.pack(">BBH", 0x80 | opcode, 0x80 | 126, length)
        else:
            header = struct.pack(">BBQ", 0x80 | opcode, 0x80 | 127, length)
        masked = bytes(byte ^ mask[i % 4] for i, byte in enumerate(payload))
        try:
            sock.sendall(header + mask + masked)
        except (OSError, socket.timeout):
            raise Failure("offline")

    def send_text(self, text: str) -> None:
        """Send one masked FIN text frame."""
        try:
            payload = text.encode("utf-8")
        except (UnicodeError, ValueError):
            raise Failure("failed")
        if len(payload) > MAX_MESSAGE_BYTES:
            raise Failure("too_large")
        self._send_frame(_OP_TEXT, payload)

    def _fill(self, need: int, deadline: float) -> None:
        sock = self.sock
        if sock is None:
            raise Failure("offline")
        while len(self.buffer) < need:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise Failure("timeout")
            sock.settimeout(remaining)
            try:
                chunk = sock.recv(65536)
            except socket.timeout:
                raise Failure("timeout")
            except OSError:
                raise Failure("offline")
            if not chunk:
                raise Failure("offline")
            self.buffer += chunk

    def recv(self, timeout: float) -> str | None:
        """Return one complete text message, or ``None`` on timeout.

        A timeout while a fragmented message is in flight returns ``None``
        and keeps the partial payload for the next call.
        """
        deadline = time.monotonic() + timeout
        while True:
            try:
                self._fill(2, deadline)
            except Failure as exc:
                if exc.code == "timeout":
                    return None
                raise
            first, second = self.buffer[0], self.buffer[1]
            fin = bool(first & 0x80)
            opcode = first & 0x0F
            masked = bool(second & 0x80)
            length = second & 0x7F
            offset = 2
            if length == 126:
                self._fill(offset + 2, deadline)
                (length,) = struct.unpack(">H", self.buffer[offset:offset + 2])
                offset += 2
            elif length == 127:
                self._fill(offset + 8, deadline)
                (length,) = struct.unpack(">Q", self.buffer[offset:offset + 8])
                offset += 8
            if masked:
                self._fill(offset + 4, deadline)
                mask = bytes(self.buffer[offset:offset + 4])
                offset += 4
            else:
                mask = b""
            self._fill(offset + length, deadline)
            payload = bytes(self.buffer[offset:offset + length])
            del self.buffer[:offset + length]
            if mask:
                payload = bytes(byte ^ mask[i % 4] for i, byte in enumerate(payload))

            if opcode == _OP_CONT:
                if self.fragment_opcode is None:
                    raise Failure("failed")
                self.fragment += payload
            elif opcode == _OP_TEXT:
                if self.fragment_opcode is not None:
                    raise Failure("failed")
                self.fragment_opcode = _OP_TEXT
                self.fragment += payload
            elif opcode == _OP_BINARY:
                raise Failure("unsupported")
            elif opcode == _OP_CLOSE:
                code = 1005
                if len(payload) >= 2:
                    (code,) = struct.unpack(">H", payload[:2])
                try:
                    self._send_frame(_OP_CLOSE, payload[:2])
                except Failure:
                    pass
                raise Closed(code)
            elif opcode == _OP_PING:
                try:
                    self._send_frame(_OP_PONG, payload)
                except Failure:
                    raise Failure("offline")
                continue
            elif opcode == _OP_PONG:
                continue
            else:
                raise Failure("failed")

            if len(self.fragment) > MAX_MESSAGE_BYTES:
                raise Failure("too_large")
            if fin:
                if self.fragment_opcode is None:
                    raise Failure("failed")
                message = bytes(self.fragment)
                self.fragment = bytearray()
                self.fragment_opcode = None
                try:
                    return message.decode("utf-8")
                except UnicodeError:
                    raise Failure("failed")

    def close(self, code: int = 1000) -> None:
        """Send a masked close frame and shut the socket down quietly."""
        sock, self.sock = self.sock, None
        if sock is None:
            return
        try:
            mask = os.urandom(4)
            payload = struct.pack(">H", code)
            masked = bytes(byte ^ mask[i % 4] for i, byte in enumerate(payload))
            sock.sendall(struct.pack(">BB", 0x88, 0x80 | len(payload)) + mask + masked)
        except OSError:
            pass
        try:
            sock.shutdown(socket.SHUT_RDWR)
        except OSError:
            pass
        try:
            sock.close()
        except OSError:
            pass


def _status_code(status_line: bytes) -> int:
    try:
        parts = status_line.decode("latin-1").split(" ", 2)
        return int(parts[1])
    except (ValueError, IndexError, UnicodeError):
        return 0


def _parse_headers(lines: list[bytes]) -> dict[str, str]:
    headers: dict[str, str] = {}
    for line in lines:
        name, separator, value = line.decode("latin-1").partition(":")
        if separator:
            headers[name.strip().lower()] = value.strip()
    return headers
