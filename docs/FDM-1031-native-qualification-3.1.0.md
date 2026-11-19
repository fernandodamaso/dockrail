# FDM-1031 SET-LOCAL — native Settings qualification for Dockrail 3.1.0

Native qualification of the Dockrail 3.1.0 release candidate (PR #176) on the
owner's Omarchy/Hyprland desktop, driven with `dockrail dev use` and Hyprland
IPC. Supersedes the partial run recorded in
`docs/FDM-1031-native-qualification.md`.

## Verdict

**Conditional pass.** The Settings surface behaves as designed on the release
candidate, but the documented local gate was red on this machine: four
`SettingsFeatures` QML tests failed on Qt 6.12 while Headless CI passed on its
older Qt. The cause was isolated, fixed without adding behavior, and re-tested
(PR #177). The release candidate is qualified **for the settings surface**; the
gate is green only once that fix is in the branch being shipped.

## Exact SHAs

| Item | SHA |
| --- | --- |
| Base (`origin/main`) | `794f4c4c20e26433e2db1e438239057ead9226c0` |
| Release candidate tested (`origin/release/fdm-1253-dockrail-3.1.0-candidate`, PR #176) | `147fda421ab4d99a88a9a1b2cd86c5e322ece9b6` |
| Gate fix branch (`fix/fdm-1031-features-fixture`, PR #177) | `c569d8279b1b9de725619d8e94919a0942bbdd45` |

## Environment

| Item | Value |
| --- | --- |
| Omarchy | `omarchy 4.5.0-3` (`/usr/share/omarchy/version` = `4.0.0.alpha`) |
| Hyprland | `0.56.2-4` |
| Quickshell | `0.3.2.r7.g2b4501a-1` (`0.3.2`, revision `2b4501a282689792b62e94f3fb30d8f512324fe6`) |
| Qt | `qt6-base 6.12.0-3` |
| Herdr | `herdr-app 0.1.15`; `herdr-core serve` running |
| hypruse | `0.14.1` |
| Monitors | `DP-1` (1920×1080, left, **sidebar** at 283 px) + `HDMI-A-1` (1920×1080, right, **classic dock**) |
| Live host | plugin mode, one Quickshell shell process, one Dockrail host |

Tests ran on `DP-1` workspace 1 and on `HDMI-A-1` workspace `Work`, at the
owner's instruction.

## Automated gate at `147fda4`

| Check | Result |
| --- | --- |
| `omarchy plugin validate .` | pass |
| `bash -n` (install/uninstall/scripts/checks) | pass |
| `py_compile` (`dockrail_paths.py`, `dockrail_migrate.py`) | pass |
| `tests/check_*.sh` (39 scripts) | 39/39 pass |
| `tests/test_*.mjs` (85 files) | 85/85 pass |
| `qmllint` (Omarchy-aware entry points) | pass, warnings only (pre-existing unqualified-access style) |
| `git diff --check` | pass |
| `qmltestrunner -input tests` (Qt 6.12) | **688 passed, 4 failed** |
| `qmltestrunner` on `origin/main` (`794f4c4`), same Qt | **same 4 failures** |

The four failures are `SettingsFeatures`: `test_badges_are_independent_of_switches`,
`test_herdr_appends_and_removes_without_reordering`,
`test_mixed_switch_commits_one_atomic_patch`,
`test_rejected_write_does_not_mutate_requested_state` (`Actual: unavailable`).
They are not introduced by the release branch.

After PR #177 (same Qt, same machine): `692 passed, 0 failed`, matching the
692 recorded by Headless CI on the same candidate.

## Live qualification

### Entry points and anchoring

| Entry point | Result |
| --- | --- |
| `dockrail settings` (CLI → `dockrail-settings open`) | opens the single panel on the focused monitor |
| IPC `dockrail-settings open` / `close` / `toggle` | opens, closes, and reports the resulting state |
| Sidebar gear (`DP-1`) | opens anchored beside the 283 px sidebar, fully on screen |
| Classic dock → Dock Controls → *Dockrail Settings…* (`HDMI-A-1`) | opens on the dock's monitor; the other monitor only receives the dismissal surface |
| Keybinding | not bound on this machine; the keybinding route is the same IPC target above (`use_bind` not exercised) |

One panel instance only: the monitor that owns the panel carries
`omarchy-keyboard-panel`; the other carries `omarchy-keyboard-panel-dismiss`.

### Keyboard and focus

- `j`/`k` moved the section selection (Features → Apps → Features).
- `Tab` switched the focus pane; `j` then moved the section cursor and
  `Space`/`Enter` activated the selected target (this is how
  `launcherBadgeMode` was toggled during the run; restored afterwards).
- `Esc` from the section pane closes the panel; from the search field it first
  clears/leaves search.
- Clicking outside the panel dismisses it.
- The panel takes the keyboard grab while open; synthetic keys are delivered to
  the panel layer, never to the window underneath.

### Features and readiness

Panel badges matched `dockrail doctor` exactly on this machine:

| Feature | Doctor | Panel |
| --- | --- | --- |
| Chrome | `degraded` / runtime `limited` (DevTools not reachable on `localhost:9222`) | **Limited** |
| Coding agents (Herdr) | `missing` (not on `PATH`) | **Not set up** |
| Launcher badge counts | `ready` | **Ready** |
| Terminal agent launchers | `ready` (“7 of 8 found on this computer”) | **Ready** |

The Chrome aggregate shortcut was toggled off and on from the panel. Both
`browserProfileBadgesEnabled` and `sidebarBrowserTabsEnabled` changed in one
write and read back `persisted:true`; readiness badges were unaffected by the
switch, as designed.

### Save and error states (forced for real)

- **Not saved / Retry (E_PERSISTENCE)**: `chmod 444 dock.json`, then toggled
  *Show Trash*. The header switched to `Not saved · Retry`, the applied live
  value stayed visible, and the host reported
  `writeState:error`, `persisted:false`,
  `Settings changed for this session, but could not be saved… Permission denied`.
  After `chmod 644`, **Retry** cleared the error and persisted
  (`writeState:idle`, `persisted:true`).
- **Broken JSON → read-only**: `{bad json` in the live file produced
  `loadState:invalid` (`SyntaxError`) and the panel showed
  `Read-only · Configuration is invalid. Repair it outside Settings before editing.`
  with the last-good values, not defaults. Restoring the original bytes cleared
  read-only automatically; the restored file is byte-identical (`sha256`
  `345c69d8…ae682`).
- **Changed elsewhere / E_STALE**: with a draft in Apps › Advanced ›
  *App launcher command*, a CLI write to the same key produced
  `Changed elsewhere. Reload or keep editing.` with `Save / Reload / Keep
  editing / Reset`; the draft was preserved. **Reload** adopted the newer value
  and cleared the conflict.

### Theme

Switched Tokyo Night → Catppuccin Latte while the panel was open. The panel
re-rendered with the light tokens (sampled panel background
`rgb(240,241,245)`), so colour tokens follow the live theme without reopening.
Restored to Tokyo Night.

### Multi-monitor

Layout › Displays lists both monitors with `Default | Classic dock | Sidebar`.
Moving `HDMI-A-1` from classic to sidebar wrote
`presentationModeByMonitor` and took effect immediately; the panel anchored to
the removed classic dock closed with it. Restoring the classic mode restored the
dock and the original configuration.

### One editing slot

With the *Change Icon* dialog open for T3 Code, opening Settings closed the icon
dialog and left a single editing surface; the reverse order (Settings open, then
context menu → Change Icon) is blocked because the first click outside the panel
is consumed by the dismissal surface and closes Settings.

### Single dock / single host

One Quickshell process owns one Dockrail host and one dock per presentation.
No duplicate browser-profile or T3 provider appeared during the run.

## Defect found and fixed

**Settings feature shortcuts were unusable on Qt 6.12 (gate red).**
Qt 6.12 hands arrays that crossed a QML `var` property boundary to JavaScript as
`[object V4Sequence]`: indexed access, `length`, `slice`, `filter`, `concat` and
`indexOf` work, but `Array.isArray()` is `false`. `DockSettingsFeaturesModel`'s
`Array.isArray(feature.keys)` guard therefore rejected the schema metadata and
`shortcutState()` returned `unavailable`.

Fix: a `list()` normalizer used by `desired()`, `shortcutState()` and
`agentSummary()`. No behavior change for ordinary arrays; no feature added.
Delivered in **PR #177** (`fix/fdm-1031-features-fixture`), targeting the
release branch. The same defect exists on `main` and must land there too.

## Observations (not blocking)

- After an IPC `toggle` that relocates the panel to the newly focused monitor,
  one run left the panel visible while `toggle` reported `closed`; clicking
  *Close* dismissed it. Not reproduced afterwards; recorded as a transient
  state desync.
- The dismissal surface consumes the first click on another monitor, so a dock
  action needs a second click while Settings is open.
- A live host update from the CLI is reflected immediately, and
  “Changed elsewhere” is shown when a row is in an active draft; with no draft,
  the value updates without the label.
- `dockrail doctor` also reports `cliFreshness degraded` because the installed
  CLI client predates the running plugin. Not a Settings finding.

## Not performed (explicit limitations)

- **Monitor hotplug** and the **one-monitor view** were not exercised: both
  require disabling/physically unplugging a monitor on the owner's working
  desktop, which would move their windows and interrupt their session.
- **Keybinding entry point**: no Dockrail Settings keybind is configured on this
  machine; only the identical IPC target was exercised.
- **`c` clipboard copy** was not exercised (would overwrite the owner clipboard).
- **Search typing**: pressing `/` focused the search field (caret visible), but
  synthetic keystrokes did not enter text in two attempts, while the same
  synthetic typing worked in the Advanced text field. Not reproduced by hand;
  needs a manual check before release.
- Standalone (`shell.qml`) smoke was not launched: it would create a second
  dock beside the live plugin.
- Several early screenshots were purged by the capture tool; the surviving
  evidence is in `docs/evidence/fdm-1031/`.

## Environment restoration

- `dockrail dev reset` restored the installed copy (`main @ f0eca6d`).
- The owner's original dev link was re-applied:
  `io.github.fernandodamaso.dockrail → /home/admin/Projects/dockrail`
  (`fix/monitor-card-transparency @ b9f1db9`).
- `~/.config/dockrail/dock.json` is byte-identical to the pre-run backup
  (`sha256 345c69d8a51c7de73cac1f1da37ccf66cd6d54954746bc57e71d79a29ffae682`):
  `autoHide:false`, `iconSize:24`, `launcherBadgeMode:"automatic"`,
  `presentationModeByMonitor {DP-1:sidebar, HDMI-A-1:classic}`, original pinned
  order, `showTrash:false`, `controlCommand` restored.
- One Quickshell process, one dock layer per presentation, no panel layers left
  mapped.
