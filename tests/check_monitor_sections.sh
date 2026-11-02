#!/usr/bin/env bash
set -euo pipefail

monitor_label="components/DockMonitorLabel.qml"
dock="components/Dock.qml"
workspace_model="components/DockWorkspaceModel.js"

[[ -f "$monitor_label" ]]

# The label is informational: native display glyph + semantic Omarchy tokens,
# with no pointer/keyboard activation surface or enclosing capsule.
rg -q '^import qs\.Ui$' "$monitor_label"
rg -q '^import qs\.Commons$' "$monitor_label"
rg -q 'OpticalGlyph' "$monitor_label"
rg -q '󰍺' "$monitor_label"
rg -q 'Color\.(muted|foreground)' "$monitor_label"
rg -q 'Style\.font\.' "$monitor_label"
rg -q 'Accessible\.name' "$monitor_label"
! rg -q 'TapHandler|MouseArea|activeFocusOnTab\s*:\s*true' "$monitor_label"
! rg -q 'DockToolTip' "$monitor_label"

# The section renders its numeric position inside the glyph.
rg -q 'property int monitorNumber' "$monitor_label"
rg -q 'String\(root\.monitorNumber\)' "$monitor_label"

# Keep one global workspace reconciler and wrap its retained delegate instead
# of introducing a model/repeater per monitor.
[[ $(rg -c 'id:\s*workspacePresentationModel' "$dock") -eq 1 ]]
[[ $(rg -c 'id:\s*workspaceCards' "$dock") -eq 1 ]]
! rg -q 'model:\s*root\.workspacePresentation\.monitorGroups' "$dock"
rg -q 'WorkspaceModel\.monitorGroupForWorkspace' "$dock"
rg -q 'DockMonitorLabel' "$dock"
rg -q 'monitorNumber:\s*workspaceCardWrapper\.monitorSectionIndex \+ 1' "$dock"
rg -q 'monitorFocused:\s*workspaceCardWrapper\.cardMonitorFocused' "$dock"
rg -q 'firstWorkspaceIdentity' "$workspace_model"
rg -q 'monitorGroupIndexForMonitor' "$workspace_model"
rg -q 'monitorGroupIndexForMonitor' "$dock"

# Drag/reveal continue to use the actual card, not prefix/wrapper pixels.
rg -q 'readonly property Item dropCard:\s*workspaceCard' "$dock"
rg -q 'card\.mapFromItem\(null, scenePoint\.x, scenePoint\.y\)' "$dock"
rg -q 'groupedLayout\.ensureVisible\(card\.dropCard, card\.headerWidth\)' "$dock"

# Singleton launchers/fallback stay outside the workspace-card repeater.
[[ $(rg -c 'model: root\.groupedRequested \? root\.workspacePresentation\.globalLaunchers : \[\]' "$dock") -eq 1 ]]
[[ $(rg -c 'id: groupedPinRepeater' "$dock") -eq 1 ]]
[[ $(rg -c 'root\.workspacePresentation\.fallbackItems' "$dock") -ge 2 ]]

echo "monitor section structural contract: PASS"
