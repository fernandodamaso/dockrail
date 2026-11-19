# Plan: stable Claude hook script path

Status: ready to implement. Base: `main` @ f11a75b (PR #159 merged).

## Problem

`dockrail claude hooks install` writes hook commands into
`~/.claude/settings.json` that run
`python3 -B <path>/dockrail_claude.py hook >/dev/null 2>&1 || true`.
`<path>` is `Path(__file__).resolve()` of whichever copy ran the install
(`scripts/dockrail_claude.py: hook_command()`).

That path is not stable:

- Installs from a source checkout (`bash ./install.sh --cli-only`) put a copy at
  `~/.local/share/dockrail-cli/scripts/dockrail_claude.py`. Hooks installed then
  point there.
- Installs from the Omarchy plugin dir (`install.sh --cli-only` inside
  `~/.config/omarchy/plugins/io.github.fernandodamaso.dockrail`) take the
  plugin-mode branch of `install.sh` (around lines 116-119): it runs
  `rm -rf "$client_dir"` and writes only `.plugin-dir` + `uninstall.sh`. That
  deletes the script the hooks point at.
- Under `dockrail dev use`, the plugin slot is a symlink to a worktree, so
  `.resolve()` bakes the worktree path into the hooks.
- Because every command ends in `|| true`, a missing script fails silently.
  The dock then shows the last saved state forever, e.g. a stale "working"
  spinner. `dockrail claude hooks status` still reports `installed: true`.
- Running Claude Code sessions keep the hook commands they started with, so
  re-running install only fixes new sessions.

Observed on 2026-10-29: after a plugin-mode `install.sh --cli-only`, all hooks
failed from 13:59 until hooks were re-installed. They now point at the plugin
slot path, which works only until the next mode switch.

## Goal

1. Hook commands point at a path that survives both install modes,
   `dockrail dev use/reset` and `omarchy plugin update`.
2. `hooks status` reports a missing or stale script as not installed.
3. Existing broken installs are repaired by re-running
   `dockrail claude hooks install`.

## Design

Ship a stable hook entry point owned by the CLI client, written in **both**
install modes:

- `install.sh` installs `scripts/dockrail_claude.py` to
  `${XDG_DATA_HOME:-~/.local/share}/dockrail-cli/hooks/dockrail_claude.py` in
  both the bundle branch and the plugin branch (after the plugin branch's
  `rm -rf "$client_dir"`, re-create `$client_dir/hooks` and copy the file
  there). It is self-contained (stdlib only; see its docstring), so one file is
  enough.
- `hook_command()` always targets that stable path
  (`stable_hook_script(env)` -> `<XDG_DATA_HOME or ~/.local/share>/dockrail-cli/hooks/dockrail_claude.py`).
  It must not use `Path(__file__).resolve()`, so worktree and symlink paths
  never reach the hooks.
- `cmd_hooks("install")` also copies its own file (`Path(__file__)`) to the
  stable path, atomically (temp file plus `os.replace`, mode 0644, parent dir
  0755). That makes `dockrail claude hooks install` self-healing even if
  `install.sh` was skipped. Copy only when the content differs.
- Keep `HOOK_MARKER = "dockrail_claude.py"`, so uninstall still finds old
  entries that point at any path.

`hooks status --json` gains:
- `scriptPath`: the path in the installed commands (parsed from the command
  with `shlex.split`);
- `scriptExists`: whether that file exists;
- `scriptCurrent`: whether it equals the stable path and its content matches the
  running copy.

`installed` is true only if all events are present AND `scriptExists` AND
`scriptPath` == stable path. Human output prints a one-line hint when not
installed: `run: dockrail claude hooks install`.

`uninstall.sh` (client) and `dockrail claude hooks uninstall`: leave
`~/.claude/settings.json` cleanup to the existing `hooks uninstall`. Only
remove `dockrail-cli/hooks/` in `uninstall.sh` if it already removes the client
dir (check the current behaviour and keep it consistent).

Also update the copy in `scripts/smartdock_cli.py` / `scripts/dockrail` only
if they reference the client `scripts/` path for the hook. Grep for
`dockrail_claude.py`.

## Files

- `scripts/dockrail_claude.py`: `stable_hook_script()`, `hook_command()`,
  self-copy in install, status fields and `installed` rule.
- `install.sh`: install `hooks/dockrail_claude.py` in both branches; keep it
  compatible with custom XDG variables (AGENTS.md rule).
- `uninstall.sh`: only if needed, as above.
- `tests/test_claude_cli.py`:
  - hook_command never contains a resolved worktree path;
  - install copies the script to the stable path under a temp XDG_DATA_HOME;
  - status reports `installed: false` with `scriptExists: false` when the
    script is deleted, and when commands point at an old path
    (`~/.local/share/dockrail-cli/scripts/...` or a plugin path);
  - re-running install repairs both cases (commands rewritten, one entry per
    event, user hooks preserved).
- Tests covering `install.sh` (find them, e.g. `tests/test_dockrail_startup_contract.py`,
  `tests/test_cli_setup.py`, or grep `cli-only` in tests/): add a case that a
  plugin-mode `--cli-only` install leaves `dockrail-cli/hooks/dockrail_claude.py`
  in place, using temp XDG dirs only.
- `docs/CLAUDE_DESKTOP.md` and `docs/CLI_REFERENCE.md`: document the stable
  path; say that `hooks status` checks the script; after updating Dockrail or
  switching install modes, run `dockrail claude hooks install` again and start
  a new Claude Desktop session (running sessions keep their old hook commands).
- `CHANGELOG.md` Unreleased > Fixed: "Claude Desktop hooks no longer break when
  the CLI is reinstalled from the Omarchy plugin."

## Constraints (from AGENTS.md)

- Never edit the installed plugin checkout. Work on a branch from `main`, and
  deliver by PR per `docs/DELIVERY.md`.
- Never start a second dock. `./scripts/run` is not needed for this change
  (CLI and install only).
- Keep `install.sh`, `uninstall.sh` and `scripts/dockrail` compatible with
  custom XDG directory variables.
- Never touch the user's real `~/.claude/settings.json` or `~/.local/share` in
  tests. Use temp dirs and `CLAUDE_CONFIG_DIR` / `XDG_DATA_HOME`.

## Validation

```bash
python3 -B -m unittest tests.test_claude_cli -v
python3 -B -m unittest discover -s provider/claude/tests
for f in tests/test_*.py; do python3 -B -m unittest discover -s tests -t tests -p "$(basename "$f")" || echo "FAIL $f"; done
bash -n install.sh uninstall.sh scripts/dockrail scripts/run tests/check_window_actions.sh
python3 -m py_compile scripts/dockrail_claude.py
python3 -B -m unittest tests.test_cli_docs tests.test_user_facing_docs
git diff --check
```

## Rollout on the user's desktop (after merge)

1. `omarchy plugin update io.github.fernandodamaso.dockrail --yes` (`--yes`
   matters: without it the command waits on a prompt).
2. `bash ~/.config/omarchy/plugins/io.github.fernandodamaso.dockrail/install.sh --cli-only`
3. Back up `~/.claude/settings.json`, then run `dockrail claude hooks install`
   and `dockrail claude hooks status --json`. Expect `installed: true`,
   `scriptExists: true`, and `scriptPath` under `~/.local/share/dockrail-cli/hooks/`.
4. Start a new Claude Desktop session; check the sidebar row goes working then
   done or input needed.

## Out of scope / known follow-ups

- The `background_tasks` check on `Stop` is unverified against a real payload.
  The subagent-PostToolUse fallback carries the "working while background
  agents run" behaviour.
- Records whose hooks died mid-session keep their last state until that
  session closes (provider ages out working records after 20 minutes of no
  transcript activity).
