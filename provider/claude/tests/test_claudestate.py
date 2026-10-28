# SPDX-License-Identifier: Apache-2.0
"""Tests for provider/claude/claudestate.py using a fake /proc tree."""
from __future__ import annotations

import json
import os
import shutil
import sys
import tempfile
import time
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))

import claudestate  # noqa: E402

NOW_MS = 1_800_000_000_000


class FakeProc:
    def __init__(self, root: Path) -> None:
        self.root = root

    def add(self, pid: int, comm: str, ppid: int, start: int, argv: list[str],
            exe: str | None = None) -> dict[str, int]:
        base = self.root / str(pid)
        base.mkdir()
        fields = ["S", str(ppid)] + ["0"] * 17 + [str(start)] + ["0"] * 30
        (base / "stat").write_bytes(f"{pid} ({comm}) {' '.join(fields)}\n".encode())
        (base / "comm").write_text(comm + "\n")
        (base / "cmdline").write_bytes(b"\0".join(a.encode() for a in argv) + b"\0")
        os.symlink(exe or argv[0], base / "exe")
        return {"pid": pid, "startTime": start}


def record(session_id: str, status: str, process: dict[str, int],
           ancestors: list[dict[str, int]], **extra: object) -> dict[str, object]:
    value: dict[str, object] = {
        "version": 1,
        "sessionId": session_id,
        "status": status,
        "event": "UserPromptSubmit",
        "cwd": "/home/me/projects/dockrail",
        "transcriptPath": "",
        "process": process,
        "ancestors": ancestors,
        "updatedAtMs": NOW_MS - 1000,
    }
    value.update(extra)
    return value


class ClaudeStateTests(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.tmp, True)
        self.proc_root = self.tmp / "proc"
        self.proc_root.mkdir()
        self.proc = FakeProc(self.proc_root)
        self.terminal = self.proc.add(10, "ghostty", 1, 100, ["/usr/bin/ghostty"])
        self.desktop = self.proc.add(
            20, "electron", 10, 200,
            ["/usr/lib/electron/electron", "/usr/lib/claude-desktop/app.asar"])
        self.utility = self.proc.add(
            21, "electron", 20, 210,
            ["/usr/lib/electron/electron", "--type=utility", "/usr/lib/claude-desktop/app.asar"])
        self.session = self.proc.add(
            30, "claude", 21, 300,
            ["/home/me/.config/Claude/claude-code/2.1.0/claude"])
        self.cli_shell = self.proc.add(40, "zsh", 10, 400, ["/usr/bin/zsh"])
        self.cli_session = self.proc.add(41, "claude", 40, 410, ["/home/me/.local/bin/claude"])

    def test_desktop_chain_stops_at_main_process(self) -> None:
        chain = claudestate.desktop_chain([self.utility, self.desktop, self.terminal],
                                          self.proc_root)
        self.assertEqual(chain, [self.utility, self.desktop])

    def test_joined_cmdline_helper_is_not_main(self) -> None:
        exe = "/usr/lib/claude-desktop/claude-desktop"
        self.proc.add(210, "claude-desktop", 20, 2100, [
            exe + " --type=utility --utility-sub-type=node.mojom.NodeService --lang=en-US"],
            exe=exe)
        self.proc.add(211, "claude-desktop", 20, 2110, [
            exe + " --type=renderer --lang=en-US /usr/lib/claude-desktop/resources/app.asar"],
            exe=exe)
        self.assertEqual(claudestate.is_desktop_process(210, self.proc_root), (True, False))
        self.assertEqual(claudestate.is_desktop_process(211, self.proc_root), (True, False))

    def test_arguments_mentioning_desktop_do_not_match(self) -> None:
        self.proc.add(220, "bash", 10, 2200,
                      ["/usr/bin/bash", "--init-file",
                       "/usr/lib/claude-desktop/resources/claude-desktop.bash"],
                      exe="/usr/bin/bash")
        self.proc.add(221, "code", 10, 2210,
                      ["/usr/bin/code", "/home/me/Projects/dockrail-claude-desktop"],
                      exe="/usr/bin/code")
        # A shared Electron runtime is matched by its app path, not later arguments.
        self.proc.add(222, "electron", 10, 2220,
                      ["/usr/lib/electron/electron", "/usr/lib/code/out/cli.js",
                       "/home/me/Projects/dockrail-claude-desktop"])
        # Electron mains usually arrive with the command line joined into argv[0].
        self.proc.add(223, "code", 10, 2230,
                      ["/usr/lib/code/code --ozone-platform=wayland "
                       "/home/me/Projects/dockrail-claude-desktop"],
                      exe="/usr/lib/code/code")
        self.proc.add(224, "electron", 10, 2240,
                      ["/usr/lib/electron/electron /usr/lib/code/out/cli.js "
                       "/home/me/Projects/dockrail-claude-desktop"],
                      exe="/usr/lib/electron/electron")
        for pid in (220, 221, 222, 223, 224):
            self.assertEqual(claudestate.is_desktop_process(pid, self.proc_root),
                             (False, False), pid)

    def test_joined_cmdline_main_matches(self) -> None:
        exe = "/usr/lib/claude-desktop/claude-desktop"
        self.proc.add(225, "claude-desktop", 10, 2250,
                      [exe + " --ozone-platform=wayland --user-data-dir=/home/me/.config/claude"],
                      exe=exe)
        self.proc.add(226, "Claude", 10, 2260,
                      ["/opt/Claude Desktop/Claude --ozone-platform=wayland"],
                      exe="/opt/Claude Desktop/Claude")
        self.proc.add(227, "electron", 10, 2270,
                      ["/usr/lib/electron/electron /usr/lib/claude-desktop/app.asar"],
                      exe="/usr/lib/electron/electron")
        for pid in (225, 226, 227):
            self.assertEqual(claudestate.is_desktop_process(pid, self.proc_root),
                             (True, True), pid)

    def test_appimage_wrapper_and_main(self) -> None:
        self.proc.add(230, "disclaimer", 231, 2300,
                      ["/tmp/.mount_ClaudeAb12/resources/disclaimer"])
        self.proc.add(231, "claude-desktop", 10, 2310,
                      ["/tmp/.mount_ClaudeAb12/claude-desktop"])
        self.assertEqual(claudestate.is_desktop_process(230, self.proc_root), (True, False))
        self.assertEqual(claudestate.is_desktop_process(231, self.proc_root), (True, True))

    def test_disclaimer_wrapper_is_not_the_main_process(self) -> None:
        claude = "/home/admin/.config/Claude/claude-code/2.1.308/f8b3641a8d36/claude"
        cli = self.proc.add(200, "claude", 201, 2000,
                            [claude, "--output-format", "stream-json"])
        wrapper = self.proc.add(
            201, "disclaimer", 202, 2010,
            ["/usr/lib/claude-desktop/resources/disclaimer", "--pgroup", "--", claude,
             "--output-format", "stream-json"])
        main = self.proc.add(
            202, "claude-desktop", 203, 2020,
            ["/usr/lib/claude-desktop/claude-desktop", "--ozone-platform=wayland",
             "--password-store=gnome-libsecret"])
        init = self.proc.add(203, "systemd", 1, 2030, ["/usr/lib/systemd/systemd", "--user"])
        self.assertEqual(claudestate.is_desktop_process(201, self.proc_root), (True, False))
        self.assertEqual(claudestate.is_desktop_process(202, self.proc_root), (True, True))
        chain = claudestate.desktop_chain([wrapper, main, init], self.proc_root)
        self.assertEqual(chain, [wrapper, main])
        records = [record("cli", "working", cli, [wrapper, main, init])]
        sessions, clients = claudestate.collect_sessions(records, self.proc_root, NOW_MS)
        self.assertEqual([s["sessionId"] for s in sessions], ["cli"])
        self.assertEqual(clients, [{"pid": 202, "startTime": 2020, "ancestors": []}])

    def test_terminal_cli_session_is_not_a_desktop_session(self) -> None:
        self.assertIsNone(claudestate.desktop_chain([self.cli_shell, self.terminal],
                                                    self.proc_root))

    def test_cli_binary_is_never_the_desktop(self) -> None:
        self.assertEqual(claudestate.is_desktop_process(30, self.proc_root), (False, False))

    def test_capitalised_official_binary_matches(self) -> None:
        self.proc.add(50, "Claude", 1, 500, ["/opt/Claude/Claude"])
        self.assertEqual(claudestate.is_desktop_process(50, self.proc_root), (True, True))

    def test_restarted_ancestor_fails_closed(self) -> None:
        stale = {"pid": 20, "startTime": 199}
        self.assertIsNone(claudestate.desktop_chain([self.utility, stale], self.proc_root))

    def test_snapshot_associates_desktop_and_reports_status(self) -> None:
        records = [
            record("desk", "working", self.session, [self.utility, self.desktop, self.terminal]),
            record("term", "working", self.cli_session, [self.cli_shell, self.terminal]),
        ]
        sessions, clients = claudestate.collect_sessions(records, self.proc_root, NOW_MS)
        self.assertEqual([s["sessionId"] for s in sessions], ["desk"])
        self.assertEqual(clients, [{"pid": 20, "startTime": 200, "ancestors": []}])
        snapshot = claudestate.build_snapshot(
            claudestate.BuildState(epoch="e", revision=1), sessions, clients)
        self.assertEqual(snapshot["servers"][0]["source"], "claude")
        self.assertEqual(snapshot["servers"][0]["id"], "claude:desktop")
        self.assertEqual(snapshot["agents"][0]["status"], "working")
        self.assertEqual(snapshot["agents"][0]["title"], "dockrail")
        self.assertEqual(snapshot["liveCounts"]["working"], 1)

    def test_dead_session_keeps_only_recent_done(self) -> None:
        dead = {"pid": 99, "startTime": 1}
        chain = [self.utility, self.desktop]
        self.assertEqual(claudestate.effective_status(
            record("a", "done", dead, chain), False, NOW_MS), "done")
        self.assertIsNone(claudestate.effective_status(
            record("a", "working", dead, chain), False, NOW_MS))
        old = record("a", "done", dead, chain, updatedAtMs=NOW_MS - claudestate.DONE_RETENTION_MS - 1)
        self.assertIsNone(claudestate.effective_status(old, False, NOW_MS))

    def test_interrupted_turn_reads_as_idle(self) -> None:
        transcript = self.tmp / "t.jsonl"
        transcript.write_text(
            json.dumps({"type": "assistant"}) + "\n"
            + json.dumps({"type": "user", "message": {"content": [
                {"type": "text", "text": "[Request interrupted by user]"}]}}) + "\n")
        value = record("a", "working", self.session, [], transcriptPath=str(transcript))
        self.assertEqual(claudestate.effective_status(value, True, NOW_MS), "idle")

    def test_stale_working_turn_reads_as_idle(self) -> None:
        value = record("a", "working", self.session, [],
                       updatedAtMs=NOW_MS - claudestate.STALE_WORKING_MS - 1)
        self.assertEqual(claudestate.effective_status(value, True, NOW_MS), "idle")
        fresh = record("a", "working", self.session, [])
        self.assertEqual(claudestate.effective_status(fresh, True, NOW_MS), "working")

    def test_read_records_validates_and_keeps_newest(self) -> None:
        first, second = self.tmp / "a", self.tmp / "b"
        first.mkdir()
        second.mkdir()
        (first / "x.json").write_text(json.dumps(record("s", "working", self.session, [])))
        (second / "y.json").write_text(json.dumps(
            record("s", "done", self.session, [], updatedAtMs=NOW_MS)))
        (second / "bad.json").write_text("{not json")
        (second / "wrong.json").write_text(json.dumps(record("t", "exploded", self.session, [])))
        os.symlink(first / "x.json", second / "link.json")
        records = claudestate.read_records([first, second])
        self.assertEqual([(r["sessionId"], r["status"]) for r in records], [("s", "done")])

    def test_state_dirs_prefer_runtime_dir(self) -> None:
        dirs = claudestate.state_dirs({"XDG_RUNTIME_DIR": "/run/user/1000", "HOME": "/home/me"})
        self.assertEqual(dirs, [Path("/run/user/1000/dockrail/claude/sessions"),
                                Path("/home/me/.local/state/dockrail/claude/sessions")])


class ProviderProcessTests(unittest.TestCase):
    def test_provider_emits_snapshot_and_echoes_window_processes(self) -> None:
        import subprocess
        state = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, state, True)
        provider = ROOT / "bin" / "dockrail-claude-provider"
        command = json.dumps({"kind": "window-processes", "revision": 4, "pids": [os.getpid()]})
        proc = subprocess.Popen(
            [sys.executable, "-B", str(provider), "--state-dir", str(state)],
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
        assert proc.stdin and proc.stdout
        proc.stdin.write(command.encode() + b"\n")
        proc.stdin.flush()
        deadline = time.monotonic() + 5
        snapshot = None
        while time.monotonic() < deadline:
            snapshot = json.loads(proc.stdout.readline())
            if snapshot["windowProcesses"]["revision"] == 4:
                break
        proc.stdin.write(b"quit\n")
        proc.stdin.close()
        proc.wait(timeout=5)
        proc.stdout.close()
        assert snapshot is not None
        self.assertEqual(snapshot["schemaVersion"], 1)
        self.assertEqual(snapshot["windowProcesses"]["revision"], 4)
        self.assertEqual(snapshot["windowProcesses"]["identities"][0]["pid"], os.getpid())
        self.assertEqual(snapshot["agents"], [])


if __name__ == "__main__":
    unittest.main()
