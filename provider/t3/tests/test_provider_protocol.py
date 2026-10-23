# SPDX-License-Identifier: Apache-2.0
"""Provider-process protocol tests: subprocess against the fake T3 server."""
from __future__ import annotations

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

ROOT = Path(__file__).resolve().parents[1]
TESTS = Path(__file__).resolve().parent
sys.path.insert(0, str(ROOT))
sys.path.insert(0, str(TESTS))

from fake_t3 import FakeT3

PROVIDER = ROOT / "bin" / "dockrail-t3-provider"
TOKEN = "protocol-token-abc"
ENV = "00000000-0000-4000-8000-000000000001"


def write_connection(path: Path, url: str, token: str = TOKEN,
                     env: str = ENV, expires_at: int = 2000000000) -> None:
    path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    os.chmod(path.parent, 0o700)
    record = {
        "version": 1,
        "environmentId": env,
        "label": "omarchy",
        "url": url,
        "token": token,
        "expiresAt": expires_at,
        "pairedAt": 1800000000,
    }
    fd = os.open(path, os.O_CREAT | os.O_WRONLY | os.O_TRUNC, 0o600)
    try:
        os.write(fd, json.dumps(record).encode())
    finally:
        os.close(fd)
    os.chmod(path, 0o600)


def working_thread(thread_id: str = "live-thread-1") -> dict[str, object]:
    from datetime import datetime, timezone

    now = datetime.now(timezone.utc).isoformat()
    return {
        "id": thread_id,
        "status": "running",
        "projectId": "project-1",
        "title": "Live working thread",
        "updatedAt": now,
    }


def working_shell(sequence: int = 42) -> dict[str, object]:
    return {
        "schemaVersion": 2,
        "snapshotSequence": sequence,
        "projects": [{"id": "project-1", "title": "Project 1"}],
        "threads": [working_thread()],
    }


def working_chunks() -> list[dict[str, object]]:
    return [{
        "_tag": "Chunk",
        "requestId": "1",
        "values": [
            {"kind": "snapshot", "snapshot": working_shell()},
            {"kind": "synchronized"},
        ],
    }]


def make_proc_tree(root: Path, port: int) -> None:
    net = root / "net"
    net.mkdir(parents=True, exist_ok=True)
    header = ("  sl  local_address rem_address   st tx_queue rx_queue tr tm->when"
              " retrnsmt   uid  timeout inode\n")
    row = ("   0: 0100007F:%04X 00000000:0000 0A 00000000:00000000 00:00000000"
           " 00000000 %5d        0 424242 1 0000000000000000 100 0 0 10 0\n"
           % (port, os.getuid()))
    (net / "tcp").write_text(header + row)
    (net / "tcp6").write_text(header)
    pid_dir = root / str(os.getpid()) / "fd"
    pid_dir.mkdir(parents=True, exist_ok=True)
    try:
        (pid_dir / "9").symlink_to("socket:[424242]")
    except FileExistsError:
        pass


class ProviderProc:
    """A running provider subprocess with line-reader threads."""

    def __init__(self, conn_file: Path, proc_root: Path) -> None:
        self.conn_file = conn_file
        self.raw_out: list[bytes] = []
        self.raw_err: list[bytes] = []
        self.snapshots: list[dict[str, object]] = []
        self.results: list[dict[str, object]] = []
        self.lock = threading.Lock()
        self.proc = subprocess.Popen(
            [sys.executable, "-B", str(PROVIDER),
             "--connection-file", str(conn_file),
             "--proc-root", str(proc_root)],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        assert self.proc.stdin is not None
        assert self.proc.stdout is not None
        assert self.proc.stderr is not None
        self._stdout_thread = threading.Thread(target=self._read_out, daemon=True)
        self._stderr_thread = threading.Thread(target=self._read_err, daemon=True)
        self._stdout_thread.start()
        self._stderr_thread.start()

    def _read_out(self) -> None:
        assert self.proc.stdout is not None
        for line in self.proc.stdout:
            with self.lock:
                self.raw_out.append(line)
            try:
                message = json.loads(line.decode("utf-8"))
            except (ValueError, UnicodeError):
                continue
            if not isinstance(message, dict):
                continue
            with self.lock:
                if "schemaVersion" in message:
                    self.snapshots.append(message)
                elif message.get("kind") == "action-result":
                    self.results.append(message)

    def _read_err(self) -> None:
        assert self.proc.stderr is not None
        for line in self.proc.stderr:
            with self.lock:
                self.raw_err.append(line)

    def send(self, payload: object) -> None:
        assert self.proc.stdin is not None
        if isinstance(payload, (dict, list)):
            raw = (json.dumps(payload) + "\n").encode()
        else:
            raw = (str(payload) + "\n").encode()
        self.proc.stdin.write(raw)
        self.proc.stdin.flush()

    def latest_snapshot(self) -> dict[str, object] | None:
        with self.lock:
            return self.snapshots[-1] if self.snapshots else None

    def wait_snapshot(self, predicate, timeout: float = 20.0, after: int | None = None):
        with self.lock:
            start = len(self.snapshots) if after is None else after
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            with self.lock:
                matches = [s for s in self.snapshots[start:] if predicate(s)]
            if matches:
                return matches[-1], len(self.snapshots)
            time.sleep(0.1)
        return None, len(self.snapshots)

    def wait_result(self, request_id: str, timeout: float = 10.0, after: int | None = None):
        with self.lock:
            start = len(self.results) if after is None else after
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            with self.lock:
                matches = [r for r in self.results[start:] if r.get("requestId") == request_id]
            if matches:
                return matches[-1]
            time.sleep(0.05)
        return None

    def stop(self) -> int | None:
        try:
            self.send("quit")
        except (BrokenPipeError, ValueError):
            pass
        try:
            return self.proc.wait(timeout=5.0)
        except subprocess.TimeoutExpired:
            self.proc.kill()
            return self.proc.wait(timeout=5.0)


def live_predicate(env: str = ENV):
    def check(snapshot: dict[str, object]) -> bool:
        servers = snapshot.get("servers")
        agents = snapshot.get("agents")
        return (
            isinstance(servers, list)
            and servers
            and servers[0].get("id") == f"t3:{env}"
            and servers[0].get("health") == "live"
            and isinstance(agents, list)
            and len(agents) > 0
        )

    return check


class ProtocolTests(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.tmp, True)
        self.conn = self.tmp / "data" / "t3" / "connection.json"
        self.proc_root = self.tmp / "proc"
        self.fake: FakeT3 | None = None
        self.provider: ProviderProc | None = None

    def tearDown(self) -> None:
        if self.provider is not None:
            try:
                self.provider.stop()
            except Exception:
                pass
            self.provider = None
        if self.fake is not None:
            self.fake.stop()
            self.fake = None

    def start_live(self, token: str = TOKEN, **fake_kwargs) -> tuple[FakeT3, ProviderProc]:
        fake_kwargs.setdefault("session_chunks", working_chunks())
        if "shell" not in fake_kwargs:
            fake_kwargs["shell"] = working_shell()
        self.fake = FakeT3(token=token, **fake_kwargs).start()
        make_proc_tree(self.proc_root, self.fake.port)
        write_connection(self.conn, self.fake.url, token=token)
        self.provider = ProviderProc(self.conn, self.proc_root)
        return self.fake, self.provider

    def test_first_line_is_schema_v1(self) -> None:
        fake, provider = self.start_live()
        snapshot, _ = provider.wait_snapshot(live_predicate())
        self.assertIsNotNone(snapshot)
        assert snapshot is not None
        self.assertEqual(snapshot["schemaVersion"], 1)
        self.assertIn("providerEpoch", snapshot)
        servers = snapshot["servers"]
        assert isinstance(servers, list)
        self.assertEqual(servers[0]["id"], f"t3:{ENV}")
        self.assertTrue(snapshot["agents"])

    def test_window_processes_echo(self) -> None:
        _fake, provider = self.start_live()
        provider.wait_snapshot(live_predicate())
        provider.send({"kind": "window-processes", "revision": 7,
                       "pids": [os.getpid()]})
        snapshot, _ = provider.wait_snapshot(
            lambda s: isinstance(s.get("windowProcesses"), dict)
            and s["windowProcesses"].get("revision") == 7
        )
        self.assertIsNotNone(snapshot)
        assert snapshot is not None
        wp = snapshot["windowProcesses"]
        assert isinstance(wp, dict)
        identities = wp.get("identities")
        assert isinstance(identities, list)
        self.assertIn(os.getpid(), [row.get("pid") for row in identities])

    def test_focus_agent_ok_and_gone(self) -> None:
        _fake, provider = self.start_live()
        snapshot, _ = provider.wait_snapshot(live_predicate())
        assert snapshot is not None
        agents = snapshot["agents"]
        assert isinstance(agents, list) and agents
        agent = agents[0]
        assert isinstance(agent, dict)
        servers = snapshot["servers"]
        assert isinstance(servers, list)
        provider.send({
            "kind": "focus-agent",
            "requestId": "req-ok",
            "providerEpoch": snapshot["providerEpoch"],
            "serverId": servers[0]["id"],
            "connectionGeneration": servers[0]["connectionGeneration"],
            "agentId": agent["id"],
            "paneId": agent["paneId"],
            "terminalId": "",
        })
        result = provider.wait_result("req-ok")
        self.assertIsNotNone(result)
        assert result is not None
        self.assertTrue(result["ok"])
        provider.send({
            "kind": "focus-agent",
            "requestId": "req-gone",
            "providerEpoch": snapshot["providerEpoch"],
            "serverId": servers[0]["id"],
            "connectionGeneration": servers[0]["connectionGeneration"],
            "agentId": "nope",
            "paneId": "nope",
            "terminalId": "",
        })
        result = provider.wait_result("req-gone")
        assert result is not None
        self.assertFalse(result["ok"])
        self.assertEqual(result["error"], "agent_gone")

    def test_focus_agent_identity_mismatch(self) -> None:
        _fake, provider = self.start_live()
        snapshot, _ = provider.wait_snapshot(live_predicate())
        assert snapshot is not None
        agents = snapshot["agents"]
        assert isinstance(agents, list) and agents
        agent = agents[0]
        assert isinstance(agent, dict)
        servers = snapshot["servers"]
        assert isinstance(servers, list)
        provider.send({
            "kind": "focus-agent",
            "requestId": "req-bad-epoch",
            "providerEpoch": "wrong",
            "serverId": servers[0]["id"],
            "connectionGeneration": servers[0]["connectionGeneration"],
            "agentId": agent["id"],
            "paneId": agent["paneId"],
            "terminalId": "",
        })
        result = provider.wait_result("req-bad-epoch")
        assert result is not None
        self.assertFalse(result["ok"])
        self.assertEqual(result["error"], "identity_mismatch")

    def test_focus_agent_invalid_request_shape(self) -> None:
        _fake, provider = self.start_live()
        provider.wait_snapshot(live_predicate())
        provider.send({"kind": "focus-agent", "requestId": "req-bad-shape"})
        result = provider.wait_result("req-bad-shape")
        assert result is not None
        self.assertFalse(result["ok"])
        self.assertEqual(result["error"], "invalid_request")

    def test_quit_exits_zero(self) -> None:
        _fake, provider = self.start_live()
        provider.wait_snapshot(live_predicate())
        code = provider.stop()
        self.provider = None
        self.assertEqual(code, 0)

    def test_stdin_eof_exits(self) -> None:
        _fake, provider = self.start_live()
        provider.wait_snapshot(live_predicate())
        assert provider.proc.stdin is not None
        provider.proc.stdin.close()
        code = provider.proc.wait(timeout=10.0)
        self.provider = None
        self.assertEqual(code, 0)

    def test_not_paired_state(self) -> None:
        self.fake = FakeT3().start()
        make_proc_tree(self.proc_root, self.fake.port)
        self.provider = ProviderProc(self.conn, self.proc_root)
        snapshot, _ = self.provider.wait_snapshot(
            lambda s: isinstance(s.get("servers"), list)
            and s["servers"]
            and s["servers"][0].get("errorCode") == "pairing_required"
        )
        self.assertIsNotNone(snapshot)

    def test_expired_state(self) -> None:
        self.fake = FakeT3().start()
        make_proc_tree(self.proc_root, self.fake.port)
        write_connection(self.conn, self.fake.url, expires_at=1000)
        self.provider = ProviderProc(self.conn, self.proc_root)
        snapshot, _ = self.provider.wait_snapshot(
            lambda s: isinstance(s.get("servers"), list)
            and s["servers"]
            and s["servers"][0].get("errorCode") == "pairing_expired"
        )
        self.assertIsNotNone(snapshot)

    def test_disconnect_withdraws_live_inventory(self) -> None:
        fake, provider = self.start_live(port=0)
        first, _ = provider.wait_snapshot(live_predicate())
        assert first is not None
        first_gen = first["servers"][0]["connectionGeneration"]
        fake.stop()
        withdrawn, _ = provider.wait_snapshot(
            lambda s: isinstance(s.get("agents"), list)
            and s["agents"] == []
            and s.get("attention") == []
            and s.get("liveCounts") is None
            and isinstance(s.get("servers"), list)
            and s["servers"][0].get("health") != "live"
        )
        self.assertIsNotNone(withdrawn, "live inventory must be withdrawn on drop")
        fake.start()
        recovered, _ = provider.wait_snapshot(
            lambda s: isinstance(s.get("agents"), list) and len(s["agents"]) > 0
            and s["servers"][0].get("health") == "live"
            and s["servers"][0].get("connectionGeneration", 0) > first_gen
        )
        self.assertIsNotNone(recovered, "must recover with a bumped generation")
        payloads = [p for p in fake.subscribe_payloads if "afterSequence" in p]
        self.assertTrue(payloads, "recovery must resume with afterSequence")

    def test_http_fallback_on_426(self) -> None:
        fake, provider = self.start_live(handshake_status=426)
        snapshot, _ = provider.wait_snapshot(live_predicate())
        self.assertIsNotNone(snapshot)
        assert snapshot is not None
        self.assertTrue(snapshot["agents"])

    def test_no_token_in_output(self) -> None:
        fake, provider = self.start_live()
        provider.wait_snapshot(live_predicate())
        provider.send({"kind": "window-processes", "revision": 3,
                       "pids": [os.getpid()]})
        provider.wait_snapshot(
            lambda s: isinstance(s.get("windowProcesses"), dict)
            and s["windowProcesses"].get("revision") == 3
        )
        combined = b"".join(provider.raw_out + provider.raw_err)
        self.assertNotIn(TOKEN.encode(), combined)


if __name__ == "__main__":
    unittest.main()
