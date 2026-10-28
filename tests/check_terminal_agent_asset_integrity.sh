#!/usr/bin/env bash
set -euo pipefail

repo_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
asset_dir="$repo_dir/assets/terminal-agents"

fail() {
  echo "check_terminal_agent_asset_integrity: $*" >&2
  exit 1
}

assert_file() {
  [[ -f "$1" ]] || fail "expected file: $1"
}

assert_contains() {
  local file="$1"
  local needle="$2"
  rg -F -- "$needle" "$file" >/dev/null || fail "missing '$needle' in $file"
}

ids=(
  smartdock-agent-pi
  smartdock-agent-oh-my-pi
  smartdock-agent-command-code
  smartdock-agent-cursor
  smartdock-agent-claude-code
  smartdock-agent-kilo-code
  smartdock-agent-cline
  smartdock-agent-herdr
)

commands=(pi omp commandcode cursor-agent claude kilo cline herdr)
extensions=(png svg svg svg svg svg svg svg)
window_classes=(
  io.github.fernandodamaso.smartdock.agent.pi
  io.github.fernandodamaso.smartdock.agent.oh-my-pi
  io.github.fernandodamaso.smartdock.agent.command-code
  io.github.fernandodamaso.smartdock.agent.cursor
  io.github.fernandodamaso.smartdock.agent.claude-code
  io.github.fernandodamaso.smartdock.agent.kilo-code
  io.github.fernandodamaso.smartdock.agent.cline
  io.github.fernandodamaso.smartdock.agent.herdr
)

assert_file "$asset_dir/ATTRIBUTIONS.md"
assert_contains "$asset_dir/ATTRIBUTIONS.md" 'https://commons.wikimedia.org/wiki/File:Pi_logo.png'
assert_contains "$asset_dir/ATTRIBUTIONS.md" 'https://github.com/can1357/oh-my-pi'
assert_contains "$asset_dir/ATTRIBUTIONS.md" 'https://commandcode.ai/'
assert_contains "$asset_dir/ATTRIBUTIONS.md" 'https://icons8.com/icon/WSo7jgx1Cz2d/cursor-ai'
assert_contains "$asset_dir/ATTRIBUTIONS.md" 'https://dashboardicons.com/icons/claude-ai'
assert_contains "$asset_dir/ATTRIBUTIONS.md" 'https://dashboardicons.com/icons/kilo-code'
assert_contains "$asset_dir/ATTRIBUTIONS.md" 'https://dashboardicons.com/icons/cline'
assert_contains "$asset_dir/ATTRIBUTIONS.md" 'redistribution terms are uncertain'
assert_contains "$asset_dir/ATTRIBUTIONS.md" 'original Dockrail artwork'
assert_contains "$asset_dir/ATTRIBUTIONS.md" 'trademark'

for i in "${!ids[@]}"; do
  id="${ids[$i]}"
  extension="${extensions[$i]}"
  command_name="${commands[$i]}"
  window_class="${window_classes[$i]}"
  icon_file="$asset_dir/$id.$extension"
  desktop_file="$asset_dir/$id.desktop"

  assert_file "$icon_file"
  assert_file "$desktop_file"
  [[ -s "$icon_file" ]] || fail "empty icon: $icon_file"
  assert_contains "$desktop_file" "Terminal=false"
  assert_contains "$desktop_file" "StartupWMClass=$window_class"
  assert_contains "$desktop_file" "Icon=$id"
  assert_contains "$desktop_file" "Exec=ghostty --gtk-single-instance=false --class=$window_class -e $command_name"
  if command -v gjs >/dev/null 2>&1; then
    gjs -c "const Gio=imports.gi.Gio; if (!Gio.Application.id_is_valid('$window_class')) imports.system.exit(1)" \
      || fail "invalid GTK application ID: $window_class"
  fi
  if [[ "$extension" == svg ]]; then
    head -n 1 "$icon_file" | rg -q '<svg|<\?xml' || fail "not an SVG: $icon_file"
  else
    file "$icon_file" | rg -q 'JPEG image data|PNG image data' || fail "not a raster icon: $icon_file"
  fi
done

if rg -q 'currentColor' "$asset_dir/smartdock-agent-kilo-code.svg" \
    "$asset_dir/smartdock-agent-cline.svg"; then
  fail "Kilo and Cline icons need a fixed fill for Qt rendering"
fi

echo "check_terminal_agent_asset_integrity: PASS"
