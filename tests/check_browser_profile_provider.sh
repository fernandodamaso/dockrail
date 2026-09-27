#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

fail() {
  printf 'check_browser_profile_provider: %s\n' "$*" >&2
  exit 1
}

provider=provider/browser-profiles/browser_profile_provider.py
service=components/DockBrowserProfileService.qml
icon=components/DockAppIcon.qml
model=components/DockIconModel.js

# Keep onboarding text from claiming remote debugging is an Omarchy default.
if git grep -nEi "omarchy.{0,40}default(s)? (enable|provide)|enabled by omarchy|omarchy does this" -- \
  . ':!tests/check_browser_profile_provider.sh'; then
  fail 'remote-debugging docs must not claim an Omarchy default'
fi

[[ -f "$provider" ]] || fail 'browser profile provider missing'
[[ -f "$service" ]] || fail 'DockBrowserProfileService.qml missing'
[[ -f "$icon" ]] || fail 'DockAppIcon.qml missing'
[[ -f "$model" ]] || fail 'DockIconModel.js missing'

python3 -m py_compile "$provider" || fail 'provider must byte-compile'
command -v python3 >/dev/null 2>&1 || fail 'python3 required'

# Behavioral checks against the real module with a stubbed CDP client. No live
# browser or Hyprland session is required for the host-independent contract.
python3 - <<'PYEOF' || fail 'provider behavior checks failed'
import json, os, sys, tempfile

sys.path.insert(0, "provider/browser-profiles")
import browser_profile_provider as provider

class StubClient:
    def __init__(self, bounds=None):
        self.bounds = bounds or {}
    def call(self, method, params=None, session_id=None):
        if method == "Browser.getWindowForTarget":
            return {"windowId": abs(hash(params["targetId"])) % 1000}
        if method == "Browser.getWindowBounds":
            return {"bounds": self.bounds.get(params["windowId"], {"width": 0, "height": 0})}
        raise provider.CdpError("unsupported")

assert provider.strip_browser_suffix("Inbox - Google Chrome") == "Inbox"
assert provider.strip_browser_suffix("Inbox - Chromium") == "Inbox"
assert provider.strip_browser_suffix("Plain title") == "Plain title"

ctx_a, ctx_b = "CTXAAAAAAAAAAAAAAAAAAAAAAAAAAA", "CTXBBBBBBBBBBBBBBBBBBBBBBBBBBB"
pages = [
    {"targetId": "t1", "title": "Mail", "browserContextId": ctx_a},
    {"targetId": "t2", "title": "New Tab", "browserContextId": ctx_a},
    {"targetId": "t3", "title": "New Tab", "browserContextId": ctx_b},
]
windows = [
    {"address": "0x1", "title": "Mail - Google Chrome", "size": [100, 100]},
    {"address": "0x2", "title": "New Tab - Google Chrome", "size": [200, 100]},
    {"address": "0x3", "title": "New Tab - Google Chrome", "size": [200, 100]},
    {"address": "0x4", "title": "Untitled - Google Chrome", "size": [100, 100]},
]
got = provider.match_window_contexts(StubClient(), windows, pages)
assert got["0x1"] == ctx_a, got
# Two same-title same-size windows stay ambiguous rather than guessing.
assert "0x2" not in got and "0x3" not in got, got
assert "0x4" not in got, got

# Geometry breaks the tie when sizes differ.
pages.append({"targetId": "t4", "title": "Untitled", "browserContextId": ctx_b})
class BoundsClient(StubClient):
    bounds_by_target = {
        "t2": {"width": 100, "height": 100},
        "t3": {"width": 300, "height": 100},
    }
    def call(self, method, params=None, session_id=None):
        if method == "Browser.getWindowForTarget":
            return {"windowId": params["targetId"]}
        if method == "Browser.getWindowBounds":
            return {"bounds": self.bounds_by_target[params["windowId"]]}
        return super().call(method, params, session_id)
windows2 = [
    {"address": "0x2", "title": "New Tab - Google Chrome", "size": [300, 100]},
    {"address": "0x3", "title": "New Tab - Google Chrome", "size": [100, 100]},
]
got2 = provider.match_window_contexts(BoundsClient(), windows2, pages)
assert got2["0x2"] == ctx_b and got2["0x3"] == ctx_a, got2

# Match browser windows one-to-one: a personal window's background New Tab
# must not claim an equal-sized Work window whose active tab is New Tab.
class GroupedWindowClient(StubClient):
    windows_by_target = {
        "personal-mail": "personal",
        "work-new-tab": "work",
        "personal-new-tab": "personal",
    }
    def call(self, method, params=None, session_id=None):
        if method == "Browser.getWindowForTarget":
            return {"windowId": self.windows_by_target[params["targetId"]]}
        if method == "Browser.getWindowBounds":
            return {"bounds": {"width": 200, "height": 100}}
        return super().call(method, params, session_id)

grouped_pages = [
    {"targetId": "personal-mail", "title": "Mail", "browserContextId": ctx_a},
    {"targetId": "work-new-tab", "title": "New Tab", "browserContextId": ctx_b},
    {"targetId": "personal-new-tab", "title": "New Tab", "browserContextId": ctx_a},
]
grouped_windows = [
    {"address": "0x5", "title": "Mail - Google Chrome", "size": [200, 100]},
    {"address": "0x6", "title": "New Tab - Google Chrome", "size": [200, 100]},
]
got3 = provider.match_window_contexts(GroupedWindowClient(), grouped_windows, grouped_pages)
assert got3 == {"0x5": ctx_a, "0x6": ctx_b}, got3

# Provider-owned inspection targets must stay out of Chrome's tab strip. The
# target may be closed after inspection because the provider created it.
class HiddenInspectionTargetClient:
    def __init__(self):
        self.calls = []
    def call(self, method, params=None, session_id=None):
        self.calls.append((method, params, session_id))
        if method == "Target.createTarget":
            return {"targetId": "provider-target"}
        if method == "Target.attachToTarget":
            return {"sessionId": "provider-session"}
        if method == "Runtime.evaluate":
            return {"result": {"value": "Profile Path  /home/u/Default"}}
        if method in ("Target.detachFromTarget", "Target.closeTarget"):
            return {}
        raise provider.CdpError("unexpected call: " + method)

hidden = HiddenInspectionTargetClient()
assert provider.read_profile_path(hidden, ctx_a, []) == "/home/u/Default"
create_call = next(call for call in hidden.calls if call[0] == "Target.createTarget")
assert create_call[1]["hidden"] is True, create_call
assert "Target.closeTarget" in [call[0] for call in hidden.calls], hidden.calls

# Refused provider-owned inspection must leave user tabs untouched. Ordinary
# pages are not safe fallback targets because navigating them can destroy
# unsaved or in-memory state.
class RefusedTargetClient:
    def __init__(self):
        self.calls = []
    def call(self, method, params=None, session_id=None):
        self.calls.append((method, params, session_id))
        if method == "Target.createTarget":
            raise provider.CdpError("target creation refused")
        if method == "Target.attachToTarget":
            return {"sessionId": "user-session"}
        if method == "Runtime.evaluate":
            return {"result": {"value": "Profile Path  /home/u/Default"}}
        if method == "Target.detachFromTarget":
            return {}
        if method in ("Page.navigate", "Target.closeTarget"):
            raise AssertionError("provider touched an existing user target")
        raise provider.CdpError("unexpected call: " + method)

refused = RefusedTargetClient()
assert provider.read_profile_path(refused, ctx_a, [{
    "targetId": "user-tab", "url": "https://example.test/unsaved"
}]) == ""
assert [call[0] for call in refused.calls] == ["Target.createTarget"], refused.calls

# An error while inspecting an already-open chrome://version page must not
# trigger navigation or a close either; only provider-created targets may be
# closed by the resolver.
class BrokenExistingVersionClient:
    def __init__(self):
        self.calls = []
    def call(self, method, params=None, session_id=None):
        self.calls.append((method, params, session_id))
        if method == "Target.createTarget":
            raise provider.CdpError("target creation refused")
        if method == "Target.attachToTarget":
            return {"sessionId": "user-session"}
        if method == "Runtime.evaluate":
            raise provider.CdpError("inspection failed")
        if method == "Target.detachFromTarget":
            return {}
        if method in ("Page.navigate", "Target.closeTarget"):
            raise AssertionError("provider touched an existing user target")
        raise provider.CdpError("unexpected call: " + method)

broken = BrokenExistingVersionClient()
assert provider.read_profile_path(broken, ctx_a, [{
    "targetId": "user-version", "url": "chrome://version"
}]) == ""
assert "Page.navigate" not in [call[0] for call in broken.calls], broken.calls
assert "Target.closeTarget" not in [call[0] for call in broken.calls], broken.calls

# Different titles from one CDP window cannot identify two OS windows.
one_group_pages = [
    {"targetId": "personal-mail", "title": "Mail", "browserContextId": ctx_a},
    {"targetId": "personal-new-tab", "title": "New Tab", "browserContextId": ctx_a},
]
assert provider.match_window_contexts(GroupedWindowClient(), grouped_windows,
                                      one_group_pages) == {}

# Snapshot metadata: Local State names, avatar presence, missing profile skip.
with tempfile.TemporaryDirectory() as tmp:
    data_home = os.path.join(tmp, "chrome")
    os.makedirs(os.path.join(data_home, "Default"))
    with open(os.path.join(data_home, "Local State"), "w") as handle:
        json.dump({"profile": {"info_cache": {
            "Default": {"name": "Fernando"},
            "Profile 1": {"name": "Work"},
        }}}, handle)
    with open(os.path.join(data_home, "Default", "Google Profile Picture.png"), "wb") as handle:
        handle.write(b"png")
    default_path = os.path.join(data_home, "Default")
    profile_path = os.path.join(data_home, "Profile 1")
    snapshot = provider.build_snapshot(
        {"0x1": ctx_a, "0x9": "CTX-UNRESOLVED"},
        {ctx_a: default_path, "CTX-UNRESOLVED": ""},
        9222)
    assert snapshot["schemaVersion"] == 1 and snapshot["available"] is True
    # Unresolved contexts publish no window mapping and no profile entry.
    assert snapshot["windows"] == {"0x1": "Default"}, snapshot["windows"]
    assert set(snapshot["profiles"]) == {"Default"}, snapshot["profiles"]
    entry = snapshot["profiles"]["Default"]
    assert entry["name"] == "Fernando"
    assert entry["avatarPath"].endswith("Google Profile Picture.png")
    # A profile without a photo reports an empty avatar path.
    snapshot2 = provider.build_snapshot({"0x2": ctx_b}, {ctx_b: profile_path}, 9222)
    assert snapshot2["profiles"]["Profile 1"]["name"] == "Work"
    assert snapshot2["profiles"]["Profile 1"]["avatarPath"] == ""

print("provider behavior checks: PASS")
PYEOF

grep -Fq 'DockBrowserProfileService {' Service.qml \
  || fail 'Service.qml must own DockBrowserProfileService'
grep -Fq 'readonly property var browserProfileService: browserLoader.item' Service.qml \
  || fail 'Service.qml must expose the migration-gated profile service'
grep -Fq 'active: migration.ready' Service.qml \
  || fail 'Service.qml must gate provider loaders on migration readiness'
grep -Fq 'DockBrowserProfileService {' Service.qml \
  || fail 'Service.qml must instantiate DockBrowserProfileService after migration'
grep -Fq 'browserProfileService: root.browserProfileService' components/Dock.qml \
  || fail 'Dock.qml must consume the profile service'
grep -Fq 'profileKey: root.browserProfileKey' components/DockItem.qml \
  || fail 'DockItem.qml must forward the window profile key'
grep -Fq 'DockWindowModel.handleForToplevel(toplevel, root.hyprToplevels)' components/Dock.qml \
  || fail 'Dock.qml must resolve generic toplevels through DockWindowModel'
grep -Fq 'DockModel.normalizeWindowAddress(handle.address || ipc.address)' components/Dock.qml \
  || fail 'Dock.qml must normalize profile snapshot addresses through DockModel'
grep -Fq 'google-chrome@profile:' tests/test_icon_overrides.mjs \
  || fail 'icon override tests must cover profile keys'

grep -Fq 'install_dir="$data_home/dockrail/providers"' scripts/install-browser-profile-provider \
  || fail 'browser profile installer must target the canonical Dockrail provider root'

printf 'check_browser_profile_provider: PASS\n'
