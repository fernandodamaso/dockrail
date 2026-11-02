# SB-04 — Sidebar interactions

FDM-966 source candidate. Native integration and rendering remain FDM-968/SB-06
acceptance gates. This document does not report an unexecuted fixture as a pass.

## Source lineage and ownership

The candidate starts from accepted SB-03 `c6d9b0dcb8f96f6e61591996bcafc728ec022dfe`
and merges `main` at `86fb65893295c95df664e6f274b19375a50f088a`, which contains
FDM-954/PR #79 and the newer classic workspace-drag integration. The single
`Dock.qml` merge conflict preserves SB-01's shared `DockDesktopModel` builder and
the newer classic drag coordinator. The builder uses the current native
`monitorActiveWorkspace` helper. SB-05/PR #78 widget footer/lifecycle is folded into the FDM-968 integration candidate with this viewport/menu/resize composition.

No installed plugin, production configuration, topbar or compositor binding is
changed. No second action controller, writer, process, monitor watcher or saved
setting is added. PR-only delivery and fresh exact-head CI remain required by
`DELIVERY.md`. A local commit or source bundle alone is not remote Done.

## Exact activation

`DockSidebarController.captureTarget` captures the session key, native handle,
address and clicked connector before pointer focus changes. The row-input adapter
uses the same separate native Qt NoModifier/ControlModifier TapHandler pattern as
FDM-954. Only explicit boolean Control permits a pull; missing information stays
plain. Raw Qt modifiers are available in the viewport's activation signal.

Plain clicks and Enter activate the exact live window without requesting a
workspace move. Ctrl+left-click canonicalizes the captured host connector and
uses the shared `pullToplevelToMonitorWorkspace` route, moving just that window
to the clicked monitor's active workspace before focusing it. Window and workspace
pins, minimized origins, named workspaces, exact-handle liveness and same-monitor
behavior remain owned by that service. No focus-derived monitor or frozen card
workspace override is substituted. Enter remains plain even while Ctrl is held.

Nested T3 Code thread and Herdr agent rows use the same captured sidebar
connector for Ctrl+left-click. A trusted Ctrl tap first uses the shared window
action to move or restore the exact host window onto that monitor's active
workspace, then sends the captured agent's exact focus request. When the host
window is already on the clicked monitor, the agent is focused in place without
a redundant window move. Missing provider/capability, stale agent or host,
unmapped connector and rejected moves cause no agent-focus request. Plain clicks
and Enter continue to focus the exact agent without moving its window. The
standalone agents Widget is unchanged.

Unknown window locations remain reachable by their live native handles; actions
requiring a trustworthy location are disabled. Address reuse, hidden-app changes,
closure and a changed captured connector cannot retarget a delayed click.

Sidebar workspace headers focus in place on plain click and Enter through the
shared `focusWorkspaceInPlace` adapter. Ctrl+click validates the captured
connector and pulls the workspace onto that monitor through
`workspaceOnMonitorRequests`. Classic header, wheel, pointer action settings,
menus and cross-dock drag behavior are unchanged.

## Menus and keyboard

One existing `DockContextMenu` is composed by the sidebar. A captured window is a
single target, not whichever row is hovered or active later. The optional sidebar
mode disables saved Group/Ungroup actions, uses live named/numeric workspaces for
window moves and adds current-owner workspace pin/unpin and explicit monitor-move
menus. All dispatches, including app-level actions without a window target field,
revalidate the captured row. Removed move destinations are revalidated before
dispatch and are not silently recreated. Menus dismiss/reanchor on closure, owner changes,
visibility/clipping, viewport scrolling, mode/edge/host change and topology refresh.
The existing popup placement slides inward within screen bounds; sidebar width
and height additionally cap the popup, including bottom anchors.

`DockSidebarKeyboard` is a focus-neutral Qt event adapter. Rows forward explicit
key events to it; it installs no global keybind and takes no hover/map focus.
Tab/Shift+Tab, Up/Down, Home/End skip noninteractive section labels. Enter activates,
Space folds an application, Shift+F10 opens the selected row's menu and Escape
cancels input/dismisses menus. Navigation remembers an exact live application
handle for explicit Escape focus restoration. Pointer-selected rows are not
changed by a delayed keyboard-entry handler. ListView wheel/touchpad scrolling
stays ordinary scrolling; its competing built-in key navigation is disabled.

## Drag lifecycle and geometry

A captured individual window moves and follows to a visible workspace group,
new-workspace slot, or explicit monitor header. Workspace groups share their
painted inset/gap geometry with hit testing; the first hit is final even when
ineligible. Footer slots appear on every monitor while a window is dragged,
not only the hovered one. No predicted workspace number is displayed. Workspace
sources retain whole-monitor-card targets and sorted, view-only placeholders.

A header resolves its monitor's active workspace through the live workspace
inventory. Its owner must equal that monitor at hover, release, and immediately
before dispatch. Missing/changed identities or owner disagreement reject the
drop with zero dispatch; an existing workspace is never relocated to repair a
stale header. The shared `moveCapturedToplevels(..., true)` action preserves
captured member identity, pins, minimized restoration, named-workspace backend
eligibility and ordered follow behavior. Ctrl-click uses the extracted active
workspace lookup without changing its existing semantics.

**Provisional Draft policy:** dropping on the current monitor's header from a
different workspace moves to its active workspace (the R1 proposed default).
The internal `headerDropWithinMonitor` guard isolates this branch. Owner
acceptance is still required before Task 4 merges; source execution is not a
record of that product decision. Dropping into one's current workspace is a no-op.

Only header/top and unclaimed bottom padding are window-to-monitor targets.
Workspace content, separators, side gutters, independent Widget pane, hierarchy drag-footer extra height,
offscreen/clipped areas and gaps between cards cannot fall through to a header.
Window pins and workspace monitor pins have distinct rejection labels. A dimmed
source and clipped, theme-aware pill identify the source and destination without
creating another window. The collapsed rail shows artwork only. Edge scrolling
remains bounded to 12 logical pixels per 16 ms tick and stops outside the viewport;
hit testing is repeated after geometry/scroll changes and at release.

Presentation ordering freezes while dragging, not live action validity. Closure,
address reuse, source location changes, target-owner changes, topology changes,
mode/edge/host/collapse invalidation, Escape and native grab cancellation abort
without a partial move. Resize, menus and row drags share the existing busy
boundary. Qt `UngrabExclusive` is the successful release; becoming inactive alone
is not permission to commit. A completed or cancelled gesture consumes its click.

## Post-dispatch feedback

The gesture ends before submission and releases its busy boundary. A separately
bounded operation captures the exact toplevel/native handle/address (or workspace
identity), expected workspace and monitor, token, deadline, originating connector
and unique viewport generation. New-workspace identity comes from the shared
action's **single-submission receipt**, not a preview allocation. Existing boolean
callers remain strict booleans.

A transport acknowledgment means **pending**, not success. Confirmation requires
consistent live identity, workspace, window monitor and workspace owner readback.
Minimized storage, replacement handles and conflicting inventories do not confirm.
The initial wait bound is 1500 ms, driven by existing refresh signals plus one
single-shot deadline timer. Timeout/ambiguous submission means **Move not confirmed**;
there is no rollback, compensating move, retry or late feedback revival.

Only known pre-dispatch rejection/cancellation can animate the captured artwork
back to its still-exact, visible source (200 ms). An absent/offscreen source or
reduced-animation preference receives cleanup without a false return animation.
Confirmed feedback waits for projection and queued scroll restoration to settle,
resolves the current row, uses `ListView.Contain` and saves its resulting anchor
before the 400 ms accent flash. Folded/absent windows only permit a verified visible
workspace-group fallback, never unfolding, focus stealing or a different window.
Only the originating live viewport participates; mirrored panels keep independent
connector × expanded/rail anchors. New gestures, topology/surface changes and
teardown invalidate outstanding tokens, timers and queued callbacks.

### Native qualification matrix (FDM-995)

Qualified on the exact dirty candidate identified in
[`FDM-995-native-qualification.md`](FDM-995-native-qualification.md), in the fresh
two-output standalone guests `fdm995-native-r3` and `fdm995-native-r4`.
“Substituted” means production QML/model code under controlled test transport or
timing; it is not a native race or rendering claim.

| Area | Result | Qualification boundary |
| --- | --- | --- |
| W1/W5/G1 source feedback | Native pass | Window/workspace source dimming, monitor-group target, expanded and collapsed/right-edge feedback, pinned-window rejection, minimized-source ghost/target, and reduced-motion flash were observed. |
| W2/W4 geometry | Native pass, partial matrix | Mirrored new-workspace slots, allocated destination, monitor-group target and held-drag autoscroll `contentY 0 → 64` passed. Every geometry permutation from the planning matrix was not independently replayed. |
| W3 header drop | Native pass with product approval pending | Cross-monitor header move confirmed with origin-only flash. Same-monitor header behavior was qualified and is not a runtime defect, but the provisional product policy still requires owner approval. Stale/missing owner races remain deterministic substituted coverage, not native evidence. |
| Workspace-source/card moves | Native pass, partial matrix | Numeric `id:3` and named `name:alpha` workspace-source moves passed in both origins represented by Virtual-1/Virtual-2. The complete placeholder/empty-monitor permutation matrix was not independently completed. |
| Confirmation | Native pass plus substituted pass | Native existing/header, new-workspace, minimized-window and workspace-source operations reached submitting → pending → confirmed; pinned and outside releases rejected. Delayed/inconsistent readback, timeout/late success, replacement and stale-owner cases are source/substituted evidence only. |
| W6/W7 finish | Native pass, partial matrix | Real held-button input, release, Escape cancellation, rejection cleanup, origin-only flash, reduced motion and live-reload settlement passed. Closing the captured source cleared its operation without flash; a fresh drag then confirmed independently without stale transfer. |
| Scrolling and lifecycle | Native pass plus substituted pass | Native autoscroll, two-panel generations, mixed expanded/rail live reload, two → one → two virtual topology recovery, and offscreen origin-only containment after queued restoration passed. The reverse-origin offscreen case was not achieved. Native folded fallback retained the fold and flashed only the workspace group, but categorical no-focus-steal was inconclusive; the complete folded contract, recreated-origin rejection and owned restore ordering passed in the QML harness. |
| Host/output scope | Blocked outside tested context | No physical-output or full-Omarchy-host claim. The tested host was standalone on two virtual KVM outputs with guest-only input. |

R13/R14 additionally exposed missing icon assets in the disposable observer copy
and `DockMenuAction` context-menu width binding-loop warnings. Those contextual
warnings are disclosed separately from the candidate result: both rounds had
zero candidate delayed-callback errors. The inspected individual settled frames
and observer records showed no stale drag presentation; clipped Thunar content
at the guest screen edge was a real test window, not dock feedback. Any further
code change invalidates this exact-candidate native evidence and requires
affected native checks to run again.

### Native UI composition inspected

Omarchy `947e2fc002d6831c7888b29b5761d59d29e69727`: `shell/Ui/BorderSurface.qml`,
`PopupCard.qml`, `shell/Commons/Style.qml`, and first-party `shell/plugins/bar/widgets/Tray.qml`.
Inline ghosts compose `qs.Ui.BorderSurface` with popup colors, native border/font/
spacing/state tokens. `PopupCard` would add a window and is deliberately not used.
The domain-only `DockSidebarDropSlot` paints dashed decoration because BorderSurface
has no dashed-edge API; it owns no input, action, settings or window lifecycle.

## Source checks

`tst_sidebardropfeedback.qml` reads trusted repository methods into a real Qt Quick
ListView harness. `QML_XHR_ALLOW_FILE_READ=1` is test-only; file writes stay disabled.
This exercises real `Qt.callLater` callbacks, not compositor/native qualification.

```bash
node tests/test_sidebar_actions.mjs
node tests/test_sidebar_drag.mjs
node tests/test_sidebar_drop_confirmation.mjs
node tests/test_sidebar_drop_scroll.mjs
node tests/test_grouped_actions.mjs
node tests/test_session_pins.mjs
QML_XHR_ALLOW_FILE_READ=1 QT_QPA_PLATFORM=offscreen /usr/lib/qt6/bin/qmltestrunner \
  -input tests/tst_sidebarinteraction.qml -import components
QML_XHR_ALLOW_FILE_READ=1 QT_QPA_PLATFORM=offscreen /usr/lib/qt6/bin/qmltestrunner \
  -input tests/tst_sidebarkeyboard.qml -import components
```

Also run every current Headless CI gate. Model tests execute production QML
methods with compositor transport substituted; Qt input tests execute the actual
pointer/key adapters with QtTest events. These are not native Wayland modifier,
physical monitor, full-shell popup or typing-focus passes.

## FDM-968 native qualification

`check-sidebar.sh` retains its automated production host/controller/delegate/
reservation/writer fixture. Its injected desktop data remains explicitly
synthetic. SB-04 additionally checks that real pointer/key/menu adapters exist.

A separate live-data observer runs the real host without injected windows,
replaced dispatchers or a copied renderer. Stop the named guest's normal dock
first; never run this on the production display:

```bash
SMARTDOCK_ISOLATED_RUNTIME=1 SMARTDOCK_RUNTIME_LOG=/tmp/sidebar-native.jsonl \
  SMARTDOCK_NATIVE_SECONDS=120 bash tests/runtime/check-sidebar.sh --native
```

The observer uses disposable source/configuration, refuses an existing mapped
SmartDock layer and is bounded to 1..300 seconds. It discovers every live
`host.sidebarPanels` surface and its ordinary and discoverable inline-workspace
badge inputs. Records contain only allowlisted scalar identities and booleans:
gesture sequence, source kind/key/address, connector/surface generation,
target/rejection changes, release and cleanup, drop-operation token/state/
expected workspace+monitor/deadline, and each viewport's restore/contentY/
anchor/flash/presentation state. They never contain titles, rows, QObject dumps,
whole toplevels or private action payloads. The output is prefixed diagnostic
JSON, not a bare JSONL file.

For FDM-995, run the command in a fresh two-output named guest after stopping its
normal dock. Require `ready.panelCount` to equal the expected sidebar panel count
and require both panel connectors to produce `panel-observed` viewport records
before interacting. Correlate one physical gesture by `sequence`; a release is
shown by `gesture-release`, cleanup by `gesture-cleanup`, and the eventual result
by `drop-operation` state transitions plus only the originating generation's
viewport records. `observedInlineInputCount` may be zero when no populated
workspace has an inline badge currently instantiated; it is not proof that the
input class was missed. A `ready` record or clean observer exit is **not** a
matrix pass. Record independent `hyprctl -j` workspace/monitor/active-window
snapshots before and after each isolated case.

SB-06 must run the following on the final combined SB-03/04/05 candidate:

1. Plain and Ctrl window navigation in both monitor directions, both Ctrl keys,
   Ctrl held before pointer entry/released before a subsequent plain click,
   same-monitor activation, named workspaces, folded application/rail members,
   pins, minimized origins and target closure/address reuse.
2. Plain header focus versus Ctrl whole-workspace moves; menu exact targeting,
   no hover retargeting, live owner invalidation, inward popup bounds on both
   edges/bottom rows, large fonts and fractional scaling.
3. Actual pointer window/workspace drags, clipped/scrolled destination rows,
   changed source/target/host topology, resize conflicts, successful release,
   Escape/grab loss, no release click and bounded edge autoscroll.
4. Keyboard entry/re-entry, focus indication, all supported keys, popup dismissal,
   empty-dock/utility interactions and typing remaining with the intended app.
5. Full Omarchy/topbar coexistence, plugin validation, shell-aware lint, physical
   output/hotplug/reservation checks and cleanup. Virtual outputs alone do not
   establish physical-output qualification.

Preserve attribution for FDM-954: PR #79 recorded user-observed native coverage,
with its final exact-head confirmation left pending in the review record. The
merge is present; this source slice neither recreates that fix nor upgrades its
historical evidence. SB-06 establishes fresh native evidence on the integrated
candidate and owns demonstrated runtime fixes. No human code-approval ritual is
required, and no deployment is implied by remote source acceptance.

## Independent Widget input boundary — FDM-999

Hierarchy wheel/row-drag auto-scroll stays in the hierarchy; Widget wheel/grip
edge-scroll stays in the Widget body clip. Fixed headers and residual blank
space do not scroll either pane. Nested native scrollables retain first refusal
and contain wheel input at their bounds. A passive bottom alpha fade paints no
new surface and handles no input. Widget title drags remain stealable for
scrolling; only the explicit grip reorders, and release outside the Widget body
cancels with zero writes. The actual blank-region gesture remains included in
mode-drag selection/cancellation/preview feedback.

Tab/Backtab cross the pane boundaries without changing hierarchy arrows,
Home/End or inline workspace/alert semantics. Reveal only the focused body
control after deferred anchor restoration. No geometry/provider update takes
focus. See SIDEBAR_WIDGETS.md for per-panel restoration and popup ownership.
