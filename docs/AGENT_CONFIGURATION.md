# Configure Dockrail through its CLI

**Agent configuration interface.** The CLI remains the complete configuration interface for AI coding agents and automation. Dockrail 3.1 has an accepted Settings-panel design for people, recorded in `docs/SETTINGS.md`, but the Settings UI is not shipped yet. When implemented, Settings must submit the same host intents through the single host writer and report the same requested/effective, applied and persisted outcomes as the CLI. Temporary preference previews and alternate writers remain forbidden; ordinary window previews, the app picker, menus, drag reordering, workspace/window actions, auto-hide and Trash remain.

Never edit a deployed checkout, scrape the UI, launch a second dock, restart Omarchy, install a provider, change desktop/theme files, or silently fall back to raw `dock.json` writes for configuration. A missing command in an older host is a compatibility/unsupported-feature result, not permission to bypass its writer. Source work is appropriate only for an explicitly requested unsupported feature or an evidenced defect, in a source branch under its owning issue.

## Five-step change workflow

1. **Discover the host and current state.** Use status/doctor/schema/get below. Stop on ambiguous or incompatible targeting; use an exact discovered instance. Read `data.configPath`, not a path inferred from the working directory or client environment.
2. **Limit the intended keys or identities.** Read the relevant schema and requested/effective values. Preserve unknown keys, pins, hidden membership, artwork and compatible legacy values. Do not turn a narrow request into a preference reset or whole-array replacement.
3. **Export to a new backup, then dry-run a minimal patch.** Record original touched values and the desired new values. A backup is a reference snapshot, not a later whole-file restore command.
4. **Apply once through the CLI.** Apply the same payload only after inspecting its diff. The host recomputes against latest state; the dry run is not a lock. Keep explicit selectors on every command.
5. **Read back and report the outcome.** Compare requested and effective values, inspect `applied`, `persisted`, `writeState`, errors and warnings. Restore only touched values after fresh readback when rollback is requested. Do not overwrite intervening edits blindly.

```sh
dockrail status --json
dockrail doctor --json
dockrail config schema --json
dockrail config get --json
dockrail config get hoverGlowOpacity --effective --json
```

When needed, append `--runtime plugin` or `--runtime standalone` and `--instance ID` using an actual returned ID, not a placeholder. Global control options work before or after the command. `runtime.instanceId` is the process ID for this host lifetime; `runtime.quickshellId` is the native qs ID. Both are exact selectors. Rediscover after restarts. The client never picks the newest instance. Changing `SMARTDOCK_CONFIG` or XDG variables in the client does not retarget a running host.

Bare `dockrail`, `help` and `agent-guide` work offline and create no directories. Automatic `config schema` may return `source: bundled` only when no matching host exists, never for explicit-target failures, ambiguity or malformed protocol. Bundled metadata is not the user's settings. All mutations and exports require a host.

## Backup and apply a related patch

The following example changes placement, size, visibility and Trash together; use it only when those changes are intended. Save the JSON block to a new `patch.json` under the private change directory, or supply the same bytes through explicit `--stdin`.

```sh
umask 077
change_dir="$(mktemp -d "${TMPDIR:-/tmp}/dockrail-change.XXXXXX")"
dockrail config export --output "$change_dir/requested-before.json" --json
```

<!-- recipe: safe-batch -->
```json
{"position":"bottom","iconSize":36,"autoHide":true,"showTrash":false}
```

After placing the intended JSON in `$change_dir/patch.json`:

```sh
dockrail config apply --file "$change_dir/patch.json" --dry-run --json
dockrail config apply --file "$change_dir/patch.json" --json
dockrail config get --json
dockrail config get --effective --json
dockrail status --json
```

Inspect dry-run `data.changedKeys`, `diff`, full proposed `requested` and `effective`. Dry run has `applied: false`, `persisted: false`; it neither creates a defaults file nor increments revision. New input must be a UTF-8 JSON object, at most 64 KiB, without duplicate keys, non-finite values, unknown new keys or invalid types/ranges. One invalid value rejects the whole batch. There is no implicit stdin or offline writer.

For one key, `dockrail config set hoverGlowOpacity 0.72 --json` parses the runtime-declared type and sends a minimal patch. Booleans require lowercase true/false; strings are literal; arrays/maps are JSON and replace that key. The requested 0.72 remains 0.72 while the effective value is 0.70. Use primitive app/icon commands rather than editing an old collection snapshot.

## Tested preference recipes

Save only the desired block as a patch, then use the backup/dry-run/apply/readback workflow above. These are examples, not presets applied automatically.

### Theme-linked surface

Pair colors with enable flags. Tokens remain live; unknown renderer-resolved values do not justify replacing a token.

<!-- recipe: theme -->
```json
{"backgroundColorEnabled":true,"backgroundColor":"@menu.background","borderColorEnabled":true,"borderColor":"@accent","backgroundOpacity":0.85}
```

Colors accept empty, `#RRGGBB`, Qt `#AARRGGBB` (alpha first), or symbolic tokens. Effective token/theme colors and theme-owned border width are null with warnings because the host does not report renderer-resolved values. Disable only a paired Enabled flag to restore inheritance while retaining the stored override.

### Calmer dock motion

This changes Dockrail motion, not compositor-wide animations. The attention badge can remain static.

<!-- recipe: calmer-motion -->
```json
{"magnification":1,"hoverGlowEnabled":false,"interfaceAnimationsEnabled":false,"urgentWindowAnimationEnabled":false}
```

### Horizontal workspace cards

The example explicitly moves to the bottom; do not move a left dock without permission. A requested grouped layout renders flat on the left without being erased. Grouped-card monitor scope is separate from flat running-window scope.

<!-- recipe: workspace-cards -->
```json
{"position":"bottom","workspaceLayout":"grouped","workspaceMonitorScope":"current-monitor"}
```

## Restore and order applications

First discover actual IDs and pinned/hidden membership. The block assumes the returned IDs are `code` and `org.gnome.Nautilus`, and the latter is already pinned; substitute the actual exact identities, not display names. Run only the intended operations. Pin does not show a hidden app, so explicit show is separate.

<!-- recipe: applications -->
```sh
dockrail apps list --query 'Editor' --json
dockrail apps list --pinned --json
dockrail apps list --hidden --json
dockrail apps pin code --json
dockrail apps show code --json
dockrail apps move code --before org.gnome.Nautilus --json
```

Discovery uses the host's native desktop catalog, not a new desktop-file scan. Rows include `id`, `name`, `available`, `pinned`, `hidden`, `pinnedIndex`. Query searches ID/name text; mutations match exact IDs after trimming, case folding and optional `.desktop` removal. Unsafe/sentinel/prototype-sensitive IDs are rejected. Stored spelling/order and unavailable pins/hidden IDs survive.

Membership operations are idempotent. `apps hide ID` hides without closing or unpinning; `apps unpin ID` removes pin membership without hiding running windows. `apps show --all` clears all hidden membership and needs explicit broad intent. Move needs two different pinned IDs and exactly one before/after anchor, preserving other relative order including hidden/unavailable entries. Re-read that order before an intentional rollback; do not replay an obsolete array.

## Set, refresh and restore per-app artwork

Discover the actual app ID first. The following `code` ID and relative path are examples; confirm the intended local PNG/SVG exists and belongs to the intended app. Use a stable path outside the plugin checkout. Set, reload and reset are shown together for a test sequence; reset is a deliberate removal, not a required step after setting an icon.

<!-- recipe: icons -->
```sh
dockrail icons list --json
dockrail icons set code './Pictures/My Ícone.svg' --json
dockrail icons reload code --json
dockrail icons reset code --json
```

The client resolves an ordinary relative path against its current directory; the shared host model validates absolute paths and supported local file URLs, preserving spaces/Unicode. Remote URLs, unsupported formats and invalid local URLs are rejected. Files are referenced in place, not downloaded/copied/imported; no `.desktop` or system theme edits occur. Shell expansion of an unquoted tilde or `$HOME` is distinct from file-URL parsing.

Set/reset updates only one canonical key against the latest map, preserving other entries and untouched legacy values. Preference reset preserves `iconOverrides` and `windowIconOverrides`. Bulk map replacement validates the entire map and rejects canonical duplicates. Missing/unreadable/corrupt files retain the requested mapping and fall back: custom → original desktop icon → generic executable → bundled theme-tinted `app-window` glyph. Custom artwork is not tinted. Main icons, preview metadata and picker rows share the mapping; identity, launch commands, screenshots, grouping, badges, Trash and action glyphs do not change.

For a per-window rule, first confirm the raw Wayland app ID from the live compositor.
Ghostty's raw app ID in the supported Omarchy environment is
`com.mitchellh.ghostty`. Run this only against the selected isolated Dockrail host:

<!-- recipe: window-icons -->

```sh
dockrail icons list --json
dockrail icons set com.mitchellh.ghostty './Pictures/solar.svg' --title-pattern '*solar*' --json
dockrail icons list --json
dockrail icons reset com.mitchellh.ghostty --title-pattern '*solar*' --json
```

The title rule affects every current/future Ghostty window whose full title matches
`*solar*`; it is not an identity for one window instance. Reset removes only that
rule and may reveal another matching rule or a lower-priority icon candidate. Do not
replace invalid/empty/oversized titles with broad `*`; the **Change Icon…** dialog
surfaces validation instead.

The dock watches referenced artwork files and refreshes automatically after same-path edits; explicit reload remains available for compatibility or forcing a refresh and advances the shared artwork revision without saving settings. Other mapped icons can refresh too. Same-source set also requests fresh bytes without a redundant settings write; repeated reset is a true no-op. `reloaded: true` means requested, not decoded; `applied`/`noop` describe settings, so reload can report `applied: false`, `noop: true`, `reloaded: true`. Every successful icon response has `renderVerified: false`. Verify cache invalidation, image decoding and multi-monitor redraw on the actual desktop; headless tests cannot establish those results.

## Persistence, recovery and rollback

Requested, effective, saved and rendered are separate. Read `loadState`, `loadPending`, `writeState`, errors and `persisted`. Missing configuration does not mean defaults were saved. Invalid JSON retains last-good settings and blocks mutations; repair deliberately instead of automatically overwriting it. Revision belongs to one host lifetime.

Cooperating writes use the host's one FileView writer: disjoint patches preserve each other; latest accepted same-key intent wins. A known pending load/write is refused. Unrelated pins, icons, hidden apps, extension keys and legacy values survive narrow changes. An identical patch does not hide an existing save failure.

A persistence error exits 4 and can leave `applied: true`, `persisted: false`. Inspect status; after the actual write problem is corrected, `dockrail config retry --json` saves the complete latest live snapshot without a new settings revision. Busy/invalid state exits 6. A timeout has unknown applied/persisted outcome: read status and affected values before deciding to mutate again. No unbounded retry loops.

Export writes a new owner-only plain JSON file and never overwrites a destination, follows a destination symlink, creates missing parents or aliases the live config. `exportWritten` concerns the snapshot; `sourcePersisted` concerns the live state. An unsaved snapshot is not evidence of a saved dock. Unknown exported keys are not accepted as new patch keys. Roll back only touched supported values after checking fresh state; when a prior value is a legacy alias or an absent key, inspect schema and report any normalization/absence limitation instead of writing raw bytes or pretending exact restoration.

`config reset KEY` resets only that key. `config reset --preferences` preserves pins, hidden apps, iconOverrides, windowIconOverrides, margin and unknown extensions, but resets other preferences **including `controlCommand`**. Do not use it for narrow requests. `controlCommand` is executable-on-use configuration: quote it literally and **never execute it to validate**. The launcher action may execute it later. Pointer `close` can close all grouped live windows on use. Change such settings only for explicit intent.

## Machine contract and installation

`--json` emits one object with `apiVersion: 1`, `ok`, `data`, `warnings`, and `error.code/message` on failure. Exit codes: 0 success; 2 usage/validation; 3 absent/ambiguous host; 4 persistence/export failure; 5 transport/protocol/timeout; 6 busy/invalid config. See [CLI_REFERENCE.md](CLI_REFERENCE.md) for exact fields/codes and [CONFIGURATION.md](CONFIGURATION.md) for all defaults/dependencies. Both ship beside this offline guide, together with the separate [desktop verification runbook](CLI_RUNTIME_CHECKS.md); installing that document does not run any desktop checks.

```sh
bash ~/.config/omarchy/plugins/io.github.fernandodamaso.dockrail/install.sh --cli-only
dockrail doctor
```

For an Omarchy plugin install, the installed plugin directory is already the checkout. The command installs launchers in `${XDG_BIN_HOME:-$HOME/.local/bin}` and a small client record under `${XDG_DATA_HOME:-$HOME/.local/share}/dockrail-cli`. The adapter, schema, defaults and offline docs are read from the plugin directory each time, so `omarchy plugin update` refreshes them automatically. A removed plugin produces a reinstall message. Use `bash ~/.config/omarchy/plugins/io.github.fernandodamaso.dockrail/uninstall.sh --cli-only` to remove the client record and launchers.

From a separate source checkout, `bash ./install.sh --cli-only` keeps the copied bundle behavior; rerun it explicitly to refresh that copy. Full standalone installation keeps its own bundle. `${XDG_BIN_HOME:-$HOME/.local/bin}/smartdock` remains a compatibility command, and legacy `smartdock-cli` discovery is retained only for pre-cutover bundles. Client-only installation/removal does not install/start a dock, user config, autostart, agent launchers or provider. It coexists with standalone in either order; removal retains the launchers while another bundle owns them. The canonical client takes precedence over standalone and legacy bundles.

The adapter uses standard-library Python and bounded argv subprocesses: `qs list --all --json` and exact `qs ipc --pid PID call -- smartdock request PAYLOAD`. It does not use the Omarchy wrapper's newest-instance selection, guess wrapper flags or implement sockets. Standalone lifecycle commands are explicit and separate, never a way to configure a plugin. Check Omarchy IPC/FileView/theme/image/monitor behavior on the actual installation. This guide does not authorize deployment or claim those checks passed.

## Sidebar configuration

Before a sidebar request, discover `presentationMode`,
`presentationModeByMonitor`, `sidebarEdge`,
`sidebarMonitor`, `sidebarExpandedWidth`, `sidebarCollapsed`,
`sidebarCollapsedByMonitor`, `sidebarBrowserTabsEnabled`, and `sidebarWidgets` through the runtime
schema. They may be unavailable in the installed version. Only change the
settings the user requested; do not update or restart the desktop implicitly.

Use the sole host writer and change only the requested sidebar field. Never copy
classic values into sidebar preferences, rewrite classic `workspaceGroups` to fold
apps, or save a topology-clamped width. Collapsing preserves expanded width; app
folds are host-session state. Keep the saved connector on disconnect. A
per-monitor presentation change is one explicit whole-map object patch:
preserve the other connectors' entries, dry-run first, and read back
`data.presentation.perMonitor` (or `modeByMonitor`) to confirm each
connector's resolved mode and `override`/`inherited` source; the background
mode gesture writes one connector's entry and never the global default.
Inspect
requested and effective values plus `data.presentation` for placement and geometry.
Do not infer rejection from `E_BUSY` when `data.applied` is true, or claim durability
without persisted readback. Desktop checks and the runnable production fixture
are documented in `docs/SIDEBAR.md` in the source checkout.

For widget requests, read the selected host's `sidebarWidgets.registeredIds`; do not
assume clock/Herdr/Todoist IDs or inject test IDs. Available providers depend on
the installed host. New ordered arrays must be registered/unique; never store provider paths,
commands, tokens or credentials here. Unknown imported IDs stay requested but
unavailable and are not executed. Preserve them on unrelated changes; do not
repair/delete them silently. Provider readiness/authentication is distinct from
typed write validation. Inspect bounded `data.presentation.widgets` diagnostics
without logging task/window content. Source API: `docs/SIDEBAR_WIDGETS.md`. Verify Widget scrolling, input and popups
in the actual Omarchy session.
