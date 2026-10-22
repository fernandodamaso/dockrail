#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

fail() { printf 'check_herdr_data_access: %s\n' "$*" >&2; exit 1; }

helper=provider/herdr/bin/smartdock-herdr-helper
provider=provider/herdr/bin/smartdock-herdr-provider
required=(
  "$helper"
  "$provider"
  provider/herdr/discovery.py
  provider/herdr/remote.py
  provider/herdr/model.py
  provider/herdr/UPSTREAM.md
  provider/herdr/LICENSE.omaherdr
  provider/herdr/tests/test_events.py
  provider/herdr/tests/test_protocol.py
  provider/herdr/tests/test_discovery.py
  provider/herdr/tests/test_model.py
  provider/herdr/tests/test_provider.py
  provider/herdr/tests/test_remote.py
  provider/herdr/tests/test_remote_attachments.py
  provider/herdr/tests/test_remote_provider.py
  components/DockHerdrService.qml
  components/DockHerdrAgentsView.qml
  docs/HERDR_DATA_ACCESS.md
)
for file in "${required[@]}"; do
  [[ -f "$file" ]] || fail "missing $file"
done

[[ -x "$helper" ]] || fail 'private helper must remain executable'
[[ "$(git hash-object provider/herdr/LICENSE.omaherdr)" == d645695673349e3947e8e5ae42332d0ac3164cd7 ]]   || fail 'upstream license text changed'

grep -Fq 'c20d9b0db3a65b5a7590876c56026bc906306e04' provider/herdr/UPSTREAM.md   || fail 'pinned provenance missing'
for file in "$helper" "$provider" provider/herdr/discovery.py provider/herdr/remote.py provider/herdr/model.py; do
  grep -Fq 'SPDX-License-Identifier: Apache-2.0' "$file"     || fail "derived-code notice missing: $file"
done

grep -Fq "discover -s provider/herdr/tests" .github/workflows/ci.yml   || fail 'provider suite is missing from CI'
grep -Fq "discover -s tests -p 'test_herdr_*.py'" .github/workflows/ci.yml   || fail 'Herdr lifecycle suite is missing from CI'

grep -Fq '"herdr.agents"' DockHost.qml   || fail 'production source registry is missing herdr.agents'
python3 -c 'import json; s=json.load(open("config/settings-schema.json", encoding="utf-8")); assert "herdr.agents" in s["settings"]["sidebarWidgets"]["registeredIds"]' \
  || fail 'typed schema is missing herdr.agents'
grep -Fq 'DockHerdrService {' Service.qml   || fail 'plugin singleton is missing shared Herdr service'
grep -Fq 'herdrService: root.pluginService.herdrService' Overlay.qml   || fail 'plugin overlay does not consume the migration-gated shared service'
grep -Fq 'DockHerdrService {' shell.qml   || fail 'standalone host is missing its migration-gated shared Herdr service'
grep -Fq 'active: migration.ready' shell.qml   || fail 'standalone Herdr service must remain gated until migration is ready'

grep -Fq '"$source_dir/provider/herdr"' install.sh   || fail 'standalone installer does not copy provider/herdr'
grep -Fq 'smartdock-herdr-provider' install.sh   || fail 'standalone installer does not retain provider entry point'

grep -Fq 'MAX_QUEUE_BYTES = 2 * 1024 * 1024' "$provider"   || fail 'provider queue bound changed unexpectedly'
grep -Fq 'DISCOVERY_CHECK_EVERY = 10.0' "$provider"   || fail 'discovery check cadence changed unexpectedly'
grep -Fq 'SAFETY_SNAPSHOT_EVERY = 60.0' "$provider"   || fail 'safety snapshot cadence changed unexpectedly'
grep -Fq 'MAX_SERVERS = 64' provider/herdr/model.py   || fail 'server cap missing'
grep -Fq 'MAX_AGENTS = 256' provider/herdr/model.py   || fail 'agent cap missing'
grep -Fq '"remote": False' provider/herdr/model.py   || fail 'local-only capability must be explicit'
grep -Fq '"actions": True' provider/herdr/model.py   || fail 'navigate capability must advertise actions'
grep -Fq 'function focusAgent' components/DockHerdrService.qml   || fail 'service missing focusAgent'
grep -Fq 'focus-agent' "$helper"   || fail 'helper missing focus-agent command'
grep -Fq 'agent.focus' "$helper"   || fail 'helper must call only agent.focus'
grep -Fq 'inventory_reconciling' "$provider"   || fail 'provider must keep inventory_reconciling error code'

# The helper is socket-only; discovery/provider may supervise fixed local
# subprocesses but neither path may regain omaherdr coupling or agent-list polling.
if grep -Eq 'subprocess|execDetached|org\.omarchy\.Omaherdr|omaherdr-notify' "$helper"; then
  fail 'private helper acquired a forbidden dependency'
fi
active_paths=(
  Service.qml Overlay.qml DockHost.qml shell.qml
  components/DockHerdrService.qml components/DockHerdrAgentsView.qml
  provider/herdr/attachments.py provider/herdr/discovery.py provider/herdr/remote.py
  provider/herdr/model.py "$provider"
)
if grep -Eiq 'herdr[[:space:]]+agent[[:space:]]+list|org\.omarchy\.Omaherdr|omaherdr-notify' "${active_paths[@]}"; then
  fail 'working integration contains legacy polling/omaherdr coupling'
fi
# SSH is centralized in remote.py; local discovery must not grow ad-hoc transport.
if grep -Eiq '(^|[^[:alnum:]_])ssh([^[:alnum:]_]|$)' provider/herdr/discovery.py; then
  fail 'local discovery must not launch SSH'
fi
grep -Fq 'BatchMode=yes' provider/herdr/remote.py || fail 'remote SSH must be non-interactive'
grep -Fq 'ConnectTimeout=8' provider/herdr/remote.py || fail 'remote SSH connect timeout missing'
grep -Fq 'ServerAliveInterval=15' provider/herdr/remote.py || fail 'remote SSH keepalive missing'
grep -Fq 'ServerAliveCountMax=3' provider/herdr/remote.py || fail 'remote SSH keepalive count missing'
grep -Fq '["ssh", *SSH_OPTIONS, "--", target, remote_command]' provider/herdr/remote.py \
  || fail 'remote target must remain argv data after --'
if grep -Fq 'shell=True' provider/herdr/remote.py; then
  fail 'remote transport must not enable local shell execution'
fi
grep -Fq 'HELPER_OWNER_LEASE_SECONDS = 20.0' provider/herdr/remote.py \
  || fail 'remote helper owner lease missing'
grep -Fq 'command == b"lease"' "$helper" || fail 'remote helper lease renewal missing'

printf 'check_herdr_data_access: PASS\n'
