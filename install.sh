#!/usr/bin/env bash
set -euo pipefail

data_home="${XDG_DATA_HOME:-$HOME/.local/share}"
config_home="${XDG_CONFIG_HOME:-$HOME/.config}"
bin_home="${XDG_BIN_HOME:-$HOME/.local/bin}"
app_dir="$data_home/dockrail"
legacy_app_dir="$data_home/smartdock"
client_dir="$data_home/dockrail-cli"
legacy_client_dir="$data_home/smartdock-cli"
config_dir="$config_home/dockrail"
legacy_config_dir="$config_home/smartdock"
desktop_dir="$data_home/applications"
desktop_file="$desktop_dir/smartdock.desktop"
install_autostart=true
agent_assets_only=false
cli_only=false

agent_ids=(
  smartdock-agent-pi
  smartdock-agent-oh-my-pi
  smartdock-agent-command-code
  smartdock-agent-cursor
  smartdock-agent-claude-code
  smartdock-agent-kilo-code
  smartdock-agent-cline
)
agent_extensions=(png svg svg svg svg svg svg)

usage() {
  cat <<'EOF'
Usage: install.sh [OPTION]

  --cli-only      Install just the client, schema/defaults and offline documentation
  --no-autostart  Do not create an XDG autostart entry for standalone installation
  --agent-assets-only
                  Install only the terminal-agent launchers and icons
  --help          Show this help
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --cli-only) cli_only=true ;;
    --no-autostart) install_autostart=false ;;
    --agent-assets-only) agent_assets_only=true ;;
    --help|-h) usage; exit ;;
    *) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
  shift
done
if $cli_only && $agent_assets_only; then
  echo '--cli-only cannot be combined with --agent-assets-only.' >&2
  exit 2
fi

for command in install cp rm; do
  command -v "$command" >/dev/null 2>&1 || {
    echo "Required command not found: $command" >&2
    exit 1
  }
done

source_dir=""
script_path="${BASH_SOURCE[0]:-}"
if [[ -n "$script_path" ]]; then
  candidate="$(cd -- "$(dirname -- "$script_path")" 2>/dev/null && pwd || true)"
  if [[ -f "$candidate/shell.qml" && -d "$candidate/components" ]]; then
    source_dir="$candidate"
  fi
fi
if [[ -z "$source_dir" ]]; then
  echo 'install.sh must be run from a Dockrail source tree.' >&2
  echo 'Clone or unpack your own Dockrail repository, then run ./install.sh.' >&2
  exit 1
fi

# Both installation types own their adapter and read-only bundle. Neither uses
# the live config as its schema, and removal of one does not break the other.
install_client_bundle() {
  local destination="$1"
  install -d "$destination/scripts" "$destination/config" "$destination/docs" "$bin_home"
  if [[ "$source_dir" != "$destination" ]]; then
    rm -rf -- "$destination/components/widgets" "$destination/SmartDock" "$destination/Dockrail"
    install -d "$destination/components"
    cp -R -- "$source_dir/components/widgets" "$destination/components/widgets"
    cp -R -- "$source_dir/SmartDock" "$destination/SmartDock"
    cp -R -- "$source_dir/Dockrail" "$destination/Dockrail"
    install -m 0644 "$source_dir/scripts/smartdock_cli.py" "$destination/scripts/smartdock_cli.py"
    install -m 0644 "$source_dir/scripts/smartdock_dev.py" "$destination/scripts/smartdock_dev.py"
    install -m 0644 "$source_dir/scripts/smartdock_widget.py" "$destination/scripts/smartdock_widget.py"
    install -m 0644 "$source_dir/scripts/dockrail_paths.py" "$destination/scripts/dockrail_paths.py"
    install -m 0644 "$source_dir/scripts/dockrail_migrate.py" "$destination/scripts/dockrail_migrate.py"
    install -m 0755 "$source_dir/scripts/smartdock_seed_demo_widgets.py" "$destination/scripts/smartdock_seed_demo_widgets.py"
    install -m 0644 "$source_dir/config/settings-schema.json" "$destination/config/settings-schema.json"
    install -m 0644 "$source_dir/config/dock.json" "$destination/config/dock.json"
    local document
    for document in AGENT_CONFIGURATION.md CLI_REFERENCE.md CONFIGURATION.md CLI_RUNTIME_CHECKS.md DEV_SWITCH.md HERDR_DATA_ACCESS.md SIDEBAR_WIDGETS.md WIDGET_COMPONENTS.md WIDGET_PACKAGES.md DOCKRAIL_MIGRATION.md; do
      install -m 0644 "$source_dir/docs/$document" "$destination/docs/$document"
    done
    install -m 0755 "$source_dir/uninstall.sh" "$destination/uninstall.sh"
  fi
  install -m 0755 "$source_dir/scripts/dockrail" "$bin_home/dockrail"
  install -m 0755 "$source_dir/scripts/smartdock" "$bin_home/smartdock"
}

if $cli_only; then
  command -v python3 >/dev/null 2>&1 || { echo 'Python 3 is required for the CLI.' >&2; exit 1; }
  plugin_dir="$HOME/.config/omarchy/plugins/io.github.fernandodamaso.dockrail"
  xdg_plugin_dir="$config_home/omarchy/plugins/io.github.fernandodamaso.dockrail"
  if [[ "$source_dir" == "$plugin_dir" || "$source_dir" == "$xdg_plugin_dir" ]]; then
    rm -rf -- "$client_dir"
    install -d "$client_dir" "$bin_home"
    printf '%s\n' "$source_dir" >"$client_dir/.plugin-dir"
    install -m 0755 "$source_dir/uninstall.sh" "$client_dir/uninstall.sh"
    install -m 0755 "$source_dir/scripts/dockrail" "$bin_home/dockrail"
    install -m 0755 "$source_dir/scripts/smartdock" "$bin_home/smartdock"
  else
    rm -f -- "$client_dir/.plugin-dir"
    install_client_bundle "$client_dir"
    printf '%s\n' "$source_dir" >"$client_dir/.source-dir"
  fi
  echo "Installed Dockrail client: $bin_home/dockrail"
  echo "Installed SmartDock compatibility command: $bin_home/smartdock"
  echo 'No dock, configuration, autostart or terminal-agent assets were installed.'
  echo "Next: $bin_home/dockrail doctor"
  exit
fi

agent_asset_dir="$source_dir/assets/terminal-agents"
svg_icon_dir="$data_home/icons/hicolor/scalable/apps"
raster_icon_dir="$data_home/icons/hicolor/256x256/apps"

install_agent_assets() {
  [[ -d "$agent_asset_dir" ]] || { echo "Terminal-agent assets not found: $agent_asset_dir" >&2; exit 1; }
  install -d "$desktop_dir" "$svg_icon_dir" "$raster_icon_dir"
  for index in "${!agent_ids[@]}"; do
    id="${agent_ids[$index]}"
    extension="${agent_extensions[$index]}"
    icon_dir="$svg_icon_dir"
    if [[ "$extension" != svg ]]; then icon_dir="$raster_icon_dir"; fi
    install -m 0644 "$agent_asset_dir/$id.desktop" "$desktop_dir/$id.desktop"
    install -m 0644 "$agent_asset_dir/$id.$extension" "$icon_dir/$id.$extension"
  done
}

if $agent_assets_only; then
  install_agent_assets
  echo 'Installed Dockrail terminal-agent launchers and icons.'
  exit
fi

if ! command -v qs >/dev/null 2>&1; then
  echo 'Quickshell is required but qs was not found.' >&2
  exit 1
fi
command -v python3 >/dev/null 2>&1 || { echo 'Python 3 is required for the CLI.' >&2; exit 1; }

migration_json=""
migration_was_running=false
migration_provenance=
if ! migration_json="$(python3 -B "$source_dir/scripts/dockrail_migrate.py" startup --runtime standalone --handoff-standalone)"; then
  printf '%s\n' "$migration_json" >&2
  exit 1
fi
migration_was_running="$(python3 -c 'import json,sys; print("true" if json.load(sys.stdin)["data"]["standaloneWasRunning"] else "false")' <<<"$migration_json")"
migration_provenance="$(python3 -c 'import json,sys; print(json.load(sys.stdin)["data"]["selectionProvenance"])' <<<"$migration_json")"

install -d "$app_dir" "$config_dir" "$bin_home" "$desktop_dir"
if [[ "$source_dir" != "$app_dir" ]]; then
  rm -rf -- "$app_dir/components"
  rm -rf -- "$app_dir/SmartDock"
  rm -rf -- "$app_dir/Dockrail"
  rm -rf -- "$app_dir/assets"
  rm -rf -- "$app_dir/provider/herdr"
  install -d "$app_dir/provider"
  cp -R -- "$source_dir/components" "$app_dir/components"
  cp -R -- "$source_dir/SmartDock" "$app_dir/SmartDock"
  cp -R -- "$source_dir/Dockrail" "$app_dir/Dockrail"
  cp -R -- "$source_dir/assets" "$app_dir/assets"
  cp -R -- "$source_dir/provider/herdr" "$app_dir/provider/herdr"
  chmod 0755 "$app_dir/provider/herdr/bin/smartdock-herdr-helper" \
    "$app_dir/provider/herdr/bin/smartdock-herdr-provider"
  install -m 0644 "$source_dir/shell.qml" "$app_dir/shell.qml"
  install -m 0644 "$source_dir/DockHost.qml" "$app_dir/DockHost.qml"
  install -m 0644 "$source_dir/LICENSE" "$app_dir/LICENSE"
  install -m 0755 "$source_dir/install.sh" "$app_dir/install.sh"
  printf '%s\n' "$source_dir" >"$app_dir/.source-dir"
fi
install_client_bundle "$app_dir"
install_agent_assets

cat >"$desktop_file" <<EOF
[Desktop Entry]
Type=Application
Name=Dockrail
Comment=Developer workspace rail for Hyprland
Exec="$bin_home/dockrail" restart
Icon=preferences-desktop
Terminal=false
Categories=Utility;
Keywords=Dock;Launcher;Hyprland;
StartupNotify=false
EOF
chmod 0644 "$desktop_file"

if [[ ! -f "$config_dir/dock.json" ]]; then
  install -m 0644 "$source_dir/config/dock.json" "$config_dir/dock.json"
  echo "Created configuration: $config_dir/dock.json"
else
  echo "Preserved configuration: $config_dir/dock.json"
fi

if [[ "$migration_provenance" == "canonical-clean" ]]; then
  demo_widget_seed_marker="$config_dir/.demo-widgets-seeded-v2"
  demo_widget_seed_result="$(python3 "$source_dir/scripts/smartdock_seed_demo_widgets.py" "$config_dir/dock.json" "$demo_widget_seed_marker")"
  case "$demo_widget_seed_result" in
    seeded) echo "Enabled missing Dockrail demo Widgets for this branch." ;;
    preserved) echo "Demo Widget selection already present." ;;
    already) ;;
    invalid) echo "Skipped demo Widget seeding because the existing Widget config needs repair." >&2 ;;
  esac
fi

if $install_autostart; then "$bin_home/dockrail" autostart enable; fi

cat <<EOF

Dockrail installed successfully.

Run explicitly:
  $bin_home/dockrail launch --daemonize

Inspect without launching:
  $bin_home/dockrail status --json
  $bin_home/dockrail agent-guide

Configuration:
  $config_dir/dock.json

Update standalone later:
  $bin_home/dockrail update
EOF
case ":$PATH:" in
  *":$bin_home:"*) ;;
  *) echo; echo "Note: add $bin_home to PATH to run dockrail by name." ;;
esac

if $migration_was_running; then
  "$bin_home/dockrail" launch --daemonize
fi
