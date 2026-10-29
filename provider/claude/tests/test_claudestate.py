# SPDX-License-Identifier: Apache-2.0
"""Tests for provider/claude/claudestate.py using a fake /proc tree."""
from __future__ import annotations

import json
import os
import shutil
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path
from typing import Any
from unittest import mock

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


def desktop_file(root: Path, desktop_id: str, cli_id: str, **extra: object) -> Path:
    """Write one Claude Desktop Code-session file under ``root``."""
    directory = root / "org" / "account"
    directory.mkdir(parents=True, exist_ok=True)
    value: dict[str, object] = {
        "sessionId": desktop_id,
        "cliSessionId": cli_id,
        "title": "Work title",
        "isArchived": False,
        "lastFocusedAt": NOW_MS - 5000,
    }
    value.update(extra)
    path = directory / f"{desktop_id}.json"
    path.write_text(json.dumps(value))
    return path


def desktop_meta(**extra: Any) -> dict[str, Any]:
    """Return one parsed Desktop metadata entry as ``desktop_sessions`` reports it."""
    value: dict[str, Any] = {
        "desktopSessionId": "local_x",
        "title": "Work title",
        "archived": False,
        "lastFocusedAt": None,
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

    def test_desktop_session_dirs_prefer_absolute_xdg_config(self) -> None:
        self.assertEqual(
            claudestate.desktop_session_dirs({"XDG_CONFIG_HOME": "/cfg", "HOME": "/home/me"}),
            [Path("/cfg/Claude/claude-code-sessions")])
        self.assertEqual(
            claudestate.desktop_session_dirs({"XDG_CONFIG_HOME": "cfg", "HOME": "/home/me"}),
            [Path("/home/me/.config/Claude/claude-code-sessions")])

    def test_desktop_sessions_parses_and_validates_fields(self) -> None:
        root = self.tmp / "sessions"
        desktop_file(root, "local_aaa", "cli-a", title="  Fix\x07 the\x00 rail  ",
                     isArchived=True, lastFocusedAt=123)
        desktop_file(root, "local_bad id", "cli-b")
        desktop_file(root, "local_wrong", "cli-c", title=7, isArchived="yes",
                     lastFocusedAt="soon")
        desktop_file(root, "local_long", "cli-d", title="x" * 300)
        desktop_file(root, "local_nocli", "cli-e", cliSessionId=None)
        (root / "org" / "account" / "local_junk.json").write_text("{not json")
        oversize = "y" * (claudestate.MAX_DESKTOP_SESSION_BYTES + 1)
        desktop_file(root, "local_big", "cli-f", title=oversize)
        result = claudestate.desktop_sessions([root])
        self.assertEqual(sorted(result), ["cli-a", "cli-b", "cli-c", "cli-d"])
        self.assertEqual(result["cli-a"], {
            "desktopSessionId": "local_aaa", "title": "Fix the rail",
            "archived": True, "lastFocusedAt": 123})
        self.assertEqual(result["cli-b"]["desktopSessionId"], "")
        self.assertEqual(result["cli-c"], {
            "desktopSessionId": "local_wrong", "title": "", "archived": False,
            "lastFocusedAt": None})
        self.assertEqual(result["cli-d"]["title"], "x" * 200)

    def test_desktop_sessions_reparses_only_changed_files(self) -> None:
        root = self.tmp / "sessions"
        desktop_file(root, "local_one", "cli-one", title="Short")
        desktop_file(root, "local_two", "cli-two")
        first = claudestate.desktop_sessions([root])
        with mock.patch.object(claudestate, "_parse_desktop_file",
                               wraps=claudestate._parse_desktop_file) as parse:
            second = claudestate.desktop_sessions([root])
            self.assertEqual(parse.call_count, 0)
            self.assertIs(second["cli-one"], first["cli-one"])
            desktop_file(root, "local_one", "cli-one", title="A much longer title")
            third = claudestate.desktop_sessions([root])
            self.assertEqual(parse.call_count, 1)
            self.assertEqual(third["cli-one"]["title"], "A much longer title")
            self.assertIs(third["cli-two"], first["cli-two"])

    def test_desktop_sessions_prefers_live_then_newest_copy(self) -> None:
        root = self.tmp / "sessions"
        desktop_file(root, "local_old", "cli-dup", isArchived=True, title="Archived copy")
        desktop_file(root, "local_live", "cli-dup", title="Live copy")
        self.assertEqual(claudestate.desktop_sessions([root])["cli-dup"]["title"], "Live copy")
        older = desktop_file(root, "local_first", "cli-two", title="First")
        newer = desktop_file(root, "local_second", "cli-two", title="Second")
        os.utime(older, ns=(1_000_000_000, 1_000_000_000))
        os.utime(newer, ns=(2_000_000_000, 2_000_000_000))
        self.assertEqual(claudestate.desktop_sessions([root])["cli-two"]["title"], "Second")

    def test_desktop_sessions_keeps_newest_files_under_cap(self) -> None:
        root = self.tmp / "sessions"
        # Name order (a, b, c) would keep a and b; recency keeps b and c.
        files = {
            "cli-a": desktop_file(root, "local_a", "cli-a"),
            "cli-b": desktop_file(root, "local_b", "cli-b"),
            "cli-c": desktop_file(root, "local_c", "cli-c"),
        }
        for seconds, cli in enumerate(("cli-a", "cli-b", "cli-c"), start=1):
            os.utime(files[cli], ns=(seconds * 10**9, seconds * 10**9))
        with mock.patch.object(claudestate, "MAX_DESKTOP_SESSION_FILES", 2):
            result = claudestate.desktop_sessions([root])
        self.assertEqual(sorted(result), ["cli-b", "cli-c"])

    def test_desktop_file_open_refuses_symlink_swap(self) -> None:
        root = self.tmp / "sessions"
        target = desktop_file(root, "local_real", "cli-real")
        link = target.with_name("local_link.json")
        os.symlink(target, link)
        # The caller's lstat saw a regular file; the path is now a link to one.
        self.assertIsNone(claudestate._parse_desktop_file(link, os.stat(target)))
        self.assertIsNotNone(claudestate._parse_desktop_file(target, os.stat(target)))

    def test_desktop_title_drops_format_characters(self) -> None:
        root = self.tmp / "sessions"
        desktop_file(root, "local_fmt", "cli-fmt",
                     title="‮Rev​ersed⁦ \ud800title\u0007")
        self.assertEqual(claudestate.desktop_sessions([root])["cli-fmt"]["title"],
                         "Reversed title")

    def test_collect_applies_desktop_visibility_rules(self) -> None:
        chain = [self.utility, self.desktop]
        updated = NOW_MS - 1000
        records = [
            record("archived", "working", self.session, chain),
            record("idle", "idle", self.session, chain),
            record("seen", "done", self.session, chain),
            record("older", "done", self.session, chain),
            record("unseen", "done", self.session, chain),
            record("busy", "blocked", self.session, chain),
        ]
        desktop = {
            "archived": desktop_meta(archived=True),
            "seen": desktop_meta(lastFocusedAt=updated),
            "older": desktop_meta(lastFocusedAt=updated - 1),
            "busy": desktop_meta(lastFocusedAt=NOW_MS),
        }
        sessions, clients = claudestate.collect_sessions(records, self.proc_root, NOW_MS, desktop)
        self.assertEqual(sorted(s["sessionId"] for s in sessions), ["busy", "older", "unseen"])
        busy = next(s for s in sessions if s["sessionId"] == "busy")
        self.assertEqual(busy["desktopSessionId"], "local_x")
        self.assertEqual(busy["desktopTitle"], "Work title")
        unseen = next(s for s in sessions if s["sessionId"] == "unseen")
        self.assertEqual((unseen["desktopSessionId"], unseen["desktopTitle"]), ("", ""))
        self.assertEqual(clients, [{"pid": 20, "startTime": 200, "ancestors": []}])

    def test_question_at_end_of_turn_clears_when_focused(self) -> None:
        updated = NOW_MS - 1000
        records = [
            record("focused", "blocked", self.session, [self.utility, self.desktop],
                   awaitingUser=True),
            record("newer", "blocked", self.session, [self.utility, self.desktop],
                   awaitingUser=True),
            record("older", "blocked", self.session, [self.utility, self.desktop],
                   awaitingUser=True),
            record("unseen", "blocked", self.session, [self.utility, self.desktop],
                   awaitingUser=True),
        ]
        desktop = {
            "focused": desktop_meta(lastFocusedAt=updated),
            "newer": desktop_meta(lastFocusedAt=NOW_MS),
            "older": desktop_meta(lastFocusedAt=updated - 1),
        }
        sessions, _ = claudestate.collect_sessions(records, self.proc_root, NOW_MS, desktop)
        self.assertEqual(sorted(s["sessionId"] for s in sessions), ["older", "unseen"])
        self.assertTrue(all(s["status"] == "blocked" for s in sessions))

    def test_permission_prompt_blocked_is_never_cleared_by_focus(self) -> None:
        updated = NOW_MS - 1000
        records = [
            record("prompt", "blocked", self.session, [self.utility, self.desktop]),
            record("subagent", "blocked", self.session, [self.utility, self.desktop],
                   pendingPrompt=True, resumeStatus="working"),
            record("ask", "blocked", self.session, [self.utility, self.desktop],
                   awaitingUser=False),
        ]
        desktop = {
            "prompt": desktop_meta(lastFocusedAt=NOW_MS),
            "subagent": desktop_meta(lastFocusedAt=updated),
            "ask": desktop_meta(lastFocusedAt=NOW_MS),
        }
        sessions, _ = claudestate.collect_sessions(records, self.proc_root, NOW_MS, desktop)
        self.assertEqual(sorted(s["sessionId"] for s in sessions),
                         ["ask", "prompt", "subagent"])

    def test_pending_question_is_not_hidden_by_focus(self) -> None:
        records = [
            record("pending", "blocked", self.session, [self.utility, self.desktop],
                   awaitingUser=True, pendingPrompt=True),
            record("answered", "blocked", self.session, [self.utility, self.desktop],
                   awaitingUser=True),
        ]
        desktop = {
            "pending": desktop_meta(lastFocusedAt=NOW_MS),
            "answered": desktop_meta(lastFocusedAt=NOW_MS),
        }
        sessions, _ = claudestate.collect_sessions(records, self.proc_root, NOW_MS, desktop)
        self.assertEqual([s["sessionId"] for s in sessions], ["pending"])

    def test_parse_record_keeps_only_exact_awaiting_user(self) -> None:
        def parsed(**extra: object) -> dict[str, Any] | None:
            value = record("s", "blocked", self.session, [], **extra)
            return claudestate.parse_record(json.dumps(value).encode())

        self.assertIs(parsed(awaitingUser=True)["awaitingUser"], True)
        for junk in ("true", 1, False, None, []):
            self.assertNotIn("awaitingUser", parsed(awaitingUser=junk), junk)
        self.assertNotIn("awaitingUser", parsed())
        self.assertIs(parsed(pendingPrompt=True)["pendingPrompt"], True)
        for junk in ("true", 1, False, None):
            self.assertNotIn("pendingPrompt", parsed(pendingPrompt=junk), junk)

    def test_idle_only_desktop_session_has_no_window_client(self) -> None:
        records = [record("idle", "idle", self.session, [self.utility, self.desktop])]
        sessions, clients = claudestate.collect_sessions(records, self.proc_root, NOW_MS)
        self.assertEqual(sessions, [])
        self.assertEqual(clients, [])

    def test_hidden_newer_records_do_not_crowd_out_visible_session(self) -> None:
        chain = [self.utility, self.desktop]
        records = [
            record(f"idle{index}", "idle", self.session, chain, updatedAtMs=NOW_MS - 1000)
            for index in range(70)
        ]
        records.append(record("work", "working", self.session, chain,
                              updatedAtMs=NOW_MS - 5000))
        sessions, clients = claudestate.collect_sessions(records, self.proc_root, NOW_MS)
        self.assertEqual([s["sessionId"] for s in sessions], ["work"])
        self.assertEqual(clients, [{"pid": 20, "startTime": 200, "ancestors": []}])

    def test_session_title_prefers_desktop_title(self) -> None:
        records = [record("a", "working", self.session, [self.utility, self.desktop])]
        sessions, _ = claudestate.collect_sessions(
            records, self.proc_root, NOW_MS, {"a": desktop_meta(title="Refactor dock")})
        self.assertEqual(claudestate.session_title(sessions[0]), "Refactor dock")
        sessions, _ = claudestate.collect_sessions(records, self.proc_root, NOW_MS)
        self.assertEqual(claudestate.session_title(sessions[0]), "dockrail")

    def test_snapshot_carries_desktop_id_and_focus_capabilities(self) -> None:
        records = [record("a", "working", self.session, [self.utility, self.desktop])]
        desktop = {"a": desktop_meta(desktopSessionId="local_abc", title="Refactor dock")}
        sessions, clients = claudestate.collect_sessions(records, self.proc_root, NOW_MS, desktop)
        snapshot = claudestate.build_snapshot(
            claudestate.BuildState(epoch="e", revision=1), sessions, clients)
        self.assertEqual(snapshot["agents"][0]["desktopSessionId"], "local_abc")
        self.assertEqual(snapshot["agents"][0]["title"], "Refactor dock")
        self.assertTrue(snapshot["servers"][0]["capabilities"]["focusAgent"])
        self.assertTrue(snapshot["capabilities"]["actions"])


class ProviderProcessTests(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.tmp, True)
        self.state = self.tmp / "state"
        self.state.mkdir()
        self.config = self.tmp / "config"
        self.config.mkdir()

    def launch(self, *extra: str) -> subprocess.Popen[bytes]:
        provider = ROOT / "bin" / "dockrail-claude-provider"
        # The child reads XDG_CONFIG_HOME for Desktop files; never the real ~/.config.
        env = dict(os.environ, XDG_CONFIG_HOME=str(self.config))
        proc = subprocess.Popen(
            [sys.executable, "-B", str(provider), "--state-dir", str(self.state), *extra],
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, env=env)
        self.addCleanup(proc.kill)
        return proc

    def send(self, proc: subprocess.Popen[bytes], command: bytes) -> None:
        assert proc.stdin
        proc.stdin.write(command + b"\n")
        proc.stdin.flush()

    def read_frame(self, proc: subprocess.Popen[bytes], wanted: Any) -> dict[str, Any]:
        assert proc.stdout
        for _ in range(100):
            frame = json.loads(proc.stdout.readline())
            if wanted(frame):
                return frame
        self.fail("provider did not emit the expected frame")

    def quit(self, proc: subprocess.Popen[bytes]) -> None:
        self.send(proc, b"quit")
        assert proc.stdin and proc.stdout
        proc.stdin.close()
        proc.wait(timeout=5)
        proc.stdout.close()
        self.assertEqual(proc.returncode, 0)

    def test_provider_emits_snapshot_and_echoes_window_processes(self) -> None:
        proc = self.launch()
        self.send(proc, json.dumps(
            {"kind": "window-processes", "revision": 4, "pids": [os.getpid()]}).encode())
        snapshot = self.read_frame(
            proc, lambda f: f.get("kind") is None and f["windowProcesses"]["revision"] == 4)
        self.quit(proc)
        self.assertEqual(snapshot["schemaVersion"], 1)
        self.assertEqual(snapshot["windowProcesses"]["revision"], 4)
        self.assertEqual(snapshot["windowProcesses"]["identities"][0]["pid"], os.getpid())
        self.assertEqual(snapshot["agents"], [])

    def test_deeply_nested_stdin_line_is_dropped_and_provider_keeps_running(self) -> None:
        proc = self.launch()
        self.read_frame(proc, lambda f: f.get("kind") is None)
        # Nesting past the interpreter recursion limit must not kill the stdin reader.
        self.send(proc, b"[" * 2000 + b"]" * 2000)
        self.send(proc, json.dumps(
            {"kind": "window-processes", "revision": 9, "pids": [os.getpid()]}).encode())
        snapshot = self.read_frame(
            proc, lambda f: f.get("kind") is None and f["windowProcesses"]["revision"] == 9)
        self.assertIsNone(proc.poll())
        self.quit(proc)
        self.assertEqual(snapshot["windowProcesses"]["revision"], 9)

    def test_surrogate_request_id_is_dropped_and_provider_keeps_running(self) -> None:
        proc = self.launch()
        first = self.read_frame(proc, lambda f: f.get("kind") is None)
        self.send(proc, b'{"kind":"focus-agent","requestId":"\\ud800","unexpected":1}')
        self.send(proc, b"refresh")
        # The stdin queue is ordered, so an echoed result would precede this snapshot.
        assert proc.stdout
        frames = []
        while True:
            frame = json.loads(proc.stdout.readline())
            frames.append(frame)
            if frame.get("kind") is None and frame["revision"] > first["revision"]:
                break
        self.assertEqual([f for f in frames if f.get("kind") == "action-result"], [])
        second = frames[-1]
        self.send(proc, json.dumps({
            "kind": "focus-agent", "requestId": "after", "providerEpoch": first["providerEpoch"],
            "serverId": "claude:desktop", "connectionGeneration": 1,
            "agentId": "claude:desktop:1:none", "paneId": "none", "terminalId": "",
        }).encode())
        answer = self.read_frame(proc, lambda f: f.get("requestId") == "after")
        self.assertEqual(answer["error"], "agent_gone")
        self.assertIsNone(proc.poll())
        self.assertEqual(second["schemaVersion"], 1)
        self.quit(proc)

    def test_focus_agent_acknowledges_only_emitted_agents(self) -> None:
        proc_root = self.tmp / "proc"
        proc_root.mkdir()
        fake = FakeProc(proc_root)
        desktop = fake.add(20, "claude-desktop", 1, 200,
                           ["/usr/lib/claude-desktop/claude-desktop"])
        cli = fake.add(30, "claude", 20, 300, ["/home/me/.config/Claude/claude-code/2.1.0/claude"])
        now_ms = int(time.time() * 1000)
        (self.state / "s1.json").write_text(json.dumps(
            record("s1", "working", cli, [desktop], updatedAtMs=now_ms)))
        desktop_file(self.config / "Claude" / "claude-code-sessions", "local_s1", "s1",
                     title="From Desktop")
        proc = self.launch("--proc-root", str(proc_root))
        snapshot = self.read_frame(proc, lambda f: f.get("kind") is None and bool(f["agents"]))
        agent = snapshot["agents"][0]
        self.assertEqual(agent["title"], "From Desktop")
        self.assertEqual(agent["desktopSessionId"], "local_s1")

        def focus(request_id: str, **changes: object) -> dict[str, Any]:
            command: dict[str, object] = {
                "kind": "focus-agent",
                "requestId": request_id,
                "providerEpoch": snapshot["providerEpoch"],
                "serverId": "claude:desktop",
                "connectionGeneration": 1,
                "agentId": agent["id"],
                "paneId": agent["paneId"],
                "terminalId": "",
            }
            command.update(changes)
            self.send(proc, json.dumps(command).encode())
            return self.read_frame(proc, lambda f: f.get("kind") == "action-result"
                                   and f.get("requestId") == request_id)

        self.assertEqual(focus("ok"), {
            "kind": "action-result", "requestId": "ok", "ok": True, "error": ""})
        self.assertEqual(focus("gone", agentId="claude:desktop:1:missing",
                               paneId="missing")["error"], "agent_gone")
        self.assertEqual(focus("epoch", providerEpoch="stale")["error"], "identity_mismatch")
        self.assertEqual(focus("server", serverId="t3:other")["error"], "server_unavailable")
        self.assertEqual(focus("generation", connectionGeneration=2)["error"],
                         "identity_mismatch")
        self.send(proc, json.dumps(
            {"kind": "focus-agent", "requestId": "bad", "unexpected": 1}).encode())
        malformed = self.read_frame(proc, lambda f: f.get("requestId") == "bad")
        self.assertEqual(malformed["error"], "invalid_request")
        self.assertFalse(malformed["ok"])
        self.quit(proc)


if __name__ == "__main__":
    unittest.main()
