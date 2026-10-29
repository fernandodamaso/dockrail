# Claude Desktop sessions on the dock and sidebar

With `dockClaudeIndicators` enabled, the Claude Desktop dock icon and its
sidebar window row show the same agent marks as Herdr and T3 Code: a working
spinner while a session is running, an input-needed mark while it waits on a
permission prompt or asks you a question, and a done mark until you open that
session in Claude Desktop. The sidebar also lists each session that needs
attention under the Claude window row; see
[Sidebar and clicking](#sidebar-and-clicking).

Claude Desktop does not publish session state itself. Its Claude Code
sessions (the Code tab) do run Claude Code hooks, so Dockrail installs a few
hooks that record each session's state locally.

## Setup

```sh
dockrail claude hooks install
dockrail config set dockClaudeIndicators true --json
```

Then start a new Claude Desktop session (or restart the app) so it loads the
hooks. The sidebar uses the same setting; it needs no separate configuration.
`dockrail claude hooks status [--json]` shows whether the hooks are
installed and how many session records exist; `dockrail claude hooks
uninstall` removes only Dockrail's hook entries.

After you update Dockrail or switch install modes (source bundle, `--cli-only`
or the Omarchy plugin), run `dockrail claude hooks install` again, then start
a new Claude Desktop session. Newer releases add hook events (for example
`PreToolUse` for Claude's questions), and sessions already running keep the
hook commands they started with, so a re-run only fixes new sessions.

Each installed command runs
`${XDG_DATA_HOME:-~/.local/share}/dockrail-cli/hooks/dockrail_claude.py`, a
CLI-owned copy that survives `install.sh` in either mode, `omarchy plugin
update` and `dockrail dev use/reset`. `hooks install` also refreshes that copy,
so it repairs an install whose old commands pointed at a checkout or plugin
path. `hooks status` checks that the script exists at that path, so a missing
script or commands pointing elsewhere report `installed: false` instead of a
silently dead hook.

`hooks install` edits `${CLAUDE_CONFIG_DIR:-~/.claude}/settings.json`,
keeping every other key and every hook you added yourself, and is safe to run
again. It refuses to touch a file that is not valid JSON. Each hook command
ends in `|| true`, so a removed Dockrail install can never block a prompt.

## Data path

```text
Claude Desktop -> [disclaimer wrapper] -> claude (Claude Code session)
  -> hook: dockrail claude hook
  -> ${XDG_RUNTIME_DIR}/dockrail/claude/sessions/<hash>.json
     (fallback ${XDG_STATE_HOME:-~/.local/state}/dockrail/claude/sessions)
  -> provider/claude/bin/dockrail-claude-provider
  -> components/DockHerdrService.qml (third instance)
  -> components/DockAgentSourceMux.qml -> dock icon and sidebar window row

${XDG_CONFIG_HOME:-~/.config}/Claude/claude-code-sessions
  -> provider/claude/bin/dockrail-claude-provider
     (session names, Desktop session IDs and archive/focus times only)

sidebar, hover-preview or dock context-menu session row
  -> focus-agent -> raise the Claude Desktop window
  -> claude://code/continue?session=<Desktop session id>
```

| Hook event | Session state |
| --- | --- |
| `SessionStart` (not after compaction) | idle (clears soft input needed) |
| `UserPromptSubmit` | working (clears input needed, hard or soft, and any open prompt) |
| `PostToolUse` | working; also answers an open prompt, which restores the state before it |
| `PreToolUse` for `AskUserQuestion` | input needed until you answer |
| `Notification` (permission, elicitation or agent input prompt) | input needed until the next completed tool call |
| `Stop` | done, or soft input needed if the turn ends with a question; input needed while a prompt is still open; a turn that ends while background agents still run stays working until they finish |
| Subagent `PostToolUse` after a finished turn | working again, since background work is still running |
| `SessionEnd` | record removed |
| Subagent `PostToolUse` while a prompt is open | answers it: back to the state before the prompt |
| Any other subagent event | keeps a working session fresh, nothing else |

A `Stop` whose end-of-turn summary asks you a question sets a softer
input-needed state. It clears when you open the session in Claude Desktop or
send the next prompt. Every end-of-turn summary resets it, and a new or
resumed session clears it. Permission prompts, elicitation prompts and
AskUserQuestion stay input needed until you answer.

Claude Code's Notification hook does not say which agent a prompt belongs to,
so a subagent's permission or elicitation prompt arrives as an ordinary prompt
and marks the session input needed. The next completed tool call, from Claude
or from a subagent, means the prompt was answered. The session then returns to
the state it had before the prompt: working, a finished turn (done), or the end
of a turn that asked you a question. A background agent that finishes after
the main turn therefore shows done once its prompt is answered. A `Stop` while
a prompt is still open keeps the session input needed until that prompt is
answered. Other subagent events only keep a working session fresh, so a long
background agent does not make it look idle. They never otherwise change state.

Known limit: one session tracks one open prompt. Because Claude Code does not
say which agent asked, a completed tool call from another agent can clear a
prompt early, and the session may then show working while an agent still waits.

Subagent events (hook input with `agent_id`) never remove the record and never
change the question you were asked.

A record holds the session ID, state, working directory, transcript path,
and the session process plus its ancestors (PID and start time). Prompts,
messages and tool input are never stored. Hook updates for one session are
serialized with a per-session lock file next to its record, removed on
`SessionEnd`, when the lock is available within 2 seconds. The provider polls
the records twice a second and:

- shows only sessions whose recorded ancestry still runs and reaches a Claude
  Desktop process, so `claude` in a terminal never marks the terminal icon;
- attributes them to the Claude Desktop main process, which owns the window;
- hides a turn as idle when its transcript's last record is a user interrupt
  (Esc does not fire `Stop`), or a working turn nothing touched for 20
  minutes;
- keeps a finished turn's done mark until you open the session in Claude
  Desktop. When the session process exits, its record is dropped, including
  one that needs input. Only a done mark outlives the process, for up to 30
  minutes, and only while every recorded ancestor up to Claude Desktop is
  still running.

Claude Desktop is recognized by a process named `Claude`, or by
`claude-desktop`/`claude_desktop`/`Claude Desktop`/AppImage paths in its
executable path or program name (argv[0]), or in the app path a shared
`electron` runtime is started with; later arguments are ignored, also when
Chromium joins the command line into one argument (Electron builds such as
`claude-desktop-debian`). The lowercase `claude` CLI binary never counts.
Electron helpers with `--type=` and launcher wrappers in the app's
`resources/` directory (such as `disclaimer`) are skipped when attributing a
session.

## Sidebar and clicking

The sidebar's Claude Desktop window row shows the same marks as the dock icon,
under the same visibility rule described below. Under that row Dockrail lists
one row per Claude Code session that needs attention. Each row is titled with
the session's name from Claude Desktop, or with its folder name when Claude
Desktop has no name.

A session needs attention while it is working, needs input, or is done and
you have not opened it since it finished. A soft input-needed mark (a question
at the end of a turn) counts only until you open the session or send the next
prompt. Idle sessions, done or soft input-needed sessions you have opened in
Claude Desktop (its `lastFocusedAt`) and archived sessions are hidden from the
sidebar and from the dock icon's marks.

Clicking a session row in the sidebar, in the dock hover preview or in the
dock context menu raises the Claude Desktop window and opens that session with
`claude://code/continue?session=<Desktop session id>`. If Dockrail cannot find
the Desktop session id for a session, the click only raises the Claude window.
Clicking the Claude window row itself raises the window.

Session names and Desktop session IDs come from the Claude Desktop files under
`${XDG_CONFIG_HOME:-~/.config}/Claude/claude-code-sessions`. The provider
reads only `cliSessionId`, `sessionId`, `title`, `isArchived` and
`lastFocusedAt` from them. Prompts and messages are never stored or emitted.

## Limits

- Only Claude Code sessions run hooks. Ordinary Claude chat replies in the
  desktop app have no hook and do not animate the icon.
- There is no Claude sidebar Widget. The marks and session rows belong to the
  Claude window row. A session row opens its session only when Dockrail can
  find that session's Desktop session id; otherwise it raises the Claude
  window.
- Done marks clear when you open the session in Claude Desktop. When Dockrail
  knows the session's Desktop id, focusing the Claude window does not clear
  them, unlike Herdr and T3 Code. Sessions without Desktop metadata follow the
  Herdr and T3 Code rule, so focusing the Claude window clears their done
  marks. Claude Desktop records a session as opened when you switch to it, so
  a session that finishes while you are already viewing it keeps its done mark
  until you switch away and back.
- The collapsed sidebar rail has no Claude session rows or counters, as with
  Herdr and T3 Code.
- Hooks are loaded when a session starts; sessions already open before
  `hooks install` stay unmarked until restarted.
