# SPDX-License-Identifier: Apache-2.0
"""Normalized, privacy-bounded Herdr state adapted from omaherdr Server logic."""
from __future__ import annotations

import copy
from dataclasses import dataclass, field
import time
from typing import Any

MAX_SERVERS = 64
MAX_AGENTS = 256
STATUSES = ("blocked", "done", "working", "idle", "unknown")
STRUCTURAL_PREFIXES = ("workspace.", "tab.", "pane.", "layout.")


def _text(value: object, maximum: int = 256) -> str | None:
    if not isinstance(value, str):
        return None
    cleaned = "".join(char for char in value[:maximum]
                      if ord(char) >= 32 and ord(char) != 127
                      and not 0xD800 <= ord(char) <= 0xDFFF)
    return cleaned or None


def _status(value: object) -> str:
    return value if isinstance(value, str) and value in STATUSES else "unknown"


def _identity(value: object) -> str | None:
    value = _text(value, 128)
    if not value or any(char.isspace() for char in value):
        return None
    return value


def _public_clients(value: object) -> list[dict[str, Any]]:
    if not isinstance(value, list):
        return []
    output: list[dict[str, Any]] = []
    for client in value[:16]:
        if not isinstance(client, dict):
            continue
        pid = client.get("pid")
        start = client.get("startTime")
        if not isinstance(pid, int) or isinstance(pid, bool) or pid <= 0:
            continue
        if not isinstance(start, int) or isinstance(start, bool) or start < 0:
            continue
        ancestors: list[dict[str, Any]] = []
        raw_ancestors = client.get("ancestors")
        if isinstance(raw_ancestors, list):
            for ancestor in raw_ancestors[:8]:
                if not isinstance(ancestor, dict):
                    continue
                apid = ancestor.get("pid")
                astart = ancestor.get("startTime")
                if not isinstance(apid, int) or isinstance(apid, bool) or apid <= 0:
                    continue
                if not isinstance(astart, int) or isinstance(astart, bool) or astart < 0:
                    continue
                ancestors.append({"pid": apid, "startTime": astart})
        output.append({"pid": pid, "startTime": start, "ancestors": ancestors})
    return output


def _sequence(value: object) -> str | None:
    if isinstance(value, str) and value.isdecimal():
        try:
            number = int(value)
        except ValueError:
            return None
        if 0 <= number < 2 ** 64:
            return str(number)
    if isinstance(value, int) and not isinstance(value, bool) and 0 <= value < 2 ** 64:
        return str(value)
    return None


@dataclass
class ServerState:
    info: dict[str, Any]
    generation: int = 1
    connected: bool = False
    snapshot: dict[str, Any] | None = None
    last_known_snapshot: dict[str, Any] | None = None
    last_snapshot_at: float | None = None
    error: str = "starting"
    observed_status: dict[str, str] = field(default_factory=dict)
    observed_since: dict[str, float] = field(default_factory=dict)
    snapshot_due: float | None = None
    clients: list[dict[str, Any]] = field(default_factory=list)

    @property
    def id(self) -> str:
        return str(self.info["id"])

    @property
    def live(self) -> bool:
        return self.connected and self.snapshot is not None

    @property
    def inventory_known(self) -> bool:
        return self.live and isinstance(self.snapshot, dict) and isinstance(self.snapshot.get("agents"), list)

    def invalidate_connection(self, error: str = "reconnecting") -> None:
        # Any loss after state was installed creates a new identity generation.
        # A reused pane id after reconnect can therefore never alias the old pane.
        if self.connected or self.snapshot is not None:
            self.generation += 1
        self.connected = False
        self.snapshot = None
        self.error = error
        self.snapshot_due = None
        self.observed_status.clear()
        self.observed_since.clear()

    def replace_connection(self) -> None:
        self.invalidate_connection("reconnecting")

    def apply_status(self, message: dict[str, Any]) -> None:
        connected = message.get("connected") is True
        if not connected:
            self.invalidate_connection("disconnected")
            return
        self.connected = True
        if self.snapshot is not None:
            self.error = ""

    def apply_snapshot(self, message: dict[str, Any], now: float) -> None:
        if message.get("ok") is not True or not isinstance(message.get("snapshot"), dict):
            self.invalidate_connection(_text(message.get("error"), 64) or "snapshot_unavailable")
            return
        snap = copy.deepcopy(message["snapshot"])
        panes = snap.get("panes")
        if not isinstance(panes, list):
            self.invalidate_connection("invalid_snapshot")
            return
        agents = snap.get("agents")
        if agents is not None and not isinstance(agents, list):
            self.invalidate_connection("invalid_snapshot")
            return

        self.snapshot = snap
        self.last_known_snapshot = copy.deepcopy(snap)
        self.last_snapshot_at = now
        self.error = "" if self.connected else "awaiting_event_stream"

        live_panes: set[str] = set()
        rows = agents if isinstance(agents, list) else panes
        for row in rows:
            if not isinstance(row, dict):
                continue
            pane = _identity(row.get("pane_id"))
            if not pane:
                continue
            live_panes.add(pane)
            status = _status(row.get("agent_status"))
            if self.observed_status.get(pane) != status:
                self.observed_status[pane] = status
                self.observed_since[pane] = now
        for pane in list(self.observed_status):
            if pane not in live_panes:
                self.observed_status.pop(pane, None)
                self.observed_since.pop(pane, None)

    def apply_event(self, message: dict[str, Any], now: float, debounce: float = 0.25) -> None:
        event = message.get("event")
        data = message.get("data")
        if not isinstance(event, str) or not isinstance(data, dict):
            return
        family, separator, suffix = event.partition("_")
        if separator and f"{family}." in STRUCTURAL_PREFIXES:
            event = f"{family}.{suffix}"
        if event == "pane.agent_status_changed" and self.snapshot is not None:
            pane = _identity(data.get("pane_id"))
            status = _status(data.get("agent_status"))
            if pane:
                for collection in ("panes", "agents"):
                    rows = self.snapshot.get(collection)
                    if not isinstance(rows, list):
                        continue
                    for row in rows:
                        if isinstance(row, dict) and row.get("pane_id") == pane:
                            row["agent_status"] = status
                if self.observed_status.get(pane) != status:
                    self.observed_status[pane] = status
                    self.observed_since[pane] = now
        if event == "pane.agent_status_changed" or event.startswith(STRUCTURAL_PREFIXES):
            self.snapshot_due = now + debounce

    def public_server(self, now: float) -> dict[str, Any]:
        sessions = [_text(value, 64) for value in self.info.get("sessions", [])]
        sessions = [value for value in sessions if value]
        transport = self.info.get("transport")
        transport = transport if transport in ("local", "remote") else "local"
        host = _text(self.info.get("host"), 255) or "local"
        capabilities = self.info.get("capabilities")
        focus_agent = transport == "local"
        if isinstance(capabilities, dict) and isinstance(capabilities.get("focusAgent"), bool):
            focus_agent = capabilities["focusAgent"]
        health = ("live" if self.live else
                  "connecting" if self.error in (
                      "starting", "reconnecting", "awaiting_event_stream", "resolving"
                  ) else "unavailable")
        default_label = host if transport == "remote" else (
            sessions[0] if sessions else "Local Herdr"
        )
        row: dict[str, Any] = {
            "id": self.id,
            "transport": transport,
            "host": host,
            "sessions": sessions,
            "session": _text(self.info.get("session"), 64) or (sessions[0] if sessions else "default"),
            "label": _text(self.info.get("label"), 128) or default_label,
            "capabilities": {"focusAgent": focus_agent},
            "connectionGeneration": self.generation,
            "health": health,
            "connected": self.connected,
            "lastSnapshotObservedMs": None if self.last_snapshot_at is None else
                max(0, int((now - self.last_snapshot_at) * 1000)),
            "clients": _public_clients(self.clients),
        }
        if self.snapshot is not None:
            version = _text(self.snapshot.get("version"), 64)
            if version:
                row["version"] = version
            protocol = self.snapshot.get("protocol")
            if isinstance(protocol, int) and not isinstance(protocol, bool) and 0 <= protocol <= 2 ** 31 - 1:
                row["protocol"] = protocol
            elif isinstance(protocol, str):
                public_protocol = _text(protocol, 64)
                if public_protocol:
                    row["protocol"] = public_protocol
        if self.error:
            row["errorCode"] = _text(self.error, 64) or "unavailable"
        return row

    def live_agents(self, now: float) -> list[dict[str, Any]] | None:
        if not self.inventory_known:
            return None
        assert self.snapshot is not None
        tab_titles = _label_index(self.snapshot.get("tabs"), "tab_id")
        workspace_labels = _label_index(self.snapshot.get("workspaces"), "workspace_id")
        output: list[dict[str, Any]] = []
        for source in self.snapshot.get("agents", []):
            if not isinstance(source, dict):
                continue
            pane = _identity(source.get("pane_id"))
            if not pane:
                continue
            transport = self.info.get("transport")
            transport = transport if transport in ("local", "remote") else "local"
            row: dict[str, Any] = {
                "id": f"{self.id}:{self.generation}:{pane}",
                "serverId": self.id,
                "connectionGeneration": self.generation,
                "transport": transport,
                "host": _text(self.info.get("host"), 255) or "local",
                "session": _text(self.info.get("session"), 64) or "default",
                "paneId": pane,
                "status": _status(source.get("agent_status")),
                "live": True,
            }
            for source_key, public_key in (
                ("workspace_id", "workspaceId"),
                ("tab_id", "tabId"),
                ("terminal_id", "terminalId"),
            ):
                value = _identity(source.get(source_key))
                if value:
                    row[public_key] = value
            for source_key, public_key in (
                ("name", "name"),
                ("agent", "agent"),
                ("label", "label"),
                ("title", "title"),
            ):
                value = _text(source.get(source_key), 128)
                if value:
                    row[public_key] = value
            tab_id = row.get("tabId")
            if isinstance(tab_id, str):
                tab_title = tab_titles.get(tab_id)
                if tab_title:
                    row["tabTitle"] = tab_title
            workspace_id = row.get("workspaceId")
            if isinstance(workspace_id, str):
                workspace_label = workspace_labels.get(workspace_id)
                if workspace_label:
                    row["workspaceLabel"] = workspace_label
            sequence = _sequence(source.get("state_change_seq"))
            if sequence is not None:
                row["stateChangeSeq"] = sequence
            since = self.observed_since.get(pane)
            row["observedAgeMs"] = None if since is None else max(0, int((now - since) * 1000))
            output.append(row)
        return output


def _label_index(rows: object, identity_key: str) -> dict[str, str]:
    """Map collection identity -> sanitized label for agent joins."""
    index: dict[str, str] = {}
    if not isinstance(rows, list):
        return index
    for row in rows:
        if not isinstance(row, dict):
            continue
        identity = _identity(row.get(identity_key))
        if not identity or identity in index:
            continue
        label = _text(row.get("label"), 128)
        if label:
            index[identity] = label
    return index


def _public_window_processes(value: object) -> dict[str, Any]:
    revision = 0
    identities: list[dict[str, int]] = []
    if isinstance(value, dict):
        raw_revision = value.get("revision")
        if isinstance(raw_revision, int) and not isinstance(raw_revision, bool) and raw_revision >= 0:
            revision = raw_revision
        raw_identities = value.get("identities")
        if isinstance(raw_identities, list):
            seen: set[int] = set()
            for row in raw_identities[:256]:
                if not isinstance(row, dict):
                    continue
                pid = row.get("pid")
                start = row.get("startTime")
                if not isinstance(pid, int) or isinstance(pid, bool) or pid <= 0:
                    continue
                if not isinstance(start, int) or isinstance(start, bool) or start < 0:
                    continue
                if pid in seen:
                    continue
                seen.add(pid)
                identities.append({"pid": pid, "startTime": start})
    return {"revision": revision, "identities": identities}


def normalized_snapshot(
    epoch: str,
    revision: int,
    servers: list[ServerState],
    discovery_error: str = "",
    now: float | None = None,
    window_processes: object | None = None,
) -> dict[str, Any]:
    now = time.monotonic() if now is None else now
    server_truncated = len(servers) > MAX_SERVERS
    selected = servers[:MAX_SERVERS]
    public_servers = [server.public_server(now) for server in selected]

    live_rows: list[dict[str, Any]] = []
    live_servers = 0
    unknown_live_inventory = False
    unavailable_servers = 0
    for server in selected:
        if not server.live:
            unavailable_servers += 1
            continue
        live_servers += 1
        agents = server.live_agents(now)
        if agents is None:
            unknown_live_inventory = True
            continue
        live_rows.extend(agents)

    agent_truncated = len(live_rows) > MAX_AGENTS
    agents = live_rows[:MAX_AGENTS]
    counts: dict[str, int | bool] | None = None
    if live_servers > 0 and not unknown_live_inventory:
        counts = {status: 0 for status in STATUSES}
        for agent in agents:
            counts[agent["status"]] += 1
        counts["agents"] = len(agents)
        counts["servers"] = live_servers
        counts["complete"] = not (
            agent_truncated or server_truncated or unavailable_servers or discovery_error
        )

    attention = [{
        "agentId": agent["id"],
        "serverId": agent["serverId"],
        "session": agent["session"],
        "paneId": agent["paneId"],
        "status": agent["status"],
    } for agent in agents if agent["status"] in ("blocked", "done")]

    partial = bool(live_servers) and (
        unknown_live_inventory or unavailable_servers > 0 or bool(discovery_error)
        or agent_truncated or server_truncated
    )
    completeness = "unknown" if live_servers == 0 else "partial" if partial else "complete"

    result: dict[str, Any] = {
        "schemaVersion": 1,
        "providerEpoch": epoch,
        "revision": revision,
        "capabilities": {
            "inventory": True,
            "attention": True,
            "remote": False,
            "actions": True,
            "desktopNotifications": False,
        },
        "servers": public_servers,
        "agents": agents,
        "attention": attention,
        "liveCounts": counts,
        "completeness": {
            "state": completeness,
            "truncated": server_truncated or agent_truncated,
            "serverTruncated": server_truncated,
            "agentTruncated": agent_truncated,
        },
        "windowProcesses": _public_window_processes(window_processes),
    }
    if discovery_error:
        result["sourceErrorCode"] = _text(discovery_error, 64) or "metadata_unavailable"
    return result
