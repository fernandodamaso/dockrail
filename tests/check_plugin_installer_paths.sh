#!/usr/bin/env bash
set -euo pipefail

repo_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
test_root="$(mktemp -d -t 'dockrail-plugin-installers.XXXXXX')"
trap 'rm -rf -- "$test_root"' EXIT

fail() {
  printf 'check_plugin_installer_paths: %s\n' "$*" >&2
  exit 1
}

assert_contains() {
  local output="$1"
  local needle="$2"
  [[ "$output" == *"$needle"* ]] || fail "missing output: $needle"
}

export HOME="$test_root/home with spaces"
export XDG_CONFIG_HOME="$HOME/.config"
export XDG_DATA_HOME="$HOME/data"
export XDG_CACHE_HOME="$HOME/cache"
export XDG_BIN_HOME="$HOME/bin"
export XDG_STATE_HOME="$HOME/state"

plugin="$XDG_CONFIG_HOME/omarchy/plugins/io.github.fernandodamaso.dockrail"
mkdir -p "$plugin/components" "$plugin/scripts" "$plugin/assets" \
  "$plugin/provider/browser-profiles" "$plugin/provider/launcher-badges"
cp "$repo_dir/install.sh" "$plugin/install.sh"
cp "$repo_dir/shell.qml" "$plugin/shell.qml"
cp "$repo_dir/scripts/install-browser-profile-provider" "$plugin/scripts/"
cp "$repo_dir/scripts/build-launcher-badge-provider" "$plugin/scripts/"
cp "$repo_dir/provider/browser-profiles/browser_profile_provider.py" \
  "$plugin/provider/browser-profiles/"
cp -R "$repo_dir/assets/terminal-agents" "$plugin/assets/"

[[ ! -e "$plugin/.git" ]] || fail 'plugin fixture must not contain .git metadata'

snapshot_plugin() {
  python3 - "$plugin" <<'PY'
import hashlib
import pathlib
import stat
import sys

root = pathlib.Path(sys.argv[1])
for path in sorted(root.rglob("*")):
    st = path.lstat()
    rel = path.relative_to(root).as_posix()
    mode = stat.S_IMODE(st.st_mode)
    if path.is_symlink():
        payload = "link:" + path.readlink().as_posix()
    elif path.is_file():
        payload = "sha256:" + hashlib.sha256(path.read_bytes()).hexdigest()
    else:
        payload = "dir"
    print(f"{rel}\t{mode:o}\t{st.st_size}\t{st.st_mtime_ns}\t{payload}")
PY
}

fake_bin="$test_root/fake-bin"
mkdir -p "$fake_bin"
cat >"$fake_bin/cmake" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
case "${1:-}" in
  -S)
    build_dir=""
    while [[ $# -gt 0 ]]; do
      if [[ "$1" == "-B" ]]; then
        build_dir="$2"
        shift 2
      else
        shift
      fi
    done
    [[ -n "$build_dir" ]]
    mkdir -p "$build_dir"
    printf 'configured\n' >"$build_dir/configure-marker"
    ;;
  --build)
    build_dir="$2"
    cat >"$build_dir/smartdock-launcher-badge-provider" <<'BIN'
#!/usr/bin/env bash
exit 0
BIN
    chmod 0755 "$build_dir/smartdock-launcher-badge-provider"
    ;;
  *)
    exit 2
    ;;
esac
EOF
cat >"$fake_bin/ctest" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod 0755 "$fake_bin/cmake" "$fake_bin/ctest"
export PATH="$fake_bin:$PATH"

plugin_invocation='bash "${XDG_CONFIG_HOME:-$HOME/.config}/omarchy/plugins/io.github.fernandodamaso.dockrail'
next_reload='Next: reload the dock with `omarchy restart shell`.'
next_doctor='Then verify with `dockrail doctor`.'

before="$(snapshot_plugin)"
cd "$plugin"

agent_output="$(bash ./install.sh --agent-assets-only)"
[[ "$before" == "$(snapshot_plugin)" ]] || fail 'agent asset install wrote inside plugin directory'
assert_contains "$agent_output" "${plugin_invocation}/install.sh\" --agent-assets-only"
assert_contains "$agent_output" "$next_reload"
assert_contains "$agent_output" "$next_doctor"

browser_output="$(bash ./scripts/install-browser-profile-provider)"
[[ "$before" == "$(snapshot_plugin)" ]] || fail 'browser provider install wrote inside plugin directory'
assert_contains "$browser_output" "${plugin_invocation}/scripts/install-browser-profile-provider\""
assert_contains "$browser_output" 'explicitly enabled DevTools endpoint'
assert_contains "$browser_output" 'security note'
assert_contains "$browser_output" "$next_reload"
assert_contains "$browser_output" "$next_doctor"
[[ -x "$XDG_DATA_HOME/dockrail/providers/smartdock-browser-profile-provider" ]] \
  || fail 'browser provider was not installed'
find "$XDG_CACHE_HOME/dockrail/browser-profile-provider-build" -type f -name '*.pyc' -print -quit | grep -q . \
  || fail 'browser bytecode check was not staged in XDG cache'
[[ ! -e "$plugin/provider/browser-profiles/__pycache__" ]] \
  || fail 'browser bytecode leaked into plugin directory'

launcher_output="$(bash ./scripts/build-launcher-badge-provider)"
[[ "$before" == "$(snapshot_plugin)" ]] || fail 'launcher provider build wrote inside plugin directory'
assert_contains "$launcher_output" "${plugin_invocation}/scripts/build-launcher-badge-provider\""
assert_contains "$launcher_output" "$next_reload"
assert_contains "$launcher_output" "$next_doctor"
[[ -x "$XDG_DATA_HOME/dockrail/providers/smartdock-launcher-badge-provider" ]] \
  || fail 'launcher badge provider was not installed'
[[ -f "$XDG_CACHE_HOME/dockrail/launcher-badge-provider-build/configure-marker" ]] \
  || fail 'launcher badge provider did not build in XDG cache'

echo 'check_plugin_installer_paths: PASS'
