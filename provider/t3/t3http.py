# SPDX-License-Identifier: Apache-2.0
"""Minimal HTTP client for the local T3 orchestration server.

Uses ``http.client.HTTPConnection`` directly: no redirects, no proxy routing
and no hidden auto-connect, so the post-connect same-UID listener check in
``t3procfs`` actually covers the socket that carries the token.
"""
from __future__ import annotations

import http.client
import json
import socket
from pathlib import Path
from typing import Any
from urllib.parse import urlencode, urlsplit

import t3procfs

PROTOCOL_VERSION = 2
DEFAULT_TIMEOUT = 5.0
MAX_BODY_BYTES = 16 * 1024 * 1024
MAX_DESCRIPTOR_BYTES = 64 * 1024
MAX_URL_LENGTH = 512


class Failure(Exception):
    """HTTP failure carrying a short machine-readable code."""

    def __init__(self, code: str) -> None:
        super().__init__(code)
        self.code = code


def check_endpoint(url: str) -> tuple[str, int]:
    """Validate a local T3 base URL, returning ``(host, port)``.

    Only plain ``http`` loopback URLs are accepted; remote/HTTPS endpoints
    are rejected with ``Failure("unsupported_endpoint")``.
    """
    if not isinstance(url, str) or not url or len(url) > MAX_URL_LENGTH:
        raise Failure("unsupported_endpoint")
    try:
        parts = urlsplit(url)
    except ValueError:
        raise Failure("unsupported_endpoint")
    if parts.scheme != "http":
        raise Failure("unsupported_endpoint")
    host = (parts.hostname or "").lower()
    if host not in ("127.0.0.1", "::1"):
        raise Failure("unsupported_endpoint")
    if parts.username or parts.password:
        raise Failure("unsupported_endpoint")
    if parts.query or parts.fragment:
        raise Failure("unsupported_endpoint")
    if parts.path not in ("", "/"):
        raise Failure("unsupported_endpoint")
    try:
        port = parts.port
    except ValueError:
        raise Failure("unsupported_endpoint")
    if port is None:
        port = 80
    if not isinstance(port, int) or port < 1 or port > 65535:
        raise Failure("unsupported_endpoint")
    return host, port


def base_headers(token: str | None = None) -> dict[str, str]:
    headers = {
        "accept": "application/json",
        "accept-encoding": "identity",
        "x-t3-orchestration-protocol": str(PROTOCOL_VERSION),
    }
    if token:
        headers["authorization"] = f"Bearer {token}"
    return headers


def _read_body(response: http.client.HTTPResponse, cap: int) -> bytes:
    chunks: list[bytes] = []
    total = 0
    while True:
        chunk = response.read(min(65536, cap - total + 1))
        if not chunk:
            break
        chunks.append(chunk)
        total += len(chunk)
        if total > cap:
            raise Failure("too_large")
    return b"".join(chunks)


def _parse_object(raw: bytes) -> dict[str, Any]:
    try:
        body = json.loads(raw.decode("utf-8"))
    except (ValueError, UnicodeError):
        raise Failure("failed")
    if not isinstance(body, dict):
        raise Failure("failed")
    return body


def request(
    host: str,
    port: int,
    method: str,
    path: str,
    headers: dict[str, str] | None = None,
    body: bytes | None = None,
    *,
    timeout: float = DEFAULT_TIMEOUT,
    max_bytes: int = MAX_BODY_BYTES,
    proc_root: Path | None = None,
    trusted: bool = False,
) -> tuple[int, dict[str, Any]]:
    """Send one request on a freshly connected socket.

    When ``trusted`` is true (the request carries a token, form credential or
    ticket) the same-UID listener check runs after ``connect()`` and before
    the first byte is written; a failed check closes the socket without
    sending.
    """
    root = proc_root if proc_root is not None else Path("/proc")
    conn = http.client.HTTPConnection(host, port, timeout=timeout)
    try:
        try:
            conn.connect()
        except (OSError, socket.timeout, socket.gaierror):
            raise Failure("offline")
        except (ValueError, TypeError):
            raise Failure("failed")
        if trusted:
            try:
                t3procfs.assert_own_listener(port, root)
            except t3procfs.ProcfsError as exc:
                if exc.code == "offline":
                    raise Failure("offline")
                raise Failure("listener_untrusted")
        try:
            conn.request(method, path, body=body, headers=headers or {})
            response = conn.getresponse()
            status = response.status
            raw = _read_body(response, max_bytes)
        except Failure:
            raise
        except (OSError, socket.timeout, http.client.HTTPException):
            raise Failure("offline")
        except (ValueError, TypeError):
            raise Failure("failed")
    finally:
        conn.close()
    return status, _parse_object(raw)


def checked_request(
    base_url: str,
    method: str,
    path: str,
    headers: dict[str, str] | None = None,
    body: bytes | None = None,
    *,
    timeout: float = DEFAULT_TIMEOUT,
    max_bytes: int = MAX_BODY_BYTES,
    proc_root: Path | None = None,
    trusted: bool = False,
) -> dict[str, Any]:
    """Send one request to ``base_url`` and map non-200 statuses to ``Failure``."""
    host, port = check_endpoint(base_url)
    status, payload = request(
        host,
        port,
        method,
        path,
        headers,
        body,
        timeout=timeout,
        max_bytes=max_bytes,
        proc_root=proc_root,
        trusted=trusted,
    )
    if status in (401, 403):
        raise Failure("authentication_required")
    if status in (404, 426):
        raise Failure("unsupported")
    if status != 200:
        raise Failure("failed")
    return payload


def get_descriptor(
    base_url: str,
    *,
    timeout: float = DEFAULT_TIMEOUT,
    proc_root: Path | None = None,
) -> dict[str, Any]:
    """GET the unauthenticated environment descriptor."""
    payload = checked_request(
        base_url,
        "GET",
        "/.well-known/t3/environment",
        base_headers(),
        timeout=timeout,
        max_bytes=MAX_DESCRIPTOR_BYTES,
        proc_root=proc_root,
        trusted=False,
    )
    if payload.get("orchestrationProtocolVersion") != PROTOCOL_VERSION:
        raise Failure("unsupported")
    if not isinstance(payload.get("environmentId"), str) or not payload["environmentId"]:
        raise Failure("unsupported")
    return payload


def api_get(
    base_url: str,
    path: str,
    token: str,
    *,
    timeout: float = DEFAULT_TIMEOUT,
    proc_root: Path | None = None,
) -> dict[str, Any]:
    """Authenticated JSON GET."""
    return checked_request(
        base_url,
        "GET",
        path,
        base_headers(token),
        timeout=timeout,
        proc_root=proc_root,
        trusted=True,
    )


def api_post(
    base_url: str,
    path: str,
    token: str,
    payload: dict[str, Any] | None = None,
    *,
    timeout: float = DEFAULT_TIMEOUT,
    proc_root: Path | None = None,
) -> dict[str, Any]:
    """Authenticated JSON POST."""
    raw = None
    headers = base_headers(token)
    if payload is not None:
        raw = json.dumps(payload, separators=(",", ":")).encode("utf-8")
        headers["content-type"] = "application/json"
    return checked_request(
        base_url,
        "POST",
        path,
        headers,
        raw,
        timeout=timeout,
        proc_root=proc_root,
        trusted=True,
    )


def form_post(
    base_url: str,
    path: str,
    fields: dict[str, str],
    *,
    timeout: float = DEFAULT_TIMEOUT,
    proc_root: Path | None = None,
) -> dict[str, Any]:
    """Form-encoded POST (token exchange; the body carries a credential)."""
    headers = base_headers()
    headers["content-type"] = "application/x-www-form-urlencoded"
    return checked_request(
        base_url,
        "POST",
        path,
        headers,
        urlencode(fields).encode("utf-8"),
        timeout=timeout,
        proc_root=proc_root,
        trusted=True,
    )
