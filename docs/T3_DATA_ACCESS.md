# T3 Code data access: local threads only

Dockrail shows threads from the T3 Code server running on this machine. It
talks to the local orchestration endpoint only (`127.0.0.1`, plain HTTP plus
a local WebSocket); remote T3 environments, Relay and T3 Connect are out of
scope and are always rejected.

The data path is:

```text
local T3 server (127.0.0.1:3773, /ws orchestration.subscribeShell)
  -> provider/t3/bin/dockrail-t3-provider
  -> components/DockHerdrService.qml (second instance)
  -> components/DockAgentSourceMux.qml
  -> internal sidebar widget t3.threads
```

## Pairing and token storage

One-time pairing uses T3's own CLI and exchanges a short-lived credential
for a read-only bearer session (`orchestration:read`, server-reported
lifetime, typically 30 days):

```sh
dockrail t3 pair
dockrail t3 status
dockrail t3 unpair
```

The token lives in a `0600` file at
`${XDG_DATA_HOME:-~/.local/share}/dockrail/t3/connection.json`, written only
by `dockrail t3 pair` and read only by the provider. It never appears in
`dock.json`, QML, logs, or on a command line. Before every request that
carries the token, the provider verifies the loopback listener is owned by
the current user and closes the socket without sending otherwise.

## What is read

Only the shell stream: projects and threads (titles, statuses, run state),
plus the protocol version and environment id from the unauthenticated
descriptor. No file contents, no terminal output, no message bodies. The
`orchestration:read` scope cannot operate, settle, snooze or approve
anything.

## States and error codes

The provider reports one `t3:<environmentId>` server with health `live`,
`connecting` or `unavailable`. While not live, no cached threads are shown:
agents, attention and counts are empty and completeness is `unknown`.

| Error code | Meaning | Fix |
| --- | --- | --- |
| `pairing_required` | never paired or unpaired | `dockrail t3 pair` |
| `pairing_expired` | session past its server-reported lifetime | `dockrail t3 pair` |
| `authentication_required` | server rejected the session | `dockrail t3 pair` |
| `server_not_running` | T3 Code is not listening | start T3 Code |
| `listener_untrusted` | the loopback listener belongs to another user | run your own T3 Code |
| `environment_changed` | pairing belongs to another environment | `dockrail t3 pair` |
| `unsupported` | orchestration protocol mismatch | update T3 Code |

## Status mapping

Thread states map to the shared agent states as follows:

| T3 condition | Shown as |
| --- | --- |
| approval or input requested, actionable plan waiting | blocked |
| preparing, starting, running or waiting (run or status) | working |
| background tasks pending | working |
| failed run you have not opened or settled | blocked |
| completed run you have not opened or settled | done |
| everything else (usage-limited, stopped, read) | idle |

Subagent threads appear only while blocked or working. Settlement acknowledges
runs completed at or before that timestamp; a later failure, active request or
ongoing work can still appear. Settled inactive threads and snoozed threads are
hidden. Clicking a thread raises the T3 Code window; there is no
per-thread deep link and no thread actions.

## Limits

Local loopback only; no remote environments. Sessions expire (see the date
reported at pairing); re-pair with `dockrail t3 pair`. Unpairing with
`dockrail t3 unpair` withdraws the running provider's threads within seconds
but does not revoke the server-side session: revoke it separately with
`t3 auth session list` / `t3 auth session revoke <id>` when needed.
