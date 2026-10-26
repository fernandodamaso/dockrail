# FDM-1025 SET-03 review corrections

Baseline reviewed: PR #142, `fbc1e093b4649f1a6b692acc62b62b72e30fd562`.
Frozen requirements: `docs/SETTINGS.md`, the 2026-10-21 canvas export and rev18 implementation plan (plan wins).

## Corrections

- Canonical schema rows own interaction snapshots, validation feedback, Reload / Keep editing and a three-second Changed elsewhere indication. Stable metadata inventories preserve drafts when CLI changes another Layout branch.
- Schema dependencies disable controls while preserving requested settings. Requested/effective differences are shown, including sidebar width clamping.
- Panel cursor supports rows, h/l, Enter/Space, Tab between panes, c to copy the selected row's fixed CLI command, Alt+Up/Down for monitor ordering and nested Escape. Search remains SET-08 and is labelled accordingly.
- Monitor choices use `monitorModeIntent`, including clearing an override for Default; disconnected/stale targets cannot be written. Icon rail uses the existing collapse intent.
- Automatic/manual order retains the session's disconnected names; manual order supports grip drag and keyboard reorder with accessible position names.
- The gear is available in the icon rail, Dock Controls uses the specified final separated action, and the Widget manager opens Sidebar & Widgets. Host anchors are registered/unregistered, validated and replaced when their surface disappears. Reanchoring preserves the editing pane.
- Layout uses three native display-mode cards (Displays, Sidebar, Classic dock with subsections) and Arrange apps tiles; panel height fits content within native available space.
- Retry accepts the writer's raw envelope, distinguishing accepted pending saves from rejected busy writes.

## Native primitive maintenance check

Inspected `omacom/omarchy` quattro at **3c7027db2a4fa9fa6a49d7af7f87c27ac48e677d**:
`shell/Ui/KeyboardPanel.qml`, `PanelKeyCatcher.qml`, `Dropdown.qml`, `NumberField.qml`, `PanelSlider.qml`, `ButtonGroup.qml`, `Button.qml`, `Toggle.qml`, plus `shell/plugins/panels/monitor/Panel.qml` as the first-party cursor/sizing composition.

The panel retains native window, outside-click dismissal, focus priming and theme ownership. It adds no focus timer, second writer or command runner. Native Dropdown selection assigns its value internally; the row restores its binding after selection and captures its snapshot when the popup opens.

Installed Omarchy/Hyprland/Quickshell versions and a physical session are unavailable here. Source inspection and fixture rendering are not native qualification.

## Verification

- All repository JavaScript model tests passed, including dependency/outcome/order/anchor regressions and existing icon late-picker tests.
- All structural guards and shell syntax checks passed.
- CLI Python suite: 63 passed.
- Pure QML suite: **491 passed, 0 failed**. New cases exercise production writer/controller methods in the QML engine, draft preservation through the full Layout, dependencies, live feedback, dropdown snapshots/bindings, keyboard pane/row navigation, monitor Default/stale topology, Alt reorder, retry, accepted busy and icon handoff.
- Compositor and FileView endpoints are substituted in the new QML source harness, as documented in its source; these tests do not assert native disk/Wayland behavior.
- An offscreen render of the panel was inspected for card/column/scroll geometry, using the headless native-interface fixtures. It is not a native visual acceptance screenshot.
- `saveSettingsIntent` remains byte-for-byte identical to INF-1 PR #139 head `bc859cc37acd2830d5cc3163f155926ee7882302`. No competing adapter was introduced. Integrate/retest the dependency stack before merge.

### Local full Python suite limitation

With extracted Qt tools on PATH: 251 tests, 12 failures, 17 errors, 2 skipped. Before any product edits, the same environment already had 12 failures and 14 errors (12 skipped without Qt). Failures concern process identity/guest guards and widget QML-validation tool discovery; none are hidden by narrowing the test command. The exact-head GitHub CI remains required, with its normal installed Qt dependencies.

Final local failing/error test names:

- `ERROR: test_forged_a_pid_does_not_signal_b (test_dev_session.CrossTargetingTests.test_forged_a_pid_does_not_signal_b)`
- `ERROR: test_stop_during_sync_does_not_resurrect_record (test_dev_session.SourceSyncTests.test_stop_during_sync_does_not_resurrect_record)`
- `ERROR: test_start_exception_releases_port_after_early_stop (test_dev_session.StartRaceTests.test_start_exception_releases_port_after_early_stop)`
- `ERROR: test_signal_during_spawn_waits_until_child_ownership_is_recorded (test_dev_session_review.SignalCleanupTests.test_signal_during_spawn_waits_until_child_ownership_is_recorded)`
- `ERROR: test_dev_use_reload_and_reset_preserve_source_and_installed_package (test_widget_packages.WidgetPackagesTest.test_dev_use_reload_and_reset_preserve_source_and_installed_package)`
- `ERROR: test_enabled_remove_is_refused_without_rewriting_config (test_widget_packages.WidgetPackagesTest.test_enabled_remove_is_refused_without_rewriting_config)`
- `ERROR: test_install_list_registry_and_remove (test_widget_packages.WidgetPackagesTest.test_install_list_registry_and_remove)`
- `ERROR: test_install_rejects_duplicate_and_protected (test_widget_packages.WidgetPackagesTest.test_install_rejects_duplicate_and_protected)`
- `ERROR: test_installed_scaffold_materializes_widgetkit_and_loads_without_global_smartdock_import_path (test_widget_packages.WidgetPackagesTest.test_installed_scaffold_materializes_widgetkit_and_loads_without_global_smartdock_import_path)`
- `ERROR: test_invalid_dev_reload_keeps_last_working_snapshot (test_widget_packages.WidgetPackagesTest.test_invalid_dev_reload_keeps_last_working_snapshot)`
- `ERROR: test_invalid_dev_reload_qml_syntax_keeps_last_working_snapshot (test_widget_packages.WidgetPackagesTest.test_invalid_dev_reload_qml_syntax_keeps_last_working_snapshot)`
- `ERROR: test_invalid_dev_reload_unresolved_import_keeps_last_working_snapshot (test_widget_packages.WidgetPackagesTest.test_invalid_dev_reload_unresolved_import_keeps_last_working_snapshot)`
- `ERROR: test_invalid_package_isolated_from_valid_registry_package (test_widget_packages.WidgetPackagesTest.test_invalid_package_isolated_from_valid_registry_package)`
- `ERROR: test_package_manager_never_writes_qml_paths_to_dock_config (test_widget_packages.WidgetPackagesTest.test_package_manager_never_writes_qml_paths_to_dock_config)`
- `ERROR: test_symlinked_installed_package_is_isolated_from_registry_and_bulk_update (test_widget_packages.WidgetPackagesTest.test_symlinked_installed_package_is_isolated_from_registry_and_bulk_update)`
- `ERROR: test_update_all_continues_after_one_broken_source (test_widget_packages.WidgetPackagesTest.test_update_all_continues_after_one_broken_source)`
- `ERROR: test_update_is_atomic_and_preserves_previous_on_invalid_candidate (test_widget_packages.WidgetPackagesTest.test_update_is_atomic_and_preserves_previous_on_invalid_candidate)`
- `FAIL: test_env_capture_and_stop_dock_refuse_on_host (test_dev_session.GuestControlHostGuardTests.test_env_capture_and_stop_dock_refuse_on_host)`
- `FAIL: test_start_compositor_refuses_on_host (test_dev_session.GuestControlHostGuardTests.test_start_compositor_refuses_on_host)`
- `FAIL: test_start_dock_refuses_on_host (test_dev_session.GuestControlHostGuardTests.test_start_dock_refuses_on_host)`
- `FAIL: test_changed_start_ticks_refuse_signal (test_dev_session.LifecycleTests.test_changed_start_ticks_refuse_signal)`
- `FAIL: test_stop_during_start_does_not_resurrect_failed (test_dev_session.StartRaceTests.test_stop_during_start_does_not_resurrect_failed)`
- `FAIL: test_stop_rereads_identity_under_lock (test_dev_session.StartRaceTests.test_stop_rereads_identity_under_lock)`
- `FAIL: test_repeated_signals_do_not_interrupt_cleanup (test_dev_session_review.SignalCleanupTests.test_repeated_signals_do_not_interrupt_cleanup)`
- `FAIL: test_sighup_cleans_up_during_guest_boot (test_dev_session_review.SignalCleanupTests.test_sighup_cleans_up_during_guest_boot)`
- `FAIL: test_sighup_cleans_up_ready_session (test_dev_session_review.SignalCleanupTests.test_sighup_cleans_up_ready_session)`
- `FAIL: test_sigint_still_cleans_up_ready_session (test_dev_session_review.SignalCleanupTests.test_sigint_still_cleans_up_ready_session)`
- `FAIL: test_sigterm_cleans_up_during_guest_boot (test_dev_session_review.SignalCleanupTests.test_sigterm_cleans_up_during_guest_boot)`
- `FAIL: test_sigterm_cleans_up_ready_session (test_dev_session_review.SignalCleanupTests.test_sigterm_cleans_up_ready_session)`

## Continuation (2026-10-26, exec branch)

Rebased onto merged `main@c0ed274` (SET-00/SET-02/INF-1/INF-2/INF-3 merged). Continuation head adds three contract fixes on top of PR #142 `8126255`:

- Focused-monitor summon: `DockHost.focusedSettingsConnector()` resolves the Hyprland focused monitor (names match Quickshell connectors) with remembered-connector fallback. `openSettings()` prefers explicit anchor, then requested/focused/remembered connector, then first usable anchor. IPC `dockrail-settings open/toggle` and `toggleSettings()` use `openSettingsForFocused()`. Menu/gear/widget-manager routes still pass their explicit anchor/connector.
- Saving-state locking: rows and Layout custom controls disable while `settingsWriteState==="saving"`, reload pending, or settings not loaded. Commits during saving return `Saving… wait for readback` instead of stacking a second write; `E_BUSY` remains the host truth.
- Per-row reset: `host.defaultSetting()`/`resetSettingIntent()` write the default through the same writer with the expected starting value. Rows show Reset + `Default: X` when the current value differs; reset participates in stale/busy handling like any commit.
- Delayed-commit cancellation: `DockSettingsRow.cancelPending()` stops the keyboard-settle timer and discards the editing draft. `DockSettingsLayout.cancelPending()` cancels all rows and clears stale monitor edit tokens. `DockSettingsPanel.close()` cancels before closing, so Change Icon handoff and panel close cannot leave a delayed write running. Reanchoring while open preserves drafts and focus pane.

### Native primitive maintenance check (continuation)

Installed host (read-only inspection, no edits): `omarchy 4.0.6-1`, `hyprland 0.56.2-4`, `quickshell 0.3.2.r7.g2b4501a-1`, `/usr/share/omarchy/version` = `4.0.0.alpha`. Re-inspected `shell/Ui/KeyboardPanel.qml` (focus prime, dismissal twins, `fittedContentHeight`), `PanelKeyCatcher.qml` (blocked forwarding, j/k/h/l/Tab/Esc), `NumberField.qml` (SpinBox `onValueModified`), `PanelSlider.qml` (drag `moved`/`released`, wheel commits), and `shell/plugins/panels/monitor/Panel.qml` (cursor sections, IPC open/close/toggle). No new focus timer, second writer, or command runner added. Installed-revision physical session still required (see gates below).

### Verification (continuation)
- QML: full `tst_settings_writer` passes including 4 new cases (focused connector, saving lock, per-row reset, close cancels pending keyboard commit). `tst_settings_review` still passes.
- JS: `test_settings_registry.mjs` passes; `test_settings_review.mjs` extended with focused summon, anchor lifecycle, and per-key reset (all pass). All other `test_*.mjs` model tests pass.
- CLI: `test_cli_settings.py` (2 tests) passes; `settings` still issues the fixed no-arg IPC `open` and treats `no-anchor` as `E_RUNTIME_NOT_FOUND`.
- Headless QML suite on this tree: 504 passed, 9 failed — the same 9 failures reproduce on clean `origin/main` (478 passed, 9 failed) in `DockWidgetCard`, `HerdrRemoteFallback`, `WidgetKit`; no new failure introduced.
- `bash -n`, `py_compile`, `git diff --check`, `qmllint` (warnings only), `omarchy plugin validate .`, and `timeout 6s ./scripts/run` all pass.
- KVM guest check not run: no verified base image at `~/.local/state/smartdock/dev-sessions/_kvm-feasibility/images/` in this environment. Native Omarchy smoke (four entries, focus/keyboard, CLI round trips, themes/monitors, error states) remains the required gate before merge.

### Owner-directed change (2026-10-26, live desktop review)

- Sidebar header gear removed: with the gear rendered it duplicated the sliders "Sidebar menu" button, so the header had two settings-looking buttons. The sidebar entry is the Sidebar menu (which already contains "Dockrail Settings…" plus "Switch to dock"); the sliders icon is restored there.
- Summon anchors follow the decision: the header menu button registers the sidebar anchor while expanded, the collapse/Expand button covers the icon rail, so keyboard/IPC/CLI summon keeps working on sidebar-only setups without a dedicated gear.
- This supersedes canvas board 3's "third header button" for the sidebar. The Dock Controls menu entry and its new gear glyph are unchanged.

## Remaining acceptance gates

Keep PR #142 Draft. Do not merge/deploy or mark FDM-1025 Done until dependencies are integrated and the native smoke is recorded at the final SHA:

1. Open via Dock Controls, expanded/rail gear, Widget manager footer and CLI/IPC; check one instance and correct monitor/anchor after mode switches and hotplug.
2. Check focus, tab/cursor/inline editors, dropdown Escape, clipboard and drag/Alt reorder in the real shell, including screen-reader announcements.
3. Change Layout and verify `dockrail config get`; change via CLI/file/drag/menu and verify live rows, drafts and effective values.
4. Exercise Change Icon in both directions and late file-picker completion.
5. Exercise invalid config, validation, stale, rejected busy, accepted saving, persistence failure and Retry.
6. Check theme changes, narrow/short displays and multiple monitors. Record screenshots and installed revisions.

SET-LOCAL remains the final qualification of all sections; it does not replace this SET-03 smoke.
