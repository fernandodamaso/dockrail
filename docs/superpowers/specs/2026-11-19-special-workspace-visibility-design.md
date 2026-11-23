# Special workspaces are invisible to Dockrail and Alt+Tab

Date: 2026-11-19
Status: approved (small change)

## Intent

The Hyprland scratchpad (`special:scratchpad`) is an invisible workspace: it is
shown on demand with `SUPER + SHIFT + S` and otherwise does not exist for the
rest of the desktop. Today its windows still become Dockrail dock icons, sidebar
rows and Alt+Tab MRU candidates, so the "invisible" workspace leaks into both
surfaces.

The same leak applies to every Hyprland special workspace, not only the one
named scratchpad.

## Why now

Live evidence at the time of the change: `hyprctl clients -j` reports
`grok-bot` on workspace `special:scratchpad` with `hidden: false`,
`mapped: true` while the scratchpad is shown. Dockrail's flat dock uses
`windowScope: "all"`, the grouped dock files special-workspace windows under
`fallbackItems`, the sidebar passes every toplevel to `DesktopModel.build`, and
`keymap/alttab.lua`'s `switchable()` only excludes unmapped, hidden and the
Wispr status overlay.

## Goals

- A window whose workspace is special never contributes a dock icon, sidebar
  row, fold, tab group, window count or Alt+Tab candidate.
- Hiding remains correct while the special workspace is shown on screen.
- Dockrail's own minimize workspace keeps working: a window moved to
  `special:smartdock-minimized` keeps its dock/sidebar position at its recorded
  origin.
- No new user-facing setting. Invisibility is a semantic guarantee.

## Non-goals

- Herdr/T3/Claude agent rows, browser activity, and notification badges are
  separate sources and are not filtered by this change.
- The workspace switcher (`SUPER + TAB`) and Omarchy's workspace model are
  already scratchpad-aware in `~/.config/hypr/workspaces.lua`; unchanged.
- No change to how users reveal, populate or move windows into a special
  workspace.

## Anti-goals

- Hiding a Dockrail-minimized window because its origin cannot be resolved.
  Unknown locations must fail open.
- A second filtering rule duplicated per surface.

## Constraints

- `filterToplevelsByScope` in `components/DockWindowModel.js` is the single
  scope filter used by the flat dock and covered by `tests/tst_windowscope.qml`.
- The grouped dock builds records from the raw `toplevels` list in
  `components/Dock.qml`, and the sidebar from `root.toplevels` in
  `components/DockSidebarController.qml`; both need the filtered list to stay
  consistent with the flat dock.
- `HL.Workspace.special` is a documented boolean (`/usr/share/hypr/stubs/hl.meta.lua:809`)
  and `keymap/alttab.lua` must keep its existing Parsec guard, logging isolation
  and reverse/release behaviour.
- Delivery: Dockrail through a PR to `main` with `Headless CI`; the Hyprland
  config repository gets one commit plus its CHANGELOG entry.

## Approaches

1. **Shared scope filter (chosen).** Teach `filterToplevelsByScope` to drop
   known special-workspace locations before the scope test, and have both
   surfaces consume that one function. Single rule, existing tests, no new
   configuration.
2. Per-surface exclusions. Filter separately in the sidebar controller and the
   dock host. Rejected: two rules drift, and each needs its own test surface.
3. Filter inside `DesktopModel.build`. Rejected: the flat dock's items come from
   `filteredToplevels`, not from that build, so the flat dock would stay broken.

## Design

- Predicate: a location is hidden when `workspaceKnown` is true and
  `workspace` starts with `special:`. Unknown locations fail open.
- `locationForToplevel` already resolves `special:smartdock-minimized` to its
  recorded origin before the predicate sees it, so Dockrail-minimized windows
  are evaluated against their origin workspace. An unresolvable origin keeps
  `workspaceKnown: false` and stays visible.
- `Dock.qml` gains `presentationToplevels` (scope `all`, bound to
  `scopeRevision`) and passes it to the grouped `DesktopModel.build` as both
  `toplevels` and the `windowRuleMatches` source; the existing
  `filteredToplevels` binding inherits the exclusion through the same function.
- `DockSidebarController` derives presentation toplevels through the same
  function and uses them for `reconcileHandles`, the desktop build input, and
  `windowRuleMatches`.
- `keymap/alttab.lua`: `switchable()` also requires
  `not (w.workspace and w.workspace.special)`. A focused scratchpad window is
  therefore never a candidate; from inside a shown scratchpad Alt+Tab lands on
  the most recently focused normal window (the MRU head, index 1, matching the
  existing empty-workspace behaviour), which retracts the overlay.

## Tests

- `tests/tst_windowscope.qml`: every `special:*` workspace hidden; unknown
  location fails open; minimized window with a normal origin retained;
  minimized window with an unresolvable origin retained.
- `tests/tst_sidebarcontroller.qml`: a toplevel on `special:scratchpad` produces
  no row and no registry entry.
- `~/.config/hypr/tests/alttab.lua`: a mapped, visible special-workspace window
  is skipped; existing MRU, Parsec, rotation and logging cases unchanged.

## Left to the builder

- Exact helper naming and whether to expose a named predicate alongside
  `filterToplevelsByScope`.
- Whether the sidebar controller calls the filter directly or through a host
  property, as long as one function owns the rule.
