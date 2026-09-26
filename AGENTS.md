# AGENTS.md

## Project overview

Dockrail is a Hyprland developer workspace rail implemented with Quickshell and Qt/QML. It runs either as a standalone Quickshell configuration or as an Omarchy Quattro overlay plugin hosted by the existing Omarchy shell.

## Development

- The canonical source checkout is `/home/admin/Projects/smart-omarchy-dock`.
- Installed Omarchy plugin checkouts are read-only deployment state; never edit
  them directly. Push validated changes from the source checkout, then update
  the installed plugin through `omarchy plugin update`.
- For user-requested visual testing on this development desktop, use
  `dockrail dev use <worktree-or-local-branch>` and `dockrail dev reset` to
  return to the installed copy. No PR or merge is required for this local
  preview. This swaps the existing plugin source; never start a second dock.
  See `docs/DEV_SWITCH.md`. Only run `omarchy plugin update` after resetting;
  while linked, it could update the source worktree itself.
- Releases are cut from validated `main`. Imports from `upstream` are explicit
  review work on a dedicated branch and must pass the complete validation gate.
- Follow `docs/DELIVERY.md` for PR-only delivery, exact-SHA evidence, protected-main
  policy, and stacked-branch retarget/rebuild rules. Never merge a local feature
  branch directly onto `main` and push that merge as feature delivery.
- Run the dock with `./scripts/run`.
- Keep the standalone entry point at `shell.qml` and the Omarchy plugin entry point at `Overlay.qml`.
- Keep shared host behavior in `DockHost.qml`; never start a second Quickshell process from the plugin.
- Keep window lifecycle actions and Dockrail-minimized origins in the single
  `DockWindowActions` instance owned by `DockHost.qml`; per-screen docks and
  context menus must consume that shared controller rather than duplicate it.
- Put reusable visual components in `components/`.
- Keep user-facing defaults in `config/dock.json`; `DockControl` loads them for
  both host modes. Keep CLI metadata in `config/settings-schema.json` and retain
  compatible runtime normalization in `DockModel.js`.
- Installed user settings use the canonical `~/.config/dockrail/dock.json`; the managed legacy `~/.config/smartdock` alias remains a compatibility path after migration. Updates must never overwrite user settings.
- Keep `install.sh`, `uninstall.sh`, `scripts/dockrail`, and the `scripts/smartdock` compatibility shim compatible with custom XDG directory variables.
- Prefer Quickshell APIs over shelling out to external commands.
- Use freedesktop desktop-entry IDs without the `.desktop` suffix.
- Preserve live configuration reloads.

## Omarchy UI conventions

Dockrail should compose Omarchy's native visual system instead of growing a
parallel generic component library.

When proposing or implementing a UI refactor:

- Inspect the Omarchy revision Dockrail targets before creating a generic
  visual/control component. Review `shell/Ui/`, `shell/Commons/`, and
  representative current first-party `shell/plugins/` call sites; on an
  installed system these live under `$OMARCHY_PATH/shell/`.
- Prefer `qs.Ui` composition for generic buttons, toggles, dropdowns, panels,
  popup surfaces, inputs, separators, tooltips, and similar primitives when the
  native component matches the required interaction, focus/keyboard,
  geometry/anchoring, state, and host contract.
- Use `qs.Commons` `Color`, `Style`, `Border`, and `Util` for semantic colors,
  spacing, typography, borders, opacity/state styling, and related design
  tokens. Do not hardcode visual values when a suitable Omarchy semantic token
  exists.
- Keep custom Dockrail components when they own material dock-specific
  behavior or simplify genuinely repeated domain composition. Examples include
  dock magnification/drag behavior, application/window/workspace semantics,
  badges, dock-relative popup geometry, and shared window-action lifecycle.
- Decision rule: replace generic UI duplication only when a current native
  primitive meaningfully removes duplicated code without weakening the
  Dockrail-specific contract. Visual similarity alone is not enough.
- Treat `docs/FDM-858-native-ui-audit.md` as historical rationale only, not as a
  current component inventory or test checklist. Do not restore the deleted
  FDM-918 Settings implementation or its obsolete validation paths. The accepted
  Dockrail 3.1 human Settings surface is recorded in `docs/SETTINGS.md`; new UI
  must follow that record and this maintenance check instead of reviving old
  components.

### UI refactor maintenance check

For each future native-UI refactor:

1. Record the exact Omarchy revision inspected.
2. Inspect the current primitive implementation and at least one first-party
   usage that matches the intended context.
3. Compare the required Dockrail contract: orientation/sizing,
   focus/keyboard/pointer behavior, popup anchoring/lifecycle,
   disabled/active states, theming, and host mode.
4. If the native primitive matches, compose it and retain only the Dockrail
   domain logic around it; if it does not, keep the custom component and reuse
   Omarchy semantic tokens/helpers where appropriate.
5. Validate only the current affected surface and tests; never treat the
   historical FDM-858 commands as live qualification.

## Sidebar Widget development

Before creating or modifying a Dockrail sidebar Widget, read
`docs/SIDEBAR_WIDGETS.md` for registry/provider/lifecycle ownership and
`docs/WIDGET_COMPONENTS.md` for the reusable `Widget*` component API. Start
from `tests/widget-gallery/WidgetGallery.qml` or a
`components/widgets/DemoWidget*Body.qml` composition.

Do not invent a second provider lifecycle, settings writer, card shell, normal
scroll area, popup manager, typography system, semantic color palette, or generic
form/action control when the existing Widget framework owns it. New Widget UI
should compose `components/widgets/` primitives first; custom presentation code
must be justified by a contract the kit does not already cover.

FDM-999 assigns one hierarchy scroll owner and one independent Widget body scroll
owner per panel; the section header and pinned/footer controls stay fixed.
Preserve natural-demand allocation, per-panel stable-ID anchors, nested-control
first refusal and the existing single host-owned provider/settings/popup owners.
See `docs/FDM-999-split-scroll-handoff.md` for the exact remote/native boundary.

External Widget packages are a different source boundary from Dockrail core.
Create them in a separate repository/directory with `dockrail widget create`,
install or select development sources with the `dockrail widget` package API,
and import the public `Dockrail.WidgetKit 1.0` module. Never develop external
Widget source inside the canonical Dockrail checkout, an installed Omarchy
plugin deployment, or `${XDG_DATA_HOME:-$HOME/.local/share}/smartdock`.
`dock.json` stores Widget IDs only; package paths and executable QML are owned
by the package registry under the canonical Dockrail XDG data root; migrated legacy package paths resolve through managed compatibility aliases. See
`docs/WIDGET_PACKAGES.md`.

## Configuration workflow

Use `dockrail status --json`, `dockrail config schema --json`, and
`dockrail config get --json` to discover the selected running host before a
minimal CLI mutation. The host-reported config path is authoritative. Read
`docs/AGENT_CONFIGURATION.md` for backup, typed patches, app/icon intents,
requested/effective readback, persistence and touched-key rollback. The complete
command contract and inventory are `docs/CLI_REFERENCE.md` and
`docs/CONFIGURATION.md`. `bash ./install.sh --cli-only` installs the client and
offline documentation; it must not start another dock or alter live settings.

Configuration requests must not edit a deployed checkout, scrape the UI, or
silently fall back to raw dock.json writes when a command is unsupported. Use
runtime metadata, preserve unknown keys and collection order, dry-run related
patches, then read back effective values and actual persistence. Never execute
controlCommand for validation. Source work is reserved for an explicitly
requested unsupported feature or an evidenced defect under its owning issue.

Configuration has two audiences. The CLI remains the complete configuration
interface for AI coding agents and automation. Dockrail 3.1 also has an accepted
Settings-panel design for people, recorded in `docs/SETTINGS.md`; SET-01 is the
policy/design foundation and does not ship that UI. Both interfaces must submit
the same host intents through the single host FileView/settings writer, with the
same applied, persisted and readback semantics. QML must never become a second
writer or edit `dock.json` directly.

Icon artwork (application, browser profile and window-title rules) continues to
use **Change Icon** from the context menu; **Change Icon** remains the sole icon
editor. Menus lazily cache dialog instances, and the accepted Settings panel
shares the host-wide single active editing slot with Change Icon. Saves from
Change Icon keep using `DockHost.saveIconChange` and the existing FileView
writer. Do not add a second config writer, preview-only preferences, another icon
editor, or any Settings surface outside the accepted 3.1 design. Retain ordinary
window previews, the app picker, dock menus, drag reordering and live theme
bindings.

The host's FileView remains the only live settings writer. Saved settings and
verified rendering are separate facts; headless tests do not qualify Omarchy
focus, auto-hide scheduling, image decoding or cache behavior.

The CLI-first branch is an unreleased Draft candidate, not permission to deploy.
After remote FDM-919 hands off an exact SHA, pause remote branch writes while the
local FDM-920 owner performs `docs/CLI_RUNTIME_CHECKS.md`, sharing surviving icon
checks with FDM-885. Preserve independent branches and scope shared documentation
edits; do not absorb unrelated workspace-drag work. AI owns source review, fixes
and test acceptance; unavailable physical/runtime checks remain explicit gates.

## Validation

GitHub `Headless CI` runs the host-independent subset documented in
`docs/DELIVERY.md`. Before committing runtime changes, also run the full local
validation gate when the owning issue requires it:

```bash
timeout 6s ./scripts/run --no-color
bash -n install.sh uninstall.sh scripts/dockrail scripts/dockrail scripts/run tests/check_window_actions.sh
python3 -m py_compile scripts/dockrail_paths.py scripts/dockrail_migrate.py
QML_XHR_ALLOW_FILE_READ=1 QT_QPA_PLATFORM=offscreen /usr/lib/qt6/bin/qmltestrunner -input tests -import components -import tests/qml-imports
omarchy plugin validate .
/usr/lib/qt6/bin/qmllint -I "$OMARCHY_PATH/shell" \
  Overlay.qml DockHost.qml components/Dock.qml components/DockItem.qml \
  components/DockContextMenu.qml components/DockControlItem.qml \
  components/DockWindowActions.qml shell.qml
git diff --check
```

Run source-host smoke checks only in the owning issue's isolated display/config
context, never by launching a second dock beside the production plugin. A portal
warning about an application ID already being registered can occur when another
Quickshell process is running; it is not by itself a dock failure.

For dock rendering, input, and screenshot checks during source work, use a fresh
named KVM guest as described in `docs/DEV_SESSIONS.md`. Sync the current worktree
after edits, restart the guest dock, collect guest evidence, and stop the session.
Use standalone mode by default; the plugin guest runs a stripped Omarchy shell
and does not replace required checks in a full Omarchy desktop.

The KVM default is for autonomous agent checks. A user's explicit request to
try a version on their desktop authorizes the local switch workflow above.

## Style

- Use two-space indentation in QML.
- Keep JavaScript helpers small and local to the component that owns the behavior.
- Add new configuration options to `config/dock.json`, the CLI schema, the tested
  configuration inventory and the README.
