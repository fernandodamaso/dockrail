# SPDX-License-Identifier: Apache-2.0
# T3 provider (`provider/t3`)

Read-only local T3 Code threads for Dockrail, presented through the Herdr
provider contract (schema v1) so the existing `DockHerdrService` /
`DockHerdrWindowAgents` stack consumes T3 threads unchanged.

## Files

| File | Purpose |
| --- | --- |
| `bin/dockrail-t3-provider` | Provider process: stdin commands, connection worker, versioned NDJSON snapshots |
| `t3paths.py` | Connection-file path (`…/dockrail/t3/connection.json`) |
| `t3store.py` | Fail-closed connection-file reader (0600, owner, symlink, size checks) |
| `t3http.py` | Loopback-only HTTP client with post-connect listener ownership checks |
| `t3ws.py` | Minimal RFC 6455 WebSocket client (stdlib only) |
| `t3rpc.py` | Effect-RPC framing (`Request`/`Ack`/`Ping`/`Chunk`/`Exit`) |
| `t3procfs.py` | `/proc` listener ownership, identities and ancestry |
| `t3model.py` | `ShellStore`, thread classification, Herdr-schema snapshot builder |
| `tools/capture_ws.py` | Protocol capture tooling (not runtime code) |
| `tests/fake_t3.py` | In-process fake T3 server (HTTP + WS) replaying sanitized fixtures |
| `tests/fixtures/` | Sanitized captures: descriptor, HTTP shell, WS session + resume |

## Contract

The provider emits exactly one server (`t3:<environmentId>`, `source: "t3"`,
`product: "T3 Code"`, no `version` key so no bogus Herdr-upgrade prompt), live
agents only while the stream is synchronized, and empty inventory with
`completeness: unknown` during any gap. Thread states map to Herdr's
`blocked`/`working`/`done`/`idle` enum; see `t3model.classify`.

## Security rules

- Python standard library only; scripts run as `python3 -B`.
- The token lives only in the 0600 connection file. It never appears on
  stdout, stderr, argv, QML or settings.
- Every request carrying a token, form credential or ticket runs the
  same-UID listener check after TCP connect and before the first byte; a
  failed check closes the socket without sending. No redirects, no proxies,
  no remote endpoints.
- Pairing is written only by `dockrail t3 pair` (`scripts/dockrail_t3.py`,
  self-contained for `--cli-only` installs).
