# SPDX-License-Identifier: Apache-2.0
"""Pair this machine's Dockrail install with the local T3 Code server.

Self-contained: it must also run from a ``--cli-only`` install that ships no
``provider/`` directory, so endpoint/descriptor/HTTP/listener checks and the
atomic connection-file writer are implemented here instead of imported from
``provider/t3``. ``dockrail_paths`` (shipped in the client bundle) is reused
for the data-root resolution.

Subcommands: ``pair [--url ...] [--json]``, ``status [--json]``,
``unpair [--json]``. Errors exit 2 with a one-line stderr message, or
``{"ok":false,...}`` on stdout with ``--json``. The bearer token is never
printed, logged, or placed on a command line.
"""
from __future__ import annotations

import argparse
import http.client
import json
import os
import secrets
import shutil
import socket
import stat
import subprocess
import sys
import time
from datetime import datetime, timezone
from pathlib import Path
from typing import Any
from urllib.parse import urlencode, urlsplit

try:
    import dockrail_paths
except ImportError:  # pragma: no cover - always shipped beside this file
    dockrail_paths = None  # type: ignore[assignment]

PROTOCOL_VERSION = 2
DEFAULT_TIMEOUT = 5.0
MAX_BODY_BYTES = 16 * 1024 * 1024
MAX_DESCRIPTOR_BYTES = 64 * 1024
MAX_URL_LENGTH = 512
MAX_EXPIRES_IN = 10 * 365 * 86400


class CliError(Exception):
    """User-facing failure carrying a short code and a one-line message."""

    def __init__(self, code: str, message: str) -> None:
        super().__init__(message)
        self.code = code
        self.message = message


# -- endpoint ---------------------------------------------------------------
def check_endpoint(url: str) -> tuple[str, int]:
    """Validate a local T3 base URL, returning ``(host, port)``."""
    if not isinstance(url, str) or not url or len(url) > MAX_URL_LENGTH:
        raise CliError("unsupported_endpoint", f"unsupported T3 endpoint: {url!r}"[:160])
    try:
        parts = urlsplit(url)
    except ValueError:
        raise CliError("unsupported_endpoint", "unsupported T3 endpoint")
    if parts.scheme != "http":
        raise CliError("unsupported_endpoint", "only local http T3 endpoints are supported")
    host = (parts.hostname or "").lower()
    if host not in ("127.0.0.1", "::1"):
        raise CliError("unsupported_endpoint", "only loopback T3 endpoints are supported")
    if parts.username or parts.password:
        raise CliError("unsupported_endpoint", "unsupported T3 endpoint")
    if parts.query or parts.fragment:
        raise CliError("unsupported_endpoint", "unsupported T3 endpoint")
    if parts.path not in ("", "/"):
        raise CliError("unsupported_endpoint", "unsupported T3 endpoint")
    try:
        port = parts.port
    except ValueError:
        raise CliError("unsupported_endpoint", "unsupported T3 endpoint")
    if port is None:
        port = 80
    if not isinstance(port, int) or port < 1 or port > 65535:
        raise CliError("unsupported_endpoint", "unsupported T3 endpoint")
    return host, port


# -- /proc listener ownership -------------------------------------------------
def _local_part(address: str) -> str:
    return address.rsplit(":", 1)[-1].upper() if ":" in address else ""


def _address_part(address: str) -> str:
    return address.rsplit(":", 1)[0].upper() if ":" in address else ""


def _is_loopback_or_any(address: str) -> bool:
    addr = _address_part(address)
    if addr in ("0100007F", "00000000"):
        return True
    if addr in ("0" * 32, "00000000000000000000000001000000"):
        return True
    if addr.startswith("0000000000000000FFFF0000") and addr[24:] in (
        "0100007F",
        "00000000",
    ):
        return True
    return False


def listener_records(
    port: int, proc_root: Path = Path("/proc")
) -> list[tuple[str, int]]:
    """Return ``(socket_symlink, uid)`` for local LISTEN rows on ``port``."""
    wanted = f"{port:04X}"
    records: list[tuple[str, int]] = []
    for name in ("tcp", "tcp6"):
        try:
            with open(proc_root / "net" / name, "r", encoding="utf-8") as handle:
                lines = handle.read().splitlines()
        except (OSError, ValueError, UnicodeError):
            raise CliError("listener_untrusted", "cannot verify the T3 listener")
        for line in lines[1:]:
            cols = line.split()
            if len(cols) < 10:
                continue
            if cols[3].upper() != "0A":
                continue
            if _local_part(cols[1]) != wanted:
                continue
            if not _is_loopback_or_any(cols[1]):
                continue
            try:
                records.append((f"socket:[{cols[9]}]", int(cols[7])))
            except (ValueError, IndexError):
                continue
    return records


def assert_own_listener(port: int, proc_root: Path = Path("/proc")) -> None:
    """Fail unless the current user owns every listener on ``port``."""
    try:
        records = listener_records(port, proc_root)
    except CliError:
        raise
    if not records:
        raise CliError("server_not_running", "T3 Code does not seem to be running")
    own = os.getuid()
    for _inode, uid in records:
        if uid != own:
            raise CliError("listener_untrusted", "the T3 listener is not owned by you")


# -- HTTP ---------------------------------------------------------------------
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
            raise CliError("failed", "T3 response too large")
    return b"".join(chunks)


def _checked_request(
    base_url: str,
    method: str,
    path: str,
    headers: dict[str, str],
    body: bytes | None = None,
    *,
    timeout: float = DEFAULT_TIMEOUT,
    max_bytes: int = MAX_BODY_BYTES,
    proc_root: Path | None = None,
    trusted: bool = False,
) -> dict[str, Any]:
    host, port = check_endpoint(base_url)
    root = proc_root if proc_root is not None else Path("/proc")
    conn = http.client.HTTPConnection(host, port, timeout=timeout)
    try:
        try:
            conn.connect()
        except (OSError, socket.timeout, socket.gaierror):
            raise CliError("server_not_running", "cannot reach the T3 server")
        except (ValueError, TypeError):
            raise CliError("failed", "cannot reach the T3 server")
        if trusted:
            try:
                assert_own_listener(port, root)
            except CliError as exc:
                if exc.code == "server_not_running":
                    raise CliError("server_not_running", "cannot reach the T3 server")
                raise CliError("listener_untrusted", "the T3 listener is not owned by you")
        try:
            conn.request(method, path, body=body, headers=headers)
            response = conn.getresponse()
            status = response.status
            raw = _read_body(response, max_bytes)
        except CliError:
            raise
        except (OSError, socket.timeout, http.client.HTTPException):
            raise CliError("server_not_running", "cannot reach the T3 server")
        except (ValueError, TypeError):
            raise CliError("failed", "cannot reach the T3 server")
    finally:
        conn.close()
    if status in (401, 403):
        raise CliError("authentication_required", "T3 rejected the credentials")
    if status in (404, 426):
        raise CliError("unsupported", "this T3 Code version is not supported")
    if status != 200:
        raise CliError("failed", f"T3 request failed (HTTP {status})")
    try:
        payload = json.loads(raw.decode("utf-8"))
    except (ValueError, UnicodeError):
        raise CliError("failed", "T3 returned an unreadable response")
    if not isinstance(payload, dict):
        raise CliError("failed", "T3 returned an unreadable response")
    return payload


def base_headers(token: str | None = None) -> dict[str, str]:
    headers = {
        "accept": "application/json",
        "accept-encoding": "identity",
        "x-t3-orchestration-protocol": str(PROTOCOL_VERSION),
    }
    if token:
        headers["authorization"] = f"Bearer {token}"
    return headers


def get_descriptor(base_url: str, proc_root: Path | None = None) -> dict[str, Any]:
    """GET the unauthenticated environment descriptor."""
    try:
        payload = _checked_request(
            base_url,
            "GET",
            "/.well-known/t3/environment",
            base_headers(),
            max_bytes=MAX_DESCRIPTOR_BYTES,
            proc_root=proc_root,
            trusted=False,
        )
    except CliError as exc:
        if exc.code in ("server_not_running",):
            raise
        raise CliError("server_not_running", "T3 Code does not seem to be running")
    if payload.get("orchestrationProtocolVersion") != PROTOCOL_VERSION:
        raise CliError("unsupported", "this T3 Code version is not supported")
    if not isinstance(payload.get("environmentId"), str) or not payload["environmentId"]:
        raise CliError("unsupported", "this T3 Code version is not supported")
    return payload


# -- connection file ------------------------------------------------------------
def connection_path() -> Path:
    """Resolve the connection-file path through ``dockrail_paths``."""
    if dockrail_paths is None:  # pragma: no cover
        home = Path(os.environ.get("HOME") or str(Path.home()))
        xdg = os.environ.get("XDG_DATA_HOME", "")
        base = Path(xdg).expanduser() if xdg else home / ".local" / "share"
        return base / "dockrail" / "t3" / "connection.json"
    return dockrail_paths.resolve_paths().canonical_data_root / "t3" / "connection.json"


def ensure_private_dir(path: Path) -> Path:
    """Create the parent directory 0700 and refuse anything untrusted."""
    parent = path.parent
    try:
        os.makedirs(parent, mode=0o700, exist_ok=True)
        os.chmod(parent, 0o700)
        info = os.lstat(parent)
    except OSError:
        raise CliError("store_untrusted", "cannot secure the pairing directory")
    if not stat.S_ISDIR(info.st_mode) or stat.S_ISLNK(info.st_mode):
        raise CliError("store_untrusted", "cannot secure the pairing directory")
    if info.st_uid != os.getuid() or info.st_mode & 0o077:
        raise CliError("store_untrusted", "cannot secure the pairing directory")
    return parent


def write_connection(record: dict[str, Any], path: Path | None = None) -> Path:
    """Atomically write the connection record with mode 0600."""
    target = path if path is not None else connection_path()
    parent = ensure_private_dir(target)
    raw = json.dumps(record, separators=(",", ":")).encode("utf-8")
    tmp = parent / f".connection-{secrets.token_hex(8)}"
    try:
        fd = os.open(tmp, os.O_CREAT | os.O_EXCL | os.O_WRONLY | os.O_NOFOLLOW, 0o600)
    except OSError:
        raise CliError("store_untrusted", "cannot write the pairing file")
    try:
        os.write(fd, raw)
        os.fsync(fd)
    finally:
        os.close(fd)
    os.chmod(tmp, 0o600)
    try:
        os.replace(tmp, target)
    except OSError:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise CliError("store_untrusted", "cannot write the pairing file")
    try:
        dir_fd = os.open(parent, os.O_RDONLY | os.O_DIRECTORY)
    except OSError:
        pass
    else:
        try:
            os.fsync(dir_fd)
        except OSError:
            pass
        finally:
            os.close(dir_fd)
    return target


MAX_STORE_BYTES = 64 * 1024


def _reject_store_duplicates(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    record: dict[str, Any] = {}
    for key, value in pairs:
        if key in record:
            raise ValueError("duplicate pairing key")
        record[key] = value
    return record


def read_connection(path: Path | None = None) -> dict[str, Any] | None:
    """Apply the same fail-closed file and schema checks as provider/t3/t3store.

    Kept self-contained for CLI-only installs without provider/t3.
    """
    target = path if path is not None else connection_path()
    try:
        os.lstat(target)
    except FileNotFoundError:
        return None
    except (OSError, ValueError):
        raise CliError("store_untrusted", "cannot read the pairing file")
    try:
        directory = os.lstat(target.parent)
    except (OSError, ValueError):
        raise CliError("store_untrusted", "cannot trust the pairing directory")
    if (not stat.S_ISDIR(directory.st_mode) or stat.S_ISLNK(directory.st_mode)
            or directory.st_uid != os.getuid() or directory.st_mode & 0o077):
        raise CliError("store_untrusted", "cannot trust the pairing directory")
    try:
        fd = os.open(target, os.O_RDONLY | os.O_NOFOLLOW)
    except FileNotFoundError:
        return None
    except (OSError, ValueError):
        raise CliError("store_untrusted", "cannot trust the pairing file")
    try:
        with os.fdopen(fd, "r", encoding="utf-8") as handle:
            info = os.fstat(handle.fileno())
            if (not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid()
                    or info.st_mode & 0o077 or info.st_size > MAX_STORE_BYTES):
                raise CliError("store_untrusted", "cannot trust the pairing file")
            raw = handle.read(MAX_STORE_BYTES + 1)
    except CliError:
        raise
    except (OSError, ValueError, UnicodeError):
        raise CliError("store_untrusted", "cannot read the pairing file")
    if len(raw) > MAX_STORE_BYTES:
        raise CliError("store_untrusted", "cannot trust the pairing file")
    try:
        record = json.loads(raw, object_pairs_hook=_reject_store_duplicates)
    except (ValueError, UnicodeError):
        raise CliError("store_invalid", "the pairing file is invalid; pair again")
    valid = isinstance(record, dict)
    if valid:
        valid = (record.get("version") == 1 and not isinstance(record.get("version"), bool)
                 and all(isinstance(record.get(key), str) and bool(record[key])
                         for key in ("environmentId", "label", "url", "token"))
                 and all(isinstance(record.get(key), int)
                         and not isinstance(record[key], bool) and record[key] > 0
                         for key in ("expiresAt", "pairedAt")))
    if not valid:
        raise CliError("store_invalid", "the pairing file is invalid; pair again")
    try:
        check_endpoint(record["url"])
    except CliError:
        raise CliError("store_invalid", "the pairing file is invalid; pair again")
    return record


# -- expiry ---------------------------------------------------------------------
def iso_to_epoch(value: object) -> int | None:
    """Normalize a server-provided ISO-8601 expiry string to epoch seconds."""
    if not isinstance(value, str) or not value:
        return None
    try:
        moment = datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError:
        return None
    try:
        if moment.tzinfo is None:
            moment = moment.replace(tzinfo=timezone.utc)
        epoch = int(moment.timestamp())
    except (ValueError, OverflowError, OSError):
        return None
    if epoch <= 0:
        return None
    return epoch


def validated_expires_in(value: object) -> int:
    """Validate the server-reported ``expires_in`` delta seconds."""
    if isinstance(value, bool) or not isinstance(value, int):
        raise CliError("failed", "T3 reported an unreadable session lifetime")
    if value <= 0 or value > MAX_EXPIRES_IN:
        raise CliError("failed", "T3 reported an unreadable session lifetime")
    return value


# -- subcommands ------------------------------------------------------------------
def cmd_pair(args: argparse.Namespace) -> dict[str, Any]:
    url = args.url
    host, port = check_endpoint(url)
    _ = host
    descriptor = get_descriptor(url)
    assert_own_listener(port)
    t3 = shutil.which("t3")
    if not t3:
        raise CliError("t3_missing", "T3 Code CLI (t3) not found; install T3 Code")
    try:
        completed = subprocess.run(
            [t3, "auth", "pairing", "create", "--scope", "orchestration:read",
             "--ttl", "5m", "--label", "Dockrail", "--json"],
            capture_output=True,
            text=True,
            timeout=30,
        )
    except (OSError, subprocess.TimeoutExpired):
        raise CliError("pairing_failed", "could not ask T3 for a pairing credential")
    if completed.returncode != 0:
        raise CliError("pairing_failed", "could not ask T3 for a pairing credential")
    try:
        pairing = json.loads(completed.stdout)
        credential = pairing["credential"]
    except (ValueError, KeyError, TypeError):
        raise CliError("pairing_failed", "could not ask T3 for a pairing credential")
    if not isinstance(credential, str) or not credential:
        raise CliError("pairing_failed", "could not ask T3 for a pairing credential")
    home = Path(os.environ.get("T3CODE_HOME") or Path.home() / ".t3")
    try:
        environment_file = (home / "userdata" / "environment-id").read_text(
            encoding="utf-8"
        ).strip()
    except OSError:
        environment_file = ""
    if environment_file and environment_file != descriptor["environmentId"]:
        raise CliError(
            "environment_changed",
            "the pairing came from a different T3 environment; refusing",
        )
    token_body = _checked_request(
        url,
        "POST",
        "/oauth/token",
        {**base_headers(), "content-type": "application/x-www-form-urlencoded"},
        urlencode({
            "grant_type": "urn:ietf:params:oauth:grant-type:token-exchange",
            "subject_token": credential,
            "subject_token_type": "urn:t3:params:oauth:token-type:environment-bootstrap",
            "requested_token_type": "urn:ietf:params:oauth:token-type:access_token",
            "scope": "orchestration:read",
            "client_label": "Dockrail",
            "client_device_type": "desktop",
            "client_os": "linux",
        }).encode("utf-8"),
        trusted=True,
    )
    if token_body.get("token_type") != "Bearer":
        raise CliError("failed", "T3 returned an unexpected token type")
    scope = token_body.get("scope")
    if not isinstance(scope, str) or set(scope.split()) != {"orchestration:read"}:
        raise CliError("failed", "T3 granted an unexpected scope")
    access_token = token_body.get("access_token")
    if not isinstance(access_token, str) or not access_token:
        raise CliError("failed", "T3 returned an unreadable token")
    del credential
    expires_in = validated_expires_in(token_body.get("expires_in"))
    now = int(time.time())
    session = _checked_request(
        url, "GET", "/api/auth/session", base_headers(access_token), trusted=True
    )
    if session.get("authenticated") is not True:
        raise CliError("authentication_required", "T3 rejected the new session")
    record = {
        "version": 1,
        "environmentId": descriptor["environmentId"],
        "label": descriptor.get("label") or "omarchy",
        "url": url,
        "token": access_token,
        "expiresAt": now + expires_in,
        "pairedAt": now,
    }
    write_connection(record)
    expires = datetime.fromtimestamp(record["expiresAt"], tz=timezone.utc).date().isoformat()
    return {
        "environmentId": record["environmentId"],
        "expiresAt": record["expiresAt"],
        "message": f"Paired with T3 Code ({record['label']}), session expires {expires}.",
    }


def cmd_status(args: argparse.Namespace) -> tuple[dict[str, Any], int]:
    _ = args
    try:
        record = read_connection()
    except CliError as exc:
        return {"paired": False, "reason": exc.code}, 1
    if record is None:
        return {"paired": False, "reason": "not_paired"}, 1
    expires_at = record.get("expiresAt")
    paired = (
        record.get("version") == 1
        and isinstance(record.get("environmentId"), str)
        and isinstance(expires_at, int)
        and not isinstance(expires_at, bool)
        and expires_at > int(time.time())
    )
    info: dict[str, Any] = {
        "paired": bool(paired),
        "environmentId": record.get("environmentId"),
        "label": record.get("label"),
        "expiresAt": expires_at,
        "daysLeft": max(0, (int(expires_at) - int(time.time())) // 86400)
        if isinstance(expires_at, int) and not isinstance(expires_at, bool)
        else 0,
    }
    try:
        descriptor = get_descriptor(str(record.get("url", "")))
        info["serverReachable"] = True
        info["serverEnvironmentId"] = descriptor.get("environmentId")
    except CliError:
        info["serverReachable"] = False
    if not paired:
        return info, 1
    return info, 0


def cmd_unpair(args: argparse.Namespace) -> dict[str, Any]:
    _ = args
    try:
        target = connection_path()
    except CliError as exc:
        raise exc
    try:
        os.unlink(target)
        removed = True
    except FileNotFoundError:
        removed = False
    except OSError:
        raise CliError("failed", "cannot remove the pairing file")
    return {
        "removed": removed,
        "message": (
            "Unpaired. The running provider withdraws T3 threads within seconds. "
            "To revoke the server-side session too, run "
            "`t3 auth session list` / `t3 auth session revoke <id>`."
        ),
    }


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(prog="dockrail t3")
    sub = parser.add_subparsers(dest="command", required=True)
    pair = sub.add_parser("pair", help="pair with the local T3 Code server")
    pair.add_argument("--url", default="http://127.0.0.1:3773")
    pair.add_argument("--json", action="store_true")
    status = sub.add_parser("status", help="show pairing state")
    status.add_argument("--json", action="store_true")
    unpair = sub.add_parser("unpair", help="remove the local pairing")
    unpair.add_argument("--json", action="store_true")
    args = parser.parse_args(argv)
    as_json = bool(getattr(args, "json", False))
    try:
        if args.command == "pair":
            data = cmd_pair(args)
            if as_json:
                print(json.dumps({"ok": True, **data}))
            else:
                print(data["message"])
            return 0
        if args.command == "status":
            data, code = cmd_status(args)
            if as_json:
                print(json.dumps({"ok": data.get("paired", False), **data}))
            elif data.get("paired"):
                print(
                    f"Paired with T3 Code ({data.get('label')}), "
                    f"{data.get('daysLeft')} day(s) left."
                )
            else:
                print(f"Not paired ({data.get('reason', 'not_paired')}).")
            return code
        if args.command == "unpair":
            data = cmd_unpair(args)
            if as_json:
                print(json.dumps({"ok": True, **data}))
            else:
                print(data["message"])
            return 0
    except CliError as exc:
        if as_json:
            print(json.dumps({"ok": False, "error": exc.code, "message": exc.message}))
        else:
            print(f"dockrail t3: {exc.message}", file=sys.stderr)
        return 2
    parser.error("unknown command")
    return 2


if __name__ == "__main__":
    raise SystemExit(main())
