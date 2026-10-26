#!/usr/bin/env bash
set -euo pipefail

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$root_dir"

fail() {
  echo "check_window_cycling: $*" >&2
  exit 1
}

require_pattern() {
  local pattern="$1"
  local file="$2"
  grep -Eq "$pattern" "$file" \
    || fail "missing expected FDM-808 wiring in $file: $pattern"
}

reject_pattern() {
  local pattern="$1"
  local file="$2"
  if grep -Eq "$pattern" "$file"; then
    fail "unexpected FDM-808 ownership in $file: $pattern"
  fi
}

# Compatibility-safe setting: scrolling remains disabled unless explicitly enabled.
require_pattern '"scrollAction"[[:space:]]*:[[:space:]]*"none"' config/dock.json
require_pattern 'property var settings: dockControl\.defaults' DockHost.qml
require_pattern 'scrollAction:[[:space:]]*normalizeSetting\(' components/DockModel.js
require_pattern 'scrollAction:[[:space:]]*settings\.scrollAction' components/Dock.qml
# Validate the schema JSON semantically: UI metadata makes formatting multiline.
python3 -c 'import json; s=json.load(open("config/settings-schema.json", encoding="utf-8")); assert s["settings"]["scrollAction"]["enum"] == ["none", "cycle-windows"]' \
  || fail 'scrollAction must still expose exactly none and cycle-windows'
require_pattern 'scrollAction' README.md
require_pattern 'cycle-windows' README.md

# Runtime delivery is local to the item; lifecycle state remains host-owned.
require_pattern 'import "DockWindowModel\.js" as DockWindowModel' components/DockItem.qml
require_pattern 'property real wheelRemainder:[[:space:]]*0' components/DockItem.qml
require_pattern 'property double lastWheelTimestamp:[[:space:]]*0' components/DockItem.qml
require_pattern 'WheelHandler[[:space:]]*\{' components/DockItem.qml
require_pattern 'runningCount[[:space:]]*>=[[:space:]]*2' components/DockItem.qml
require_pattern 'applicationActions\.scrollAction[[:space:]]*===[[:space:]]*"cycle-windows"' components/DockItem.qml
require_pattern 'event\.accepted[[:space:]]*=[[:space:]]*false' components/DockItem.qml
require_pattern 'dominantVerticalWheelDelta' components/DockItem.qml
require_pattern 'wheelRemainderForTimestamp' components/DockItem.qml
require_pattern 'accumulateWheelSteps' components/DockItem.qml
require_pattern 'wheelStepDirection' components/DockItem.qml
require_pattern 'event\.accepted[[:space:]]*=[[:space:]]*cycled' components/DockItem.qml

require_pattern 'function cycleToplevels\(' components/DockWindowActions.qml
require_pattern 'readonly property var activeToplevel:[[:space:]]*ToplevelManager\.activeToplevel' components/DockWindowActions.qml
require_pattern 'cycleGroupMember' components/DockWindowActions.qml
require_pattern 'restoreToplevel' components/DockWindowActions.qml
require_pattern 'focusWindowRequest' components/DockWindowActions.qml

for helper in cycleTargetIndex cycleGroupMember dominantVerticalWheelDelta \
  accumulateWheelSteps wheelStepDirection wheelRemainderForTimestamp; do
  require_pattern "function ${helper}\\(" components/DockWindowModel.js
done

# FDM-819 ownership stays singular; transient wheel state is the only per-item state.
host_instances="$(grep -Ec '^[[:space:]]*DockWindowActions[[:space:]]*\{' DockHost.qml || true)"
[[ "$host_instances" -eq 1 ]] \
  || fail "DockHost.qml must own exactly one DockWindowActions instance"
reject_pattern 'property var minimizedOrigins' components/DockItem.qml
reject_pattern 'property var minimizedOrigins' components/Dock.qml

# FDM-808 must not resurrect the parked Shift-click action schema.
reject_pattern 'shiftClickAction' config/dock.json config/settings-schema.json

echo "check_window_cycling: PASS"
