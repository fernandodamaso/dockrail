#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

fail() {
  printf 'check_herdr_dock_indicators: %s\n' "$*" >&2
  exit 1
}

dock=components/Dock.qml
item=components/DockItem.qml
bridge=components/DockHerdrWindowAgents.qml

grep -Fq 'function herdrSummaryFor(item)' "$dock" \
  || fail 'Dock summary projection missing'
grep -Fq '!(root.dockHerdrIndicators || root.dockT3Indicators)' "$dock" \
  || fail 'Dock summary must be setting-gated'
grep -Fq 'summaryForToplevels((item.toplevels || []).filter(root.sourceIndicatorsEnabled))' "$dock" \
  || fail 'Dock summary must use only item toplevels'
grep -Fq 'herdrWindowCount: Number(dockHerdrSummary.herdrWindowCount || 0)' "$dock" \
  || fail 'associated-window count is not passed to DockItem'

grep -Fq 'size: Math.round(Math.min(26, Math.max(16, root.iconSize * 0.84)))' "$item" \
  || fail 'status mark must scale with the icon between 16 and 26px'
grep -Fq 'y: -Math.round(height * 0.3)' "$item" \
  || fail 'status mark must own the top-right corner'
grep -Fq 'root.runningCount > 1 && !herdrStatusMark.visible' "$item" \
  || fail 'status mark must replace the numeric corner badge'
if grep -Fq 'herdrAgentCount >= 2' "$item"; then
  fail 'agent count must not occupy the corner badge'
fi
grep -Fq 'root.herdrReplacesAttention ? "none" : root.attentionBadge' "$item" \
  || fail 'same-window blocked attention replacement missing'
grep -Fq 'status === "blocked") name += " · " + count + " needs input"' "$item" \
  || fail 'needs-input accessibility phrase missing'
grep -Fq 'status === "working") name += " · " + count + " working"' "$item" \
  || fail 'working accessibility phrase missing'
grep -Fq 'status === "done") name += " · " + count + " done"' "$item" \
  || fail 'done accessibility phrase missing'

blocked_motion="$(sed -n '/function requestHerdrBlockedMotion()/,/^  }/p' "$item")"
grep -Fq 'root.urgentWindowAnimationEnabled' <<<"$blocked_motion" \
  || fail 'blocked transition bounce animation gate missing'
grep -Fq 'root.attentionBadgesEnabled' <<<"$blocked_motion" \
  || fail 'blocked transition bounce badge gate missing'
grep -Fq 'attentionMotion.play()' <<<"$blocked_motion" \
  || fail 'blocked transition must use DockAttentionMotion'

grep -Fq 'property var agentIndicatorStates: ({})' "$bridge" \
  || fail 'session-only completion memory missing'
grep -Fq 'completionSeq: 0' "$bridge" \
  || fail 'completion sequence missing'
grep -Fq 'previous.lastLiveStatus !== "done"' "$bridge" \
  || fail 'fresh completion transition missing'
grep -Fq 'previous.lastLiveStatus !== "blocked"' "$bridge" \
  || fail 'fresh blocked transition missing'
grep -Fq 'onFocusedToplevelChanged: root.acknowledgeWindow(root.focusedToplevel)' "$bridge" \
  || fail 'focus acknowledgment hook missing'

if rg -n 'DockHerdrStatusMark|herdrSummary|dockHerdrIndicators' \
    components/DockWorkspaceGroup.qml components/DockWorkspaceStrip.qml >/dev/null; then
  fail 'workspace indicators must remain untouched'
fi

printf 'check_herdr_dock_indicators: PASS\n'
