"""Tests for scripts/dockrail_claude.py (Claude Code hooks for Claude Desktop)."""
from __future__ import annotations

import importlib.util
import json
import os
import shutil
import subprocess
import sys
import tempfile
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

    def test_invalid_session_id_is_ignored(self) -> None:
        self.assertEqual(self.hook({"hook_event_name": "Stop", "session_id": ""}), "ignored")
        self.assertEqual(self.hook({"hook_event_name": "Stop"}), "ignored")

    def test_hook_entry_point_never_fails(self) -> None:
        script = REPO / "scripts" / "dockrail_claude.py"
        result = subprocess.run([sys.executable, "-B", str(script), "hook"], input=b"not json",
                                capture_output=True, env=dict(os.environ, **self.env))
        self.assertEqual((result.returncode, result.stdout, result.stderr), (0, b"", b""))


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
        command = settings["hooks"]["Stop"][0]["hooks"][0]["command"]
        self.assertIn("dockrail_claude.py", command)
        self.assertTrue(command.endswith("|| true"))
        self.assertEqual(sorted(settings["hooks"]), sorted(dockrail_claude.HOOK_EVENTS))

        data = dockrail_claude.cmd_hooks("uninstall")
        self.assertFalse(data["installed"])
        self.assertEqual(json.loads(self.settings.read_text()),
                         {"model": "opus", "hooks": {"PostToolUse": [user_hook]}})

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
