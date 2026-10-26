# SPDX-License-Identifier: Apache-2.0
"""Tests for provider/t3/t3http.py against a stub HTTP server."""
from __future__ import annotations

import json
import os
import shutil
import socket
import sys
import tempfile
import threading
import unittest
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))

import t3http
from t3http import Failure

UID = os.getuid()


class StubHandler(BaseHTTPRequestHandler):
    seen: list[str] = []
    body: bytes = b'{"ok":true}'
    status: int = 200

    def log_message(self, *args: object) -> None:
        pass

    def _serve(self) -> None:
        length = int(self.headers.get("Content-Length") or 0)
        if length:
            self.rfile.read(length)
        type(self).seen.append(f"{self.command} {self.path}")
        payload = type(self).body
        self.send_response(type(self).status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    do_GET = _serve
    do_POST = _serve


def write_proc_tree(root: Path, port: int, uid: int) -> None:
    net = root / "net"
    net.mkdir(exist_ok=True)
    row = (
        "   0: 0100007F:%04X 00000000:0000 0A 00000000:00000000 00:00000000"
        " 00000000 %5d        0 99 1 0000000000000000 100 0 0 10 0\n" % (port, uid)
    )
    (net / "tcp").write_text(
        "  sl  local_address rem_address   st tx_queue rx_queue tr tm->when"
        " retrnsmt   uid  timeout inode\n" + row
    )
    (net / "tcp6").write_text(
        "  sl  local_address rem_address   st tx_queue rx_queue tr tm->when"
        " retrnsmt   uid  timeout inode\n"
    )


class EndpointTests(unittest.TestCase):
    GOOD = [
        "http://127.0.0.1:3773",
        "http://127.0.0.1:3773/",
        "http://127.0.0.1:1",
        "http://127.0.0.1:65535",
        "http://[::1]:3773",
        "http://127.0.0.1:80",
        "http://127.0.0.1",
    ]
    BAD = [
        "",
        "http://127.0.0.1:3773/path",
        "http://127.0.0.1:3773?x=1",
        "http://127.0.0.1:3773#frag",
        "http://127.0.0.1:0",
        "http://127.0.0.1:65536",
        "https://127.0.0.1:3773",
        "http://localhost:3773",
        "http://192.168.1.1:3773",
        "http://user@127.0.0.1:3773",
        "ftp://127.0.0.1:3773",
        "http://127.0.0.1:3773/" + "x" * 600,
        "not a url",
    ]

    def test_accepts_local_endpoints(self) -> None:
        for url in self.GOOD:
            with self.subTest(url=url):
                host, port = t3http.check_endpoint(url)
                self.assertIn(host, ("127.0.0.1", "::1"))
                self.assertGreaterEqual(port, 1)

    def test_rejects_remote_endpoints(self) -> None:
        for url in self.BAD:
            with self.subTest(url=url):
                with self.assertRaises(Failure) as ctx:
                    t3http.check_endpoint(url)
                self.assertEqual(ctx.exception.code, "unsupported_endpoint")

    def test_explicit_port_parsed(self) -> None:
        self.assertEqual(t3http.check_endpoint("http://127.0.0.1:3773"), ("127.0.0.1", 3773))


class HttpTests(unittest.TestCase):
    def setUp(self) -> None:
        StubHandler.seen = []
        StubHandler.body = b'{"ok":true}'
        StubHandler.status = 200
        self.server = HTTPServer(("127.0.0.1", 0), StubHandler)
        self.port = self.server.server_address[1]
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()
        self.addCleanup(self.server.shutdown)
        self.addCleanup(self.server.server_close)
        self.base = f"http://127.0.0.1:{self.port}"
        self.proc = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.proc, True)
        write_proc_tree(self.proc, self.port, UID)

    def test_get_ok(self) -> None:
        payload = t3http.api_get(self.base, "/x", "tok", proc_root=self.proc)
        self.assertEqual(payload, {"ok": True})
        self.assertIn("GET /x", StubHandler.seen)

    def test_status_mapping(self) -> None:
        for status, code in (
            (401, "authentication_required"),
            (403, "authentication_required"),
            (404, "unsupported"),
            (426, "unsupported"),
            (500, "failed"),
            (301, "failed"),
        ):
            with self.subTest(status=status):
                StubHandler.status = status
                with self.assertRaises(Failure) as ctx:
                    t3http.api_get(self.base, "/x", "tok", proc_root=self.proc)
                self.assertEqual(ctx.exception.code, code)
        StubHandler.status = 200

    def test_connection_refused_is_offline(self) -> None:
        with self.assertRaises(Failure) as ctx:
            t3http.api_get("http://127.0.0.1:1", "/x", "tok", proc_root=self.proc)
        self.assertEqual(ctx.exception.code, "offline")

    def test_non_object_body_fails(self) -> None:
        StubHandler.body = b"[1,2]"
        with self.assertRaises(Failure) as ctx:
            t3http.api_get(self.base, "/x", "tok", proc_root=self.proc)
        self.assertEqual(ctx.exception.code, "failed")

    def test_untrusted_listener_closes_without_sending(self) -> None:
        StubHandler.seen = []
        write_proc_tree(self.proc, self.port, UID + 1)
        with self.assertRaises(Failure) as ctx:
            t3http.api_get(self.base, "/x", "tok", proc_root=self.proc)
        self.assertEqual(ctx.exception.code, "listener_untrusted")
        self.assertEqual(StubHandler.seen, [])

    def test_missing_listener_is_offline(self) -> None:
        empty = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, empty, True)
        (empty / "net").mkdir()
        for name in ("tcp", "tcp6"):
            (empty / "net" / name).write_text("  sl  local_address\n")
        with self.assertRaises(Failure) as ctx:
            t3http.api_get(self.base, "/x", "tok", proc_root=empty)
        self.assertEqual(ctx.exception.code, "offline")

    def test_descriptor_ok(self) -> None:
        StubHandler.body = json.dumps(
            {"orchestrationProtocolVersion": 2, "environmentId": "env-1"}
        ).encode()
        descriptor = t3http.get_descriptor(self.base, proc_root=self.proc)
        self.assertEqual(descriptor["environmentId"], "env-1")

    def test_descriptor_rejects_protocol(self) -> None:
        StubHandler.body = json.dumps(
            {"orchestrationProtocolVersion": 1, "environmentId": "env-1"}
        ).encode()
        with self.assertRaises(Failure) as ctx:
            t3http.get_descriptor(self.base, proc_root=self.proc)
        self.assertEqual(ctx.exception.code, "unsupported")

    def test_body_cap(self) -> None:
        StubHandler.body = b'{"k":"' + b"x" * (17 * 1024 * 1024) + b'"}'
        with self.assertRaises(Failure) as ctx:
            t3http.api_get(self.base, "/x", "tok", proc_root=self.proc)
        self.assertEqual(ctx.exception.code, "too_large")

    def test_protocol_header_sent(self) -> None:
        seen_headers: list[str] = []
        original_get = StubHandler.do_GET
        original_post = StubHandler.do_POST

        def spy(handler: StubHandler) -> None:
            seen_headers.append(handler.headers.get("x-t3-orchestration-protocol", ""))
            StubHandler._serve(handler)

        StubHandler.do_GET = spy  # type: ignore[method-assign]
        StubHandler.do_POST = spy  # type: ignore[method-assign]
        self.addCleanup(setattr, StubHandler, "do_GET", original_get)
        self.addCleanup(setattr, StubHandler, "do_POST", original_post)
        t3http.api_get(self.base, "/x", "tok", proc_root=self.proc)
        self.assertEqual(seen_headers, ["2"])

    def test_socket_receives_no_token_on_untrusted(self) -> None:
        # The token must never reach a listener owned by someone else.
        received: list[bytes] = []
        srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        srv.bind(("127.0.0.1", 0))
        srv.listen(1)
        port = srv.getsockname()[1]
        self.addCleanup(srv.close)
        write_proc_tree(self.proc, port, UID + 1)

        def accept() -> None:
            conn, _ = srv.accept()
            with conn:
                conn.settimeout(2)
                try:
                    while True:
                        chunk = conn.recv(4096)
                        if not chunk:
                            break
                        received.append(chunk)
                except socket.timeout:
                    pass

        worker = threading.Thread(target=accept, daemon=True)
        worker.start()
        with self.assertRaises(Failure):
            t3http.api_get(
                f"http://127.0.0.1:{port}", "/x", "super-secret", proc_root=self.proc
            )
        worker.join(timeout=5)
        self.assertEqual(b"".join(received), b"")


if __name__ == "__main__":
    unittest.main()
