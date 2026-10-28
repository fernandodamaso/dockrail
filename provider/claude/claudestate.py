# SPDX-License-Identifier: Apache-2.0
"""Claude Desktop session state: hook records, /proc checks and snapshot.

``dockrail claude hook`` (installed as Claude Code hooks) writes one small
JSON record per session. This module reads those records, keeps only sessions
whose process ancestry proves they were started by Claude Desktop, and builds
a Herdr-schema-v1 snapshot so the existing ``DockHerdrService`` /
``DockHerdrWindowAgents`` stack shows the state on the Claude Desktop icon.

Every function that touches the filesystem takes an explicit root so tests
can point it at fake trees. No message bodies or prompts are stored or
emitted; transcripts are only probed for the user-interrupt marker.
"""
from __future__ import annotations

import hashlib
import json
import os
import stat as stat_module
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Mapping

SCHEMA_VERSION = 1
SERVER_ID = "claude:desktop"
MAX_SESSIONS = 64
MAX_RECORD_BYTES = 16 * 1024
MAX_ANCESTORS = 16
MAX_WINDOW_PIDS = 256
TRANSCRIPT_TAIL_BYTES = 64 * 1024
DONE_RETENTION_MS = 30 * 60 * 1000
STALE_WORKING_MS = 20 * 60 * 1000
STATUSES = ("working", "blocked", "done", "idle")
INTERRUPT_MARKER = "[Request interrupted by user"

# Fragments that identify a Claude Desktop process, matched against its comm,
# executable path and argv[0] only. The Claude Code CLI itself (`claude`)
# never qualifies.
DESKTOP_MARKERS = (
    "claude-desktop",
    "claude_desktop",
    "claude desktop",
    ".mount_claude",
    "claude.appimage",
    "/claude.app/",
)


def state_dirs(env: Mapping[str, str] | None = None) -> list[Path]:
    """Return candidate session-state directories, preferred first.

    Hooks write to the first; the provider reads all so a hook environment
    without ``XDG_RUNTIME_DIR`` still reaches a provider that has one.
    """
    if env is None:
        env = os.environ
    dirs: list[Path] = []
    runtime = env.get("XDG_RUNTIME_DIR", "")
    if runtime and Path(runtime).is_absolute():
        dirs.append(Path(runtime) / "dockrail" / "claude" / "sessions")
    state_home = env.get("XDG_STATE_HOME", "")
    if state_home and Path(state_home).is_absolute():
        base = Path(state_home)
    else:
        home = env.get("HOME", "") or str(Path.home())
        base = Path(home) / ".local" / "state"
    dirs.append(base / "dockrail" / "claude" / "sessions")
    return dirs


# -- /proc ---------------------------------------------------------------------
def _parse_stat(data: bytes) -> tuple[int, int] | None:
    """Return ``(ppid, startTime)`` from /proc/<pid>/stat bytes."""
    rparen = data.rfind(b")")
    if rparen < 0:
        return None
    fields = data[rparen + 2:].split()
    if len(fields) < 20:
        return None
    try:
        return int(fields[1]), int(fields[19])
    except ValueError:
        return None


def _stat(pid: int, proc_root: Path) -> tuple[int, int] | None:
    if not isinstance(pid, int) or isinstance(pid, bool) or pid <= 0:
        return None
    try:
        if os.stat(proc_root / str(pid)).st_uid != os.getuid():
            return None
        with open(proc_root / str(pid) / "stat", "rb") as handle:
            return _parse_stat(handle.read(65536))
    except (OSError, ValueError):
        return None


def identity(pid: int, proc_root: Path = Path("/proc")) -> dict[str, int] | None:
    """Return ``{"pid", "startTime"}`` for a same-uid process, else ``None``."""
    parsed = _stat(pid, proc_root)
    if parsed is None or parsed[1] < 0:
        return None
    return {"pid": pid, "startTime": parsed[1]}


def alive(record: Mapping[str, Any], proc_root: Path) -> bool:
    """True when ``record``'s pid still runs with the same start time."""
    found = identity(record.get("pid"), proc_root)  # type: ignore[arg-type]
    return found is not None and found["startTime"] == record.get("startTime")


def resolve_window_identities(
    pids: list[int], proc_root: Path = Path("/proc")
) -> list[dict[str, int]]:
    """Resolve window PIDs to identities (max 256, failures skipped)."""
    output: list[dict[str, int]] = []
    seen: set[int] = set()
    for pid in pids:
        if pid in seen or len(output) >= MAX_WINDOW_PIDS:
            continue
        seen.add(pid)
        found = identity(pid, proc_root)
        if found is not None:
            output.append(found)
    return output


def process_text(pid: int, proc_root: Path) -> tuple[str, str, list[str]]:
    """Return ``(comm, exe, argv)`` for a process; empty values on failure."""
    base = proc_root / str(pid)
    comm = exe = ""
    argv: list[str] = []
    try:
        comm = (base / "comm").read_text("utf-8", "replace").strip()
    except OSError:
        pass
    try:
        exe = os.readlink(base / "exe")
    except OSError:
        pass
    try:
        raw = (base / "cmdline").read_bytes()[:16384]
        argv = [part.decode("utf-8", "replace") for part in raw.split(b"\0") if part]
    except OSError:
        pass
    return comm, exe, argv


def is_desktop_process(pid: int, proc_root: Path) -> tuple[bool, bool]:
    """Return ``(isClaudeDesktop, isMainProcess)`` for one process.

    Electron helpers (renderer/GPU/utility/zygote) carry ``--type=`` (possibly
    inside one space-joined cmdline) and launcher wrappers such as
    ``disclaimer`` live in the app's ``resources/`` directory. Both match but
    are not the window owner.
    """
    comm, exe, argv = process_text(pid, proc_root)
    if len(argv) == 1 and " " in argv[0]:
        # Chromium rewrites its command line into one space-joined argument;
        # split it after the executable so a path with spaces stays whole.
        head = exe if exe and argv[0].startswith(exe + " ") else ""
        argv = [head] + argv[0][len(head):].split() if head else argv[0].split()
    program = argv[0] if argv else ""
    names = {comm, Path(exe).name, Path(program).name}
    if "claude" in names:
        # The lowercase `claude` binary is the Claude Code CLI, never the window.
        return False, False
    # Match the program itself, not its arguments: a shell or editor whose
    # arguments mention a claude-desktop path is not Claude Desktop. A shared
    # Electron runtime is identified by its app path, the first non-option
    # argument (`electron /usr/lib/claude-desktop/app.asar`).
    identity = [comm, exe, program]
    if any(name.startswith("electron") for name in names):
        identity += [arg for arg in argv[1:] if not arg.startswith("-")][:1]
    haystack = " ".join(identity).lower()
    if "Claude" not in names and not any(m in haystack for m in DESKTOP_MARKERS):
        return False, False
    main = not any(arg.startswith("--type=") for arg in argv)
    if Path(exe or program).parent.name == "resources":
        main = False
    return True, main


def desktop_chain(
    ancestors: list[dict[str, Any]], proc_root: Path
) -> list[dict[str, int]] | None:
    """Return the live ancestry up to the Claude Desktop main process.

    ``ancestors`` is the nearest-first chain recorded by the hook. The chain
    is cut after the desktop process so no farther ancestor (a terminal that
    launched Claude Desktop, for example) can claim the session's window.
    ``None`` means the session was not started by Claude Desktop.
    """
    chain: list[dict[str, int]] = []
    fallback: int | None = None
    for index, ancestor in enumerate(ancestors[:MAX_ANCESTORS]):
        if not isinstance(ancestor, dict) or not alive(ancestor, proc_root):
            return None
        chain.append({"pid": ancestor["pid"], "startTime": ancestor["startTime"]})
        matched, main = is_desktop_process(ancestor["pid"], proc_root)
        if matched and main:
            return chain
        if matched:
            fallback = index
    if fallback is not None:
        return chain[: fallback + 1]
    return None


# -- records --------------------------------------------------------------------
def _valid_identity(value: object) -> bool:
    return (
        isinstance(value, dict)
        and isinstance(value.get("pid"), int)
        and not isinstance(value.get("pid"), bool)
        and value["pid"] > 0
        and isinstance(value.get("startTime"), int)
        and not isinstance(value.get("startTime"), bool)
        and value["startTime"] >= 0
    )


def parse_record(raw: bytes) -> dict[str, Any] | None:
    """Validate one hook record; ``None`` for anything malformed."""
    if len(raw) > MAX_RECORD_BYTES:
        return None
    try:
        record = json.loads(raw)
    except (ValueError, UnicodeError):
        return None
    if not isinstance(record, dict) or record.get("version") != 1:
        return None
    session_id = record.get("sessionId")
    if not isinstance(session_id, str) or not 0 < len(session_id) <= 128:
        return None
    if record.get("status") not in STATUSES:
        return None
    if not _valid_identity(record.get("process")):
        return None
    ancestors = record.get("ancestors")
    if not isinstance(ancestors, list) or not all(_valid_identity(a) for a in ancestors):
        return None
    if not isinstance(record.get("updatedAtMs"), int):
        return None
    for key in ("cwd", "transcriptPath"):
        if not isinstance(record.get(key, ""), str):
            return None
    return record


def read_records(dirs: list[Path]) -> list[dict[str, Any]]:
    """Read every valid session record from ``dirs`` (same-uid files only)."""
    records: dict[str, dict[str, Any]] = {}
    own = os.getuid()
    for directory in dirs:
        try:
            entries = sorted(os.listdir(directory))
        except OSError:
            continue
        for name in entries:
            if not name.endswith(".json"):
                continue
            path = directory / name
            try:
                info = os.lstat(path)
                if not stat_module.S_ISREG(info.st_mode) or info.st_uid != own:
                    continue
                with open(path, "rb") as handle:
                    record = parse_record(handle.read(MAX_RECORD_BYTES + 1))
            except OSError:
                continue
            if record is None:
                continue
            previous = records.get(record["sessionId"])
            if previous is None or previous["updatedAtMs"] < record["updatedAtMs"]:
                records[record["sessionId"]] = record
    return list(records.values())


def transcript_state(path: str) -> tuple[bool, float | None]:
    """Return ``(interrupted, mtime)`` from a transcript's last record."""
    if not path or not os.path.isabs(path):
        return False, None
    try:
        info = os.lstat(path)
        if not stat_module.S_ISREG(info.st_mode) or info.st_uid != os.getuid():
            return False, None
        with open(path, "rb") as handle:
            handle.seek(max(0, info.st_size - TRANSCRIPT_TAIL_BYTES))
            tail = handle.read(TRANSCRIPT_TAIL_BYTES)
    except OSError:
        return False, None
    lines = [line for line in tail.splitlines() if line.strip()]
    last = lines[-1].decode("utf-8", "replace") if lines else ""
    return INTERRUPT_MARKER in last, info.st_mtime


def effective_status(
    record: dict[str, Any], process_alive: bool, now_ms: int
) -> str | None:
    """Return the shown status for a record, or ``None`` to hide it."""
    status = record["status"]
    age_ms = max(0, now_ms - record["updatedAtMs"])
    if not process_alive:
        # A finished turn stays visible briefly; anything else died mid-turn.
        return "done" if status == "done" and age_ms < DONE_RETENTION_MS else None
    if status in ("working", "blocked"):
        interrupted, mtime = transcript_state(record.get("transcriptPath", ""))
        if interrupted:
            return "idle"
        if status == "working":
            touched_ms = max(
                record["updatedAtMs"], int(mtime * 1000) if mtime is not None else 0
            )
            if now_ms - touched_ms > STALE_WORKING_MS:
                return "idle"
    return status


def session_title(record: dict[str, Any]) -> str:
    cwd = record.get("cwd", "")
    name = Path(cwd).name if cwd else ""
    cleaned = "".join(ch for ch in name if ch.isprintable())[:80]
    return cleaned or "Claude session"


# -- snapshot ---------------------------------------------------------------------
@dataclass
class BuildState:
    epoch: str
    revision: int
    wp_revision: int = 0
    wp_identities: list[dict[str, int]] = field(default_factory=list)
    now_ms: int = 0


def collect_sessions(
    records: list[dict[str, Any]], proc_root: Path, now_ms: int
) -> tuple[list[dict[str, Any]], list[dict[str, Any]]]:
    """Return ``(sessions, clients)`` for Claude Desktop sessions only."""
    sessions: list[dict[str, Any]] = []
    clients: list[dict[str, Any]] = []
    seen_clients: set[str] = set()
    ordered = sorted(records, key=lambda r: (-r["updatedAtMs"], r["sessionId"]))
    for record in ordered[:MAX_SESSIONS]:
        chain = desktop_chain(record["ancestors"], proc_root)
        if chain is None:
            continue
        status = effective_status(record, alive(record["process"], proc_root), now_ms)
        if status is None:
            continue
        sessions.append(dict(record, status=status))
        # The desktop main process is the window owner: one client per chain.
        key = json.dumps(chain[-1], sort_keys=True)
        if key not in seen_clients:
            seen_clients.add(key)
            clients.append(
                {"pid": chain[-1]["pid"], "startTime": chain[-1]["startTime"], "ancestors": []}
            )
    return sessions, clients


def build_snapshot(
    state: BuildState, sessions: list[dict[str, Any]], clients: list[dict[str, Any]]
) -> dict[str, Any]:
    """Build a Herdr-schema-v1 snapshot for the current Claude Desktop state."""
    agents: list[dict[str, Any]] = []
    attention: list[dict[str, Any]] = []
    counts: dict[str, Any] = {
        "blocked": 0, "done": 0, "working": 0, "idle": 0, "unknown": 0,
        "agents": 0, "servers": 1, "complete": True,
    }
    for session in sessions:
        session_id = session["sessionId"]
        agent_id = f"{SERVER_ID}:1:{session_id}"
        status = session["status"]
        title = session_title(session)
        agents.append({
            "id": agent_id,
            "serverId": SERVER_ID,
            "connectionGeneration": 1,
            "transport": "local",
            "host": "local",
            "session": "",
            "paneId": session_id,
            "status": status,
            "live": True,
            "workspaceId": "",
            "workspaceLabel": "",
            "tabId": "",
            "tabTitle": "",
            "title": title,
            "agent": "claude",
            "stateChangeSeq": str(session["updatedAtMs"]),
        })
        counts[status] += 1
        if status in ("blocked", "done"):
            attention.append({
                "agentId": agent_id,
                "serverId": SERVER_ID,
                "session": "",
                "paneId": session_id,
                "status": status,
            })
    counts["agents"] = len(agents)
    return {
        "schemaVersion": SCHEMA_VERSION,
        "providerEpoch": state.epoch,
        "revision": state.revision,
        "capabilities": {
            "inventory": True,
            "attention": True,
            "remote": False,
            "actions": False,
            "desktopNotifications": False,
        },
        "servers": [{
            "id": SERVER_ID,
            "source": "claude",
            "product": "Claude",
            "transport": "local",
            "host": "local",
            "sessions": [],
            "session": "",
            "label": "Claude",
            "capabilities": {"focusAgent": False},
            "connectionGeneration": 1,
            "health": "live",
            "connected": True,
            "clients": clients,
        }],
        "agents": agents,
        "attention": attention,
        "liveCounts": counts,
        "completeness": {
            "state": "complete",
            "truncated": False,
            "serverTruncated": False,
            "agentTruncated": False,
        },
        "windowProcesses": {
            "revision": state.wp_revision,
            "identities": list(state.wp_identities),
        },
    }


def snapshot_fingerprint(snapshot: dict[str, Any]) -> str:
    """Hash a snapshot excluding the revision counter."""
    redacted = dict(snapshot)
    redacted.pop("revision", None)
    canonical = json.dumps(redacted, sort_keys=True, separators=(",", ":"))
    return hashlib.sha256(canonical.encode("utf-8")).hexdigest()
