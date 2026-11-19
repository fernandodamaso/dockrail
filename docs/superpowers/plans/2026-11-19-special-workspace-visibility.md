# Special Workspaces Invisible to Dockrail and Alt+Tab — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Windows on any Hyprland special workspace stop producing Dockrail dock icons, sidebar rows and Alt+Tab candidates, while Dockrail-minimized windows keep their recorded origin.

**Architecture:** One predicate in `components/DockWindowModel.js` decides whether a resolved window location is presentation-visible. The flat dock already filters through `filterToplevelsByScope`, so the predicate is applied there; the grouped dock (`Dock.qml`) and the sidebar controller (`DockSidebarController.qml`) feed the same helper's output into `DesktopModel.build`. The Hyprland Alt+Tab switcher gains the same rule against `w.workspace.special`.

**Tech Stack:** QML/Qt 6, Quickshell, plain JavaScript model files, `qmltestrunner`; Hyprland 0.56 Lua config (`hl.*` API).

**Spec:** `docs/superpowers/specs/2026-11-19-special-workspace-visibility-design.md`

## Global Constraints

- A location is hidden only when `workspaceKnown === true` and `workspace` starts with `special:`. Unknown locations fail open.
- `special:smartdock-minimized` must resolve to its recorded origin before the predicate runs; do not special-case the workspace name in the predicate.
- No new `dock.json` key, CLI flag or Settings row.
- One rule, one function: neither the dock nor the sidebar may reimplement the check.
- All work happens in the worktree `/home/admin/.t3/worktrees/dockrail/fix-scratchpad-visibility` on branch `fix/scratchpad-invisible`.
- Never edit `/home/admin/.config/omarchy/plugins/...` deployment copies.

## Review Focus

1. A window Dockrail minimized whose origin cannot be resolved must stay visible (fail open), not vanish.
2. A minimized window whose recorded origin is itself a special workspace must stay hidden.
3. A newly mapped window with no Hyprland record yet (unknown location) must stay visible.
4. An app with one normal window and one scratchpad window keeps its icon and count from the normal window only.
5. Alt+Tab pressed while the shown scratchpad holds focus must leave the scratchpad, never trap focus.

---

### Task 1: Presentation predicate and scope filter

**Files:**
- Modify: `components/DockWindowModel.js` (after `locationMatchesContext`, around line 305)
- Test: `tests/tst_windowscope.qml`

**Interfaces:**
- Consumes: `locationForToplevel(toplevel, handles, originSnapshot)` (existing), which already resolves `special:smartdock-minimized` to its origin.
- Produces:
  - `isSpecialWorkspace(identity) -> boolean`
  - `locationHiddenFromPresentation(location) -> boolean`
  - `filterPresentationToplevels(toplevels, handles, originSnapshot) -> array` (preserves input order and object identity)
  - `filterToplevelsByScope` now drops hidden locations before the scope test.

- [ ] **Step 1: Write the failing tests**

Append to `tests/tst_windowscope.qml` (inside `TestCase`, next to the other `hasFunction` helpers):

```qml
  function test_presentationHidesEverySpecialWorkspace() {
    if (!hasFunction("filterPresentationToplevels")) return

    var normal = window("normal")
    var scratch = window("scratch")
    var magic = window("magic")
    var handles = [
      handle(normal, "0x1", 2, "2", 1, false),
      handle(scratch, "0x2", -98, "special:scratchpad", 1, false),
      handle(magic, "0x3", -99, "special:magic", 1, false)
    ]
    var filtered = DockWindowModel.filterPresentationToplevels(
      [normal, scratch, magic], handles, {})
    compare(filtered.length, 1)
    compare(filtered[0], normal)
    compare(DockWindowModel.locationHiddenFromPresentation(
      { workspace: "special:scratchpad", workspaceKnown: true }), true)
    compare(DockWindowModel.locationHiddenFromPresentation(
      { workspace: "", workspaceKnown: false }), false)
  }

  function test_presentationFailsOpenForUnknownAndMinimizedWindows() {
    if (!hasFunction("filterPresentationToplevels")) return

    var fresh = window("fresh")
    var minimized = window("min")
    var handles = [
      handle(minimized, "0xbbb", -99, "special:smartdock-minimized", 0, false)
    ]
    compare(DockWindowModel.filterPresentationToplevels(
      [fresh, minimized], handles, {}).length, 2)
  }

  function test_presentationKeepsMinimizedOriginAndHidesSpecialOrigin() {
    if (!hasFunction("filterPresentationToplevels")) return

    var minimized = window("min")
    var handles = [
      handle(minimized, "0xccc", -99, "special:smartdock-minimized", 1, false)
    ]
    compare(DockWindowModel.filterPresentationToplevels(
      [minimized], handles,
      { "0xccc": { workspace: "id:3", monitor: "id:1" } }).length, 1)
    compare(DockWindowModel.filterPresentationToplevels(
      [minimized], handles,
      { "0xccc": { workspace: "special:scratchpad", monitor: "id:1" } }).length, 0)
  }

  function test_scopeFilterHidesSpecialWorkspacesInAllScope() {
    if (!hasFunction("filterToplevelsByScope")) return

    var normal = window("normal")
    var scratch = window("scratch")
    var handles = [
      handle(normal, "0x1", 2, "2", 1, false),
      handle(scratch, "0x2", -98, "special:scratchpad", 1, false)
    ]
    var filtered = DockWindowModel.filterToplevelsByScope(
      [normal, scratch], handles, {}, context("all", 2, "2", 1, true))
    compare(filtered.length, 1)
    compare(filtered[0], normal)
  }
```

- [ ] **Step 2: Run the tests to verify they fail**

```bash
cd /home/admin/.t3/worktrees/dockrail/fix-scratchpad-visibility
QML_XHR_ALLOW_FILE_READ=1 QT_QPA_PLATFORM=offscreen /usr/lib/qt6/bin/qmltestrunner \
  -input tests/tst_windowscope.qml -import components -import tests/qml-imports
```

Expected: the four new cases report failures (`filterPresentationToplevels must be implemented` or a failing compare); existing cases still pass.

- [ ] **Step 3: Implement the predicate**

In `components/DockWindowModel.js`, directly after `locationMatchesContext`:

```js
function isSpecialWorkspace(identity) {
  return String(identity || "").indexOf("special:") === 0
}

// Special workspaces are overlays, not desktop space: nothing they hold belongs
// in the dock or sidebar. Unknown locations fail open, and Dockrail's own
// minimized workspace resolves to its recorded origin before this check.
function locationHiddenFromPresentation(location) {
  var value = location || ({})
  return value.workspaceKnown === true && isSpecialWorkspace(value.workspace)
}

function filterPresentationToplevels(toplevels, handles, originSnapshot) {
  var values = toplevels || []
  var result = []
  for (var i = 0; i < values.length; ++i) {
    if (!values[i]) continue
    if (locationHiddenFromPresentation(
      locationForToplevel(values[i], handles, originSnapshot))) continue
    result.push(values[i])
  }
  return result
}
```

Then in `filterToplevelsByScope`, add the check immediately after `var location = locationForToplevel(...)` and before `locationMatchesContext`:

```js
    if (locationHiddenFromPresentation(location)) continue
```

- [ ] **Step 4: Run the tests to verify they pass**

Run the Step 2 command. Expected: PASS for all `WindowScope` cases.

- [ ] **Step 5: Commit**

```bash
git add components/DockWindowModel.js tests/tst_windowscope.qml
git commit -m "fix: hide special-workspace windows from dock presentation"
```

---

### Task 2: Grouped dock consumes the filtered inventory

**Files:**
- Modify: `components/Dock.qml` (property block near `filteredToplevels`, and `refreshVisibleItems` around line 673)
- Test: `tests/tst_desktopmodel.qml`

**Interfaces:**
- Consumes: `DockWindowModel.filterPresentationToplevels` from Task 1.
- Produces: `Dock.presentationToplevels` — a `var` property bound to `scopeRevision`, holding every live toplevel except those on a known special workspace.

- [ ] **Step 1: Write the failing test**

Append to `tests/tst_desktopmodel.qml`:

```qml
  function test_groupedPresentationDropsSpecialWorkspaceWindows() {
    var normal = { appId: "example.browser", title: "Normal" }
    var scratch = { appId: "example.browser", title: "Scratch" }
    var input = snapshot("classic-grouped")
    input.toplevels = [normal, scratch]
    input.filteredToplevels = [normal]
    input.hyprToplevels = [
      { wayland: normal, address: "0xa",
        lastIpcObject: { workspace: { id: 1 }, monitor: 0 } },
      { wayland: scratch, address: "0xb",
        lastIpcObject: { workspace: { id: -98, name: "special:scratchpad" }, monitor: 0 } }
    ]
    var filtered = DockWindowModel.filterPresentationToplevels(
      input.toplevels, input.hyprToplevels, input.minimizedOrigins)
    compare(filtered.length, 1)
    input.toplevels = filtered
    var result = DesktopModel.build(input)
    var group = result.workspacePresentation.groups.filter(function(value) {
      return value.identity === "id:1"
    })[0]
    compare(group.items.length, 1)
    compare(group.items[0].toplevels.length, 1)
    compare(result.workspacePresentation.fallbackItems.length, 0)
  }
```

Add `import "../components/DockWindowModel.js" as DockWindowModel` to the test's imports.

- [ ] **Step 2: Run the test to verify it fails**

```bash
cd /home/admin/.t3/worktrees/dockrail/fix-scratchpad-visibility
QML_XHR_ALLOW_FILE_READ=1 QT_QPA_PLATFORM=offscreen /usr/lib/qt6/bin/qmltestrunner \
  -input tests/tst_desktopmodel.qml -import components -import tests/qml-imports
```

Expected: FAIL on the `group.items.length` or `fallbackItems.length` assertion (the scratchpad window lands in `fallbackItems`).

- [ ] **Step 3: Bind the filtered inventory in `Dock.qml`**

Add immediately after the existing `filteredToplevels` property:

```qml
  // Special workspaces are overlays; their windows never reach the dock build.
  readonly property var presentationToplevels: {
    var revision = scopeRevision
    return DockWindowModel.filterPresentationToplevels(
      toplevels, hyprToplevels,
      windowActions ? windowActions.minimizedOriginsSnapshot : ({}))
  }
```

In `refreshVisibleItems`, replace the grouped build inputs:

```qml
      toplevels: toplevels,
      windowRuleMatches: toplevels.map(function(toplevel) {
```

with:

```qml
      toplevels: presentationToplevels,
      windowRuleMatches: presentationToplevels.map(function(toplevel) {
```

Leave `filteredToplevels: filteredToplevels` unchanged: Task 1 already excludes specials there.

- [ ] **Step 4: Run the tests to verify they pass**

Run the Step 2 command. Expected: PASS for all `DesktopModel` cases.

- [ ] **Step 5: Lint the changed surface**

```bash
cd /home/admin/.t3/worktrees/dockrail/fix-scratchpad-visibility
/usr/lib/qt6/bin/qmllint -I "$OMARCHY_PATH/shell" components/Dock.qml
```

Expected: no errors (warnings unchanged from `main`).

- [ ] **Step 6: Commit**

```bash
git add components/Dock.qml tests/tst_desktopmodel.qml
git commit -m "fix: build grouped dock from presentation-visible windows"
```

---

### Task 3: Sidebar consumes the filtered inventory

**Files:**
- Modify: `components/DockSidebarController.qml` (properties near line 27; `refreshBody` lines 460, 516-521)
- Test: `tests/tst_sidebarcontroller.qml`

**Interfaces:**
- Consumes: `WindowModel.filterPresentationToplevels` from Task 1; `root.minimizedOrigins` (existing, default `({})`).
- Produces: `DockSidebarController.presentationToplevels` — every sidebar-visible toplevel; used for registry keys, the desktop build and `windowRuleMatches`.

- [ ] **Step 1: Write the failing test**

Append to `tests/tst_sidebarcontroller.qml`:

```qml
  function test_scratchpadWindowProducesNoRowOrRegistryEntry() {
    var a = createTemporaryObject(toplevelFactory, this, {title:"Normal"})
    var b = createTemporaryObject(toplevelFactory, this, {title:"Scratch"})
    var screen = {name:"DP-1",width:1920,height:1080}
    var c = createTemporaryObject(factory, this, {
      settings: {presentationMode:"sidebar",pinned:[],workspaceGroups:[],sidebarCollapsed:false},
      screens:[screen], monitors:[{id:0,name:"DP-1",activeWorkspace:{id:1}}],
      workspaces:[{id:1,monitorID:0}], toplevels:[a,b],
      hyprToplevels:[{wayland:a,address:"0xa",lastIpcObject:{workspace:{id:1},monitor:0}},
        {wayland:b,address:"0xb",lastIpcObject:{workspace:{id:-98,name:"special:scratchpad"},monitor:0}}]
    })
    verify(c !== null)
    c.refresh()
    compare(c.presentationToplevels.length, 1)
    compare(c.presentationToplevels[0], a)
    compare(c.registry.entries.length, 1)
    var windows = c.projection.rows.filter(function(r) {return r.kind === "window"})
    compare(windows.length, 1)
  }
```

- [ ] **Step 2: Run the test to verify it fails**

```bash
cd /home/admin/.t3/worktrees/dockrail/fix-scratchpad-visibility
QML_XHR_ALLOW_FILE_READ=1 QT_QPA_PLATFORM=offscreen /usr/lib/qt6/bin/qmltestrunner \
  -input tests/tst_sidebarcontroller.qml -import components -import tests/qml-imports
```

Expected: FAIL — `presentationToplevels` is undefined and the scratchpad window still produces a row.

- [ ] **Step 3: Add the property and use it in `refreshBody`**

Add after `property var minimizedOrigins: ({})`:

```qml
  // Special workspaces are overlays; their windows never reach sidebar rows,
  // folds, browser tabs or registry keys.
  readonly property var presentationToplevels: {
    var revision = root.scopeRevision
    return WindowModel.filterPresentationToplevels(
      root.toplevels, root.hyprToplevels, root.minimizedOrigins)
  }
```

In `refreshBody`:

- `SidebarModel.reconcileHandles(root.registry, root.toplevels)` → `root.presentationToplevels`
- `toplevels: root.toplevels,` in the `DesktopModel.build` call → `toplevels: root.presentationToplevels,`
- `windowRuleMatches: root.toplevels.map(...)` → `root.presentationToplevels.map(...)`
- `filteredToplevels: root.toplevels,` → `filteredToplevels: root.presentationToplevels,`

Do not change the action paths that resolve a handle for an existing row (`root.toplevels` stays correct there).

- [ ] **Step 4: Run the tests to verify they pass**

Run the Step 2 command. Expected: PASS for all `SidebarController` cases.

- [ ] **Step 5: Commit**

```bash
git add components/DockSidebarController.qml tests/tst_sidebarcontroller.qml
git commit -m "fix: keep special-workspace windows out of the sidebar"
```

---

### Task 4: Documentation, full headless gate, PR

**Files:**
- Modify: `docs/CONFIGURATION.md` (after the "Workspace cards and window filtering" paragraph, line 104)
- Modify: `CHANGELOG.md` (top `Unreleased` section)

**Interfaces:**
- Consumes: completed behavior from Tasks 1–3.
- Produces: reviewed PR against `main`, `Headless CI` green, exact base/head SHAs recorded.

- [ ] **Step 1: Document the rule**

Add to `docs/CONFIGURATION.md` after the existing paragraph:

```markdown
Windows on a Hyprland special workspace (`special:*`, including the scratchpad) are never presented as dock icons or sidebar rows, in any `windowScope`. Special workspaces are overlays rather than desktop space, so their windows contribute no items, counts, folds or browser-tab groups. Dockrail's own `special:smartdock-minimized` windows keep their recorded origin and stay visible; a window whose origin cannot be resolved fails open.
```

Add a `CHANGELOG.md` bullet under `Unreleased`, matching the file's existing tone:

```markdown
- Hide windows on Hyprland special workspaces (the scratchpad) from the dock and sidebar in every window scope.
```

- [ ] **Step 2: Run the full headless gate**

```bash
cd /home/admin/.t3/worktrees/dockrail/fix-scratchpad-visibility
QML_XHR_ALLOW_FILE_READ=1 QT_QPA_PLATFORM=offscreen /usr/lib/qt6/bin/qmltestrunner \
  -input tests -import components -import tests/qml-imports
bash -n install.sh uninstall.sh scripts/dockrail scripts/run tests/check_window_actions.sh
git diff --check
```

Expected: `Totals` with 0 failures, shell syntax silent, `git diff --check` silent.

- [ ] **Step 3: Commit and open the PR**

```bash
git add docs/CONFIGURATION.md CHANGELOG.md
git commit -m "docs: record special-workspace visibility rule"
git push -u origin fix/scratchpad-invisible
gh pr create --draft --base main \
  --title "Hide special-workspace windows from dock and sidebar" \
  --body "Windows on Hyprland special workspaces (the scratchpad) no longer produce dock icons, sidebar rows, folds or tab groups. Dockrail-minimized windows keep their recorded origin; unknown locations fail open.

Spec: docs/superpowers/specs/2026-11-19-special-workspace-visibility-design.md
Plan: docs/superpowers/plans/2026-11-19-special-workspace-visibility.md

base: $(git rev-parse origin/main)
head: $(git rev-parse HEAD)"
```

Link the PR, then watch it until `Headless CI` reports.

- [ ] **Step 4: Live check on the development desktop (after CI)**

Only with the user's go-ahead: `dockrail dev use fix/scratchpad-invisible`, confirm the grok-bot window on `special:scratchpad` has no dock icon and no sidebar row while the scratchpad is shown, then `dockrail dev reset`. A second dock must never run beside the production plugin.

---

### Task 5: Alt+Tab never cycles special workspaces

**Files:**
- Modify: `/home/admin/.config/hypr/keymap/alttab.lua` (`switchable()`, lines 32-37)
- Modify: `/home/admin/.config/hypr/tests/alttab.lua`
- Modify: `/home/admin/.config/omarchy/agents/CHANGELOG.md`

**Interfaces:**
- Consumes: `HL.Window.workspace` with `HL.Workspace.special` (`/usr/share/hypr/stubs/hl.meta.lua:809`).
- Produces: no API; behavior only.

- [ ] **Step 1: Add the failing test case**

In `/home/admin/.config/hypr/tests/alttab.lua`, before the `io.open, os.rename = real_open, real_rename` line:

```lua
-- Special workspaces are an invisible overlay: never a candidate, even shown.
press("ALT + ALT_L")
local scratch_window = window("0xs", 0)
scratch_window.workspace = { id = -98, name = "special:scratchpad", special = true }
windows = { scratch_window, a, b }
scratch_window.focus_history_id, a.focus_history_id, b.focus_history_id = 0, 1, 2
active = a
press("ALT + TAB"); target("0xb")
press("ALT + ALT_L")
-- Focus inside a shown scratchpad leaves it for the newest normal window.
active = scratch_window
press("ALT + TAB"); target("0xb")
press("ALT + ALT_L")
```

Extend the final `print(...)` summary with `, scratchpad exclusion`.

- [ ] **Step 2: Run the test to verify it fails**

```bash
lua /home/admin/.config/hypr/tests/alttab.lua
```

Expected: assertion failure at the first new `target("0xb")` — the scratchpad window is selected instead (`0xs`).

- [ ] **Step 3: Exclude special workspaces in `switchable()`**

```lua
local function switchable(w)
  -- The scratchpad and every other special workspace are an invisible overlay:
  -- never hand them focus, even while the overlay is shown.
  if w.workspace and w.workspace.special then return false end
  -- Wispr keeps its transparent, pinned status surface mapped while invisible.
  local wispr_status = ...
```

- [ ] **Step 4: Run the test to verify it passes**

```bash
lua /home/admin/.config/hypr/tests/alttab.lua
```

Expected: `PASS: MRU order, ... , scratchpad exclusion`.

- [ ] **Step 5: Commit in the Hyprland repo and record the change**

```bash
cd /home/admin/.config/hypr
git add keymap/alttab.lua tests/alttab.lua
git commit -m "alttab: never cycle windows living on a special workspace"
```

Then add the task line to `/home/admin/.config/omarchy/agents/CHANGELOG.md` following that file's existing format.

---

## Verification summary

- `tests/tst_windowscope.qml`, `tests/tst_desktopmodel.qml`, `tests/tst_sidebarcontroller.qml`, and the full headless suite pass.
- `lua /home/admin/.config/hypr/tests/alttab.lua` passes.
- Live check (user-approved) shows no grok-bot icon/row while the scratchpad is shown, and Alt+Tab never lands inside it.
