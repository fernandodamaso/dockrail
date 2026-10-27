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
desktop_file="$data_home/applications/smartdock.desktop"
purge=false
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
desktop_dir="$data_home/applications"
svg_icon_dir="$data_home/icons/hicolor/scalable/apps"
raster_icon_dir="$data_home/icons/hicolor/256x256/apps"

usage() {
  cat <<'EOF'
Usage: uninstall.sh [OPTION]

  --cli-only      Remove only client-owned files, never live plugin configuration
  --agent-assets-only
                  Remove only the terminal-agent launchers and icons
  --purge         Remove standalone Dockrail and its configuration
  --help          Show this help
EOF
}
while [[ $# -gt 0 ]]; do
  case "$1" in
    --cli-only) cli_only=true ;;
    --purge) purge=true ;;
    --agent-assets-only) agent_assets_only=true ;;
    --help|-h) usage; exit ;;
    *) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
  shift
done
if $cli_only && { $purge || $agent_assets_only; }; then
  echo '--cli-only cannot be combined with --purge or --agent-assets-only.' >&2
  exit 2
fi
if $agent_assets_only && $purge; then
  echo '--agent-assets-only cannot be combined with --purge.' >&2
  exit 2
fi

has_supported_bundle() {
  [[ -f "$app_dir/shell.qml" || -f "$legacy_app_dir/shell.qml"
    || -f "$client_dir/scripts/smartdock_cli.py"
    || -f "$legacy_client_dir/scripts/smartdock_cli.py" ]]
}

if $cli_only; then
  rm -rf -- "$client_dir"
  if ! has_supported_bundle; then
    rm -f -- "$bin_home/dockrail" "$bin_home/smartdock"
  fi
  echo 'Removed Dockrail client-only files. Plugin, standalone and configuration were not changed.'
  exit
fi

remove_agent_assets() {
  for index in "${!agent_ids[@]}"; do
    id="${agent_ids[$index]}"
    extension="${agent_extensions[$index]}"
    rm -f -- "$desktop_dir/$id.desktop"
    if [[ "$extension" == svg ]]; then
      rm -f -- "$svg_icon_dir/$id.svg"
    else
      rm -f -- "$raster_icon_dir/$id.$extension"
    fi
  done
}
if $agent_assets_only; then
  remove_agent_assets
  echo 'Removed Dockrail terminal-agent launchers and icons.'
  exit
fi
# Refuse --purge before removing anything: the plugin shares the configuration.
# Check both plugin roots, as install.sh --cli-only and the CLI do.
if $purge; then
  for plugins_dir in "$HOME/.config/omarchy/plugins" "$config_home/omarchy/plugins"; do
    for plugin_id in io.github.fernandodamaso.dockrail io.github.fernandodamaso.smartdock; do
      plugin_root="$plugins_dir/$plugin_id"
      plugin_backup="$plugins_dir/.$plugin_id.smartdock-installed"
      if [[ -e "$plugin_root" || -L "$plugin_root" || -e "$plugin_backup" ]]; then
        echo 'Refusing --purge while the Omarchy Dockrail plugin is installed or in development mode.' >&2
        echo "Nothing was removed. Configuration preserved at: $config_dir/dock.json" >&2
        exit 1
      fi
    done
  done
fi
if command -v qs >/dev/null 2>&1; then
  qs kill -p "$app_dir" --any-display >/dev/null 2>&1 || true
fi
remove_agent_assets
rm -f -- "$config_home/autostart/smartdock.desktop"
rm -f -- "$desktop_file"
# Remove standalone deployment files without deleting shared Widget/provider
# state that can still be consumed by the Omarchy plugin.
rm -rf -- "$app_dir/components" "$app_dir/SmartDock" "$app_dir/Dockrail" "$app_dir/assets"   "$app_dir/provider" "$app_dir/scripts" "$app_dir/config" "$app_dir/docs"
rm -f -- "$app_dir/shell.qml" "$app_dir/DockHost.qml" "$app_dir/LICENSE"   "$app_dir/install.sh" "$app_dir/uninstall.sh" "$app_dir/.source-dir"
rmdir "$app_dir" 2>/dev/null || true

if ! has_supported_bundle; then
  rm -f -- "$bin_home/dockrail" "$bin_home/smartdock"
fi
if $purge; then
  rm -rf -- "$config_dir"
  if [[ -L "$legacy_config_dir" ]]; then
    legacy_target="$(readlink -f -- "$legacy_config_dir" 2>/dev/null || true)"
    canonical_target="$(readlink -f -- "$config_dir" 2>/dev/null || printf '%s' "$config_dir")"
    if [[ "$legacy_target" == "$canonical_target" || ! -e "$legacy_config_dir" ]]; then
      rm -f -- "$legacy_config_dir"
    fi
  fi
  echo 'Removed standalone Dockrail configuration. Shared Widget/provider state was preserved.'
else
  echo 'Removed standalone Dockrail. Configuration preserved at:'
  echo "  $config_dir/dock.json"
fi
