# External Widget packages -- API v1

Dockrail custom Widgets are independent packages. They do **not** live in the
Dockrail repository and must never be developed in the installed Omarchy plugin
checkout.

## Source, deployment and runtime boundaries

There are three different locations with different ownership:

1. **Dockrail core source** -- this repository's root (`.`). Core changes use
   an ordinary branch/worktree and `dockrail dev use`.
2. **Custom Widget source** -- a separate directory or Git repository owned by the
   Widget developer, normally under `~/Projects/dockrail-widgets/`. Use the
   `dockrail widget ...` commands below.
3. **Installed Dockrail plugin** --
   `~/.config/omarchy/plugins/io.github.fernandodamaso.dockrail/`. This is
   deployment state. Never edit it or create Widget source under it.

Installed external package snapshots live at:

```text
${XDG_DATA_HOME:-$HOME/.local/share}/dockrail/widgets/<widget-id>/
```

Dockrail upgrades copy/update core files without owning that `widgets/`
subdirectory. Widget package updates operate only there and never run `git pull`
in the Dockrail plugin checkout.

## Package API v1

A source package is self-contained:

```text
my-widget/
|-- widget.json
|-- Widget.qml
`-- assets/
```

`widget.json` v1:

```json
{
  "apiVersion": 1,
  "id": "io.example.weather",
  "name": "Weather",
  "version": "0.1.0",
  "entry": "Widget.qml",
  "icon": "cloud"
}
```

Fields are deliberately small and closed in v1:

- `apiVersion` -- integer `1`. Incompatible packages are not registered or run.
- `id` -- stable lower-case Widget ID, maximum 64 characters. External packages
  cannot replace Dockrail-owned IDs such as `herdr.agents` or `demo.*`.
- `name` -- display name, maximum 128 characters.
- `version` -- package version string used for diagnostics/listing.
- `entry` -- relative `.qml` entry inside the package. Absolute paths and `..`
  traversal are rejected.
- `icon` -- Lucide-style lower-case icon name.

Package trees are bounded and may not contain symlinked files/directories. The
top-level `Dockrail/` directory is reserved for host-owned runtime files and
is rejected in developer source packages. A validated package is copied into
Dockrail-owned data, then Dockrail materializes the public WidgetKit beside
the installed entry. Developer source keeps the versioned
`import Dockrail.WidgetKit 1.0` contract; only the Dockrail-owned
installed/development snapshot adapts either the canonical or legacy named import to the package-local runtime
copy so dynamically loaded QML does not depend on an engine-global Dockrail
import path. The developer source is never rewritten. The host constructs the
file URL from that trusted package root; `dock.json` never receives the path or
URL.

> External Widget packages are trusted local code. Installation is explicit;
> Dockrail does not auto-execute arbitrary repositories or marketplace entries.

## Runtime contract

`dock.json` continues to select IDs only:

```json
{
  "sidebarWidgets": ["io.example.weather"]
}
```

The package subsystem maps validated installed IDs to package-relative entry paths
in its own atomic registry. The host reconstructs executable file URLs only from
that Dockrail-owned package root. The host merges those descriptors into the **existing**
Widget registry. From there the normal `DockSidebarWidgetModel` lease manager,
`DockWidgetCard`, shared-scroll area, popup ownership and existing settings writer
remain authoritative.

Unknown IDs are non-executable. A malformed package is omitted independently;
it cannot disable an unrelated valid package. Duplicate/protected IDs are never
silently allowed to shadow another Widget.

The Widget entry root follows the existing body contract:

```qml
import QtQuick
import Dockrail.WidgetKit 1.0

Item {
  property var widgetContext: ({})
  implicitHeight: body.implicitHeight

  WidgetSection {
    id: body
    width: parent.width
    title: "Weather"

    WidgetText {
      width: parent.width
      text: "Ready"
    }
  }
}
```

The body consumes `widgetContext.data`; it does not acquire providers, write
settings, recreate card chrome or own sidebar scrolling. See
[`WIDGET_COMPONENTS.md`](WIDGET_COMPONENTS.md) for the public presentation kit.

## CLI

### Create source

```bash
dockrail widget create io.example.weather --name "Weather"
dockrail widget create io.example.weather --destination ~/Projects/weather-widget
```

The default source root is `~/Projects/dockrail-widgets/<id>`. The command
creates `widget.json`, `Widget.qml` and `README.md`, then validates its own output.
A destination inside Dockrail source/deployment state is a hard error.

### Install

```bash
dockrail widget install ~/Projects/weather-widget
dockrail widget install https://github.com/example/weather-widget.git
```

Only an explicit local directory or explicit supported Git repository source is
accepted. Dockrail validates before installing and atomically exposes the new
snapshot. Installing an already installed ID fails; use `update` instead.

### List

```bash
dockrail widget list
dockrail widget list --json
```

Rows report ID, name, API/package version, source/install/dev state, enabled
state, compatibility/validation, and ownership (`built-in`, `integration` or
`external`). Invalid package directories are reported separately and are not
registered.

### Remove

```bash
dockrail widget remove io.example.weather
```

Removal is targeted. The developer source is never deleted. An enabled Widget or
one with an active dev override must first be removed from the enabled Widget list
or reset respectively. Dockrail does not silently edit unrelated settings to
make removal succeed.

### Update

```bash
dockrail widget update io.example.weather
dockrail widget update
```

The stored explicit source metadata is reused. Local sources are recopied; Git
sources are cloned into a fresh temporary checkout. Candidates are validated
before atomic replacement. `update` without an ID processes packages
independently, so a broken package does not prevent another valid package from
updating.

## Development workflow

Install the package once, then select a separate local source:

```bash
dockrail widget install ~/Projects/weather-widget
dockrail widget dev use ~/Projects/weather-widget
```

`dev use` validates the source and creates a Dockrail-owned working snapshot.
The source is never checked out, reset, pulled, rewritten or linked into the
Dockrail plugin. The installed package remains available as the reset target.

After editing source:

```bash
dockrail widget dev reload
```

Reload validates and snapshots the candidate first, including QML syntax and
import resolution before registry metadata switches. A failed reload retains
the previous working snapshot. The existing host observes the package registry
change, so no second Dockrail or Quickshell process is started.

Return to the installed package:

```bash
dockrail widget dev reset
```

Reset removes only the Dockrail-owned dev override/snapshot and preserves the
developer source directory.

## Source-location safety

`create`, local `install`, and `dev use/reload` resolve symlinks before accepting
a source. They hard-reject direct or nested locations inside:

- the installed Omarchy Dockrail plugin tree;
- the standalone Dockrail application deployment under XDG data;
- the Dockrail source checkout used by the running CLI bundle.

If a coding agent is asked to "create a Dockrail Widget", use
`dockrail widget create` in a separate repository. Do not add custom package
source to `components/`, and do not edit the installed plugin checkout.

## Legacy module compatibility

Existing package sources and installed snapshots using `SmartDock.WidgetKit 1.0` remain supported. New source should import `Dockrail.WidgetKit 1.0`. Dockrail does not rewrite external source repositories or legacy installed snapshots merely to change the module name.
