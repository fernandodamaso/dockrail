# SPDX-License-Identifier: Apache-2.0
"""Claude Desktop session state for Dockrail through Claude Code hooks.

Claude Desktop runs Claude Code sessions as child processes. Claude Code
hooks report each turn's lifecycle; ``hook`` turns those events into one
small per-session record that ``provider/claude`` reads to animate the Claude
Desktop dock icon. Prompts, messages and tool input are never stored.

Self-contained: it must also run from a ``--cli-only`` install that ships no
``provider/`` directory, so the state-directory rule is duplicated here (a
parity test keeps both copies equal).

Subcommands: ``hooks install|uninstall|status [--json]`` and ``hook`` (the
hook entry point; reads the Claude Code hook payload on stdin, never fails).
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import shlex
import sys
import tempfile
import time
from pathlib import Path
from typing import Any, Mapping

HOOK_MARKER = "dockrail_claude.py"
MAX_PAYLOAD_BYTES = 1024 * 1024
MAX_ANCESTORS = 16
SHELL_NAMES = ("sh", "bash", "dash", "zsh", "fish", "env", "timeout", "nice")
# Event -> whether Claude Code accepts a tool matcher for it.
HOOK_EVENTS = {
    "SessionStart": False,
    "UserPromptSubmit": False,
    "PostToolUse": True,
    "Notification": False,
    "Stop": False,
    "SessionEnd": False,
}
BLOCKING_NOTIFICATIONS = ("permission_prompt", "elicitation_dialog")


class CliError(Exception):
    def __init__(self, code: str, message: str) -> None:
        super().__init__(message)
        self.code = code
        self.message = message


def state_dirs(env: Mapping[str, str] | None = None) -> list[Path]:
    """Return candidate session-state directories, preferred first.

    Must stay identical to ``provider/claude/claudestate.state_dirs``.
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


def claude_settings_path(env: Mapping[str, str] | None = None) -> Path:
    if env is None:
        env = os.environ
    config_dir = env.get("CLAUDE_CONFIG_DIR", "")
    if config_dir:
        return Path(config_dir).expanduser() / "settings.json"
    home = env.get("HOME", "") or str(Path.home())
    return Path(home) / ".claude" / "settings.json"


# -- hook ------------------------------------------------------------------------
def _stat(pid: int, proc_root: Path) -> tuple[int, int, str] | None:
    """Return ``(ppid, startTime, comm)`` for a same-uid process."""
    try:
        if os.stat(proc_root / str(pid)).st_uid != os.getuid():
            return None
        data = (proc_root / str(pid) / "stat").read_bytes()[:65536]
    except OSError:
        return None
    lparen, rparen = data.find(b"("), data.rfind(b")")
    if lparen < 0 or rparen < 0:
        return None
    fields = data[rparen + 2:].split()
    try:
        return int(fields[1]), int(fields[19]), data[lparen + 1:rparen].decode("utf-8", "replace")
    except (ValueError, IndexError):
        return None


def process_chain(start: int, proc_root: Path = Path("/proc")) -> tuple[dict[str, int] | None, list[dict[str, int]]]:
    """Return ``(sessionProcess, ancestors)`` starting at the hook's parent.

    The session process is the nearest ancestor that is not a shell wrapper;
    ``ancestors`` is its own same-uid ancestry, nearest first.
    """
    pid = start
    session: dict[str, int] | None = None
    ancestors: list[dict[str, int]] = []
    for _ in range(MAX_ANCESTORS + 8):
        if pid <= 1:
            break
        info = _stat(pid, proc_root)
        if info is None:
            break
        ppid, start_time, comm = info
        if session is None:
            if comm not in SHELL_NAMES:
                session = {"pid": pid, "startTime": start_time}
        else:
            ancestors.append({"pid": pid, "startTime": start_time})
            if len(ancestors) >= MAX_ANCESTORS:
                break
        pid = ppid
    return session, ancestors


def status_for(payload: Mapping[str, Any]) -> str | None:
    """Map one hook payload to a session status; ``None`` keeps the record."""
    event = payload.get("hook_event_name")
    if event == "SessionStart":
        return None if payload.get("source") == "compact" else "idle"
    if event in ("UserPromptSubmit", "PostToolUse"):
        return "working"
    if event == "Stop":
        return "done"
    if event == "Notification":
        kind = payload.get("notification_type")
        if kind in BLOCKING_NOTIFICATIONS:
            return "blocked"
        if kind is None and "permission" in str(payload.get("message", "")).lower():
            return "blocked"
    return None


def record_path(directory: Path, session_id: str) -> Path:
    digest = hashlib.sha256(session_id.encode("utf-8")).hexdigest()[:32]
    return directory / f"{digest}.json"


def write_record(directory: Path, record: dict[str, Any]) -> None:
    directory.mkdir(mode=0o700, parents=True, exist_ok=True)
    data = json.dumps(record, separators=(",", ":")).encode("utf-8")
    fd, temp = tempfile.mkstemp(prefix=".tmp-", dir=directory)
    try:
        with os.fdopen(fd, "wb") as handle:
            handle.write(data)
        os.replace(temp, record_path(directory, record["sessionId"]))
    except BaseException:
        try:
            os.unlink(temp)
        except OSError:
            pass
        raise


def handle_hook(
    payload: Mapping[str, Any],
    env: Mapping[str, str] | None = None,
    proc_root: Path = Path("/proc"),
    parent: int | None = None,
) -> str:
    """Apply one hook payload; return what happened (for tests)."""
    if env is None:
        env = os.environ
    session_id = payload.get("session_id")
    if not isinstance(session_id, str) or not 0 < len(session_id) <= 128:
        return "ignored"
    directory = state_dirs(env)[0]
    if payload.get("hook_event_name") == "SessionEnd":
        try:
            os.unlink(record_path(directory, session_id))
        except OSError:
            pass
        return "removed"
    status = status_for(payload)
    if status is None:
        return "ignored"
    session, ancestors = process_chain(os.getppid() if parent is None else parent, proc_root)
    if session is None:
        return "ignored"
    cwd = payload.get("cwd")
    transcript = payload.get("transcript_path")
    write_record(directory, {
        "version": 1,
        "sessionId": session_id,
        "status": status,
        "event": str(payload.get("hook_event_name")),
        "cwd": cwd if isinstance(cwd, str) else "",
        "transcriptPath": transcript if isinstance(transcript, str) else "",
        "process": session,
        "ancestors": ancestors,
        "updatedAtMs": int(time.time() * 1000),
    })
    return status


def cmd_hook() -> int:
    # A hook must never disturb the Claude session: no output, always exit 0.
    try:
        payload = json.loads(sys.stdin.buffer.read(MAX_PAYLOAD_BYTES))
        if isinstance(payload, dict):
            handle_hook(payload)
    except Exception:  # noqa: BLE001 - deliberately silent
        pass
    return 0


# -- hooks install ----------------------------------------------------------------
def hook_command(script: Path | None = None) -> str:
    # Exit 2 from a hook can block a prompt, so a missing script or Python
    # must still succeed silently.
    script = (script or Path(__file__)).resolve()
    return f"python3 -B {shlex.quote(str(script))} hook >/dev/null 2>&1 || true"


def is_dockrail_hook(entry: object) -> bool:
    return (
        isinstance(entry, dict)
        and isinstance(entry.get("command"), str)
        and HOOK_MARKER in entry["command"]
    )


def load_settings(path: Path) -> dict[str, Any]:
    try:
        text = path.read_text("utf-8")
    except FileNotFoundError:
        return {}
    except OSError as exc:
        raise CliError("settings_unreadable", f"cannot read {path}: {exc.strerror}")
    try:
        settings = json.loads(text) if text.strip() else {}
    except ValueError:
        raise CliError("settings_invalid", f"{path} is not valid JSON; fix it first")
    if not isinstance(settings, dict):
        raise CliError("settings_invalid", f"{path} must contain a JSON object")
    hooks = settings.get("hooks", {})
    if not isinstance(hooks, dict):
        raise CliError("settings_invalid", f"{path}: \"hooks\" must be an object")
    return settings


def save_settings(path: Path, settings: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    mode = 0o600
    try:
        mode = path.stat().st_mode & 0o777
    except OSError:
        pass
    data = json.dumps(settings, indent=2, ensure_ascii=False) + "\n"
    fd, temp = tempfile.mkstemp(prefix=".settings-", dir=path.parent)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            handle.write(data)
        os.chmod(temp, mode)
        os.replace(temp, path)
    except BaseException:
        try:
            os.unlink(temp)
        except OSError:
            pass
        raise


def without_dockrail_hooks(hooks: dict[str, Any]) -> dict[str, Any]:
    """Return ``hooks`` with every Dockrail entry (and emptied group) removed."""
    cleaned: dict[str, Any] = {}
    for event, groups in hooks.items():
        if not isinstance(groups, list):
            cleaned[event] = groups
            continue
        kept = []
        for group in groups:
            if not isinstance(group, dict) or not isinstance(group.get("hooks"), list):
                kept.append(group)
                continue
            entries = [entry for entry in group["hooks"] if not is_dockrail_hook(entry)]
            if entries:
                kept.append(dict(group, hooks=entries))
            elif not any(is_dockrail_hook(entry) for entry in group["hooks"]):
                kept.append(group)
        if kept:
            cleaned[event] = kept
    return cleaned


def installed_events(settings: Mapping[str, Any]) -> list[str]:
    hooks = settings.get("hooks", {})
    found = []
    for event, groups in (hooks.items() if isinstance(hooks, dict) else []):
        for group in groups if isinstance(groups, list) else []:
            entries = group.get("hooks") if isinstance(group, dict) else None
            if isinstance(entries, list) and any(is_dockrail_hook(e) for e in entries):
                found.append(event)
                break
    return sorted(found)


def install_hooks(settings: dict[str, Any], command: str) -> dict[str, Any]:
    hooks = without_dockrail_hooks(settings.get("hooks", {}))
    for event, has_matcher in HOOK_EVENTS.items():
        group: dict[str, Any] = {"hooks": [{"type": "command", "command": command, "timeout": 10}]}
        if has_matcher:
            group = {"matcher": "*", **group}
        hooks[event] = list(hooks.get(event, [])) + [group]
    return dict(settings, hooks=hooks)


def uninstall_hooks(settings: dict[str, Any]) -> dict[str, Any]:
    result = dict(settings)
    hooks = without_dockrail_hooks(settings.get("hooks", {}))
    if hooks:
        result["hooks"] = hooks
    else:
        result.pop("hooks", None)
    return result


def count_sessions(env: Mapping[str, str] | None = None) -> int:
    total = 0
    for directory in state_dirs(env):
        try:
            total += sum(1 for name in os.listdir(directory) if name.endswith(".json"))
        except OSError:
            continue
    return total


def cmd_hooks(action: str) -> dict[str, Any]:
    path = claude_settings_path()
    settings = load_settings(path)
    if action == "install":
        save_settings(path, install_hooks(settings, hook_command()))
        settings = load_settings(path)
    elif action == "uninstall":
        if installed_events(settings):
            save_settings(path, uninstall_hooks(settings))
            settings = load_settings(path)
    events = installed_events(settings)
    return {
        "settingsPath": str(path),
        "installed": events == sorted(HOOK_EVENTS),
        "events": events,
        "stateDir": str(state_dirs()[0]),
        "sessionRecords": count_sessions(),
    }


def main(argv: list[str] | None = None) -> int:
    args_list = list(sys.argv[1:] if argv is None else argv)
    if args_list[:1] == ["hook"]:
        return cmd_hook()
    parser = argparse.ArgumentParser(prog="dockrail claude")
    sub = parser.add_subparsers(dest="command", required=True)
    sub.add_parser("hook", help="Claude Code hook entry point (reads stdin)")
    hooks = sub.add_parser("hooks", help="manage the Claude Code hooks Dockrail uses")
    hooks.add_argument("action", choices=("install", "uninstall", "status"))
    hooks.add_argument("--json", action="store_true")
    args = parser.parse_args(args_list)
    try:
        data = cmd_hooks(args.action)
    except CliError as exc:
        if args.json:
            print(json.dumps({"ok": False, "error": {"code": exc.code, "message": exc.message}}))
        else:
            print(f"dockrail claude: {exc.message}", file=sys.stderr)
        return 2
    if args.json:
        print(json.dumps({"ok": True, "data": data}))
        return 0
    if data["installed"]:
        print(f"Claude Code hooks installed in {data['settingsPath']}.")
        print("Restart Claude Desktop sessions so they load the hooks.")
    elif data["events"]:
        print(f"Claude Code hooks partially installed ({', '.join(data['events'])}); "
              "run: dockrail claude hooks install")
    else:
        print(f"Claude Code hooks not installed in {data['settingsPath']}.")
    print(f"Session records: {data['sessionRecords']} in {data['stateDir']}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
