# CLI-first local qualification — FDM-920 with FDM-885

**Gate: not run by remote FDM-919. Candidate remains Draft, unmerged and undeployed.** This is one AI-owned local coding/qualification run for the exact SHA in the latest FDM-919 handoff, not a second icon implementation or a request for ceremonial human code approval. FDM-920 owns the run; FDM-885 records surviving icon outcomes from that same run. Keep the parent open until actual local evidence exists.

## 1. Acquire the exact candidate without disturbing other work

Read the live FDM-919 handoff, FDM-920/FDM-885, AGENTS.md and docs/DELIVERY.md. Set `CANDIDATE_SHA` and `BASE_SHA` to the **full hashes from that handoff**, not a branch's latest commit or this document's historical provenance. Confirm remote branch writes have paused and take single-writer ownership before publishing fixes. FDM-889's separate drag branch/PR must not be imported or modified.

Use Bash with failure checking for setup; stop at a failed identity/precondition check. Preserve the run directory and variables when changing test terminals. Run the block from this repository's root so `source_repo=.` is that checkout.

```bash
set -euo pipefail
: "${CANDIDATE_SHA:?Set the full head SHA from the FDM-919 handoff}"
: "${BASE_SHA:?Set the full base SHA from the FDM-919 handoff}"
source_repo=.
git -C "$source_repo" status --short
git -C "$source_repo" worktree list
git -C "$source_repo" fetch origin main feat/fdm-914-cli-first
test "$(git -C "$source_repo" rev-parse origin/feat/fdm-914-cli-first)" = "$CANDIDATE_SHA"
git -C "$source_repo" cat-file -e "$BASE_SHA^{commit}"
umask 077
run_dir="$(mktemp -d "$HOME/dockrail-cli-qualification.XXXXXX")"
git -C "$source_repo" worktree add --detach "$run_dir/source" "$CANDIDATE_SHA"
test "$(git -C "$run_dir/source" rev-parse HEAD)" = "$CANDIDATE_SHA"
mkdir -p "$run_dir/evidence" "$run_dir/state" "$run_dir/artwork"
printf 'base=%s\nhead=%s\n' "$BASE_SHA" "$CANDIDATE_SHA" > "$run_dir/evidence/source.txt"
```

Preserve all dirty/unpushed work. Do not reset, clean, stash blindly, repoint another worktree or edit an installed checkout. A moved branch means refresh the handoff/coordinate ownership, not silently test newer source. The detached worktree is an isolated source copy; it does **not** by itself isolate a display, host or user configuration.

## 2. Establish runtime and configuration isolation

Record Quickshell/Qt/Omarchy/Hyprland versions and the installed command help. `qs --help`, `qs list --help`, `qs ipc --help`, `qs list --all --json` and `hyprctl version` are read-only discovery. Derive Omarchy version/plugin development controls from its installed documentation/package/source; do not invent `omarchy-shell` selectors or assume flags from another version. Capture real instance IDs, native config paths and display/monitor topology.

Use a dedicated test display/session with no production Dockrail instance before launching this candidate. Never start a second dock on Fernando's production display. A temporary client XDG directory alone does not isolate a running plugin; the host's own config path remains authoritative. For the plugin case, use a supported, inspected local source-plugin harness in that isolated Omarchy session and verify that it loads this exact source. Do not copy files into or retarget the deployed plugin checkout. If a safe plugin harness/display is unavailable, record that specific check NOT RUN rather than touch production.

For standalone in the isolated session only, use a private config and the source launcher. The baseline can be shipped defaults or an explicitly inspected copy of a configuration; keep the original bytes/artwork untouched. Do not evaluate copied controlCommand values merely to validate them.

```bash
cp "$run_dir/source/config/dock.json" "$run_dir/state/dock.json"
# Execute only in the isolated test display/session, not alongside the plugin.
XDG_CACHE_HOME="$run_dir/state/cache" SMARTDOCK_CONFIG="$run_dir/state/dock.json" "$run_dir/source/scripts/run"
```

Keep that host in its own terminal/process and perform CLI checks from another terminal in the same isolated session. Test plugin and standalone sequentially, not as competing production writers. For plugin mode, its own isolated XDG_CONFIG_HOME supplies `dockrail/dock.json`. `DOCKRAIL_CONFIG` is the canonical explicit override; `SMARTDOCK_CONFIG` remains a compatibility override for mixed-version checks. Use temporary copies of valid/corrupt/missing PNG/SVG artwork for failures. Never corrupt a system theme or the user's current ChatGPT artwork.

The source CLI can run without installing over the existing client. Discover first, then set `SD_RUNTIME` and `SD_INSTANCE` from actual selected-host responses; keep them on every subsequent command:

```bash
bash "$run_dir/source/scripts/dockrail" status --json
: "${SD_RUNTIME:?Set plugin or standalone from the selected host}"
: "${SD_INSTANCE:?Set its exact runtime.instanceId or quickshellId}"
sd() { bash "$run_dir/source/scripts/dockrail" --runtime "$SD_RUNTIME" --instance "$SD_INSTANCE" "$@"; }
sd status --json > "$run_dir/evidence/status-before.json"
sd doctor --json > "$run_dir/evidence/doctor.json"
sd config schema --json > "$run_dir/evidence/schema.json"
sd config get --json > "$run_dir/evidence/requested-before.json"
sd config get --effective --json > "$run_dir/evidence/effective-before.json"
```

Before any mutation, verify status reports the expected isolated **host** config path and candidate host mode, and native discovery/harness evidence identifies this source. Stop on mismatch, pending load, ambiguous target, invalid config or unexpected protocol. Never treat bundled schema as live settings. The temporary CLI-only install/coexistence checks can run with temporary HOME/XDG roots; they do not justify installing a second runtime.

## 3. Run the bounded acceptance matrix and record actual observations

Use the guide's minimal patch/primitive commands. Record command, exit code, JSON, before/after values, actual file bytes, relevant logs and visual evidence. Put PASS, FAIL or NOT RUN beside each row; state unavailable hardware/service cases explicitly. Avoid permanent polling and retry loops. Capture deliberate error probes with an explicit conditional so a required nonzero exit is recorded, not mistaken for success or allowed to skip cleanup.

| Area | Action and required observation |
| --- | --- |
| Discovery/compatibility | Actual plugin and standalone discovery, exact PID/native-ID selection, absent runtime, deliberate isolated ambiguity where safe, invalid selector and clean JSON/stderr. No newest-host fallback or automatic launch. Verify installed qs syntax and one host-owned IPC endpoint. |
| Read-only/offline | Help and installed agent-guide work with no runtime/source checkout; automatic schema fallback is labeled bundled. Reads create no config/autostart. Explicit miss/ambiguity/protocol errors do not fall back. |
| Typed patches/dry run | Export to a new private file; apply theme, calmer-motion and authorized horizontal-card recipes. Dry run changes no live values/revision/file; apply changes only intended keys. One invalid member rejects the whole patch. Requested fractions, tokens and grouped-on-vertical intent survive normalization. |
| FileView save/error/retry | Real first save creates only the intended config path. A controlled isolated unwritable-parent failure leaves session-only applied state and visible error. Correct the actual cause and retry the latest snapshot; no stale patch or misleading no-op success. Exercise failed-write echo protection and ordinary external rollback after a successful save. Never manufacture failure on the real user file. |
| Concurrent/reload state | Cooperating disjoint changes survive; same-key order is explicit. Known pending reload/write refuses mutation. Invalid isolated file retains last-good state and blocks mutation; explicit repair restores reads. Timeout outcomes require readback before repeating. |
| Reset/export/rollback | Single-key and deliberate preference reset obey exclusions, including icons/pins/hidden/margin/unknown keys. Note controlCommand resets. Export refuses existing paths, symlink/live-path aliases and missing parent; unsaved-source export is not a live save. Restore touched values only after fresh reads. |
| Applications | Native IDs and unavailable stored IDs; pin/unpin/hide/show, explicit show-all only in isolated state, before/after reorder including hidden pins. Verify identity, other order/map/settings, launches and existing window targets are preserved. |
| Retained behavior | Ordinary menus, app picker, real window previews, live theme changes, auto-hide/reveal, scope/workspace actions, Trash visibility/polling, grouping and badge ownership. Settings/editor routes are absent; do not try to reopen them. No compositor-wide config changes or destructive Trash/close action without explicit test intent. |
| Layout/monitors | Top/bottom cards, vertical flat fallback, fullLength, hover bounds and scopes. Run the existing `bash tests/runtime/check-workspace-resize.sh` only in its supported isolated host context. Exercise actual physical-monitor redraw/hotplug where available; otherwise mark the unavailable physical cases NOT RUN, not simulated PASS. |
| Icons — one shared FDM-885 run | Complete the surviving icon matrix immediately below with this same candidate/session/evidence set. |

### Surviving FDM-885 icon checks

Use exact catalog/dock-resolved IDs, including one whose resolved desktop identity differs from raw window appId. Per-app CLI list/set/reset/reload is the scripting entry point; the context menu's **Change Icon…** dialog is the only UI editor, and no Settings editor is required.

| Case | Required evidence |
| --- | --- |
| PNG/SVG and surface parity | Valid transparent/non-square PNG and SVG, paths with spaces/Unicode, magnification and fixed caller sizes. Main icons, open preview metadata and open picker rows agree; screenshots and launch/group/window identity are unchanged. Custom artwork is not tinted. |
| Bounded fallback | Missing/unreadable/corrupt custom files retain mappings. In an isolated theme/harness only, original and generic failures settle through custom → original → application-x-executable → bundled tinted app-window without loops. Do not damage installed icons. |
| Same-path refresh | Replace only temporary artwork bytes A→B at the same URL; icons reload and same-source set request fresh bytes across open surfaces and monitors. Without any command, the file watcher also refreshes within about 250 ms after a same-path edit, replace, delete or recreate. No redundant settings write for reload/same-source/watcher refresh. CLI renderVerified remains false even when visual evidence is separately recorded. |
| Failed set/reset + retry | Controlled isolated save failure after set and after removal. Session-only state is honest; latest-map retry preserves unrelated overrides and does not resurrect a stale removed entry. |
| Persistence and interactions | Controlled source-host reload/restart, preference-reset preservation, grouped/ungrouped/closed pins, hide/show/order, badges/window actions, delegate removal during loading and actual monitors where available. Re-discover the new instance after restart. |
| Existing ChatGPT artwork | Read/record the current artwork/identity non-destructively, test a private copy or stable reference with explicit intent, and verify app-wide mapping compatibility. Do not alter the original file, system icon or desktop launcher. Record what was and was not adopted; no automatic deployment. |

**Superseded, not passed:** old Settings hidden-row controls, Change/Restore editor dialog, preview-only selection, Cancel/stale-draft handling, FileDialog layering, Escape order and Settings screen-loss behavior. CLI discovery/restoration and shared renderer coverage replace those routes. Historical #42/#43 CI does not qualify this aggregate SHA.

## 4. Fix only evidenced defects and reverify the resulting SHA

The local coding agent owns code review, narrow source fixes, tests and CI. Do not ask Fernando to manually accept generated code. Use the same delivery branch only after taking single-writer ownership; never overwrite newer remote work. Commit only demonstrated fixes, not artificial qualification commits. If another worktree owns the delivery branch, commit in the isolated worktree and coordinate a non-force fast-forward; do not reset that worktree. Any changed SHA requires fresh relevant runtime checks and full existing CI.

Re-run the repository's existing headless commands from the candidate source:

```bash
set -euo pipefail
cd "$run_dir/source"
for script in install.sh uninstall.sh scripts/dockrail scripts/smartdock scripts/run tests/check_*.sh; do bash -n "$script" || exit; done
for script in tests/check_*.sh; do bash "$script" || exit; done
for script in tests/test_*.mjs; do node "$script" || exit; done
python3 -m unittest discover -s tests -p 'test_*.py'
QT_QPA_PLATFORM=offscreen /usr/lib/qt6/bin/qmltestrunner -input tests -import components -import tests/qml-imports
git diff --check "$BASE_SHA...HEAD"
```

Also perform the host-aware `omarchy plugin validate .` and qmllint/source-smoke checks in AGENTS.md when supported by the installed harness, without treating missing Omarchy imports as a successful lint. Record versions and actual commands. Full plugin loading, real IPC/FileView timing, focus/auto-hide, image decode/cache/theme output and physical monitors require their own observations beyond these headless commands.

## 5. Restore touched state and report one evidence-backed outcome

Stop only the test hosts created by this run, using recorded identity and installed supported controls; never broad-kill Quickshell/Omarchy. Restore only touched supported configuration values after comparing current state with the recorded test intent. Preserve concurrent edits, pin order, unknown keys and all original artwork. Keep evidence/backups until the run is recorded; remove only confirmed temporary test worktrees/files, not the canonical/deployed source.

Update FDM-920 and FDM-885 with the same final SHA, PR, exact-head CI, runtime versions, matrix PASS/FAIL/NOT RUN, evidence paths/screenshots/logs, narrow fixes and remaining unavailable gates. Keep parent open for unverified requirements. Leave the candidate Draft, unmerged and undeployed unless a separate authorized delivery decision changes that boundary.

## Retained source provenance

Aggregate source begins from main `4f5d77b0fc7bf20a48365cd2c54dab00a150b373` and continues the accepted FDM-918 head `5c750cdfd843e403f8f1f2bd359f594df0f3b42c`. These are historical provenance, **not** the final head variable above.

Retained icon model/renderer/forwarding: PR #42 at `27f35995d8da72a42d9a381250b1fd61783b51ae`, foundation `05a5b5cf614a56e7739172e7e6d987da8b721d23`, renderer `b734a6d1e2bd15fc7ee680230d6ddfba61c2a430`. Retained save/error/retry and echo-protection source: PR #43 at `7473a23abcfaca7454a7f791f241dd3e7ca9e061`. CLI app/icon integration is the accepted FDM-917 source `5f9982cb139f101445bc97f4e54cfb952efe2357`. The Settings/editor-only portions of the icon stack were not imported and are superseded, not silently reimplemented. Existing icon PRs remain separate historical sources; do not merge their full branches into this candidate.
