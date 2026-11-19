# T3 Code Threads Implementation Plan

> **For agentic workers:** Execute one slice at a time, in order. Each slice is
> one branch and one PR (stacked per `docs/DELIVERY.md`). Do not start a slice
> until the previous slice's checks pass. Every step names the exact files, the
> change, the style to match and the check to run. When a step says
> **STOP AND REPORT**, do not improvise: report what you found and wait.

**Goal:** Show T3 Code threads in Dockrail exactly the way Herdr agents are
shown today: status mark and count on the T3 Code dock icon, the hover preview
list, the context-menu records, and in the sidebar, threads indented under the
T3 Code window row. Clicking a thread raises the T3 Code window.

**Architecture (decided, do not change):**

```text
T3 server (local, 127.0.0.1:3773, /ws Effect-RPC "orchestration.subscribeShell")
  -> provider/t3/bin/dockrail-t3-provider     NEW  Python stdlib, NDJSON, speaks the
                                                   *Herdr provider contract* (schema v1)
  -> DockHerdrService instance #2             REUSED, parameterised by providerPath
  -> DockAgentSourceMux                       NEW  merges Herdr + T3 behind the
                                                   exact DockHerdrService API
  -> DockHerdrWindowAgents (unchanged bridge) -> Dock / preview / menu / sidebar
```

- The T3 provider emits the **same snapshot schema the Herdr provider emits**,
  including `servers[].clients[]` with PID ancestry. On this machine the T3
  server process (`/usr/lib/t3code/t3code … apps/server/dist/bin.mjs`) is a
  direct child of the T3 Code window process, so the existing PID-ancestry
  association in `DockHerdrModel.associateWindows` attaches every thread to the
  T3 Code window with no new association code. (Verified 2026-10-23: server pid
  33203 → parent 33040 = `com.t3tools.T3Code` window pid.)
- Herdr and T3 merge **after** each provider has produced its own epoch and
  revision, inside one mux object that exposes the same API as
  `DockHerdrService`. The bridge, `DockHerdrAgentActions`, `Dock.qml`, the
  preview, the context menu and the sidebar projection keep consuming one
  "service". Only user-visible strings and per-source gating change in those files.
- Clicking a T3 row: the T3 provider advertises `capabilities.focusAgent: true`
  and answers every valid `focus-agent` request with `ok: true` (no-op). The
  existing two-phase activation path in `DockHerdrAgentActions` then raises the
  T3 window through `windowActions.activateToplevel`. T3 has no thread deep link.
- Authentication: one-time pairing through T3's own CLI
  (`t3 auth pairing create --scope orchestration:read`), exchanged for a
  read-only bearer session (30 days). The token lives in a 0600 file in the
  Dockrail data root, written only by the `dockrail t3` CLI and only read by
  the provider. Never in `dock.json`, never in QML, never on a command line.

**Out of scope (say so in PR descriptions):** remote T3 environments, Relay /
T3 Connect, opening a specific thread, `dockrail setup --feature t3`, `dockrail
doctor` integration, thread actions (settle/snooze/approve). These are
follow-ups.

**Tech stack:** Python 3 standard library only (no pip packages), Qt/QML,
`.pragma library` JavaScript models, existing node/python/qmltestrunner tests.

**Base:** `main` at `994de31`. Branches:
`feat/t3-threads-1-provider` → `feat/t3-threads-2-mux` → `feat/t3-threads-3-ui`.
Slice 0 is not a branch.

---

## Global rules for the executor

1. Never modify anything under `provider/herdr/`. `tests/check_herdr_data_access.sh`
   checks its file list, license hash and pinned revision.
2. Herdr behaviour must stay identical. All existing Herdr tests are the
   regression gate and must pass unmodified, except where a step below
   explicitly tells you to edit a specific assertion.
3. Python: standard library only, `from __future__ import annotations`, type
   hints, 4-space indentation, match the style of
   `provider/herdr/bin/smartdock-herdr-provider`. Scripts run as
   `python3 -B`. No `print` of tokens, ever; redact tokens from every error
   string (`str(exc).replace(token, "…")`).
4. QML: two-space indentation, match surrounding code. JS models use
   `.pragma library` and are tested with node through `tests/host_harness.mjs`
   (see `tests/test_herdr_sidebar_model.mjs` for the pattern).
5. `qmltestrunner` must always be run with `QT_QPA_PLATFORM=offscreen` in the
   same command (a local hook blocks it otherwise).
6. Never start a second dock. Never run `./scripts/run` beside the production
   plugin for visual checks; visual checks are slice 3's runtime gate and are
   done by the user or in a KVM guest per `docs/DEV_SESSIONS.md`.
7. Never commit secrets or captured tokens. Fixtures must be sanitised
   (see slice 0).
8. Never run code from the downloaded plugin clones under `/tmp/t3plugins`.
   They are reference reading only. All tools used here are written in this
   repository.
9. Many existing tests are source-string (grep) contract checks. The **only**
   existing test edits allowed are the ones listed in "Allowed test edits"
   below. If any other existing test fails, **STOP AND REPORT**.

### Allowed test edits (exhaustive)

Verified against `tests/` on 2026-10-23. These are the literal assertions and
shared fixture that this plan deliberately changes. New T3 test files may be
added as specified below; do not weaken existing Herdr assertions.

| Test file:line | Today pins | Change it to | Slice |
|---|---|---|---|
| `tests/check_window_previews.sh:62` | `text: "Click a row to focus its pane."` in DockWindowPreview.qml | require `property string herdrFocusHint: "Click a row to focus its pane."` **and** `text: root.herdrFocusHint` | 3 |
| `tests/check_herdr_dock_indicators.sh:17` | `!root.dockHerdrIndicators` in Dock.qml | `!(root.dockHerdrIndicators \|\| root.dockT3Indicators)` | 3 |
| `tests/check_herdr_data_access.sh:45` | `"registeredIds": ["herdr.agents"]` in the schema | `"registeredIds": ["herdr.agents", "t3.threads"]` (match the exact spacing you write in the schema) | 3 |
| `tests/test_sidebar_widget_config.py:26` and `:79` | `registeredIds == ['herdr.agents']` | `['herdr.agents', 't3.threads']` | 3 |
| `tests/host_harness.mjs:48-53` | runtime fixture registry contains only `herdr.agents` | add an inert `t3.threads` descriptor with the same no-op lease shape; retain the Herdr descriptor unchanged | 3 |
| `tests/check_herdr_dock_indicators.sh:19` | `summaryForToplevels(item.toplevels \|\| [])` in Dock.qml | `summaryForToplevels((item.toplevels \|\| []).filter(root.sourceIndicatorsEnabled))` | 3 |

The fixture change must accompany the schema assertions: `DockControl` derives
runtime `registeredIds` from `host.sidebarWidgetRegistry`, overriding bundled
metadata. Editing `settings-schema.json` alone cannot update that runtime test.
Add new protected-ID coverage in `tests/test_t3_widget_packages.py`, reusing
the existing package fixtures without changing `tests/test_widget_packages.py`.

Traps that are **not** test edits but will break tests if ignored:
`tests/check_context_menu_contract.sh:44` pins the `agentRecord(...)`
signature (do not change it, §3.3); `tests/test_browser_activity_preview.py:32-34`
copies DockWindowPreview.qml lines 74-82 (placement rule, §3.3);
`tests/SidebarSplitSourceHarness.js:29-51` evaluates DockHost's registry
block verbatim (T3 identifiers inside `if (root.t3Service)`, §3.2);
`tests/test_user_facing_docs.py:20-24` forbids `FDM-` and the word
"qualification" in public docs (§3.6).

These must keep passing **unchanged** (the plan keeps their literals for
Herdr): `test_context_menu_herdr_records.mjs:56` (`'Herdr · …'`),
`test_herdr_sidebar_model.mjs` / `test_herdr_fallback_visibility.mjs` /
`tst_herdr_remote_fallback.qml` (`'Herdr unavailable'`, `'No active agents'`),
`tst_herdr_host_bridge.qml:172` and `test_herdr_lifecycle.py:49`
(`host.herdr-window-agents`, `root.herdrService.acquire(…)` in the bridge,
which this plan does not touch), `test_herdr_lifecycle.py:59` (uses
`assertIn`, still true), `check_herdr_data_access.sh:8` (Herdr provider path).

### Full validation gate (run at the end of every slice)

Run this whole block as one Bash command. The subshell stops on the first
failure and returns its nonzero status; a failed command is a failed slice.
Do not replace failures with successful `echo` calls or advance to the next
slice after a failure.

```bash
(
set -euo pipefail
cd /home/admin/Projects/dockrail
bash -n install.sh uninstall.sh scripts/dockrail scripts/run tests/check_window_actions.sh
python3 -m py_compile scripts/dockrail_paths.py scripts/dockrail_migrate.py
python3 -m py_compile scripts/dockrail_t3.py provider/t3/*.py provider/t3/bin/dockrail-t3-provider   # from slice 1 on
omarchy plugin validate .
for f in tests/check_*.sh; do bash "$f"; done
for f in tests/test_*.mjs; do node "$f"; done
python3 -B -m unittest discover -s tests -p 'test_*.py'
python3 -B -m unittest discover -s provider/herdr/tests -p 'test_*.py'
python3 -B -m unittest discover -s provider/t3/tests -p 'test_*.py'      # from slice 1 on
QML_XHR_ALLOW_FILE_READ=1 QT_QPA_PLATFORM=offscreen /usr/lib/qt6/bin/qmltestrunner -input tests -import components -import tests/qml-imports
/usr/lib/qt6/bin/qmllint -I "$OMARCHY_PATH/shell" Overlay.qml DockHost.qml components/Dock.qml components/DockItem.qml components/DockContextMenu.qml components/DockControlItem.qml components/DockWindowActions.qml shell.qml
git diff --check
)
```

---

## Slice 0: capture the real protocol (needs user approval, no code)

Why: the WebSocket frame shapes below come from t3-loupe's reading of T3's
source and its fake server. Nobody has captured real frames. The fake server
and fixtures in slice 1 must be built from real traffic.

**This slice creates one read-only T3 session labelled "Dockrail probe" on the
user's T3. Ask the user before running it.**

Slice 0 is split: the HTTP part (0a) runs before slice 1; the WebSocket part
(0b) runs inside slice 1 right after `t3ws.py`/`t3rpc.py` exist (step 1.5b),
using our own capture tool, never t3-loupe's code.

Steps for 0a (Opus or the user runs these, not an unattended executor). Keep
secrets in 0600 files under a fresh `mktemp -d` directory, never in argv:

1. Issue a pairing credential, scope restricted to read:
   ```bash
   P=$(mktemp -d); chmod 700 "$P"
   t3 auth pairing create --scope orchestration:read --ttl 5m --label "Dockrail probe" --json > "$P/pair.json"
   python3 -I -c 'import json,sys;print(json.load(open(sys.argv[1]))["credential"],end="")' "$P/pair.json" > "$P/cred"
   ```
   Record the JSON *field names* of `pair.json` (expected: `credential`).
2. Exchange it (form POST); the credential is read from the file by curl:
   ```bash
   curl -s -X POST http://127.0.0.1:3773/oauth/token \
     -H 'x-t3-orchestration-protocol: 2' \
     --data-urlencode grant_type=urn:ietf:params:oauth:grant-type:token-exchange \
     --data-urlencode subject_token@"$P/cred" \
     --data-urlencode subject_token_type=urn:t3:params:oauth:token-type:environment-bootstrap \
     --data-urlencode requested_token_type=urn:ietf:params:oauth:token-type:access_token \
     --data-urlencode scope=orchestration:read \
     --data-urlencode client_label="Dockrail probe" \
     --data-urlencode client_device_type=desktop --data-urlencode client_os=linux
   ```
   Save the response to `"$P/token.json"` (`> "$P/token.json"`), extract
   `access_token` into `"$P/token"` the same way as step 1, and record the
   response field names (`access_token`, `token_type`, `expires_in`, `scope`).
3. `GET /api/auth/session` and `GET /api/orchestration/shell`, passing the
   header from a file so the token stays out of argv:
   `printf 'Authorization: Bearer %s\n' "$(cat "$P/token")" > "$P/auth.hdr"` then
   `curl -s -H @"$P/auth.hdr" -H 'x-t3-orchestration-protocol: 2' http://127.0.0.1:3773/api/orchestration/shell > "$P/shell.json"`.
   (The `printf` builtin does not appear in the process list.) Also save
   `GET /.well-known/t3/environment`.
4. `POST /api/auth/websocket-ticket` (no body, same header file) and record
   the response field names (`ticket`, `expiresAt`). Keep `"$P"` for step 0b.
5. Sanitise: replace every token/ticket/credential, real thread titles, paths,
   branch names and PR URLs with placeholders. Keep every key name, every enum
   value and the sequence numbers. Save as:
   - `provider/t3/tests/fixtures/shell-snapshot.json` (HTTP shell body)
   - `provider/t3/tests/fixtures/descriptor.json`
6. Do **not** revoke yet; 0b reuses the token. After 0b: revoke with
   `t3 auth session list` then `t3 auth session revoke <id>`, and `rm -rf "$P"`.
7. Write down any difference from the spec in slice 1 §1.3 to §1.5. If a
   difference changes a field the plan relies on (`status`, `activityRunStatus`,
   `pendingRuntimeRequest`, `lastVisitedAt`, `latestRunCompletedAt`, `lineage`,
   `projectId`, the `kind` values of shell items, the RPC `_tag` values),
   update this plan before slice 1 starts.

---

## Slice 1: T3 provider and pairing CLI (no UI)

Branch `feat/t3-threads-1-provider` from `main`.

### 1.1 Files to create

```text
provider/t3/
  README.md                 short: purpose, contract (= Herdr schema v1), files
  bin/dockrail-t3-provider  executable entry (#!/usr/bin/env python3), chmod 0755
  t3paths.py                connection-file path resolution (shared with the CLI)
  t3store.py                read connection file (provider side only)
  t3http.py                 small HTTP client (urllib) + descriptor + listener check
  t3ws.py                   minimal RFC 6455 WebSocket client
  t3rpc.py                  Effect-RPC framing over t3ws
  t3procfs.py               /proc helpers: listener owner, identities, ancestry
  t3model.py                ShellStore + classification + Herdr-schema snapshot
  tools/capture_ws.py       slice-0b capture tool (never shipped as runtime code)
  tests/
    __init__.py
    fake_t3.py              in-process fake T3 server (HTTP + WS) driven by fixtures
    fixtures/…              from slice 0
    test_t3ws.py test_t3rpc.py test_t3model.py test_t3procfs.py
    test_t3store.py test_provider_protocol.py test_provider_lifecycle.py
scripts/dockrail_t3.py      `dockrail t3 …` CLI (pairing writer), SELF-CONTAINED
```

**Decision: the CLI does not import anything from `provider/t3/`.** A
`--cli-only` install copies only an explicit list of `scripts/*.py` files
(`install.sh` `install_client_bundle`, around line 91) and has no `provider/`
directory. So `scripts/dockrail_t3.py` contains its own small copies of:
endpoint check, descriptor GET, form POST/JSON GET (urllib, no redirects),
listener-owner check, and the atomic writer (~120 lines total). It may import
`dockrail_paths` (already shipped in the client bundle). Add a parity test
`tests/test_t3_cli_parity.py` that loads both modules and asserts the
endpoint check accepts/rejects the same 10 URLs, and the listener check gives
the same result on the same fake `/proc` tree.

Module import style: `bin/dockrail-t3-provider` does
`sys.path.insert(0, str(Path(__file__).resolve().parent.parent))` then
`import t3model` etc. Tests load the bin with `SourceFileLoader` exactly like
`provider/herdr/tests/test_provider.py:14-25`.

### 1.2 Connection file (`t3paths.py`, `t3store.py`, CLI writer)

- Path: `${XDG_DATA_HOME:-$HOME/.local/share}/dockrail/t3/connection.json`.
  `t3paths.connection_path(env=os.environ) -> Path`. If `XDG_DATA_HOME` is set
  but empty, treat as unset (same rule as `scripts/dockrail_paths.py:_base`).
  `scripts/dockrail_t3.py` must compute the same path with
  `dockrail_paths.resolve_paths().canonical_data_root / "t3" / "connection.json"`.
  Add a test (`tests/test_t3_paths.py`) that both resolve to the same path for
  three env variants (default, custom XDG_DATA_HOME, empty XDG_DATA_HOME).
- Shape (exactly):
  ```json
  {"version":1,"environmentId":"…","label":"omarchy","url":"http://127.0.0.1:3773",
   "token":"…","expiresAt":1767225600,"pairedAt":1764633600}
  ```
  `expiresAt`/`pairedAt` are epoch seconds (int).
- Directory created with `os.makedirs(dir, mode=0o700, exist_ok=True)`, then
  `os.chmod(dir, 0o700)` (makedirs does not fix an existing directory), then
  `lstat` must show a real directory owned by `os.getuid()`, else refuse. The
  file is written atomically by the CLI:
  temp file `.connection-<16 hex>` opened `O_CREAT|O_EXCL|O_WRONLY|O_NOFOLLOW`
  mode 0600, write, `fsync`, `os.replace`, fsync the directory.
- Reader (`t3store.load(path) -> dict | None`, raises `StoreError(code)`):
  open with `O_RDONLY|O_NOFOLLOW`; `fstat` must show owner == `os.getuid()` and
  `mode & 0o077 == 0`, size ≤ 64 KiB; directory must not be a symlink and must
  have `mode & 0o077 == 0`. Violations → `StoreError("store_untrusted")`.
  Missing file → `None`. Bad JSON / missing keys / `version != 1` →
  `StoreError("store_invalid")`. `url` must pass `t3http.check_endpoint`.

### 1.3 HTTP (`t3http.py`)

- `PROTOCOL_VERSION = 2`. Every request sends `accept: application/json`,
  `accept-encoding: identity`, `x-t3-orchestration-protocol: 2`, and
  `authorization: Bearer <token>` when a token is given.
- Never follow redirects (custom `HTTPRedirectHandler` returning `None`, see
  `omat3_t3.py` pattern). Timeout 5 s default. Response cap 16 MiB (read in
  chunks, abort beyond the cap). Status mapping: 401/403 →
  `Failure("authentication_required")`, 404/426 → `Failure("unsupported")`,
  connection refused → `Failure("offline")`, other non-200 → `Failure("failed")`.
  Body must be a JSON object.
- `check_endpoint(url)`: scheme `http`, host exactly `127.0.0.1` or `[::1]`, no
  userinfo/query/fragment, path `""` or `/`, length ≤ 512. (Remote/HTTPS is out
  of scope; reject it with `Failure("unsupported_endpoint")`.)
- `get_descriptor(base)`: GET `/.well-known/t3/environment` (no auth, 64 KiB
  cap). Require `orchestrationProtocolVersion == 2` and string
  `environmentId`, else `Failure("unsupported")`. Return the dict.
- **Before any request that carries a token, form or ticket** call
  `t3procfs.assert_own_listener(port)` (see 1.6). This includes the WS upgrade.
  To narrow the gap between that check and the send, do it **after** the TCP
  connection is open and right before the first byte is written: build the
  request on a connected socket (`http.client.HTTPConnection.connect()`
  first, then the check, then `request()`; for the WS, after
  `create_connection` and before the handshake bytes). A failed check closes
  the socket without sending.

### 1.4 WebSocket client (`t3ws.py`): the hardest module, test it thoroughly

Class `WebSocket` with:
- `connect(host: str, port: int, path_and_query: str, timeout: float = 10.0)`
  - plain TCP `socket.create_connection((host, port), timeout)`; no TLS.
  - Handshake request:
    ```text
    GET <path_and_query> HTTP/1.1\r\n
    Host: <host>:<port>\r\n
    Upgrade: websocket\r\n
    Connection: Upgrade\r\n
    Sec-WebSocket-Key: <base64 of 16 random bytes>\r\n
    Sec-WebSocket-Version: 13\r\n\r\n
    ```
  - Read until `\r\n\r\n` (cap 16 KiB). Status must be `101`. Verify
    `Sec-WebSocket-Accept == base64(sha1(key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"))`.
    Status 401 → `Failure("authentication_required")`; 426/404 →
    `Failure("unsupported")`; anything else → `Failure("failed")`.
  - Any bytes already read after the header terminator are kept in the receive buffer.
- `send_text(text: str)`: one FIN frame, opcode 0x1, **masked** (client frames
  must be masked: 4 random mask bytes, payload XOR mask). Lengths: <126 →
  7-bit; ≤65535 → 126 + 2-byte big-endian; else 127 + 8-byte big-endian.
- `recv(timeout: float) -> str | None`: returns one complete text message, or
  `None` on timeout with no complete message.
  - Parse frames from the buffer: FIN bit, opcode, mask bit (server frames are
    not masked; if masked, unmask anyway), extended length.
  - Opcodes: 0x0 continuation (append to the fragmented message), 0x1 text,
    0x2 binary (→ `Failure("unsupported")`), 0x8 close (reply with close frame
    echoing the 2-byte code if present, then raise `Closed(code)`), 0x9 ping
    (reply pong 0xA with the same payload, keep reading), 0xA pong (ignore).
  - Message cap 16 MiB across fragments → `Failure("too_large")`.
  - Decode as UTF-8 (`errors="strict"`; on error `Failure("failed")`).
- `close(code=1000)`: send masked close frame, shut down the socket, ignore errors.
- `Closed.code == 1008` must be mapped by callers to `authentication_required`.

Tests (`test_t3ws.py`) against `fake_t3.py`'s WS side: handshake accept check
(wrong accept → failure), 0/125/126/65535/65536/1 MiB payloads both
directions, fragmented text (3 frames), ping → pong reply, close handshake,
binary frame rejection, oversize rejection, partial reads (server writes one
byte at a time), 401 handshake.

### 1.5 Effect-RPC (`t3rpc.py`)

Wire format (one JSON object per text message):

| Direction | Message |
|---|---|
| client → server | `{"_tag":"Request","id":"<n>","tag":"<method>","payload":{…},"headers":[]}`, ids are decimal strings from a per-socket counter starting at `"1"` |
| client → server | `{"_tag":"Ack","requestId":"<n>"}` after **every** `Chunk`, sent **before** processing the chunk's values |
| client → server | `{"_tag":"Ping"}` every 20 s; no `Pong` within 10 s → close, `Failure("offline")` |
| client → server | `{"_tag":"Interrupt","requestId":"<n>","interruptors":[]}` on shutdown |
| server → client | `{"_tag":"Pong"}` |
| server → client | `{"_tag":"Chunk","requestId":"<n>","values":[…]}` |
| server → client | `{"_tag":"Exit","requestId":"<n>","exit":{…}}`; stream ended. If the JSON text of `exit` contains `"Forbidden"` or `"scope"` → `authentication_required`, else `offline` |
| server → client | `{"_tag":"ClientProtocolError",…}` or `{"_tag":"Defect",…}` → close, `Failure("failed")` |

Class `RpcSession(ws)`: `stream(tag, payload) -> request_id`;
`poll(timeout) -> list[tuple[request_id, value]]` (handles Ack, Ping/Pong
timing, Exit → raises `StreamEnded(request_id, code)`); `close()` (sends
Interrupt for open streams, then ws close). Single-threaded; the provider's
connection thread calls `poll(0.5)` in a loop.

### 1.5b Slice 0b: capture real WebSocket frames (needs the user, as in 0a)

Write `provider/t3/tools/capture_ws.py` (our code, stdlib, imports `t3ws`,
`t3rpc`, `t3http`): arguments `--token-file PATH --seconds 60 --out PATH`.
It POSTs `/api/auth/websocket-ticket`, connects
`/ws?orchestrationProtocol=2&wsTicket=<ticket>&clientSurface=dockrail`,
streams `orchestration.subscribeShell` with `{"requestCompletionMarker": true}`,
and writes every **raw server message** (one per line) to `--out` (which must
be inside the 0700 `$P` directory; the tool refuses any other location), then sends
a Ping, records the Pong, and closes. Run it with the 0a token while the user
starts a thread, lets it finish, and opens it in T3. Then run it a second time
with `afterSequence` set to the last sequence seen (add `--after-sequence N`)
to capture the resume behaviour.

Sanitise as in 0a step 5 and save as
`provider/t3/tests/fixtures/ws-session.jsonl` and
`provider/t3/tests/fixtures/ws-resume.jsonl`. Then revoke the session and
delete the temp dir (0a step 6).

If the real frames differ from §1.5 or §1.7 (frame `_tag`s, item `kind`s,
thread fields), **STOP AND REPORT** the differences before writing
`t3model.py`. Build `tests/fake_t3.py` so it replays these fixture files.

### 1.6 /proc helpers (`t3procfs.py`)

- `listener_inodes(port) -> set[str]`: read `/proc/net/tcp` and
  `/proc/net/tcp6`, skip header line; keep rows where `cols[3] == "0A"`
  (LISTEN), local port hex (`cols[1].split(":")[-1]`) equals `f"{port:04X}"`,
  and local address is loopback/any (IPv4 `0100007F` or `00000000`; IPv6 32
  zeros, `00000000000000000000000001000000`, or `0000000000000000FFFF0000` +
  IPv4). Return `{"socket:[" + cols[9] + "]"}`; also return the UIDs (`cols[7]`).
- `assert_own_listener(port)`: no listener → `Failure("offline")`; any listener
  UID ≠ `os.getuid()` → `Failure("listener_untrusted")`; `/proc/net` unreadable →
  `Failure("listener_untrusted")`.
- `listener_pid(port) -> int | None`: walk `/proc/<pid>/fd` only for processes
  owned by the current user (`os.stat(f"/proc/{pid}").st_uid`), `os.readlink` each fd,
  return the pid whose fd matches one of the inodes. Ignore `PermissionError`/
  `FileNotFoundError` per process.
- `identity(pid) -> {"pid": int, "startTime": int} | None`: startTime is field
  22 of `/proc/<pid>/stat` (parse after the last `)`; the field after `)` is
  field 3). Only for same-uid processes.
- `ancestors(pid, limit=8) -> list[identity]`: follow PPID (field 4) upward,
  stop at pid ≤ 1 or limit. The list **excludes `pid` itself** and starts
  with its parent, matching the Herdr client shape
  (`provider/herdr/attachments.py:305-321`).
- `peer_listener_uid(local_port, remote_port) -> int | None`: for an
  already-connected client socket (`sock.getsockname()[1]`), find the
  LISTEN row on `remote_port` and return its UID. Used for the post-connect
  check in §1.3.
- `resolve_window_identities(pids) -> list[identity]`: `identity()` for each
  unique positive int pid (max 256), skipping failures. This must produce the
  same shape as the Herdr provider's `windowProcesses.identities`.

Tests use a fake `/proc` root: every function takes an optional
`proc_root: Path = Path("/proc")` parameter.

### 1.7 Shell model (`t3model.py`)

`ShellStore`: `projects: dict[id, dict]`, `threads: dict[id, dict]`,
`sequence: int = -1`, `synchronized: bool`.
`apply(item: dict)`:
- `kind == "synchronized"` → `synchronized = True`.
- `kind == "snapshot"`: `snap = item["snapshot"]`; if `snap.get("schemaVersion") != 2`
  raise `Failure("unsupported")`. If **`item`**, not `snap`, has a list
  `resolvedRepositoryIdentityRoots` → upsert `snap["projects"]` only, preserving
  all threads, unrelated projects and the applied sequence. The marker is on
  the outer stream item; enrichment snapshots intentionally have empty thread
  arrays. Else replace `projects` and `threads` from
  `snap["projects"]` / `snap["threads"]` (keep only valid threads) and set
  `sequence = snap["snapshotSequence"]`.
- Every other kind: if `item.get("sequence")` is an int and `<= self.sequence`
  → ignore; if int, set `self.sequence`. Then:
  `thread.updated` → upsert `item["thread"]` if valid else delete its id;
  `thread.removed` → delete `item["threadId"]`; `project.updated` → upsert
  `item["project"]`; `project.removed` → delete `item["projectId"]`. Unknown
  kinds are ignored.
- Valid thread: dict, string `id`, falsy `archivedAt`, falsy `deletedAt`.
- `load_http_snapshot(body)` = `apply({"kind":"snapshot","snapshot":body})`.

`classify(thread, now_ms) -> "blocked" | "working" | "done" | "idle"` (Herdr's
status enum). Evaluate in this order; first match wins:

| # | Condition | Status | Why |
|---|---|---|---|
| 1 | `pendingRuntimeRequest` is a dict with a truthy `kind`, `blocking` is not `False`, and `status` is a live-run status (row 4's set) | `blocked` | approval / user input needed; a non-blocking request never pauses the agent, and a request whose run ended can never be answered |
| 2 | `hasActionableProposedPlan` is true and `status` is a live-run status | `blocked` | plan waiting for you while the run is parked; once the run ends it is just an unread result (row 7/8) |
| 3 | `activityRunStatus` in {preparing, starting, running, waiting} | `working` | |
| 4 | `status` in {queued, preparing, starting, running, waiting} | `working` | `waiting` without a pending request is the agent waiting on itself |
| 5 | `pendingBackgroundTasks` is a non-empty list | `working` | |
| 6 | `status == "failed"` and `unread(thread)` | `blocked` | a failure you have not looked at needs you |
| 7 | `status == "completed"` and `unread(thread)` and not subagent | `done` | |
| 8 | otherwise | `idle` | includes usage-limited, stopped, read completions |

`unread(t)`: `latestRunCompletedAt` present and (`lastVisitedAt` missing or
`parse(lastVisitedAt) < parse(latestRunCompletedAt)`). Timestamps are ISO
8601 strings; parse with `datetime.fromisoformat(s.replace("Z", "+00:00"))`;
unparsable → treat as missing. Subagent: `lineage.relationshipToParent == "subagent"`.

`visible_threads(store, now_ms) -> list[thread]`:
- drop if `snoozedUntil` parses to a time in the future;
- drop if `settledAt` is set and status is not blocked/working;
- subagent threads: keep only if blocked or working;
- root threads: always kept — idle threads are the gray "quiet but live"
  rows (not settled, not snoozed, not done, nothing running or waiting).
  Settling is the only explicit dismiss: a settled thread never shows
  unless it is genuinely blocked or working again;
- sort: status rank (blocked 0, done 1, idle 2, working 3 — attention
  first, working last), then `updatedAt`
  descending, then id; cap at 64 (`completeness.agentTruncated = True` when cut).

`build_snapshot(state) -> dict`: exactly the Herdr schema v1 shape
(`provider/herdr/model.py:343 normalized_snapshot`):

```python
{"schemaVersion": 1, "providerEpoch": epoch, "revision": revision,
 "capabilities": {"inventory": True, "attention": True, "remote": False,
                  "actions": True, "desktopNotifications": False},
 "servers": [server] or [],
 "agents": agents, "attention": attention, "liveCounts": live_counts,
 "completeness": {"state": ..., "truncated": agent_truncated,
                  "serverTruncated": False, "agentTruncated": bool},
 "windowProcesses": {"revision": wp_revision, "identities": identities}}
```

Server object: always exactly one. When not paired (or the store is invalid)
emit a placeholder with `"id": "t3:unpaired"`, `health: "unavailable"`,
`connected: false`, `clients: []`, `connectionGeneration: 1` and
`errorCode` = `pairing_required` / `store_untrusted` / `store_invalid`, so
every error state belongs to the T3 source (the mux keeps top-level fields
from Herdr; see §2.2). Do **not** put T3 error codes in the top-level
`sourceErrorCode`; that key is only for the 1 MiB fallback, as in Herdr.

```python
{"id": "t3:" + environmentId, "source": "t3", "product": "T3 Code",
 "transport": "local", "host": "local", "sessions": [], "session": "",
 "label": "T3 Code",
 "capabilities": {"focusAgent": True},
 "connectionGeneration": generation,          # int >= 1; bump on every new socket or HTTP fallback start
 "health": "live" | "connecting" | "unavailable",
 "connected": health == "live",
 "lastSnapshotObservedMs": ms | None,
 "clients": [{"pid", "startTime", "ancestors": [...]}] or [],   # T3 server process, see 1.8
 "errorCode": code}                            # only when unavailable
```

Do **not** include a `version` key: `DockHerdrModel.serverNeedsFocusUpgrade`
(DockHerdrModel.js:354) would compare T3's `0.1.0` against Herdr's 0.9.1
minimum and show a bogus "Update Herdr" message. Missing `version` disables
that check.

**Live inventory rule:** emit agent objects only when server health is `live`
and the current stream has reached `synchronized` (or an HTTP fallback snapshot
has loaded successfully). In every connecting/unavailable state, emit
`agents: []`, `attention: []`, `liveCounts: None` and completeness `unknown`,
with all truncation flags false. Keep cached threads and sequence internally
for same-connection-file resume only; they are never displayable live inventory
during a gap. Existing sidebar consumers trust this provider boundary and can
otherwise render cached rows as actionable even when the server is not live.

Agent object per visible thread, subject to the live inventory rule:

```python
{"id": f"{server_id}:{generation}:{thread_id}", "serverId": server_id,
 "connectionGeneration": generation, "transport": "local", "host": "local",
 "session": "", "paneId": thread_id, "status": status, "live": True,
 "workspaceId": project_id or "", "workspaceLabel": project_title or "",
 "tabId": project_id or "", "tabTitle": project_title or "",
 "title": (thread title or "Untitled thread") prefixed "Subagent: " for subagents,
 "agent": agent_kind,            # see below
 "stateChangeSeq": counter bumped only when this thread's *status* changes,
 "observedAgeMs": now - time of that status change}
```

**Emission churn rule (important):** `thread.updated` arrives many times per
second while an agent works. The provider must compute a fingerprint of the
built snapshot **excluding** `revision`, every agent's `observedAgeMs`, and
`servers[].lastSnapshotObservedMs`, and emit only when the fingerprint
changes (plus the 60 s safety emit). Keep a per-thread
`{status, changedAtMs, seq}` map in the provider to produce
`stateChangeSeq`/`observedAgeMs`. Test: 50 `thread.updated` items that only
change `updatedAt` on a working thread produce zero extra emits.

- Project title: `projects[projectId].get("title") or .get("name")`.
- `agent_kind`: lowercase `providerInstanceId` (fallback
  `modelSelection.provider`); if it contains `codex` → `"codex"`, `claude` →
  `"claude"`, `cursor` → `"cursor"`, `opencode` → `"opencode"`, else the raw
  string. (`DockHerdrModel.displayAgentKind` then renders "Codex"/"Claude".)
- Clean every display string: strip control characters, collapse whitespace,
  cap 200 chars.
- `attention`: `[{agentId, serverId, session: "", paneId, status}]` for
  status in (blocked, done), only while live; otherwise `[]`.
- `liveCounts`: `{blocked, done, working, idle, unknown: 0, agents, servers, complete}`
  when health is `live`, else `None`.
- `completeness.state`: `"unknown"` when not live; otherwise `"partial"`
  when truncated and `"complete"` when not truncated. `completeness.truncated` equals
  `agentTruncated` (as in the Herdr provider); `serverTruncated` is always
  `False`.
- Frame cap 1 MiB, same fallback as the Herdr provider
  (provider:1013-1028): empty `agents`/`attention`, `liveCounts=None`,
  `sourceErrorCode="normalized_output_too_large"`.

### 1.8 Provider process (`bin/dockrail-t3-provider`)

Structure mirrors `provider/herdr/bin/smartdock-herdr-provider`: a stdin
reader thread, a connection worker thread, and a main loop draining a
`queue.Queue` of events, emitting a snapshot when dirty (debounce 0.25 s) plus
a safety re-emit every 60 s. `providerEpoch = uuid.uuid4().hex`; `revision`
+1 per emit. One JSON line per emit, `flush()` after each. SIGTERM/SIGINT → stop.
Stdin EOF → stop.

**Stdin commands** (each line ≤ 4096 bytes; same contract as Herdr, see
`provider/herdr/attachments.py:714` and `:764`):
- `refresh`: reload the connection file and reconnect if it changed.
- `quit`: stop.
- `{"kind":"window-processes","revision":int>=0,"pids":[int>0,…]}` (exact key
  set, ≤256 pids): store revision, set
  `identities = t3procfs.resolve_window_identities(pids)`, mark dirty. The next
  snapshot must carry `windowProcesses.revision == revision`. Before any
  command arrives, `windowProcesses` is `{"revision": 0, "identities": []}`,
  the same initial value as the Herdr provider (`window_process_revision = 0`,
  smartdock-herdr-provider:349). This keeps the two sources' revisions equal
  at start-up so the mux does not have to wait.
- `{"kind":"focus-agent","requestId":str,"providerEpoch":str,"serverId":str,"connectionGeneration":int,"agentId":str,"paneId":str,"terminalId":str}`.
  This is the exact key set `DockHerdrService.focusAgent` writes
  (DockHerdrService.qml:76-85); `terminalId` is always present and is `""`
  for T3. Reject other key sets with `invalid_request`. Reply `{"kind":"action-result","requestId":…,"ok":true,"error":""}` when the
  epoch matches, the server id matches, server health is live, generation
  matches, and `agentId` is in the last emitted agents with that `paneId`.
  Otherwise `ok:false` with `error` from: `invalid_request`, `identity_mismatch`,
  `server_unavailable`, `agent_gone`. Copy the exact `emit_action_result`
  shape from provider:727-740. (Raising the window is done by Dockrail.)
- Anything else → ignore (do not crash).

**Connection worker state machine:**

**Connection-file monitoring runs independently of connection health.** The
existing main loop reloads the file through `t3store.load` on a monotonic 1 s
deadline in every state, including live WS, HTTP fallback and retry waits.
`refresh` runs that same check immediately. Compare validated contents without
logging credentials; unchanged contents must not reconnect.

On deletion, invalid/untrusted contents, expiry or a changed valid record,
invalidate the current connection attempt, close its stream/socket, wake retry
waits, clear cached projects/threads/sequence and status-transition memory, and
mark the public snapshot dirty. Each worker event carries an in-memory
`connectionRevision`; increment it on invalidation and discard events from
older revisions, so a late snapshot cannot restore an unpaired inventory.
Deletion publishes `t3:unpaired` / `pairing_required`; invalid/untrusted records
publish their store error; expiry publishes `pairing_expired`. A changed valid
record starts at step 1 with a fresh store and authenticates with its own token;
never resume a sequence from the previous record. Local invalidation must be
published within 2 s, independently of network timeouts. `window-processes`
commands must still receive their revision echoes while unpaired or offline.

1. Load the connection file. `None` → the `t3:unpaired` placeholder server
   with `errorCode:"pairing_required"`. `StoreError` → same placeholder with
   that error code. The main-loop monitor handles subsequent file changes.
2. `expiresAt <= now` → server `health:"unavailable"`, `errorCode:"pairing_expired"`;
   wait for the main-loop monitor to find a valid replacement.
3. Not listening (`listener_inodes(port)` empty) → server
   `unavailable`/`server_not_running`, `clients: []`; re-check every 2 s (a
   cheap /proc read, no network).
4. `assert_own_listener` → else `unavailable`/`listener_untrusted`, retry 30 s.
5. `get_descriptor`; `environmentId` must equal the stored one, else
   `unavailable`/`environment_changed` (user must re-pair), retry 30 s.
6. Fill `clients`: `pid = listener_pid(port)`; `clients = [{**identity(pid), "ancestors": ancestors(pid)}]`.
7. GET `/api/auth/session` with the token: `authenticated` must be true, else
   `unavailable`/`authentication_required`, retry 5 min (connection-file change
   short-circuits the wait).
8. Health `connecting`. POST `/api/auth/websocket-ticket` → `ticket`. Connect
   WS `/ws?orchestrationProtocol=2&wsTicket=<urlencoded>&clientSurface=dockrail`.
   `generation += 1`. Stream `orchestration.subscribeShell` with payload
   `{"requestCompletionMarker": True}` plus `"afterSequence": store.sequence`
   when `store.sequence >= 0`. Reset `store.synchronized = False` before each
   new subscription, even when retaining the same record's resume cache.
9. Apply every value through `ShellStore.apply`; on `synchronized` set health
   `live`; mark dirty on every change.
10. On socket loss: health `connecting`, backoff `min(30, 2**failures)` s with
    ±20 % jitter, reset failures to 0 once live again. Go to step 3 (the
    listener may have gone because T3 quit). Immediately withdraw live
    inventory under §1.7; do not wait for reconnect or the safety emit.
11. **HTTP fallback**: if the WS handshake fails with `unsupported`, poll
    `GET /api/orchestration/shell` every 5 s (load as snapshot; health `live`
    while polls succeed). On a failed poll withdraw live inventory under
    §1.7. Retry the WS every 5 min.
12. Session recheck every 6 h (step 7).

### 1.9 Pairing CLI (`scripts/dockrail_t3.py`, wired in `scripts/dockrail`)

In `scripts/dockrail`, extend the existing special-case block (lines 39-48)
with exactly one new case, matching the `dev`/`widget` style:

```bash
  t3)     shift; exec python3 -B "$(dirname -- "$adapter")/dockrail_t3.py" "$@" ;;
```

This bypasses the argparse/schema coupling enforced by
`tests/test_cli_docs.py:101-108` on purpose, like `dev` and `widget`.

`dockrail_t3.py` (argparse, `prog="dockrail t3"`), subcommands:

- `pair [--url http://127.0.0.1:3773] [--json]`
  1. `check_endpoint(url)`; `get_descriptor(url)` (fail clearly if T3 is not running).
  2. `assert_own_listener(port)`.
  3. Run `["t3", "auth", "pairing", "create", "--scope", "orchestration:read",
     "--ttl", "5m", "--label", "Dockrail", "--json"]` with `subprocess.run`,
     `capture_output=True`, `text=True`, `timeout=30`. Resolve `t3` with
     `shutil.which("t3")`; if missing, error "T3 Code CLI (t3) not found; install T3 Code".
     Parse stdout JSON, take `credential` (field name confirmed in slice 0).
     **Never include the subprocess's stdout or stderr in any error message
     or log**: stdout contains the credential. On failure, report only the
     exit code.
  4. Verify the issuing server is the same environment: read
     `${T3CODE_HOME:-~/.t3}/userdata/environment-id` and compare with the
     descriptor's `environmentId`; mismatch → error, do not exchange.
  5. POST `/oauth/token` (form body exactly as in slice 0 step 2, with
     `client_label=Dockrail`). Require `token_type == "Bearer"`, `scope`
     split on whitespace == `{"orchestration:read"}`, string `access_token`.
  6. Verify with GET `/api/auth/session` (authenticated true).
  7. Write the connection file atomically (§1.2). Print
     "Paired with T3 Code (<label>), session expires <date>." or the JSON
     `{"ok":true,"environmentId":…,"expiresAt":…}`. Never print the token.
- `status [--json]`: reads the file; prints paired/not paired, environment id,
  label, expiry, days left, and whether the server answers the descriptor.
  Exit 0 when paired and not expired, 1 otherwise.
- `unpair [--json]`: deletes the connection file; prints a hint that the
  session can be revoked in T3 → Settings → Connections or with
  `t3 auth session list` / `t3 auth session revoke`. The running provider
  detects deletion and withdraws the inventory within 2 s (§1.8); no dock
  restart or extra `refresh` is needed. Local unpairing does not revoke the
  server-side session.

Errors: exit code 2 with a one-line message on stderr; with `--json`,
`{"ok":false,"error":"<code>","message":"…"}` on stdout.

Add a section "`dockrail t3`" to `docs/CLI_REFERENCE.md` (pair/status/unpair,
flags, exit codes) and to `README.md` near the Herdr section.

### 1.10 Install, CI, lifecycle test

- `install.sh` (around lines 183-191): add the same three operations for
  `provider/t3` right after the Herdr ones (`rm -rf`, `cp -R`, `chmod 0755
  "$app_dir/provider/t3/bin/dockrail-t3-provider"`). Do not touch the Herdr lines.
- `install.sh` `install_client_bundle` (line ~91): add
  `install -m 0644 "$source_dir/scripts/dockrail_t3.py" "$destination/scripts/dockrail_t3.py"`
  next to the `smartdock_widget.py` line (`dockrail_paths.py` is already listed).
  Check `uninstall.sh` removes the client dir as a whole; if it removes files
  one by one, add `dockrail_t3.py` there too.
- `.github/workflows/ci.yml`: after the "Herdr provider tests" step (line ~118),
  add a step "T3 provider tests":
  `python3 -B -m unittest discover -s provider/t3/tests -p 'test_*.py' -v`.
- `tests/test_t3_lifecycle.py` (source-string contract checks in the style of
  `tests/test_herdr_lifecycle.py`): install.sh contains the t3 copy and chmod;
  CI contains the t3 test step; `scripts/dockrail` contains the `t3)` case;
  the provider file is executable.

### 1.11 Tests that must exist and pass

- `test_t3model.py`: every row of the classify table (one test per row,
  including order conflicts, e.g. pending request + running → blocked);
  unread logic; visibility filters (snoozed, settled, subagent, idle hidden
  unless pinned, cap 64 → `agentTruncated`); sequence dedupe; snapshot replace vs
  metadata-only snapshot. `test_enrichment_preserves_threads_and_sequence`
  applies an outer `resolvedRepositoryIdentityRoots` marker with empty thread
  arrays and an advanced snapshot sequence: existing threads, unrelated
  projects and the prior sequence survive, while the named project updates;
  cover initial-stream and resumed-stream fixtures. `build_snapshot` matches the Herdr schema key set
  (assert exact top-level keys, server keys, agent keys); no `version` key;
  1 MiB fallback; built from `fixtures/shell-snapshot.json`.
  `test_non_live_snapshot_withholds_cached_inventory` covers connecting and
  unavailable health with cached working/blocked/done threads: agents and
  attention are empty, counts are null and completeness is unknown. A new
  subscription must not restore inventory before its synchronized marker.
- `test_t3procfs.py`: fake /proc tree: listener found/missing/other uid,
  IPv4/IPv6 rows, identity parsing with a `comm` that contains spaces and `)`,
  ancestry stops at limit and at pid 1.
- `test_t3store.py`: 0600 ok; 0644 rejected; symlink rejected; oversize
  rejected; invalid JSON; bad url.
- `test_t3ws.py`, `test_t3rpc.py`: see 1.4/1.5. RPC: Ack is sent before the
  next frame is read; Ping/Pong timeout; Exit with Forbidden →
  authentication_required.
- `test_provider_protocol.py`: run the provider as a subprocess against
  `fake_t3.py` (listening on port 0) with a temp connection file whose `url`
  points at the fake. Add one hidden test-only flag, `--connection-file PATH`
  (default: `t3paths.connection_path()`); the URL always comes from the
  file. Also add a hidden `--proc-root PATH` (default `/proc`) so the
  listener-owner check can be pointed at a fake tree that lists the fake's port; assert: first line is schema v1;
  window-processes echo carries the revision; focus-agent ok and
  agent_gone; `quit` exits 0 within 2 s; stdin EOF exits; not-paired state;
  expired state; server stop → `connecting`/`server_not_running` → recovery
  with `generation` bumped; HTTP fallback when the fake answers 426 on `/ws`.
  `test_disconnect_withdraws_live_inventory` keeps cached threads across a WS
  drop and an HTTP poll failure but asserts no published agent/attention rows
  until recovery is synchronized/successful.
- `test_provider_lifecycle.py`: no token appears in any stdout/stderr line
  (search for the fake token string across all captured output).
  `test_live_unpair_withdraws_inventory` deletes the file during a healthy
  stream: within 2 s the provider closes that stream, publishes the unpaired
  placeholder and empty inventory, and rejects a delayed old-revision event.
  `test_live_connection_replacement` atomically replaces a healthy record:
  old inventory is withdrawn, the new token is used and the new subscription
  omits `afterSequence`; unchanged records do not reconnect. Repeat deletion
  and replacement during HTTP fallback and a long retry wait. Cover expiry
  and invalid/untrusted replacement without exposing either token.
- `tests/test_t3_paths.py`, `tests/test_t3_lifecycle.py` (above).
- `tests/test_t3_cli.py`: `pair` against the fake server with a fake `t3`
  executable on `PATH` (a small script printing `{"credential":"c"}`) and a
  temp `T3CODE_HOME` containing `userdata/environment-id`; asserts the file
  is written 0600 and the token is not in stdout; `status` exit codes;
  `unpair` deletes; environment mismatch refuses.

**Slice 1 done when:** the full validation gate passes, and (with the
user's approval) a manual run of
`dockrail t3 pair && python3 -B provider/t3/bin/dockrail-t3-provider` on this
machine prints a live snapshot whose `servers[0].clients[0].ancestors`
includes the T3 Code window pid (`hyprctl clients -j` → class
`com.t3tools.T3Code` → `pid`). Send `quit` to stop it.

---

## Slice 2: generic service and source mux (Herdr unchanged)

Branch `feat/t3-threads-2-mux` from slice 1's head. **This slice needs
judgement; have the critic review the diff before the PR.**

### 2.1 Parameterise `components/DockHerdrService.qml`

- Add `property string providerRelativePath: "../provider/herdr/bin/smartdock-herdr-provider"`.
  Change `providerPath` (lines 25-26) to
  `localPath(Qt.resolvedUrl(root.providerRelativePath))`. `Qt.resolvedUrl`
  resolves relative to `DockHerdrService.qml` (in `components/`) even when the
  string is set from `Service.qml`, so `"../provider/t3/…"` lands in the
  repository's `provider/t3/`. Herdr instances do not set the property, so
  behaviour is identical. (No other new property.)
- Check `tests/test_herdr_lifecycle.py` for assertions on the literal
  provider path string in `DockHerdrService.qml`. If one exists, keep the
  literal in the file as the default value (it is) and do not change the test.

### 2.2 New pure model `components/DockAgentSourceModel.js` (`.pragma library`)

Functions (all pure, no QML):

- `compositeEpoch(sources)`: `sources` is `[{id, epoch, enabled, running}]`.
  Return `id + "=" + epoch` for each enabled, running source with a non-empty
  epoch, joined by `"|"`, in input order. Empty string when none.
- `sourceIdForServerId(serverId)`: `"t3"` if it starts with `"t3:"`, else `"herdr"`.
- `mergeSnapshots(entries, compositeEpoch, revision)`: `entries` is
  `[{id, snapshot}]` for enabled sources that have a ready snapshot. Returns:
  ```js
  { schemaVersion: 1, providerEpoch: compositeEpoch, revision: revision,
    capabilities: primary.capabilities,
    servers: concat over entries of entry.snapshot.servers.map(s => Object.assign({}, s, {
               source: s.source || entry.id,
               providerEpoch: entry.snapshot.providerEpoch,
               sourceCompleteness: entry.snapshot.completeness || null,
               sourceLiveCountsKnown: entry.snapshot.liveCounts !== null
                                      && entry.snapshot.liveCounts !== undefined })),
    agents: concat(entry.snapshot.agents), attention: concat(entry.snapshot.attention),
    liveCounts: primary.liveCounts, completeness: primary.completeness,
    windowProcesses: mergedWindowProcesses(entries) }
  ```
  `primary` is the `"herdr"` entry if present, otherwise the first entry.
  **Top-level `liveCounts`, `completeness` and `sourceErrorCode` are copied
  from `primary` only (omit `sourceErrorCode` when primary has none).** Never
  sum or mix them across sources: `DockSidebarModel.herdrStateTitle` and
  `herdrInventoryPartial` read them, and a truncated T3 list must not make
  Herdr windows say "Partial inventory". Per-source values travel on each
  server as `sourceCompleteness` / `sourceLiveCountsKnown` (see §3.3).
- `mergedWindowProcesses(entries)`: if every entry's
  `snapshot.windowProcesses.revision` is the same integer R, return
  `{revision: R, identities: union deduped by pid}`; otherwise
  `{revision: -1, identities: []}`. (Revision -1 never matches the bridge's
  request, so `resolveAssociations` returns null and the bridge keeps its
  preserved parents until both providers have echoed the latest revision.)
- `mergeStatus(statuses)`: `"ready"` if any `"ready"`; else `"loading"` if any
  `"loading"`; else `"unavailable"` if any `"unavailable"`; else `"error"`.

Node tests `tests/test_agent_source_model.mjs` (pattern:
`tests/test_herdr_sidebar_model.mjs` + `tests/host_harness.mjs`): composite
epoch ordering and exclusion; merge with one source equals the source except
`providerEpoch` and the four stamped server fields; revision mismatch → -1;
identity dedupe; top-level `liveCounts`/`completeness`/`sourceErrorCode` come
from Herdr even when T3 is truncated or erroring; T3-only merge takes them
from T3; status merge table.

### 2.3 New `components/DockAgentSourceMux.qml`

An `Item` that implements **exactly the members consumers use on
`DockHerdrService`** (verified list: `acquire(owner)`, `available`,
`running`, `sourceEpoch`, `sourceRevision`, `setWindowProcesses(revision, pids)`,
`refresh()`, `focusAgent(target)`, signal `focusAgentFinished(requestId, ok, errorCode)`).

```qml
property var sources: []   // [{ id: "herdr", service: <DockHerdrService>, enabled: bool }, …]
```

Behaviour:

- **Lease** (`acquire(owner)`): return an object with the same shape as
  `DockHerdrService.acquire` (DockHerdrService.qml:120-168): `{owner, provider,
  active, released, publish, revision, setActive(active, publish), release()}`.
  Keep `activeCount`. When `activeCount` goes 0 → 1, or `sources` changes
  while active, call `syncChildLeases()`; when it returns to 0 release
  activity on all children.
  **Ordering (children publish synchronously inside `setActive`, which
  re-enters the mux and then the bridge):** in the mux lease's
  `setActive(true)`, first set `lease.active = true`, store `lease.publish`,
  increment `activeCount` and publish `"loading"` to that lease (or the last
  merged view if there is one), and only then call `syncChildLeases()`. On a
  repeated `setActive(true)` for an already-active lease, republish the last
  merged view to that lease, as `DockHerdrService.qml:141-142` does; the
  bridge relies on this in `updateServiceLease` (DockHerdrWindowAgents.qml:500).
- `syncChildLeases()`: for each source, keep one child lease
  (`service.acquire("agent-source-mux." + id)`), created lazily and
  released in `Component.onDestruction`. Remember which service object each
  lease came from. Services start as `null` (the loaders wait for
  `migration.ready`) and plugin reloads replace them, so on every `sources`
  change: if a source's `service` object differs from the one its lease came
  from, release the old lease, drop `childViews[id]`, and acquire from the
  new service (same idea as the bridge's `onHerdrServiceChanged` →
  `syncServiceLease`, DockHerdrWindowAgents.qml:530). A `null` service means
  no lease. Child lease is active iff the mux is
  active **and** `source.enabled`. Child publish callback stores
  `childViews[id] = value` and calls `republish()`.
- `republish()`: `entries` = enabled sources whose `service.running` is true,
  whose `childViews[id].status === "ready"` and data is an object, and which
  are not currently *lagging*.
  **Lagging rule (isolates either slow or hung provider):** when
  `setWindowProcesses(R, …)` is forwarded, record `pendingRevision = R` and
  start a 2000 ms `Timer`. At the deadline, if at least one enabled, running,
  ready source has a snapshot whose `windowProcesses.revision === R`, mark
  every other enabled source without current evidence as lagging, including
  Herdr when T3 has current evidence. Leave lagging sources out of `entries`
  (their servers and agents disappear for now), so the remaining sources'
  merged revision becomes R. If none has current evidence, do not exclude
  all sources or invent successful association evidence; keep waiting.
  Never mark the only enabled source as lagging: Herdr alone must retain
  today's indefinite wait for its own echo. Re-evaluate this rule when a
  source first catches up after the deadline, so both initially stale sources
  cannot keep a subsequently healthy one blocked.
  A lagging source is un-marked as soon as its snapshot carries
  `windowProcesses.revision === pendingRevision`, or when its service object
  or `service.sourceEpoch` changes; then `republish()`. A replacement/restarted
  source gets a new 2000 ms catch-up deadline. Repeated publications or sends
  for the same revision must not postpone an existing source's deadline.
  The timer's `onTriggered` must call `republish()`.
- **Never publish `"ready"` without data.** If `entries` is empty: broadcast
  `"loading"` when any enabled child is `"loading"` or lagging; otherwise
  `mergeStatus(...)` over the enabled children's statuses (which then cannot
  be `"ready"`), with `null` data. `sourceEpoch` = `compositeEpoch(...)` from
  each enabled source's `service.sourceEpoch` and `service.running`.
  `sourceRevision++`. If `entries` is non-empty broadcast `"ready"` with
  `mergeSnapshots(entries, sourceEpoch, sourceRevision)`; else broadcast
  `mergeStatus(...)` with `null`. Broadcast uses the same `publishLease` logic
  as `DockHerdrService.qml:104-118` (copy it).
- `running`: true if any enabled source's `service.running`. `available`:
  true if any enabled source's `service.available !== false`.
- `setWindowProcesses(revision, pids)`: call it on every enabled running
  child; return true only if every such call returned true and at least one
  child was called.
- `refresh()`: forward to every enabled child.
- `focusAgent(target)`: find the server with `id === target.serverId` in the
  last merged snapshot; route by its stamped `server.source` (fall back to
  `sourceIdForServerId` only if the server is not found, and then return `""`
  unless that source is enabled); take the server's stamped `providerEpoch`; call
  `child.focusAgent(Object.assign({}, target, { providerEpoch: thatEpoch }))`.
  If it returns a non-empty id, return `id + ":" + childRequestId` and record
  the mapping. Else return `""`.
- Re-emit each child's `focusAgentFinished(childId, ok, code)` as
  `focusAgentFinished(sourceId + ":" + childId, ok, code)` (use one
  `Connections` per source via a `Repeater`/`Instantiator` over `sources`, or
  connect in `syncChildLeases` and disconnect on change; pick the
  `Instantiator` + `Connections { target: modelData.service }` form).
- `Connections` on each child for `runningChanged`, `sourceEpochChanged`,
  `sourceRevisionChanged` → recompute `sourceEpoch` (the bridge listens to
  the mux's `sourceEpochChanged` to resend window processes).

QML test `tests/tst_agent_source_mux.qml` with two stub services (pattern:
the stub `QtObject` service in `tests/tst_herdr_host_bridge.qml`):
single-source pass-through (merged data deep-equals the child snapshot apart
from the top-level `providerEpoch`/`revision` and the four stamped server
fields); never-ready-without-data; either source alone never marked lagging;
`test_lagging_source_isolation` in both directions: a stale T3 source cannot
block current Herdr, and stale Herdr cannot block current T3 after 2000 ms;
both stale sources keep waiting, then the first to catch up becomes usable;
same-revision publications cannot extend the deadline; a lagging source rejoins
when its echo arrives; lease
re-acquired when a source's service object is replaced; repeated
`setActive(true)` republishes; both sources; disabling a source removes its
servers and agents; child lease activity follows `enabled`; `setWindowProcesses`
fan-out; `focusAgent` routing by `t3:` prefix with epoch rewrite;
`focusAgentFinished` re-emission with prefix; epoch change on child restart.

### 2.4 Source-aware labels in `components/DockHerdrModel.js`

Add (do not change existing functions' Herdr output):

```js
function serverSource(server) { … "t3" when server.source === "t3", else "herdr" }
function serverProduct(server) { "T3 Code" for t3, else "Herdr" }   // prefer cleanDisplayText(server.product) if non-empty
function agentNoun(server) { "thread" for t3, else "agent" }
function focusHint(server) { "Click a row to open T3 Code." for t3, else "Click a row to focus its pane." }
```

Node tests: each helper returns the Herdr value for `{}`, `null`, a Herdr
server, and the T3 value for `{source:"t3"}`.

**Slice 2 done when:** the full gate passes and **no existing Herdr test
was modified**. Nothing is wired into DockHost yet, so runtime behaviour is
unchanged.

---

## Slice 3: wiring, widget, config, strings, docs

Branch `feat/t3-threads-3-ui` from slice 2's head.

### 3.1 Service instances

- `Service.qml`: add a second loader next to `herdrLoader` (lines ~43-49):
  ```qml
  Loader {
    id: t3Loader
    active: migration.ready
    sourceComponent: Component {
      DockHerdrService {
        providerRelativePath: "../provider/t3/bin/dockrail-t3-provider"
      }
    }
  }
  ```
  and `readonly property var t3Service: t3Loader.item` next to `herdrService`.
- `shell.qml`: same loader; pass `t3Service: t3Loader.item` to `DockHost`.
- `Overlay.qml` (line ~32): pass `t3Service: root.pluginService.t3Service`.

### 3.2 `DockHost.qml`

- Add `property var t3Service: null` next to `herdrService` (line ~25).
- Add availability probe for T3, copying the Herdr probe pattern (lines 26-27,
  52-57, 666-692): `t3BinaryInstalled`, `t3BinaryProbePending`,
  `refreshT3BinaryAvailability()`, a `Process` running
  `["sh", "-c", "command -v t3"]`, same timeout and 30 s re-run timer.
- Add the wanted flags. They mirror exactly when a provider runs today: the
  dock consumer only with classic screens, the sidebar only while its widget
  view is active (not merely listed in settings):
  ```qml
  function sidebarWidgetActive(id) {
    var view = sidebarState.widgetView(id)
    return !!(view && view.active)
  }
  readonly property bool herdrSourceWanted: (DockModel.normalizeSetting(
      "dockHerdrIndicators", root.settings.dockHerdrIndicators)
      && root.presentation.classicScreens.length > 0)
    || root.sidebarWidgetActive("herdr.agents")
  readonly property bool t3SourceWanted: (DockModel.normalizeSetting(
      "dockT3Indicators", root.settings.dockT3Indicators)
      && root.presentation.classicScreens.length > 0)
    || root.sidebarWidgetActive("t3.threads")
  ```
  If `widgetView` is not reactive enough to re-evaluate these bindings (check
  `DockSidebarController.widgetView` and whether it reads a revision
  property such as `widgetRevision`), read that revision inside
  `sidebarWidgetActive` the way `DockSidebarWidgetArea.qml:26` does.
- Instantiate the mux:
  ```qml
  DockAgentSourceMux {
    id: agentSourceMux
    sources: [
      { id: "herdr", service: root.herdrService, enabled: root.herdrSourceWanted && !!root.herdrService },
      { id: "t3", service: root.t3Service, enabled: root.t3SourceWanted && !!root.t3Service }
    ]
  }
  ```
- `DockHerdrWindowAgents` (line ~785): `herdrService: agentSourceMux`; change
  `dockConsumerActive` to exactly:
  ```qml
  dockConsumerActive: (DockModel.normalizeSetting("dockHerdrIndicators", root.settings.dockHerdrIndicators)
      || DockModel.normalizeSetting("dockT3Indicators", root.settings.dockT3Indicators))
    && root.presentation.classicScreens.length > 0
  ```
  (Both arguments are required; `normalizeSetting` without the value returns
  the default `false` and would silently switch Herdr dock indicators off.)
- `DockHerdrAgentActions` (line ~797): `herdrService: agentSourceMux`.
- Widget registry (lines 77-88): keep `herdr.agents` exactly; its `available`
  keeps reading `root.herdrService.available`. `tests/SidebarSplitSourceHarness.js:29-51`
  evaluates this registry block verbatim with a fixture that only defines
  Herdr identifiers, so **every T3 identifier (`t3Service`,
  `t3BinaryInstalled`, `acquireT3Widget`, `t3ExpandedView`, …) must stay inside
  the `if (root.t3Service) { … }` block**. Add, inside `if (root.t3Service)`:
  ```js
  registry["t3.threads"] = {
    id: "t3.threads", label: "T3 Code threads",
    manageable: root.t3BinaryInstalled,
    available: root.t3BinaryInstalled && root.t3Service.available !== false,
    revision: 1, acquire: root.acquireT3Widget,
    expandedView: t3ExpandedView, compactView: t3CompactView, popupView: t3PopupView
  }
  ```
  `function acquireT3Widget(owner) { return root.herdrWindowAgents.createConsumerLease(owner) }`
  (a stable function, same reason as `acquireHerdrWidget`, see
  `docs/SIDEBAR_WIDGETS.md` 84-87).
- View components next to lines 819-821:
  `Component { id: t3ExpandedView; DockHerdrAgentsView { sourceFilter: "t3" } }` (×3),
  and set `sourceFilter: "herdr"` on the three Herdr view components.

### 3.3 Per-source filtering in consumers

- `components/DockHerdrAgentsView.qml`: add `property string sourceFilter: "herdr"`.
  At the top of the data path (where it reads `widgetContext.data`, lines
  ~27-53), filter `servers` to `HerdrModel.serverSource(server) === root.sourceFilter`
  and `agents` to those whose server survived. Everything else is unchanged.
  For T3 session-row `detail`, use
  `SidebarModel.t3PairingHint(server)` (§3.3 below) when non-empty;
  `server_not_running` → "T3 Code is not running"; other non-live states →
  `SidebarModel.herdrStateTitle(server, root.snapshot)`. A non-live server
  gets no empty child (`DockHerdrAgentsView.qml:119-125`), so the session row
  must carry the hint for an unmatched server. Matched servers remain excluded
  from this view; their pairing hint belongs in the associated hierarchy
  state row instead.
- `components/DockSidebarWidgetArea.qml` (lines 25-32): apply the same rule
  per widget id: for `"herdr.agents"` and `"t3.threads"`, compute
  `herdrFallbackVisible(filterSnapshot(snap, source), associations)` where
  `filterSnapshot` is a new `SidebarModel.filterSnapshotBySource(snapshot, source)`
  (add it in `DockSidebarModel.js` next to `herdrFallbackVisible`, with a node test).
  The view to read for `t3.threads` is `widgetView("t3.threads")`. Also show
  the card when an **unmatched** T3 server has a non-empty
  `SidebarModel.t3PairingHint(server)`. Use
  `SidebarModel.matchedHerdrServerIds(associations)` for this exception too;
  a matched auth-error server must not force an empty fallback card visible.
- `components/DockSidebarController.qml` (lines 525-545): replace the single
  `herdrVerified` with:
  ```js
  var herdrView = root.widgetView("herdr.agents")
  var t3View = root.widgetView("t3.threads")
  var ready = !!(root.herdrWindowAgents && root.herdrWindowAgents.snapshotReady)
  var herdrActive = !!herdrView && herdrView.active
  var t3Active = !!t3View && t3View.active
  var herdrVerified = ready && (herdrActive || t3Active)   // replaces the old line
  var verifiedSources = { herdr: ready && herdrActive, t3: ready && t3Active,
                          t3Present: t3Active }
  ```
  pass `herdrAssociationsVerified: herdrVerified` (unchanged key) **and**
  `herdrVerifiedSources: verifiedSources` into `projectInput`.
- `components/DockSidebarModel.js`:
  - Import `DockAgentSourceModel.js` as `AgentSourceModel` using the existing
    `.import` style. Add `herdrServerForDisplay(snapshot, serverId)` next to
    `herdrServerById`: return the real server when present. When absent and
    `AgentSourceModel.sourceIdForServerId(serverId) === "t3"`, return only
    presentation metadata `{id: serverId, source: "t3", product: "T3 Code",
    label: "T3 Code", health: "unavailable", capabilities: {focusAgent: false}}`;
    otherwise return null, preserving existing Herdr fallbacks. Use this
    lookup in `attachHerdr` and `emitHerdrChildren`. The controller deliberately
    passes a null snapshot while `snapshotReady` is false; the retained
    `t3:` server ID must still identify a T3 parent during that interval.
    This display metadata never enters the provider snapshot or grants
    association verification, agents or actions.
  - `attachHerdr` (line ~741): find display metadata before the unassociated
    guard, so the guard also applies when the snapshot is null. If
    `HerdrModel.serverSource(server) === "t3"` and
    `input.herdrVerifiedSources` is an object and
    `input.herdrVerifiedSources.t3Present !== true`, take the
    not-associated branch (same as `!serverId`). **Never** unassociate Herdr
    windows here: today an unverified Herdr parent keeps its label and shows a
    pending child (lines 817-821); keep that, or Herdr rows flicker every time
    a window opens or closes (`snapshotReady` drops briefly then).
  - Live verification per window: where `attachHerdr` and `emitHerdrChildren`
    test `herdrAssociationsVerified`, use
    `var verified = input.herdrVerifiedSources
       ? input.herdrVerifiedSources[HerdrModel.serverSource(server)] === true
       : herdrAssociationsVerified`.
    When `herdrVerifiedSources` is absent (all existing Herdr tests) the
    behaviour is exactly today's.
  - Set `window.herdrDisplayLabel` to `HerdrModel.serverProduct(server)` for
    local T3 servers, including retained T3 parents without a current server
    object (Herdr local stays `"Herdr"`, remote stays
    `serverMeta.serverLabel`). An associated window row shows only this label
    (`DockSidebarInteractionModel.sidebarWindowDisplayTitle`, lines 492-494),
    so the T3 Code window row reads **"T3 Code"**, with the threads indented
    beneath it. The window title stays in the tooltip.
  - Line ~819, the pending title for unverified parents: replace
    `"Herdr unavailable"` with `HerdrModel.serverProduct(server) + " unavailable"`
    using the display lookup above. A missing T3 server still produces
    `"T3 Code unavailable"`; a missing Herdr server remains
    `"Herdr unavailable"`, byte-identical for Herdr.
  - Add `t3PairingHint(server)`: return `""` for non-T3 servers or other
    error codes; `pairing_required` → "Pair T3 Code: run `dockrail t3 pair`";
    `pairing_expired` or `authentication_required` →
    "T3 Code pairing expired: run `dockrail t3 pair`". This one helper owns
    the copy shared by fallback session rows and associated state rows.
  - `herdrInventoryPartial(snapshot)` (line ~622) becomes
    `herdrInventoryPartial(snapshot, server)` with `server` optional; pass
    `server` at its call site (line ~880).
- `components/DockSidebarModel.js` `herdrStateTitle` (line ~599): replace the
  literal `"Herdr unavailable"` with `HerdrModel.serverProduct(server) + " unavailable"`
  (when `server` is null use `"Herdr"` to keep current text), and `"No active
  agents"` with `"No active " + HerdrModel.agentNoun(server) + "s"`. Before
  the generic unavailable return, prefer a non-empty `t3PairingHint(server)`;
  associated auth-error servers therefore show the re-pair instruction even
  though the fallback view suppresses them. Keep the Herdr strings
  byte-identical. In both `herdrStateTitle` and
  `herdrInventoryPartial`, prefer the server's own `sourceCompleteness` and
  `sourceLiveCountsKnown` (stamped by the mux, §2.2) when those keys are
  present, and fall back to the snapshot-level fields when absent (all
  existing Herdr tests pass servers without them). **Watch out:** `herdrFallbackEmptyChild` and
  `herdrFallbackStateChild` compare against the literal `"No active agents"`;
  change those comparisons to compare against the computed string for the
  same server.
- `components/Dock.qml`:
  - Add `readonly property bool dockT3Indicators: DockModel.normalizeSetting("dockT3Indicators", settings.dockT3Indicators)`
    next to line 441.
  - Add `function sourceIndicatorsEnabled(toplevel)`: look up the window's
    server via `herdrWindowAgents.herdrAssociations.byWindowKey[herdrWindowAgents.windowKeyFor(toplevel)]`,
    find the server in `herdrWindowAgents.snapshot.servers`, return
    `dockT3Indicators` for source t3, `dockHerdrIndicators` otherwise.
  - In `herdrSummaryFor`, `herdrPreviewAgentsFor` and
    `allItemWindowsHerdrAssociated` (lines 817-873): replace the
    `!root.dockHerdrIndicators` guard with
    `!(root.dockHerdrIndicators || root.dockT3Indicators)`, and pass only
    `(item.toplevels || []).filter(root.sourceIndicatorsEnabled)` to the
    bridge. In `herdrSummaryFor` the call must read exactly
    `summaryForToplevels((item.toplevels || []).filter(root.sourceIndicatorsEnabled))`
    (pinned by the allowed edit to `check_herdr_dock_indicators.sh:19`).
  - `herdrServerLabel` returns `HerdrModel.serverDisplayLabel(server)`; for
    T3 servers return `HerdrModel.serverProduct(server)` instead.
  - Add `previewHerdrProduct` and `previewHerdrFocusHint` bindings on the item
    (next to `previewHerdrLabel`, line ~1726), computed from the first preview
    agent's server (`"Herdr"` / `"Click a row to focus its pane."` when none).
  - `herdrPreviewLabelFor`: skip labels equal to the product name (today it
    skips `"Herdr"`; also skip `"T3 Code"`).
- `components/DockItem.qml` (lines 66-69): add
  `property string previewHerdrProduct: "Herdr"` and
  `property string previewHerdrFocusHint: "Click a row to focus its pane."`.
  Accessible text (lines 696-708): replace the word "agents" with
  `HerdrModel.agentNoun`-based plural when the product is T3 Code.
- `components/DockWindowPreview.qml`:
  - Declare `property string herdrProduct: "Herdr"` and
    `property string herdrFocusHint: "Click a row to focus its pane."`
    **directly after** `property string herdrLabel: ""` (line 80) and before
    `readonly property bool showWindowPreviews:`.
    `tests/test_browser_activity_preview.py:32-34` copies only lines 74-82
    into its harness, so they must sit inside that block. Read them with
    bracket access and a default, because that test's anchor fixture lacks
    them: `String(anchorItem["previewHerdrProduct"] || "Herdr")` and
    `String(anchorItem["previewHerdrFocusHint"] || "Click a row to focus its pane.")`.
    Set them everywhere the file sets
    `herdrLabel` (lines ~199, 266, 346) and reset them to those defaults where
    `herdrLabel` is reset; add the matching `on*Changed` handlers next to
    lines 1150-1157.
  - Line ~776: `text: root.herdrLabel ? root.herdrProduct + " · " + root.herdrLabel : root.herdrProduct`.
  - Line ~767 header glyph: `iconName: root.herdrProduct === "T3 Code" ? "messages-square" : "terminal"`
    (check `components/DockLucideIcon.qml` for an available icon name; if
    `messages-square` is missing, keep `terminal`).
  - Line ~1004 footer: `text: root.herdrFocusHint` (then apply the allowed
    edit to `tests/check_window_previews.sh:62`).
  - Lines ~869-870, row accessibility description:
    `actionable ? (root.herdrProduct === "T3 Code" ? "Open T3 Code" : "Focus this Herdr agent pane") : "Remote Herdr agent"`.
- `components/DockContextMenu.qml`: line 197 builds the header record
  `"Herdr · " + label`. Change it to
  `String(anchor["previewHerdrProduct"] || "Herdr") + " · " + label` so
  `test_context_menu_herdr_records.mjs:56` still sees `"Herdr · …"`. Line 1357
  tooltip `"Focus this Herdr agent pane"`: use `"Open T3 Code"` when the
  record's product is T3 Code, else keep the existing text. To carry the
  product, set `record.product = String(anchor["previewHerdrProduct"] || "Herdr")`
  on each agent record right after creating it, the same way
  `header.muted = true` is set at line 198. **Do not change the
  `DockMenuModel.agentRecord(...)` signature**: `tests/check_context_menu_contract.sh:44`
  pins it.
- `components/DockSidebarRow.qml` (lines 259-267): `"Herdr agent: "` →
  `(row.serverLabel === "T3 Code" ? "T3 Code thread: " : "Herdr agent: ")`;
  `"Herdr: "` → same switch with `"T3 Code: "`. (`serverLabel` is already on
  every herdr-agent/herdr-state row, see DockSidebarModel `emitHerdrState`.)
  Lines ~158-159, `windowTitle` fallback for `herdr-state` rows: `"Herdr"` →
  `String(row.serverLabel || "").trim() || "Herdr"`.
- `components/DockSidebarInteractionModel.js` (lines 488-489): the
  `"Herdr"` fallback for `herdr-state` rows becomes
  `String(source.serverLabel || "").trim() || "Herdr"`.

### 3.4 Protected ids and config keys (change all of these together)

- `config/dock.json`: add `"dockT3Indicators": false` right after
  `dockHerdrIndicators`.
- `config/settings-schema.json`: add `"t3.threads"` to
  `sidebarWidgets.registeredIds` (lines 35/38); add
  `"dockT3Indicators": {"type":"boolean","description":"Show T3 Code thread state on the T3 Code icon, in hover previews and in the context menu. Requires `dockrail t3 pair`; enabling it starts the T3 provider while a classic dock is active."}`
  right after `dockHerdrIndicators` (line 71).
- `components/DockModel.js`: default `dockT3Indicators: false` next to line
  440; boolean normalisation next to line 780 (copy the Herdr lines).
- `docs/CONFIGURATION.md`: inventory row right after line 67, same format
  (the regex in `tests/test_cli_docs.py:86-100` requires one row per key).
- `README.md`: config example (near line 508), key table (near 568), and a
  "T3 Code threads" section after the Herdr section (near 166-182):
  `dockrail t3 pair`, `dockrail config set sidebarWidgets '["t3.threads"]'`,
  `dockrail config set dockT3Indicators true`, and the limits (local only,
  click raises the window, re-pair every 30 days).
- `scripts/smartdock_widget.py:42`: add
  `"t3.threads": ("T3 Code threads", "integration", False)`.
- `components/DockExternalWidgetRegistry.qml:28-29`: add `"t3.threads"` to the
  protected id list.

### 3.5 Tests to add or extend (do not edit Herdr assertions)

- `tests/test_t3_sidebar_model.mjs`: project a desktop with one T3 Code window
  (pid matching a merged snapshot with a `source:"t3"` server) → `window`
  row has `herdrDisplayLabel === "T3 Code"`, children are `herdr-agent` rows
  with T3 titles and `treeDepth = parent + 1`; with
  `herdrVerifiedSources: {herdr: true, t3: false, t3Present: true}` → the T3
  window shows the pending "T3 Code unavailable" child, not thread rows; with
  `t3Present: false` → the T3 window is not associated at all; in the same
  projection a Herdr window with `herdr: false` still keeps its "Herdr"
  label and pending child (no flicker regression); state title strings
  "T3 Code unavailable" / "No active threads"; a truncated T3 server does not
  turn a Herdr window's empty state into "Partial inventory".
  `test_retained_t3_parent_without_snapshot` repeats the pending projection
  with `herdrSnapshot: null`: the retained T3 parent keeps its "T3 Code"
  label and "T3 Code unavailable" child, with no agent rows or actions.
  `test_removed_t3_widget_without_snapshot` sets `t3Present: false` in that
  same null-snapshot case: T3 is unassociated while the Herdr parent retains
  its existing label and pending child. Also cover a non-null snapshot whose
  server list omits the retained T3 server.
- New `tests/tst_t3_dock_indicators.qml`, using the existing dock indicator
  test's fixture pattern without editing it: badge appears only when
  `dockT3Indicators` is true; Herdr badges are unaffected by that setting.
- New `tests/tst_t3_window_preview.qml` (pattern of the existing herdr-only preview tests):
  header text `"T3 Code"`, footer `"Click a row to open T3 Code."`.
- New `tests/tst_t3_pairing_hints.qml`: with a matched T3 server carrying
  `authentication_required`, the projected hierarchy contains the re-pair
  instruction, no agents/actions, and no empty fallback card is presented.
  With the same server unmatched, the T3 fallback card is presented and its
  session-row `detail` contains that same instruction. Repeat for
  `pairing_required` and `pairing_expired`, and assert Herdr text is unchanged.
  Exercise the real view and Widget-area presentation filter using the source
  harness pattern from `tests/SidebarSplitSourceHarness.js`.
- `tests/host_harness.mjs`: add the inert `t3.threads` descriptor from the
  allowed fixture edit. Update only the two listed registered-ID assertions
  in `tests/test_sidebar_widget_config.py`. New
  `tests/test_t3_widget_packages.py`: `t3.threads` is protected against external
  package installation; reuse the fixtures from `tests/test_widget_packages.py`
  without modifying its existing tests.
- `tests/test_t3_lifecycle.py`: add the registry descriptor and Service/shell
  loader checks.
- **Herdr end-to-end regression through the mux**,
  `tests/tst_agent_source_herdr_regression.qml`: wire
  `DockAgentSourceMux` (sources: a stub Herdr service, enabled; a stub T3
  service, disabled, then enabled) → real `DockHerdrWindowAgents` → real
  `DockHerdrAgentActions` with a stub `windowActions`, using the toplevel and
  stub fixtures from `tests/tst_herdr_host_bridge.qml`. Assert:
  (a) with T3 disabled, `herdrAssociations.byWindowKey` and
  `agentsByAddress` equal what the bridge produces when wired straight to
  the stub Herdr service (run both wirings in the same test);
  (b) the `focus-agent` call the stub Herdr service receives carries the
  Herdr stub's own `sourceEpoch`, not the composite epoch;
  (c) enabling T3 with a stub that never echoes the new
  `windowProcesses.revision`: within 2.5 s (`tryVerify`) the Herdr window is
  associated again and has its agents; the T3 window has none; once the T3
  stub echoes the revision, both associate;
  (d) a T3 snapshot with `completeness.agentTruncated: true` does not change
  the Herdr window's state title;
  (e) reverse the lagging-source scenario: Herdr never echoes while T3 does;
  within 2.5 s T3 associates and its focus action routes to the T3 stub, while
  Herdr has no actionable agent rows; Herdr rejoins after its echo arrives;
  (f) after a live T3 snapshot, a connecting/unavailable snapshot from §1.7
  carries no cached agents into the sidebar, previews, menu or dock summary.

### 3.6 Docs

- New `docs/T3_DATA_ACCESS.md` in the style of `docs/HERDR_DATA_ACCESS.md`:
  data path diagram, pairing and token storage, what is read (shell stream
  only, read scope), states and error codes, the status mapping table from
  §1.7, limits (local only, no deep link, 30-day session), how to unpair and
  revoke. Explain that unpairing withdraws the running provider's inventory
  within 2 s and that server-side revocation is a separate action.
- `install.sh` line ~96: add `T3_DATA_ACCESS.md` to the offline docs list
  right after `HERDR_DATA_ACCESS.md`.
- Public docs (`T3_DATA_ACCESS.md`, README, CLI_REFERENCE, CONFIGURATION,
  CHANGELOG entries) must not contain `FDM-` or the word "qualification"
  (`tests/test_user_facing_docs.py:20-24`).
- `docs/SIDEBAR_WIDGETS.md`: list `t3.threads` next to `herdr.agents`.
- `CHANGELOG.md`: "Added: T3 Code threads (sidebar widget `t3.threads`, dock
  indicators `dockT3Indicators`, `dockrail t3 pair|status|unpair`)."

### 3.7 Runtime gate (not automatable here; report as an explicit gate)

The KVM guest has no T3 Code, so the association cannot be verified there.
After the full gate passes, hand off to the user (or run with their explicit
approval) using the local switch workflow from `AGENTS.md`:

1. Read `docs/AGENT_CONFIGURATION.md`. Discover the running host with
   `dockrail status --json`, `dockrail config schema --json` and
   `dockrail config get --json`; record the authoritative config path and
   exact target selectors. With `umask 077`, create a private temporary change
   directory and export requested settings there with `dockrail config export
   --output <new-backup-path> --json`. Record the original requested
   `sidebarWidgets` array, whether `dockT3Indicators` exists and its value,
   and which Widget IDs this test will add. The backup is a reference for
   touched-key cleanup, never a whole-file restore payload.
2. `dockrail t3 pair` (if not already paired in slice 1), then
   `dockrail dev use feat/t3-threads-3-ui`. Rediscover the host and exact
   selectors after the switch; confirm its config path is the one recorded
   above. Read the current requested values again before building the patch.
3. Build one JSON patch containing only `sidebarWidgets` and
   `dockT3Indicators`: append missing `herdr.agents` / `t3.threads` to the
   existing ordered array without dropping/reordering other IDs, and set the
   indicator flag true. Preserve unknown imported IDs under the configuration
   workflow; if the host rejects resubmitting them, stop and report that
   limitation instead of deleting them to make the test pass. Run
   `dockrail config apply --file <patch-path> --dry-run --json`, inspect its
   diff, then apply the same file once. Keep exact target selectors on every
   configuration command. Read requested and effective values back and check
   `applied`, `persisted`, `writeState`, errors and warnings. Record the exact
   values written by the test for cleanup comparison.
4. Check: T3 Code dock icon shows the status mark and count; hovering it shows
   the "T3 Code" preview list with threads grouped by project; clicking a row
   raises T3 Code; in the sidebar the T3 Code window row reads "T3 Code"
   with threads indented beneath; a thread finishing shows done, and
   opening it in T3 clears it; Herdr rows still look and behave exactly as
   before.
5. Quit T3 Code → rows disappear without errors; relaunch → rows return
   within a few seconds. During an association refresh, the retained T3 row
   must keep the "T3 Code" label; it must never flash "Herdr".
6. **Clean up while the candidate still supports the T3 setting.** Rediscover
   the host if needed and read the latest requested values. If a touched
   value still equals the value this test wrote, restore that key's original
   requested value through a minimal dry-run/apply/readback cycle, preserving
   all other keys. For an originally absent `dockT3Indicators`, use the
   supported `config reset dockT3Indicators` path and report that the CLI
   restores the default rather than exact key absence; never edit raw JSON.
   If a touched key changed meanwhile, do not overwrite that intervening
   edit: restore independent uncontested keys and report the precise cleanup
   conflict. Verify requested/effective values and actual persistence; an
   error or inability to restore an original imported value is an explicit
   cleanup limitation, not a successful rollback.
7. Run `dockrail dev reset` after the cleanup attempt, including when a check
   or rollback failed; use a `finally`/exit-cleanup path if automating the
   sequence. Rediscover the restored host, verify the original config path,
   and confirm the touched settings' requested values/persistence again.
   `dev reset` restores the plugin source only and never substitutes for
   step 6. Report any remaining test changes before handing back the desktop.
   Delete the private temporary directory only after the evidence and cleanup
   result have been recorded; keep a needed recovery backup private.

---

## Risks and how the plan handles them

| Risk | Handling |
|---|---|
| Real WS frames differ from t3-loupe's reading | Slice 0 captures real frames; fixtures drive the fake server; HTTP fallback (§1.8 step 11) |
| T3 changes its internal protocol | `orchestrationProtocolVersion` must be 2; otherwise state `unsupported` (visible in the widget card), no crash |
| Mux breaks Herdr | Slice 2 is isolated, adds tests only, no Herdr test edits; critic review |
| Bogus "Update Herdr" message on T3 rows | T3 servers omit `version` (§1.7) |
| T3 rows appear without the widget enabled | per-source verification (§3.3) and per-source dock gating |
| Token leak | file 0600 + owner checks, never on argv/QML/logs, listener-owner check before every send, test greps all output |
| Metadata enrichment clears threads or advances the resume cursor | Read the marker from the outer item; preserve threads, unrelated projects and sequence; initial/resume fixture regression (§1.7, §1.11) |
| Cached threads appear actionable during a connection gap | Non-live snapshots publish empty agents/attention and unknown counts; WS/HTTP recovery tests enforce the provider boundary (§1.7, §1.11, §3.5) |
| Unpair/re-pair does not affect a healthy provider | Monitor the connection file in every state; invalidate within 2 s and reject old-revision worker events (§1.8, §1.11) |
| Two providers' window-process echoes out of sync | Merged revision is -1 until evidence matches; after 2 s isolate either stale source when another is current, with recovery tests in both directions (§2.2, §2.3, §3.5) |
| A source alone stops waiting for its own identity evidence | Never mark the only enabled source lagging; preserve Herdr-only behavior and test the no-current-source case (§2.3) |
| T3 parents become Herdr during association refresh or widget removal | Recover display-only source metadata from the retained server ID; null/missing-snapshot tests cover labels and source gating (§3.3, §3.5) |
| Pairing guidance is suppressed with matched fallback rows | Share the hint helper between unmatched session details and associated state rows; do not present an empty matched fallback card (§3.3, §3.5) |
| Runtime schema tests disagree with the static schema | Explicitly permit/update the shared host registry fixture alongside the two registered-ID assertions (§3.5) |
| A failing check reports a successful slice | Run the full validation block in a fail-fast subshell; all failures retain nonzero status |
| Desktop preview leaves persistent test preferences | Export first, dry-run a minimal patch, verify persistence, restore uncontested touched values before resetting the source, and report conflicts/absence limits (§3.7) |
