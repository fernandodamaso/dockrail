#!/usr/bin/env python3
"""Dockrail Widget package API v1 manager.

Owns external Widget source scaffolds, installed package snapshots and development
overrides. It never writes dock.json and never mutates the Dockrail source or
installed Omarchy plugin checkout.
"""
from __future__ import annotations

import argparse
import contextlib
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
import time
import uuid

API_VERSION = 1
REGISTRY_SCHEMA_VERSION = 1
STATE_SCHEMA_VERSION = 1
PLUGIN_ID = "io.github.fernandodamaso.dockrail"
LEGACY_PLUGIN_ID = "io.github.fernandodamaso.smartdock"
ID_RE = re.compile(r"^[a-z][a-z0-9]*(?:[._-][a-z0-9]+)*$")
ICON_RE = re.compile(r"^[a-z0-9](?:[a-z0-9-]{0,62}[a-z0-9])?$")
VERSION_RE = re.compile(r"^[0-9A-Za-z](?:[0-9A-Za-z.+_-]{0,62}[0-9A-Za-z])?$")
MAX_PACKAGE_FILES = 256
MAX_REGISTRY_PACKAGES = 128
MAX_PACKAGE_BYTES = 8 * 1024 * 1024
MAX_FILE_BYTES = 2 * 1024 * 1024
PROTECTED_WIDGETS = {
    "demo.display": ("Demo - Display", "built-in", True),
    "demo.lists": ("Demo - Lists", "built-in", True),
    "demo.inputs": ("Demo - Inputs", "built-in", True),
    "demo.actions-states": ("Demo - Actions & states", "built-in", True),
    "herdr.agents": ("Coding agents", "integration", False),
}
RESERVED_PACKAGE_FILES = {".smartdock-source.json", ".smartdock-package.json"}
RUNTIME_WIDGETKIT_DIR = "Dockrail"
LEGACY_RUNTIME_WIDGETKIT_DIR = "SmartDock"
RUNTIME_WIDGETKIT_DIRS = {RUNTIME_WIDGETKIT_DIR, LEGACY_RUNTIME_WIDGETKIT_DIR}
WIDGETKIT_IMPORT_RE = re.compile(
    r"^(?P<indent>\s*)import\s+(?:Dockrail|SmartDock)[.]WidgetKit\s+1[.]0"
    r"(?P<alias>\s+as\s+[A-Za-z_][A-Za-z0-9_]*)?"
    r"(?P<comment>\s*//.*)?\s*\Z"
)


class WidgetError(Exception):
    def __init__(self, code: str, message: str, data=None):
        super().__init__(message)
        self.code = code
        self.data = {} if data is None else data


def envelope(data, warnings=None):
    return {
        "apiVersion": API_VERSION,
        "ok": True,
        "data": data,
        "warnings": [] if warnings is None else warnings,
    }


def error_envelope(error: WidgetError):
    return {
        "apiVersion": API_VERSION,
        "ok": False,
        "error": {"code": error.code, "message": str(error)},
        "data": error.data,
        "warnings": [],
    }


def _object_without_duplicates(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError("duplicate key: " + str(key))
        result[key] = value
    return result


def read_json(path: Path, label: str):
    try:
        raw = path.read_bytes()
        if len(raw) > MAX_FILE_BYTES:
            raise WidgetError("E_VALIDATION", f"{label} exceeds the {MAX_FILE_BYTES}-byte limit.")
        return json.loads(raw.decode("utf-8"), object_pairs_hook=_object_without_duplicates)
    except WidgetError:
        raise
    except (OSError, UnicodeError, ValueError) as error:
        raise WidgetError("E_VALIDATION", f"{label} is not valid UTF-8 JSON: {error}") from error


def write_json_atomic(path: Path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    payload = json.dumps(value, ensure_ascii=False, allow_nan=False, indent=2) + "\n"
    temporary = path.with_name(f".{path.name}.tmp-{os.getpid()}-{uuid.uuid4().hex}")
    try:
        with temporary.open("x", encoding="utf-8") as stream:
            os.chmod(temporary, 0o600)
            stream.write(payload)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, path)
    finally:
        temporary.unlink(missing_ok=True)


def valid_widget_id(widget_id):
    return (
        isinstance(widget_id, str)
        and 0 < len(widget_id) <= 64
        and ID_RE.fullmatch(widget_id) is not None
        and widget_id not in {"constructor", "prototype", "__proto__"}
    )


def _resolved_candidate(path: Path):
    path = path.expanduser()
    if path.exists() or path.is_symlink():
        return path.resolve()
    parent = path.parent.resolve()
    return parent / path.name


def _is_within(path: Path, root: Path):
    return path == root or path.is_relative_to(root)


def validate_manifest(package_root: Path, *, allow_protected=False, allow_runtime_widgetkit=False):
    root = package_root.resolve()
    manifest_path = root / "widget.json"
    manifest = read_json(manifest_path, "widget.json")
    if not isinstance(manifest, dict):
        raise WidgetError("E_VALIDATION", "widget.json must contain one JSON object.")
    allowed = {"apiVersion", "id", "name", "version", "entry", "icon"}
    unknown = sorted(set(manifest) - allowed)
    if unknown:
        raise WidgetError("E_VALIDATION", "Unsupported widget.json fields: " + ", ".join(unknown))
    if type(manifest.get("apiVersion")) is not int or manifest["apiVersion"] != API_VERSION:
        raise WidgetError(
            "E_INCOMPATIBLE",
            f"Unsupported Widget package API version {manifest.get('apiVersion')!r}; Dockrail supports v{API_VERSION}.",
        )
    widget_id = manifest.get("id")
    if not valid_widget_id(widget_id):
        raise WidgetError("E_VALIDATION", "Widget id must be a valid stable lower-case ID (maximum 64 characters).")
    if not allow_protected and widget_id in PROTECTED_WIDGETS:
        raise WidgetError("E_PROTECTED", f"Widget id {widget_id!r} is owned by Dockrail and cannot be replaced externally.")
    name = manifest.get("name")
    if not isinstance(name, str) or not name.strip() or len(name.strip()) > 128:
        raise WidgetError("E_VALIDATION", "Widget name must be a non-empty string up to 128 characters.")
    version = manifest.get("version")
    if not isinstance(version, str) or VERSION_RE.fullmatch(version) is None:
        raise WidgetError("E_VALIDATION", "Widget version must be a compact package version string.")
    icon = manifest.get("icon")
    if not isinstance(icon, str) or ICON_RE.fullmatch(icon) is None:
        raise WidgetError("E_VALIDATION", "Widget icon must be a Lucide-style lower-case icon name.")
    entry = manifest.get("entry")
    if not isinstance(entry, str) or not entry or len(entry) > 160 or "\x00" in entry:
        raise WidgetError("E_VALIDATION", "Widget entry must be a relative QML path.")
    relative_entry = Path(entry)
    if relative_entry.is_absolute() or any(part in ("", ".", "..") for part in relative_entry.parts):
        raise WidgetError("E_VALIDATION", "Widget entry must stay inside the package and may not contain traversal segments.")
    if relative_entry.suffix.lower() != ".qml":
        raise WidgetError("E_VALIDATION", "Widget entry must reference a .qml file.")
    entry_path = (root / relative_entry).resolve()
    if not _is_within(entry_path, root) or not entry_path.is_file():
        raise WidgetError("E_VALIDATION", "Widget entry is missing or resolves outside the package.")
    runtime_widgetkits = [root / name for name in RUNTIME_WIDGETKIT_DIRS]
    if not allow_runtime_widgetkit and any(path.exists() or path.is_symlink() for path in runtime_widgetkits):
        raise WidgetError(
            "E_VALIDATION",
            "Widget source may not provide reserved Dockrail/SmartDock runtime module directories."
        )
    scan_package(root, ignored_root_names=RUNTIME_WIDGETKIT_DIRS if allow_runtime_widgetkit else None)
    normalized = {
        "apiVersion": API_VERSION,
        "id": widget_id,
        "name": name.strip(),
        "version": version,
        "entry": relative_entry.as_posix(),
        "icon": icon,
    }
    return normalized


def scan_package(root: Path, ignored_root_names=None):
    count = 0
    total = 0
    ignored_root_names = set(ignored_root_names or ())
    try:
        for directory, dirnames, filenames in os.walk(root, followlinks=False):
            directory_path = Path(directory)
            ignored = ignored_root_names if directory_path == root else set()
            dirnames[:] = sorted(name for name in dirnames if name != ".git" and name not in ignored)
            for name in list(dirnames):
                path = directory_path / name
                if path.is_symlink():
                    raise WidgetError("E_VALIDATION", f"Widget packages may not contain symlink directories: {path.relative_to(root)}")
            for name in sorted(filenames):
                if name in RESERVED_PACKAGE_FILES or name == ".git":
                    continue
                path = directory_path / name
                if path.is_symlink():
                    raise WidgetError("E_VALIDATION", f"Widget packages may not contain symlink files: {path.relative_to(root)}")
                if not path.is_file():
                    raise WidgetError("E_VALIDATION", f"Widget package contains a non-regular file: {path.relative_to(root)}")
                size = path.stat().st_size
                if size > MAX_FILE_BYTES:
                    raise WidgetError("E_VALIDATION", f"Widget file exceeds the {MAX_FILE_BYTES}-byte limit: {path.relative_to(root)}")
                count += 1
                total += size
                if count > MAX_PACKAGE_FILES or total > MAX_PACKAGE_BYTES:
                    raise WidgetError("E_VALIDATION", "Widget package exceeds the bounded file-count or total-size limit.")
    except OSError as error:
        raise WidgetError("E_VALIDATION", "Could not inspect Widget package: " + str(error)) from error
    return {"files": count, "bytes": total}


def package_digest(root: Path, manifest):
    digest = hashlib.sha256()
    digest.update(json.dumps(manifest, sort_keys=True, separators=(",", ":")).encode("utf-8"))
    for directory, dirnames, filenames in os.walk(root, followlinks=False):
        directory_path = Path(directory)
        ignored = RUNTIME_WIDGETKIT_DIRS if directory_path == root else set()
        dirnames[:] = sorted(name for name in dirnames if name != ".git" and name not in ignored)
        for name in sorted(filenames):
            if name in RESERVED_PACKAGE_FILES or name == ".git":
                continue
            path = directory_path / name
            relative = path.relative_to(root).as_posix()
            digest.update(relative.encode("utf-8") + b"\0")
            with path.open("rb") as stream:
                while True:
                    chunk = stream.read(65536)
                    if not chunk:
                        break
                    digest.update(chunk)
    return digest.hexdigest()


def copy_package(source: Path, destination: Path):
    scan_package(source)

    def ignore(directory, names):
        ignored = []
        ignored.extend(name for name in names if name in RESERVED_PACKAGE_FILES)
        if ".git" in names:
            ignored.append(".git")
        return ignored

    shutil.copytree(source, destination, symlinks=False, ignore=ignore)


def is_git_source(text: str):
    return text.startswith(("https://", "ssh://", "git@"))


class Store:
    def __init__(self, *, bundle=None, home=None, data_home=None, config_home=None, qml_import_paths=None):
        self.bundle = Path(bundle or Path(__file__).resolve().parents[1]).resolve()
        self.home = Path(home or Path.home()).resolve()
        self.data_home = Path(data_home or os.environ.get("XDG_DATA_HOME", self.home / ".local/share")).expanduser().resolve()
        self.config_home = Path(config_home or os.environ.get("XDG_CONFIG_HOME", self.home / ".config")).expanduser().resolve()
        self.canonical_root = self.data_home / "dockrail/widgets"
        self.legacy_root = self.data_home / "smartdock/widgets"
        # Startup migration owns legacy aliases. New package writes must match
        # the host registry root even when an empty legacy directory survives.
        self.root = self.canonical_root
        self.registry_path = self.root / "registry.json"
        self.dev_state_path = self.root / ".dev-state.json"
        self.dev_root = self.root / ".dev"
        self.lock_path = self.root / ".package.lock"
        canonical_config = self.config_home / "dockrail/dock.json"
        legacy_config = self.config_home / "smartdock/dock.json"
        canonical_override = os.environ.get("DOCKRAIL_CONFIG", "")
        legacy_override = os.environ.get("SMARTDOCK_CONFIG", "")
        if canonical_override:
            self.config_path = Path(canonical_override).expanduser()
        elif legacy_override:
            self.config_path = Path(legacy_override).expanduser()
        elif canonical_config.exists() or not legacy_config.exists():
            self.config_path = canonical_config
        else:
            self.config_path = legacy_config
        self.qml_import_paths = [Path(path).expanduser().resolve() for path in (qml_import_paths or [])]

    def _qml_tool(self, name):
        found = shutil.which(name)
        if found:
            return found
        fallback = Path("/usr/lib/qt6/bin") / name
        return str(fallback) if fallback.is_file() else None

    def _runtime_qml_import_paths(self):
        paths = list(self.qml_import_paths)
        for variable in ("QML_IMPORT_PATH", "QML2_IMPORT_PATH"):
            value = os.environ.get(variable, "")
            if value:
                paths.extend(Path(item).expanduser().resolve() for item in value.split(os.pathsep) if item)
        omarchy_shell = Path(os.environ.get("OMARCHY_PATH", "/usr/share/omarchy")) / "shell"
        if (omarchy_shell / "Commons").is_dir():
            cache_home = Path(os.environ.get("XDG_CACHE_HOME", self.home / ".cache")).expanduser().resolve()
            import_root = cache_home / "dockrail/qml-imports"
            import_root.mkdir(parents=True, exist_ok=True)
            qs_link = import_root / "qs"
            if not qs_link.exists() and not qs_link.is_symlink():
                try:
                    qs_link.symlink_to(omarchy_shell, target_is_directory=True)
                except OSError:
                    pass
            if qs_link.exists():
                paths.append(import_root)
        result = []
        for path in paths:
            if path not in result:
                result.append(path)
        return result

    def _materialize_widgetkit(self, package_root: Path):
        source_qmldir = self.bundle / "Dockrail/WidgetKit/qmldir"
        legacy_qmldir = self.bundle / "SmartDock/WidgetKit/qmldir"
        if not source_qmldir.is_file() or not legacy_qmldir.is_file():
            raise WidgetError("E_STATE", "Dockrail/SmartDock WidgetKit runtime files are missing from this CLI bundle.")
        target_root = package_root / RUNTIME_WIDGETKIT_DIR / "WidgetKit"
        if target_root.exists() or target_root.is_symlink():
            shutil.rmtree(package_root / RUNTIME_WIDGETKIT_DIR, ignore_errors=True)
        target_root.mkdir(parents=True, exist_ok=True)
        output = []
        try:
            for raw_line in source_qmldir.read_text(encoding="utf-8").splitlines():
                line = raw_line.strip()
                if not line:
                    continue
                if line.startswith("module "):
                    # Installed/dev snapshots use a relative directory import so
                    # dynamically loaded QML does not depend on engine-global paths.
                    continue
                fields = line.split()
                if len(fields) != 3:
                    raise WidgetError("E_STATE", "Dockrail WidgetKit qmldir contains an unsupported entry.")
                type_name, version, relative_source = fields
                source_file = (source_qmldir.parent / relative_source).resolve()
                widget_root = (self.bundle / "components/widgets").resolve()
                if not _is_within(source_file, widget_root) or not source_file.is_file():
                    raise WidgetError("E_STATE", "Dockrail WidgetKit references a missing public component.")
                target_file = target_root / source_file.name
                shutil.copy2(source_file, target_file)
                output.append(f"{type_name} {version} {target_file.name}")
            (target_root / "qmldir").write_text("\n".join(output) + "\n", encoding="utf-8")
        except WidgetError:
            raise
        except (OSError, UnicodeError) as error:
            raise WidgetError("E_STATE", "Could not materialize Dockrail WidgetKit: " + str(error)) from error

    def _rewrite_widgetkit_imports(self, package_root: Path):
        runtime_root = (package_root / RUNTIME_WIDGETKIT_DIR / "WidgetKit").resolve()
        if not runtime_root.is_dir():
            raise WidgetError("E_STATE", "Dockrail WidgetKit runtime directory is missing.")
        try:
            qml_files = sorted(package_root.rglob("*.qml"))
        except OSError as error:
            raise WidgetError("E_VALIDATION", "Could not enumerate Widget QML files: " + str(error)) from error
        for qml_file in qml_files:
            resolved = qml_file.resolve()
            if _is_within(resolved, runtime_root):
                continue
            try:
                raw = qml_file.read_text(encoding="utf-8")
            except (OSError, UnicodeError) as error:
                raise WidgetError("E_VALIDATION", "Widget QML must be readable UTF-8: " + str(qml_file)) from error
            lines = raw.splitlines(keepends=True)
            changed = False
            rewritten = []
            for line in lines:
                body = line.rstrip("\r\n")
                newline = line[len(body):]
                match = WIDGETKIT_IMPORT_RE.fullmatch(body)
                if not match:
                    rewritten.append(line)
                    continue
                relative = os.path.relpath(runtime_root, qml_file.parent).replace(os.sep, "/")
                if not relative.startswith("."):
                    relative = "./" + relative
                alias = match.group("alias") or ""
                comment = match.group("comment") or ""
                rewritten.append(
                    f'{match.group("indent")}import "{relative}"{alias}{comment}{newline}'
                )
                changed = True
            if changed:
                try:
                    qml_file.write_text("".join(rewritten), encoding="utf-8")
                except OSError as error:
                    raise WidgetError("E_VALIDATION", "Could not prepare Widget runtime QML: " + str(qml_file)) from error

    def _validate_qml_entry(self, package_root: Path, manifest):
        entry = package_root / manifest["entry"]
        formatter = self._qml_tool("qmlformat")
        linter = self._qml_tool("qmllint")
        if not formatter and not linter:
            raise WidgetError(
                "E_VALIDATION",
                "Qt QML validation tools are unavailable; previous Widget state was preserved."
            )
        if formatter:
            try:
                result = subprocess.run(
                    [formatter, str(entry)],
                    stdin=subprocess.DEVNULL,
                    stdout=subprocess.PIPE,
                    stderr=subprocess.PIPE,
                    text=True,
                    timeout=15,
                    check=False,
                )
            except (OSError, subprocess.SubprocessError) as error:
                raise WidgetError("E_VALIDATION", "Could not validate Widget entry QML syntax.") from error
            if result.returncode != 0:
                raise WidgetError("E_VALIDATION", "Widget entry QML syntax validation failed; previous Widget state was preserved.")
        if linter:
            command = [linter, "--ignore-settings"]
            for import_path in self._runtime_qml_import_paths():
                command.extend(["-I", str(import_path)])
            command.append(str(entry))
            try:
                result = subprocess.run(
                    command,
                    stdin=subprocess.DEVNULL,
                    stdout=subprocess.PIPE,
                    stderr=subprocess.PIPE,
                    text=True,
                    timeout=20,
                    check=False,
                )
            except (OSError, subprocess.SubprocessError) as error:
                raise WidgetError("E_VALIDATION", "Could not validate Widget QML imports.") from error
            diagnostics = (result.stdout or "") + "\n" + (result.stderr or "")
            import_failure = re.search(
                r"failed to import\s+[A-Za-z0-9_.]+|module\s+[\"']?[A-Za-z0-9_.]+[\"']?\s+is not installed",
                diagnostics,
                re.IGNORECASE,
            )
            if import_failure:
                raise WidgetError(
                    "E_VALIDATION",
                    "Widget entry QML import validation failed; previous Widget state was preserved."
                )

    def _validate_installed(self, package_dir: Path):
        if package_dir.is_symlink():
            raise WidgetError("E_VALIDATION", "Installed Widget package directory may not be a symlink.")
        return validate_manifest(package_dir, allow_runtime_widgetkit=True)

    def forbidden_source_roots(self):
        roots = [
            self.home / ".config/omarchy/plugins" / PLUGIN_ID,
            self.home / ".config/omarchy/plugins" / LEGACY_PLUGIN_ID,
            self.data_home / "dockrail",
            self.data_home / "smartdock",
            self.bundle,
        ]
        source_record = self.bundle / ".source-dir"
        if source_record.is_file():
            try:
                recorded = Path(source_record.read_text(encoding="utf-8").strip()).expanduser()
                if str(recorded):
                    roots.append(recorded)
            except (OSError, UnicodeError):
                pass
        result = []
        for root in roots:
            try:
                resolved = _resolved_candidate(root)
            except (OSError, RuntimeError):
                continue
            if resolved not in result:
                result.append(resolved)
        return result

    def source_preflight(self, source: Path):
        try:
            resolved = _resolved_candidate(source)
        except (OSError, RuntimeError) as error:
            raise WidgetError("E_SOURCE", "Could not resolve Widget source path: " + str(error)) from error
        for forbidden in self.forbidden_source_roots():
            if _is_within(resolved, forbidden):
                raise WidgetError(
                    "E_SOURCE_FORBIDDEN",
                    "Refusing Widget source under deployed/read-only Dockrail state: "
                    + str(forbidden)
                    + ". Custom Widget source must live in a separate directory/repository. "
                    "Use `dockrail widget create ...` outside Dockrail, then `dockrail widget install <source>` "
                    "or `dockrail widget dev use <source>`.",
                    {"source": str(resolved), "forbiddenRoot": str(forbidden)},
                )
        return resolved

    @contextlib.contextmanager
    def locked(self):
        self.root.mkdir(parents=True, exist_ok=True)
        with self.lock_path.open("a+", encoding="utf-8") as stream:
            try:
                fcntl.flock(stream.fileno(), fcntl.LOCK_EX)
                yield
            finally:
                fcntl.flock(stream.fileno(), fcntl.LOCK_UN)

    @contextlib.contextmanager
    def resolved_source(self, source_spec: str, *, development=False):
        if development and is_git_source(source_spec):
            raise WidgetError("E_SOURCE", "Widget development requires a local source directory; install may use an explicit repository URL.")
        if is_git_source(source_spec):
            temporary = Path(tempfile.mkdtemp(prefix="smartdock-widget-source-"))
            checkout = temporary / "source"
            try:
                try:
                    subprocess.run(
                        ["git", "clone", "--depth", "1", "--", source_spec, str(checkout)],
                        stdin=subprocess.DEVNULL,
                        stdout=subprocess.PIPE,
                        stderr=subprocess.PIPE,
                        text=True,
                        timeout=120,
                        check=True,
                    )
                except FileNotFoundError as error:
                    raise WidgetError("E_SOURCE", "git is required to install a repository Widget source.") from error
                except subprocess.TimeoutExpired as error:
                    raise WidgetError("E_SOURCE", "Repository Widget source clone timed out.") from error
                except subprocess.CalledProcessError as error:
                    # Do not surface clone stderr: an explicit repository URL may
                    # contain credentials and package diagnostics must not echo them.
                    raise WidgetError("E_SOURCE", "Could not clone explicit Widget repository source.") from error
                resolved = self.source_preflight(checkout)
                yield resolved, {"type": "git", "location": source_spec}
            finally:
                shutil.rmtree(temporary, ignore_errors=True)
            return
        path = Path(source_spec).expanduser()
        resolved = self.source_preflight(path)
        if not resolved.is_dir():
            raise WidgetError("E_SOURCE", "Widget source directory does not exist: " + str(resolved))
        yield resolved, {"type": "local", "location": str(resolved)}

    def create(self, widget_id: str, name=None, destination=None):
        if not valid_widget_id(widget_id):
            raise WidgetError("E_VALIDATION", "Widget id must be a valid stable lower-case ID (maximum 64 characters).")
        if widget_id in PROTECTED_WIDGETS:
            raise WidgetError("E_PROTECTED", f"Widget id {widget_id!r} is owned by Dockrail.")
        display_name = name.strip() if isinstance(name, str) and name.strip() else widget_id.rsplit(".", 1)[-1].replace("-", " ").title()
        if len(display_name) > 128:
            raise WidgetError("E_VALIDATION", "Widget name must be at most 128 characters.")
        target = Path(destination).expanduser() if destination else self.home / "Projects/dockrail-widgets" / widget_id
        target = self.source_preflight(target)
        if target.exists() or target.is_symlink():
            raise WidgetError("E_CONFLICT", "Widget scaffold destination already exists: " + str(target))
        target.parent.mkdir(parents=True, exist_ok=True)
        manifest = {
            "apiVersion": API_VERSION,
            "id": widget_id,
            "name": display_name,
            "version": "0.1.0",
            "entry": "Widget.qml",
            "icon": "layout-grid",
        }
        target.mkdir(mode=0o755)
        try:
            (target / "widget.json").write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
            (target / "Widget.qml").write_text(
                "import QtQuick\n"
                "import Dockrail.WidgetKit 1.0\n\n"
                "Item {\n"
                "  property var widgetContext: ({})\n"
                "  implicitHeight: content.implicitHeight\n\n"
                "  WidgetSection {\n"
                "    id: content\n"
                "    width: parent.width\n"
                f"    title: {json.dumps(display_name, ensure_ascii=False)}\n"
                "    subtitle: \"External Dockrail Widget\"\n\n"
                "    WidgetText {\n"
                "      width: parent.width\n"
                "      text: \"Ready\"\n"
                "      role: \"body\"\n"
                "    }\n"
                "  }\n"
                "}\n",
                encoding="utf-8",
            )
            (target / "README.md").write_text(
                f"# {display_name}\n\n"
                "Dockrail Widget package API v1 source. Keep this repository separate from Dockrail itself.\n\n"
                "Development:\n\n"
                "```bash\n"
                f"dockrail widget install {target}\n"
                f"dockrail widget dev use {target}\n"
                "dockrail widget dev reload\n"
                "dockrail widget dev reset\n"
                "```\n\n"
                "Component API: https://github.com/fernandodamaso/dockrail/blob/main/docs/WIDGET_COMPONENTS.md\n\n"
                "Package API: https://github.com/fernandodamaso/dockrail/blob/main/docs/WIDGET_PACKAGES.md\n",
                encoding="utf-8",
            )
            validate_manifest(target)
        except Exception:
            shutil.rmtree(target, ignore_errors=True)
            raise
        return {"id": widget_id, "name": display_name, "sourcePath": str(target), "apiVersion": API_VERSION}

    def installed_dirs(self):
        if not self.root.is_dir():
            return []
        return sorted(
            (path for path in self.root.iterdir()
             if (path.is_dir() or path.is_symlink()) and not path.name.startswith(".")),
            key=lambda item: item.name,
        )

    def _metadata_path(self, package_dir: Path):
        return package_dir / ".smartdock-source.json"

    def source_metadata(self, package_dir: Path):
        path = self._metadata_path(package_dir)
        try:
            value = read_json(path, "Dockrail Widget source metadata")
        except WidgetError:
            return None
        if (
            not isinstance(value, dict)
            or value.get("schemaVersion") != STATE_SCHEMA_VERSION
            or value.get("type") not in ("local", "git")
            or not isinstance(value.get("location"), str)
            or not value["location"]
        ):
            return None
        return value

    def _stage_from_source(self, source: Path, source_metadata):
        self.root.mkdir(parents=True, exist_ok=True)
        stage = self.root / (".stage-" + uuid.uuid4().hex)
        copy_package(source, stage)
        try:
            manifest = validate_manifest(stage)
            self._materialize_widgetkit(stage)
            self._rewrite_widgetkit_imports(stage)
            self._validate_qml_entry(stage, manifest)
            manifest = validate_manifest(stage, allow_runtime_widgetkit=True)
            write_json_atomic(
                self._metadata_path(stage),
                {
                    "schemaVersion": STATE_SCHEMA_VERSION,
                    "type": source_metadata["type"],
                    "location": source_metadata["location"],
                },
            )
            return stage, manifest
        except Exception:
            shutil.rmtree(stage, ignore_errors=True)
            raise

    def _swap_package(self, target: Path, stage: Path):
        backup = self.root / (".backup-" + uuid.uuid4().hex)
        had_target = target.exists()
        if had_target:
            os.replace(target, backup)
        try:
            os.replace(stage, target)
            self.rebuild_registry()
        except Exception:
            if target.exists():
                shutil.rmtree(target, ignore_errors=True)
            if had_target and backup.exists():
                os.replace(backup, target)
            try:
                self.rebuild_registry()
            except Exception:
                pass
            raise
        finally:
            shutil.rmtree(stage, ignore_errors=True)
        if backup.exists():
            shutil.rmtree(backup, ignore_errors=True)

    def install(self, source_spec: str, *, expected_manifest=None):
        with self.resolved_source(source_spec) as (source, source_metadata):
            manifest = validate_manifest(source)
            if expected_manifest is not None and manifest != expected_manifest:
                raise WidgetError("E_STALE", "Widget identity or manifest changed; review the source again before installing.")
            with self.locked():
                target = self.root / manifest["id"]
                if target.exists():
                    raise WidgetError("E_CONFLICT", f"Widget {manifest['id']!r} is already installed; use `dockrail widget update {manifest['id']}`.")
                stage, staged_manifest = self._stage_from_source(source, source_metadata)
                if staged_manifest != manifest:
                    shutil.rmtree(stage, ignore_errors=True)
                    raise WidgetError("E_VALIDATION", "Widget source changed while it was being installed; retry from a stable source.")
                self._swap_package(target, stage)
            return self.package_row(target, manifest, enabled=self.enabled_ids())

    def _read_dev_state(self):
        if not self.dev_state_path.is_file():
            return None
        value = read_json(self.dev_state_path, "Widget development state")
        if (
            not isinstance(value, dict)
            or value.get("schemaVersion") != STATE_SCHEMA_VERSION
            or not valid_widget_id(value.get("id"))
            or not isinstance(value.get("source"), str)
            or not isinstance(value.get("snapshot"), str)
        ):
            raise WidgetError("E_STATE", "Widget development state is invalid; repair or remove " + str(self.dev_state_path))
        return value

    def _active_root(self, package_dir: Path, manifest, dev_state):
        if dev_state and dev_state.get("id") == manifest["id"]:
            snapshot = Path(dev_state["snapshot"])
            try:
                snapshot = snapshot.resolve()
            except OSError:
                return package_dir, False
            if _is_within(snapshot, self.dev_root.resolve()) and snapshot.is_dir():
                try:
                    snapshot_manifest = validate_manifest(snapshot, allow_runtime_widgetkit=True)
                    if snapshot_manifest["id"] == manifest["id"]:
                        return snapshot, True
                except WidgetError:
                    pass
        return package_dir, False

    def rebuild_registry(self):
        self.root.mkdir(parents=True, exist_ok=True)
        try:
            dev_state = self._read_dev_state()
        except WidgetError as error:
            dev_state = None
            state_error = {"path": str(self.dev_state_path), "error": str(error)}
        else:
            state_error = None
        candidates = []
        errors = [] if state_error is None else [state_error]
        for package_dir in self.installed_dirs():
            try:
                manifest = self._validate_installed(package_dir)
                if package_dir.name != manifest["id"]:
                    raise WidgetError("E_VALIDATION", "Installed directory name does not match widget.json id.")
                active_root, development = self._active_root(package_dir, manifest, dev_state)
                active_manifest = validate_manifest(active_root, allow_runtime_widgetkit=True)
                if active_manifest["id"] != manifest["id"]:
                    raise WidgetError("E_VALIDATION", "Development package id does not match the installed Widget.")
                candidates.append((package_dir, active_root, active_manifest, development))
            except WidgetError as error:
                errors.append({"path": str(package_dir), "id": package_dir.name, "error": str(error)})
        by_id = {}
        for candidate in candidates:
            by_id.setdefault(candidate[2]["id"], []).append(candidate)
        packages = []
        for widget_id in sorted(by_id):
            rows = by_id[widget_id]
            if len(rows) != 1:
                for row in rows:
                    errors.append({"path": str(row[0]), "id": widget_id, "error": "Duplicate installed Widget id; no duplicate is executable."})
                continue
            if len(packages) >= MAX_REGISTRY_PACKAGES:
                errors.append({
                    "path": str(rows[0][0]),
                    "id": widget_id,
                    "error": f"External Widget registry limit ({MAX_REGISTRY_PACKAGES}) exceeded; package is not executable.",
                })
                continue
            package_dir, active_root, manifest, development = rows[0]
            digest = package_digest(active_root, manifest)
            revision = int(digest[:12], 16)
            entry_path = (active_root / manifest["entry"]).resolve()
            source = self.source_metadata(package_dir)
            packages.append(
                {
                    **manifest,
                    "entryPath": entry_path.relative_to(self.root.resolve()).as_posix(),
                    "entryRevision": digest[:16],
                    "revision": revision,
                    "ownership": "external",
                    "manageable": True,
                    "development": development,
                    "sourceType": source["type"] if source else "unknown",
                }
            )
        registry = {
            "schemaVersion": REGISTRY_SCHEMA_VERSION,
            "apiVersion": API_VERSION,
            "packages": packages,
            "errors": sorted(errors, key=lambda row: (row.get("id", ""), row.get("path", ""), row.get("error", ""))),
        }
        write_json_atomic(self.registry_path, registry)
        return registry

    def enabled_ids(self):
        if not self.config_path.exists():
            return set()
        try:
            value = read_json(self.config_path, "Dockrail configuration")
        except WidgetError as error:
            raise WidgetError("E_CONFIG", "Cannot verify Widget enabled state before this operation: " + str(error)) from error
        ids = value.get("sidebarWidgets", []) if isinstance(value, dict) else []
        if not isinstance(ids, list) or any(not isinstance(item, str) for item in ids):
            raise WidgetError("E_CONFIG", "Cannot verify Widget enabled state because sidebarWidgets is invalid.")
        return set(ids)

    def package_row(self, package_dir: Path, manifest=None, enabled=None, dev_state=None):
        if manifest is None:
            manifest = self._validate_installed(package_dir)
        if enabled is None:
            enabled = self.enabled_ids()
        if dev_state is None:
            try:
                dev_state = self._read_dev_state()
            except WidgetError:
                dev_state = None
        source = self.source_metadata(package_dir)
        development = bool(dev_state and dev_state.get("id") == manifest["id"])
        return {
            "id": manifest["id"],
            "name": manifest["name"],
            "apiVersion": manifest["apiVersion"],
            "version": manifest["version"],
            "icon": manifest["icon"],
            "installed": True,
            "enabled": manifest["id"] in enabled,
            "compatible": manifest["apiVersion"] == API_VERSION,
            "validation": "valid",
            "ownership": "external",
            "manageable": True,
            "development": development,
            "sourceType": source["type"] if source else "unknown",
            "source": source["location"] if source else None,
        }

    def list_rows(self):
        try:
            enabled = self.enabled_ids()
            enabled_warning = None
        except WidgetError as error:
            enabled = set()
            enabled_warning = str(error)
        try:
            dev_state = self._read_dev_state()
        except WidgetError:
            dev_state = None
        rows = []
        for widget_id, (name, ownership, manageable) in sorted(PROTECTED_WIDGETS.items()):
            rows.append(
                {
                    "id": widget_id,
                    "name": name,
                    "apiVersion": API_VERSION,
                    "version": None,
                    "installed": True,
                    "enabled": None if enabled_warning else widget_id in enabled,
                    "compatible": True,
                    "validation": "source-owned",
                    "ownership": ownership,
                    "manageable": manageable,
                    "development": False,
                    "sourceType": "source-owned",
                    "source": None,
                }
            )
        errors = []
        seen = set(PROTECTED_WIDGETS)
        for package_dir in self.installed_dirs():
            try:
                manifest = self._validate_installed(package_dir)
                if manifest["id"] in seen:
                    raise WidgetError("E_CONFLICT", "Duplicate Widget id; duplicate is not executable.")
                seen.add(manifest["id"])
                row = self.package_row(package_dir, manifest, enabled, dev_state)
                if enabled_warning:
                    row["enabled"] = None
                rows.append(row)
            except WidgetError as error:
                errors.append({"path": str(package_dir), "id": package_dir.name, "error": str(error)})
        rows.sort(key=lambda row: row["id"])
        warnings = []
        if enabled_warning:
            warnings.append(enabled_warning)
        unique_errors = []
        seen_errors = set()
        for row in errors:
            key = (row.get("path"), row.get("id"), row.get("error"))
            if key not in seen_errors:
                seen_errors.add(key)
                unique_errors.append(row)
        return rows, unique_errors, warnings

    def remove(self, widget_id: str):
        if widget_id in PROTECTED_WIDGETS:
            raise WidgetError("E_PROTECTED", f"Widget {widget_id!r} is source-owned and cannot be removed by the package manager.")
        if not valid_widget_id(widget_id):
            raise WidgetError("E_VALIDATION", "Invalid Widget id.")
        with self.locked():
            enabled = self.enabled_ids()
            if widget_id in enabled:
                raise WidgetError(
                    "E_ENABLED",
                    f"Widget {widget_id!r} is enabled. Remove its ID through the existing Dockrail Widget/settings UI before uninstalling it.",
                )
            state = self._read_dev_state()
            if state and state["id"] == widget_id:
                raise WidgetError("E_DEV_ACTIVE", "Reset the active Widget development override before removing this package.")
            target = self.root / widget_id
            if not target.is_dir() and not target.is_symlink():
                raise WidgetError("E_NOT_FOUND", f"Widget {widget_id!r} is not installed.")
            manifest = self._validate_installed(target)
            if manifest["id"] != widget_id:
                raise WidgetError("E_STATE", "Installed Widget directory identity is inconsistent; refusing targeted removal.")
            tombstone = self.root / (".remove-" + uuid.uuid4().hex)
            os.replace(target, tombstone)
            try:
                self.rebuild_registry()
            except Exception:
                os.replace(tombstone, target)
                self.rebuild_registry()
                raise
            shutil.rmtree(tombstone, ignore_errors=True)
        return {"id": widget_id, "removed": True}

    def _update_one_locked(self, widget_id: str):
        if widget_id in PROTECTED_WIDGETS or not valid_widget_id(widget_id):
            raise WidgetError("E_PROTECTED", "Only installed external Widget packages can be updated.")
        state = self._read_dev_state()
        if state and state["id"] == widget_id:
            raise WidgetError("E_DEV_ACTIVE", "Reset the Widget development override before updating its installed package.")
        target = self.root / widget_id
        if not target.is_dir() and not target.is_symlink():
            raise WidgetError("E_NOT_FOUND", f"Widget {widget_id!r} is not installed.")
        previous = self._validate_installed(target)
        metadata = self.source_metadata(target)
        if metadata is None:
            raise WidgetError("E_SOURCE", "Installed Widget has no valid package source metadata; reinstall it from an explicit source.")
        with self.resolved_source(metadata["location"]) as (source, fresh_metadata):
            if fresh_metadata["type"] != metadata["type"]:
                raise WidgetError("E_SOURCE", "Widget source type changed unexpectedly; reinstall explicitly.")
            manifest = validate_manifest(source)
            if manifest["id"] != widget_id:
                raise WidgetError("E_VALIDATION", "Updated source changed Widget id; previous package was preserved.")
            stage, staged = self._stage_from_source(source, metadata)
            if staged["id"] != previous["id"]:
                shutil.rmtree(stage, ignore_errors=True)
                raise WidgetError("E_VALIDATION", "Updated source changed Widget identity; previous package was preserved.")
            self._swap_package(target, stage)
        return self.package_row(target, enabled=self.enabled_ids())

    def update(self, widget_id=None):
        with self.locked():
            if widget_id:
                return {"results": [{"id": widget_id, "ok": True, "package": self._update_one_locked(widget_id)}], "failed": 0}
            ids = []
            for package_dir in self.installed_dirs():
                try:
                    manifest = self._validate_installed(package_dir)
                except WidgetError:
                    ids.append(package_dir.name)
                else:
                    ids.append(manifest["id"])
            results = []
            failed = 0
            for current_id in sorted(set(ids)):
                try:
                    package = self._update_one_locked(current_id)
                    results.append({"id": current_id, "ok": True, "package": package})
                except (WidgetError, OSError) as error:
                    failed += 1
                    code = error.code if isinstance(error, WidgetError) else "E_IO"
                    results.append({"id": current_id, "ok": False, "error": {"code": code, "message": str(error)}})
            return {"results": results, "failed": failed}

    def _new_dev_snapshot(self, source: Path, manifest):
        parent = self.dev_root / manifest["id"]
        parent.mkdir(parents=True, exist_ok=True)
        stage = parent / (".stage-" + uuid.uuid4().hex)
        copy_package(source, stage)
        try:
            staged = validate_manifest(stage)
            if staged != manifest:
                raise WidgetError("E_VALIDATION", "Widget source changed while preparing the development snapshot.")
            self._materialize_widgetkit(stage)
            self._rewrite_widgetkit_imports(stage)
            self._validate_qml_entry(stage, staged)
            staged = validate_manifest(stage, allow_runtime_widgetkit=True)
            if staged != manifest:
                raise WidgetError("E_VALIDATION", "Widget source changed while preparing the development snapshot.")
            digest = package_digest(stage, staged)
            target = parent / digest[:24]
            if target.exists():
                shutil.rmtree(stage, ignore_errors=True)
            else:
                os.replace(stage, target)
            return target
        except Exception:
            shutil.rmtree(stage, ignore_errors=True)
            raise

    def dev_use(self, source_spec: str):
        with self.resolved_source(source_spec, development=True) as (source, _):
            manifest = validate_manifest(source)
            with self.locked():
                current = self._read_dev_state()
                if current and current["id"] != manifest["id"]:
                    raise WidgetError("E_DEV_ACTIVE", f"Widget {current['id']!r} already has the selected development source; reset it first.")
                installed = self.root / manifest["id"]
                if not installed.is_dir() and not installed.is_symlink():
                    raise WidgetError("E_NOT_FOUND", "Install this Widget package before selecting its development source, so reset has a known working package.")
                installed_manifest = self._validate_installed(installed)
                if installed_manifest["id"] != manifest["id"]:
                    raise WidgetError("E_STATE", "Installed Widget identity is inconsistent.")
                snapshot = self._new_dev_snapshot(source, manifest)
                old_state = current
                state = {
                    "schemaVersion": STATE_SCHEMA_VERSION,
                    "id": manifest["id"],
                    "source": str(source),
                    "snapshot": str(snapshot),
                }
                try:
                    write_json_atomic(self.dev_state_path, state)
                    self.rebuild_registry()
                except Exception:
                    if old_state:
                        write_json_atomic(self.dev_state_path, old_state)
                    else:
                        self.dev_state_path.unlink(missing_ok=True)
                    self.rebuild_registry()
                    if not old_state or old_state.get("snapshot") != str(snapshot):
                        shutil.rmtree(snapshot, ignore_errors=True)
                    raise
                if old_state and old_state.get("snapshot") != str(snapshot):
                    shutil.rmtree(Path(old_state["snapshot"]), ignore_errors=True)
                return {"id": manifest["id"], "source": str(source), "development": True, "snapshot": str(snapshot)}

    def dev_reload(self):
        with self.locked():
            state = self._read_dev_state()
            if not state:
                raise WidgetError("E_NOT_FOUND", "No Widget development source is selected. Run `dockrail widget dev use <source>` first.")
            source = self.source_preflight(Path(state["source"]))
            if not source.is_dir():
                raise WidgetError("E_SOURCE", "Selected Widget development source no longer exists; previous working snapshot remains active.")
            manifest = validate_manifest(source)
            if manifest["id"] != state["id"]:
                raise WidgetError("E_VALIDATION", "Selected Widget source changed ID; previous working snapshot remains active.")
            snapshot = self._new_dev_snapshot(source, manifest)
            old_snapshot = Path(state["snapshot"])
            next_state = dict(state, snapshot=str(snapshot))
            try:
                write_json_atomic(self.dev_state_path, next_state)
                self.rebuild_registry()
            except Exception:
                write_json_atomic(self.dev_state_path, state)
                self.rebuild_registry()
                if str(snapshot) != state["snapshot"]:
                    shutil.rmtree(snapshot, ignore_errors=True)
                raise
            if old_snapshot != snapshot:
                shutil.rmtree(old_snapshot, ignore_errors=True)
            return {"id": state["id"], "source": str(source), "development": True, "snapshot": str(snapshot), "reloaded": True}

    def dev_reset(self):
        with self.locked():
            state = self._read_dev_state()
            if not state:
                return {"reset": False, "development": False}
            source = state["source"]
            snapshot = Path(state["snapshot"])
            backup = self.dev_state_path.with_name(".dev-state.reset-" + uuid.uuid4().hex + ".json")
            os.replace(self.dev_state_path, backup)
            try:
                self.rebuild_registry()
            except Exception:
                os.replace(backup, self.dev_state_path)
                self.rebuild_registry()
                raise
            backup.unlink(missing_ok=True)
            shutil.rmtree(snapshot, ignore_errors=True)
            try:
                snapshot.parent.rmdir()
            except OSError:
                pass
            return {"id": state["id"], "source": source, "reset": True, "development": False}


def build_parser():
    parser = argparse.ArgumentParser(prog="dockrail widget", add_help=True)
    actions = parser.add_subparsers(dest="action", required=True)
    create = actions.add_parser("create", help="Create a Widget package API v1 source scaffold")
    create.add_argument("id")
    create.add_argument("--name")
    create.add_argument("--destination")
    install = actions.add_parser("install", help="Install an explicit trusted local or repository Widget source")
    install.add_argument("source")
    remove = actions.add_parser("remove", help="Remove one installed external Widget package")
    remove.add_argument("id")
    actions.add_parser("list", help="List source-owned and external Widgets")
    update = actions.add_parser("update", help="Update one or all installed external Widget packages")
    update.add_argument("id", nargs="?")
    dev = actions.add_parser("dev", help="Use a local Widget development source without editing deployment state")
    dev_actions = dev.add_subparsers(dest="dev_action", required=True)
    use = dev_actions.add_parser("use", help="Select and snapshot a local Widget source")
    use.add_argument("source")
    dev_actions.add_parser("reload", help="Validate and snapshot current development edits")
    dev_actions.add_parser("reset", help="Restore the installed Widget package")
    return parser


def execute(args, store=None):
    store = store or Store()
    if args.action == "create":
        return envelope(store.create(args.id, args.name, args.destination))
    if args.action == "install":
        return envelope({"package": store.install(args.source)})
    if args.action == "remove":
        return envelope(store.remove(args.id))
    if args.action == "list":
        rows, errors, warnings = store.list_rows()
        return envelope({"widgets": rows, "errors": errors, "packageRoot": str(store.root)}, warnings)
    if args.action == "update":
        result = store.update(args.id)
        if result["failed"]:
            raise WidgetError("E_PARTIAL", f"{result['failed']} Widget update(s) failed; unrelated packages were still processed.", result)
        return envelope(result)
    if args.dev_action == "use":
        return envelope(store.dev_use(args.source))
    if args.dev_action == "reload":
        return envelope(store.dev_reload())
    return envelope(store.dev_reset())


def print_human(reply):
    if not reply["ok"]:
        print(f"dockrail widget: {reply['error']['code']}: {reply['error']['message']}", file=sys.stderr)
        if reply.get("data"):
            print(json.dumps(reply["data"], ensure_ascii=False, indent=2), file=sys.stderr)
        return
    data = reply["data"]
    if "widgets" in data:
        for row in data["widgets"]:
            enabled = "?" if row["enabled"] is None else ("yes" if row["enabled"] else "no")
            version = row["version"] or "source"
            mode = "dev" if row["development"] else ("installed" if row["installed"] else "source")
            print(f"{row['id']}\t{row['name']}\tapi={row['apiVersion']}\tversion={version}\t{mode}\tenabled={enabled}\t{row['ownership']}\t{row['validation']}")
        for item in data.get("errors", []):
            print("dockrail widget: invalid package: " + item.get("path", "") + ": " + item.get("error", ""), file=sys.stderr)
    else:
        print(json.dumps(data, ensure_ascii=False, indent=2))
    for warning in reply.get("warnings", []):
        print("dockrail widget: " + str(warning), file=sys.stderr)


def main(argv=None):
    argv = list(sys.argv[1:] if argv is None else argv)
    as_json = "--json" in argv
    argv = [item for item in argv if item != "--json"]
    try:
        args = build_parser().parse_args(argv)
        reply = execute(args)
    except WidgetError as error:
        reply = error_envelope(error)
    except (OSError, subprocess.SubprocessError) as error:
        reply = error_envelope(WidgetError("E_IO", str(error)))
    if as_json:
        print(json.dumps(reply, ensure_ascii=False, allow_nan=False, separators=(",", ":")))
    else:
        print_human(reply)
    return 0 if reply["ok"] else 1


if __name__ == "__main__":
    sys.exit(main())
