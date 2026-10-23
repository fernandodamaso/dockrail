# SPDX-License-Identifier: Apache-2.0
"""Connection-file path resolution for the local T3 Code provider.

The token lives in a 0600 file under the Dockrail data root, written only by
``dockrail t3 pair`` and only read by the provider. It never appears in
``dock.json``, QML, or on a command line.
"""
from __future__ import annotations

import os
from pathlib import Path
from typing import Mapping


def connection_path(env: Mapping[str, str] | None = None) -> Path:
    """Return the T3 connection-file path for the given environment mapping."""
    if env is None:
        env = os.environ
    data_home = env.get("XDG_DATA_HOME", "")
    if data_home:
        base = Path(data_home).expanduser()
    else:
        home = env.get("HOME", "") or str(Path.home())
        base = Path(home).expanduser() / ".local" / "share"
    return base / "dockrail" / "t3" / "connection.json"
