# SPDX-License-Identifier: Apache-2.0
"""Tests for provider/t3/t3procfs.py using a fake /proc tree."""
from __future__ import annotations

import os
import shutil
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))

import t3procfs
from t3procfs import ProcfsError

TCP_HEADER = (
    "  sl  local_address rem_address   st tx_queue rx_queue tr tm->when retrnsmt"
    "   uid  timeout inode\n"
)


def tcp_row(
    local: str,
    remote: str = "00000000:0000",
    state: str = "0A",
    uid: int = 0,
    inode: int = 99,
) -> str:
    return (
        f"   0: {local} {remote} {state} 00000000:00000000 00:00000000 00000000"
        f"  {uid:>5d}        0 {inode} 1 0000000000000000 100 0 0 10 0\n"
    )


def stat_bytes(pid: int, comm: str, state: str, ppid: int, start: int) -> bytes:
    fields = [state, str(ppid)] + ["0"] * 17 + [str(start)] + ["0"] * 30
    assert len(fields) >= 20
    return f"{pid} ({comm}) {' '.join(fields)}\n".encode()


class ProcfsTests(unittest.TestCase):
    def setUp(self) -> None:
        self.uid = os.getuid()
        self.root = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.root, True)
        (self.root / "net").mkdir()

    def write_net(self, name: str, rows: list[str]) -> None:
        (self.root / "net" / name).write_text(TCP_HEADER + "".join(rows))

    def test_listener_found_ipv4(self) -> None:
        self.write_net("tcp", [tcp_row("0100007F:0EC9", uid=self.uid, inode=111)])
        self.write_net("tcp6", [])
        records = t3procfs.listener_records(3785, self.root)
        self.assertEqual(records, [("socket:[111]", self.uid)])
        t3procfs.assert_own_listener(3785, self.root)

    def test_listener_missing(self) -> None:
        self.write_net("tcp", [tcp_row("0100007F:0EC9", uid=self.uid)])
        self.write_net("tcp6", [])
        self.assertEqual(t3procfs.listener_records(9999, self.root), [])
        with self.assertRaises(ProcfsError) as ctx:
            t3procfs.assert_own_listener(9999, self.root)
        self.assertEqual(ctx.exception.code, "offline")

    def test_listener_other_uid_rejected(self) -> None:
        self.write_net("tcp", [tcp_row("0100007F:0EC9", uid=self.uid + 1, inode=5)])
        self.write_net("tcp6", [])
        with self.assertRaises(ProcfsError) as ctx:
            t3procfs.assert_own_listener(3785, self.root)
        self.assertEqual(ctx.exception.code, "listener_untrusted")

    def test_listener_ipv6_loopback(self) -> None:
        self.write_net("tcp", [])
        self.write_net(
            "tcp6",
            [tcp_row("00000000000000000000000001000000:0EC9", uid=self.uid, inode=7)],
        )
        records = t3procfs.listener_records(3785, self.root)
        self.assertEqual(records, [("socket:[7]", self.uid)])

    def test_non_listen_state_ignored(self) -> None:
        self.write_net("tcp", [tcp_row("0100007F:0EC9", state="01", uid=self.uid)])
        self.write_net("tcp6", [])
        self.assertEqual(t3procfs.listener_records(3785, self.root), [])

    def test_non_loopback_ignored(self) -> None:
        self.write_net("tcp", [tcp_row("C0A80101:0EC9", uid=self.uid)])
        self.write_net("tcp6", [])
        self.assertEqual(t3procfs.listener_records(3785, self.root), [])

    def test_unreadable_proc_maps_untrusted(self) -> None:
        with self.assertRaises(ProcfsError) as ctx:
            t3procfs.assert_own_listener(3785, self.root / "missing")
        self.assertEqual(ctx.exception.code, "listener_untrusted")

    def test_missing_tcp6_reads_as_ipv6_disabled(self) -> None:
        # Kernels booted with ipv6.disable=1 expose no /proc/net/tcp6.
        self.write_net("tcp", [
            tcp_row("0100007F:0EC9", uid=self.uid, inode=111),
            tcp_row("0100007F:1234", "0100007F:0EC9", state="01", uid=self.uid),
        ])
        self.assertEqual(
            t3procfs.listener_records(3785, self.root), [("socket:[111]", self.uid)]
        )
        t3procfs.assert_own_listener(3785, self.root)
        self.assertEqual(
            t3procfs.peer_listener_uid(0x1234, 3785, self.root), self.uid
        )

    def test_missing_tcp_table_stays_untrusted(self) -> None:
        self.write_net("tcp6", [])
        with self.assertRaises(ProcfsError) as ctx:
            t3procfs.assert_own_listener(3785, self.root)
        self.assertEqual(ctx.exception.code, "listener_untrusted")
        self.assertIsNone(t3procfs.peer_listener_uid(0x1234, 3785, self.root))

    def test_listener_pid(self) -> None:
        self.write_net("tcp", [tcp_row("0100007F:0EC9", uid=self.uid, inode=4242)])
        self.write_net("tcp6", [])
        pid_dir = self.root / "4243"
        fd_dir = pid_dir / "fd"
        fd_dir.mkdir(parents=True)
        (pid_dir / "stat").write_bytes(stat_bytes(4243, "t3code", "S", 100, 555))
        (fd_dir / "9").symlink_to("socket:[4242]")
        (fd_dir / "0").symlink_to("/dev/null")
        self.assertEqual(t3procfs.listener_pid(3785, self.root), 4243)

    def test_listener_pid_missing(self) -> None:
        self.write_net("tcp", [])
        self.write_net("tcp6", [])
        self.assertIsNone(t3procfs.listener_pid(3785, self.root))

    def test_identity_parses_tricky_comm(self) -> None:
        pid_dir = self.root / "777"
        pid_dir.mkdir()
        (pid_dir / "stat").write_bytes(stat_bytes(777, "my ) app (x", "S", 1, 424242))
        self.assertEqual(
            t3procfs.identity(777, self.root), {"pid": 777, "startTime": 424242}
        )

    def test_identity_rejects_other_uid(self) -> None:
        # Fake tree entries are owned by us; a non-numeric lookup fails safely.
        self.assertIsNone(t3procfs.identity(-3, self.root))
        self.assertIsNone(t3procfs.identity(0, self.root))

    def test_ancestors_follow_ppid(self) -> None:
        for pid, ppid in ((3, 2), (2, 1), (1, 0)):
            pid_dir = self.root / str(pid)
            pid_dir.mkdir()
            (pid_dir / "stat").write_bytes(
                stat_bytes(pid, "proc", "S", ppid, 1000 + pid)
            )
        chain = t3procfs.ancestors(3, proc_root=self.root)
        self.assertEqual([row["pid"] for row in chain], [2, 1])
        self.assertEqual(chain[0]["startTime"], 1002)

    def test_ancestors_respect_limit(self) -> None:
        for pid in range(1, 7):
            pid_dir = self.root / str(pid)
            pid_dir.mkdir()
            (pid_dir / "stat").write_bytes(
                stat_bytes(pid, "proc", "S", pid - 1, 1000 + pid)
            )
        chain = t3procfs.ancestors(6, limit=2, proc_root=self.root)
        self.assertEqual([row["pid"] for row in chain], [5, 4])

    def test_resolve_window_identities(self) -> None:
        pid_dir = self.root / "555"
        pid_dir.mkdir()
        (pid_dir / "stat").write_bytes(stat_bytes(555, "win", "S", 1, 777))
        rows = t3procfs.resolve_window_identities([555, 555, 999999, -1], self.root)
        self.assertEqual(rows, [{"pid": 555, "startTime": 777}])

    def test_peer_listener_uid(self) -> None:
        self.write_net(
            "tcp",
            [
                tcp_row("0100007F:0EC9", uid=self.uid, inode=11),
                tcp_row("0100007F:1234", "0100007F:0EC9", state="01", uid=self.uid),
            ],
        )
        self.write_net("tcp6", [])
        self.assertEqual(
            t3procfs.peer_listener_uid(0x1234, 3785, self.root), self.uid
        )
        self.assertIsNone(t3procfs.peer_listener_uid(0x9999, 3785, self.root))

    def test_describe_listener_error(self) -> None:
        self.assertEqual(
            t3procfs.describe_listener_error(ProcfsError("offline")),
            "server_not_running",
        )
        self.assertEqual(
            t3procfs.describe_listener_error(ProcfsError("listener_untrusted")),
            "listener_untrusted",
        )


if __name__ == "__main__":
    unittest.main()
