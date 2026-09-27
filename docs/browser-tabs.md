# Browser tabs in the sidebar

Dockrail can nest open Chrome **page tabs** under each matched Hyprland Chrome
window row in sidebar mode. This is a separate snapshot channel from unread
[`activities`](browser-activity.md); it does not overload activity rows.
Enable the optional Chrome endpoint and install the provider using
**[Enable Chrome profiles and tabs](browser-activity.md#enable-chrome-profiles-and-tabs)**.

## Snapshot contract

When the optional browser-profile provider can talk to Chrome DevTools, the
runtime snapshot includes a `tabs` map keyed by Hyprland window address:

```json
{
  "schemaVersion": 1,
  "available": true,
  "port": 9222,
  "windows": {"0x123": "Profile 1"},
  "profiles": {},
  "activities": {},
  "tabs": {
    "0x123": [
      {"targetId": "A1B2C3D4", "title": "Inbox - Gmail", "active": true,
       "windowAddress": "0x123",
       "faviconPath": "/home/user/.cache/smartdock/tab-favicons/abcd.png"},
      {"targetId": "E5F6A7B8", "title": "Linear", "active": false,
       "windowAddress": "0x123"}
    ]
  }
}
```

Each row publishes **title**, **active**, and an optional local **faviconPath**
(cached under `~/.cache/smartdock/tab-favicons/`). Full page URLs and remote
favicon URLs are never included in the dock snapshot. Extension pages and the
provider's temporary `chrome://version` helper targets are omitted.
Lists are capped at 50 tabs per window. Order follows Chrome's tab-strip index
(`Target.getTargets` filter `type=tab` → `embedderData.tabStripIndex`, Chrome
150+), which stays correct with tab groups. Older Chrome falls back to page
target enumeration order. The sidebar never promotes the selected tab to the
top. Optional `tabGroupId` is included when Chrome reports it. Tabs without a
site favicon render the bundled Lucide `earth` icon, never a remote URL. Older
snapshots without `tabs` stay classic-safe: the dock treats missing `tabs` as
an empty map.

## Sidebar behavior

- Setting: `sidebarBrowserTabsEnabled` (default `true`). Independent of
  `browserActivityMutedServices`.
- When the provider is unavailable or the setting is false, Chrome windows stay
  ordinary window rows with no tab children.
- Sole Chrome windows can expand for tabs (session fold key `tabs:<windowKey>`).
  Tabs start **expanded**; the window-row chevron folds the list. Clicking the
  window header still focuses the toplevel.
- Clicking a `browser-tab` row focuses the owning Hyprland window, then runs
  `Target.activateTarget` through the provider (same activation path as classic
  activity cards).

## Out of scope (v1)

Close / reorder / pin tabs, tab previews, merging tabs across profiles/windows,
Firefox, and exposing URLs in the tree.

## Validation

Provider matching, filtering, and caps:
`provider/browser-profiles/tests/test_browser_profile_provider.py`.

Service parse helpers: `tests/test_browser_tabs_model.mjs`.

Sidebar projection / fold defaults: `tests/test_sidebar_model.mjs`.

Live CDP focus switching requires an isolated graphical session with Chrome
remote debugging and the installed provider binary.
