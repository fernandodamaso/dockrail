# SPDX-License-Identifier: Apache-2.0
"""Claude Desktop session state for Dockrail through Claude Code hooks.

Claude Desktop runs Claude Code sessions as child processes. Claude Code
hooks report each turn's lifecycle; ``hook`` turns those events into one
small per-session record that ``provider/claude`` reads to animate the Claude
Desktop dock icon and sidebar row. Prompts, messages and tool input are never
stored.

Self-contained: it must also run from a ``--cli-only`` install that ships no
``provider/`` directory, so the state-directory rule is duplicated here (a
parity test keeps both copies equal).

Subcommands: ``hooks install|uninstall|status [--json]`` and ``hook`` (the
hook entry point; reads the Claude Code hook payload on stdin, never fails).
"""
from __future__ import annotations

import argparse
import contextlib
import fcntl
import hashlib
import json
import os
import re
import shlex
import stat
import sys
import tempfile
import time
from pathlib import Path
from typing import Any, Iterator, Mapping

HOOK_MARKER = "dockrail_claude.py"
MAX_PAYLOAD_BYTES = 1024 * 1024
MAX_ANCESTORS = 16
MAX_RECORD_BYTES = 64 * 1024
# Hooks for parallel tool calls can overlap; wait briefly for the session lock.
LOCK_WAIT_SECONDS = 2.0
LOCK_POLL_SECONDS = 0.02
SHELL_NAMES = ("sh", "bash", "dash", "zsh", "fish", "env", "timeout", "nice")
# Event -> tool matcher Claude Code applies to it (None: no matcher).
HOOK_EVENTS: dict[str, str | None] = {
    "SessionStart": None,
    "UserPromptSubmit": None,
    "PreToolUse": "AskUserQuestion",
    "PostToolUse": "*",
    "Notification": None,
    "Stop": None,
    "SessionEnd": None,
}
BLOCKING_NOTIFICATIONS = (
    "permission_prompt",
    "elicitation_dialog",
    "worker_permission_prompt",
    "agent_needs_input",
    "elicitation_url_dialog",
)
# Record fields that describe an open prompt and what the session resumes to.
PROMPT_FIELDS = ("pendingPrompt", "resumeStatus", "resumeUpdatedAtMs")
ASK_USER_TOOL = "AskUserQuestion"
# Claude Desktop's end-of-turn tool; a non-empty ``ask`` input is a question.
WRAP_UP_TOOL = re.compile(r"mcp__.*ccd_turn__wrap_up")


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


def is_wrap_up(payload: Mapping[str, Any]) -> bool:
    tool = payload.get("tool_name")
    return (
        payload.get("hook_event_name") == "PostToolUse"
        and isinstance(tool, str)
        and WRAP_UP_TOOL.fullmatch(tool) is not None
    )


def asks_user(payload: Mapping[str, Any]) -> bool:
    """Return whether a PostToolUse carries Claude's end-of-turn question."""
    tool_input = payload.get("tool_input")
    return (
        is_wrap_up(payload)
        and isinstance(tool_input, dict)
        and isinstance(tool_input.get("ask"), str)
        and bool(tool_input["ask"])
    )


def has_background_tasks(payload: Mapping[str, Any]) -> bool:
    """Return whether a Stop payload reports background work still in flight."""
    tasks = payload.get("background_tasks")
    return bool(tasks) and not isinstance(tasks, str)


def status_for(payload: Mapping[str, Any], awaiting_user: bool = False) -> str | None:
    """Map one hook payload to a session status; ``None`` keeps the record."""
    event = payload.get("hook_event_name")
    if event == "SessionStart":
        return None if payload.get("source") == "compact" else "idle"
    if event == "PreToolUse":
        return "blocked" if payload.get("tool_name") == ASK_USER_TOOL else None
    if event in ("UserPromptSubmit", "PostToolUse"):
        return "working"
    if event == "Stop":
        if awaiting_user:
            return "blocked"
        # A turn that ends while background agents still run stays working until they finish.
        return "working" if has_background_tasks(payload) else "done"
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


def lock_path(directory: Path, session_id: str) -> Path:
    return record_path(directory, session_id).with_suffix(".lock")


def read_record(directory: Path, session_id: str) -> dict[str, Any]:
    """Return the stored record for a session, or ``{}`` when none is readable."""
    try:
        fd = os.open(record_path(directory, session_id), os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    except OSError:
        return {}
    try:
        info = os.fstat(fd)
        if not stat.S_ISREG(info.st_mode) or info.st_size > MAX_RECORD_BYTES:
            return {}
        data = os.read(fd, MAX_RECORD_BYTES + 1)
    except OSError:
        return {}
    finally:
        os.close(fd)
    if len(data) > MAX_RECORD_BYTES:
        return {}
    try:
        record = json.loads(data)
    except ValueError:
        return {}
    return record if isinstance(record, dict) else {}


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


@contextlib.contextmanager
def session_lock(directory: Path, session_id: str) -> Iterator[None]:
    """Hold an exclusive per-session lock; after a bounded wait, proceed unlocked."""
    fd: int | None = None
    try:
        directory.mkdir(mode=0o700, parents=True, exist_ok=True)
        fd = os.open(lock_path(directory, session_id), os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW, 0o600)
        deadline = time.monotonic() + LOCK_WAIT_SECONDS
        while True:
            try:
                fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
                break
            except BlockingIOError:
                if time.monotonic() >= deadline:
                    break
                time.sleep(LOCK_POLL_SECONDS)
    except OSError:
        pass
    try:
        yield
    finally:
        if fd is not None:
            os.close(fd)  # Closing the descriptor releases the flock.


def prompt_fields(record: Mapping[str, Any]) -> dict[str, Any]:
    """Return the fields a blocking prompt adds; an open prompt keeps its resume state."""
    if record.get("pendingPrompt") is True:
        kept = {key: record[key] for key in ("resumeStatus", "resumeUpdatedAtMs") if key in record}
        return dict(kept, pendingPrompt=True)
    previous = record.get("status")
    fields: dict[str, Any] = {
        "pendingPrompt": True,
        "resumeStatus": previous if isinstance(previous, str) and previous else "working",
    }
    seen_ms = record.get("updatedAtMs")
    if isinstance(seen_ms, int):
        fields["resumeUpdatedAtMs"] = seen_ms
    return fields


def subagent_update(payload: Mapping[str, Any], record: dict[str, Any], now: int) -> dict[str, Any] | None:
    """Return the record after a subagent event, or ``None`` to leave it unchanged.

    Claude Code does not say which agent a prompt belongs to, so a session tracks
    one pending prompt. The next completed tool call, from Claude or a subagent,
    answers it and the state from before the prompt returns. A subagent tool call
    after a finished turn means background work is still running, so it reopens
    the turn as working. Subagent payloads never supply cwd, transcript or
    process, and never touch awaitingUser.
    """
    if not record or record.get("sessionId") != payload.get("session_id"):
        return None
    event = payload.get("hook_event_name")
    if event == "Notification" and status_for(payload) == "blocked":
        blocked = dict(record, status="blocked", updatedAtMs=now)
        blocked.update(prompt_fields(record))
        return blocked
    if record.get("pendingPrompt") is True:
        if event != "PostToolUse":
            return None
        resume = record.get("resumeStatus")
        status = resume if isinstance(resume, str) and resume else "working"
        resumed = {key: value for key, value in record.items() if key not in PROMPT_FIELDS}
        resumed["status"] = status
        # A restored finished or question state keeps the time the user last saw it.
        seen_ms = record.get("resumeUpdatedAtMs")
        keeps_seen_time = status in ("done", "blocked") and isinstance(seen_ms, int)
        resumed["updatedAtMs"] = seen_ms if keeps_seen_time else now
        return resumed
    if record.get("status") == "working":
        return dict(record, updatedAtMs=now)
    if event == "PostToolUse" and record.get("status") == "done":
        return dict(record, status="working", updatedAtMs=now)
    return None


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
    # Subagent hooks share the parent session_id; they may only mark or answer the
    # parent's prompt, and SessionEnd from a subagent never removes the record.
    agent_id = payload.get("agent_id")
    subagent = isinstance(agent_id, str) and bool(agent_id)
    event = payload.get("hook_event_name")
    if subagent and event == "SessionEnd":
        return "ignored"
    directory = state_dirs(env)[0]
    with session_lock(directory, session_id):
        if event == "SessionEnd":
            for path in (record_path(directory, session_id), lock_path(directory, session_id)):
                try:
                    os.unlink(path)
                except OSError:
                    pass
            return "removed"
        record = read_record(directory, session_id)
        now = int(time.time() * 1000)
        if subagent:
            updated = subagent_update(payload, record, now)
            if updated is None:
                return "ignored"
            write_record(directory, updated)
            return str(updated["status"])
        # Claude is waiting on the user after its end-of-turn question until the next prompt
        # or a fresh session; a wrap_up without a question clears a stale flag.
        awaiting = record.get("awaitingUser") is True
        if event == "UserPromptSubmit" or (event == "SessionStart" and payload.get("source") != "compact"):
            awaiting = False
        elif is_wrap_up(payload):
            awaiting = asks_user(payload)
        status = status_for(payload, awaiting)
        if status is None:
            return "ignored"
        prompt: dict[str, Any] = {}
        if event == "Notification" and status == "blocked":
            prompt = prompt_fields(record)
        elif event == "Stop" and record.get("pendingPrompt") is True:
            # A subagent's prompt is still open: the turn stays input needed until it is answered.
            prompt = {"pendingPrompt": True, "resumeStatus": status, "resumeUpdatedAtMs": now}
            status = "blocked"
        session, ancestors = process_chain(os.getppid() if parent is None else parent, proc_root)
        if session is None:
            return "ignored"
        cwd = payload.get("cwd")
        transcript = payload.get("transcript_path")
        new_record: dict[str, Any] = {
            "version": 1,
            "sessionId": session_id,
            "status": status,
            "event": str(event),
            "cwd": cwd if isinstance(cwd, str) else "",
            "transcriptPath": transcript if isinstance(transcript, str) else "",
            "process": session,
            "ancestors": ancestors,
            "updatedAtMs": now,
        }
        new_record.update(prompt)
        if awaiting:
            new_record["awaitingUser"] = True
        write_record(directory, new_record)
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
    for event, matcher in HOOK_EVENTS.items():
        group: dict[str, Any] = {"hooks": [{"type": "command", "command": command, "timeout": 10}]}
        if matcher is not None:
            group = {"matcher": matcher, **group}
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
