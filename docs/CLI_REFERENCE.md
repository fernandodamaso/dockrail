# Dockrail CLI reference

**Unreleased CLI-first candidate — Draft PR #44, `feat/fdm-914-cli-first`.** This describes implemented source, not an available release, permission to deploy, or completed Omarchy runtime qualification. Older installed builds may not implement this interface. Discover the selected host's schema instead of assuming this document describes that installation.

Start with [the agent guide](AGENT_CONFIGURATION.md). [Configuration inventory](CONFIGURATION.md) records every declared default and dependency. Source qualification belongs to [CLI_RUNTIME_CHECKS.md](CLI_RUNTIME_CHECKS.md); historical delivery evidence is not evidence for a newer SHA.

## Selection and transport

All commands below are prefixed with `dockrail`. Control options work before or after the command, including after a subcommand:

| Option | Meaning |
| --- | --- |
| `--json` | Exactly one versioned JSON object on stdout; diagnostics on stderr. |
| `--runtime auto` | Default: require exactly one matching Dockrail host. |
| `--runtime plugin` / `--runtime standalone` | Filter by host mode; multiple hosts of that mode still require an instance. |
| `--instance ID` | Exact native Quickshell ID or process ID, not a fuzzy/newest selector. |
| `--help`, `-h` | Offline help. |

`runtime.instanceId` is the process ID for that host lifetime; `runtime.quickshellId` is the native Quickshell ID attached by the client. Rediscover after a host restart. Explicit misses, ambiguity and protocol failures never select a different host. Retain the same selectors on every command in an operation.

The host's `data.configPath` is authoritative. The canonical configuration is `${XDG_CONFIG_HOME:-$HOME/.config}/dockrail/dock.json`; `DOCKRAIL_CONFIG` is the canonical explicit override and `SMARTDOCK_CONFIG` remains accepted for compatibility. A managed legacy `${XDG_CONFIG_HOME:-$HOME/.config}/smartdock` path may resolve to the canonical state after migration. Changing the client's environment does **not** redirect an already-running host. No configuration command launches, restarts or installs a host.

The standard-library Python adapter currently uses `qs list --all --json` and `qs ipc --pid PID call -- smartdock request PAYLOAD`, with argv arrays, no shell evaluation, a 2-second subprocess timeout and an 8-second discovery/IPC deadline. Requests are bounded to 64 KiB and response stdout to 1 MiB. Diagnostics remain separate. The Omarchy wrapper's newest-instance selection cannot provide the exact selection required here; no guessed wrapper flags or raw socket protocol are used. Compatibility with the installed Quickshell build and real scheduling is a local gate.

## Discovery commands

| Command | Result and limits |
| --- | --- |
| `help` | Prints full help; bare `dockrail` does the same. No host or directories required. |
| `agent-guide` | Prints the installed `docs/AGENT_CONFIGURATION.md`; works without the source checkout or a host. With JSON, text is `data.text`. |
| `status` | Selected host identity, config path, load/write state and revision. Not a settings mutation. |
| `doctor` | Read-only status plus `data.checks` and stable `data.features` readiness. Optional `missing`/`degraded` features still exit 0; missing runtime, invalid configuration or failed persistence exits nonzero. |
| `config schema` | Optional `KEY`; keyed `data.settings`, `schemaVersion: 1`, implemented `data.commands`, `source: runtime` or `bundled`. Defaults are loaded from `config/dock.json`, not duplicated in metadata. |
| `config get` | Optional `KEY` and `--effective`; keyed `data.settings` even for one key, `source`/`view: requested` or `effective`. Includes unknown retained keys on a full read. |

Only `config schema` may fall back to bundled metadata, and only after genuinely absent automatic discovery with no explicit instance. It is not the user's configuration. Explicit runtime selection, ambiguity, timeouts or malformed responses prohibit fallback. All other config/app/icon operations require a running host.

Status fields: `runtime`, `configPath`, `loadState` (`missing`, `loaded`, `invalid`), `loadError`, `loadPending`, `revision`, `writeState` (`idle`, `saving`, `saved`, `error`), `writeError`, `persisted`, `defaultsInUse`. A missing file is not a saved defaults file. Invalid disk configuration retains last-good live values and blocks ordinary writes; repair explicitly rather than replacing it with defaults. Revision is scoped to the host lifetime, not a compare-and-swap token. Pending readback makes persistence unconfirmed.

Requested values retain intent. Effective output projects current normalization and layout dependencies, not fully resolved rendering. Theme-owned/token colors and theme-owned border width are `null`, with `themeResolution: not-reported` and a warning on effective reads. Do not erase a token because its renderer-resolved value is unknown.

### Doctor feature readiness

`dockrail doctor --json` keeps `apiVersion: 1` and adds a stable
`data.features` object. Its keys are `sidebar`, `herdrAgents`,
`chromeProfilesTabs`, `launcherCounts`, `agentLaunchers`, and
`cliFreshness`. Every feature has exactly these readiness fields:

```json
{
  "status": "ready | missing | degraded",
  "reason": "human-readable current fact",
  "nextStep": "one human-readable next action"
}
```

`ready` means the requested runtime prerequisites are currently observable;
`missing` means a required optional component or enablement is absent; and
`degraded` means the feature is configured or partly present but cannot provide
its complete behavior. Optional readiness does not change doctor exit status.
Core runtime discovery, invalid configuration, persistence failure, transport
and protocol failures keep their existing nonzero behavior.

The detector is strictly read-only. It reads effective per-monitor presentation
from status, requested feature flags through `config.get`, local executable and
desktop-entry presence, Herdr's bounded `--version` output, current
`herdr.agents` Widget lease diagnostics, and installed provider processes.
The Chrome check makes one bounded HTTP request to
`127.0.0.1:<configured-port>/json/version`; it never follows redirects or
contacts a non-loopback host. Doctor never starts a provider or host, writes
configuration, runs migration, installs anything, or changes the desktop.

Herdr below 0.9.1 is `degraded` because click-to-focus is unavailable. Chrome
profiles/tabs require an installed and running browser-profile provider, a
reachable local DevTools endpoint, and at least one of
`browserProfileBadgesEnabled` or `sidebarBrowserTabsEnabled`. Launcher counts
check only the provider binary as specified by that feature's install contract.
CLI freshness compares the client source revision and bundled client surface with
the running plugin/standalone installation; a plugin-linked ONB-01 client is
inherently `ready`.

Human `dockrail doctor` renders the same feature status, reason and single next
step without changing the JSON contract.

## Configuration commands

| Command | Arguments and semantics |
| --- | --- |
| `config set` | `KEY VALUE`. Reads the selected host's schema and sends one minimal `config.apply` patch. Strings are literal; booleans require lowercase `true`/`false`; numbers must be finite; arrays/objects are JSON arguments. |
| `config apply` | Exactly one of `--stdin` or `--file PATH`; optional `--dry-run`. Explicit UTF-8 JSON object input, at most 64 KiB. No implicit stdin, offline writer or deep merge. |
| `config reset` | Exactly one `KEY` or `--preferences`. One key resets that key, including a collection; preference reset has the exclusions below. |
| `config retry` | Retry a failed save using the complete **current** live snapshot, not an old patch. Does not increment the settings revision. Inspect the error first. |
| `config export` | `--output PATH`. Export requested live settings to a separate **new** owner-only JSON file; not necessarily saved source values. |

Array values use JSON syntax. `workspaceMonitorOrder` is an exact case-sensitive connector-name array used only to order grouped/all monitor sections. Empty `[]` selects automatic physical ordering by finite monitor x then y; configured connected connectors lead, other connected monitors append automatically, and disconnected connector names remain saved for reconnect. It never reconfigures Hyprland monitors or workspaces, and flat/current-monitor layouts keep the value without a visual effect.

```bash
dockrail config get workspaceMonitorOrder --json
dockrail config set workspaceMonitorOrder '["HDMI-A-1","DP-1"]' --json
dockrail config get workspaceMonitorOrder --effective --json
dockrail config reset workspaceMonitorOrder --json
```

New patches reject unknown keys, unsafe/prototype-sensitive keys, wrong types, invalid enums/ranges, duplicate JSON keys/canonical application identities and non-finite numbers. Validation is atomic: one bad value rejects the complete patch. `workspaceMonitorOrder` additionally rejects blank/padded/control-containing connector names and exact duplicates while allowing valid virtual connector strings. Array/object values replace that key; per-app commands are preferable to replacing a collection. Accepted unrelated legacy values and unknown extension keys remain untouched.

Dry run validates against current state and returns proposed `changedKeys`, `diff`, full `requested`, projected `effective`, `dryRun: true`, `applied: false`, `persisted: false`. `sourcePersisted` describes the current source. It does not write, create config directories or increment revision. Apply recomputes against latest host state; a dry run is not a reservation. Cooperating host intents serialize; disjoint changes survive and the later accepted same-key intent wins. Known pending reload/write returns busy instead of using stale state. Arbitrary external editors are not transaction-safe participants.

Mutation data includes status plus `changedKeys`, full `requested`/`effective`, `diff` keyed by changes with `{from,to}`, `dryRun`, `noop`, `applied`, `persisted`, `sourcePersisted`, and `themeResolution`. An actual completed save reports `writeState: saved`; an unchanged already-durable state need not perform another save. `noop` describes settings, not image reloads. A previous write error remains visible on an identical request.

A failed save can return `E_PERSISTENCE`, `applied: true`, `persisted: false`: the live change remains active for the session. Retry saves the latest snapshot. Busy/invalid states refuse unsafe mutations. A timeout has unknown outcome (`applied: null`, `persisted: null`); read status and affected values before another mutation. Never interpret exit status alone as visible-rendering confirmation.

Preference reset preserves `pinned`, `hiddenApplications`, `browserActivityMutedServices`, `iconOverrides`, `windowIconOverrides`, `margin` and unknown extension keys. It resets all other declared preferences, **including `controlCommand` and `workspaceMonitorOrder`**; the latter returns to `[]` automatic ordering. That command is executable configuration used later by the launcher action; validation never executes it. Pointer action `close` may close all live grouped members when used. Change executable or destructive-on-use settings only for explicit user intent.

Malformed legacy `workspaceMonitorOrder` state is preserved in requested readback and projects effectively as `[]` without an automatic rewrite. This keeps unrelated mutations byte-for-value compatible while allowing an explicit `config set` or `config reset` to repair the key.

Export creates a new file with mode 0600, does not create missing parent directories, and refuses existing files, destination symlinks/hardlinks and aliases of the live path. There is no force switch. The plain file contains requested settings, including unsaved values and unknown keys. Its acknowledgment includes `exportWritten`, `exportPath`, `sourcePersisted`, `sourceRevision`, `sourceRuntime`, `configPath`, `applied: false`. A successful snapshot is not a successful live save. No whole-snapshot restore/import command exists: re-read and restore only touched supported keys. A snapshot containing unknown keys is deliberately not accepted wholesale by apply.

## Application commands

| Command | Arguments and semantics |
| --- | --- |
| `apps list` | At most one of `--query TEXT`, `--pinned`, `--hidden`; no filter lists the host catalog plus retained configured identities. |
| `apps pin` | `ID`; add pinned membership without showing a hidden app or launching it. |
| `apps unpin` | `ID`; remove pinned membership, not running windows or hidden membership. |
| `apps hide` | `ID`; hide the application without closing windows or changing pins. |
| `apps show` | Exactly `ID` or `--all`; clear the requested hidden membership, not pins. `--all` needs explicit broad intent. |
| `apps move` | `ID` and exactly `--before OTHER` or `--after OTHER`; both distinct IDs must already be pinned. |

Discovery uses the selected host's native `DesktopEntries.applications.values`, not a separate file scanner. Rows in `data.applications` contain `id`, `name`, `available`, `pinned`, `hidden`, `pinnedIndex` (zero-based, null when unpinned). Query matches ID/display-name text; mutation identity is exact after trimming, case folding and optional `.desktop` removal. Names and fuzzy results never become mutation targets automatically. Unsafe/path/control-containing, placeholder and prototype-reserved IDs are rejected.

Configured spelling and order are retained. Pinned/hidden filters preserve their configured order and include unavailable stored IDs. An otherwise unknown safe ID can be pinned without an installation claim. Membership commands are idempotent. Move operates on the latest complete pinned list, including hidden/unavailable entries, preserving all other relative order. These are host primitive intents, not stale client array replacements.

## Icon commands

| Command | Arguments and semantics |
| --- | --- |
| `icons list` | Requested app-wide `data.overrides`, normalized `effectiveOverrides`, requested `windowOverrides`, normalized `effectiveWindowOverrides`, `iconReloadRevision`, `renderVerified: false`, plus status. |
| `icons set` | `ID PATH`; update one app-wide mapping, or add/edit a window rule when `--title-pattern` is supplied. |
| `icons reset` | `ID`; remove only that app-wide mapping, or the exact window rule when `--title-pattern` is supplied. |
| `icons reload` | `ID`; require a valid existing app/profile mapping and advance the shared reload revision without a config write. Window rules use same-source `icons set ... --title-pattern` for byte reload. |
| `--profile DIR` | With `set`/`reset`/`reload`, target one browser profile instead of the whole application. Mutually exclusive with `--title-pattern`. |
| `--title-pattern PATTERN` | With `set`/`reset`, target raw Wayland `ID` + title rule. Only `*` is special; patterns are trimmed, case-insensitive, 1–200 chars, and cannot contain controls. Mutually exclusive with `--profile`. |

Use static local PNG/SVG files referenced in place. The client resolves ordinary relative paths against its current directory; the shared model validates absolute paths and supported local `file:///` URLs, preserving spaces/Unicode through URL encoding. No remote URLs, downloads, system theme writes, imports or `.desktop` edits. Store artwork outside the plugin checkout. Missing/unreadable/corrupt files keep their requested mapping and fall back.

Window-rule set/reset is also a latest-state intent: a CLI set edits the exact normalized
`(appId,titlePattern)` key in place or appends it when absent; reset removes only that
key. Rule order controls first-match precedence. The host-owned **Change Icon…** dialog adds
stale-edit protection (`E_CONFLICT`) to its own saves, but no public concurrency flag is added.

Set/reset preserves unrelated map entries, including untouched legacy sources. A bulk `iconOverrides` patch instead validates/replaces the whole map, rejecting canonical duplicates. A same-source set requests fresh bytes without a redundant settings write. The dock watches referenced artwork files and refreshes automatically after same-path edits, so reload is retained for compatibility and forcing a refresh. Reload advances a global revision, so other mapped icons may refresh too.

Successful icon mutations add `reloaded`, `iconReloadRevision`, `renderVerified: false` to mutation data. Reload normally has `applied: false`, `noop: true`, `reloaded: true`; these fields are not contradictory. `reloaded` means requested, not decoded. Settings acceptance, durable save and actual rendering are separate observations.

The shared renderer applies across main app icons, preview metadata and picker rows. Fallback is profile-specific custom file → app-wide custom file → original desktop icon → `application-x-executable` → bundled theme-tinted `app-window` glyph. Custom artwork is not tinted. A successfully rendered profile-specific file suppresses its profile badge; app-wide artwork and fallbacks retain the badge. Identity, launch command, grouping, preview screenshots, Trash and action glyphs are unchanged. A Chrome tab remains a Chrome-grouped item; artwork does not split browser groups.

## JSON and errors

Every response uses `apiVersion: 1`, Boolean `ok`, object `data`, array `warnings`; failures add `error: {code,message}`. Help/guide put text in `data.text`. The IPC endpoint is one typed host-owned `smartdock.request(string): string`, outside screen delegates. Requests are `{apiVersion:1, command:"config.apply", arguments:{patch:{showTrash:false},dryRun:false}}`; other requests use dotted commands with primitive/object arguments, never executable snippets. `set` maps to apply; export reads get and writes only its separate new snapshot. There is no second capabilities registry.

| Exit | Error codes | Response action |
| --- | --- | --- |
| 0 | none | Inspect operation-specific application/persistence/rendering fields. |
| 2 | `E_USAGE`, `E_VALIDATION` | Correct syntax or the requested key/value; no successful mutation. |
| 3 | `E_RUNTIME_NOT_FOUND`, `E_RUNTIME_AMBIGUOUS` | Discover/choose the intended exact host; do not start one automatically. |
| 4 | `E_PERSISTENCE`, `E_EXPORT` | Inspect live state and save/export error; a live change can remain unsaved. |
| 5 | `E_TRANSPORT`, `E_PROTOCOL`, `E_TIMEOUT` | Verify installed compatibility and selected-host state; applied outcome can be unknown. |
| 6 | `E_BUSY`, `E_CONFIG_INVALID` | Re-read once pending work settles, or explicitly repair the invalid file; do not replace defaults or retry forever. |

## Installation and lifecycle boundary

From the intended source checkout, `bash ./install.sh --cli-only` installs the canonical `${XDG_BIN_HOME:-$HOME/.local/bin}/dockrail` command plus the `${XDG_BIN_HOME:-$HOME/.local/bin}/smartdock` compatibility command, with the adapter, defaults, schema, agent guide, reference and inventory under `${XDG_DATA_HOME:-$HOME/.local/share}/dockrail-cli`. `bash ./uninstall.sh --cli-only` removes this bundle while preserving settings, plugin and standalone ownership. Both installation orders retain the launchers while another bundle owns them. Help and guide use the installed bundle, not `.source-dir`. When canonical and legacy bundles coexist, the canonical client bundle takes precedence; update that bundle explicitly from the intended source.

Full `install.sh` is an explicit standalone installation with separate lifecycle effects and optional autostart; it is not needed to configure the plugin. Explicit wrapper commands `launch`/`--daemonize`, `restart`, `stop`, `update`, `uninstall`, and `autostart enable|disable|status` remain standalone lifecycle commands, outside this versioned control-command JSON contract. `dockrail update` is not a plugin or client-only updater. Use client-only reinstall for client updates and the normal, separately authorized Omarchy deployment path for a released plugin. No merge/deploy is authorized by this candidate reference.

## Sidebar configuration and diagnostics

The SB-02 candidate adds `presentationMode`, `presentationModeByMonitor`,
`sidebarEdge`, `sidebarMonitor`,
`sidebarExpandedWidth`, `sidebarCollapsed`, `sidebarCollapsedByMonitor`,
`sidebarBrowserTabsEnabled`, `sidebarWidgets` and `sidebarWidgetCollapsed`.
Discover these keys on the selected
host; do not assume an installed release implements this candidate.

In an isolated candidate session only:

```sh
dockrail config set presentationMode sidebar --json
dockrail config set presentationModeByMonitor '{"DP-1":"classic"}' --json
dockrail config set sidebarEdge right --json
dockrail config set sidebarMonitor DP-1 --json
dockrail config set sidebarExpandedWidth 320 --json
dockrail config set sidebarCollapsed true --json
dockrail config apply --json '{"sidebarCollapsedByMonitor":{"DP-1":true,"HDMI-A-1":false}}'
dockrail config get --effective --json
dockrail config set presentationMode classic --json
dockrail config reset presentationModeByMonitor --json
```

`data.presentation` reports the primary screen, full `screens` list for mirrored
panels, per-screen `collapsedByScreen`, effective width, geometry mapping
eligibility, and inactive classic settings. It also reports the per-monitor
resolution: `defaultMode`, `perMonitor` (each connected connector's
`{connector, mode, source, mapped, sidebarSelected}`), keyed `modeByMonitor`,
`sourceByMonitor` and `mappedByMonitor`, the `classicScreens` list, and `mixed`
when classic and sidebar outputs coexist. `source` is `override` for an explicit
`presentationModeByMonitor` entry and `inherited` otherwise. In a mixed layout
the legacy summary fields stay historical — `mode` is the inherited default and
`screen`, `screens`, `width` and `mapped` describe the rendering sidebar — so
use `perMonitor` for the per-connector truth. Saved disconnected monitor
preferences remain visible in requested output; in a sidebar-only layout
effective `sidebarMonitor` names the primary mapped connector or is null with no
screens. Empty preference maps every connected output. Global
`sidebarCollapsed` is the default rail when a connector has no map entry.
`presentationModeByMonitor` follows the same explicit object-patch rule as
`sidebarCollapsedByMonitor`: set/apply replaces the whole map, dropping one
connector's key restores inheritance for it,
`config reset presentationModeByMonitor` restores `{}`, and a
`presentationMode` write changes only the default, never the overrides.
Connector keys are exact case-sensitive names; control characters or values
other than `classic`/`sidebar` fail with `E_VALIDATION`. `sidebarExpandedWidth`
is the effective expanded width, while `presentation.width` is the current
rail/expanded width on the primary sidebar screen.
A successful model projection is not live rendering evidence. Existing persistence
flags remain authoritative: accepted-but-saving (`data.applied: true`) must not be
replayed as though rejected. `config retry` uses the latest host snapshot.

These controls do not install widgets or alter the stock topbar. This Draft slice
is not an integrated release; see `docs/SIDEBAR.md` in the source checkout.

### Internal Widgets (FDM-967 / FDM-973)

```sh
dockrail config schema sidebarWidgets --json
dockrail config get sidebarWidgets --json
dockrail config set sidebarWidgets '[]' --json
dockrail config get sidebarWidgetCollapsed --json
dockrail config set sidebarWidgetCollapsed '{"example.internal":true}' --json
dockrail config get --effective --json
```

`sidebarWidgets` is an ordered, duplicate-free array of IDs from live
`registeredIds`, initially empty. Explicit unknown IDs/types/duplicates fail with
`E_VALIDATION`; `config apply` validates atomically at the host. Registration is
independent of authentication or loading/error status. Imported unknown IDs survive
unrelated writes and appear unavailable under `data.presentation.widgets`; they
are omitted from effective `sidebarWidgets` and never executed. Diagnostics contain
at most 32 status rows plus aggregate lifecycle counters, never task/window content
or credentials. The ordered array is also the card order. Clearing/resetting it
removes all enabled Widget cards. `sidebarWidgetCollapsed` is a separate typed
ID→boolean map; missing keys mean expanded, and removing a Widget intentionally
keeps its saved collapse state for a later re-add. No collapse entry enables or
executes a provider. No test provider or external QML path is enabled by production.


## External Widget packages (API v1)

Widget package management is a top-level local CLI surface and does not mutate
Dockrail configuration directly:

```bash
dockrail widget create io.example.weather --name "Weather" --destination "$HOME/Projects/weather-widget"
dockrail widget install "$HOME/Projects/weather-widget"
dockrail widget remove io.example.weather
dockrail widget list --json
dockrail widget update io.example.weather
dockrail widget dev use "$HOME/Projects/weather-widget"
dockrail widget dev reload
dockrail widget dev reset
```

`<source>` is an explicit trusted local directory or repository URL. Installed
packages live under `${XDG_DATA_HOME:-$HOME/.local/share}/dockrail/widgets/<id>/`.
Updates stage and validate a replacement before swapping it into place; updating
one package never runs `git pull` against the Dockrail plugin/deployment and a
failure does not stop unrelated packages from being attempted.

The runtime registry is host-owned. `dock.json` and `sidebarWidgets` continue
to contain stable Widget IDs only; they never contain QML paths or package source
locations. Package schema, trust boundaries, development workflow, and source
location rules are specified in `docs/WIDGET_PACKAGES.md`.
