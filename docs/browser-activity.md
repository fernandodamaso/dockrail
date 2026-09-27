# Browser activity provider

Dockrail's optional browser-profile provider publishes profile ownership and
small, privacy-preserving activity rows for Chrome. It is an additive snapshot
alongside the existing `windows` and `profiles` maps.

## Enable Chrome profiles and tabs

Chrome's DevTools endpoint is optional; Omarchy does not enable it by default.
[Chrome requires a non-default user data directory for remote debugging](https://developer.chrome.com/blog/remote-debugging-port).
This starts a fresh Chrome profile, separate from your normal logins and
extensions. You will need to sign in again and set up extensions in that profile.

To add the two required flags to `~/.config/chrome-flags.conf`, run:

```bash
mkdir -p "${XDG_CONFIG_HOME:-$HOME/.config}"
printf '%s\n' \
  "--user-data-dir=$HOME/.config/google-chrome-debug" \
  '--remote-debugging-port=9222' \
  >> "${XDG_CONFIG_HOME:-$HOME/.config}/chrome-flags.conf"
```

The file must contain an absolute path, such as
`--user-data-dir=/home/your-name/.config/google-chrome-debug`, followed by
`--remote-debugging-port=9222`; a literal `$HOME` in this file is not expanded
by the Chrome launcher. If these flags are already present, edit the existing
lines instead of appending duplicates. Quit all Chrome windows and restart
Chrome so it reads the new flags.

From the installed Dockrail plugin folder, install the optional provider and
reload or restart the Dockrail plugin:

```bash
cd "${XDG_CONFIG_HOME:-$HOME/.config}/omarchy/plugins/io.github.fernandodamaso.dockrail"
bash ./scripts/install-browser-profile-provider
```

With Chrome running, check the endpoint:

```bash
curl -s localhost:9222/json/version
```

A JSON response with a `Browser` field confirms that Chrome is listening.
If the connection fails, check the flags and restart Chrome. This checks the
DevTools endpoint; profile and tab display also requires the provider and
Dockrail plugin to be running.

**Security:** The port binds to localhost only, but while it is open any local
process can control this Chrome profile and read its pages and cookies. Enable
it only if you want Dockrail's profile and tab features. To turn it off, remove
`--remote-debugging-port=9222` from `chrome-flags.conf` and restart Chrome.
Remove the `--user-data-dir` line too if you want Chrome to return to your
normal profile. Without the endpoint, Dockrail keeps plain application icons.

## Snapshot contract

The provider emits a snapshot such as:

```json
{
  "schemaVersion": 1,
  "available": true,
  "port": 9222,
  "classes": ["google-chrome"],
  "windows": {"0x123": "Profile 1"},
  "profiles": {"Profile 1": {"name": "Work", "path": "..."}},
  "activities": {
    "0x123": [{
      "targetId": "A1B2",
      "serviceId": "whatsapp",
      "label": "WhatsApp",
      "profileKey": "Profile 1",
      "domain": "web.whatsapp.com",
      "count": 3,
      "windowAddress": "0x123"
    }]
  }
}
```

The provider accepts only HTTPS targets on `web.whatsapp.com`,
`www.instagram.com`, or `mail.google.com`. WhatsApp requires `(N) WhatsApp`;
Instagram accepts `(N) Instagram` with its optional page label. Gmail requires
the supported English or Portuguese inbox title and the exact `#inbox` listing
route. Subjects, drafts, other
folders, and unverified localized title forms are ignored rather than
interpreted as unread counts. Keep a supported Gmail inbox tab open to expose
its count; an open message is not an inbox listing even when its subject
resembles an inbox title. Counts are positive integers capped at 999999.
Duplicate targets for one service/profile are reduced to the highest count, and
target IDs are validated before display or activation.

The card exposes profile names, service labels, counts, and ordinary window
preview captures. It never publishes URLs, titles, message text, account
identifiers, or page content. A click is accepted only when the target ID and
window address still exist in the current snapshot; Dockrail then activates
the Hyprland window and sends `Target.activateTarget` through the provider.

Users can mute individual services from the activity card with the eye /
eye-off control on each row. Mute is keyed by `serviceId` only (for example
`gmail` or `whatsapp`), not by profile. Muted rows stay in the list and remain
clickable, but they are dimmed and excluded from the card header total and the
Chrome dock badge fallback. The muted set is stored as
`browserActivityMutedServices` in user `dock.json`, survives preference reset,
and can be read or written with the ordinary CLI:

```bash
dockrail config get browserActivityMutedServices --json
dockrail config set browserActivityMutedServices '["gmail"]' --json
```

The provider executable is optional. If it is absent, unreachable, or emits an
invalid optional `activities` field, profile/window previews remain usable and
activity rows are cleared. A validated Chrome activity total is only a fallback
for the Chrome launcher badge. An authoritative LauncherEntry count always
wins, including an explicit zero or hidden state; other applications keep the
existing launcher-count and attention-dot precedence.

When one dock item represents multiple Chrome windows, its fallback count is the
reduced total for those represented windows. When window grouping is disabled,
each Chrome item shows only the fallback count owned by its represented window.
Application-wide LauncherEntry counts retain precedence and render only on the
primary visible item.

Sidebar nesting of ordinary open tabs (titles only) is documented separately in
[`browser-tabs.md`](browser-tabs.md). Do not overload `activities` for a general
tab list.

## Validation

Provider parsing and activation are covered by
`provider/browser-profiles/tests/test_browser_profile_provider.py` and the
negative title/snapshot fixtures in `test_activity_title_regressions.py` beside
it. `tests/test_browser_activity_preview.py` exercises the production session
methods, activity bindings and change handlers with real offscreen Qt
notifications, including preview switching, activity loss and muted rows.
QML model, preview, and badge behavior are also covered by the existing
`qmltestrunner` suites. The checks do not claim live Chrome CDP, image decoding,
focus, or auto-hide qualification; those require an isolated graphical session
with the provider installed and Chrome launched with remote debugging enabled.
