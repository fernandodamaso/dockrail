#!/usr/bin/env python3
"""Managed PNG/SVG artwork for Dockrail. Never writes dock.json.

All commands are stdlib-only so the same helper can be used from the CLI and
the host's asynchronous Change Icon chooser. Data lives in XDG_DATA_HOME.
"""
from __future__ import annotations

import hashlib
import json
import os
from pathlib import Path
import re
import stat
import sys
import tempfile
import zlib
from urllib.parse import unquote, urlsplit
import xml.etree.ElementTree as ET

MAX_BYTES = 8 * 1024 * 1024
MANAGED_NAME = re.compile(r"^[0-9a-f]{64}\.(?:png|svg)$")
PNG_MAGIC = b"\x89PNG\r\n\x1a\n"
SVG_NS = "{http://www.w3.org/2000/svg}svg"
GC_GRACE_SECONDS = 120


class IconAssetError(ValueError):
    pass


def icon_directory(env=None):
    env = os.environ if env is None else env
    home = Path(env.get("HOME") or str(Path.home()))
    data_home = Path(env.get("XDG_DATA_HOME") or str(home / ".local/share"))
    return data_home / "dockrail" / "icons"


def source_path(value):
    if not isinstance(value, str) or not value or any(ord(c) < 32 or ord(c) == 127 for c in value):
        raise IconAssetError("Invalid local artwork path")
    if re.match(r"^[A-Za-z][A-Za-z0-9+.-]*:", value):
        parts = urlsplit(value)
        if parts.scheme.lower() != "file" or parts.netloc not in ("", "localhost") or parts.query or parts.fragment:
            raise IconAssetError("Only local file URLs are supported")
        if re.search(r"%(?![0-9a-fA-F]{2})", parts.path):
            raise IconAssetError("Invalid file URL encoding")
        value = unquote(parts.path)
    path = Path(value)
    if not path.is_absolute() or "\x00" in value:
        raise IconAssetError("Artwork path must be absolute")
    return path


def _validate_bytes(data, extension):
    if not data or len(data) > MAX_BYTES:
        raise IconAssetError("Artwork must be between 1 byte and 8 MiB")
    if extension == ".png":
        # A signature-only file is not an image. Check complete chunk framing,
        # CRCs, a nonzero IHDR and the IDAT/IEND sequence before publishing.
        # Actual Qt decoding remains a separate, non-guaranteed observation.
        if not data.startswith(PNG_MAGIC):
            raise IconAssetError("Invalid PNG signature")
        offset = len(PNG_MAGIC)
        seen_image = False
        seen_end = False
        first = True
        while offset + 12 <= len(data):
            length = int.from_bytes(data[offset:offset + 4], "big")
            end = offset + length + 12
            if end > len(data):
                raise IconAssetError("Truncated PNG chunk")
            kind = data[offset + 4:offset + 8]
            payload = data[offset + 8:offset + 8 + length]
            checksum = int.from_bytes(data[end - 4:end], "big")
            if zlib.crc32(kind + payload) & 0xffffffff != checksum:
                raise IconAssetError("Invalid PNG checksum")
            if first:
                if kind != b"IHDR" or length != 13:
                    raise IconAssetError("PNG missing IHDR")
                width = int.from_bytes(payload[0:4], "big")
                height = int.from_bytes(payload[4:8], "big")
                if not width or not height or width > 16384 or height > 16384:
                    raise IconAssetError("Unsupported PNG dimensions")
                first = False
            elif kind == b"IHDR":
                raise IconAssetError("Duplicate PNG header")
            if kind == b"IDAT":
                seen_image = True
            if kind == b"IEND":
                if length or not seen_image or end != len(data):
                    raise IconAssetError("Invalid PNG end marker")
                seen_end = True
                break
            offset = end
        if not seen_end:
            raise IconAssetError("Incomplete PNG image")
    elif extension == ".svg":
        # Block DTD/entity declarations; ElementTree itself does not resolve
        # remote resources. Do not attempt to sanitize or rewrite user SVGs.
        if re.search(rb"<!\s*(?:DOCTYPE|ENTITY)\b", data, re.IGNORECASE):
            raise IconAssetError("SVG document declarations are unsupported")
        try:
            document = ET.fromstring(data)
        except ET.ParseError as exc:
            raise IconAssetError("Invalid SVG document") from exc
        if document.tag not in ("svg", SVG_NS):
            raise IconAssetError("Expected an SVG root element")
    else:
        raise IconAssetError("Choose a PNG or SVG file")


def _open_source(path):
    if path.suffix.lower() not in (".png", ".svg"):
        raise IconAssetError("Choose a PNG or SVG file")
    try:
        # No symlink traversal when reading user artwork.
        fd = os.open(path, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0))
        with os.fdopen(fd, "rb") as stream:
            if not stat.S_ISREG(os.fstat(stream.fileno()).st_mode):
                raise IconAssetError("Artwork must be a regular file")
            data = stream.read(MAX_BYTES + 1)
    except OSError as exc:
        raise IconAssetError("Could not read the chosen artwork") from exc
    _validate_bytes(data, path.suffix.lower())
    return data


def ingest(source, env=None):
    path = source_path(source)
    managed_dir = icon_directory(env)
    if managed_dir.is_symlink():
        raise IconAssetError("Managed icon directory must not be a symlink")
    # Existing managed paths use exactly the same validation; no separate
    # shortcut bypasses validation or hash/filename checks.
    data = _open_source(path)
    extension = path.suffix.lower()
    target = managed_dir / (hashlib.sha256(data).hexdigest() + extension)
    if path == target:
        return target.as_uri()
    managed_dir.mkdir(mode=0o700, parents=True, exist_ok=True)
    if target.is_symlink():
        raise IconAssetError("Managed artwork destination is not a regular file")
    if target.exists():
        if _open_source(target) != data:
            raise IconAssetError("Managed artwork has unexpected contents")
        return target.as_uri()
    fd, staged = tempfile.mkstemp(prefix=".incoming-", dir=str(managed_dir))
    try:
        with os.fdopen(fd, "wb") as stream:
            stream.write(data)
            stream.flush()
            os.fsync(stream.fileno())
        os.chmod(staged, 0o600)
        # Hard-link publication is atomic and never clobbers an existing
        # content-addressed entry, even when two icon saves race each other.
        try:
            os.link(staged, target, follow_symlinks=False)
        except FileExistsError:
            if target.is_symlink() or _open_source(target) != data:
                raise IconAssetError("Managed artwork destination changed")
        else:
            dirfd = os.open(managed_dir, os.O_RDONLY)
            try:
                os.fsync(dirfd)
            finally:
                os.close(dirfd)
        return target.as_uri()
    finally:
        if staged and os.path.exists(staged):
            os.unlink(staged)


def _source_values(settings):
    values = []
    icons = settings.get("iconOverrides")
    if isinstance(icons, dict):
        values.extend(value for value in icons.values() if isinstance(value, str))
    rules = settings.get("windowIconOverrides")
    if isinstance(rules, list):
        values.extend(row.get("source") for row in rules
                      if isinstance(row, dict) and isinstance(row.get("source"), str))
    return values


def migration(config_path, env=None):
    # Read-only to the configuration: DockHost still validates and commits any
    # patch through its one FileView writer, with a current-snapshot check.
    raw = json.loads(Path(config_path).read_text(encoding="utf-8"))
    if not isinstance(raw, dict):
        raise IconAssetError("Configuration must be a JSON object")
    expected_icons = raw.get("iconOverrides", {})
    expected_rules = raw.get("windowIconOverrides", [])
    new_icons = dict(expected_icons) if isinstance(expected_icons, dict) else None
    new_rules = [dict(row) if isinstance(row, dict) else row
                 for row in expected_rules] if isinstance(expected_rules, list) else None
    changed = False
    if new_icons is not None:
        for key, source in new_icons.items():
            if not isinstance(source, str):
                continue
            try:
                updated = ingest(source, env)
            except (IconAssetError, OSError):
                continue  # Missing sources must remain removable, not vanish.
            if updated != source:
                new_icons[key] = updated
                changed = True
    if new_rules is not None:
        for row in new_rules:
            if not isinstance(row, dict) or not isinstance(row.get("source"), str):
                continue
            try:
                updated = ingest(row["source"], env)
            except (IconAssetError, OSError):
                continue
            if updated != row["source"]:
                row["source"] = updated
                changed = True
    return {
        "expected": {"iconOverrides": expected_icons, "windowIconOverrides": expected_rules},
        "patch": ({"iconOverrides": new_icons, "windowIconOverrides": new_rules} if changed else {}),
    }


def collect(config_path, env=None, *, now=None):
    import time
    # No config -> do not guess reachability or delete anything.
    settings = json.loads(Path(config_path).read_text(encoding="utf-8"))
    if not isinstance(settings, dict):
        raise IconAssetError("Configuration must be a JSON object")
    managed_dir = icon_directory(env)
    if not managed_dir.is_dir() or managed_dir.is_symlink():
        return []
    live = set()
    for source in _source_values(settings):
        try:
            path = source_path(source)
        except IconAssetError:
            continue
        if path.parent == managed_dir and MANAGED_NAME.fullmatch(path.name):
            live.add(path.name)
    current = time.time() if now is None else now
    removed = []
    for entry in managed_dir.iterdir():
        if not MANAGED_NAME.fullmatch(entry.name) or entry.name in live or entry.is_symlink():
            continue
        metadata = entry.lstat()
        if (stat.S_ISREG(metadata.st_mode)
                and current - metadata.st_mtime >= GC_GRACE_SECONDS):
            entry.unlink()
            removed.append(entry.name)
    return sorted(removed)


def main(argv=None):
    args = sys.argv[1:] if argv is None else argv
    try:
        if len(args) != 2 or args[0] not in ("ingest", "migrate", "collect"):
            raise IconAssetError("Usage: dockrail_icon_assets.py ingest|migrate|collect ARG")
        command, value = args
        if command == "ingest":
            output = {"source": ingest(value)}
        elif command == "migrate":
            output = migration(value)
        else:
            output = {"removed": collect(value)}
        print(json.dumps(output, ensure_ascii=False))
        return 0
    except (IconAssetError, OSError, ValueError, TypeError) as exc:
        print(str(exc), file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
