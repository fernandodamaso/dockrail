# T3 Thread Activation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking. This request authorizes planning only; execute after the proposed design and plan are accepted. Native inline execution is the recommended fit for this small shared-controller change.

**Goal:** Make an actionable Dockrail T3 row open its specific thread in the existing paired T3 Code desktop.

**Architecture:** Retain the single host-owned `DockHerdrAgentActions` controller and its provider-validation, raise and revalidation sequence. After the second successful validation of a T3 target, construct a native thread URL from its environment ID and raw `paneId`, then dispatch it once with Qt's URL opener. Keep the provider read-only and preserve Herdr behavior.

**Tech Stack:** Existing Quickshell/Qt QML, JavaScript helpers, Node model tests, QtTest and the local T3 desktop URL handler. No new dependencies.

**Spec:** `/home/admin/.cache/dockrail/dev-worktrees/t3-project-branding/docs/superpowers/specs/2026-10-26-t3-thread-activation-design.md`.

## Global Constraints

- Keep `DockHerdrAgentActions` as the single action owner, with the existing shared `DockWindowActions` instance.
- Build the URL from the validated server ID and `paneId`, never from a title, list position or a split composite agent ID.
- Use `t3code://threads/<environmentId>/<threadId>`; encode each path segment once and omit all query parameters, credentials and prompts.
- Preserve provider leases, source multiplexing, read-only authentication, configuration, artwork, status indicators, ordinary previews, popup dismissal and modifier rules.
- A normal T3 visit may update read/visited state; Dockrail must not send messages or invoke settle, snooze, approval or run commands.
- Add no setting, dependency, generic UI component, provider lifecycle, configuration writer or thread-order mirroring.
- Do not silently rewrite desktop entries/default associations or inject keyboard input as an automatic fallback.
- Keep existing uncommitted classic-preview artwork work separate. Do not edit installed plugin checkouts, start a second production dock, or switch the user's live dock for autonomous testing.

## Review Focus

1. An old cached row, provider reconnect or same-address replacement must not navigate a different live target; Task 2 tests invalidation at both validation phases.
2. An encoded, reserved-character or non-UUID thread ID must retain its exact identity; Task 2 tests URL round trips and malformed input.
3. Repeated clicks and out-of-order acknowledgements must not dispatch duplicate or superseded pending requests; Task 2 tests both.
4. A different URL handler/build can accept dispatch without selecting the intended thread; Task 1 and Task 3 require native destination and process-identity evidence.
5. Sidebar, preview and context-menu callers must retain shared behavior while Herdr remains unaffected; Task 2 and Task 3 cover all entry points, keyboard activation and Herdr regression.

## Workspace and file map

Inspection baseline is `/home/admin/.cache/dockrail/dev-worktrees/t3-project-branding` at `774fc8e548177af27a9bd0585d377c7301617a69`. Do not execute in its dirty checkout. The existing main Git checkout is `/home/admin/Projects/dockrail`; the legacy canonical path `/home/admin/Projects/smart-omarchy-dock` named in AGENTS is currently absent. Discover the real Git common directory rather than recreating that missing path.

At execution, use the worktree skill to prepare branch `feat/t3-thread-activation` in `/home/admin/.cache/dockrail/dev-worktrees/t3-thread-activation`. Refresh remote state first and select a base containing the integrated T3 UI/mux and settlement fix; the local main checkout is stale. If those changes remain unmerged, use their owning branch as the stack parent and record its exact SHA. Copy only this plan and its spec into the new checkout; do not copy unrelated dirty product changes. Rebase/retarget according to `/home/admin/.cache/dockrail/dev-worktrees/t3-project-branding/docs/DELIVERY.md` if the parent changes.

Planned paths below refer to that new execution checkout:

- Create `/home/admin/.cache/dockrail/dev-worktrees/t3-thread-activation/components/DockT3ActivationModel.js`: pure URL validation/construction only.
- Modify `/home/admin/.cache/dockrail/dev-worktrees/t3-thread-activation/components/DockHerdrAgentActions.qml`: dispatch once through the existing action lifecycle.
- Modify `/home/admin/.cache/dockrail/dev-worktrees/t3-thread-activation/components/DockHerdrModel.js`, `/home/admin/.cache/dockrail/dev-worktrees/t3-thread-activation/components/DockWindowPreview.qml` and `/home/admin/.cache/dockrail/dev-worktrees/t3-thread-activation/components/DockContextMenu.qml`: source-specific thread action text.
- Create `/home/admin/.cache/dockrail/dev-worktrees/t3-thread-activation/tests/test_t3_focus_activation.mjs`: URL and real controller-method behavior with injected dispatcher/provider/window stubs.
- Extend `/home/admin/.cache/dockrail/dev-worktrees/t3-thread-activation/tests/tst_herdr_host_bridge.qml`, `/home/admin/.cache/dockrail/dev-worktrees/t3-thread-activation/tests/tst_t3_window_preview.qml` and `/home/admin/.cache/dockrail/dev-worktrees/t3-thread-activation/tests/tst_t3_dock_indicators.qml`: host action and text regressions.
- Update `/home/admin/.cache/dockrail/dev-worktrees/t3-thread-activation/docs/T3_DATA_ACCESS.md`: replace the obsolete no-deep-link claim with qualified behavior and limitations.
- Record evidence in `/home/admin/.cache/dockrail/dev-worktrees/t3-thread-activation/docs/t3-thread-activation-evidence.md`: exact Dockrail SHA, T3 package/build digest, dispatch/native results and open gates.

No provider, mux, host-controller instantiation, settings or Widget framework changes are expected.

## Task 1: Qualify native thread routing

**Files:** Read the spec and `/home/admin/.cache/dockrail/dev-worktrees/t3-thread-activation/docs/DEV_SESSIONS.md`; create the evidence record listed above.

**Interfaces:**
- Consumes the paired environment ID and two existing disposable test-thread IDs from a guest-only T3 server.
- Produces an evidence-backed contract: `Qt.openUrlExternally(url)` routes an encoded thread URL to the existing paired T3 desktop, with dispatch acceptance distinguished from actual navigation.

- [ ] **Step 1:** Prepare the isolated source checkout as above and record exact base/head SHAs. Re-read its actual action implementation if the base has advanced.
- [ ] **Step 2:** Restore/locate the verified Arch base-image prerequisite and start one fresh named guest, `t3-open-probe-20261026-a`, using the documented supervisor. Install/copy the inspected T3 build and its required runtime assets into that guest; use a private guest profile, server, settings and disposable fixture threads. Match the installed T3 package/digest to the spec or explicitly record and inspect the replacement revision. Never use the user's conversation database as a test fixture.
- [ ] **Step 3:** In the guest, use a temporary Quickshell test surface containing only the native URL-opener invocation. This is not a second dock. Open thread B while A is selected, then reverse them. Read the selected environment/thread identity through the guest renderer or accessibility/test instrumentation and capture evidence; title-only matching is insufficient. Assert one pre-existing T3 window/process remains the destination, and no composer prompt/message is injected.
- [ ] **Step 4:** Exercise encoded IDs supported by the guest fixtures and the build/profile routing boundary. With two handler candidates, establish which default points to the paired instance; test a conflicting handler in the disposable guest and record it as an unsupported routing configuration, not a successful dispatch. Do not change the host's associations.
- [ ] **Step 5:** Stop the guest and record the native result. Proceed only if the correct-route contract passes. If the route fails or the verified image is unavailable, mark this gate blocked, keep any source work provisional, and revise the design before implementing an ID-search or explicit-launcher alternative. Parser assertions and opener return values do not satisfy this gate.

## Task 2: Navigate once through the shared action owner

**Files:** The new activation helper/test and the shared action controller from the file map; extend the existing host-bridge test.

**Interfaces:**
- `DockT3ActivationModel.threadUrl(serverId: string, threadId: string): string` returns the fully encoded URL or `""` for invalid input. Require the `t3:` server prefix, nonempty environment/thread IDs, the existing bounds of 128 characters for full server ID and thread ID, no control characters or unpaired surrogates, and neither segment equal to `.` or `..`. Preserve opaque identity text without trimming or decoding it first.
- `DockHerdrAgentActions.openT3ThreadUrl(url): bool` is an injectable function property, defaulting to `Qt.openUrlExternally(url)`.
- `DockHerdrAgentActions.serverForId(serverId): object|null` reads the current canonical server from the bridge snapshot; reuse it in support/source checks.
- Existing `captureAgentTarget`, `activateHerdrTarget`, `enqueueHerdrFocus`, `targetIsCurrent` and `onHerdrFocusFinished` signatures remain compatible. No provider command/result schema changes.

- [ ] **Step 1:** Add failing tests using the existing `loadModel`, `qmlMethods` and `interactionFixture` harness patterns. Assert that `threadUrl("t3:env-1", "thread-1")` equals `"t3code://threads/env-1/thread-1"`; a composite opaque ID containing `:`, `%`, `/`, `?`, `#` and Unicode survives decoding exactly once; empty, non-T3, overlong, control/surrogate and dot-segment inputs return `""`.
- [ ] **Step 2:** Add controller tests proving that first validation success raises the captured window and requests second validation, with zero URL dispatches yet; second success for a current T3 target dispatches exactly one URL from `serverId` plus `paneId`, even when `agentId` is a composite value or two titles are identical. Add a Herdr fixture asserting zero URL calls and its existing focus/raise/refocus behavior.
- [ ] **Step 3:** Add failure/race tests: first/second provider failure, dispatch returning false, unavailable dispatcher, failed raise, source disabled, generation/epoch change, thread removal, window closure/address replacement, a state change during raise, repeated clicks, and A/B replies arriving out of order. Assert no stale/superseded dispatch, at most one dispatch for a deduplicated request and no attempt to switch to a substitute thread. Dispatch rejection records the existing `unsupported` focus error.
- [ ] **Step 4:** Run `node --test tests/test_t3_focus_activation.mjs` from `/home/admin/.cache/dockrail/dev-worktrees/t3-thread-activation`; confirm the new cases fail for missing URL navigation rather than a harness/setup error.
- [ ] **Step 5:** Implement the small pure helper and injectable dispatcher. Import the helper in the existing action controller. In `onHerdrFocusFinished`, retain latest-request and target revalidation, retain the first-success raise/second-validation phase, and add T3 URL dispatch only to the second-success branch. Determine T3 from the current server's source, and construct the URL from its canonical server ID and the pending raw `paneId`. Herdr's second-success branch keeps returning without URL work. Recheck the target immediately before native dispatch; handle an empty URL, missing callback, exception or false return with the existing focus-error path.
- [ ] **Step 6:** Extend the real host-bridge QtTest fixture with a T3 server and an injected dispatcher. Assert one acquire/shared action owner, two validation calls and one URL dispatch for a successful activation, plus no dispatch after invalidation. Mock the native opener here; this test must not change desktop focus.
- [ ] **Step 7:** Run the new Node test, `node --test tests/test_herdr_focus_activation.mjs`, and `QML_XHR_ALLOW_FILE_READ=1 QT_QPA_PLATFORM=offscreen /usr/lib/qt6/bin/qmltestrunner -input tests/tst_herdr_host_bridge.qml -import components -import tests/qml-imports`. Expected: all affected tests pass. Inspect the diff and commit only this task's source/tests and the approved planning/evidence documents, after the repository's required checks.

## Task 3: Correct action text and verify the full click flow

**Files:** The model, preview/menu text, affected QtTests, data-access documentation and evidence record from the file map.

**Interfaces:** Existing callers keep using the shared controller. T3 focus hint becomes `"Click a row to open this thread in T3 Code."`; preview/menu accessibility action becomes `"Open this T3 thread"`. Herdr text is unchanged.

- [ ] **Step 1:** Update the affected text expectations first and run the preview/indicator QtTests to observe the expected failures. Change the T3-only strings in the model, preview and context menu. Update the data-access document to describe native thread links, correct-handler/build requirements, normal visited/read effects and dispatch-versus-navigation evidence. Preserve the existing privacy/read-only and unmatched-row contracts.
- [ ] **Step 2:** Run the focused Node/QtTests from Task 2 plus `node --test tests/test_t3_sidebar_model.mjs tests/test_context_menu_herdr_records.mjs`; run the QML cases `tests/tst_t3_window_preview.qml`, `tests/tst_t3_dock_indicators.qml`, `tests/tst_agent_source_mux.qml` and `tests/tst_agent_source_herdr_regression.qml` with the same offscreen/import environment. Run `python3 -m unittest discover -s provider/t3/tests` to preserve the validation-only provider behavior. Expected: affected tests pass and no provider protocol/lease regression.
- [ ] **Step 3:** Run the current full local validation gate required by the execution checkout's AGENTS instructions and `/home/admin/.cache/dockrail/dev-worktrees/t3-thread-activation/docs/DELIVERY.md`, including plugin validation, Omarchy-aware lint and `git diff --check`. Run any standalone smoke only inside the isolated guest/config context. Compare broader failures with the same base revision; never label a failing suite green.
- [ ] **Step 4:** Start a new guest, `t3-open-accept-20261026-a`, sync the final candidate and run one guest Dockrail host. Verify mouse and keyboard activation from sidebar rows, classic hover previews and context-menu entries while a different T3 thread is selected. Include duplicate titles, a thread beyond slot nine, rapid A/B activation and a target closed/reconnected while its preview/menu is cached. Check popup dismissal and retained Herdr behavior. Assert the actual selected environment/thread, reuse of the intended T3 instance and absence of prompt/message insertion. Capture evidence, then stop the guest. A stripped plugin guest does not establish full Omarchy desktop acceptance; use a separately authorized local switch if that additional gate is required.
- [ ] **Step 5:** Inspect the final diff for unrelated classic-artwork, settings, order, provider and desktop-association changes; remove any accidental scope. Commit the final task after required checks, then record/re-run acceptance against the exact resulting head/base pair. Any later commit, rebase or parent update invalidates the old acceptance. Keep incomplete delivery Draft; use a separate activation PR/stack layer under the delivery contract only when publication is authorized. Register any PR worked on with T3's PR-link tool. Do not merge or deploy as part of this planning request.

## Plan review and current limits

Self-review must map every acceptance item and all five review-focus cases to the steps above, check helper/callback names across tasks, and confirm every referenced existing file against the selected execution base before coding.

Planning evidence is limited to source inspection, current handler metadata and the extracted T3 parser assertion. No desktop URL was opened and no Dockrail source was implemented for activation. Mocked URL-opener results do not qualify the native handler; that requires the real Quickshell/T3 guest check above. The verified guest base image is currently missing, so native qualification remains an explicit prerequisite.
