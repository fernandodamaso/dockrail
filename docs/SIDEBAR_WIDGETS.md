# Dockrail sidebar Widget contract

**FDM-967 owns provider lifecycle; FDM-973 owns the management foundation; FDM-999 supersedes its shared-scroll placement; FDM-970 registers the source-owned `herdr.agents` provider.**
Classic remains the default. `sidebarWidgets` defaults to `[]`; that starts no
provider, loads no widget view and reserves zero Widget-pane height. FDM-970 now
registers the source-owned `herdr.agents` adapter on top of this contract.
Clock/calendar (FDM-969) and Todoist (FDM-971) remain independent follow-ups.
No credential, stock topbar change, second host or notification daemon is needed.

## Registration and typed configuration

`DockHost.sidebarWidgetRegistry` is the host-owned dictionary of trusted Widget
descriptors. Dockrail source-owned integrations register descriptors in source;
validated external packages are contributed by `DockExternalWidgetRegistry`
through the package workflow in `docs/WIDGET_PACKAGES.md`. External custom
Widgets must not edit `DockHost`, `settings-schema.json`, or the installed
Omarchy plugin checkout.

Runtime schema readback derives registered IDs from this merged trusted registry.
Neither settings nor `dock.json` may supply QML paths, commands, URLs,
credentials, or factories. Tests may inject the controller registry; production
package discovery accepts only package-manager registry metadata under the
Dockrail XDG data store.

IDs are case-sensitive ASCII strings, at most 64 characters, matching
`^[a-z][a-z0-9]*(?:[._-][a-z0-9]+)*$`; `constructor`, `prototype` and `__proto__`
are forbidden. Explicit set/apply writes reject unknown IDs, duplicates, incorrect
types and invalid syntax atomically. Registration, **not transient readiness or
authentication**, determines whether an ID can be written. Ordered arrays replace
the entire key; preference reset clears it. The Python client preflights `set`
against the live schema; the existing host validates every write authoritatively.

Imported requested IDs remain saved, including unknown IDs. Unrelated writes do
not delete or execute them. Effective normalization removes invalid syntax and
duplicates; `effectiveSettings.sidebarWidgets` contains registered IDs only.
`data.presentation.widgets` explains unavailable requested IDs and live lifecycle
state separately. An unavailable provider can remain registered and requested.

## Descriptor and lease API

A trusted descriptor supplies:

```javascript
{
  id: "example.internal",             // Source example, NOT a registered provider.
  label: "Example",                   // Short non-sensitive label.
  manageable: true,                   // false hides source-owned integrations from Add/Manage.
  available: true,                    // Static capability; not an auth gate.
  status: "loading",                  // Initial capability metadata.
  revision: 1,                        // Descriptor/view revision, not snapshot revision.
  expandedView: expandedComponent,    // QML Component or null.
  compactView: compactComponent,      // QML Component or null.
  popupView: popupComponent,          // QML Component or null.
  acquire: function(owner) { return sharedAdapter.acquire(owner); }
}
```

`acquire(owner)` returns one **initially inactive** lease:

```javascript
{
  provider: sharedProviderQObject,
  setActive: function(active, publish) { /* provider-owned subscription scope */ },
  release: function() { /* release THIS owner only, exactly once */ }
}
```

Acquisition must be atomic: an exception must leave no partially acquired work.
`release` must clean up even after partial activation failure. Adapters own backend
reference counts and notification event de-duplication. They must never stop work
held by the topbar or another owner. Host code calls only lease methods, never a
shared service's `stop()` or `destroy()`. There is one manager on the host-owned
`DockSidebarController`, no process/provider per screen, slot, loader or popup.

Enable acquires once; disable/removal or host destruction releases once. Classic
mode and no usable screen suspend via `setActive(false, null)` while retaining the
lease. Resume activates the same lease. Collapse, resize, fold, title refresh,
view creation/destruction and popup changes do not reacquire or resubscribe.
Replacing an adapter's acquisition function or static availability is a deliberate
registry replacement and releases the old lease first. Replace descriptor snapshots
when changing metadata so QML observes the update. View-factory/descriptor revision
changes alone never restart the backend.

Reactive host registry bindings may rebuild descriptor maps when unrelated
providers change. Preserve the `acquire` function identity across those rebuilds;
use a stable host method reference instead of an inline closure. Change that
reference only when the adapter's acquisition boundary is intentionally replaced.

Each `setActive(true, publish)` receives a **new generation callback**. The provider
must replace its old callback, cancel sidebar-only pending work on suspension and
publish snapshots through the current callback:

```javascript
publish({status: "ready", revision: 17, data: { /* view-only snapshot */ }});
```

Status is `loading`, `ready`, `unavailable` or `error`. Snapshot revisions are
nonnegative safe integers, strictly increasing within an activation. Resume may
restart revision numbering. Duplicate/out-of-order updates and callbacks from a
suspended, released or replaced instance are ignored. Only ready snapshots retain
data. Malformed updates, acquisition/activation exceptions and view failures become
isolated error states; later valid updates recover without restarting the lease.
A failed acquisition/activation is not retried in a polling loop: repair/re-register
the adapter or explicitly disable/re-enable the ID.

## View API and failure isolation

Each factory's root is an `Item` with **non-required**
`property var widgetContext: ({})` and a sensible finite `implicitHeight`.
`DockSidebarWidgetView` injects a live binding immediately after Loader creation:

```javascript
{ id, status, revision, data, provider, presentation, openPopup, closePopup }
```

Factories must tolerate the initial empty context. `presentation` is `expanded`,
`compact` or `popup`. `openPopup()` routes to the controller using the owning slot's
anchor; `closePopup()` closes the single host. Views consume snapshots, never
acquire leases, subscribe, poll, or emit background notifications. Compact views
are read-only inside a native activation button. Expanded/popup views may expose
explicit provider actions. User data must be rendered as plain text, not markup
or executable input. Views must fit assigned width; long popup content scrolls.

Missing factories fall back to a bounded status button/message. Loader/context
errors are converted to `view-error`; a deferred failure is accepted only for its
exact provider-instance token, activation generation and snapshot revision. An old
view therefore cannot poison a removed/re-enabled or already recovered widget.
Failure unloads that view, not the window list or other providers.

## Split-scroll layout, management and persistence

FDM-999 gives the hierarchy and Widget bodies **independent sibling scroll
viewports** in the bounded middle region of `DockSidebar`. The Widget section
header is fixed above its body Flickable. PINNED and Applications remain fixed.
The old `contentTail` API/Loader is removed; Widgets are not domain hierarchy
rows and do not enter `visibleRows` or section-span keys.

`sidebarSplitLayout()` allocates logical pixels from canonical hierarchy row
metrics and the natural Widget header/card-column demands. Its automatic
hierarchy cap is 55% of the middle region; short content returns unused space
to the other pane. Allocated heights never feed back into natural demand.
The desired minimums are one monitor heading plus two rows and one Widget
header plus a collapsed card, each limited by actual content demand.

When those minimums cannot fit, reserve the whole Widget header if possible,
then the hierarchy minimum, then remaining Widget body space. Header-only is
valid. Below the complete header height, hide the section entirely and keep
Add/Manage reachable from the main Dockrail header. Rail and zero *presented*
Widget cards allocate zero Widget height. A filtered-out Herdr fallback does
not count as presented and retains its provider lease.

This is not the retired `min(240, 30%)` compact footer or an overflow sentinel.
There is no adjustable splitter/setting in this slice (FDM-1000 remains optional).
The actual residual blank area alone accepts mode-switch dragging.

Each panel retains an in-memory first-visible Widget ID, offset and old order.
Width/font/content/reorder changes restore that anchor after layout; removal
uses the next surviving old neighbor, then previous, then origin. Rail and
temporary zero space preserve the expanded anchor. Wheel/touch/reorder input
is not fought by restoration; focused-descendant reveal runs after pending
restoration. No scroll offsets are written to dock.json or shared across mirrors.

Vertical input over hierarchy changes hierarchy only; input over Widget bodies
changes Widgets only, even at bounds. Fixed headers/blank background change
neither. Native nested scrollables must contain vertical input at their bounds
and retain first refusal; ordinary content uses the outer Widget scroller.
Prefer a native `Controls.ScrollView` for a nested editor instead of a blanket
overlay handler. External packages need no new required property.

`sidebarWidgets` remains the canonical ordered list for both enabled state and
Widget order. Add/remove/reorder always go through the existing host settings
mutation path. Runtime schema readback injects IDs from the trusted source
registry; transient provider readiness does not decide whether an ID is writable.
Unknown imported IDs remain requested/unavailable according to the FDM-967 rules.

Per-card body state is stored independently:

```json
"sidebarWidgetCollapsed": {
  "example.internal": true
}
```

Keys use the same internal Widget-ID syntax and values are booleans. Missing keys
mean expanded. Removing a Widget intentionally leaves its collapse preference in
place, so re-adding the same ID restores it. A collapse map never enables or
executes a provider by itself.

`DockWidgetCard.qml` owns the common card header/chrome: icon, title, optional
count badge, drag affordance, collapse control, body clipping/status placement,
keyboard focus and the **Remove from Widgets** context action. The normal body
uses the existing descriptor `expandedView`. `compactView` remains in the
provider ABI for compatibility but is not used by the expanded sidebar area;
`popupView` remains available through the single host-owned Widget popup.

Drag starts from the card drag affordance, computes insertion boundaries only
among Widget cards and uses only the Widget body viewport's edge auto-scroll.
A release over hierarchy, section header, PINNED, Applications, blank space or
outside the panel cancels with zero settings writes. Escape, removed source,
external order changes or invalidated ownership also cancel. Geometry is mapped
from the retained scene point on every tick; reflow is not an external reorder. It cannot
drop into Monitor/Workspace/Window rows or reorder with Pinned/Applications.
Reorder and collapse are presentation/settings changes only: the host-owned
provider manager keeps the same leases/subscriptions.

The controller still owns `{widgetPopupId, widgetPopupAnchor}` for
Widget-specific popup content. There is no normal-card overflow sentinel.
Destroyed/hidden/scrolled-out anchors, removal, collapse, host invalidation and
surface teardown close safely. The Add/Manage picker is a panel-owned native Omarchy popup, independent of the
independent Widget pane. It therefore remains available from the Dockrail
header even when zero Widget cards are enabled and the pane has zero height.
Outside clicks dismiss it through Omarchy's normal click-popup focus handling.
It lists trusted source descriptors whose `manageable` flag is true, plus any
already-enabled registered descriptor so an unavailable integration always retains
a removal path, and routes add/remove back through the controller. `herdr.agents`
sets `manageable` from a bounded Herdr-binary readiness probe: installed Herdr is
offered in Add/Manage, while a requested widget stays removable if the binary later
disappears. This probe never acquires a provider lease or starts the Herdr provider.

`widgetManager.diagnostics()` and CLI `data.presentation.widgets` retain the
bounded, payload-free lifecycle diagnostics from FDM-967.

## Focus, presentation and popup geometry

Tab proceeds from hierarchy navigation to section Add/Manage, card root/header,
collapse and enabled body controls, then PINNED and Applications/Trash. Backtab
reverses those boundaries. The pointer grip is not a keyboard stop. Collapsed,
disabled and zero-body-area controls are skipped, while offscreen controls can
be revealed. An oversized card reveals the actual focused descendant rather
than attempting to fit its entire body. A focused removed Widget transfers only
its owning panel's focus to next/previous surviving card, section manager or
main-header manager. Provider refresh and geometry changes never request focus.

`layoutRevision` covers pane/ancestor geometry, clipping, card position/size,
contentY, screen/edge and effective visibility. Cards use the Widget body's
clip, and fully clipped presentations stop animating without unloading their
bodies or stopping providers. The one controller-owned popup follows actual
anchor geometry, including split changes at unchanged contentY; hidden,
destroyed, removed or fully clipped anchors close it. Fixed section and main
manager anchors are independent of the hierarchy viewport.

## Verification and FDM-1001 handoff

Source gates:

```sh
node tests/test_sidebar_split_layout.mjs
node tests/test_sidebar_widgets.mjs
python3 -m unittest discover -s tests -p 'test_sidebar_widget_config.py'
node tests/test_sidebar_host.mjs
python3 -m unittest discover -s tests -p 'test_cli_docs.py'
QT_QPA_PLATFORM=offscreen /usr/lib/qt6/bin/qmltestrunner -input tests -import components -import tests/qml-imports

```

Then run the complete current Headless CI matrix on the exact final head.
`tests/tst_sidebarwidgets.qml` uses the **production controller and view loader**
plus `tests/fixtures/SidebarWidgetFixture.qml`; it instruments acquire/release,
backend start/stop/subscription/notification counts, errors, stale callbacks,
mode/reflow cycles, popup routing/anchor destruction and an outside shared owner.
The `fixture.one` provider used by these SB-05 tests is synthetic and test-only.
Production registration of `herdr.agents` is covered by FDM-970 lifecycle/provider
tests; this foundation suite still does not count as live Herdr data evidence.

`tests/runtime/sidebar.qml` additionally uses the real host, `DockSidebarWidgetArea`,
native popup, footer/overflow, viewport/delegates and layers. It checks both edges,
bottom placement, independent scrolling, compact/expanded factories, tiny/large-row
bounds, failure recovery, one popup, provider/anchor removal and teardown. Its
snapshots and provider are test fixtures, not live-data evidence.

**Real compositor/pointer qualification remains a local follow-up (FDM-974), not a remote source pass.**
Use an isolated actual Omarchy/Quickshell session (see `DEV_SESSIONS.md`), stop that
guest's normal dock, and run:

```sh
SMARTDOCK_ISOLATED_RUNTIME=1 bash tests/runtime/check-sidebar.sh
```

SB-06 must also observe actual pointer/keyboard focus, both real monitor edges and
bottoms, hotplug, fractional scaling/real large-font settings, full-shell topbar
coexistence and integrated SB-03/SB-04 interactions on one final exact candidate.
No model/rectangle test, synthetic state or pure-Qt result substitutes for that.


## Reusable Widget UI kit and gallery (FDM-975)

For the coding-agent-facing per-component API — public properties, signals,
supported semantic/state values, model shapes, inherited control behavior and a
new-Widget checklist — read
[`docs/WIDGET_COMPONENTS.md`](WIDGET_COMPONENTS.md). The source QML remains the
final authority when a component implementation changes.

FDM-975 adds a presentation-only UI kit under `components/widgets/`. It does
not add a registry, provider manager, provider process, settings writer or service
integration. Widget bodies continue to receive the existing FDM-967/FDM-973
`widgetContext`; the kit only standardizes how those bodies render and interact.

The approved visual contract is preserved verbatim in the repository at
[`docs/widget-gallery/reference/approved-widget-mockup.html`](widget-gallery/reference/approved-widget-mockup.html).
That HTML remains the design reference. The executable coding-agent boilerplate is
[`tests/widget-gallery/WidgetGallery.qml`](../tests/widget-gallery/WidgetGallery.qml)
and uses synthetic data only.

The canonical body primitives are:

- display: `WidgetText`, `WidgetBadge`, `WidgetStatus`, `WidgetDivider`,
  `WidgetSection`, `WidgetList`, `WidgetListItem`, `WidgetChecklist`,
  `WidgetKeyValue`, `WidgetStat`, `WidgetStatGrid`, `WidgetProgressBar`,
  `WidgetMeter`, `WidgetActivity`, `WidgetSparkline`, `WidgetIconText`;
- icons: one `WidgetIcon` for Lucide names or arbitrary SVG/raster sources,
  theme tint versus brand-preserved rendering, shared size tokens,
  `plain | soft | outlined | tile` containers and bounded fallback;
- forms: `WidgetFormField`, `WidgetTextInput`, `WidgetSearchInput`,
  `WidgetTextArea`, `WidgetNumberInput`, `WidgetSelect`, `WidgetCheckbox`,
  `WidgetToggle`, `WidgetRadioGroup`, `WidgetSegmentedControl`;
- actions: `WidgetButton`, `WidgetIconButton`, `WidgetButtonGroup`;
- framework states: `WidgetState` with `loading | empty | unavailable | error | stale`.

Use semantic values such as `success`, `warning`, `danger`, `urgent` and
`overdue` rather than service-provided colors. Widget bodies can pass
`reducedMotion: true` to `WidgetState` and attention rows; nonessential loading
or nudge animation then stops while the semantic state remains visible.

`DockWidgetCard.qml` remains the single card shell from FDM-973. Its header now
uses the same `WidgetIcon` primitive as bodies/actions/states, and its no-view
surface uses `WidgetState`; provider acquisition, collapse/reorder persistence,
Add/Manage ownership and shared-scroll ownership are unchanged.

For a new Widget body, copy a composition from the gallery instead of creating
parallel typography, icon, form, action or state controls. Keep the root as an
`Item` with non-required `property var widgetContext: ({})`, consume snapshot
data as plain text, and leave provider/settings ownership in the existing host.

Focused source checks:

```sh
node tests/test_widgetkit_structure.mjs
QT_QPA_PLATFORM=offscreen /usr/lib/qt6/bin/qmltestrunner -input tests -import components -import tests/qml-imports

python3 -m unittest tests.test_sidebar_qml_syntax
```

Real compositor/pointer/theme/font qualification remains FDM-974 after this
source slice is accepted.


## External package discovery (Widget package API v1)

Installed external Widget packages join the same host registry and lease lifecycle
described above. `DockExternalWidgetRegistry` consumes only validated registry
metadata generated under the Dockrail XDG package store and contributes descriptors
to the existing `sidebarWidgetRegistry`; there is no second card, provider,
persistence, popup, or Widget-manager system.

Runtime configuration remains ID-only. An external descriptor may provide a
host-constructed `<presentation>Source` URL, but no executable path is accepted
from `dock.json` or `sidebarWidgets`. Invalid or incompatible packages are
isolated and omitted from executable descriptors, and external IDs cannot replace
built-in/demo or integration-owned IDs.

Source-owned integrations can opt out of Add/Manage with `manageable: false`;
already-enabled registered integrations remain listed only for removal.
`herdr.agents` remains source-owned and becomes manageable only while the Herdr
binary readiness probe succeeds. External packages are manageable by default. See
[`WIDGET_PACKAGES.md`](WIDGET_PACKAGES.md) for package validation, install/update,
development, and source-location rules.

FDM-999 executable coverage additionally includes
`tests/tst_sidebarsplitscroll.qml`, `tests/test_sidebar_split_qml.py`, and the
queued-drop/overflow regression in `tests/tst_sidebardropfeedback.qml`.
The source harness executes production methods/bindings and actual Qt input;
its compositor popup endpoints and Commons/Ui dependencies are fixtures.
Full Omarchy/Quickshell rendering, device input, native grabs/tooltips and both
host modes remain FDM-1001, not claims made by headless tests.
See [the source handoff](FDM-999-split-scroll-handoff.md).
