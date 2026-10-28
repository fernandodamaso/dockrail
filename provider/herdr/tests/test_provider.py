# SPDX-License-Identifier: Apache-2.0
import json
import os
from importlib.machinery import SourceFileLoader
from pathlib import Path
import selectors
import subprocess
import sys
import tempfile
import threading
import time
import unittest

ROOT = Path(__file__).resolve().parents[1]
PROVIDER = ROOT / "bin" / "smartdock-herdr-provider"
sys.path.insert(0, str(ROOT))


class ProviderQueueTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.provider_mod = SourceFileLoader(
            "smartdock_herdr_provider_queue", str(PROVIDER)
        ).load_module()

    def test_control_put_wait_backpressures_instead_of_dropping(self):
        queue = self.provider_mod.BoundedQueue(max_bytes=16)
        self.assertTrue(queue.put(("helper", "burst"), 16))
        finished = threading.Event()
        result = []

        def writer():
            result.append(queue.put_wait(("window-processes", 7), 8))
            finished.set()

        thread = threading.Thread(target=writer)
        thread.start()
        time.sleep(0.05)
        self.assertFalse(finished.is_set(), "control writer must wait while queue is full")
        self.assertEqual(queue.get_nowait(), ("helper", "burst"))
        self.assertTrue(finished.wait(1), "control writer should resume when bounded space frees")
        thread.join(timeout=1)
        self.assertEqual(result, [True])
        self.assertEqual(queue.get_nowait(), ("window-processes", 7))

    def test_stdin_routes_all_control_events_through_lossless_enqueue(self):
        recorded = []

        class RecordingQueue:
            def put_wait(self, value, size):
                recorded.append((value, size))
                return True

            def put(self, *_args, **_kwargs):
                raise AssertionError("stdin control event used lossy put()")

        class FakeStdin:
            buffer = [
                b"refresh\n",
                b'{"kind":"window-processes","revision":7,"pids":[123]}\n',
                (
                    b'{"kind":"focus-agent","requestId":"focus-1",'
                    b'"providerEpoch":"epoch","serverId":"srv",'
                    b'"connectionGeneration":1,"agentId":"srv:1:p",'
                    b'"paneId":"p","terminalId":""}\n'
                ),
                b"quit\n",
            ]

        provider = self.provider_mod.Provider(Path("/tmp/helper"))
        provider.events = RecordingQueue()
        original_stdin = self.provider_mod.sys.stdin
        try:
            self.provider_mod.sys.stdin = FakeStdin()
            provider._stdin()
        finally:
            self.provider_mod.sys.stdin = original_stdin

        self.assertEqual(
            [event[0][0] for event in recorded],
            ["command", "window-processes", "focus-agent", "command"],
        )
        self.assertEqual(recorded[1][0][1]["revision"], 7)
        self.assertEqual(recorded[2][0][1]["requestId"], "focus-1")

    def test_helper_exit_uses_lossless_lifecycle_enqueue(self):
        recorded = []

        class RecordingQueue:
            def put_wait(self, value, size):
                recorded.append((value, size))
                return True

            def put(self, *_args, **_kwargs):
                raise AssertionError("helper exit used lossy put()")

        class EmptyStdout:
            def readline(self, _limit):
                return b""

        class ExitedProcess:
            stdout = EmptyStdout()

            def wait(self):
                return 17

        helper = self.provider_mod.HelperProcess(
            "srv", "/tmp/herdr.sock", 3, RecordingQueue(), Path("/tmp/helper")
        )
        helper._pump(ExitedProcess())
        self.assertEqual(recorded, [(("exit", "srv", 3, 17, False), 128)])


class ProviderProcessTests(unittest.TestCase):
    def test_process_discovers_supervises_publishes_refreshes_and_cleans_up(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            bin_dir = root / "bin"
            bin_dir.mkdir()
            home = root / "home"
            home.mkdir()
            marker = root / "helper-stopped"
            socket_path = root / "herdr.sock"

            herdr = bin_dir / "herdr"
            herdr.write_text(
                "#!/bin/sh\n"
                "printf 'NAME  STATUS  PID  SOCKET\\ndefault  running  1  %s\\n' "
                "\"$FAKE_SOCKET\"\n"
            )
            herdr.chmod(0o755)

            helper = root / "fake-helper.py"
            helper.write_text(
                "#!/usr/bin/env python3\n"
                "import json, os, sys\n"
                "snapshot={\"kind\":\"snapshot\",\"ok\":True,\"snapshot\":"
                "{\"panes\":[{\"pane_id\":\"p1\"}],\"agents\":[{\"pane_id\":\"p1\","
                "\"agent\":\"codex\",\"agent_status\":\"working\","
                "\"state_change_seq\":\"18446744073709551615\"}]}}\n"
                "def emit(value): print(json.dumps(value), flush=True)\n"
                "emit(snapshot); emit({\"kind\":\"status\",\"connected\":True})\n"
                "for line in sys.stdin:\n"
                " command=line.strip()\n"
                " if command == \"snapshot\": emit(snapshot)\n"
                " elif command == \"quit\":\n"
                "  open(os.environ[\"FAKE_HELPER_MARKER\"],\"w\").write(\"stopped\")\n"
                "  break\n"
            )
            helper.chmod(0o755)

            env = dict(os.environ)
            env.update({
                "HOME": str(home),
                "PATH": str(bin_dir) + os.pathsep + env.get("PATH", ""),
                "FAKE_SOCKET": str(socket_path),
                "FAKE_HELPER_MARKER": str(marker),
            })
            process = subprocess.Popen(
                [sys.executable, "-B", str(PROVIDER), "--helper", str(helper)],
                stdin=subprocess.PIPE,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                env=env,
            )
            self.addCleanup(lambda: process.poll() is None and process.kill())
            assert process.stdin is not None and process.stdout is not None
            assert process.stderr is not None

            selector = selectors.DefaultSelector()
            selector.register(process.stdout, selectors.EVENT_READ)
            messages = []
            buffer = b""

            def wait_for(predicate, timeout=5):
                nonlocal buffer
                deadline = time.monotonic() + timeout
                while time.monotonic() < deadline:
                    while b"\n" in buffer:
                        line, buffer = buffer.split(b"\n", 1)
                        value = json.loads(line)
                        messages.append(value)
                        if predicate(value):
                            return value
                    ready = selector.select(max(0, deadline - time.monotonic()))
                    if not ready:
                        break
                    chunk = os.read(process.stdout.fileno(), 65536)
                    if not chunk:
                        break
                    buffer += chunk
                self.fail(f"provider condition not reached: {messages!r}")

            ready = wait_for(
                lambda value: (value.get("liveCounts") or {}).get("agents") == 1
            )
            self.assertEqual(ready["schemaVersion"], 1)
            self.assertFalse(ready["capabilities"]["remote"])
            self.assertTrue(ready["capabilities"]["actions"])
            self.assertEqual(
                ready["agents"][0]["stateChangeSeq"],
                str(2 ** 64 - 1),
            )

            first_revision = ready["revision"]
            process.stdin.write(b"refresh\n")
            process.stdin.flush()
            refreshed = wait_for(
                lambda value: value.get("revision", 0) > first_revision
            )
            self.assertGreater(refreshed["revision"], first_revision)

            process.stdin.write(b"quit\n")
            process.stdin.flush()
            self.assertEqual(
                process.wait(timeout=4),
                0,
                process.stderr.read().decode(),
            )
            selector.close()
            process.stdin.close()
            process.stdout.close()
            process.stderr.close()
            self.assertTrue(marker.exists())

    def test_window_processes_command_publishes_matching_identities(self):
        from attachments import open_linux_proc, parse_window_processes_command
        from attachments import resolve_window_identities

        # Command parser accepts only bounded integer revision + PIDs.
        parsed = parse_window_processes_command(
            b'{"kind":"window-processes","revision":1,"pids":[123,456,123]}'
        )
        self.assertEqual(parsed, {"revision": 1, "pids": [123, 456]})
        self.assertIsNone(parse_window_processes_command(
            b'{"kind":"window-processes","revision":1,"pids":["/bin/sh"]}'
        ))
        self.assertIsNone(parse_window_processes_command(
            b'{"kind":"window-processes","revision":1.5,"pids":[1]}'
        ))
        # Fail closed: more than 256 unique PIDs, malformed tail, extra fields.
        oversized = list(range(1, 258))
        self.assertIsNone(parse_window_processes_command(
            json.dumps({"kind": "window-processes", "revision": 2, "pids": oversized}).encode()
        ))
        self.assertIsNone(parse_window_processes_command(
            json.dumps({
                "kind": "window-processes",
                "revision": 2,
                "pids": list(range(1, 257)) + ["/bin/sh"],
            }).encode()
        ))
        self.assertIsNone(parse_window_processes_command(
            b'{"kind":"window-processes","revision":1,"pids":[1],'
            b'"command":"id","argv":["x"],"path":"/tmp"}'
        ))
        exact = list(range(1, 257))
        capped = parse_window_processes_command(
            json.dumps({"kind": "window-processes", "revision": 2, "pids": exact}).encode()
        )
        self.assertEqual(len(capped["pids"]), 256)

        # Live self identity through the opened proc reader.
        self_pid = os.getpid()
        handle = open_linux_proc(self_pid)
        self.assertIsNotNone(handle)
        try:
            identity = handle.identity()
            self.assertIsNotNone(identity)
            expected_start = int(identity["startTime"])
        finally:
            handle.close()

        # PID 1 is rejected only when another user owns it (not as root).
        foreign = [1] if os.stat("/proc/1").st_uid != os.getuid() else []
        resolved = resolve_window_identities([self_pid, self_pid] + foreign)
        self.assertEqual(len(resolved), 1)
        self.assertEqual(resolved[0]["pid"], self_pid)
        self.assertEqual(resolved[0]["startTime"], expected_start)
        self.assertEqual(list(resolved[0].keys()), ["pid", "startTime"])

        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            bin_dir = root / "bin"
            bin_dir.mkdir()
            home = root / "home"
            home.mkdir()
            marker = root / "helper-stopped"
            socket_path = root / "herdr.sock"

            herdr = bin_dir / "herdr"
            herdr.write_text(
                "#!/bin/sh\n"
                "printf 'NAME  STATUS  PID  SOCKET\\ndefault  running  1  %s\\n' "
                "\"$FAKE_SOCKET\"\n"
            )
            herdr.chmod(0o755)

            helper = root / "fake-helper.py"
            helper.write_text(
                "#!/usr/bin/env python3\n"
                "import json, os, sys\n"
                "snapshot={\"kind\":\"snapshot\",\"ok\":True,\"snapshot\":"
                "{\"panes\":[{\"pane_id\":\"p1\"}],\"agents\":[{\"pane_id\":\"p1\","
                "\"agent\":\"codex\",\"agent_status\":\"idle\"}]}}\n"
                "def emit(value): print(json.dumps(value), flush=True)\n"
                "emit(snapshot); emit({\"kind\":\"status\",\"connected\":True})\n"
                "for line in sys.stdin:\n"
                " command=line.strip()\n"
                " if command == \"snapshot\": emit(snapshot)\n"
                " elif command == \"quit\":\n"
                "  open(os.environ[\"FAKE_HELPER_MARKER\"],\"w\").write(\"stopped\")\n"
                "  break\n"
            )
            helper.chmod(0o755)

            env = dict(os.environ)
            env.update({
                "HOME": str(home),
                "PATH": str(bin_dir) + os.pathsep + env.get("PATH", ""),
                "FAKE_SOCKET": str(socket_path),
                "FAKE_HELPER_MARKER": str(marker),
            })
            process = subprocess.Popen(
                [sys.executable, "-B", str(PROVIDER), "--helper", str(helper)],
                stdin=subprocess.PIPE,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                env=env,
            )
            self.addCleanup(lambda: process.poll() is None and process.kill())
            assert process.stdin is not None and process.stdout is not None
            assert process.stderr is not None

            selector = selectors.DefaultSelector()
            selector.register(process.stdout, selectors.EVENT_READ)
            messages = []
            buffer = b""

            def wait_for(predicate, timeout=5):
                nonlocal buffer
                deadline = time.monotonic() + timeout
                while time.monotonic() < deadline:
                    while b"\n" in buffer:
                        line, buffer = buffer.split(b"\n", 1)
                        value = json.loads(line)
                        messages.append(value)
                        if predicate(value):
                            return value
                    ready = selector.select(max(0, deadline - time.monotonic()))
                    if not ready:
                        break
                    chunk = os.read(process.stdout.fileno(), 65536)
                    if not chunk:
                        break
                    buffer += chunk
                self.fail(f"provider condition not reached: {messages!r}")

            wait_for(lambda value: (value.get("liveCounts") or {}).get("agents") == 1)

            command = json.dumps({
                "kind": "window-processes",
                "revision": 7,
                "pids": [self_pid],
            }, separators=(",", ":")).encode("ascii") + b"\n"
            self.assertLessEqual(len(command), 4096)
            process.stdin.write(command)
            process.stdin.flush()

            replied = wait_for(
                lambda value: (value.get("windowProcesses") or {}).get("revision") == 7
            )
            identities = replied["windowProcesses"]["identities"]
            self.assertEqual(len(identities), 1)
            self.assertEqual(identities[0]["pid"], self_pid)
            self.assertEqual(identities[0]["startTime"], expected_start)

            process.stdin.write(b"quit\n")
            process.stdin.flush()
            self.assertEqual(process.wait(timeout=4), 0, process.stderr.read().decode())
            selector.close()
            process.stdin.close()
            process.stdout.close()
            process.stderr.close()
            self.assertTrue(marker.exists())


if __name__ == "__main__":
    unittest.main()
