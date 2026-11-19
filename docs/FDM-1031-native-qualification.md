# FDM-1031 SET-LOCAL native Settings qualification — partial run

Qualification gate on the owner's live Omarchy/Hyprland desktop. This is a
**partial** run: one defect (focused-monitor summon) was reproduced and fixed,
one report (sidebar-edge anchoring) was retracted as a false positive, several
sections are still placeholders at the tested SHA, and the visual review pass
was done with OCR and geometry instead of direct image inspection (see
*Limitations*).

## Exact-SHA and environment evidence

| Item | Value |
| --- | --- |
| Dockrail SHA | `73f60bcb18b70872e4812d26dddd2f5b1e69191e` (`main`, also the installed plugin head) |
| Installed plugin | `/home/admin/.config/omarchy/plugins/io.github.fernandodamaso.dockrail` @ `73f60bc` |
| Omarchy | `4.0.6-1` (`/usr/share/omarchy/version` = `4.0.0.alpha`) |
| Hyprland | `0.56.2-4` |
| Quickshell | `0.3.2.r7.g2b4501a-1` |
| Herdr | `0.9.1-2` |
| Qt | `6.12.0-3` |
| hypruse | `0.13.0` |
| Monitors | `DP-1` (Sidebar, left edge, **focused**) + `HDMI-A-1` (Classic, bottom) |

## Automated gate (this SHA)

- `bash -n` (install/uninstall/scripts/checks): **pass**
- `py_compile`: **pass**
- Structural guards (`tests/check_*.sh`): **pass** except
  `check_terminal_agent_assets.sh`, which fails only from an inherited
  `XDG_STATE_HOME` leaking the live migration dir into the sandbox; it passes
  with `env -u XDG_STATE_HOME` (known contamination, not a code defect).
- JavaScript model tests (`tests/test_*.mjs`, 77 files): **pass**
- Pure QML suite (`qmltestrunner`): **613 passed, 0 failed**
- `omarchy plugin validate .`: **pass**
- `qmllint`: **pass** (warnings only)
- `git diff --check`: **pass**

## Single dock / single host

One Quickshell shell process (`pid 107614`) owns one `DockHost`; the only
providers are the three expected ones (`smartdock-browser-profile-provider`,
`smartdock-herdr-provider`, `dockrail-t3-provider`) plus the Herdr helper. No
duplicate provider lifecycle or second dock.

## Entry points

| Entry point | Result |
| --- | --- |
| CLI `dockrail settings` | `opened:true`, panel layer appears — but on the **wrong monitor** (defect A) |
| IPC `dockrail-settings toggle` | opens/closes the single panel; same wrong-monitor behavior |
| Sidebar gear (DP-1) | opens the panel on DP-1 (correctly positioned; see Defect B retraction) |
| Dock Controls hamburger | not exercised this run (see *Limitations*); previously verified natively in FDM-1025/FDM-1026 |

## Defects reproduced

### Defect A — CLI/IPC focused-monitor summon opens on the wrong monitor (FIXED)

`dockrail settings` and `dockrail-settings toggle` are specified to open on the
focused monitor. With `DP-1` focused, a fresh `dockrail settings` opened the
panel on `HDMI-A-1` (classic). After the panel was opened once from the DP-1
sidebar gear (which sets the remembered connector to `DP-1`), subsequent CLI
summons followed `DP-1` — i.e. the summon follows the **last-anchored
connector**, not the **focused** monitor.

**Root cause (confirmed empirically):** `DockHost.focusedSettingsConnector()`
scans `Hyprland.monitors.values` for a per-monitor `focused` flag, but on
Quickshell 0.3.2 that flag is **never set** (`focused=false` for every monitor
even the focused one); the authoritative singleton `Hyprland.focusedMonitor`
correctly reports `DP-1`. A probe confirmed `monitors=[HDMI-A-1 focused=false,
DP-1 focused=false]` while `focusedMonitor=DP-1`. The scan resolves nothing on a
fresh summon, so the connector degenerates to `settingsConnector` (empty) →
`candidates[0]` (the classic dock).

**Fix:** `focusedSettingsConnector()` now prefers `Hyprland.focusedMonitor.name`
and keeps the monitor-list scan + remembered connector as fallbacks. Verified
headlessly (17 writer / 35 review / 7 host-writer QML cases and 77 JS files) and
live via `dockrail dev use`: with `DP-1` focused, fresh `dockrail settings` and
`dockrail-settings toggle` now open the panel on `DP-1`.

### Defect B — Settings panel renders off-screen from a left-edge Sidebar (FALSE POSITIVE, retracted)

An earlier capture during the panel's open animation suggested the panel card
was clipped on `DP-1` (left-edge sidebar, `sidebarEdge = left`). Re-testing with
a settled capture shows the panel renders **correctly** on `DP-1`, positioned
just right of the sidebar (`x ≈ 321`, fully on-screen, nav + Appearance section
both readable by OCR). The KeyboardPanel's `barPos === "left"` branch places the
card at `barW + gap`, which is correct. No code change is needed; the panel was
simply caught mid-fade in the first capture.

## Forced save/error states (live host, byte-exact restore)

- **Broken JSON → read-only**: wrote `{bad json` to the live `dock.json`;
  `dockrail status` → `loadState: invalid`, `loadError: SyntaxError`; `config
  get` reports "Invalid disk config; showing last-good live settings" and does
  not replace with defaults. Restored byte-exact (`sha256` match).
- **Read-only file → Not saved / Retry**: `chmod 444` then `config set iconSize 30`
  → `E_PERSISTENCE` ("Settings changed for this session, but could not be saved …
  Permission denied"); `writeState: error`, `persisted: false` (the applied live
  value is retained, matching the accepted Not-saved semantics). Restored
  permissions, value, and byte-exact file.
- **CLI round-trip**: `config set` → `config get` readback and `status`
  `persisted:true` confirmed; value restored afterward.

## Observations (not yet triaged)

- On save, the writer **reorders an unknown top-level key**. `dockClaudeIndicators`
  (not in `settings-schema.json`) moved from an early position to the end of the
  file after a successful `config set`. The value is preserved, only the position
  changes. `docs/SETTINGS.md` requires "unknown keys and collection order"
  preserved — top-level unknown-key position may or may not be in scope; flag for
  the owner to confirm.

## Not qualifiable at this SHA

The following sections are still `"This section is reserved …"` placeholders on
`main@73f60bc` and are implemented only on unmerged branches
(`origin/exec/fdm-1027-sidebar-widgets`, `origin/exec/fdm-1029-settings-apps`):

- **Features** (SET-06): feature shortcuts Off/Partly on/On, readiness match
  against `dockrail doctor`, launcher add/remove.
- **Apps** (SET-07): pinned/hidden apps, Chrome, Advanced `controlCommand`.
- **Search** (SET-08).

`dockrail doctor` was captured for reference: Sidebar ready, Herdr agents
missing (not enabled), Chrome ready, Launcher counts ready, Agent launchers
ready, CLI freshness degraded (CLI source differs from running install).

## Limitations

- **No image input in this session.** Screenshots are saved to disk
  (`/tmp/opencode/fdm1031/proof/`) but were verified through `tesseract` OCR,
  `hyprctl layers/clients` geometry, `dockrail` CLI readbacks, and ImageMagick
  pixel metrics — not by visual inspection.
- **Live seat contention**: the owner was actively using the desktop, so pointer
  interactions were kept minimal and the Dock Controls hamburger was not located
  reliably enough to re-click. Dock Controls → Settings was verified natively in
  the FDM-1025 and FDM-1026 smokes and remains covered there.
- **Not exercised natively here**: keyboard focus/cursor states (highlight is
  visual only), `c` clipboard copy (avoided to preserve the owner clipboard),
  theme colour-token changes while open, hotplug, and the one-monitor view —
  these need a calmer/isolated session (or the KVM guest) to verify visually.

## Remaining acceptance gates

The focused-monitor summon defect is fixed (see Defect A); the sidebar-edge
"off-screen" report was a false positive and needs no work. What still blocks a
clean SET-LOCAL pass is scope, not defect state: Features (SET-06), Apps
(SET-07) and Search (SET-08) are placeholders at this SHA, and the visual-only
focus/keyboard/theme/hotplug items remain unexercised. Re-run this checklist at
the final SHA once those sections merge.
