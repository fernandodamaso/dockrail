# SPDX-License-Identifier: Apache-2.0
"""SmartDock extraction hardening; no Herdr, omaherdr or desktop required."""
import json
from pathlib import Path
import runpy
import socket
import time
import unittest
from unittest.mock import patch

HELPER = Path(__file__).resolve().parents[1] / "bin" / "smartdock-herdr-helper"


class ProtocolTests(unittest.TestCase):
    def setUp(self):
        self.assertTrue(HELPER.is_file(), "SmartDock-owned helper is not scaffolded")
        self.module = runpy.run_path(str(HELPER))

    def test_import_does_not_connect_or_run_a_process(self):
        with patch("socket.socket", side_effect=AssertionError("import opened socket")):
            runpy.run_path(str(HELPER))

    def test_request_allowlist_rejects_mutation_before_connect(self):
        with patch("socket.socket", side_effect=AssertionError("mutation opened socket")):
            with self.assertRaises(self.module["ProtocolError"]):
                self.module["request"]("pane.focus", {"pane_id": "w1:p1"})

    def test_decoder_rejects_bad_json_nonobjects_and_nonfinite_numbers(self):
        for payload in (b"{", b"[]", b"null", b'{"x": NaN}', b'{"x": 1e999}', b"\xff"):
            with self.subTest(payload=payload), self.assertRaises(self.module["ProtocolError"]):
                self.module["decode_object"](payload)

    def test_snapshot_shape_is_not_silently_treated_as_empty(self):
        for value in ({}, {"panes": None}, {"panes": [None]}, {"panes": [], "agents": {}},
                      {"panes": [{"pane_id": None}]}):
            with self.subTest(value=value), self.assertRaises(self.module["ProtocolError"]):
                self.module["project_snapshot"](value)

    def test_projection_keeps_identity_but_drops_private_raw_fields(self):
        raw = {"panes": [{"pane_id": "w1:p1", "terminal_id": "t1", "cwd": "secret",
                          "terminal_title_stripped": "secret", "agent": "opencode",
                          "title": "Visible pane title"}],
               "agents": [{"pane_id": "w1:p1", "terminal_id": "t1", "agent_status": "done",
                           "state_change_seq": 2 ** 64 - 1, "transcript": "secret",
                           "title": "Visible agent title", "terminal_title": "secret"}],
               "tabs": [{"tab_id": "w1:t1", "label": "Tab Label", "cwd": "secret"}],
               "workspaces": [{"workspace_id": "w1", "label": "Fixture", "cwd": "secret"}]}
        result = self.module["project_snapshot"](raw)
        self.assertNotIn("secret", json.dumps(result))
        self.assertEqual(result["panes"][0]["terminal_id"], "t1")
        self.assertEqual(result["panes"][0]["title"], "Visible pane title")
        self.assertEqual(result["agents"][0]["title"], "Visible agent title")
        self.assertEqual(result["agents"][0]["state_change_seq"], str(2 ** 64 - 1))
        self.assertEqual(result["tabs"][0]["label"], "Tab Label")
        self.assertEqual(result["workspaces"][0]["label"], "Fixture")
        self.assertNotIn("terminal_title", result["agents"][0])
        self.assertNotIn("terminal_title_stripped", result["panes"][0])
        self.assertNotIn("cwd", result["workspaces"][0])

    def test_projection_preserves_bounded_server_version_and_protocol(self):
        result = self.module["project_snapshot"]({
            "panes": [], "version": "0.9.1", "protocol": 1,
        })
        self.assertEqual(result["version"], "0.9.1")
        self.assertEqual(result["protocol"], 1)
        result = self.module["project_snapshot"]({
            "panes": [], "version": ["0.9.0"], "protocol": {"major": 1},
        })
        self.assertNotIn("version", result)
        self.assertNotIn("protocol", result)

    def test_missing_inventory_is_not_invented_as_an_empty_list(self):
        result = self.module["project_snapshot"]({"panes": []})
        self.assertNotIn("agents", result)
        self.assertNotIn("workspaces", result)

    def test_bad_sequence_not_rounded_or_invented(self):
        for value in (True, -1, 2 ** 64, 1.5):
            result = self.module["project_snapshot"]({"panes": [], "agents": [
                {"pane_id": "w1:p1", "state_change_seq": value}]})
            self.assertNotIn("state_change_seq", result["agents"][0])

    def test_output_frame_limit_is_enforced(self):
        with self.assertRaises(self.module["ProtocolError"]):
            self.module["encode_message"]({"data": "x" * self.module["MAX_EVENT_BYTES"]})

    def test_invalid_status_becomes_unknown(self):
        result = self.module["project_snapshot"]({"panes": [], "agents": [
            {"pane_id": "w1:p1", "agent_status": "future-state"}]})
        self.assertEqual(result["agents"][0]["agent_status"], "unknown")


    def test_receive_line_rejects_oversized_unterminated_frames(self):
        left, right = socket.socketpair()
        try:
            right.sendall(b"x" * 17)
            with self.assertRaises(self.module["ProtocolError"]):
                self.module["receive_line"](left, 16, time.monotonic() + 1)
        finally:
            left.close()
            right.close()

    def test_receive_line_keeps_data_after_the_acknowledgement(self):
        left, right = socket.socketpair()
        try:
            right.sendall(b"ack\nevent\n")
            self.assertEqual(self.module["receive_line"](left, 32, time.monotonic() + 1),
                             (b"ack", b"event\n"))
        finally:
            left.close()
            right.close()

    def test_receive_line_obeys_a_whole_request_deadline(self):
        left, right = socket.socketpair()
        try:
            with self.assertRaises(OSError):
                self.module["receive_line"](left, 32, time.monotonic() + 0.02)
        finally:
            left.close()
            right.close()

    def test_failed_subscription_has_bounded_backoff(self):
        sub = self.module["Subscription"]()
        for _ in range(12):
            sub.failed()
        self.assertEqual(sub.backoff, 30)
        self.assertFalse(sub.snapshot_pending)
        self.assertIsNone(sub.sock)

    def test_deep_json_is_rejected(self):
        with self.assertRaises(self.module["ProtocolError"]):
            self.module["decode_object"](("{\"a\":" * 40 + "null" + "}" * 40).encode())

if __name__ == "__main__":
    unittest.main()
