# T3 thread activation: evidence (provisional)

Status: **PROVISIONAL — native routing gate BLOCKED.** All headless/static
checks below pass for the recorded pair, but clicking a row has NOT been
observed to navigate the real T3 desktop. Do not treat mocked dispatch results
as navigation evidence.

## Revision pair

```text
base: 774fc8e548177af27a9bd0585d377c7301617a69 (origin/feat/t3-project-branding)
head: <filled on commit; see git log feat/t3-thread-activation>
```

Stack parent is `feat/t3-project-branding` (local main checkout is stale for
this stack). No merge or deployment performed; no live dock switch.

## Inspected T3 build (host)

- Package: `t3code-nightly-bin 0.1.3_nightly.20261024.3617-1`
- `/usr/lib/t3code-nightly/resources/app.asar` SHA-256:
  `bbe876b38b4426ebf132c4b031ffe3f9ab5c7c6d363eae7aea950f690f4781e7`
  (matches the design spec assertion input).
- Default `t3code` scheme handler: `com.t3tools.T3Code.desktop` (Nightly).
- Conflicting handler present but NOT default:
  `~/.local/share/applications/t3code-url-handler.desktop` points at
  `/usr/lib/t3code/t3code` (Alpha). A guest with this handler active is an
  unsupported routing configuration, not a pass.

## Headless dispatch evidence (mocked opener — NOT navigation)

- `tests/test_t3_focus_activation.mjs` (new): URL validation/round-trip plus
  real controller-method behavior with injected dispatcher/provider/window
  stubs — PASS (covers composite opaque IDs, dot-segments, overlong,
  control/surrogate rejection, first-success raise + second validation with
  zero early dispatches, exactly-one dispatch on second success, Herdr
  zero-URL regression, provider failures, dispatch rejection → `unsupported`,
  unavailable dispatcher, failed raise, source disabled, generation/epoch/
  thread-removal/window-closure/address changes, repeated clicks, A/B
  out-of-order with no substitute-thread dispatch).
- `tests/tst_herdr_host_bridge.qml` (+2 T3 cases, injected dispatcher):
  one shared action owner, two validation calls, exactly one dispatch of
  `t3code://threads/env-1/thread-1`, zero dispatch after invalidation — PASS.
- Related suites PASS: `test_herdr_focus_activation.mjs`,
  `test_agent_source_labels.mjs`, `test_context_menu_herdr_records.mjs`,
  `test_t3_sidebar_model.mjs`, `tst_t3_window_preview.qml`,
  `tst_t3_dock_indicators.qml`, `tst_agent_source_mux.qml`,
  `tst_agent_source_herdr_regression.qml`, `provider/t3/tests` (146 tests).
- Static: `bash -n` (install/uninstall/scripts/checks) OK, `py_compile` OK,
  `omarchy plugin validate .` exit 0, `qmllint` (Omarchy-aware set) warnings
  only, `git diff --check` clean.
- Full `qmltestrunner -input tests`: 533 passed, 9 failed — all 9 reproduce
  on the clean base `774fc8e` (`tst_dockwidgetcard` ×4,
  `tst_herdr_remote_fallback` ×4, `tst_widgetkit` ×1) and are unrelated to
  this change.
- `./scripts/run` smoke NOT executed: a production dock
  (`quickshell -p /usr/share/omarchy/shell`) is running on this desktop and
  project instructions forbid starting a second dock beside it.

## Native gate: BLOCKED

Task 1 native qualification was not performed. Exact blocker:

- The verified KVM Arch base image is absent at the documented path
  (`~/.local/state/smartdock/dev-sessions/_kvm-feasibility/images/
  Arch-Linux-x86_64-cloudimg.qcow2`); `~/.local/state/smartdock/dev-sessions/`
  is empty and no `*.qcow2` exists anywhere on this filesystem
  (`find / -xdev -name '*.qcow2'` returns nothing). Host packages
  (`qemu-desktop 11.1.2-1`, `edk2-ovmf 202608-1`, `cloud-utils 0.33-3`) are
  present and the Arch mirror is reachable, but the image was not
  re-downloaded and no guest (`t3-open-probe-20261026-a`) was provisioned in
  this turn.
- Consequently: no guest T3 install, no fixture threads, no
  `Qt.openUrlExternally` probe, no selected environment/thread readback, no
  destination/process-identity evidence, and no Task 3 Step 4 guest click-flow
  (`t3-open-accept-20261026-a`).

Required before claiming support: provision the verified image, run the
Task 1 probe (thread B→A→B with duplicate titles, rapid A/B, closed/replaced
target, conflicting handler as unsupported), then the Task 3 Step 4 guest
click-flow from sidebar, classic preview and context menu against the exact
head recorded above. Any later commit, rebase or parent update invalidates
that acceptance.
