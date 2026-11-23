# Switch the desktop dock to a local version

For visual testing on your own Omarchy development desktop, no PR, merge, push,
or plugin update is needed. Install the client once from this checkout:

```bash
bash ./install.sh --cli-only
dockrail dev list
dockrail dev use /absolute/path/to/worktree
dockrail dev use my-local-branch
dockrail dev status
dockrail dev reload
dockrail dev reset
```

`use` links the existing Dockrail plugin slot to the chosen checkout and runs
Omarchy's normal shell restart to clear cached QML. The installed directory is kept
beside it under a hidden backup name, without editing its contents. Only one
dock runs, in normal plugin mode, with your usual windows, theme, and settings.
The selection persists across shell restarts and login until `reset`.

Existing worktrees include uncommitted edits. A branch that has no worktree gets
a detached checkout at its current commit under
New detached worktrees are created under `${XDG_CACHE_HOME:-~/.cache}/dockrail/dev-worktrees/`. Existing managed worktrees under the legacy `${XDG_CACHE_HOME:-~/.cache}/smartdock/dev-worktrees/` remain valid and are not relocated solely for the product rename. Running `use` again picks
up a branch's new commit. These checkouts are retained; manage them with ordinary
`git worktree` commands once they are no longer selected. `list` shows local
branches and worktrees from the checkout that installed the client; fetch remote
work yourself first if needed.

After edits, run `dockrail dev reload` to explicitly load the selected source.
The dock, top bar, and other shell plugins briefly restart; app windows and
workspaces stay in place. A plain plugin rescan can retain old compiled code.
The switcher requires one unambiguous Omarchy shell and checks the new dock by
exact PID after restarting. A failed switch restores
the previous source and attempts to reload it. `reset` restores the saved files
even if the candidate worktree was deleted or the shell is unavailable; if the
shell is down, restart it after restoring.

For older branches without the control CLI, startup is checked through the
Dockrail layer surface belonging to the new shell process. Normal configuration
commands still require a branch that supports the control CLI.

Your settings remain at the host's existing config path. The switcher does not
copy or rewrite them; settings changes you make while testing are real and
persist after switching back. A successful reload confirms a responding dock,
not that every visual interaction works.

**Reset before using `omarchy plugin update` or removing the plugin.** Those
Omarchy commands operate on the plugin path and could otherwise modify the
linked source checkout. Do not delete or switch branches inside a selected
worktree unless you intend to change the live dock. Use `dev use` for switching.

`omarchy plugin update` rewrites the installed plugin in place but does not
restart the shell, so the running dock keeps executing the previous QML until it
does. Run `omarchy-restart-shell` after the update, then confirm the shell
process started after the plugin files were written (`ps -o lstart= -C quickshell`
against the file modification time). Reloading the top bar or rescanning plugins
is not enough; published fixes look absent until the shell restarts.

Normal PR delivery rules still apply to merging changes into `main`. VM sessions
in `DEV_SESSIONS.md` remain available for isolated autonomous testing.
