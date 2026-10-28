# Claude Desktop sessions on the dock

With `dockClaudeIndicators` enabled, the Claude Desktop dock icon shows the
same agent marks as Herdr and T3 Code: a working spinner while a session is
running, an input-needed mark while it waits on a permission prompt, and a
done mark until you focus the Claude window.

Claude Desktop does not publish session state itself. Its Claude Code
sessions (the Code tab) do run Claude Code hooks, so Dockrail installs a few
hooks that record each session's state locally.

## Setup

```sh
dockrail claude hooks install
dockrail config set dockClaudeIndicators true --json
```

Then start a new Claude Desktop session (or restart the app) so it loads the
hooks. `dockrail claude hooks status [--json]` shows whether the hooks are
installed and how many session records exist; `dockrail claude hooks
uninstall` removes only Dockrail's hook entries.

`hooks install` edits `${CLAUDE_CONFIG_DIR:-~/.claude}/settings.json`,
keeping every other key and every hook you added yourself, and is safe to run
again. It refuses to touch a file that is not valid JSON. Each hook command
ends in `|| true`, so a removed Dockrail install can never block a prompt.

## Data path

```text
Claude Desktop -> claude (Claude Code session) -> hook: dockrail claude hook
  -> ${XDG_RUNTIME_DIR}/dockrail/claude/sessions/<hash>.json
     (fallback ${XDG_STATE_HOME:-~/.local/state}/dockrail/claude/sessions)
  -> provider/claude/bin/dockrail-claude-provider
  -> components/DockHerdrService.qml (third instance)
  -> components/DockAgentSourceMux.qml -> dock icon
```

| Hook event | Session state |
| --- | --- |
| `SessionStart` (not after compaction) | idle |
| `UserPromptSubmit`, `PostToolUse` | working |
| `Notification` (permission or elicitation prompt) | blocked (input needed) |
| `Stop` | done |
| `SessionEnd` | record removed |

A record holds the session ID, state, working directory, transcript path,
and the session process plus its ancestors (PID and start time). Prompts,
messages and tool input are never stored. The provider polls the records
twice a second and:

- shows only sessions whose recorded ancestry still runs and reaches a Claude
  Desktop process, so `claude` in a terminal never marks the terminal icon;
- attributes them to the Claude Desktop main process, which owns the window;
- shows a turn as idle when its transcript's last record is a user
  interrupt (Esc does not fire `Stop`), or when nothing touched it for
  20 minutes;
- keeps a finished turn's done mark for up to 30 minutes after the session
  process exits and drops anything else whose process is gone.

Claude Desktop is recognized by a process named `Claude`, or by
`claude-desktop`/`claude_desktop`/`Claude Desktop`/AppImage paths in its
executable or command line (Electron builds such as `claude-desktop-debian`).
The lowercase `claude` CLI binary never counts.

## Limits

- Only Claude Code sessions run hooks. Ordinary Claude chat replies in the
  desktop app have no hook and do not animate the icon.
- The marks are dock-only; there is no sidebar widget, and rows in the hover
  preview do not jump to a specific session.
- Hooks are loaded when a session starts; sessions already open before
  `hooks install` stay unmarked until restarted.
