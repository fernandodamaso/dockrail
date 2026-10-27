import hashlib
import json
import os
import shutil
import socket
import subprocess
import sys
import tarfile
import tempfile
import unittest
from datetime import datetime
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "scripts"))
sys.path.insert(0, str(Path(__file__).resolve().parent / "runtime/dev-session"))
from dev_session import (  # noqa: E402
    GUEST_CONFIG_PATH,
    HYPRLAND_FD_HARD_LIMIT,
    HYPRLAND_FD_SOFT_LIMIT,
    _commit_live_record,
    _flock,
    _atspi_find_qemu_app,
    _atspi_process_id,
    _guard_hyprland_fds,
    _hyprland_fd_count,
    _read_record_unlocked,
    _reservation_path,
    _wait_for_guest_setup,
    _write_record_unlocked,
    default_runtime_root,
    owned_process,
    prepare_private_inputs,
    process_identity,
    qemu_argv,
    read_record,
    reserve_port,
    session_dir,
    source_manifest,
    guest_capture,
    guest_dock,
    guest_exec,
    dock_argv,
    qualify_guest_dock,
    first_party_plugin_ids,
    plugin_shell_config,
    ssh_argv,
    start,
    start_guest_dock,
    status,
    stop,
    sync_source,
    validate_name,
)


class ContractTests(unittest.TestCase):
    def test_host_focus_signature_ignores_window_geometry(self):
        from dev_session import _host_focus_signature

        before = {
            "active_workspace": {"id": 1, "name": "1", "windows": 1},
            "active_window": {"address": "0x1", "at": [0, 0], "size": [1900, 968]},
        }
        after = {
            "active_workspace": {"id": 1, "name": "1", "windows": 3},
            "active_window": {"address": "0x1", "at": [0, 0], "size": [945, 479]},
        }
        self.assertEqual(_host_focus_signature(before), _host_focus_signature(after))

    def test_name(self):
        self.assertEqual(validate_name("agent-a"), "agent-a")
        for value in ("", "A", "../a", "a/b", "a" * 33):
            with self.assertRaises(ValueError):
                validate_name(value)

    def test_qemu_target_is_private(self):
        paths = {
            "overlay": Path("/tmp/a/overlay.qcow2"),
            "vars": Path("/tmp/a/vars.fd"),
            "seed": Path("/tmp/a/seed.iso"),
        }
        argv = qemu_argv(paths, 22341)
        self.assertIn(
            "user,id=net0,hostfwd=tcp:127.0.0.1:22341-:22",
            argv,
        )
        self.assertIn(
            "file=/tmp/a/overlay.qcow2,if=virtio,format=qcow2,discard=unmap",
            argv,
        )
        self.assertIn("file=/tmp/a/vars.fd", " ".join(argv))
        self.assertIn("file=/tmp/a/seed.iso,media=cdrom,if=virtio,readonly=on", argv)
        self.assertIn("virtio-vga,max_outputs=2", argv)
        self.assertIn("gtk,gl=off,window-close=on,show-tabs=on", argv)

    def test_owned_windows_keep_both_qemu_heads(self):
        from dev_session import _owned_windows

        clients = [
            {
                "pid": 9,
                "address": "0xa",
                "title": "QEMU (SmartDock visual-a)",
                "workspace": {"name": "4"},
            },
            {
                "pid": 9,
                "address": "0xb",
                "title": "QEMU (SmartDock visual-a): virtio-vga.1",
                "workspace": {"name": "1"},
            },
            {"pid": 8, "address": "0xc", "title": "ghostty"},
        ]
        owned = _owned_windows(clients, 9)
        self.assertEqual([item["address"] for item in owned], ["0xa", "0xb"])

    def test_qemu_launch_rule_covers_both_owned_titles(self):
        from dev_session import _disable_launch_rule, _launch_rule

        calls = []
        result = subprocess.CompletedProcess([], 0, stdout="true\n", stderr="")
        with mock.patch("dev_session.subprocess.run", side_effect=lambda *args, **kwargs: calls.append(args[0]) or result):
            _launch_rule("visual-a", "4")
            _disable_launch_rule("visual-a")
        launch = " ".join(calls[0])
        disable = " ".join(calls[1])
        for expression in (launch, disable):
            self.assertIn("virtio-vga", expression)
            self.assertIn(")?$", expression)
            self.assertIn("SmartDock visual", expression)

    def test_omarchy_package_metadata_records_installed_build(self):
        from dev_session import _host_omarchy_package_metadata

        result = subprocess.CompletedProcess(
            ["pacman", "-Qi", "omarchy"],
            0,
            stdout="Name            : omarchy\nVersion         : 4.0.4-1\nBuild Date      : today\n",
            stderr="",
        )
        with mock.patch("dev_session.subprocess.run", return_value=result) as run:
            metadata = _host_omarchy_package_metadata()

        run.assert_called_once_with(
            ["pacman", "-Qi", "omarchy"], check=False, capture_output=True, text=True
        )
        self.assertEqual(metadata["status"], "available")
        self.assertEqual(metadata["returncode"], 0)
        self.assertEqual(
            metadata["output"],
            "Name            : omarchy\nVersion         : 4.0.4-1\nBuild Date      : today",
        )

    def test_omarchy_package_metadata_marks_command_or_package_unavailable(self):
        from dev_session import _host_omarchy_package_metadata

        with mock.patch(
            "dev_session.subprocess.run", side_effect=FileNotFoundError("pacman missing")
        ):
            command_missing = _host_omarchy_package_metadata()
        self.assertEqual(command_missing["status"], "unavailable")
        self.assertEqual(command_missing["command"], ["pacman", "-Qi", "omarchy"])
        self.assertIsNone(command_missing["returncode"])
        self.assertNotIn("output", command_missing)
        self.assertIn("pacman missing", command_missing["stderr"])

        result = subprocess.CompletedProcess(
            ["pacman", "-Qi", "omarchy"], 1, stdout="", stderr="package not found\n"
        )
        with mock.patch("dev_session.subprocess.run", return_value=result):
            package_missing = _host_omarchy_package_metadata()
        self.assertEqual(package_missing["status"], "unavailable")
        self.assertEqual(package_missing["returncode"], 1)
        self.assertEqual(package_missing["stderr"], "package not found")
        self.assertNotIn("output", package_missing)

    def test_qemu_heads_are_exactly_two_owned_titles_and_ordered(self):
        from dev_session import _show_both_qemu_heads

        heads = [
            {"pid": 9, "address": "0xb", "title": "QEMU (SmartDock visual-a): virtio-vga.1",
             "workspace": {"name": "4"}, "at": [900, 0]},
            {"pid": 9, "address": "0xa", "title": "QEMU (SmartDock visual-a)",
             "workspace": {"name": "4"}, "at": [0, 0]},
        ]
        with mock.patch("dev_session._guard_hyprland_fds"):
            with mock.patch("dev_session._host_command_json", return_value=heads):
                with mock.patch("dev_session._owned_windows", return_value=heads):
                    with mock.patch("dev_session._place_owned_windows", return_value=heads):
                        actual = _show_both_qemu_heads(9, "4", "visual-a")
        self.assertEqual([item["address"] for item in actual], ["0xa", "0xb"])

    def test_guest_seed_is_persisted_and_not_repeated_on_restart(self):
        from dev_session import GUEST_CONFIG_PATH

        evidence = Path(tempfile.mkdtemp(prefix="dev-session-seed-evidence-"))
        self.addCleanup(lambda: shutil.rmtree(evidence, ignore_errors=True))
        record = {
            "name": "seed-once", "state": "ready", "mode": "standalone",
            "evidence_path": str(evidence), "config_path": GUEST_CONFIG_PATH,
            "guest_config_path": GUEST_CONFIG_PATH, "guest_seeded": False,
            "source": "/tmp/source", "qemu_pid": 9, "qemu_start_ticks": 1,
            "qemu_pgid": 9, "host_pid": 9, "guest_dock_pid": 8,
        }
        starts = []
        seeds = []

        def guest_argv(_record, argv, _timeout):
            if argv[-1] == "start-dock":
                starts.append(argv)
                return subprocess.CompletedProcess(argv, 0,
                    stdout=json.dumps({"pid": 8, "config_path": GUEST_CONFIG_PATH}) + "\n",
                    stderr="")
            if argv[-1] == "seed-desktop":
                seeds.append(argv)
                return subprocess.CompletedProcess(argv, 0,
                    stdout=json.dumps({"seeded": True}) + "\n", stderr="")
            raise AssertionError(argv)

        with mock.patch("dev_session._require_runnable_session", return_value=record):
            with mock.patch("dev_session._read_guest_ready", return_value={
                "wayland_display": "wayland-1",
                "hyprland_instance_signature": "sig",
                "output": "Virtual-1",
                "outputs": ["Virtual-1", "Virtual-2"],
            }):
                with mock.patch("dev_session._commit_live_record"):
                    with mock.patch("dev_session._stop_guest_dock") as stop_dock:
                        with mock.patch("dev_session.stage_omarchy_qml_assets"):
                            with mock.patch("dev_session._run_guest_argv", side_effect=guest_argv):
                                with mock.patch("dev_session._guest_qs_instances",
                                                  return_value=[{"pid": 8}]):
                                    with mock.patch("dev_session._guest_smartdock_status",
                                                      return_value={"ok": True}):
                                        with mock.patch("dev_session.qualify_guest_dock",
                                                          return_value={"loadState": "loaded"}):
                                            first = start_guest_dock("seed-once")
                                            second = start_guest_dock("seed-once")
        self.assertTrue(first["guest_seeded"])
        self.assertTrue(second["guest_seeded"])
        self.assertEqual(len(seeds), 1)
        self.assertEqual(len(starts), 2)
        self.assertEqual(stop_dock.call_count, 2)
        self.assertEqual(json.loads((evidence / "guest-seed.json").read_text())["seeded"], True)

    def test_hyprland_fd_guard_limits(self):
        self.assertLess(HYPRLAND_FD_SOFT_LIMIT, HYPRLAND_FD_HARD_LIMIT)
        self.assertGreaterEqual(HYPRLAND_FD_SOFT_LIMIT, 500)
        self.assertGreaterEqual(HYPRLAND_FD_HARD_LIMIT, 1500)

        with tempfile.TemporaryDirectory() as tmp:
            fd_dir = Path(tmp)
            for index in range(7):
                (fd_dir / str(index)).symlink_to("/dev/null")
            (fd_dir / "plain").write_text("not-a-symlink\n", encoding="utf-8")
            with mock.patch("dev_session.Path", return_value=fd_dir):
                self.assertEqual(_hyprland_fd_count(4242), 7)

        with mock.patch("dev_session._hyprland_fd_count", return_value=None):
            self.assertIsNone(_guard_hyprland_fds("unit"))
        with mock.patch(
            "dev_session._hyprland_fd_count", return_value=HYPRLAND_FD_SOFT_LIMIT
        ):
            self.assertEqual(_guard_hyprland_fds("unit-soft"), HYPRLAND_FD_SOFT_LIMIT)
        with mock.patch(
            "dev_session._hyprland_fd_count", return_value=HYPRLAND_FD_HARD_LIMIT
        ):
            with self.assertRaisesRegex(RuntimeError, "FD leak detected"):
                _guard_hyprland_fds("unit-hard")

    def test_atspi_qemu_app_matches_owned_pid(self):
        other = mock.Mock()
        other.get_name.return_value = "QEMU"
        other.get_process_id.return_value = 111
        owned = mock.Mock()
        owned.get_name.return_value = "QEMU"
        owned.get_process_id.return_value = 222
        ignored = mock.Mock()
        ignored.get_name.return_value = "ghostty"
        ignored.get_process_id.return_value = 222
        desktop = mock.Mock()
        desktop.get_child_count.return_value = 3
        desktop.get_child_at_index.side_effect = [other, ignored, owned]

        self.assertEqual(_atspi_process_id(owned), 222)
        self.assertIs(_atspi_find_qemu_app(desktop, 222), owned)
        desktop.get_child_at_index.side_effect = [other, ignored, owned]
        self.assertIs(_atspi_find_qemu_app(desktop, 111), other)
        desktop.get_child_at_index.side_effect = [other, ignored, owned]
        self.assertIsNone(_atspi_find_qemu_app(desktop, 999))

        import inspect
        from dev_session import _atspi_qemu_app, _detach_second_qemu_head, _show_both_qemu_heads

        self.assertIn("pid", inspect.signature(_atspi_qemu_app).parameters)
        self.assertIn("pid", inspect.signature(_detach_second_qemu_head).parameters)
        source = inspect.getsource(_show_both_qemu_heads)
        self.assertIn("_detach_second_qemu_head(pid)", source)

    def test_supervised_wait_polls_fd_guard(self):
        from dev_session import HYPRLAND_FD_POLL_SECONDS, _wait_supervised

        self.assertGreaterEqual(HYPRLAND_FD_POLL_SECONDS, 1)
        self.assertLessEqual(HYPRLAND_FD_POLL_SECONDS, 15)

        proc = mock.Mock()
        proc.wait.side_effect = [
            subprocess.TimeoutExpired(cmd="qemu", timeout=5),
            subprocess.TimeoutExpired(cmd="qemu", timeout=5),
            0,
        ]
        with mock.patch("dev_session._guard_hyprland_fds") as guard:
            self.assertEqual(_wait_supervised(proc, poll_seconds=5), 0)
        self.assertEqual(proc.wait.call_count, 3)
        self.assertEqual(guard.call_count, 2)
        guard.assert_called_with("supervise")

        proc = mock.Mock()
        proc.wait.side_effect = subprocess.TimeoutExpired(cmd="qemu", timeout=5)
        with mock.patch(
            "dev_session._guard_hyprland_fds",
            side_effect=RuntimeError("Hyprland FD leak detected during supervise"),
        ):
            with self.assertRaisesRegex(RuntimeError, "FD leak detected"):
                _wait_supervised(proc, poll_seconds=5)

        import inspect
        from dev_session import start

        self.assertIn("_wait_supervised(proc)", inspect.getsource(start))

    def test_guest_ready_requires_two_monitors(self):
        import guest_ready

        with self.assertRaises(ValueError):
            guest_ready.ready_outputs([{"name": "Virtual-1", "x": 0}])
        primary, names = guest_ready.ready_outputs(
            [
                {"name": "Virtual-2", "x": 1280},
                {"name": "Virtual-1", "x": 0},
            ]
        )
        self.assertEqual(primary, "Virtual-1")
        self.assertEqual(names, ["Virtual-1", "Virtual-2"])

    def test_invalid_source_and_base_image(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            state = root / "state"
            runtime = root / "runtime"
            state.mkdir()
            runtime.mkdir()
            missing = root / "missing"
            with self.assertRaises(ValueError):
                prepare_private_inputs(
                    "agent-a",
                    source=missing,
                    base_image=missing,
                    state_root=state,
                    runtime_root=runtime,
                )


class PrivateInputsTests(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp(prefix="dev-session-test-"))
        self.state = self.tmp / "state"
        self.runtime = self.tmp / "runtime"
        self.state.mkdir()
        self.runtime.mkdir()
        self.source = Path(__file__).resolve().parents[1]
        base = Path.home() / (
            ".local/state/smartdock/dev-sessions/_kvm-feasibility/images/"
            "Arch-Linux-x86_64-cloudimg.qcow2"
        )
        if not base.is_file():
            self.skipTest(f"missing verified base image: {base}")
        self.base = base

    def tearDown(self):
        shutil.rmtree(self.tmp, ignore_errors=True)

    def test_two_names_get_distinct_private_paths(self):
        a = prepare_private_inputs(
            "agent-a",
            source=self.source,
            base_image=self.base,
            state_root=self.state,
            runtime_root=self.runtime,
        )
        b = prepare_private_inputs(
            "agent-b",
            source=self.source,
            base_image=self.base,
            state_root=self.state,
            runtime_root=self.runtime,
        )
        for key in ("overlay", "vars", "seed", "ssh_key", "ssh_pub"):
            self.assertNotEqual(a[key], b[key])
            self.assertTrue(a[key].exists(), key)
            self.assertTrue(b[key].exists(), key)
        overlay_info = json.loads(
            subprocess.run(
                ["qemu-img", "info", "--output=json", str(a["overlay"])],
                check=True,
                capture_output=True,
                text=True,
            ).stdout
        )
        self.assertEqual(overlay_info["virtual-size"], 40 * 1024**3)
        self.assertEqual(a["ssh_key"].stat().st_mode & 0o777, 0o600)
        self.assertEqual(session_dir("agent-a", self.state), a["session"])
        with self.assertRaises(ValueError):
            prepare_private_inputs(
                "agent-a",
                source=self.source,
                base_image=self.base,
                state_root=self.state,
                runtime_root=self.runtime,
            )

    def test_process_identity_reads_start_ticks(self):
        proc = subprocess.Popen(
            [sys.executable, "-c", "import time; time.sleep(30)"],
            start_new_session=True,
        )
        try:
            ident = process_identity(proc.pid)
            self.assertIsNotNone(ident)
            self.assertEqual(ident["pid"], proc.pid)
            self.assertIsInstance(ident["start_ticks"], int)
            self.assertEqual(ident["pgid"], os.getpgid(proc.pid))
            self.assertIsNone(process_identity(2**30))
        finally:
            proc.terminate()
            proc.wait(timeout=5)


class LifecycleTests(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp(prefix="dev-session-lifecycle-"))
        self.state_home = self.tmp / "state-home"
        self.runtime_dir = self.tmp / "runtime"
        self.state_home.mkdir()
        self.runtime_dir.mkdir()
        self.env = mock.patch.dict(
            os.environ,
            {
                "XDG_STATE_HOME": str(self.state_home),
                "XDG_RUNTIME_DIR": str(self.runtime_dir),
            },
        )
        self.env.start()

    def tearDown(self):
        self.env.stop()
        shutil.rmtree(self.tmp, ignore_errors=True)

    def write_record(self, name, record):
        session = session_dir(name)
        session.mkdir(mode=0o700, parents=True)
        (session / "record.json").write_text(json.dumps(record), encoding="utf-8")

    def test_duplicate_name_cannot_reserve_second_port(self):
        runtime = default_runtime_root()
        first = reserve_port(runtime, "agent-a")
        self.assertGreaterEqual(first, 22000)
        self.assertLessEqual(first, 22999)
        with self.assertRaisesRegex(ValueError, "already has"):
            reserve_port(runtime, "agent-a")

    def test_port_occupied_by_another_listener_is_skipped(self):
        listener = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        occupied = 22000
        try:
            listener.bind(("127.0.0.1", occupied))
            listener.listen()
        except OSError:
            occupied = 22000
        try:
            port = reserve_port(default_runtime_root(), "agent-b")
        finally:
            listener.close()
        self.assertNotEqual(port, occupied)

    def test_malformed_and_stale_records_are_reported(self):
        session = session_dir("agent-a")
        session.mkdir(mode=0o700, parents=True)
        (session / "record.json").write_text("{broken", encoding="utf-8")
        with self.assertRaisesRegex(ValueError, "malformed"):
            read_record("agent-a")

        self.write_record(
            "agent-b",
            {
                "name": "agent-b",
                "state": "starting",
                "qemu_pid": 2**30,
                "qemu_start_ticks": 1,
                "qemu_pgid": 2**30,
            },
        )
        result = status("agent-b")
        self.assertEqual(result["state"], "failed")
        self.assertFalse(result["qemu_alive"])
        self.assertIn("dead", result["error"])

    def test_changed_start_ticks_refuse_signal(self):
        proc = subprocess.Popen(
            [sys.executable, "-c", "import time; time.sleep(30)"],
            start_new_session=True,
        )
        try:
            ident = process_identity(proc.pid)
            self.assertIsNotNone(ident)
            record = {
                "name": "agent-a",
                "state": "starting",
                "qemu_pid": ident["pid"],
                "qemu_start_ticks": ident["start_ticks"],
                "qemu_pgid": ident["pgid"],
            }
            self.assertTrue(owned_process(record))
            record["qemu_start_ticks"] += 1
            self.assertFalse(owned_process(record))
            self.write_record("agent-a", record)

            with self.assertRaisesRegex(ValueError, "ownership mismatch"):
                stop("agent-a")
            self.assertIsNone(proc.poll())
        finally:
            if proc.poll() is None:
                proc.terminate()
            proc.wait(timeout=5)

    def test_stop_is_idempotent(self):
        self.write_record("agent-a", {"name": "agent-a", "state": "stopped"})
        self.assertEqual(stop("agent-a")["state"], "stopped")
        self.assertEqual(stop("agent-a")["state"], "stopped")

    def test_ssh_wait_writes_progress_json_each_attempt(self):
        evidence = self.tmp / "evidence"
        evidence.mkdir()
        ssh_calls = {"true": 0}

        def fake_ssh(_record, command, _timeout):
            if command == "true":
                ssh_calls["true"] += 1
                if ssh_calls["true"] == 1:
                    return mock.Mock(
                        returncode=255,
                        stderr="ssh: connect to host 127.0.0.1 port 22000: Connection refused\n",
                        stdout="",
                    )
                first = json.loads((evidence / "progress.json").read_text(encoding="utf-8"))
                self.assertEqual(first["attempt"], 1)
                self.assertEqual(first["last_ssh_returncode"], 255)
                self.assertIn("Connection refused", first["last_ssh_stderr"])
                datetime.fromisoformat(first["timestamp"])
                return mock.Mock(returncode=0, stderr="", stdout="")
            return mock.Mock(returncode=0, stderr="", stdout="ok")

        with mock.patch("dev_session._run_ssh", side_effect=fake_ssh):
            with mock.patch("dev_session.time.sleep"):
                _wait_for_guest_setup({"name": "agent-a", "port": 22000}, evidence)

        progress = json.loads((evidence / "progress.json").read_text(encoding="utf-8"))
        self.assertEqual(progress["attempt"], 2)
        self.assertEqual(progress["last_ssh_returncode"], 0)
        self.assertEqual(progress["last_ssh_stderr"], "")
        datetime.fromisoformat(progress["timestamp"])


def _git(cwd, *args, extra_env=None):
    env = os.environ.copy()
    if extra_env:
        env.update(extra_env)
    subprocess.run(
        ["git", *args],
        cwd=cwd,
        check=True,
        capture_output=True,
        text=True,
        env=env,
    )


def _init_candidate_repo(root: Path) -> Path:
    root.mkdir(parents=True, exist_ok=True)
    _git(root, "init")
    (root / "tracked.txt").write_text("tracked-bytes\n", encoding="utf-8")
    (root / "dirty.txt").write_text("dirty-original\n", encoding="utf-8")
    (root / "path with spaces.txt").write_text("spaces\n", encoding="utf-8")
    (root / "ignored.txt").write_text("should-not-transfer\n", encoding="utf-8")
    (root / ".gitignore").write_text("ignored.txt\n", encoding="utf-8")
    os.symlink("tracked.txt", root / "link-to-tracked")
    _git(root, "add", "tracked.txt", "dirty.txt", "path with spaces.txt", ".gitignore", "link-to-tracked")
    _git(
        root,
        "-c",
        "user.email=dev-session@test",
        "-c",
        "user.name=dev-session",
        "commit",
        "-m",
        "init",
    )
    (root / "dirty.txt").write_text("dirty-edited\n", encoding="utf-8")
    (root / "untracked.txt").write_text("untracked-bytes\n", encoding="utf-8")
    return root


class SourceSyncTests(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp(prefix="dev-session-sync-"))
        self.source = _init_candidate_repo(self.tmp / "source")
        self.state_home = self.tmp / "state-home"
        self.runtime_dir = self.tmp / "runtime"
        self.state_home.mkdir()
        self.runtime_dir.mkdir()
        self.env = mock.patch.dict(
            os.environ,
            {
                "XDG_STATE_HOME": str(self.state_home),
                "XDG_RUNTIME_DIR": str(self.runtime_dir),
            },
        )
        self.env.start()
        self.session = session_dir("agent-sync")
        self.session.mkdir(parents=True)
        self.evidence = self.session / "evidence"
        self.evidence.mkdir()
        self.guest_root = self.tmp / "guest"
        self.guest_root.mkdir()
        self.record = {
            "name": "agent-sync",
            "state": "starting",
            "source": str(self.source),
            "source_digest": "prior-digest",
            "port": 22001,
            "qemu_pid": 1,
            "qemu_start_ticks": 1,
            "qemu_pgid": 1,
            "evidence_path": str(self.evidence),
            "error": None,
        }
        (self.session / "record.json").write_text(
            json.dumps(self.record), encoding="utf-8"
        )

    def tearDown(self):
        self.env.stop()
        shutil.rmtree(self.tmp, ignore_errors=True)

    def test_manifest_tracks_dirty_untracked_spaces_and_skips_ignored(self):
        entries, digest = source_manifest(self.source)
        paths = {entry["path"] for entry in entries}
        self.assertIn("tracked.txt", paths)
        self.assertIn("dirty.txt", paths)
        self.assertIn("untracked.txt", paths)
        self.assertIn("path with spaces.txt", paths)
        self.assertIn("link-to-tracked", paths)
        self.assertNotIn("ignored.txt", paths)
        self.assertFalse(any(path == ".git" or path.startswith(".git/") for path in paths))
        self.assertEqual(len(digest), 64)

        dirty = next(entry for entry in entries if entry["path"] == "dirty.txt")
        self.assertEqual(dirty["kind"], "file")
        self.assertEqual(
            dirty["sha256"],
            hashlib.sha256(b"dirty.txt\0" + b"dirty-edited\n").hexdigest(),
        )
        link = next(entry for entry in entries if entry["path"] == "link-to-tracked")
        self.assertEqual(link["kind"], "symlink")
        self.assertEqual(
            link["sha256"],
            hashlib.sha256(b"link-to-tracked\0" + b"tracked.txt").hexdigest(),
        )

        before = digest
        (self.source / "dirty.txt").write_text("dirty-again\n", encoding="utf-8")
        _, after = source_manifest(self.source)
        self.assertNotEqual(before, after)

    def test_sync_archive_excludes_git_and_ignored_and_is_one_way(self):
        host_tracked = hashlib.sha256((self.source / "tracked.txt").read_bytes()).hexdigest()
        scp_calls = []

        def fake_scp(record, local, remote):
            self.assertEqual(record["name"], "agent-sync")
            self.assertTrue(str(remote).startswith("/tmp/") or str(remote).startswith("/home/admin/"))
            scp_calls.append((Path(local), remote))
            dest = self.guest_root / Path(remote).name
            shutil.copy2(local, dest)

        def fake_ssh(record, command, timeout):
            del timeout
            self.assertEqual(record["name"], "agent-sync")
            self.assertIn("/home/admin/smartdock-candidate", command)
            self.assertNotIn("virtiofs", command)
            tar_remote = next(remote for _, remote in scp_calls if str(remote).endswith(".tar"))
            guest_tar = self.guest_root / Path(tar_remote).name
            dest_new = self.guest_root / "smartdock-candidate.new"
            dest = self.guest_root / "smartdock-candidate"
            if dest_new.exists():
                shutil.rmtree(dest_new)
            dest_new.mkdir()
            with tarfile.open(guest_tar, "r") as tar:
                names = tar.getnames()
                self.assertNotIn("ignored.txt", names)
                self.assertFalse(any(name == ".git" or name.startswith(".git/") for name in names))
                self.assertIn("path with spaces.txt", names)
                self.assertIn("untracked.txt", names)
                tar.extractall(dest_new, filter="data")
            if dest.exists():
                shutil.rmtree(dest)
            dest_new.rename(dest)
            _, digest = source_manifest(self.source)
            return subprocess.CompletedProcess(command, 0, stdout=digest + "\n", stderr="")

        with mock.patch("dev_session._scp_to_guest", side_effect=fake_scp):
            with mock.patch("dev_session._run_ssh", side_effect=fake_ssh):
                with mock.patch("dev_session.owned_process", return_value=True):
                    digest = sync_source(self.record)

        self.assertTrue(scp_calls)
        guest_only = self.guest_root / "smartdock-candidate" / "GUEST-ONLY"
        guest_only.write_text("guest-marker\n", encoding="utf-8")
        (self.guest_root / "smartdock-candidate" / "tracked.txt").write_text(
            "mutated-on-guest\n", encoding="utf-8"
        )
        self.assertEqual(
            hashlib.sha256((self.source / "tracked.txt").read_bytes()).hexdigest(),
            host_tracked,
        )
        self.assertFalse((self.source / "GUEST-ONLY").exists())
        self.assertEqual(read_record("agent-sync")["source_digest"], digest)
        self.assertNotEqual(digest, "prior-digest")

    def test_sync_retains_prior_digest_when_guest_readback_mismatches(self):
        def fake_scp(record, local, remote):
            del record, remote
            Path(local).touch(exist_ok=True)

        def fake_ssh(_record, command, _timeout):
            return subprocess.CompletedProcess(command, 0, stdout="not-the-digest\n", stderr="")

        with mock.patch("dev_session._scp_to_guest", side_effect=fake_scp):
            with mock.patch("dev_session._run_ssh", side_effect=fake_ssh):
                with mock.patch("dev_session.owned_process", return_value=True):
                    with self.assertRaises(ValueError):
                        sync_source(self.record)
        self.assertEqual(read_record("agent-sync")["source_digest"], "prior-digest")

    def test_stop_during_sync_does_not_resurrect_record(self):
        proc = subprocess.Popen(
            [sys.executable, "-c", "import time; time.sleep(30)"],
            start_new_session=True,
        )
        try:
            ident = process_identity(proc.pid)
            self.record.update(
                {
                    "qemu_pid": ident["pid"],
                    "qemu_start_ticks": ident["start_ticks"],
                    "qemu_pgid": ident["pgid"],
                }
            )
            (self.session / "record.json").write_text(
                json.dumps(self.record), encoding="utf-8"
            )

            def fake_scp(_record, local, _remote):
                Path(local).touch(exist_ok=True)

            def fake_ssh(_record, command, _timeout):
                self.assertEqual(stop("agent-sync")["state"], "stopped")
                _, digest = source_manifest(self.source)
                return subprocess.CompletedProcess(
                    command, 0, stdout=digest + "\n", stderr=""
                )

            with mock.patch("dev_session._scp_to_guest", side_effect=fake_scp):
                with mock.patch("dev_session._run_ssh", side_effect=fake_ssh):
                    with self.assertRaisesRegex(ValueError, r"state 'stopped'"):
                        sync_source(self.record)
            latest = read_record("agent-sync")
            self.assertEqual(latest["state"], "stopped")
            self.assertEqual(latest["source_digest"], "prior-digest")
            self.assertIsNotNone(proc.poll())
        finally:
            if proc.poll() is None:
                proc.terminate()
                proc.wait(timeout=5)

    def test_archive_rejects_file_changed_after_inventory(self):
        real_manifest = source_manifest

        def mutating_manifest(source):
            entries, digest = real_manifest(source)
            (source / "tracked.txt").write_text("changed-after-inventory\n", encoding="utf-8")
            return entries, digest

        with mock.patch("dev_session.source_manifest", side_effect=mutating_manifest):
            with mock.patch("dev_session.owned_process", return_value=True):
                with self.assertRaises(ValueError):
                    sync_source(self.record)
        self.assertEqual(read_record("agent-sync")["source_digest"], "prior-digest")


class GuestExecCaptureTests(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp(prefix="dev-session-exec-"))
        self.state_home = self.tmp / "state-home"
        self.runtime_dir = self.tmp / "runtime"
        self.state_home.mkdir()
        self.runtime_dir.mkdir()
        self.env = mock.patch.dict(
            os.environ,
            {
                "XDG_STATE_HOME": str(self.state_home),
                "XDG_RUNTIME_DIR": str(self.runtime_dir),
            },
        )
        self.env.start()
        self.session = session_dir("agent-exec")
        self.session.mkdir(parents=True)
        self.evidence = self.session / "evidence"
        self.evidence.mkdir()
        self.record = {
            "name": "agent-exec",
            "state": "starting",
            "source": str(Path(__file__).resolve().parents[1]),
            "source_digest": "abc123",
            "port": 22002,
            "qemu_pid": 1,
            "qemu_start_ticks": 1,
            "qemu_pgid": 1,
            "evidence_path": str(self.evidence),
            "error": None,
            "guest_display": "wayland-1",
            "guest_signature": "sig",
            "guest_output": "Virtual-1",
        }
        (self.session / "record.json").write_text(
            json.dumps(self.record), encoding="utf-8"
        )

    def tearDown(self):
        self.env.stop()
        shutil.rmtree(self.tmp, ignore_errors=True)

    def test_exec_passes_literal_argv(self):
        captured = {}

        def fake_ssh(_record, command, _timeout):
            captured["command"] = command
            return subprocess.CompletedProcess(command, 0, stdout="ok\n", stderr="")

        unique = self.tmp / "host-should-not-create"
        with mock.patch("dev_session._run_ssh", side_effect=fake_ssh):
            with mock.patch("dev_session.owned_process", return_value=True):
                code = guest_exec(
                    "agent-exec", ["echo", f"$(touch {unique})"]
                )
        self.assertEqual(code, 0)
        self.assertIn(f"echo '$(touch {unique})'", captured["command"])
        self.assertFalse(unique.exists())

    def test_exec_returns_guest_exit_code(self):
        def fake_ssh(_record, command, _timeout):
            return subprocess.CompletedProcess(command, 17, stdout="", stderr="boom")

        with mock.patch("dev_session._run_ssh", side_effect=fake_ssh):
            with mock.patch("dev_session.owned_process", return_value=True):
                self.assertEqual(guest_exec("agent-exec", ["false"]), 17)

    def test_capture_rejects_non_png(self):
        def fake_ssh(_record, command, _timeout):
            if "grim" in command:
                return subprocess.CompletedProcess(command, 0, stdout="", stderr="")
            return subprocess.CompletedProcess(
                command,
                0,
                stdout=json.dumps(
                    {
                        "wayland_display": "wayland-1",
                        "hyprland_instance_signature": "sig",
                        "output": "Virtual-1",
                        "xdg_runtime_dir": "/run/user/1000",
                    }
                ),
                stderr="",
            )

        def fake_scp(_record, remote, local):
            del remote
            Path(local).write_text("not a png", encoding="utf-8")

        with mock.patch("dev_session._run_ssh", side_effect=fake_ssh):
            with mock.patch("dev_session._scp_from_guest", side_effect=fake_scp):
                with mock.patch("dev_session.owned_process", return_value=True):
                    with self.assertRaisesRegex(ValueError, "PNG"):
                        guest_capture("agent-exec")

    def test_capture_grabs_all_guest_outputs(self):
        captured = {}

        def fake_ssh(_record, command, _timeout):
            if "grim" in command:
                captured["command"] = command
                return subprocess.CompletedProcess(command, 0, stdout="", stderr="")
            return subprocess.CompletedProcess(
                command,
                0,
                stdout=json.dumps(
                    {
                        "wayland_display": "wayland-1",
                        "hyprland_instance_signature": "sig",
                        "output": "Virtual-1",
                        "outputs": ["Virtual-1", "Virtual-2"],
                        "xdg_runtime_dir": "/run/user/1000",
                    }
                ),
                stderr="",
            )

        def fake_scp(_record, remote, local):
            del remote
            Path(local).write_bytes(b"\x89PNG\r\n\x1a\n" + b"\0" * 32)

        with mock.patch("dev_session._run_ssh", side_effect=fake_ssh):
            with mock.patch("dev_session._scp_from_guest", side_effect=fake_scp):
                with mock.patch("dev_session.owned_process", return_value=True):
                    with mock.patch(
                        "dev_session._guest_config_digest", return_value="a" * 64
                    ):
                        guest_capture("agent-exec")
        self.assertIn("grim", captured["command"])
        self.assertNotIn("grim -o ", captured["command"])
        self.assertNotIn("'grim', '-o'", captured["command"])

    def test_exec_and_capture_reject_stopped_or_failed(self):
        for state in ("stopped", "failed", "stopping"):
            self.record["state"] = state
            (self.session / "record.json").write_text(
                json.dumps(self.record), encoding="utf-8"
            )
            with self.assertRaisesRegex(ValueError, state):
                guest_exec("agent-exec", ["true"])
            with self.assertRaisesRegex(ValueError, state):
                guest_capture("agent-exec")


class DockArgvTests(unittest.TestCase):
    def setUp(self):
        self.source_config = Path(__file__).resolve().parents[1] / "config/dock.json"
        self.source_bytes = self.source_config.read_bytes()
        self.record = {
            "name": "agent-dock",
            "mode": "standalone",
            "host_pid": 4242,
            "config_path": "/home/admin/.config/smartdock/dock.json",
            "state": "starting",
        }

    def tearDown(self):
        self.assertEqual(self.source_config.read_bytes(), self.source_bytes)

    def test_rejects_instance_and_runtime_overrides(self):
        for args in (
            ["--instance", "999", "status", "--json"],
            ["--instance=999", "status", "--json"],
            ["--runtime", "auto", "status", "--json"],
            ["--runtime=plugin", "status", "--json"],
            ["status", "--json", "--runtime", "plugin"],
            ["config", "get", "--instance=999"],
        ):
            with self.subTest(args=args):
                with self.assertRaises(ValueError):
                    dock_argv(self.record, args)

    def test_injects_recorded_mode_and_pid(self):
        argv = dock_argv(self.record, ["status", "--json"])
        self.assertEqual(argv[0], "/home/admin/smartdock-candidate/scripts/smartdock")
        self.assertEqual(argv[argv.index("--runtime") + 1], "standalone")
        self.assertEqual(argv[argv.index("--instance") + 1], "4242")
        self.assertIn("status", argv)
        self.assertIn("--json", argv)
        self.assertNotIn("999", argv)
        self.assertNotIn("auto", argv)
        self.assertNotIn("plugin", argv)

    def test_readiness_rejects_wrong_pid_or_config_path(self):
        good = {
            "ok": True,
            "data": {
                "runtime": {"mode": "standalone", "instanceId": "4242"},
                "configPath": "/home/admin/.config/smartdock/dock.json",
                "loadState": "loaded",
            },
        }
        self.assertEqual(qualify_guest_dock(self.record, good)["configPath"], good["data"]["configPath"])
        wrong_pid = json.loads(json.dumps(good))
        wrong_pid["data"]["runtime"]["instanceId"] = "999"
        with self.assertRaises(ValueError):
            qualify_guest_dock(self.record, wrong_pid)
        wrong_config = json.loads(json.dumps(good))
        wrong_config["data"]["configPath"] = "/tmp/wrong.json"
        with self.assertRaises(ValueError):
            qualify_guest_dock(self.record, wrong_config)
        wrong_mode = json.loads(json.dumps(good))
        wrong_mode["data"]["runtime"]["mode"] = "plugin"
        with self.assertRaises(ValueError):
            qualify_guest_dock(self.record, wrong_mode)


class PluginHostTests(unittest.TestCase):
    def test_rejects_standalone_mode_and_changed_pid(self):
        record = {
            "mode": "plugin",
            "host_pid": 5555,
            "config_path": "/home/admin/.config/smartdock/dock.json",
        }
        good = {
            "ok": True,
            "data": {
                "runtime": {"mode": "plugin", "instanceId": "5555"},
                "configPath": "/home/admin/.config/smartdock/dock.json",
                "loadState": "loaded",
            },
        }
        self.assertEqual(qualify_guest_dock(record, good)["runtime"]["mode"], "plugin")
        argv = dock_argv(record, ["status", "--json"])
        self.assertEqual(argv[argv.index("--runtime") + 1], "plugin")
        self.assertEqual(argv[argv.index("--instance") + 1], "5555")
        wrong_mode = json.loads(json.dumps(good))
        wrong_mode["data"]["runtime"]["mode"] = "standalone"
        with self.assertRaises(ValueError):
            qualify_guest_dock(record, wrong_mode)
        changed_pid = json.loads(json.dumps(good))
        changed_pid["data"]["runtime"]["instanceId"] = "999"
        with self.assertRaises(ValueError):
            qualify_guest_dock(record, changed_pid)

    def test_plugin_shell_config_enables_smartdock_and_disables_first_party(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp) / "plugins"
            (root / "bar").mkdir(parents=True)
            (root / "idle").mkdir()
            (root / "bar" / "manifest.json").write_text(
                json.dumps(
                    {
                        "schemaVersion": 1,
                        "id": "omarchy.bar",
                        "name": "Bar",
                        "version": "1.0.0",
                        "kinds": ["bar"],
                        "entryPoints": {"bar": "Bar.qml"},
                    }
                ),
                encoding="utf-8",
            )
            (root / "idle" / "manifest.json").write_text(
                json.dumps(
                    {
                        "schemaVersion": 1,
                        "id": "omarchy.idle",
                        "name": "Idle",
                        "version": "1.0.0",
                        "kinds": ["service"],
                        "entryPoints": {"service": "Service.qml"},
                    }
                ),
                encoding="utf-8",
            )
            ids = first_party_plugin_ids(root)
            self.assertEqual(ids, ["omarchy.bar", "omarchy.idle"])
            config = plugin_shell_config(ids)
        self.assertEqual(config["version"], 1)
        self.assertEqual(
            config["plugins"],
            [{"id": "io.github.fernandodamaso.dockrail"}],
        )
        self.assertEqual(sorted(config["disabledPlugins"]), ["omarchy.bar", "omarchy.idle"])
        self.assertEqual(config["bar"]["layout"], {"left": [], "center": [], "right": []})
        self.assertIsInstance(config["plugins"][0], dict)
        self.assertNotIsInstance(config["plugins"][0], str)


class CrossTargetingTests(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp(prefix="dev-session-cross-"))
        self.state_home = self.tmp / "state-home"
        self.runtime_dir = self.tmp / "runtime"
        self.state_home.mkdir()
        self.runtime_dir.mkdir()
        self.env = mock.patch.dict(
            os.environ,
            {
                "XDG_STATE_HOME": str(self.state_home),
                "XDG_RUNTIME_DIR": str(self.runtime_dir),
            },
        )
        self.env.start()

    def tearDown(self):
        self.env.stop()
        shutil.rmtree(self.tmp, ignore_errors=True)

    def write_record(self, name, record):
        session = session_dir(name)
        session.mkdir(mode=0o700, parents=True)
        (session / "id_ed25519").write_bytes(b"key-" + name.encode())
        os.chmod(session / "id_ed25519", 0o600)
        (session / "known_hosts").write_text("", encoding="utf-8")
        evidence = session / "evidence"
        evidence.mkdir()
        record = dict(record)
        record.setdefault("evidence_path", str(evidence))
        (session / "record.json").write_text(json.dumps(record), encoding="utf-8")
        return record, session, evidence

    def test_two_records_use_distinct_ssh_and_evidence(self):
        rec_a, session_a, evidence_a = self.write_record(
            "agent-a",
            {"name": "agent-a", "state": "starting", "port": 22001},
        )
        rec_b, session_b, evidence_b = self.write_record(
            "agent-b",
            {"name": "agent-b", "state": "starting", "port": 22002},
        )
        argv_a = ssh_argv(rec_a, "true")
        argv_b = ssh_argv(rec_b, "true")
        self.assertNotEqual(argv_a, argv_b)
        self.assertNotEqual(argv_a[argv_a.index("-i") + 1], argv_b[argv_b.index("-i") + 1])
        self.assertNotEqual(argv_a[argv_a.index("-p") + 1], argv_b[argv_b.index("-p") + 1])
        known_a = next(part for part in argv_a if part.startswith("UserKnownHostsFile="))
        known_b = next(part for part in argv_b if part.startswith("UserKnownHostsFile="))
        self.assertNotEqual(known_a, known_b)
        self.assertIn(str(session_a / "id_ed25519"), argv_a)
        self.assertIn(str(session_b / "id_ed25519"), argv_b)
        self.assertNotEqual(evidence_a, evidence_b)
        self.assertEqual(Path(rec_a["evidence_path"]), evidence_a)
        self.assertEqual(Path(rec_b["evidence_path"]), evidence_b)

    def test_forged_a_pid_does_not_signal_b(self):
        proc_a = subprocess.Popen(
            [sys.executable, "-c", "import time; time.sleep(30)"],
            start_new_session=True,
        )
        proc_b = subprocess.Popen(
            [sys.executable, "-c", "import time; time.sleep(30)"],
            start_new_session=True,
        )
        try:
            ident_a = process_identity(proc_a.pid)
            ident_b = process_identity(proc_b.pid)
            self.write_record(
                "agent-a",
                {
                    "name": "agent-a",
                    "state": "starting",
                    "port": 22001,
                    "qemu_pid": ident_a["pid"],
                    "qemu_start_ticks": ident_a["start_ticks"] + 1,
                    "qemu_pgid": ident_a["pgid"],
                },
            )
            rec_b, _, _ = self.write_record(
                "agent-b",
                {
                    "name": "agent-b",
                    "state": "starting",
                    "port": 22002,
                    "qemu_pid": ident_b["pid"],
                    "qemu_start_ticks": ident_b["start_ticks"],
                    "qemu_pgid": ident_b["pgid"],
                },
            )
            with self.assertRaisesRegex(ValueError, "ownership mismatch"):
                stop("agent-a")
            self.assertIsNone(proc_a.poll())
            self.assertIsNone(proc_b.poll())
            self.assertEqual(read_record("agent-b")["qemu_pid"], rec_b["qemu_pid"])
            self.assertEqual(read_record("agent-b")["state"], "starting")
            self.assertEqual(stop("agent-b")["state"], "stopped")
            self.assertIsNotNone(proc_b.poll())
            self.assertIsNone(proc_a.poll())
            self.assertEqual(read_record("agent-a")["state"], "failed")
        finally:
            for proc in (proc_a, proc_b):
                if proc.poll() is None:
                    proc.terminate()
                    proc.wait(timeout=5)


GUEST_CONTROL_SH = Path(__file__).resolve().parent / "runtime/dev-session/guest-control.sh"


def _test_machine_is_kvm_guest():
    """Mirror guest-control.sh: on a KVM guest its host guard rightly passes."""
    fields = []
    for name in ("sys_vendor", "product_name"):
        try:
            fields.append(Path("/sys/class/dmi/id", name).read_text(errors="replace"))
        except OSError:
            pass
    try:
        fields.append(subprocess.run(
            ["systemd-detect-virt", "--vm"], capture_output=True, text=True, timeout=5,
        ).stdout)
    except (OSError, subprocess.SubprocessError):
        pass
    return any(marker in field.lower() for field in fields for marker in ("qemu", "kvm"))


skip_in_kvm_guest = unittest.skipIf(
    _test_machine_is_kvm_guest(), "the host guard intentionally passes inside a KVM guest")


class GuestControlHostGuardTests(unittest.TestCase):
    def run_control(self, cmd, extra_env=None):
        env = os.environ.copy()
        env["SMARTDOCK_SESSION_NAME"] = "agent-guard"
        env["SMARTDOCK_CANDIDATE"] = "/home/admin/smartdock-candidate"
        env["SMARTDOCK_SESSION_MODE"] = "standalone"
        if extra_env:
            env.update(extra_env)
        return subprocess.run(
            ["bash", str(GUEST_CONTROL_SH), cmd],
            capture_output=True,
            text=True,
            env=env,
            timeout=5,
        )

    def test_guest_control_is_two_head_production_host(self):
        text = GUEST_CONTROL_SH.read_text(encoding="utf-8")
        self.assertNotIn("expected exactly one monitor", text)
        self.assertIn("seed-desktop", text)
        self.assertIn("guest_ready.py", text)
        self.assertIn("hl.dsp.exec_cmd", text)
        lua = (GUEST_CONTROL_SH.parent / "guest-hyprland.lua").read_text(encoding="utf-8")
        self.assertIn("auto-right", lua)

    @skip_in_kvm_guest
    def test_start_dock_refuses_on_host(self):
        result = self.run_control("start-dock")
        self.assertNotEqual(result.returncode, 0)
        self.assertRegex(result.stderr, r"refuses to run on the host")
        self.assertNotRegex(result.stderr, r"missing.*ready")

    def test_start_dock_refuses_wrong_candidate_path(self):
        result = self.run_control(
            "start-dock",
            extra_env={"SMARTDOCK_CANDIDATE": "/tmp/not-a-guest-candidate"},
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertRegex(result.stderr, r"refuses to run on the host")

    @skip_in_kvm_guest
    def test_start_compositor_refuses_on_host(self):
        result = self.run_control("start-compositor")
        self.assertNotEqual(result.returncode, 0)
        self.assertRegex(result.stderr, r"refuses to run on the host")

    @skip_in_kvm_guest
    def test_env_capture_and_stop_dock_refuse_on_host(self):
        for cmd in ("env", "capture", "stop-dock", "seed-desktop"):
            result = subprocess.run(
                ["bash", str(GUEST_CONTROL_SH), cmd]
                + (["/tmp/smartdock-host-capture.png"] if cmd == "capture" else []),
                capture_output=True,
                text=True,
                env={
                    **os.environ,
                    "SMARTDOCK_SESSION_NAME": "agent-guard",
                    "SMARTDOCK_CANDIDATE": "/home/admin/smartdock-candidate",
                    "SMARTDOCK_SESSION_MODE": "standalone",
                },
                timeout=5,
            )
            self.assertNotEqual(result.returncode, 0, cmd)
            self.assertRegex(result.stderr, r"refuses to run on the host", cmd)
            self.assertNotRegex(result.stderr, r"missing.*ready", cmd)


class GuestTargetingStatusTests(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp(prefix="dev-session-target-"))
        self.state_home = self.tmp / "state-home"
        self.runtime_dir = self.tmp / "runtime"
        self.state_home.mkdir()
        self.runtime_dir.mkdir()
        self.env = mock.patch.dict(
            os.environ,
            {
                "XDG_STATE_HOME": str(self.state_home),
                "XDG_RUNTIME_DIR": str(self.runtime_dir),
            },
        )
        self.env.start()
        self.session = session_dir("agent-target")
        self.session.mkdir(mode=0o700, parents=True)

    def tearDown(self):
        self.env.stop()
        shutil.rmtree(self.tmp, ignore_errors=True)

    def test_status_json_marks_guest_not_production(self):
        (self.session / "record.json").write_text(
            json.dumps(
                {
                    "name": "agent-target",
                    "state": "ready",
                    "host_pid": 4577,
                    "config_path": GUEST_CONFIG_PATH,
                    "qemu_pid": 2**30,
                    "qemu_start_ticks": 1,
                    "qemu_pgid": 2**30,
                }
            ),
            encoding="utf-8",
        )
        result = status("agent-target")
        self.assertEqual(result["target"], "guest")
        self.assertEqual(result["guest_dock_pid"], 4577)
        self.assertEqual(result["guest_config_path"], GUEST_CONFIG_PATH)
        self.assertEqual(result["host_pid"], 4577)
        self.assertEqual(result["config_path"], GUEST_CONFIG_PATH)
        self.assertNotEqual(result["host_pid"], os.getpid())
        self.assertNotIn("/usr/share/omarchy", json.dumps(result))


class ReadySyncDockTests(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp(prefix="dev-session-ready-sync-"))
        self.source = _init_candidate_repo(self.tmp / "source")
        self.state_home = self.tmp / "state-home"
        self.runtime_dir = self.tmp / "runtime"
        self.state_home.mkdir()
        self.runtime_dir.mkdir()
        self.env = mock.patch.dict(
            os.environ,
            {
                "XDG_STATE_HOME": str(self.state_home),
                "XDG_RUNTIME_DIR": str(self.runtime_dir),
            },
        )
        self.env.start()
        self.session = session_dir("agent-sync")
        self.session.mkdir(parents=True)
        self.evidence = self.session / "evidence"
        self.evidence.mkdir()
        self.record = {
            "name": "agent-sync",
            "state": "ready",
            "mode": "standalone",
            "source": str(self.source),
            "source_digest": "prior-digest",
            "port": 22001,
            "qemu_pid": 1,
            "qemu_start_ticks": 1,
            "qemu_pgid": 1,
            "host_pid": 4577,
            "guest_dock_pid": 4577,
            "config_path": GUEST_CONFIG_PATH,
            "evidence_path": str(self.evidence),
            "error": None,
        }
        (self.session / "record.json").write_text(
            json.dumps(self.record), encoding="utf-8"
        )

    def tearDown(self):
        self.env.stop()
        shutil.rmtree(self.tmp, ignore_errors=True)

    def test_ready_sync_stops_dock_and_rejects_cli_until_restart(self):
        scp_calls = []

        def fake_scp(_record, local, remote):
            scp_calls.append(remote)
            Path(local).touch(exist_ok=True)

        def fake_ssh(_record, command, _timeout):
            _, digest = source_manifest(self.source)
            return subprocess.CompletedProcess(command, 0, stdout=digest + "\n", stderr="")

        with mock.patch("dev_session._scp_to_guest", side_effect=fake_scp):
            with mock.patch("dev_session._run_ssh", side_effect=fake_ssh):
                with mock.patch("dev_session.owned_process", return_value=True):
                    with mock.patch("dev_session._stop_guest_dock") as stop_dock:
                        digest = sync_source(self.record)
                        stop_dock.assert_called_once()
                        latest = read_record("agent-sync")
                        self.assertEqual(latest["state"], "starting")
                        self.assertIsNone(latest["host_pid"])
                        self.assertIsNone(latest["guest_dock_pid"])
                        self.assertEqual(latest["source_digest"], digest)
                        with self.assertRaisesRegex(ValueError, r"dock in state 'starting'"):
                            guest_dock("agent-sync", ["status", "--json"])


class StartRaceTests(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp(prefix="dev-session-start-race-"))
        self.source = _init_candidate_repo(self.tmp / "source")
        self.state_home = self.tmp / "state-home"
        self.runtime_dir = self.tmp / "runtime"
        self.state_home.mkdir()
        self.runtime_dir.mkdir()
        self.base = self.tmp / "base.qcow2"
        self.base.write_bytes(b"fake-base")
        self.env = mock.patch.dict(
            os.environ,
            {
                "XDG_STATE_HOME": str(self.state_home),
                "XDG_RUNTIME_DIR": str(self.runtime_dir),
            },
        )
        self.env.start()

    def tearDown(self):
        self.env.stop()
        shutil.rmtree(self.tmp, ignore_errors=True)

    def test_stop_during_start_does_not_resurrect_failed(self):
        proc = subprocess.Popen(
            [sys.executable, "-c", "import time; time.sleep(30)"],
            start_new_session=True,
        )
        try:
            ident = process_identity(proc.pid)
            session = session_dir("agent-start")
            evidence = session / "evidence"
            evidence.mkdir(parents=True, mode=0o700)
            paths = {
                "session": session,
                "evidence": evidence,
                "source": self.source,
                "base_image": self.base,
                "overlay": session / "overlay.qcow2",
                "vars": session / "vars.fd",
                "seed": session / "seed.iso",
                "ssh_key": session / "id_ed25519",
                "ssh_pub": session / "id_ed25519.pub",
            }
            for key in ("overlay", "vars", "seed", "ssh_key", "ssh_pub"):
                paths[key].write_bytes(b"x")

            host_state = {
                "active_workspace": {"id": 1, "name": "1"},
                "active_window": {"address": "0x1", "title": "test"},
                "cursorpos": "10,10",
                "production_settings_sha256": "abc",
            }

            def fake_wait(record, _evidence):
                self.assertEqual(stop(record["name"])["state"], "stopped")
                raise RuntimeError("inject-after-stop")

            with mock.patch("dev_session.prepare_private_inputs", return_value=paths):
                with mock.patch("dev_session._capture_host_state", return_value=host_state):
                    with mock.patch("dev_session._launch_rule"):
                        with mock.patch("dev_session._disable_launch_rule"):
                            with mock.patch(
                                "dev_session._reserve_port_locked", return_value=22042
                            ):
                                with mock.patch(
                                    "dev_session.qemu_argv", return_value=["true"]
                                ):
                                    with mock.patch(
                                        "dev_session.subprocess.Popen",
                                        return_value=proc,
                                    ):
                                        with mock.patch(
                                            "dev_session._wait_for_owned_port"
                                        ):
                                            with mock.patch(
                                                "dev_session._place_owned_window",
                                                return_value={"address": "0xdead"},
                                            ):
                                                with mock.patch(
                                                    "dev_session._show_both_qemu_heads",
                                                    return_value=[
                                                        {"address": "0xdead", "at": [0, 0]}
                                                    ],
                                                ):
                                                    with mock.patch(
                                                        "dev_session._wait_for_guest_setup",
                                                        side_effect=fake_wait,
                                                    ):
                                                        with self.assertRaisesRegex(
                                                            RuntimeError,
                                                            "inject-after-stop",
                                                        ):
                                                            start(
                                                                "agent-start",
                                                                source=self.source,
                                                                base_image=self.base,
                                                                mode="standalone",
                                                                workspace="4",
                                                            )
            latest = read_record("agent-start")
            self.assertEqual(latest["state"], "stopped")
            self.assertNotEqual(latest["state"], "failed")
            self.assertIsNotNone(proc.poll())
        finally:
            if proc.poll() is None:
                proc.terminate()
                proc.wait(timeout=5)

    def _start_paths(self, name: str) -> dict:
        session = session_dir(name)
        evidence = session / "evidence"
        evidence.mkdir(parents=True, mode=0o700)
        paths = {
            "session": session,
            "evidence": evidence,
            "source": self.source,
            "base_image": self.base,
            "overlay": session / "overlay.qcow2",
            "vars": session / "vars.fd",
            "seed": session / "seed.iso",
            "ssh_key": session / "id_ed25519",
            "ssh_pub": session / "id_ed25519.pub",
        }
        for key in ("overlay", "vars", "seed", "ssh_key", "ssh_pub"):
            paths[key].write_bytes(b"x")
        return paths

    def test_start_exception_releases_port_after_early_stop(self):
        proc = subprocess.Popen(
            [sys.executable, "-c", "import time; time.sleep(30)"],
            start_new_session=True,
        )
        try:
            paths = self._start_paths("agent-port")
            host_state = {
                "active_workspace": {"id": 1, "name": "1"},
                "active_window": {"address": "0x1", "title": "test"},
                "cursorpos": "10,10",
                "production_settings_sha256": "abc",
            }
            reserved = {"port": None}

            def wrapping_commit(updated, **kwargs):
                if kwargs.get("allow_identity_assign"):
                    reserved["port"] = updated.get("port")
                    self.assertIsInstance(reserved["port"], int)
                    self.assertTrue(
                        _reservation_path(
                            default_runtime_root(), reserved["port"]
                        ).is_file()
                    )
                    self.assertEqual(stop(updated["name"])["state"], "stopped")
                return _commit_live_record(updated, **kwargs)

            with mock.patch("dev_session.prepare_private_inputs", return_value=paths):
                with mock.patch("dev_session._capture_host_state", return_value=host_state):
                    with mock.patch("dev_session._launch_rule"):
                        with mock.patch("dev_session._disable_launch_rule"):
                            with mock.patch(
                                "dev_session.qemu_argv", return_value=["true"]
                            ):
                                with mock.patch(
                                    "dev_session.subprocess.Popen",
                                    return_value=proc,
                                ):
                                    with mock.patch(
                                        "dev_session._commit_live_record",
                                        side_effect=wrapping_commit,
                                    ):
                                        with self.assertRaises(ValueError):
                                            start(
                                                "agent-port",
                                                source=self.source,
                                                base_image=self.base,
                                                mode="standalone",
                                                workspace="4",
                                            )
            self.assertEqual(read_record("agent-port")["state"], "stopped")
            self.assertFalse(
                _reservation_path(
                    default_runtime_root(), reserved["port"]
                ).exists()
            )
            self.assertIsNotNone(proc.poll())
        finally:
            if proc.poll() is None:
                proc.terminate()
                proc.wait(timeout=5)

    def test_qemu_exit_while_stopping_returns_stopping(self):
        paths = self._start_paths("agent-wait")
        host_state = {
            "active_workspace": {"id": 1, "name": "1"},
            "active_window": {"address": "0x1", "title": "test"},
            "cursorpos": "10,10",
            "production_settings_sha256": "abc",
        }
        identity = {"pid": 424242, "start_ticks": 99, "pgid": 424242}
        proc = mock.Mock()
        proc.pid = 424242

        def wait_and_mark_stopping(*_args, **_kwargs):
            from dev_session import _write_record

            record = read_record("agent-wait")
            record["state"] = "stopping"
            _write_record(record)
            return 0

        proc.wait.side_effect = wait_and_mark_stopping

        def fake_dock(name):
            record = read_record(name)
            record["state"] = "ready"
            record["host_pid"] = 7
            record["guest_dock_pid"] = 7
            from dev_session import _write_record

            _write_record(record)
            return record

        with mock.patch("dev_session.prepare_private_inputs", return_value=paths):
            with mock.patch("dev_session._capture_host_state", return_value=host_state):
                with mock.patch("dev_session._launch_rule"):
                    with mock.patch("dev_session._disable_launch_rule"):
                        with mock.patch(
                            "dev_session._reserve_port_locked", return_value=22055
                        ):
                            with mock.patch(
                                "dev_session.qemu_argv", return_value=["true"]
                            ):
                                with mock.patch(
                                    "dev_session.subprocess.Popen",
                                    return_value=proc,
                                ):
                                    with mock.patch(
                                        "dev_session.process_identity",
                                        return_value=identity,
                                    ):
                                        with mock.patch(
                                            "dev_session._wait_for_owned_port"
                                        ):
                                            with mock.patch(
                                                "dev_session._place_owned_window",
                                                return_value={"address": "0xbeef"},
                                            ):
                                                with mock.patch(
                                                    "dev_session._show_both_qemu_heads",
                                                    return_value=[
                                                        {"address": "0xbeef", "at": [0, 0]}
                                                    ],
                                                ):
                                                    with mock.patch(
                                                        "dev_session._wait_for_guest_setup"
                                                    ):
                                                        with mock.patch(
                                                            "dev_session.sync_source"
                                                        ):
                                                            with mock.patch(
                                                                "dev_session._run_guest_argv",
                                                                return_value=mock.Mock(
                                                                    returncode=0,
                                                                    stdout="",
                                                                    stderr="",
                                                                ),
                                                            ):
                                                                with mock.patch(
                                                                    "dev_session.start_guest_dock",
                                                                    side_effect=fake_dock,
                                                                ):
                                                                    result = start(
                                                                        "agent-wait",
                                                                        source=self.source,
                                                                        base_image=self.base,
                                                                        mode="standalone",
                                                                        workspace="4",
                                                                    )
        self.assertEqual(result["state"], "stopping")
        self.assertIsNone(result.get("error"))
        self.assertEqual(read_record("agent-wait")["state"], "stopping")

    def test_stop_rereads_identity_under_lock(self):
        import threading
        import time

        proc = subprocess.Popen(
            [sys.executable, "-c", "import time; time.sleep(30)"],
            start_new_session=True,
        )
        try:
            ident = process_identity(proc.pid)
            self.assertIsNotNone(ident)
            session = session_dir("agent-lock")
            session.mkdir(parents=True, mode=0o700)
            seed = {
                "name": "agent-lock",
                "state": "starting",
                "qemu_pid": None,
                "qemu_start_ticks": None,
                "qemu_pgid": None,
                "port": 22066,
                "error": None,
            }
            from dev_session import _write_record

            _write_record(seed)
            lock_held = threading.Event()
            result = {}

            def stopper():
                lock_held.wait(timeout=5)
                result["record"] = stop("agent-lock")

            thread = threading.Thread(target=stopper)
            thread.start()
            with _flock(session / "record.lock"):
                lock_held.set()
                time.sleep(0.05)
                current = dict(_read_record_unlocked("agent-lock"))
                current.update(
                    {
                        "qemu_pid": ident["pid"],
                        "qemu_start_ticks": ident["start_ticks"],
                        "qemu_pgid": ident["pgid"],
                    }
                )
                _write_record_unlocked(current)
            thread.join(timeout=10)
            self.assertFalse(thread.is_alive())
            self.assertEqual(result["record"]["state"], "stopped")
            self.assertIsNotNone(proc.poll())
        finally:
            if proc.poll() is None:
                proc.terminate()
                proc.wait(timeout=5)


if __name__ == "__main__":
    unittest.main()
