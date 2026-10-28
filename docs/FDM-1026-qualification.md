# FDM-1026 qualification — 2026-10-27

This review continues the existing SET-04 implementation against the frozen
2026-10-21 design export and implementation plan rev18. PR #148 remains Draft
until its remaining acceptance gates are recorded. No merge or deployment.

## Environment and inspected native contracts

- Omarchy package `4.0.6-1` (installed tree has no Git metadata).
- Hyprland `0.56.2-4`, Quickshell `0.3.2.r7.g2b4501a-1`, Qt `6.12.0`, Herdr `0.9.1-2`.
- Actual desktop: DP-1 Sidebar and HDMI-A-1 Classic, both 1920×1080 at scale 1.
- Native `KeyboardPanel` owns border/padding, focus, dismissal and anchoring;
  its content must fill the inner holder, not repeat the outer card dimensions.
- `SearchableDropdown` owns its search and popup focus and assigns its own
  value before `changed`. Snapshot expected values at popup opening and restore
  the live value binding after selection. `TextField` retains native editing
  signals; text drafts must survive host updates.
- `PanelSlider` emits `moved` during pointer input and `released` at release;
  the Settings consumer writes only on release. Keyboard settling is 400 ms.
- Compared native implementations with first-party audio/monitor panels and
  the dev-gallery editor/popup keyboard-ownership example.

Inspected native file SHA-256 values:

| File under `/usr/share/omarchy/shell/Ui/` | SHA-256 |
| --- | --- |
| `KeyboardPanel.qml` | `c8b3b0fd52d8a79469675e925ff851e1dd0588eb1eeb90bd4df004a4c7d72a0a` |
| `PanelSlider.qml` | `e1a56b744e89ccb9abee22557e062e23f6ba11b18b081508577165178bb49841` |
| `SearchableDropdown.qml` | `98e71d4fc3679d9a260db2ca29b6935db18447faecf190a8122ee31ef4a1384b` |
| `TextField.qml` | `08c8141e74b7791060461939626f08453a28fe97eed4f4339dabde9d6a6edb3b` |

## Corrected defects

- Panel content overflowed the native card padding.
- Color menus did not capture their starting pair when opened; a later CLI
  write could be silently overwritten. External writes also replaced typed hex.
- Custom hex selection did not focus the field; blur did not commit; cancelled
  menus/drafts retained stale interaction state. Hovering another row could
  return keyboard ownership to the panel while an editor remained active.
- Border width had no value label and displayed theme-owned `null` as 0 px.
- Reset could label its own synchronous write as Changed elsewhere; grouped
  app keyboard actions could submit while their visible button was disabled.
- Whole-row opacity reduced dependency-help contrast. Labels/help now retain
  semantic foreground while native controls retain their disabled state.
- Pending keyboard timers could re-enable a width override after Theme default,
  submit during a pointer drag, or send a duplicate mutation after Reset.
  Pointer takeover and explicit commits/resets now cancel those timers.
- The sidebar had no direct Settings gear or rail gear. Both now open the
  existing shared panel; the existing sidebar menu is retained.
- Anchors registered before their surface Loader assigned the final monitor.
  Opening now derives the connector from the actual surface screen.
- Explicit `Commons.Color` avoids Qt 6.12's ambiguous unqualified Color type.

## Native checks performed

These checks ran in the real Omarchy plugin through `dockrail dev use`, using
temporary diagnostic observation/navigation that was removed before delivery.
The diagnostic probe did not implement a settings writer or provider lifecycle.

- Four color pairs: native @accent selection then Theme default; each advanced
  exactly one host revision, persisted and retained its saved token.
- Border width: native pointer drag wrote its value and flag once on release;
  Theme default retained the width and disabled the override.
- Icon slider: real moved events retained the starting host value; release
  advanced one revision. Two keyboard steps produced one write 421 ms after
  the final draft event.
- Hex conflict: CLI update preserved typed text; stale Enter did not write;
  explicit Keep editing allowed one atomic pair write.
- Native Behavior controls: destructive options labeled, previews toggle,
  attention dependencies preserve requested values, terminal indicators toggle,
  and a temporary inert group was removed through the existing ungroup intent.
- Actual light palette loaded from installed Catppuccin Latte using Omarchy's
  `shell applyTheme` IPC; original Aether colors/shell restored using that IPC.
  Theme files were not changed. Dark and light panel captures were inspected.
- Expanded sidebar gear opens on DP-1 after the monitor-anchor fix. Candidate
  CLI installed into an isolated directory and its `dockrail settings` opened
  the running plugin. Final clean-head route/restart evidence belongs in the PR.
- Test settings restored through typed host patches with fresh readback;
  unknown keys and collection order preserved. No user package was replaced.

## Automated checks and limitations

Focused SettingsReview: 33 passed, zero warnings. Production-writer QML tests:
17 passed. JavaScript suite: 71 files passed. Structural guards: 38 passed after
removing inherited XDG_STATE_HOME from isolated-test environments. Plugin
validation and diff whitespace checks passed. Shell syntax: 43 files passed.

The broad baseline on this Qt 6.12 desktop already failed in widget palette,
widget chrome, split-scroll feedback and Herdr fallback tests. SET-05 records
the affected Widget fixes; these failures must not be represented as a green
SET-04 full-suite result. Omarchy-aware qmllint emits existing dynamic-type and
unqualified-access warnings; the full output is retained.

Offscreen Quickshell has no PanelWindow backend. A fresh KVM run with inherited
NO_AT_BRIDGE=1 could not discover QEMU's accessibility tree. A second fresh run
with that variable unset reached the real guest dock but its startup harness
could not parse `qs list --all --json`; standalone CLI qualification is blocked,
not passed. Both guest processes/windows were stopped by their owned session.

Not tested here: physical cable reconnect, real unavailable/older Herdr binary
versions, or native disk-failure/invalid-config injection against the user's
live file. Writer failure, retry, stale, busy and invalid-config behavior is
covered by the production-method QML harness, not claimed as physical evidence.
Search is SET-08 and Features is SET-06; their placeholder surfaces are not
qualified by SET-04.

Local logs, captures, baseline exports and reproduction scripts are retained at
`/home/admin/Documents/Codex/2026-10-27/dockrail-set04-set05/`.
Exact base/head SHAs and GitHub CI links are recorded in the PR and Linear so
the document does not contain a self-referential commit hash.
