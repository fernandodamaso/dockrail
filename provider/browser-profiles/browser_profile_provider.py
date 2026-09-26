#!/usr/bin/env python3
"""SmartDock browser-profile provider.

Maps Google Chrome windows to the browser profile that owns them.
Modern Chrome (v136+) runs all profiles inside a single browser process, so a
window's PID cannot identify its profile. Instead each tab belongs to a CDP
browser context (one per profile), which this provider resolves through the
browser's DevTools endpoint:

  1. List browser windows from `hyprctl clients -j`.
  2. Match each window title to the active tab of a CDP page target, giving the
     tab's browserContextId.
  3. Resolve each unknown browserContextId to its on-disk profile directory by
     reading "Profile Path" from a chrome://version page inside that context.
  4. Publish window address -> profile key plus profile metadata as a JSON
     snapshot for the dock's FileView consumer.

The browser must be launched with --remote-debugging-port and a separate
--user-data-dir. Without a reachable endpoint the provider stays up and reports
available=false; per-window profiles are simply absent.
"""

import argparse
import base64
import hashlib
import json
import os
import re
import socket
import struct
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request
from urllib.parse import urlsplit

TITLE_SUFFIXES = (" - Google Chrome", " - Chromium", " - Brave", " - Microsoft Edge")
MAX_UNREAD_COUNT = 999999
MAX_TABS_PER_WINDOW = 50
MAX_TAB_TITLE = 120
MAX_FAVICON_BYTES = 256 * 1024
MAX_FAVICON_FETCHES_PER_POLL = 3
FAVICON_MISS_TTL_SEC = 300
FAVICON_FETCH_TIMEOUT_SEC = 0.5
WHATSAPP_TITLE = re.compile(r"^\((\d+)\)\s+WhatsApp$")
INSTAGRAM_TITLE = re.compile(r"^\((\d+)\)\s+Instagram(?: • [^\r\n]+)?$")
# Only the supported inbox title is an unread signal. Other mailbox counts
# and parenthesized numbers in message subjects are not unread evidence.
GMAIL_TITLE = re.compile(
    r"(?:Inbox|Caixa de entrada) \(([0-9]+)\) - [^\r\n]+ - "
    r"(?:Gmail|E-mail de [^\r\n]+)"
)


def valid_target_id(value):
    return re.fullmatch(r"[0-9A-Fa-f]{1,64}", str(value or "")) is not None


def _unread_count(match):
    digits = match.group(1)
    if len(digits) > 6:
        return None
    count = int(digits)
    return count if 1 <= count <= MAX_UNREAD_COUNT else None


def activity_for_target(target, profile_key, window_address):
    target = target if isinstance(target, dict) else {}
    target_id = str(target.get("targetId", ""))
    if not valid_target_id(target_id):
        return None
    try:
        parsed = urlsplit(str(target.get("url", "")))
    except ValueError:
        return None
    if parsed.scheme != "https":
        return None
    host = (parsed.hostname or "").lower()
    title = str(target.get("title", ""))
    service_id = ""
    label = ""
    domain = ""
    match = WHATSAPP_TITLE.fullmatch(title) if host == "web.whatsapp.com" else None
    if match:
        service_id, label, domain = "whatsapp", "WhatsApp", "web.whatsapp.com"
    elif host == "www.instagram.com":
        match = INSTAGRAM_TITLE.fullmatch(title)
        if match:
            service_id, label, domain = "instagram", "Instagram", "www.instagram.com"
    elif host == "mail.google.com" and parsed.fragment == "inbox":
        # A message subject can itself look like an inbox title. Require the
        # inbox listing route too; never publish or persist the inspected URL.
        match = GMAIL_TITLE.fullmatch(title)
        if match:
            service_id, label, domain = "gmail", "Gmail", "mail.google.com"
    if not match:
        return None
    count = _unread_count(match)
    if count is None:
        return None
    return {
        "targetId": target_id,
        "serviceId": service_id,
        "label": label,
        "profileKey": str(profile_key or ""),
        "domain": domain,
        "count": count,
        "windowAddress": str(window_address or "").strip().lower(),
    }


def reduce_activities(rows):
    selected = {}
    for row in rows if isinstance(rows, list) else []:
        if not isinstance(row, dict) or not valid_target_id(row.get("targetId")):
            continue
        try:
            count = int(row.get("count"))
        except (TypeError, ValueError):
            continue
        if not 1 <= count <= MAX_UNREAD_COUNT:
            continue
        profile_key = str(row.get("profileKey", "")).strip()
        address = str(row.get("windowAddress", "")).strip().lower()
        key = (str(row.get("serviceId", "")), profile_key) if profile_key else (
            str(row.get("serviceId", "")), "", address)
        current = selected.get(key)
        if current is None or count > int(current.get("count", 0)) \
                or (count == int(current.get("count", 0))
                    and str(row.get("targetId")) < str(current.get("targetId"))):
            selected[key] = dict(row, count=count)
    return sorted(selected.values(), key=lambda row: (
        -int(row["count"]), str(row.get("label", "")), str(row["targetId"])))


def tab_for_target(target, window_address, active=False, favicon_path=""):
    """Publish a sidebar tab row: title + optional local favicon, never URL."""
    if not isinstance(target, dict) or not valid_target_id(target.get("targetId")):
        return None
    url = str(target.get("url") or "")
    if url.startswith("chrome-extension://") or url.startswith("chrome://version"):
        return None
    title = str(target.get("title") or "").strip() or "Tab"
    if len(title) > MAX_TAB_TITLE:
        title = title[: MAX_TAB_TITLE - 1] + "…"
    row = {
        "targetId": str(target["targetId"]),
        "title": title,
        "active": bool(active),
        "windowAddress": str(window_address or "").strip().lower(),
    }
    path = str(favicon_path or "").strip()
    if path.startswith("/") and os.path.isfile(path):
        row["faviconPath"] = path
    return row


def favicon_cache_dir():
    base = os.environ.get("XDG_CACHE_HOME") or os.path.join(
        os.environ.get("HOME", "/tmp"), ".cache")
    return os.path.join(base, "smartdock", "tab-favicons")


def list_page_favicon_urls(port):
    """Map target id -> remote favicon URL from Chrome's /json list."""
    try:
        with urllib.request.urlopen(
                "http://127.0.0.1:%d/json" % int(port), timeout=2) as reply:
            targets = json.loads(reply.read().decode())
    except (OSError, ValueError, urllib.error.URLError, TypeError):
        return {}
    if not isinstance(targets, list):
        return {}
    result = {}
    for target in targets:
        if not isinstance(target, dict):
            continue
        target_id = str(target.get("id") or "")
        favicon = target.get("faviconUrl")
        if not target_id or not isinstance(favicon, str) or not favicon.strip():
            continue
        result[target_id] = favicon.strip()
    return result


def _favicon_extension(url, content_type):
    ctype = str(content_type or "").split(";", 1)[0].strip().lower()
    by_type = {
        "image/png": ".png",
        "image/x-icon": ".ico",
        "image/vnd.microsoft.icon": ".ico",
        "image/jpeg": ".jpg",
        "image/jpg": ".jpg",
        "image/webp": ".webp",
        "image/gif": ".gif",
        "image/svg+xml": ".svg",
    }
    if ctype in by_type:
        return by_type[ctype]
    path = urlsplit(url).path.lower()
    for ext in (".png", ".ico", ".jpg", ".jpeg", ".webp", ".gif", ".svg"):
        if path.endswith(ext):
            return ".jpg" if ext == ".jpeg" else ext
    return ".ico"


def cache_favicon(url, cache_dir=None, fetch_budget=None):
    """Return a local favicon path. Never returns remote URLs.

    Existing cache hits are free. New downloads consume one unit of fetch_budget
    (a one-element list) and are capped so a slow icon host cannot stall the
    provider poll that also publishes activities/tabs titles.
    """
    source = str(url or "").strip()
    if not source:
        return ""
    directory = cache_dir or favicon_cache_dir()
    digest = hashlib.sha256(source.encode("utf-8")).hexdigest()[:32]
    miss_path = os.path.join(directory, digest + ".miss")
    try:
        os.makedirs(directory, exist_ok=True)
        for name in os.listdir(directory):
            if name.startswith(digest + ".") and not name.endswith(".miss") \
                    and os.path.isfile(os.path.join(directory, name)):
                return os.path.join(directory, name)
        if os.path.isfile(miss_path):
            if time.time() - os.path.getmtime(miss_path) < FAVICON_MISS_TTL_SEC:
                return ""
    except OSError:
        return ""

    if isinstance(fetch_budget, list):
        if not fetch_budget or fetch_budget[0] <= 0:
            return ""
        fetch_budget[0] -= 1

    body = b""
    content_type = ""
    if source.startswith("data:image/"):
        try:
            header, _, payload = source.partition(",")
            if ";base64" in header.lower():
                body = base64.b64decode(payload, validate=False)
            else:
                body = urllib.parse.unquote_to_bytes(payload)
            content_type = header[5:].split(";", 1)[0]
        except (ValueError, TypeError):
            try:
                open(miss_path, "wb").close()
            except OSError:
                pass
            return ""
    elif source.startswith("http://") or source.startswith("https://"):
        try:
            request = urllib.request.Request(
                source, headers={"User-Agent": "SmartDock-browser-profile-provider"})
            with urllib.request.urlopen(
                    request, timeout=FAVICON_FETCH_TIMEOUT_SEC) as reply:
                content_type = reply.headers.get("Content-Type", "")
                body = reply.read(MAX_FAVICON_BYTES + 1)
        except (OSError, ValueError, urllib.error.URLError):
            try:
                open(miss_path, "wb").close()
            except OSError:
                pass
            return ""
    else:
        return ""
    if not body or len(body) > MAX_FAVICON_BYTES:
        try:
            open(miss_path, "wb").close()
        except OSError:
            pass
        return ""
    ext = _favicon_extension(source, content_type)
    path = os.path.join(directory, digest + ext)
    fd, temp_path = tempfile.mkstemp(dir=directory, prefix=".favicon-")
    try:
        with os.fdopen(fd, "wb") as handle:
            handle.write(body)
        os.replace(temp_path, path)
        try:
            os.unlink(miss_path)
        except OSError:
            pass
        return path
    except OSError:
        try:
            os.unlink(temp_path)
        except OSError:
            pass
        return ""


def list_tab_strip_entries(client):
    """Chrome 150+ tab targets with real tab-strip index (and tabGroupId).

    Page-target order from Target.getTargets is not strip order. Tab targets
    carry embedderData.tabStripIndex / tabGroupId; use those when present.
    """
    try:
        result = client.call("Target.getTargets", {"filter": [
            {"type": "tab", "exclude": False},
            {"exclude": True},
        ]})
    except (CdpError, TypeError, ValueError, OSError):
        return []
    entries = []
    for info in result.get("targetInfos", []) if isinstance(result, dict) else []:
        if not isinstance(info, dict) or info.get("type") != "tab":
            continue
        embedder = info.get("embedderData")
        if not isinstance(embedder, dict):
            continue
        index = embedder.get("tabStripIndex")
        if not isinstance(index, int) or index < 0:
            continue
        target_id = str(info.get("targetId") or "")
        if not valid_target_id(target_id):
            continue
        try:
            window_id = client.call(
                "Browser.getWindowForTarget",
                {"targetId": target_id}).get("windowId")
        except (CdpError, OSError, ValueError, TypeError):
            window_id = None
        entries.append({
            "targetId": target_id,
            "title": str(info.get("title") or ""),
            "url": str(info.get("url") or ""),
            "windowId": window_id,
            "tabStripIndex": index,
            "tabActive": embedder.get("tabActive") is True,
            "tabPinned": embedder.get("tabPinned") is True,
            "tabGroupId": str(embedder.get("tabGroupId") or ""),
        })
    entries.sort(key=lambda row: (
        row.get("windowId") is None,
        row.get("windowId") if isinstance(row.get("windowId"), int) else 0,
        row["tabStripIndex"],
        row["title"],
        row["targetId"],
    ))
    return entries


def build_tabs(matches, pages, os_windows=None, favicon_urls=None, strip_tabs=None):
    """Group page targets by matched Hyprland window address (cap per window).

    Prefer Chrome 150+ tab-strip order (tabStripIndex) when strip_tabs is
    provided; otherwise keep Target.getTargets page order. Never promote the
    active tab or sort by title.
    """
    target_windows = matches.get("targetWindows", {}) if isinstance(matches, dict) else {}
    window_ids = matches.get("windowIds", {}) if isinstance(matches, dict) else {}
    assignments = _context_map(matches)
    favicons = favicon_urls if isinstance(favicon_urls, dict) else {}
    fetch_budget = [MAX_FAVICON_FETCHES_PER_POLL]
    os_titles = {}
    for window in os_windows or []:
        if not isinstance(window, dict):
            continue
        address = str(window.get("address", "")).strip().lower()
        if address:
            os_titles[address] = strip_browser_suffix(str(window.get("title", "")))

    page_by_id = {}
    page_by_window_url = {}
    fallback_order = []
    for page in pages if isinstance(pages, list) else []:
        target_id = str(page.get("targetId", ""))
        cdp_window = target_windows.get(target_id)
        if cdp_window is None:
            continue
        address = next((key for key, value in window_ids.items()
                        if value == cdp_window), "")
        if not address or address not in assignments:
            continue
        address = str(address).strip().lower()
        active_title = os_titles.get(address, "")
        page_title = str(page.get("title") or "")
        active = bool(active_title) and (
            page_title == active_title
            or strip_browser_suffix(page_title) == active_title)
        page_by_id[target_id] = {
            "page": page,
            "address": address,
            "active": active,
            "windowId": cdp_window,
        }
        url = str(page.get("url") or "").strip()
        if url:
            page_by_window_url[(cdp_window, url)] = target_id
        fallback_order.append(target_id)

    by_address = {}
    ordered_ids = []
    strip = strip_tabs if isinstance(strip_tabs, list) else []
    if strip:
        for tab in strip:
            window_id = tab.get("windowId")
            url = str(tab.get("url") or "").strip()
            page_id = page_by_window_url.get((window_id, url)) if url else None
            if not page_id or page_id not in page_by_id:
                continue
            info = page_by_id[page_id]
            # Authoritative strip selection when Chrome reports it.
            if tab.get("tabActive") is True:
                info = dict(info, active=True)
            elif tab.get("tabActive") is False and info["active"]:
                # Title match can lag; prefer strip metadata when present.
                info = dict(info, active=False)
            ordered_ids.append((page_id, info, tab))
    else:
        for page_id in fallback_order:
            ordered_ids.append((page_id, page_by_id[page_id], None))

    seen = set()
    for page_id, info, tab in ordered_ids:
        if page_id in seen:
            continue
        seen.add(page_id)
        favicon_path = cache_favicon(favicons.get(page_id, ""),
                                     fetch_budget=fetch_budget)
        row = tab_for_target(info["page"], info["address"],
                             active=info["active"], favicon_path=favicon_path)
        if not row:
            continue
        if tab and tab.get("tabGroupId"):
            row["tabGroupId"] = str(tab.get("tabGroupId"))
        if tab and tab.get("tabPinned") is True:
            row["pinned"] = True
        by_address.setdefault(info["address"], []).append(row)

    return {address: rows[:MAX_TABS_PER_WINDOW]
            for address, rows in by_address.items()}


class WindowMatches(dict):
    """Address map with additive structured mappings for provider consumers."""

    def __init__(self, contexts=None, window_ids=None, target_windows=None):
        contexts = contexts or {}
        super().__init__(contexts)
        self["contexts"] = contexts
        self["windowIds"] = window_ids or {}
        self["targetWindows"] = target_windows or {}

    def __eq__(self, other):
        if isinstance(other, dict) and not any(
                key in other for key in ("contexts", "windowIds", "targetWindows")):
            return self["contexts"] == other
        return dict.__eq__(self, other)


class CdpError(Exception):
    pass


class WebSocket:
    """Minimal RFC 6455 client sufficient for Chrome DevTools endpoints."""

    def __init__(self, url, timeout=5.0):
        match = re.match(r"ws://([^:/]+):(\d+)(/.*)?$", url)
        if not match:
            raise CdpError("unsupported websocket URL: " + url)
        host, port, resource = match.group(1), int(match.group(2)), match.group(3) or "/"
        self.sock = socket.create_connection((host, port), timeout=timeout)
        self.sock.settimeout(timeout)
        key = base64.b64encode(os.urandom(16)).decode()
        request = (
            "GET %s HTTP/1.1\r\nHost: %s:%d\r\nUpgrade: websocket\r\n"
            "Connection: Upgrade\r\nSec-WebSocket-Key: %s\r\n"
            "Sec-WebSocket-Version: 13\r\n\r\n" % (resource, host, port, key)
        )
        self.sock.sendall(request.encode())
        response = b""
        while b"\r\n\r\n" not in response:
            chunk = self.sock.recv(4096)
            if not chunk:
                raise CdpError("websocket handshake closed")
            response += chunk
        if b" 101" not in response.split(b"\r\n", 1)[0]:
            raise CdpError("websocket handshake failed: " + response.split(b"\r\n", 1)[0].decode("utf-8", "replace"))
        self._buffer = response.split(b"\r\n\r\n", 1)[1]

    def _read_exact(self, count):
        while len(self._buffer) < count:
            chunk = self.sock.recv(65536)
            if not chunk:
                raise CdpError("websocket closed")
            self._buffer += chunk
        data, self._buffer = self._buffer[:count], self._buffer[count:]
        return data

    def _read_frame(self):
        while True:
            header = self._read_exact(2)
            fin = header[0] & 0x80
            opcode = header[0] & 0x0F
            masked = header[1] & 0x80
            length = header[1] & 0x7F
            if length == 126:
                length = struct.unpack(">H", self._read_exact(2))[0]
            elif length == 127:
                length = struct.unpack(">Q", self._read_exact(8))[0]
            mask = self._read_exact(4) if masked else None
            payload = self._read_exact(length)
            if mask:
                payload = bytes(b ^ mask[i % 4] for i, b in enumerate(payload))
            if opcode == 0x9:  # ping
                self._send_frame(0xA, payload)
                continue
            if opcode == 0x8:
                raise CdpError("websocket close frame")
            if opcode in (0x1, 0x2, 0x0):
                return fin, opcode, payload

    def _send_frame(self, opcode, payload):
        mask = os.urandom(4)
        length = len(payload)
        header = bytes([0x80 | opcode])
        if length < 126:
            header += bytes([0x80 | length])
        elif length < 65536:
            header += bytes([0x80 | 126]) + struct.pack(">H", length)
        else:
            header += bytes([0x80 | 127]) + struct.pack(">Q", length)
        masked = bytes(b ^ mask[i % 4] for i, b in enumerate(payload))
        self.sock.sendall(header + mask + masked)

    def send_text(self, text):
        self._send_frame(0x1, text.encode())

    def recv_text(self):
        parts = []
        while True:
            fin, opcode, payload = self._read_frame()
            parts.append(payload)
            if fin:
                return b"".join(parts).decode("utf-8", "replace")

    def close(self):
        try:
            self._send_frame(0x8, b"")
            self.sock.close()
        except OSError:
            pass


class CdpClient:
    def __init__(self, port):
        self.port = port
        self.ws = None
        self._next_id = 0

    def _ensure_connected(self):
        if self.ws is not None:
            return
        with urllib.request.urlopen(
            "http://127.0.0.1:%d/json/version" % self.port, timeout=3
        ) as reply:
            version = json.loads(reply.read().decode())
        browser_url = version.get("webSocketDebuggerUrl")
        if not browser_url:
            raise CdpError("endpoint has no browser websocket")
        self.ws = WebSocket(browser_url)

    def call(self, method, params=None, session_id=None):
        self._ensure_connected()
        self._next_id += 1
        message = {"id": self._next_id, "method": method}
        if params is not None:
            message["params"] = params
        if session_id is not None:
            message["sessionId"] = session_id
        self.ws.send_text(json.dumps(message))
        while True:
            reply = json.loads(self.ws.recv_text())
            if reply.get("id") == self._next_id:
                break
        if "error" in reply:
            raise CdpError(reply["error"].get("message", method + " failed"))
        return reply.get("result", {})

    def close(self):
        if self.ws is not None:
            self.ws.close()
            self.ws = None


def strip_browser_suffix(title):
    for suffix in TITLE_SUFFIXES:
        if title.endswith(suffix):
            return title[: -len(suffix)]
    return title


def list_windows(classes):
    try:
        output = subprocess.run(
            ["hyprctl", "clients", "-j"], capture_output=True, timeout=5, check=True
        ).stdout
    except (OSError, subprocess.SubprocessError):
        return []
    try:
        clients = json.loads(output)
    except ValueError:
        return []
    wanted = set(classes)
    windows = []
    for client in clients:
        if client.get("class") in wanted and client.get("mapped", True):
            windows.append(
                {
                    "address": str(client.get("address", "")),
                    "title": str(client.get("title", "")),
                    "size": list(client.get("size", [])),
                }
            )
    return windows


def match_window_contexts(client, windows, pages):
    """Match OS windows one-to-one with CDP browser windows."""
    assignments = {}
    assignment_window_ids = {}
    cdp_windows = {}
    for page in pages:
        try:
            window_id = client.call(
                "Browser.getWindowForTarget", {"targetId": page["targetId"]}
            )["windowId"]
        except (CdpError, KeyError):
            continue
        group = cdp_windows.setdefault(window_id, {"pages": [], "size": None})
        group["pages"].append(page)
    for window_id, group in cdp_windows.items():
        try:
            bounds = client.call("Browser.getWindowBounds", {"windowId": window_id})["bounds"]
            group["size"] = [bounds.get("width"), bounds.get("height")]
        except (CdpError, KeyError):
            pass
        contexts = {page.get("browserContextId") for page in group["pages"]}
        contexts.discard(None)
        group["context"] = contexts.pop() if len(contexts) == 1 else None
        group["titles"] = {page.get("title", "") for page in group["pages"]}

    os_by_title = {}
    cdp_by_title = {}
    for window in windows:
        os_by_title.setdefault(strip_browser_suffix(window["title"]), []).append(window)
    for window_id, group in cdp_windows.items():
        if not group["context"]:
            continue
        for title in group["titles"]:
            cdp_by_title.setdefault(title, []).append(window_id)

    reserved = set()
    # A title unique on both sides identifies the active CDP window even when
    # another window contains a same-sized background tab with another title.
    unique_matches = []
    for title, matching_windows in os_by_title.items():
        matching_cdp = cdp_by_title.get(title, [])
        if len(matching_windows) == 1 and len(matching_cdp) == 1:
            unique_matches.append((matching_windows[0], matching_cdp[0]))
    unique_owners = {}
    for window, window_id in unique_matches:
        unique_owners.setdefault(window_id, []).append(window)
    for window_id, matching_windows in unique_owners.items():
        if len(matching_windows) == 1:
            assignments[matching_windows[0]["address"]] = cdp_windows[window_id]["context"]
            assignment_window_ids[matching_windows[0]["address"]] = window_id
            reserved.add(window_id)

    # Geometry resolves duplicate titles only when it produces a unique pair
    # in both directions. Anything still ambiguous keeps the plain icon.
    remaining = [window for window in windows if window["address"] not in assignments]
    candidates = {}
    for window in remaining:
        title = strip_browser_suffix(window["title"])
        candidates[window["address"]] = {
            window_id for window_id in cdp_by_title.get(title, [])
            if window_id not in reserved and cdp_windows[window_id]["size"] == window["size"]
        }
    owners = {}
    for address, window_ids in candidates.items():
        for window_id in window_ids:
            owners.setdefault(window_id, []).append(address)
    for address, window_ids in candidates.items():
        if len(window_ids) != 1:
            continue
        window_id = next(iter(window_ids))
        if len(owners[window_id]) == 1:
            assignments[address] = cdp_windows[window_id]["context"]
            assignment_window_ids[address] = window_id
    window_ids = {}
    target_windows = {}
    for address, window_id in assignment_window_ids.items():
        group = cdp_windows.get(window_id)
        if not group:
            continue
        window_ids[address] = window_id
        for page in group["pages"]:
            target_windows[str(page.get("targetId", ""))] = window_id
    return WindowMatches(assignments, window_ids, target_windows)


def read_profile_path(client, context_id, pages_in_context):
    """Resolve a browser context to its on-disk profile directory."""
    try:
        target = client.call(
            "Target.createTarget",
            {"url": "chrome://version", "browserContextId": context_id, "hidden": True},
        )
        target_id = target["targetId"]
        try:
            return _profile_path_from_target(client, target_id)
        finally:
            try:
                client.call("Target.closeTarget", {"targetId": target_id})
            except CdpError:
                pass
    except CdpError:
        pass

    # Some contexts refuse createTarget. An already-open chrome://version page
    # is safe to inspect, but existing user pages must never be navigated.
    for page in pages_in_context:
        if not page.get("url", "").startswith("chrome://version"):
            continue
        try:
            result = _profile_path_from_target(client, page["targetId"])
        except CdpError:
            continue
        if result:
            return result
    return ""


def _profile_path_from_target(client, target_id):
    session_id = client.call(
        "Target.attachToTarget", {"targetId": target_id, "flatten": True}
    )["sessionId"]
    try:
        deadline = time.monotonic() + 5.0
        while time.monotonic() < deadline:
            time.sleep(0.4)
            reply = client.call(
                "Runtime.evaluate",
                {"expression": "document.body ? document.body.innerText : ''"},
                session_id=session_id,
            )
            text = str(reply.get("result", {}).get("value", ""))
            match = re.search(r"Profile Path\s+(\S[^\n]*)", text)
            if match:
                return match.group(1).strip()
        return ""
    finally:
        try:
            client.call("Target.detachFromTarget", {"sessionId": session_id})
        except CdpError:
            pass


def load_profile_names(user_data_dir):
    state_path = os.path.join(user_data_dir, "Local State")
    try:
        with open(state_path, encoding="utf-8") as handle:
            state = json.load(handle)
    except (OSError, ValueError):
        return {}
    cache = state.get("profile", {}).get("info_cache", {})
    return {key: str(value.get("name", "")) for key, value in cache.items()}


def _context_map(matches):
    return matches.get("contexts", matches) if isinstance(matches, dict) else {}


def build_snapshot(matches, context_profiles, pages=None, port=9222, classes=None,
                   os_windows=None, strip_tabs=None):
    # Keep the old three-argument call shape used by the installed-provider
    # check while allowing the richer target/window mapping for live activity.
    if isinstance(pages, (int, float)):
        port, pages = int(pages), []
    assignments = _context_map(matches)
    profiles = {}
    names_cache = {}
    for context_id in set(assignments.values()):
        profile_path = context_profiles.get(context_id, "")
        if not profile_path:
            continue
        profile_dir = os.path.basename(profile_path.rstrip("/"))
        user_data_dir = os.path.dirname(profile_path.rstrip("/"))
        if user_data_dir not in names_cache:
            names_cache[user_data_dir] = load_profile_names(user_data_dir)
        avatar = os.path.join(profile_path, "Google Profile Picture.png")
        profiles[profile_dir] = {
            "name": names_cache[user_data_dir].get(profile_dir, ""),
            "path": profile_path,
            "avatarPath": avatar if os.path.isfile(avatar) else "",
        }
    windows = {}
    for address, context_id in assignments.items():
        profile_path = context_profiles.get(context_id, "")
        if profile_path:
            windows[address] = os.path.basename(profile_path.rstrip("/"))
    activities = {}
    target_windows = matches.get("targetWindows", {}) if isinstance(matches, dict) else {}
    window_ids = matches.get("windowIds", {}) if isinstance(matches, dict) else {}
    all_rows = []
    for page in pages if isinstance(pages, list) else []:
        target_id = str(page.get("targetId", ""))
        cdp_window = target_windows.get(target_id)
        if cdp_window is None:
            continue
        address = next((key for key, value in window_ids.items()
                        if value == cdp_window), "")
        if not address or address not in assignments:
            continue
        profile_path = context_profiles.get(assignments[address], "")
        profile_key = os.path.basename(profile_path.rstrip("/")) if profile_path else windows.get(address, "")
        row = activity_for_target(page, profile_key, address)
        if row:
            all_rows.append(row)
    for row in reduce_activities(all_rows):
        activities.setdefault(row["windowAddress"], []).append(row)
    tabs = build_tabs(matches, pages, os_windows, list_page_favicon_urls(port),
                      strip_tabs)
    return {
        "schemaVersion": 1,
        "available": True,
        "port": port,
        "windows": windows,
        "profiles": profiles,
        "classes": [str(value).strip() for value in (classes or []) if str(value).strip()],
        "activities": activities,
        "tabs": tabs,
    }


def snapshot_fingerprint(snapshot):
    value = snapshot if isinstance(snapshot, dict) else {}
    return json.dumps({key: value.get(key) for key in (
        "available", "classes", "port", "windows", "profiles", "activities", "tabs")},
        sort_keys=True, separators=(",", ":"))


def activate_target(port, target_id, client_factory=CdpClient):
    try:
        normalized_port = int(port)
    except (TypeError, ValueError):
        return False
    if not valid_target_id(target_id) or not 1 <= normalized_port <= 65535:
        return False
    try:
        client = client_factory(normalized_port)
        client.call("Target.activateTarget", {"targetId": str(target_id)})
        return True
    except (CdpError, OSError, ValueError, TypeError):
        return False
    finally:
        if "client" in locals():
            client.close()


def write_snapshot(state_file, payload, revision):
    payload["revision"] = revision
    directory = os.path.dirname(state_file)
    os.makedirs(directory, exist_ok=True)
    fd, temp_path = tempfile.mkstemp(dir=directory, prefix=".browser-profiles-")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            json.dump(payload, handle)
        os.replace(temp_path, state_file)
    except OSError:
        try:
            os.unlink(temp_path)
        except OSError:
            pass


def snapshot_windows(snapshot):
    return snapshot.get("windows", {})


def run(args):
    classes = [name.strip() for name in args.classes.split(",") if name.strip()]
    client = CdpClient(args.port)
    context_profiles = {}
    context_retry_after = {}
    revision = 0
    last_fingerprint = None
    while True:
        try:
            targets = client.call("Target.getTargets").get("targetInfos", [])
            pages = [t for t in targets if t.get("type") == "page"]
            windows = list_windows(classes)
            assignments = match_window_contexts(client, windows, pages)
            by_context = {}
            for page in pages:
                by_context.setdefault(page.get("browserContextId"), []).append(page)
            context_assignments = _context_map(assignments)
            for context_id in set(context_assignments.values()):
                if context_id in context_profiles:
                    continue
                if time.monotonic() < context_retry_after.get(context_id, 0):
                    continue
                profile_path = read_profile_path(client, context_id, by_context.get(context_id, []))
                if profile_path:
                    context_profiles[context_id] = profile_path
                else:
                    context_retry_after[context_id] = time.monotonic() + 30
            snapshot = build_snapshot(assignments, context_profiles, pages,
                                      args.port, classes, windows,
                                      list_tab_strip_entries(client))
            available = True
        except (CdpError, OSError, ValueError) as error:
            client.close()
            context_profiles.clear()
            context_retry_after.clear()
            snapshot = {
                "schemaVersion": 1,
                "available": False,
                "error": str(error),
                "classes": classes,
                "port": args.port,
                "windows": {},
                "profiles": {},
                "activities": {},
                "tabs": {},
            }
            available = False
        fingerprint = snapshot_fingerprint(snapshot)
        if fingerprint != last_fingerprint:
            revision += 1
            write_snapshot(args.state_file, snapshot, revision)
            last_fingerprint = fingerprint
        time.sleep(args.interval)


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--state-file")
    parser.add_argument("--port", type=int, default=9222,
                        help="browser DevTools port (default: 9222)")
    parser.add_argument("--interval", type=float, default=1.5,
                        help="poll interval in seconds (default: 1.5)")
    parser.add_argument("--classes", default="google-chrome",
                        help="comma-separated Hyprland window classes to track")
    parser.add_argument("--activate-target")
    args = parser.parse_args()
    if args.activate_target is not None:
        return 0 if activate_target(args.port, args.activate_target) else 1
    if not args.state_file:
        parser.error("--state-file is required unless --activate-target is used")
    try:
        run(args)
    except KeyboardInterrupt:
        pass
    return 0


if __name__ == "__main__":
    sys.exit(main())
