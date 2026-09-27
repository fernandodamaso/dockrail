# SB-02/SB-03/SB-04/SB-05 — Global sidebar source contract

**FDM-964 + FDM-965 + FDM-966 + FDM-967, unreleased integrated source candidate.**
SB-02 implements shared construction, projection, mirrored panels on connected
outputs, app folding/rail,
typed preferences and initial reservation. SB-03 adds live resize, cancellation and
conflict-safe preference commits. SB-04 adds exact-window actions, menus, keyboard
navigation and single-sidebar drag adapters. SB-05 adds host-owned widget leases and
a bounded footer with no production providers (historical SB-05 placement;
FDM-999 now uses independent, content-aware hierarchy and Widget panes). These slices do not deploy or qualify
a compositor. Classic remains the default; per-monitor `presentationModeByMonitor`
overrides let one output run the classic dock while another runs the sidebar.
Parent contract: FDM-962. Detailed SB-03
behavior is in [`SIDEBAR_RESIZE.md`](SIDEBAR_RESIZE.md); SB-04 is in
[`SIDEBAR_INTERACTIONS.md`](SIDEBAR_INTERACTIONS.md); SB-05 is in
[`SIDEBAR_WIDGETS.md`](SIDEBAR_WIDGETS.md).

## Source boundary

Shared workspace-monitor routing retains the FDM-942/FDM-943 pin enforcement
hooks for callers that establish a pin; the current workspace header has no pin
menu. FDM-949 tracks the full-host monitor-section qualification. User-facing
behavior is documented in `CONFIGURATION.md` without internal tracking IDs.

SB-03 starts from accepted SB-02 head
`1b06719163a3d333b712cbbbb73582c1a865da06` on
`feat/fdm-964-global-sidebar`. Stack the child against that exact source until the
parent lands. See `DELIVERY.md` for fresh base/head evidence after any rebase,
retarget or new commit.

- `DockDesktopModel.build(input)` accepts `mode: "sidebar"`, using the existing
  native workspace construction with all windows/monitors and no classic saved
  grouping. Classic inputs and the characterization remain unchanged. Unknown
  Wayland app IDs are isolated from pin matching in sidebar mode; an empty
  StartupWMClass is not evidence that a pin owns an unidentified handle.
- `DockWorkspaceModel.monitorMetadataCompare(a, b, order)` extracts the existing
  physical/configured comparator unchanged so connected screens without workspace
  descriptors use the same ordering. The existing monitor-label implementation is
  untouched; broader FDM-949 qualification remains open.
- `DockSidebarModel.reconcileHandles(previous, toplevels)` allocates session tokens
  once per actual live handle and prunes closure. `project(input)` consumes the
  native desktop, screen/monitor snapshots, pins, registry, folds and collapsed
  flag. It returns `monitorSections`, `launchers`, `unassignedWindows`, `rows` and
  `badgeItems`. Row keys are domain identities, not list indices or addresses.
- `selectScreens(screens, monitors, order, preferred, previousMapped, busy)` maps
  every connected screen when `preferred` is empty or disconnected, and a single
  connector when that preference is connected. While busy, removed outputs drop
  immediately but newly added outputs wait until idle. `selectScreen(...)` returns
  the primary (first mapped) output for dockMonitor / CLI back-compat.
- `screenGeometry(screen, requestedWidth, collapsed)` uses the full logical screen
  width, not scale-adjusted pixels or a workarea already reduced by the panel's own
  reservation. `resizeWidth(...)` clamps one captured screen-global pointer delta;
  right-edge drag reverses the delta without accumulating panel-origin movement.
- `recoverAnchor(anchor, oldKeys, rows)` keeps the first visible key and offset or
  nearest surviving neighbor.
- `DockSidebarController` is the sole host-owned session state object. Its snapshot
  inputs use existing host data/revisions; it adds no timer, IPC, topology listener,
provider or settings writer. SB-05 adds host-owned widget leases with no production
  providers initially. It owns handle tokens, app folds, selection, scroll/focus
  keys, captured menu/input targets and temporary resize/drag state. It emits
  `aboutToRefresh`, `refreshed` and `surfaceInvalidated`. `interactionBusy` freezes
  preferred reconnects during an active interaction or open widget popup; current-screen
  removal, sidebar membership/pin changes and explicit edge/host changes cancel immediately.
  Widget work, resize eligibility, collapse requests, target checks and drag eligibility
  follow actual sidebar membership per connector, never the global mode, so a classic
  output drives no sidebar work; workspace-card drag registration stays on classic docks.
  Shared expanded
  width, collapse and edge preferences drive every sidebar panel; each panel clamps
  geometry to its own screen.
- `DockHost` owns one stable `DockScreenPresentation` surface owner per connected
  output instead of a single mutually exclusive presentation Loader. Each owner
  resolves its own mode through the shared `DockScreenPresentationModel` and swaps
  classic/sidebar surfaces teardown-first, so switching one screen never recreates
  another screen's renderer instance, and a surface-key change rebuilds only that
  owner's surface. Hotplug, `sidebarMonitor` remapping and override changes adopt
  or tear down only the affected owners: a disconnected output cancels its gesture
  and closes its popups, and reconnecting restores the configured presentation.
  The existing action, monitor-drag, badge and config
  services remain singletons. `saveSettingIntent` is only an acceptance/staleness
  adapter around the existing sole FileView writer; it is not a second write path.
  Each `DockSidebar` uses `badgeScopeOwner: "smartdock-sidebar:<connector>"` and
  keeps `WlrLayershell.namespace: "smartdock-sidebar"`. Host desktop RMB → launcher
  binds (for example Omarchy background `mouse:273`) must exempt `smartdock` and
  `smartdock-sidebar`, or any `smartdock*` namespace—the same exemption classic dock
  already needs—so right-clicks reach the sidebar context menu instead of opening
  the launcher.
- `DockSidebarViewport` uses Quickshell `ScriptModel.objectProp: "key"` and actual
  `DockSidebarRow` delegates. Before model reconciliation it guards the scroll
  anchor; background data/focus refreshes are not scroll commands. Rows bind live
  title/focus, share `DockAppIcon`/profile artwork and `DockApplicationBadge`, and
  render user titles as plain text. No thumbnail or automatic flyout exists.

## Behavior and ownership

Visual order comes from native monitor/workspace hierarchy, not `renderedItems`.
Applications group only within a workspace, pinned apps lead in pin order, and
members retain first-seen handle order. Multi-window application groups emit an
expandable header with a window count; single-window apps emit only the window
row so titles stay primary. Empty/named/unknown-owner workspaces stay
represented. Sticky/minimized membership follows native resolution. Unsupported
locations appear once under Unassigned windows; closed pins appear once under
Pinned (the Pinned section remains reachable for add-pin even when every pin is
running); hidden apps are excluded. Unknown application handles have distinct app
identities. A connected empty monitor gets a header, never an invented workspace.

`DockModel.buildVisibleItems` attaches the matching desktop-entry object as
`item.entry` so sidebar projection, artwork, context menus and launcher execute
share the same catalog metadata classic `DockItem` resolves through
`DesktopEntries.byId`. Icon overrides and browser-profile artwork remain separate
`DockAppIcon` paths on top of that entry icon.

Only application groups fold, with session-only state. Workspaces and monitors do
not collapse or display window-total counters. Rail mode removes application and
window names and emits every window icon, including folded members, retaining the
wide-mode fold state. Native primary-workspace traversal assigns one app-wide badge
owner; a folded app header can own it. Other indicators use actual window-address
records, not an invented per-window share of an app total.

The classic control command, application pin picker and optional Open Trash remain
available as utilities using existing host actions. They are not widget providers.
The application picker closes before surface destruction; only each sidebar panel's
badge scope is removed. A sidebar never registers as an invisible classic monitor dock.

## Settings, geometry and resize

The sidebar keys are typed through bundled defaults/schema, runtime normalization,
the existing strict host validator, Python CLI parsing and the sole FileView writer:
`presentationMode`, `presentationModeByMonitor`, `sidebarEdge`, `sidebarMonitor`,
`sidebarExpandedWidth`,
`sidebarCollapsed`, `sidebarCollapsedByMonitor`, `sidebarBrowserTabsEnabled`,
plus SB-05 `sidebarWidgets`. See
`CONFIGURATION.md` for their inventory and `SIDEBAR_RESIZE.md` for gesture/persistence
semantics. Chrome open-tab nesting (titles only) is documented in
[`browser-tabs.md`](browser-tabs.md).

Requested classic settings, unknown extension keys, pins, artwork, hidden apps and
provider preferences are preserved. `data.presentation` describes the primary
screen, full `screens` list for mirrored panels, per-screen `collapsedByScreen`,
width, mapping eligibility and inactive classic fields. The per-monitor
resolution is `defaultMode` plus `perMonitor`/`modeByMonitor`/`sourceByMonitor`/
`mappedByMonitor`, the `classicScreens` list and the `mixed` flag; in a mixed
layout the legacy `mode` field reports the inherited default while `screen`,
`screens`, `width` and `mapped` describe the rendering sidebar. A dry-run reports the
proposed projection without writing. Classic action policies are `null` in sidebar
effective output, not falsely active. Theme values are not claimed as decoded
rendering evidence.

Explicit per-panel collapse sends only `sidebarCollapsedByMonitor` for that
connector, preserves expanded width, and distinguishes preflight rejection from
accepted-but-saving. Empty map entries follow `sidebarCollapsed`. Shared projection
stays expanded so every panel shares row keys; each panel applies its own rail
chrome from `collapsedFor(screen)`. Resize pointer motion
writes nothing; a changed successful release sends only `sidebarExpandedWidth`.
No-op release, Escape/grab loss and invalidation write nothing. `E_STALE` rejects a
field whose host value changed after capture. An accepted live intent remains
accepted if FileView persistence is temporarily `E_BUSY` or later fails; retry uses
the latest host snapshot and never replays the drag-start snapshot. The UI surfaces
the host's persistence state and does not claim early durability.

The background mode gesture is a sibling of that writer contract: a press on
eligible empty sidebar background (the panel surface, or the list's blank tail
while it exists) captures that connector's presentation token, and dragging down
past the same 48 px threshold arms a switch of that monitor back to the classic
dock, showing a direction hint pill and then a bottom-edge silhouette on the
source monitor. Release revalidates the captured token and commits exactly one
`presentationModeByMonitor` entry for the source connector through
`DockHost.commitMonitorModeGesture`, leaving every other connector's mode
untouched; release below threshold, Escape, grab loss, an open
menu/popup, resize, row/widget drag, a presentation or topology change during
the press, or a disconnected source cancels with no write. The gesture yields whenever
`controller.interactionBusy` becomes true, is cancelled by panel closure, and
its stale/busy/persistence failures use shared host feedback keyed by the source
connector, so a rejected message appears only on that monitor.

For unreserved logical screen width W, rail = min(72, W); expanded maximum =
min(W, max(72, min(480, floor(0.40 × W)))); minimum = min(240, maximum).
Clamp the requested expanded width to those runtime bounds, never back into the
saved preference. No scale division or workarea feedback loop. Zero width does not
map. The panel anchors top/bottom plus left or right on each mapped output, uses
normal Top layer, and reserves the effective persistent width exactly once per
output. The active resize handle is
8 logical pixels **inside** expanded width on the desktop-facing edge and is absent
from rail interaction. It uses targetless pointer handling and screen-global logical
coordinates for **that panel's** screen. Shared resize/collapse commits update every
mirrored panel. Rows are at least 44 logical pixels and icons cap at 32. The stock
topbar is neither disabled nor assigned guessed pixel dimensions.

## Native composition inspection

Inspected Omarchy Quattro source `9c5482c58dbe4974de337450754885083c91eada`:
`shell/Ui/Button.qml`, `shell/Ui/BorderSurface.qml`, `shell/Commons/Style.qml` and
`shell/plugins/dev-gallery/GalleryPanel.qml`. Buttons supply native focus/hover,
keyboard activation, tooltip and theme state; BorderSurface composes semantic
border specifications. Sidebar rows retain domain identity/artwork/attention logic
rather than replacing the generic kit. Upstream inspection is not proof of the
installed ABI: SB-06 records the actual Omarchy/Quickshell/Qt revisions and validates
full-shell/topbar compatibility. Generic native Button color transitions remain
native behavior; no sidebar geometry animation repeatedly retiles the desktop.

## Validation and explicitly deferred work

Focused source commands include SB-03 and SB-04:

```bash
node tests/test_sidebar_model.mjs
node tests/test_sidebar_host.mjs
node tests/test_sidebar_geometry.mjs
node tests/test_sidebar_mutations.mjs
node tests/test_sidebar_actions.mjs
node tests/test_sidebar_drag.mjs
node tests/test_screen_presentation_model.mjs
node tests/test_desktop_model.mjs
python3 -m unittest discover -s tests -p 'test_sidebar_config.py'
python3 -m unittest discover -s tests -p 'test_sidebar_qml_syntax.py'
QT_QPA_PLATFORM=offscreen /usr/lib/qt6/bin/qmltestrunner -input tests -import components -import tests/qml-imports
```

Then run the complete current `.github/workflows/ci.yml` matrix and
`git diff --check`. The Qt tests instantiate the production controller/resize
handle; source host-method tests substitute unavailable services only. Syntax
parsing is not rendering.

`tests/runtime/sidebar.qml` and `check-sidebar.sh` instantiate the actual host,
FileView writer, panel, viewport, delegates and resize handle and probe native layer
counts. Fixture window/monitor snapshots are synthetic; renderer/controller/writer
are not copied. In addition to SB-02 lifecycle checks, the fixture now verifies
live right-edge preview reservation, zero settings revisions/writer-text changes
during pointer motion, one settings revision on changed release, zero on grab-loss
cancel, external-width conflict cancellation, layer teardown and final disk readback
with unknown/classic keys preserved. It does not certify real hotplug or physical
pointer input until executed in SB-06.

**Runtime fixture and compositor checks are unexecuted by the remote source slice.**
FDM-968/SB-06 owns their execution and demonstrated fixes. Inside the disposable
Omarchy Wayland session from `DEV_SESSIONS.md`, first stop that session's ordinary
dock, then run (never alongside a production host):

```bash
SMARTDOCK_ISOLATED_RUNTIME=1 SMARTDOCK_RUNTIME_LOG=/tmp/sidebar-runtime.log \
  bash tests/runtime/check-sidebar.sh
```

The wrapper refuses an already mapped SmartDock layer, uses a disposable config,
and removes its temporary source on exit. Retain sanitized logs/captures and stop
the named guest. Real multi-monitor/fractional/portrait/hotplug, full-shell stock
bar creation orders, focus/input, fullscreen on another monitor, plugin validation,
shell-aware lint and rendering remain integrated gates. A stripped plugin guest
alone does not prove stock-bar coexistence.

**FDM-966/SB-04** reuses merged FDM-954 and adds exact-target activation, menus,
keyboard and drag. **FDM-967/SB-05** supplies bounded widget lifecycle/popups; see
[the provider/view API](SIDEBAR_WIDGETS.md). **FDM-968/SB-06** owns this integrated
candidate and physical runtime qualification. Keep the feature-bearing PR Draft until the
integrated core passes SB-06. Source acceptance does not merge, install or deploy.

## Current Widget split layout — FDM-999

The middle region excludes fixed controls, PINNED, Applications and margins
once, in logical pixels. Canonical row metrics (including alerts, Herdr/browser
rows and drag footers) drive hierarchy demand, never ListView's virtualized
content-height estimate. A fixed Widget header and clipped body Flickable are
siblings of the hierarchy. Only residual blank space accepts mode dragging.
Rail/hidden Herdr/zero-card and constrained-header policies, stable-ID anchors,
focus and input ownership are specified in [SIDEBAR_WIDGETS.md](SIDEBAR_WIDGETS.md).
Existing FDM-994 origin-only confirmation and FDM-995 native boundaries remain.
