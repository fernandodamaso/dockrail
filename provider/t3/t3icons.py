"""Normalize T3 project icons for read-only sidebar presentation."""
from __future__ import annotations

import base64
from functools import cache
import gzip
import json
from pathlib import Path
import re
import unicodedata

COLORS = ("gray", "red", "orange", "amber", "yellow", "lime", "green", "emerald",
          "teal", "cyan", "sky", "blue", "indigo", "violet", "purple", "fuchsia", "pink", "rose")


@cache
def _lucide_catalog() -> dict[str, str]:
    path = Path(__file__).resolve().parents[2] / "assets/lucide/catalog.json.gz"
    try:
        with gzip.open(path, "rt", encoding="utf-8") as source:
            return json.load(source)
    except (OSError, ValueError, EOFError):
        return {}


def project_icon(project: object) -> dict[str, str] | None:
    if not isinstance(project, dict):
        return None
    title = project.get("title") or project.get("name") or ""
    title = unicodedata.normalize("NFKC", title if isinstance(title, str) else "").strip()
    words = re.findall(r"[^\W_]+", title)
    text = "PR"
    if words:
        first = words[0]
        last = next((c for c in first[1:] if unicodedata.category(c).startswith("N")),
                    words[-1][0] if len(words) > 1 else first[-1])
        text = (first[0] + last).upper()[:2]
    color_index = 0
    for char in title.lower() or "project":
        color_index = (color_index * 31 + ord(char)) % len(COLORS)
    fallback = {"kind": "monogram", "text": text, "color": COLORS[color_index]}
    icon = project.get("projectIcon")
    if not isinstance(icon, dict):
        return fallback
    kind = icon.get("kind")
    if kind == "emoji":
        emoji = icon.get("emoji")
        if isinstance(emoji, str) and 0 < len(emoji) <= 64 and all(
            ord(c) >= 32 and ord(c) != 127 and not 0xD800 <= ord(c) <= 0xDFFF for c in emoji
        ):
            return {"kind": "emoji", "emoji": emoji}
        return fallback
    color = icon.get("color")
    if color not in COLORS:
        return fallback
    if kind == "monogram":
        value = icon.get("text")
        if (isinstance(value, str) and 1 <= len(value) <= 32
            # shortcut: preserve unassigned T3 glyphs while Python's Unicode tables lag; tighten when versions match.
            and (unicodedata.category(value[0])[0] in "LN" or unicodedata.category(value[0]) == "Cn")
            and all(unicodedata.category(c)[0] in "LNM" or unicodedata.category(c) == "Cn"
                    or c in "\u200c\u200d" for c in value)
            and len(value.encode("utf-16-le")) <= 64):
            return {"kind": kind, "text": value, "color": color}
    if kind == "lucide":
        name = icon.get("name")
        if isinstance(name, str) and len(name) <= 80 and re.fullmatch(r"[a-z0-9]+(?:-[a-z0-9]+)*", name):
            svg = _lucide_catalog().get(name)
            if svg:
                return {"kind": kind, "name": name, "color": color,
                        "source": "data:image/svg+xml;base64," + base64.b64encode(svg.encode()).decode()}
    return fallback
