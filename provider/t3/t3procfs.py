# SPDX-License-Identifier: Apache-2.0
"""Linux /proc helpers: listener ownership, identities and ancestry.

Every function takes an optional ``proc_root`` so tests can point it at a
fake tree. Production callers always use the default ``/proc``.
"""
from __future__ import annotations

import os
import stat as stat_module
from pathlib import Path
from typing import Any

LISTEN_STATE = "0A"
ANCESTOR_LIMIT = 8
MAX_WINDOW_PIDS = 256

_IPV4_LOOPBACK = "0100007F"
_IPV4_ANY = "00000000"
_IPV6_ANY = "0" * 32
_IPV6_LOOPBACK = "00000000000000000000000001000000"
_IPV6_V4_PREFIX = "0000000000000000FFFF0000"


class ProcfsError(Exception):
    """Raised when /proc cannot answer a trust question fail-closed."""

    def __init__(self, code: str) -> None:
        super().__init__(code)
        self.code = code


def _local_part(address: str) -> str:
    return address.rsplit(":", 1)[-1].upper() if ":" in address else ""


def _address_part(address: str) -> str:
    return address.rsplit(":", 1)[0].upper() if ":" in address else ""


def _is_loopback_or_any(address: str) -> bool:
    addr = _address_part(address)
    if addr in (_IPV4_LOOPBACK, _IPV4_ANY):
        return True
    if addr in (_IPV6_ANY, _IPV6_LOOPBACK):
        return True
    if addr.startswith(_IPV6_V4_PREFIX) and addr[len(_IPV6_V4_PREFIX):] in (
        _IPV4_LOOPBACK,
        _IPV4_ANY,
    ):
        return True
    return False


def _listen_rows(port: int, proc_root: Path) -> list[list[str]]:
    wanted = f"{port:04X}"
    rows: list[list[str]] = []
    for name in ("tcp", "tcp6"):
        try:
            with open(proc_root / "net" / name, "r", encoding="utf-8") as handle:
                lines = handle.read().splitlines()
        except (OSError, ValueError, UnicodeError):
            raise ProcfsError("unreadable")
        for line in lines[1:]:
            cols = line.split()
            if len(cols) < 10:
                continue
            if cols[3].upper() != LISTEN_STATE:
                continue
            if _local_part(cols[1]) != wanted:
                continue
            if not _is_loopback_or_any(cols[1]):
                continue
            rows.append(cols)
    return rows


def listener_records(
    port: int, proc_root: Path = Path("/proc")
) -> list[tuple[str, int]]:
    """Return ``(socket_symlink, uid)`` for every local LISTEN row on ``port``."""
    try:
        rows = _listen_rows(port, proc_root)
    except ProcfsError:
        raise
    records: list[tuple[str, int]] = []
    for cols in rows:
        try:
            uid = int(cols[7])
        except (ValueError, IndexError):
            continue
        records.append((f"socket:[{cols[9]}]", uid))
    return records


def listener_inodes(port: int, proc_root: Path = Path("/proc")) -> set[str]:
    """Return the socket symlinks listening on ``port``."""
    return {inode for inode, _uid in listener_records(port, proc_root)}


def assert_own_listener(port: int, proc_root: Path = Path("/proc")) -> None:
    """Fail unless the current user owns every listener on ``port``.

    Raises ``ProcfsError("offline")`` when nothing listens and
    ``ProcfsError("listener_untrusted")`` when another user listens or /proc
    cannot be read.
    """
    try:
        records = listener_records(port, proc_root)
    except ProcfsError:
        raise ProcfsError("listener_untrusted")
    if not records:
        raise ProcfsError("offline")
    own = os.getuid()
    for _inode, uid in records:
        if uid != own:
            raise ProcfsError("listener_untrusted")


def listener_pid(port: int, proc_root: Path = Path("/proc")) -> int | None:
    """Return the same-uid PID owning a listener socket on ``port``."""
    try:
        inodes = listener_inodes(port, proc_root)
    except ProcfsError:
        return None
    if not inodes:
        return None
    own = os.getuid()
    try:
        entries = sorted(os.listdir(proc_root))
    except OSError:
        return None
    for entry in entries:
        if not entry.isdigit():
            continue
        pid_dir = proc_root / entry
        try:
            if os.stat(pid_dir).st_uid != own:
                continue
            fd_dir = pid_dir / "fd"
            fds = os.listdir(fd_dir)
        except (OSError, ValueError):
            continue
        for fd in fds:
            try:
                if os.readlink(fd_dir / fd) in inodes:
                    return int(entry)
            except (OSError, ValueError):
                continue
    return None


def _parse_stat(data: bytes) -> tuple[int, int] | None:
    """Return ``(ppid, startTime)`` from /proc/<pid>/stat bytes."""
    if not data:
        return None
    rparen = data.rfind(b")")
    if rparen < 0:
        return None
    fields = data[rparen + 2:].split()
    if len(fields) < 20:
        return None
    try:
        return int(fields[1]), int(fields[19])
    except (ValueError, IndexError):
        return None


def identity(
    pid: int, proc_root: Path = Path("/proc")
) -> dict[str, int] | None:
    """Return ``{"pid", "startTime"}`` for a same-uid process, else ``None``."""
    if not isinstance(pid, int) or isinstance(pid, bool) or pid <= 0:
        return None
    stat_path = proc_root / str(pid) / "stat"
    try:
        if os.stat(proc_root / str(pid)).st_uid != os.getuid():
            return None
        with open(stat_path, "rb") as handle:
            parsed = _parse_stat(handle.read(65536))
    except (OSError, ValueError):
        return None
    if parsed is None:
        return None
    _ppid, start_time = parsed
    if start_time < 0:
        return None
    return {"pid": pid, "startTime": start_time}


def ancestors(
    pid: int, limit: int = ANCESTOR_LIMIT, proc_root: Path = Path("/proc")
) -> list[dict[str, int]]:
    """Return same-uid ancestors starting with the parent (excludes ``pid``)."""
    if not isinstance(pid, int) or isinstance(pid, bool) or pid <= 1:
        return []
    chain: list[dict[str, int]] = []
    seen: set[int] = {pid}
    current = pid
    while len(chain) < limit:
        stat_path = proc_root / str(current) / "stat"
        try:
            if os.stat(proc_root / str(current)).st_uid != os.getuid():
                break
            with open(stat_path, "rb") as handle:
                parsed = _parse_stat(handle.read(65536))
        except (OSError, ValueError):
            break
        if parsed is None:
            break
        ppid, _start = parsed
        if ppid <= 0 or ppid in seen:
            break
        seen.add(ppid)
        parent = identity(ppid, proc_root)
        if parent is None:
            break
        chain.append(parent)
        current = ppid
    return chain


def peer_listener_uid(
    local_port: int,
    remote_port: int,
    proc_root: Path = Path("/proc"),
) -> int | None:
    """Return the UID of the local listener on ``remote_port``.

    The already-connected client socket (``getsockname()[1] == local_port``)
    must have a row whose remote port is ``remote_port``; otherwise ``None``.
    """
    try:
        local_hex = f"{local_port:04X}"
        remote_hex = f"{remote_port:04X}"
        connected = False
        listener_uid: int | None = None
        for name in ("tcp", "tcp6"):
            try:
                with open(proc_root / "net" / name, "r", encoding="utf-8") as handle:
                    lines = handle.read().splitlines()
            except (OSError, ValueError, UnicodeError):
                return None
            for line in lines[1:]:
                cols = line.split()
                if len(cols) < 10:
                    continue
                if _local_part(cols[1]) == local_hex and _local_part(cols[2]) == remote_hex:
                    connected = True
                if (
                    cols[3].upper() == LISTEN_STATE
                    and _local_part(cols[1]) == remote_hex
                    and _is_loopback_or_any(cols[1])
                ):
                    try:
                        listener_uid = int(cols[7])
                    except (ValueError, IndexError):
                        continue
    except (OSError, ValueError):
        return None
    if not connected:
        return None
    return listener_uid


def resolve_window_identities(
    pids: list[int], proc_root: Path = Path("/proc")
) -> list[dict[str, int]]:
    """Resolve window PIDs to ``identity()`` dicts (max 256, failures skipped)."""
    output: list[dict[str, int]] = []
    seen: set[int] = set()
    for pid in pids:
        if not isinstance(pid, int) or isinstance(pid, bool) or pid <= 0:
            continue
        if pid in seen or len(output) >= MAX_WINDOW_PIDS:
            continue
        seen.add(pid)
        found = identity(pid, proc_root)
        if found is not None:
            output.append(found)
    return output


def describe_listener_error(exc: BaseException) -> str:
    """Map a listener-check failure to a provider ``errorCode``."""
    if isinstance(exc, ProcfsError):
        if exc.code == "offline":
            return "server_not_running"
        return "listener_untrusted"
    return "listener_untrusted"
