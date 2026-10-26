# SPDX-License-Identifier: Apache-2.0
"""Read the T3 connection file written by ``dockrail t3 pair``.

Fail-closed: the file must be a 0600 regular file owned by the current user
inside a non-symlink directory owned by the current user with no group/other
permission bits. Anything else raises ``StoreError``; only a missing file
returns ``None``.
"""
from __future__ import annotations

import json
import os
import stat
from pathlib import Path
from typing import Any

from t3http import check_endpoint

MAX_STORE_BYTES = 64 * 1024

_REQUIRED_KEYS = (
    "version",
    "environmentId",
    "label",
    "url",
    "token",
    "expiresAt",
    "pairedAt",
)


class StoreError(Exception):
    """Connection-store failure carrying a short machine-readable code."""

    def __init__(self, code: str) -> None:
        super().__init__(code)
        self.code = code


def _reject_duplicates(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    result: dict[str, Any] = {}
    for key, value in pairs:
        if key in result:
            raise ValueError(f"duplicate key: {key!r}")
        result[key] = value
    return result


def _non_empty_string(value: object) -> bool:
    return isinstance(value, str) and len(value) > 0


def _epoch_seconds(value: object) -> bool:
    return isinstance(value, int) and not isinstance(value, bool) and value > 0


def load(path: str | Path) -> dict[str, Any] | None:
    """Load and validate the connection record, or return ``None`` if absent."""
    target = Path(path)
    try:
        os.lstat(target)
    except FileNotFoundError:
        return None
    except (OSError, ValueError):
        raise StoreError("store_untrusted")
    try:
        parent_stat = os.lstat(target.parent)
    except (OSError, ValueError):
        raise StoreError("store_untrusted")
    if not stat.S_ISDIR(parent_stat.st_mode):
        raise StoreError("store_untrusted")
    if stat.S_ISLNK(parent_stat.st_mode):
        raise StoreError("store_untrusted")
    if parent_stat.st_uid != os.getuid():
        raise StoreError("store_untrusted")
    if parent_stat.st_mode & 0o077:
        raise StoreError("store_untrusted")

    try:
        fd = os.open(target, os.O_RDONLY | os.O_NOFOLLOW)
    except FileNotFoundError:
        return None
    except (OSError, ValueError):
        raise StoreError("store_untrusted")
    try:
        # Adopt the descriptor before validating it: all rejection paths close it.
        with os.fdopen(fd, "r", encoding="utf-8") as handle:
            file_stat = os.fstat(handle.fileno())
            if not stat.S_ISREG(file_stat.st_mode):
                raise StoreError("store_untrusted")
            if file_stat.st_uid != os.getuid():
                raise StoreError("store_untrusted")
            if file_stat.st_mode & 0o077:
                raise StoreError("store_untrusted")
            if file_stat.st_size > MAX_STORE_BYTES:
                raise StoreError("store_untrusted")
            raw = handle.read(MAX_STORE_BYTES + 1)
    except StoreError:
        raise
    except (OSError, ValueError, UnicodeError):
        raise StoreError("store_untrusted")
    if len(raw) > MAX_STORE_BYTES:
        raise StoreError("store_untrusted")

    try:
        record = json.loads(raw, object_pairs_hook=_reject_duplicates)
    except (ValueError, UnicodeError):
        raise StoreError("store_invalid")
    if not isinstance(record, dict):
        raise StoreError("store_invalid")
    for key in _REQUIRED_KEYS:
        if key not in record:
            raise StoreError("store_invalid")
    version = record.get("version")
    if version != 1 or isinstance(version, bool):
        raise StoreError("store_invalid")
    if not _non_empty_string(record.get("environmentId")):
        raise StoreError("store_invalid")
    if not _non_empty_string(record.get("label")):
        raise StoreError("store_invalid")
    if not _non_empty_string(record.get("token")):
        raise StoreError("store_invalid")
    if not _epoch_seconds(record.get("expiresAt")):
        raise StoreError("store_invalid")
    if not _epoch_seconds(record.get("pairedAt")):
        raise StoreError("store_invalid")
    url = record.get("url")
    if not isinstance(url, str):
        raise StoreError("store_invalid")
    try:
        check_endpoint(url)
    except Exception:
        raise StoreError("store_invalid")
    return record
