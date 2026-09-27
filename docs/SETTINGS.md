# Dockrail Settings 3.1 — accepted design record

## Status and evidence

This document records the owner-accepted Dockrail 3.1 Settings design from FDM-1022/FDM-1023, accepted on 2026-09-26 (canvas version 5).

**SET-01 is documentation and policy only. The Settings UI is not shipped by this change.** UI implementation starts in later SET issues after the schema metadata foundation. Accepted entry points, IPC, and the `dockrail settings` command described below are design requirements, not claims about the current executable surface.

The design pass inspected **Omarchy 4.0.4** and compared its first-party network, audio, and Bluetooth panel patterns. The review snapshot recorded in FDM-1022 was Dockrail `main@2889f13`.

Owner-accepted canvas: https://claude.ai/artifact/2hMEW7BB2rGoakSLF3sM3b

## Policy: two audiences, one writer

Dockrail has two configuration audiences:

- **AI coding agents and automation use the CLI.** It remains the complete agent interface.
- **People use Settings.** The accepted Settings panel makes ordinary configuration discoverable without requiring a terminal.
- Both interfaces submit the same host intents through the **single host FileView/settings writer**. They share the same validation, latest-state application, persistence, retry, and readback semantics.
- QML does not write `dock.json` directly. There is no second writer and no preview-only preference layer.
- **Change Icon is the sole icon editor.** Settings can hand the shared editing slot to Change Icon, but must not implement another icon editor.
- The accepted 3.1 surface in this document is the boundary. Do not add another Settings/preferences surface outside it.

## Surface

Settings is a single host-owned Omarchy **`KeyboardPanel`**, approximately **680 px wide**, with **two panes**:

1. section navigation and search on the left;
2. the selected section's controls on the right.

There is one host-wide instance, not one instance per screen. It is dock-anchored, moves to the monitor that opened it, and grows with content until the monitor limit, then scrolls.

The accepted entry points for later implementation are Dock Controls, the sidebar/icon-rail header, an IPC target, and `dockrail settings`. All entry points open the same host-owned panel.

## Sections and setting homes

Each setting has one home. Features is setup/readiness only; it does not duplicate toggles that belong to another section.

| Section | Home |
| --- | --- |
| **Appearance** | Icon size, hover magnification and reach, hover glow, background opacity, interface animations, theme/custom colours, and theme/custom border width. |
| **Layout** | Per-monitor Classic/Sidebar presentation, sidebar edge/width, classic auto-hide/reserved space/margin, and one Workspaces group containing workspace mode and its dependent settings. |
| **Behavior · Pointer** | Left click, middle click, and scroll actions. Destructive actions such as closing an app's windows are marked as destructive. |
| **Behavior · Windows** | Window previews and window behavior controls. |
| **Behavior · Attention** | Attention badges, urgent nudge, launcher badge style/count behavior, and Herdr agent state on terminal icons. |
| **Sidebar & Widgets** | Enabled/ordered sidebar widgets, including `herdr.agents`; compact workspace rows; Chrome tabs under windows. Widget collapse state stays on the card. |
| **Features** | Readiness and setup guidance for Chrome profiles/tabs, Herdr, launcher counts, and terminal agent launchers. It consumes the shared host readiness projection when ONB-05 lands; Settings does not implement separate detection. |
| **Apps** | Pinned apps, hidden apps, Show Trash, and discovery/reset of custom-icon rules by handing off to Change Icon. |
| **Apps · Chrome** | Chrome profile badges and muted unread services. |
| **Apps · Advanced** | `controlCommand`, saved explicitly and never executed by Settings. |
| **Search** | Search across schema labels, keys, and help text, returning the owning section and jumping to the row. |
| **First run / legacy** | Welcome content only when no `dock.json` exists; one-click conversion of legacy `sidebarMonitor` to per-monitor choices. |

Four schema keys are intentionally not ordinary generated controls: `position` is shown as the fixed classic placement, `groupWindows` is deprecated, `sidebarWidgetCollapsed` is edited in place on its widget card, and legacy `sidebarMonitor` appears through the conversion banner.

## Interaction rules

- **Apply on change.** Ordinary controls submit an actual host write; there is no hidden preview state.
- **Sliders commit on release.** Keyboard stepping settles before commit; shown values follow effective normalization rather than pretending every requested intermediate value is renderable.
- **Paired theme controls write one patch.** Colour and border-width controls offer **Theme default** or a custom value; choosing a custom value updates its paired enabled flag atomically.
- **Dependencies come from schema metadata.** Disabled/dependent controls use readable dim help text. Amber is reserved for real warnings.
- **Classic collapse rule.** When no connected monitor uses the classic dock, classic-only groups collapse into one “Classic dock: not in use on any monitor” row instead of filling the page with inactive controls.
- **One-monitor presentation writes that monitor's own entry.** With one monitor, Settings shows **Classic dock | Sidebar**; the multi-monitor matrix appears only with two or more monitors.
- **One editing slot.** Settings shares the host-wide editing slot with Change Icon. Opening one closes the other; late results from the old editing surface must not win.
- **Live updates are visible.** CLI or other accepted host writes update the open page. A changed row is marked “Changed elsewhere” rather than silently overwriting an active text draft.
- **Stale text drafts conflict explicitly.** An `E_STALE` response produces a conflict prompt; it is not auto-retried over newer state.
- **Per-row reset is retained.** Reset acts through the same host writer and does not restore the removed page's broad hidden reset behavior.
- **Setup commands are copy-only.** Settings never runs installers or restarts the shell. Feature guidance uses the accepted `dockrail setup --feature ...` commands, with installed-plugin-folder instructions as fallback.
- `controlCommand` is visible only under Advanced and is **never executed for validation or by Settings**.
- Right-click menus and drag interactions remain the primary in-dock app-management interactions; Settings provides a discoverable place to review and undo them.

## Save, live-update, and error states

| State | Accepted behavior |
| --- | --- |
| **Saving** | A write is in progress; do not send a duplicate mutation as though the first were rejected. |
| **Saved** | Confirm the durable write, then fade the Saved indicator after about two seconds. |
| **Not saved** / `E_PERSISTENCE` | Keep the applied live value visible, pin the error, and offer **Retry** through the same persistence retry path as `config retry`. |
| `E_VALIDATION` | Reject the write and keep the user's field text so it can be corrected. |
| `E_CONFIG_INVALID` | Make Settings read-only until the invalid configuration is repaired; do not replace it with defaults. |
| **Changed elsewhere** | Reflect a live host update and highlight the affected row. |
| `E_STALE` | For an active text draft, show a conflict decision instead of overwriting the newer value. |
| **Requested vs shown** | Preserve requested intent while displaying normalized/effective values honestly. |

Errors remain pinned until resolved. Informational Saved feedback is transient.

## Lessons from the removed Settings page

FDM-918 removed the previous Settings implementation in commit `0dbd7c54151577457deb45b3cf282b37fb2fc258`. The accepted 3.1 design deliberately avoids the failure modes captured during that removal and the FDM-1022 review:

| Removed-page problem | 3.1 correction |
| --- | --- |
| A Settings surface was created per screen. | One host-owned panel and one editing session. |
| Hidden preview state could diverge from saved state. | No preview-only preferences; every change uses the real host writer. |
| Write failures had no honest UI state. | Saving/Saved/Not saved, validation, invalid-config, stale, and retry states are explicit. |
| Reset could broadly reset preferences, including executable `controlCommand`. | Settings uses schema-driven, scoped controls and per-row reset; `controlCommand` is Advanced and never executed. |
| A hand-built `PanelWindow`, focus timers, and a separate component kit duplicated shell behavior. | Compose Omarchy `qs.Ui` controls and `qs.Commons` tokens around Dockrail-specific behavior. |
| About 1,379 hardcoded QML lines covered only part of the settings and drifted from the CLI/schema. | Generate controls from `config/settings-schema.json` UI metadata; one home per key. |
| Validation mostly grepped QML text. | Later SET implementation tests exercise the real host writer, persistence errors/retry, stale writes, live updates, and panel ownership. |

Do not restore the deleted FDM-918 components or their obsolete validation paths.

## Decided

The accepted design has no open design questions. These decisions are binding for the 3.1 Settings implementation:

- Use one host-owned Omarchy `KeyboardPanel`, about 680 px wide, with two panes.
- Open on the section for the current presentation mode and remember the last section.
- Collapse classic-only groups when no monitor uses the classic dock.
- With one monitor, show Classic dock/Sidebar and write that monitor's own `presentationModeByMonitor` entry; use the monitor matrix only for two or more monitors.
- Keep workspace mode and every dependent workspace setting together.
- Settings is the on/off surface for the `herdr.agents` widget; do not change the Herdr provider lifecycle to implement it.
- Keep Features for setup/readiness only; toggles stay in the section where they take effect.
- Use the shared readiness projection; do not duplicate feature detection in Settings.
- Sliders commit on release.
- Use one colour control and one border-width control with **Theme default** or a custom value.
- Keep Chrome profile badges and muted services in **Apps · Chrome**; keep Chrome tabs in **Sidebar & Widgets**.
- Keep launcher-count presentation and Herdr terminal-icon state in **Behavior · Attention**.
- Include Apps, while context menus and dragging remain primary.
- Keep Change Icon as the only icon editor and share its editing slot with Settings.
- Put `controlCommand` under Advanced and never execute it from Settings.
- Provide one-click conversion for legacy `sidebarMonitor`.
- Search labels, keys, and help text across the schema.
- Show the first-run welcome only when no `dock.json` exists; do not add a dismiss preference.
- Provide the accepted IPC target and `dockrail settings` entry point in the implementation slice; SET-01 does not add them.
- Feature setup steps are copy-only and use the final `dockrail setup --feature chrome|herdr|launcher-counts|agent-launchers` flags with plugin-folder fallback.
- Rename the sidebar's legacy “SmartDock” accessibility label when the Settings shell is implemented.
- Hide demo widgets from production Settings.
- Use readable dependency hints; reserve amber for actual warnings.
- Keep the single host writer, preserve live reload, unknown keys and collection order, and never execute `controlCommand`.
