#!/usr/bin/env bash
# Standalone launchers keep the qs.* import alias pointed at the current
# OMARCHY_PATH, recover from a dangling alias, and never replace a real directory.
set -euo pipefail
repo="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
tmp="$(mktemp -d -t 'dockrail-qml-alias.XXXXXX')"
trap 'rm -rf -- "$tmp"' EXIT
export HOME="$tmp/home with spaces"
export XDG_DATA_HOME="$HOME/data" XDG_CONFIG_HOME="$HOME/config"
export XDG_CACHE_HOME="$HOME/cache"
mkdir -p "$tmp/tools" "$XDG_DATA_HOME/dockrail"
touch "$XDG_DATA_HOME/dockrail/shell.qml"
printf '#!/usr/bin/env bash\nexit 0\n' >"$tmp/tools/qs"
chmod +x "$tmp/tools/qs"
export PATH="$tmp/tools:$PATH"
alias_path="$XDG_CACHE_HOME/dockrail/qml-imports/qs"

make_omarchy() { mkdir -p "$1/shell/Commons" "$1/shell/Ui"; }
make_omarchy "$tmp/omarchy old"
make_omarchy "$tmp/omarchy new"

for launcher in run dockrail; do
  rm -rf -- "$XDG_CACHE_HOME"
  command=("$repo/scripts/run")
  [[ "$launcher" == dockrail ]] && command=("$repo/scripts/dockrail" launch)

  OMARCHY_PATH="$tmp/omarchy old" bash "${command[@]}"
  test "$(readlink -- "$alias_path")" = "$tmp/omarchy old/shell"

  # Existing but stale alias follows the new OMARCHY_PATH.
  OMARCHY_PATH="$tmp/omarchy new" bash "${command[@]}"
  test "$(readlink -- "$alias_path")" = "$tmp/omarchy new/shell"

  # Dangling alias (Omarchy moved away) is replaced instead of aborting.
  ln -sfn -- "$tmp/omarchy gone/shell" "$alias_path"
  OMARCHY_PATH="$tmp/omarchy new" bash "${command[@]}"
  test "$(readlink -- "$alias_path")" = "$tmp/omarchy new/shell"

  # A real directory at the alias path is left alone.
  rm -f -- "$alias_path"
  mkdir -p "$alias_path/keep"
  OMARCHY_PATH="$tmp/omarchy new" bash "${command[@]}"
  test ! -L "$alias_path"
  test -d "$alias_path/keep"
done

echo "qml import alias: ok"
