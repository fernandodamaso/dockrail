# Open a selected T3 Code thread

**Status:** Proposed design accompanying a planning-only request. No implementation, deployment, desktop navigation or approval of the finished design is implied.

## Outcome

Clicking an actionable T3 thread in Dockrail opens that specific thread in the paired, already-running T3 Code desktop. The same behavior applies to sidebar hierarchy rows, classic hover-preview rows and context-menu thread entries. Ordinary keyboard activation uses the same action.

## Findings and evidence

- Inspected source: `/home/admin/.cache/dockrail/dev-worktrees/t3-project-branding` at `774fc8e548177af27a9bd0585d377c7301617a69`. Existing uncommitted classic-preview artwork work is unrelated and must remain separate.
- `/home/admin/.cache/dockrail/dev-worktrees/t3-project-branding/components/DockHerdrAgentActions.qml` already captures exact window/thread identities and coordinates provider validation, window raising and a second validation. All three actionable surfaces use this host-owned controller.
- `/home/admin/.cache/dockrail/dev-worktrees/t3-project-branding/provider/t3/bin/dockrail-t3-provider` currently validates a `focus-agent` target and acknowledges it; it does not navigate the T3 UI. Its `paneId` is the raw T3 thread ID. The canonical server ID is `t3:<environmentId>`.
- Installed T3 package: `t3code-nightly-bin 0.1.3_nightly.20261024.3617-1`. Inspected `/usr/lib/t3code-nightly/resources/app.asar`, SHA-256 `bbe876b38b4426ebf132c4b031ffe3f9ab5c7c6d363eae7aea950f690f4781e7`.
- That build accepts `t3code://threads/<environmentId>/<threadId>` without a prompt, forwards it to the existing renderer and navigates to the corresponding thread route. Its actual extracted desktop URL parser passed a Node assertion. This proves parser behavior, not successful desktop navigation.
- The installed command palette includes the thread ID in search terms. T3 also defines Ctrl+1 through Ctrl+9 thread jumps. Neither alternative has been exercised through Dockrail.
- The current default `t3code` scheme handler is `com.t3tools.T3Code.desktop`, which launches Nightly. `/home/admin/.local/share/applications/t3code-url-handler.desktop` separately points to Alpha. A generic handler must therefore be qualified against the intended running build; do not silently rewrite either desktop entry or the user's default association.

## Approaches and recommendation

1. **Direct URL, recommended for this plan.** Build an encoded URL from the current validated environment/thread identities and dispatch it through Qt's native URL opener. It avoids ordering, clipboard and keyboard-focus dependencies. Correct routing into the existing paired desktop is a required live gate.
2. **Search by thread ID, contingency.** Focus the exact T3 window, open the command palette, enter the ID, verify the exact result and activate it. This requires input injection and observable completion; blind delays followed by Enter are insufficient. Revisit this design if direct URLs fail qualification.
3. **Position shortcuts.** Match T3's jump ordering and invoke the corresponding numeric shortcut. The nine-slot limit, grouping and order changes make this unnecessary for opening by stable identity.

The user's request to plan follows the direct-link recommendation. This document proposes that approach for review; it does not claim separate approval of the design or of keyboard automation.

## Proposed behavior and ownership

- Keep `/home/admin/.cache/dockrail/dev-worktrees/t3-project-branding/components/DockHerdrAgentActions.qml` as the single action owner. Keep the existing two-phase provider validation and shared `DockWindowActions` window activation.
- On the second successful validation, dispatch one URL for a current T3 target. Retain Herdr's existing pane-focus behavior. Never launch a URL from a presentation delegate or from the read-only provider.
- Build the URL from the validated server ID and `paneId`, never from a title, list position or a split composite agent ID. Encode each path segment once, reject empty/malformed identities and dot-only path segments, and omit all query parameters, credentials and prompts.
- Use an injectable `openT3ThreadUrl(url): bool` function in the existing controller, defaulting to `Qt.openUrlExternally(url)`. A true return means the native dispatcher accepted the URL; it is not an acknowledgement from T3 that navigation completed.
- Revalidate the latest request, current association, provider epoch, generation, live toplevel/address and current thread before dispatch. Dispatch once after the existing raise-and-revalidate sequence. Failed validation or a superseded pending request must dispatch nothing.
- If dispatch rejects the URL, retain the already-raised T3 window and record the existing focus error. Do not open another thread, retry through another build, or silently inject keys.
- Preserve provider leases, source multiplexing, read-only authentication, configuration, artwork, status indicators, ordinary previews, popup dismissal and modifier rules. A normal T3 visit may update read/visited state; Dockrail must not send messages or invoke settle, snooze, approval or run commands.
- Unmatched fallback Widget rows remain read-only until an exact live desktop association exists. This feature does not add cold launching or a second association policy.

## Scope and gates

This is a small activation change, plus regression tests and corrected action text/documentation. It adds no setting, dependency, generic UI component, provider lifecycle, configuration writer or thread-order mirroring. Preserve current thread visibility/filtering; this change does not expose snoozed or settled threads that are currently hidden.

Before claiming support, qualify the native route with the inspected T3 build in a fresh isolated KVM desktop, including a different thread initially selected, duplicate titles, rapid selections, a closed/replaced target and a conflicting scheme handler. Assert the destination by environment/thread identity, not title alone. A mismatched handler is an unsupported environment and must not count as a pass. If reliable routing cannot be established, stop this approach and revise the design around exact-ID search or explicit build routing before changing the implementation contract.

The verified Arch guest image is currently absent at both documented legacy and canonical state locations. Restore that prerequisite through `/home/admin/.cache/dockrail/dev-worktrees/t3-project-branding/docs/DEV_SESSIONS.md` before native qualification. This planning request does not authorize switching the user's live dock or changing desktop associations.

## Acceptance

1. Sidebar, preview and menu activation each select the clicked thread in the existing paired T3 desktop, including threads beyond the ninth slot and two threads with the same title.
2. The route carries exactly the intended environment ID and raw thread ID, safely encoded, with no message/prompt or credential.
3. Stale, superseded, disconnected and replaced targets cannot cause navigation; a rejected dispatch does not substitute a different target.
4. Herdr still uses its existing focus/raise/refocus sequence and T3 still shares one host-owned action controller.
5. Tests pass for the exact candidate SHA, and native routing evidence is recorded separately from mocked dispatch results.
