#!/usr/bin/env bash
# CLI installation owns no desktop/plugin state and cooperates with standalone.
set -euo pipefail
repo="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
tmp="$(mktemp -d -t 'smartdock-cli-install.XXXXXX')"
trap 'rm -rf -- "$tmp"' EXIT
export HOME="$tmp/home with spaces"
export XDG_DATA_HOME="$HOME/data" XDG_CONFIG_HOME="$HOME/config"
export XDG_BIN_HOME="$HOME/bin" XDG_CACHE_HOME="$HOME/cache"
export XDG_STATE_HOME="$HOME/state"
mkdir -p "$tmp/tools"
printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >>"$QS_INSTALL_LOG"\n' >"$tmp/tools/qs"
chmod +x "$tmp/tools/qs"
export QS_INSTALL_LOG="$tmp/qs.log"
export PATH="$tmp/tools:$PATH"

cli_install() { bash "$repo/install.sh" --cli-only; }
full_install() { bash "$repo/install.sh" --no-autostart; }
cli_remove() { bash "$repo/uninstall.sh" --cli-only; }
full_remove() { bash "$repo/uninstall.sh"; }

cli_install
cli_install
test -x "$XDG_BIN_HOME/dockrail"
test -x "$XDG_BIN_HOME/smartdock"
test -f "$XDG_DATA_HOME/dockrail-cli/scripts/smartdock_cli.py"
test -f "$XDG_DATA_HOME/dockrail-cli/scripts/smartdock_widget.py"
test -f "$XDG_DATA_HOME/dockrail-cli/scripts/dockrail_migrate.py"
test -f "$XDG_DATA_HOME/dockrail-cli/SmartDock/WidgetKit/qmldir"
test -f "$XDG_DATA_HOME/dockrail-cli/Dockrail/WidgetKit/qmldir"
test -f "$XDG_DATA_HOME/dockrail-cli/components/widgets/WidgetSection.qml"
test -f "$XDG_DATA_HOME/dockrail-cli/config/settings-schema.json"
test -f "$XDG_DATA_HOME/dockrail-cli/config/dock.json"
test -f "$XDG_DATA_HOME/dockrail-cli/docs/AGENT_CONFIGURATION.md"
test "$(cat "$XDG_DATA_HOME/dockrail-cli/.source-dir")" = "$repo"
test ! -e "$XDG_DATA_HOME/dockrail"
test ! -e "$XDG_DATA_HOME/smartdock"
test ! -e "$XDG_DATA_HOME/applications"
test ! -e "$XDG_DATA_HOME/icons"
test ! -e "$XDG_CONFIG_HOME"
test ! -e "$XDG_CACHE_HOME"
test ! -e "$QS_INSTALL_LOG"
"$XDG_BIN_HOME/smartdock" agent-guide >/dev/null
"$XDG_BIN_HOME/smartdock" help >/dev/null
"$XDG_BIN_HOME/smartdock" dev --help >/dev/null
"$XDG_BIN_HOME/smartdock" widget --help >/dev/null
"$XDG_BIN_HOME/smartdock" widget list --json >/dev/null
test -f "$XDG_DATA_HOME/dockrail-cli/docs/DEV_SWITCH.md"
test -f "$XDG_DATA_HOME/dockrail-cli/docs/WIDGET_PACKAGES.md"
test -f "$XDG_DATA_HOME/dockrail-cli/docs/DOCKRAIL_MIGRATION.md"
test ! -e "$QS_INSTALL_LOG"
if bash "$repo/uninstall.sh" --cli-only --purge; then
  echo 'Client-only purge must be rejected' >&2
  exit 1
fi
test -x "$XDG_BIN_HOME/smartdock"

# Client first, then standalone: client removal retains standalone ownership.
full_install
printf '{"pinned":["Keep.Me"],"extension":true}\n' >"$XDG_CONFIG_HOME/dockrail/dock.json"
config_before="$(cat "$XDG_CONFIG_HOME/dockrail/dock.json")"
source_before="$(cat "$XDG_DATA_HOME/dockrail/.source-dir")"
cli_remove
test -x "$XDG_BIN_HOME/smartdock"
test -f "$XDG_DATA_HOME/dockrail/shell.qml"
test -f "$XDG_DATA_HOME/dockrail/scripts/smartdock_cli.py"
test -f "$XDG_DATA_HOME/dockrail/scripts/smartdock_widget.py"
test -f "$XDG_DATA_HOME/dockrail/SmartDock/WidgetKit/qmldir"
test -f "$XDG_DATA_HOME/dockrail/Dockrail/WidgetKit/qmldir"
test "$source_before" = "$(cat "$XDG_DATA_HOME/dockrail/.source-dir")"
test "$config_before" = "$(cat "$XDG_CONFIG_HOME/dockrail/dock.json")"
"$XDG_BIN_HOME/smartdock" agent-guide >/dev/null
full_remove
test ! -e "$XDG_BIN_HOME/dockrail"
test ! -e "$XDG_BIN_HOME/smartdock"
test "$config_before" = "$(cat "$XDG_CONFIG_HOME/dockrail/dock.json")"

# Standalone first, then client: standalone removal retains client ownership.
full_install
cli_install
full_remove
test -x "$XDG_BIN_HOME/smartdock"
test -f "$XDG_DATA_HOME/dockrail-cli/scripts/smartdock_cli.py"
"$XDG_BIN_HOME/smartdock" help >/dev/null
"$XDG_BIN_HOME/smartdock" agent-guide >/dev/null
cli_remove
cli_remove
test ! -e "$XDG_BIN_HOME/dockrail"
test ! -e "$XDG_BIN_HOME/smartdock"
test "$config_before" = "$(cat "$XDG_CONFIG_HOME/dockrail/dock.json")"

# A plugin install uses its live tree, including a path with spaces, and survives updates.
export HOME="$tmp/plugin home with spaces"
export XDG_DATA_HOME="$HOME/data" XDG_CONFIG_HOME="$HOME/config"
export XDG_BIN_HOME="$HOME/bin" XDG_CACHE_HOME="$HOME/cache" XDG_STATE_HOME="$HOME/state"
export PATH="$XDG_BIN_HOME:$PATH"
plugin="$HOME/.config/omarchy/plugins/io.github.fernandodamaso.dockrail"
mkdir -p "$plugin/components"
cp -R "$repo/scripts" "$repo/config" "$repo/docs" "$plugin/"
cp "$repo/install.sh" "$repo/uninstall.sh" "$plugin/"
touch "$plugin/shell.qml"
bash "$repo/install.sh" --cli-only >/dev/null
test -f "$XDG_DATA_HOME/dockrail-cli/scripts/smartdock_cli.py"
install_output="$(bash "$plugin/install.sh" --cli-only 2>&1)"
test "$(command -v dockrail)" = "$XDG_BIN_HOME/dockrail"
test "$(command -v smartdock)" = "$XDG_BIN_HOME/smartdock"
test -f "$XDG_DATA_HOME/dockrail-cli/.plugin-dir"
test ! -e "$XDG_DATA_HOME/dockrail-cli/scripts/smartdock_cli.py"
[[ "$install_output" == *'dockrail doctor'* ]]
dockrail help >/dev/null
smartdock agent-guide >/dev/null
python3 - "$plugin/config/settings-schema.json" <<'PY'
import json, pathlib, sys
path = pathlib.Path(sys.argv[1])
schema = json.loads(path.read_text())
schema['settings']['iconSize']['description'] = 'Updated plugin schema'
path.write_text(json.dumps(schema))
PY
python3 - "$plugin/config/dock.json" <<'PY'
import json, pathlib, sys
path = pathlib.Path(sys.argv[1])
defaults = json.loads(path.read_text())
defaults['iconSize'] = 47
path.write_text(json.dumps(defaults))
PY
printf '\nPlugin guide updated\n' >>"$plugin/docs/AGENT_CONFIGURATION.md"
dockrail config schema iconSize --json | python3 -c 'import json,sys; spec = json.load(sys.stdin)["data"]["settings"]["iconSize"]; assert (spec["description"], spec["default"]) == ("Updated plugin schema", 47)'
dockrail agent-guide | rg -q 'Plugin guide updated'
test ! -e "$XDG_CONFIG_HOME"
test ! -e "$XDG_CACHE_HOME"
test ! -e "$XDG_STATE_HOME"
mv "$plugin" "$plugin.removed"
if "$XDG_BIN_HOME/dockrail" config schema --json >"$tmp/missing-plugin.out" 2>"$tmp/missing-plugin.err"; then
  echo 'A removed plugin must stop the live CLI launcher' >&2
  exit 1
fi
rg -q 'bash ~/.config/omarchy/plugins/io.github.fernandodamaso.dockrail/install.sh --cli-only' "$tmp/missing-plugin.out" "$tmp/missing-plugin.err"
! rg -q 'Traceback' "$tmp/missing-plugin.out" "$tmp/missing-plugin.err"
if smartdock help >"$tmp/missing-smartdock.out" 2>&1; then
  echo 'A removed plugin must stop the compatibility launcher' >&2
  exit 1
fi
rg -q 'Reinstall with: omarchy plugin add' "$tmp/missing-smartdock.out"
bash "$repo/uninstall.sh" --cli-only
test ! -e "$XDG_BIN_HOME/dockrail"
test ! -e "$XDG_BIN_HOME/smartdock"
echo 'CLI-only installation/coexistence checks passed.'
