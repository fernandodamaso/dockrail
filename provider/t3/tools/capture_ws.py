# SPDX-License-Identifier: Apache-2.0
"""Capture raw T3 orchestration WebSocket frames for protocol validation.

Slice-0 tooling only: never shipped as runtime code. Reads a bearer token
from a file, subscribes to ``orchestration.subscribeShell`` and writes every
raw server message (one JSON object per line) to ``--out``.

``--out`` must live inside a 0700 directory owned by the current user; the
tool refuses any other location so captured material never lands somewhere
shared.
"""
from __future__ import annotations

import argparse
import json
import os
import stat
import sys
import time
from pathlib import Path
from urllib.parse import quote

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

import t3http
from t3http import Failure
from t3ws import Closed, WebSocket


def _refuse_unless_private(out: Path) -> None:
    parent = out.resolve().parent
    try:
        info = os.lstat(parent)
    except OSError as exc:
        raise SystemExit(f"error: cannot stat output directory: {exc}")
    if not stat.S_ISDIR(info.st_mode):
        raise SystemExit("error: output directory is not a directory")
    if info.st_uid != os.getuid():
        raise SystemExit("error: output directory is not owned by you")
    if info.st_mode & 0o077:
        raise SystemExit("error: output directory must be mode 0700")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--token-file", required=True)
    parser.add_argument("--seconds", type=float, default=60.0)
    parser.add_argument("--out", required=True)
    parser.add_argument("--url", default="http://127.0.0.1:3773")
    parser.add_argument("--after-sequence", type=int, default=None)
    args = parser.parse_args()

    out = Path(args.out)
    _refuse_unless_private(out)
    try:
        token = Path(args.token_file).read_text(encoding="utf-8").strip()
    except OSError as exc:
        raise SystemExit(f"error: cannot read token file: {exc}")
    if not token:
        raise SystemExit("error: token file is empty")

    try:
        host, port = t3http.check_endpoint(args.url)
    except Failure as exc:
        raise SystemExit(f"error: bad url: {exc.code}")

    try:
        ticket_body = t3http.api_post(args.url, "/api/auth/websocket-ticket", token, {})
    except Failure as exc:
        raise SystemExit(f"error: ticket request failed: {exc.code}")
    ticket = ticket_body.get("ticket")
    if not isinstance(ticket, str) or not ticket:
        raise SystemExit("error: ticket response has no ticket")

    ws = WebSocket()
    try:
        ws.connect(
            host,
            port,
            f"/ws?orchestrationProtocol=2&wsTicket={quote(ticket, safe='')}"
            "&clientSurface=dockrail",
        )
    except Failure as exc:
        raise SystemExit(f"error: websocket handshake failed: {exc.code}")

    payload: dict[str, object] = {"requestCompletionMarker": True}
    if args.after_sequence is not None:
        payload["afterSequence"] = args.after_sequence
    ws.send_text(
        json.dumps(
            {
                "_tag": "Request",
                "id": "1",
                "tag": "orchestration.subscribeShell",
                "payload": payload,
                "headers": [],
            },
            separators=(",", ":"),
        )
    )

    deadline = time.monotonic() + max(1.0, args.seconds)
    pong_seen = False
    try:
        with open(out, "w", encoding="utf-8") as handle:
            while time.monotonic() < deadline:
                remaining = deadline - time.monotonic()
                try:
                    raw = ws.recv(min(1.0, remaining))
                except Closed:
                    break
                except Failure:
                    break
                if raw is None:
                    continue
                handle.write(raw + "\n")
                try:
                    message = json.loads(raw)
                except ValueError:
                    continue
                if not isinstance(message, dict):
                    continue
                tag = message.get("_tag")
                if tag == "Chunk":
                    request_id = message.get("requestId")
                    if isinstance(request_id, str):
                        ws.send_text(
                            json.dumps(
                                {"_tag": "Ack", "requestId": request_id},
                                separators=(",", ":"),
                            )
                        )
                elif tag == "Exit":
                    break
                elif tag == "Pong":
                    pong_seen = True
            ws.send_text(json.dumps({"_tag": "Ping"}, separators=(",", ":")))
            ping_deadline = time.monotonic() + 10.0
            while time.monotonic() < ping_deadline and not pong_seen:
                try:
                    raw = ws.recv(1.0)
                except (Closed, Failure):
                    break
                if raw is None:
                    continue
                handle.write(raw + "\n")
                try:
                    message = json.loads(raw)
                except ValueError:
                    continue
                if isinstance(message, dict) and message.get("_tag") == "Pong":
                    pong_seen = True
            handle.write(json.dumps({"_tag": "CapturePongSeen", "ok": pong_seen}) + "\n")
    finally:
        try:
            ws.send_text(
                json.dumps(
                    {"_tag": "Interrupt", "requestId": "1", "interruptors": []},
                    separators=(",", ":"),
                )
            )
        except Failure:
            pass
        ws.close()
    print(f"captured; pong seen: {pong_seen}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
