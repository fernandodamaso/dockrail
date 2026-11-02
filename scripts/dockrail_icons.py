#!/usr/bin/env python3
"""Dockrail-managed custom-icon storage: the single artwork ingestion path.

Custom icon selections (Change Icon UI and ``icons set ID PATH``) copy the
supported local PNG/SVG into a persistent Dockrail-owned data directory
(``$XDG_DATA_HOME/dockrail/icons``) and persist the managed ``file://``
reference. The user's original file is never moved, modified or deleted.
Legacy in-place references are migrated on a best-effort basis; unreferenced
managed assets are pruned only when ownership and lack of references are
established.

The helper speaks one JSON line on stdout per invocation (like
``dockrail_migrate.py``) so QML hosts can consume it through a Process +
SplitParser. Exit status is 0 on success, 2 on usage/validation errors and 3
on runtime/storage errors.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import stat
import sys
import tempfile
import urllib.parse

sys.path.insert(0, str(Path(__file__).resolve().parent))
import dockrail_paths

API_VERSION = 1
MANAGED_NAME_PATTERN = re.compile(r"^[A-Za-z0-9._-]+-[0-9a-f]{12}\.(?:png|svg)$")
SOURCE_EXTENSION_PATTERN = re.compile(r"\.(?:png|svg)$", re.IGNORECASE)
CONTROL_CHARACTERS = re.compile(r"[\x00-\x1f\x7f]")
# Qt's encodeURIComponent leaves these unescaped; keep URL spelling identical
# to the QML validators so managed references round-trip through normalizeSource.
QUOTE_SAFE = "-_.!~*'()"


class IconStoreError(Exception):
    def __init__(self, code, message):
        super().__init__(message)
        self.code = code
        self.message = message


def _encode_segment(segment):
    return urllib.parse.quote(segment, safe=QUOTE_SAFE)


def _decode_segment(segment):
    # decodeURIComponent throws on malformed escapes; unquote forgives them.
    if re.search(r"%(?![0-9A-Fa-f]{2})", segment):
        return None
    try:
        return urllib.parse.unquote(segment, errors="strict")
    except UnicodeDecodeError:
        return None


def local_file_url(value):
    """Python twin of DockIconModel.localFileUrl: local absolute paths only."""
    if not isinstance(value, str) or not value:
        return ""
    path = value
    match = re.match(r"^file://(?:localhost)?(/[^?#]*)$", value, re.IGNORECASE)
    if match:
        decoded = _decode_segment(match.group(1))
        if decoded is None:
            return ""
        path = decoded
    if path[0] != "/" or CONTROL_CHARACTERS.search(path):
        return ""
    parts = []
    for segment in path.split("/"):
        if segment == "..":
            if parts:
                parts.pop()
        elif segment and segment != ".":
            parts.append(segment)
    suffix = "/" if path.endswith("/") and parts else ""
    return "file:///" + "/".join(_encode_segment(part) for part in parts) + suffix


def normalize_source(value):
    """Python twin of DockIconModel.normalizeSource: local PNG/SVG file URLs."""
    url = local_file_url(value)
    return url if SOURCE_EXTENSION_PATTERN.search(url) else ""


def managed_icon_dir(data_root):
    return Path(data_root) / "icons"


def resolve_data_root(explicit, environ=None):
    if explicit:
        return Path(explicit).expanduser().resolve(strict=False)
    paths = dockrail_paths.resolve_paths(os.environ if environ is None else environ)
    return paths.canonical_data_root.resolve(strict=False)


def managed_prefix(data_root):
    """Normalized file:// prefix of the managed icons directory."""
    root = Path(data_root).resolve(strict=False)
    parts = root.parts
    if parts and parts[0] == os.sep:
        return "file://" + os.sep + "/".join(
            _encode_segment(part) for part in parts[1:]) + "/icons/"
    return "file://" + "/".join(_encode_segment(part) for part in parts) + "/icons/"


def is_managed_source(source, data_root):
    """True when a normalized source URL already lives inside managed storage."""
    url = normalize_source(source)
    return bool(url) and url.startswith(managed_prefix(data_root))


def managed_file_name(key, content, extension):
    """Collision-safe, ownership-asserting asset name.

    The content hash dedups identical artwork across overrides and makes the
    name self-verifying; the sanitized override key is readable context only.
    """
    digest = hashlib.sha1(content).hexdigest()[:12]
    stem = re.sub(r"[^A-Za-z0-9._-]+", "-", str(key or "icon")).strip("-._") or "icon"
    return "%s-%s.%s" % (stem[:48], digest, extension.lower())


def is_managed_file_name(name):
    """Ownership predicate shared with DockIconModel.isManagedIconFileName.

    Only names this helper mints are ever deletion candidates.
    """
    return isinstance(name, str) and MANAGED_NAME_PATTERN.match(name) is not None


def _atomic_copy(source, destination):
    destination.parent.mkdir(parents=True, exist_ok=True)
    fd, temporary = tempfile.mkstemp(
        prefix=destination.name + ".", dir=str(destination.parent))
    try:
        with os.fdopen(fd, "wb") as stream:
            with open(source, "rb") as origin:
                shutil.copyfileobj(origin, stream, 1024 * 256)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, destination)
    except BaseException:
        try:
            os.unlink(temporary)
        except OSError:
            pass
        raise


def ingest_source(source, key="", data_root=None, environ=None):
    """Copy one supported local PNG/SVG into managed storage.

    Returns the managed ``file://`` URL. Idempotent for sources already in
    managed storage. Raises IconStoreError without creating any mapping on
    invalid input or copy failure; the original file is never modified.
    """
    root = resolve_data_root(data_root, environ)
    url = normalize_source(source)
    if not url:
        raise IconStoreError("E_VALIDATION", "Select a local PNG or SVG file.")
    source_path = Path(urllib.parse.unquote(urllib.parse.urlparse(url).path))
    try:
        resolved = source_path.resolve(strict=True)
    except OSError:
        raise IconStoreError("E_VALIDATION", "Artwork file does not exist: " + str(source_path))
    if not resolved.is_file():
        raise IconStoreError("E_VALIDATION", "Artwork path is not a regular file: " + str(resolved))
    if is_managed_source(url, root):
        return url
    try:
        content = resolved.read_bytes()
    except OSError as error:
        raise IconStoreError("E_PERSISTENCE", "Artwork file could not be read: " + str(error))
    extension = SOURCE_EXTENSION_PATTERN.search(resolved.name).group(0)[1:]
    name = managed_file_name(key, content, extension)
    destination = managed_icon_dir(root) / name
    try:
        if not destination.exists():
            _atomic_copy(resolved, destination)
        elif destination.read_bytes() != content:
            raise IconStoreError(
                "E_PERSISTENCE",
                "Managed artwork name collision for " + name + "; refusing to overwrite.")
    except IconStoreError:
        raise
    except OSError as error:
        raise IconStoreError("E_PERSISTENCE", "Artwork could not be copied into managed storage: " + str(error))
    return local_file_url(str(destination))


def _iter_override_sources(settings):
    """Yield (container, locator, source) for every custom icon mapping."""
    overrides = settings.get("iconOverrides")
    if isinstance(overrides, dict):
        for key, value in overrides.items():
            yield "iconOverrides", ("key", key), value
    rules = settings.get("windowIconOverrides")
    if isinstance(rules, list):
        for index, rule in enumerate(rules):
            if isinstance(rule, dict):
                yield "windowIconOverrides", ("index", index), rule.get("source")


def migrate_settings(settings, data_root=None, environ=None):
    """Best-effort migration of legacy in-place references to managed storage.

    Existing managed references are left untouched. References whose source
    file still exists are copied and reported as changes; missing sources are
    kept as-is so fallback display and removal keep working. Nothing is deleted.
    """
    root = resolve_data_root(data_root, environ)
    migrated = json.loads(json.dumps(settings))
    changed = []
    managed_by_source = {}
    for container, locator, source in list(_iter_override_sources(migrated)):
        url = normalize_source(source)
        if not url or is_managed_source(url, root):
            continue
        source_path = Path(urllib.parse.unquote(urllib.parse.urlparse(url).path))
        if not source_path.is_file():
            continue
        # One source file becomes one shared managed asset per run, so app,
        # profile and window overrides of the same artwork refcount together.
        managed = managed_by_source.get(str(source_path))
        if managed is None:
            key = locator[1] if container == "iconOverrides" else str(locator[1])
            try:
                managed = ingest_source(url, key=key, data_root=root)
            except IconStoreError:
                continue
            managed_by_source[str(source_path)] = managed
        if container == "iconOverrides":
            migrated["iconOverrides"][locator[1]] = managed
            changed.append({"container": container, "locator": locator[1],
                            "from": source, "to": managed})
        else:
            rule = migrated["windowIconOverrides"][locator[1]]
            rule["source"] = managed
            changed.append({"container": container,
                            "locator": {"appId": rule.get("appId"),
                                        "titlePattern": rule.get("titlePattern")},
                            "from": source, "to": managed})
    return migrated, changed


def referenced_managed_files(settings, data_root):
    """Managed file names still referenced by any override mapping."""
    root = Path(data_root)
    referenced = set()
    for _container, _locator, source in _iter_override_sources(settings):
        url = normalize_source(source)
        if not url or not is_managed_source(url, root):
            continue
        name = url.rstrip("/").rsplit("/", 1)[-1]
        if is_managed_file_name(name):
            referenced.add(name)
    return referenced


def prune_orphans(settings, data_root=None, environ=None):
    """Delete managed assets no longer referenced by any override.

    Only regular files inside the managed icons directory whose names match
    the ownership predicate are considered, and only when absent from the
    settings' referenced set. Source files outside managed storage are never
    touched. Returns the sorted list of removed file names.
    """
    root = resolve_data_root(data_root, environ)
    return prune_unreferenced(referenced_managed_files(settings, root), root)


def prune_unreferenced(keep_names, data_root):
    """Delete managed files absent from ``keep_names``; ownership-gated."""
    directory = managed_icon_dir(data_root)
    keep = set(keep_names or ())
    removed = []
    try:
        entries = list(directory.iterdir())
    except OSError:
        return removed
    for entry in entries:
        try:
            info = entry.lstat()
        except OSError:
            continue
        if not stat.S_ISREG(info.st_mode):
            continue
        if not is_managed_file_name(entry.name) or entry.name in keep:
            continue
        try:
            entry.unlink()
            removed.append(entry.name)
        except OSError:
            continue
    return sorted(removed)


def _reply(ok, data=None, error=None):
    envelope = {"apiVersion": API_VERSION, "ok": ok}
    if ok:
        envelope["data"] = data
    else:
        envelope["error"] = error
    return envelope


def _emit(envelope):
    sys.stdout.write(json.dumps(envelope, ensure_ascii=False, separators=(",", ":")) + "\n")
    sys.stdout.flush()


def _read_settings(path):
    try:
        raw = Path(path).read_text(encoding="utf-8")
    except (OSError, UnicodeError) as error:
        raise IconStoreError("E_VALIDATION", "Settings file could not be read: " + str(error))
    try:
        settings = json.loads(raw)
    except ValueError as error:
        raise IconStoreError("E_VALIDATION", "Settings file is not valid JSON: " + str(error))
    if not isinstance(settings, dict):
        raise IconStoreError("E_VALIDATION", "Settings file must contain a JSON object.")
    return settings


def main(argv=None):
    parser = argparse.ArgumentParser(prog="dockrail-icons", add_help=False)
    commands = parser.add_subparsers(dest="command")
    ingest = commands.add_parser("ingest", add_help=False)
    ingest.add_argument("--source", required=True)
    ingest.add_argument("--key", default="")
    migrate = commands.add_parser("migrate", add_help=False)
    migrate.add_argument("--config", required=True)
    prune = commands.add_parser("prune", add_help=False)
    prune.add_argument("--keep", nargs="*", default=[])
    for child in (ingest, migrate, prune):
        child.add_argument("--data-root", default=None)
    arguments = parser.parse_args(argv)
    try:
        data_root = resolve_data_root(arguments.data_root)
        if arguments.command == "ingest":
            managed = ingest_source(
                arguments.source, key=arguments.key, data_root=data_root)
            _emit(_reply(True, {"source": managed, "managed": True}))
        elif arguments.command == "migrate":
            settings = _read_settings(arguments.config)
            migrated, changed = migrate_settings(settings, data_root=data_root)
            _emit(_reply(True, {"changed": changed, "settings": migrated}))
        elif arguments.command == "prune":
            removed = prune_unreferenced(set(arguments.keep), data_root)
            _emit(_reply(True, {"removed": removed}))
        else:
            raise IconStoreError("E_USAGE", "Expected ingest, migrate or prune.")
        return 0
    except IconStoreError as error:
        _emit(_reply(False, error={"code": error.code, "message": error.message}))
        return 2 if error.code in ("E_USAGE", "E_VALIDATION") else 3


if __name__ == "__main__":
    sys.exit(main())
