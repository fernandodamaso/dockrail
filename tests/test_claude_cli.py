"""Tests for scripts/dockrail_claude.py (Claude Code hooks for Claude Desktop)."""
from __future__ import annotations

import fcntl
import importlib.util
import json
import os
import shutil
import subprocess
import sys
import tempfile
import threading
import time
import unittest
from pathlib import Path
from unittest import mock

REPO = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(REPO / "scripts"))

import dockrail_claude  # noqa: E402

# Load by path: putting provider/claude on sys.path would let its `tests`
# package shadow this repository's tests namespace for later modules.
_spec = importlib.util.spec_from_file_location(
    "claudestate", REPO / "provider" / "claude" / "claudestate.py")
claudestate = importlib.util.module_from_spec(_spec)
sys.modules["claudestate"] = claudestate
_spec.loader.exec_module(claudestate)


def fake_stat(root: Path, pid: int, comm: str, ppid: int, start: int) -> None:
    base = root / str(pid)
    base.mkdir()
    fields = ["S", str(ppid)] + ["0"] * 17 + [str(start)] + ["0"] * 30
    (base / "stat").write_bytes(f"{pid} ({comm}) {' '.join(fields)}\n".encode())


def lock_is_busy(path: Path) -> bool:
    """Return whether another open file description holds the lock file."""
    fd = os.open(path, os.O_RDWR)
    try:
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        return True
    finally:
        os.close(fd)
    return False


class HookTests(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.tmp, True)
        self.proc = self.tmp / "proc"
        self.proc.mkdir()
        fake_stat(self.proc, 20, "claude-desktop", 1, 200)
        fake_stat(self.proc, 30, "claude", 20, 300)
        fake_stat(self.proc, 40, "sh", 30, 400)
        self.env = {"XDG_RUNTIME_DIR": str(self.tmp / "run"), "HOME": str(self.tmp)}

    def hook(self, payload: dict[str, object]) -> str:
        return dockrail_claude.handle_hook(payload, self.env, self.proc, parent=40)

    def records(self) -> list[dict[str, object]]:
        return claudestate.read_records(claudestate.state_dirs(self.env))

    def test_state_dirs_match_provider(self) -> None:
        for env in (self.env, {"HOME": "/h"}, {"HOME": "/h", "XDG_STATE_HOME": "/s"},
                    {"HOME": "/h", "XDG_RUNTIME_DIR": "relative"}):
            self.assertEqual(dockrail_claude.state_dirs(env), claudestate.state_dirs(env))

    def test_turn_lifecycle(self) -> None:
        base = {"session_id": "s1", "cwd": "/w/proj"}
        self.assertEqual(self.hook(dict(base, hook_event_name="SessionStart", source="startup")), "idle")
        self.assertEqual(self.hook(dict(base, hook_event_name="UserPromptSubmit", prompt="secret")), "working")
        [record] = self.records()
        self.assertEqual(record["process"], {"pid": 30, "startTime": 300})
        self.assertEqual(record["ancestors"], [{"pid": 20, "startTime": 200}])
        self.assertNotIn("secret", json.dumps(record))
        self.assertEqual(self.hook(dict(base, hook_event_name="Notification",
                                        notification_type="permission_prompt")), "blocked")
        self.assertEqual(self.hook(dict(base, hook_event_name="Notification",
                                        notification_type="idle_prompt")), "ignored")
        self.assertEqual(self.hook(dict(base, hook_event_name="PostToolUse")), "working")
        self.assertEqual(self.hook(dict(base, hook_event_name="SessionStart", source="compact")), "ignored")
        self.assertEqual(self.records()[0]["status"], "working")
        self.assertEqual(self.hook(dict(base, hook_event_name="Stop")), "done")
        self.assertEqual(self.records()[0]["status"], "done")
        self.assertEqual(self.hook(dict(base, hook_event_name="SessionEnd")), "removed")
        self.assertEqual(self.records(), [])

    def test_foreground_subagent_prompt_resumes_on_its_next_tool_call(self) -> None:
        base = {"session_id": "s2", "cwd": "/w/proj"}
        sub = dict(base, agent_id="agent-1", agent_type="Explore")
        # Claude Code sends Notification without agent_id; the subagent's tool call carries it.
        prompt = dict(base, hook_event_name="Notification", notification_type="permission_prompt")
        self.hook(dict(base, hook_event_name="UserPromptSubmit"))
        self.assertEqual(self.hook(prompt), "blocked")
        [record] = self.records()
        self.assertEqual((record["pendingPrompt"], record["resumeStatus"]), (True, "working"))
        self.assertEqual(self.hook(dict(sub, hook_event_name="PostToolUse", tool_name="Bash")), "working")
        [record] = self.records()
        self.assertEqual(record["status"], "working")
        for key in ("pendingPrompt", "resumeStatus", "resumeUpdatedAtMs"):
            self.assertNotIn(key, record)

    def test_background_subagent_prompt_after_stop_restores_done_time(self) -> None:
        base = {"session_id": "s15", "cwd": "/w/proj"}
        sub = dict(base, agent_id="agent-1")
        prompt = dict(base, hook_event_name="Notification", notification_type="permission_prompt")
        with mock.patch.object(dockrail_claude.time, "time", return_value=1_000_000_000.0):
            self.hook(dict(base, hook_event_name="UserPromptSubmit"))
            self.assertEqual(self.hook(dict(base, hook_event_name="Stop")), "done")
        self.assertEqual(self.hook(prompt), "blocked")
        [record] = self.records()
        self.assertEqual((record["resumeStatus"], record["resumeUpdatedAtMs"]), ("done", 1_000_000_000_000))
        self.assertEqual(self.hook(dict(sub, hook_event_name="PostToolUse", tool_name="Bash")), "done")
        [record] = self.records()
        self.assertEqual((record["status"], record["updatedAtMs"]), ("done", 1_000_000_000_000))
        self.assertNotIn("pendingPrompt", record)
        # Once answered, a finished subagent's later tool calls change nothing.
        self.assertEqual(self.hook(dict(sub, hook_event_name="PostToolUse", tool_name="Bash")), "ignored")

    def test_subagent_prompt_during_pending_question_restores_question(self) -> None:
        base = {"session_id": "s16", "cwd": "/w/proj"}
        sub = dict(base, agent_id="agent-1")
        prompt = dict(base, hook_event_name="Notification", notification_type="permission_prompt")
        self.hook(dict(base, hook_event_name="UserPromptSubmit"))
        with mock.patch.object(dockrail_claude.time, "time", return_value=1_000_000_000.0):
            self.hook(dict(base, hook_event_name="PostToolUse", tool_name="mcp__ccd_turn__wrap_up",
                           tool_input={"ask": "Which?"}))
            self.assertEqual(self.hook(dict(base, hook_event_name="Stop")), "blocked")
        self.assertEqual(self.hook(prompt), "blocked")
        [record] = self.records()
        self.assertEqual((record["resumeStatus"], record["awaitingUser"]), ("blocked", True))
        self.assertEqual(self.hook(dict(sub, hook_event_name="PostToolUse", tool_name="Bash")), "blocked")
        [record] = self.records()
        self.assertEqual((record["status"], record["awaitingUser"], record["updatedAtMs"]),
                         ("blocked", True, 1_000_000_000_000))
        self.assertNotIn("pendingPrompt", record)

    def test_stop_during_pending_prompt_keeps_turn_blocked_until_answered(self) -> None:
        base = {"session_id": "s17", "cwd": "/w/proj"}
        sub = dict(base, agent_id="agent-1")
        prompt = dict(base, hook_event_name="Notification", notification_type="permission_prompt")
        self.hook(dict(base, hook_event_name="UserPromptSubmit"))
        self.assertEqual(self.hook(prompt), "blocked")
        self.assertEqual(self.hook(dict(base, hook_event_name="Stop")), "blocked")
        [record] = self.records()
        self.assertEqual((record["status"], record["pendingPrompt"], record["resumeStatus"]),
                         ("blocked", True, "done"))
        self.assertIn("resumeUpdatedAtMs", record)
        self.assertEqual(self.hook(dict(sub, hook_event_name="PostToolUse", tool_name="Bash")), "done")
        self.assertEqual(self.records()[0]["status"], "done")

    def test_every_blocking_notification_type_blocks(self) -> None:
        base = {"session_id": "s18", "cwd": "/w/proj"}
        self.hook(dict(base, hook_event_name="UserPromptSubmit"))
        for kind in ("permission_prompt", "elicitation_dialog", "worker_permission_prompt",
                     "agent_needs_input", "elicitation_url_dialog"):
            with self.subTest(kind=kind):
                self.assertEqual(self.hook(dict(base, hook_event_name="Notification",
                                                notification_type=kind)), "blocked")
                self.hook(dict(base, hook_event_name="UserPromptSubmit"))
        # The legacy message heuristic still blocks a prompt without a notification_type.
        self.assertEqual(self.hook(dict(base, hook_event_name="Notification", message="Needs permission")),
                         "blocked")
        self.hook(dict(base, hook_event_name="UserPromptSubmit"))
        self.assertEqual(self.hook(dict(base, hook_event_name="Notification", notification_type="idle_prompt")),
                         "ignored")

    def test_user_prompt_and_main_tool_call_clear_pending_prompt(self) -> None:
        base = {"session_id": "s19", "cwd": "/w/proj"}
        prompt = dict(base, hook_event_name="Notification", notification_type="permission_prompt")
        self.hook(dict(base, hook_event_name="UserPromptSubmit"))
        self.assertEqual(self.hook(prompt), "blocked")
        self.assertEqual(self.hook(dict(base, hook_event_name="UserPromptSubmit")), "working")
        for key in ("pendingPrompt", "resumeStatus", "resumeUpdatedAtMs"):
            self.assertNotIn(key, self.records()[0])
        self.assertEqual(self.hook(prompt), "blocked")
        self.assertEqual(self.hook(dict(base, hook_event_name="PostToolUse", tool_name="Bash")), "working")
        [record] = self.records()
        self.assertEqual(record["status"], "working")
        for key in ("pendingPrompt", "resumeStatus", "resumeUpdatedAtMs"):
            self.assertNotIn(key, record)

    def test_subagent_events_refresh_only_working_turns(self) -> None:
        base = {"session_id": "s20", "cwd": "/w/proj"}
        sub = dict(base, agent_id="agent-1")
        post = dict(sub, hook_event_name="PostToolUse", tool_name="Bash")
        self.assertEqual(self.hook(post), "ignored")
        self.hook(dict(base, hook_event_name="UserPromptSubmit"))
        with mock.patch.object(dockrail_claude.time, "time", return_value=1_000_000_000.0):
            self.assertEqual(self.hook(post), "working")
        [record] = self.records()
        self.assertEqual((record["status"], record["updatedAtMs"]), ("working", 1_000_000_000_000))
        self.assertEqual(self.hook(dict(base, hook_event_name="Stop")), "done")
        self.assertEqual(self.hook(post), "ignored")
        # Subagent SessionEnd never removes the parent record.
        self.assertEqual(self.hook(dict(sub, hook_event_name="SessionEnd")), "ignored")
        self.assertEqual(self.records()[0]["status"], "done")

    def test_agent_tagged_prompt_also_blocks(self) -> None:
        base = {"session_id": "s21", "cwd": "/w/proj"}
        sub = dict(base, agent_id="agent-1")
        self.hook(dict(base, hook_event_name="UserPromptSubmit"))
        self.assertEqual(self.hook(dict(sub, hook_event_name="Notification",
                                        notification_type="elicitation_dialog")), "blocked")
        self.assertIs(self.records()[0]["pendingPrompt"], True)
        self.assertEqual(self.hook(dict(sub, hook_event_name="PostToolUse", tool_name="Bash")), "working")

    def test_subagent_events_keep_awaiting_user(self) -> None:
        base = {"session_id": "s7", "cwd": "/w/proj"}
        sub = dict(base, agent_id="agent-1")
        self.hook(dict(base, hook_event_name="UserPromptSubmit"))
        self.hook(dict(base, hook_event_name="PostToolUse", tool_name="mcp__ccd_turn__wrap_up",
                       tool_input={"ask": "Which?"}))
        self.assertEqual(self.hook(dict(base, hook_event_name="Notification",
                                        notification_type="permission_prompt")), "blocked")
        self.assertIs(self.records()[0]["awaitingUser"], True)
        self.assertEqual(self.hook(dict(sub, hook_event_name="PostToolUse", tool_name="Bash")), "working")
        self.assertIs(self.records()[0]["awaitingUser"], True)
        self.assertEqual(self.hook(dict(base, hook_event_name="Stop")), "blocked")

    def test_subagent_prompt_keeps_pending_question_blocked_across_stop(self) -> None:
        base = {"session_id": "s14", "cwd": "/w/proj"}
        sub = dict(base, agent_id="agent-1")
        self.hook(dict(base, hook_event_name="UserPromptSubmit"))
        self.hook(dict(base, hook_event_name="PostToolUse", tool_name="mcp__ccd_turn__wrap_up",
                       tool_input={"ask": "Which?"}))
        self.assertEqual(self.hook(dict(base, hook_event_name="Stop")), "blocked")
        self.assertEqual(self.hook(dict(base, hook_event_name="Notification",
                                        notification_type="permission_prompt")), "blocked")
        [record] = self.records()
        self.assertEqual((record["resumeStatus"], record["awaitingUser"]), ("blocked", True))
        self.assertEqual(self.hook(dict(sub, hook_event_name="PostToolUse", tool_name="Bash")), "blocked")
        [record] = self.records()
        self.assertEqual(record["status"], "blocked")
        self.assertIs(record["awaitingUser"], True)
        self.assertNotIn("pendingPrompt", record)

    def test_ask_user_question_blocks_until_answered(self) -> None:
        base = {"session_id": "s3", "cwd": "/w/proj"}
        self.hook(dict(base, hook_event_name="UserPromptSubmit"))
        ask = dict(base, hook_event_name="PreToolUse", tool_name="AskUserQuestion",
                   tool_input={"questions": [{"question": "Which branch?"}]})
        self.assertEqual(self.hook(ask), "blocked")
        self.assertEqual(self.records()[0]["status"], "blocked")
        self.assertNotIn("Which branch", json.dumps(self.records()))
        self.assertEqual(self.hook(dict(base, hook_event_name="PostToolUse", tool_name="AskUserQuestion")),
                         "working")
        self.assertEqual(self.records()[0]["status"], "working")
        self.assertEqual(self.hook(dict(base, hook_event_name="PreToolUse", tool_name="Bash")), "ignored")

    def test_wrap_up_question_keeps_turn_blocked_at_stop(self) -> None:
        base = {"session_id": "s4", "cwd": "/w/proj"}
        self.hook(dict(base, hook_event_name="UserPromptSubmit"))
        wrap_up = dict(base, hook_event_name="PostToolUse", tool_name="mcp__ccd_turn__wrap_up",
                       tool_input={"ask": "SECRET QUESTION?"})
        self.assertEqual(self.hook(wrap_up), "working")
        [record] = self.records()
        self.assertIs(record["awaitingUser"], True)
        self.assertNotIn("SECRET", json.dumps(record))
        self.assertEqual(self.hook(dict(base, hook_event_name="PostToolUse", tool_name="Bash")), "working")
        self.assertIs(self.records()[0]["awaitingUser"], True)
        self.assertEqual(self.hook(dict(base, hook_event_name="Stop")), "blocked")
        [record] = self.records()
        self.assertEqual(record["status"], "blocked")
        self.assertIs(record["awaitingUser"], True)
        self.assertNotIn("SECRET", json.dumps(self.records()))

    def test_turn_without_question_ends_done(self) -> None:
        base = {"session_id": "s5", "cwd": "/w/proj"}
        self.hook(dict(base, hook_event_name="UserPromptSubmit"))
        cases = (
            ("mcp__ccd_turn__wrap_up", {}),
            ("mcp__ccd_turn__wrap_up", {"ask": ""}),
            ("mcp__ccd_turn__wrap_up", {"ask": None}),
            ("mcp__other__wrap_up", {"ask": "Not Claude Desktop"}),
        )
        for tool_name, tool_input in cases:
            with self.subTest(tool_name=tool_name, tool_input=tool_input):
                self.assertEqual(self.hook(dict(base, hook_event_name="PostToolUse", tool_name=tool_name,
                                                tool_input=tool_input)), "working")
                self.assertNotIn("awaitingUser", self.records()[0])
                self.assertEqual(self.hook(dict(base, hook_event_name="Stop")), "done")

    def test_awaiting_user_is_cleared_by_next_prompt(self) -> None:
        base = {"session_id": "s6", "cwd": "/w/proj"}
        self.hook(dict(base, hook_event_name="UserPromptSubmit"))
        self.hook(dict(base, hook_event_name="PostToolUse", tool_name="mcp__ccd_turn__wrap_up",
                       tool_input={"ask": "Which?"}))
        self.assertEqual(self.hook(dict(base, hook_event_name="UserPromptSubmit")), "working")
        self.assertNotIn("awaitingUser", self.records()[0])
        self.assertEqual(self.hook(dict(base, hook_event_name="Stop")), "done")

    def test_wrap_up_without_question_clears_awaiting_user(self) -> None:
        base = {"session_id": "s8", "cwd": "/w/proj"}
        self.hook(dict(base, hook_event_name="UserPromptSubmit"))
        self.hook(dict(base, hook_event_name="PostToolUse", tool_name="mcp__ccd_turn__wrap_up",
                       tool_input={"ask": "Which?"}))
        self.assertIs(self.records()[0]["awaitingUser"], True)
        self.assertEqual(self.hook(dict(base, hook_event_name="PostToolUse", tool_name="mcp__ccd_turn__wrap_up",
                                        tool_input={})), "working")
        self.assertNotIn("awaitingUser", self.records()[0])
        self.assertEqual(self.hook(dict(base, hook_event_name="Stop")), "done")

    def test_session_start_clears_awaiting_user_unless_compacting(self) -> None:
        base = {"session_id": "s9", "cwd": "/w/proj"}
        ask = dict(base, hook_event_name="PostToolUse", tool_name="mcp__ccd_turn__wrap_up",
                   tool_input={"ask": "Which?"})
        for source in ("startup", "resume"):
            with self.subTest(source=source):
                self.hook(ask)
                self.assertEqual(self.hook(dict(base, hook_event_name="SessionStart", source=source)), "idle")
                self.assertNotIn("awaitingUser", self.records()[0])
        self.hook(ask)
        self.assertEqual(self.hook(dict(base, hook_event_name="SessionStart", source="compact")), "ignored")
        self.assertIs(self.records()[0]["awaitingUser"], True)
        self.assertEqual(self.hook(dict(base, hook_event_name="Stop")), "blocked")

    def test_session_lock_is_held_during_update_and_removed_on_session_end(self) -> None:
        base = {"session_id": "s10", "cwd": "/w/proj"}
        lock = dockrail_claude.lock_path(dockrail_claude.state_dirs(self.env)[0], "s10")
        self.assertEqual(lock.suffix, ".lock")
        busy: list[bool] = []
        real_write = dockrail_claude.write_record

        def probing_write(directory: Path, record: dict[str, object]) -> None:
            busy.append(lock.exists() and lock_is_busy(lock))
            real_write(directory, record)

        with mock.patch.object(dockrail_claude, "write_record", probing_write):
            self.hook(dict(base, hook_event_name="UserPromptSubmit"))
        self.assertEqual(busy, [True])
        self.assertFalse(lock_is_busy(lock))
        self.assertEqual(self.hook(dict(base, hook_event_name="SessionEnd")), "removed")
        self.assertFalse(lock.exists())
        self.assertEqual(self.records(), [])

    def test_session_lock_is_released_when_update_fails(self) -> None:
        base = {"session_id": "s11", "cwd": "/w/proj"}
        lock = dockrail_claude.lock_path(dockrail_claude.state_dirs(self.env)[0], "s11")
        with mock.patch.object(dockrail_claude, "write_record", side_effect=RuntimeError("disk full")):
            with self.assertRaises(RuntimeError):
                self.hook(dict(base, hook_event_name="UserPromptSubmit"))
        self.assertFalse(lock_is_busy(lock))

    def test_hook_proceeds_unlocked_when_session_lock_stays_busy(self) -> None:
        base = {"session_id": "s12", "cwd": "/w/proj"}
        directory = dockrail_claude.state_dirs(self.env)[0]
        directory.mkdir(parents=True)
        holder = os.open(dockrail_claude.lock_path(directory, "s12"), os.O_RDWR | os.O_CREAT, 0o600)
        self.addCleanup(os.close, holder)
        fcntl.flock(holder, fcntl.LOCK_EX)
        with mock.patch.object(dockrail_claude, "LOCK_WAIT_SECONDS", 0.1):
            self.assertEqual(self.hook(dict(base, hook_event_name="UserPromptSubmit")), "working")
        self.assertEqual(self.records()[0]["status"], "working")

    def test_parallel_hooks_do_not_lose_awaiting_user(self) -> None:
        base = {"session_id": "s13", "cwd": "/w/proj"}
        self.hook(dict(base, hook_event_name="UserPromptSubmit"))
        real_write = dockrail_claude.write_record
        slow_started = threading.Event()

        def slow_first_write(directory: Path, record: dict[str, object]) -> None:
            if not slow_started.is_set():
                # The Bash hook holds the session lock while it sleeps before writing.
                slow_started.set()
                time.sleep(0.2)
            real_write(directory, record)

        results: dict[str, str] = {}
        slow = threading.Thread(target=lambda: results.setdefault(
            "bash", self.hook(dict(base, hook_event_name="PostToolUse", tool_name="Bash"))))
        fast = threading.Thread(target=lambda: results.setdefault(
            "wrap_up", self.hook(dict(base, hook_event_name="PostToolUse", tool_name="mcp__ccd_turn__wrap_up",
                                      tool_input={"ask": "Which?"}))))
        with mock.patch.object(dockrail_claude, "write_record", slow_first_write):
            slow.start()
            self.assertTrue(slow_started.wait(5))
            fast.start()
            slow.join()
            fast.join()
        self.assertEqual(results, {"bash": "working", "wrap_up": "working"})
        self.assertIs(self.records()[0]["awaitingUser"], True)

    def test_invalid_session_id_is_ignored(self) -> None:
        self.assertEqual(self.hook({"hook_event_name": "Stop", "session_id": ""}), "ignored")
        self.assertEqual(self.hook({"hook_event_name": "Stop"}), "ignored")

    def test_hook_entry_point_never_fails(self) -> None:
        script = REPO / "scripts" / "dockrail_claude.py"
        result = subprocess.run([sys.executable, "-B", str(script), "hook"], input=b"not json",
                                capture_output=True, env=dict(os.environ, **self.env))
        self.assertEqual((result.returncode, result.stdout, result.stderr), (0, b"", b""))


class ReadRecordTests(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.tmp, True)
        self.directory = self.tmp / "sessions"
        self.directory.mkdir()
        self.path = dockrail_claude.record_path(self.directory, "s20")

    def test_reads_regular_record(self) -> None:
        self.path.write_text(json.dumps({"status": "done"}))
        self.assertEqual(dockrail_claude.read_record(self.directory, "s20"), {"status": "done"})

    def test_refuses_fifo(self) -> None:
        os.mkfifo(self.path)
        self.assertEqual(dockrail_claude.read_record(self.directory, "s20"), {})

    def test_refuses_symlink(self) -> None:
        target = self.tmp / "target.json"
        target.write_text(json.dumps({"status": "done"}))
        self.path.symlink_to(target)
        self.assertEqual(dockrail_claude.read_record(self.directory, "s20"), {})

    def test_refuses_oversize_record(self) -> None:
        padding = "x" * dockrail_claude.MAX_RECORD_BYTES
        self.path.write_text(json.dumps({"status": "done", "pad": padding}))
        self.assertEqual(dockrail_claude.read_record(self.directory, "s20"), {})


class HooksInstallTests(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.tmp, True)
        self.settings = self.tmp / ".claude" / "settings.json"
        self.settings.parent.mkdir()
        patcher = mock.patch.dict(os.environ, {"HOME": str(self.tmp),
                                               "XDG_RUNTIME_DIR": str(self.tmp / "run")})
        patcher.start()
        self.addCleanup(patcher.stop)
        os.environ.pop("CLAUDE_CONFIG_DIR", None)

    def test_install_preserves_user_hooks_and_is_idempotent(self) -> None:
        user_hook = {"matcher": "Bash", "hooks": [{"type": "command", "command": "my-lint"}]}
        self.settings.write_text(json.dumps({
            "model": "opus", "hooks": {"PostToolUse": [user_hook]}}))
        for _ in range(2):
            data = dockrail_claude.cmd_hooks("install")
        self.assertTrue(data["installed"])
        settings = json.loads(self.settings.read_text())
        self.assertEqual(settings["model"], "opus")
        post = settings["hooks"]["PostToolUse"]
        self.assertEqual(post[0], user_hook)
        self.assertEqual(len(post), 2)
        self.assertEqual(post[1]["matcher"], "*")
        pre = settings["hooks"]["PreToolUse"]
        self.assertEqual(len(pre), 1)
        self.assertEqual(pre[0]["matcher"], "AskUserQuestion")
        self.assertIn("PreToolUse", data["events"])
        command = settings["hooks"]["Stop"][0]["hooks"][0]["command"]
        self.assertIn("dockrail_claude.py", command)
        self.assertTrue(command.endswith("|| true"))
        self.assertEqual(sorted(settings["hooks"]), sorted(dockrail_claude.HOOK_EVENTS))

        data = dockrail_claude.cmd_hooks("uninstall")
        self.assertFalse(data["installed"])
        self.assertEqual(json.loads(self.settings.read_text()),
                         {"model": "opus", "hooks": {"PostToolUse": [user_hook]}})

    def test_install_missing_pretooluse_is_partial_until_reinstalled(self) -> None:
        settings = dockrail_claude.install_hooks({}, dockrail_claude.hook_command())
        del settings["hooks"]["PreToolUse"]
        self.settings.write_text(json.dumps(settings))
        data = dockrail_claude.cmd_hooks("status")
        self.assertFalse(data["installed"])
        self.assertNotIn("PreToolUse", data["events"])
        data = dockrail_claude.cmd_hooks("install")
        self.assertTrue(data["installed"])
        self.assertIn("PreToolUse", data["events"])

    def test_invalid_settings_are_never_overwritten(self) -> None:
        self.settings.write_text("{broken")
        with self.assertRaises(dockrail_claude.CliError):
            dockrail_claude.cmd_hooks("install")
        self.assertEqual(self.settings.read_text(), "{broken")

    def test_status_json(self) -> None:
        script = REPO / "scripts" / "dockrail_claude.py"
        result = subprocess.run([sys.executable, "-B", str(script), "hooks", "status", "--json"],
                                capture_output=True, text=True, env=dict(os.environ))
        payload = json.loads(result.stdout)
        self.assertTrue(payload["ok"])
        self.assertFalse(payload["data"]["installed"])
        self.assertEqual(payload["data"]["settingsPath"], str(self.settings))


if __name__ == "__main__":
    unittest.main()
